# Gemini robotics, stage-show, and local action plan

## Outcome and current boundary

Cerebro now has the first safe rehearsal layer:

- `stop_motion` is dispatched ahead of ordinary blocking tool work and applies a
  local base software stop without waiting for ROBController approval;
- spoken stop, Gemini stop, stage cancellation, autonomy stop, and shutdown use
  the same neutral/braked base frame plus heartbeat-drop path;
- the result explicitly reports Amber arm state as unverified;
- the main-window **Show…** panel can load, validate, dry-run, and run a show in
  speech-only or adaptive mode;
- `ROBStageShow` v1 rejects unknown fields, so a show cannot contain raw joints,
  servo values, hosts, ports, or shell commands;
- every adaptive `gemini_turn` has a short timeout and authored offline line;
- a schema-constrained local stage director can now select a dialogue beat,
  produce a validated offline line, and hand a bounded prompt to Gemini Live;
- local inference runs through a loopback `llama.cpp` server with strict
  timeouts/cancellation, while the provider registry leaves an MLX Swift seam;
- named gesture cues fail closed because no calibrated gesture executor exists
  yet.

This is intentionally useful for writing and rehearsing dialogue now without
pretending that the current arm scripts form a safe motion controller.

The current `robot_action` path is only an approval/status ledger. ROBController
approval does not actuate hardware, and Cerebro does not start an action after
approval. The existing Amber commands launch independent Python processes with
no retained cancellation handle, structured result, or observed final joint
state. They must not be connected directly to model output.

## Recommended runtime architecture

Use two cloud roles and one authoritative local executive:

```text
camera RGB + aligned depth + microphone
              |
              v
  low-latency conversation model  <---->  ROBSpeechBox
              |
              | high-level intent only
              v
  optional Robotics-ER snapshot planner
              |
              | typed ActionIntent / ShowCue
              v
  Cerebro local action executive + safety supervisor
              |
              +--> stage-show runner / named gesture catalog
              +--> perception + transforms + IK in shadow mode
              +--> trajectory validation + resource leases
              |
              v
  typed hardware gateway --> Amber adapter / Maestro / base Arduino
              ^
              |
  timestamped joint, mode, fault, and completion feedback
```

The conversation model owns natural dialogue and may propose a bounded tool.
Robotics-ER can inspect selected RGB-D observations and produce structured task
plans, but it should not sit in a hard real-time loop. The local executive is the
only layer allowed to translate a named intent into motion.

### Current Google model distinction

Google's public documentation currently lists
`gemini-robotics-er-1.6-preview` as the Robotics-ER model and states that it does
not support the Live API. It does support function calling and structured
output. Gemini Live has a separate WebSocket function-calling contract. The
repository's configured `gemini-robotics-er-2-streaming-preview` may represent
access to a separate preview, but it should not be assumed to have the public
Robotics-ER 1.6 contract.

Therefore:

1. keep the currently validated streaming model configurable for conversation;
2. add an asynchronous `ROBRoboticsReasoner` interface for public Robotics-ER
   image/audio reasoning;
3. normalize both outputs into the same local `ActionIntent` schema;
4. keep every tool response correlated to the local executor's observed result.

References:

- <https://ai.google.dev/gemini-api/docs/live-api/tools>
- <https://ai.google.dev/api/live>
- <https://ai.google.dev/gemini-api/docs/robotics-overview>
- <https://ai.google.dev/gemini-api/docs/live-api/capabilities>

## Stage-show workflow available now

Open **Show…** in the main-window title bar. The bundled Maker Faire sample
demonstrates:

1. an operator safety checkpoint;
2. authored local speech;
3. deterministic beats;
4. an optional six-second Gemini improvisation;
5. an authored line when Gemini is unavailable or slow;
6. an optional named gesture that is logged and skipped until a safe executor is
   installed;
7. a closing authored line.

Modes have distinct contracts:

- **Dry Run** validates and walks every cue quickly without speech, network, or
  hardware requests.
- **Run Offline** uses local speech and authored fallbacks. It never asks Gemini
  for an improvisation.
- **Run Local** uses the schema-constrained local provider and speaks its
  validated line without contacting Gemini. Provider failure uses the authored
  fallback.
- **Run Adaptive** gives the local director at most 35 percent of a
  `gemini_turn` deadline, then sends its allow-listed beat and delivery through
  a trusted Gemini brief builder in Cerebro
  for camera/audio-aware delivery when those inputs are enabled. A Gemini
  failure uses the validated local line when available; otherwise it uses the
  authored line.
- **Stop** is idempotent, stops current speech/local coordinators, emits one
  neutral/braked base frame, drops its heartbeat, and returns base authority to
  `Brain`. It does not claim the Amber arms are held.

The v1 cue kinds are `speak`, `wait`, `gemini_turn`, `play_gesture`, and
`checkpoint`. A failed optional gesture continues the show. A failed required
gesture ends it. Keep all physical cues optional until the gesture catalog and
executor below pass hardware-in-loop testing.

## Maker Faire network strategy

Design the performance so loss of internet changes the flavor, not the ability
to finish:

- put the show's dramatic structure, safety checkpoints, dialogue, timing, and
  gestures in the local show file;
- use cloud turns only for audience names, topical callbacks, and short
  improvisation;
- require an authored fallback for every cloud cue;
- preflight Gemini, RGB-D, arm telemetry, controller pairing, and E-stop, but do
  not make internet health a requirement for **Run Offline**;
- record cue IDs, mode, monotonic dispatch time, fallback use, model latency,
  gesture revision, and observed executor result for post-show review;
- keep a physical operator at the E-stop and a separate manual control path.

A local language model now fills optional improvisation cues through the
`ROBLocalImprovisationProviding` abstraction. The first provider calls a
loopback `llama.cpp` OpenAI-compatible chat endpoint with a shallow JSON schema,
then revalidates the returned `ROBLocalImprovisationPlan`. It returns only an
allow-listed stage beat, delivery style, short Gemini prompt, and short offline
line; it receives no hardware driver and never returns joints or shell commands.

The main-window Show panel persists provider, endpoint, model alias, and timeout,
tests `/health`, and reports redacted counts/latency/error categories. Cerebro
does not install, download, or start a model at launch. A future native MLX
Swift target can register through `ROBLocalImprovisationProviderRegistry`; the
current MLX selection fails safely until `mlx-swift-lm` guided generation and a
pinned model-management path are deliberately linked.

Stage improvisation is dialogue-only. Cerebro attaches the originating text-turn
context to Gemini tool events and rejects every non-stop physical-action tool
call whose context begins `stage:`, including after a cue or show ends.
`stop_motion` remains in its
priority safety lane.

References:

- <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>
- <https://github.com/ml-explore/mlx-swift>
- <https://github.com/ml-explore/mlx-swift-lm>
- [Local improvisation provider](local-improvisation-provider.md)

## Phase 1: authoritative robot state and calibration

Do not infer the droid geometry from “10 cm apart and 30 degrees.” The separation
axis, arm origins, rotation axis, inward/outward sign, height, and tool frames are
still unknown. Measure them.

Create two versioned artifacts:

1. `robot_description/rob_droid.urdf.xacro` for mechanics and collision geometry;
2. `config/rob_hardware_calibration.v1.json` for hardware mapping and measured
   offsets.

The droid description should include the known B1 URDF twice under unique
prefixes. Attach each arm with a fixed joint to `torso_link` using measured
transforms:

```xml
<joint name="left_b1_mount" type="fixed">
  <parent link="torso_link"/>
  <child link="left_b1_base_link"/>
  <origin xyz="MEASURE_X MEASURE_Y MEASURE_Z"
          rpy="MEASURE_ROLL MEASURE_PITCH MEASURE_YAW"/>
</joint>
```

Repeat for the right arm. Do not encode `+/-0.05 m` or `+/-30 degrees` until the
reference center, axis, and signs are confirmed physically.

For each of the fourteen arm joints, neck axes, treads, rotating plate, and
grippers, record:

- stable joint and frame IDs;
- controller host/port/index without exposing them to models;
- axis sign and encoder zero;
- hard and normal-animation limits in SI units;
- velocity, acceleration, effort, and jerk limits;
- measured versus commanded-only feedback;
- calibration revision and hash.

Extend RGB-D metadata with camera intrinsics, distortion/crop metadata, device
and calibration IDs, and timestamped camera-to-neck/torso/base transforms.
`latestAlignedDepthFrame` already provides aligned millimeter depth, but no
consumer currently converts a selected RGB target into a named 3D frame.

Exit criteria: a read-only state snapshot stays fresh under load, every joint is
identified, and missing/stale calibration makes arm actuation unavailable.

## Phase 2: replace one-process-per-command Amber control

Build a supervised long-lived Amber adapter, preferably out of process so an SDK
exception cannot terminate Cerebro. Its typed API should provide:

```text
preparePositionMode(arm) -> Result
readJointState(arm) -> timestamped positions, velocities, mode, faults
commandJointTrajectory(arm, trajectory, deadline) -> cancellable handle
stopOrHold(arm, deadline) -> observed disposition
setGripper(arm, target, forceLimit) -> observed result
```

Requirements:

- one serialized queue per arm and one cross-arm resource lease;
- finite socket/process deadlines;
- retained cancellation handles;
- explicit stale, disconnected, malformed, wrong-mode, rejected, and fault
  results;
- post-command joint feedback and deviation monitoring;
- no terminal `completed` state until the observed pose is inside tolerance;
- `commanded_unverified` while feedback is unavailable;
- startup and network-loss behavior that leaves each arm in a documented safe
  disposition.

Do not promote the bundled Cartesian scripts: the active legacy path can block
on UDP receive, and the v2 Cartesian script currently has missing/undefined
symbols. Joint-space gestures are the safer first animated capability.

## Phase 3: named gesture catalog and supervised executor

Create an immutable `ROBGestureCatalogV1` separate from user keyframe files.
Each entry needs:

- unique normalized name and catalog revision/hash;
- one-arm-only designation for initial rollout;
- required starting pose and return/hold pose;
- full joint-space waypoints in calibrated radians;
- bounded duration, speed, acceleration, and maximum per-joint delta;
- allowed robot modes and required free-space envelope;
- explicit cancellation/hold behavior.

Migrate legacy keyframes only through a validator; never expose arbitrary saved
keyframes automatically. The current animation file has no named keyframes or
sequences, and the legacy playback path blocks the main thread, assumes a row
exists, uses mutable sliders, and has no completion feedback.

Enable `play_gesture` in this order:

1. dry-run produces a resolved immutable plan and zero hardware calls;
2. simulation checks limits and self-collision;
3. one arm, fixture-supported, minimum speed, operator E-stop ready;
4. compare commanded and measured trajectory;
5. add cancellation and network-loss tests;
6. only then let a controller-approved Gemini call enter the executor.

ROBController should approve or reject. Cerebro should own `executing` and every
terminal physical result. An approval must never be returned to Gemini as
completion.

## Phase 4: local FK, IK, trajectories, and dual-arm geometry

Load the verified URDF into an out-of-process planner. Pinocchio is a strong
candidate for local forward/inverse kinematics and URDF models; a complete
collision checker and time-parameterization layer are still required around it.

Before commanding Cartesian motion:

1. compare local FK with Amber-reported Cartesian positions over safely sampled
   joint poses;
2. reject the model until residual thresholds pass;
3. run IK in shadow mode and verify each candidate with FK;
4. enforce joint, workspace, self-collision, environment-collision, and
   singularity margins;
5. time-parameterize a cancellable joint trajectory;
6. monitor measured deviation and hold on stale state or lease loss.

The flaky Amber IK may remain available as a secondary candidate generator, but
it should not be the safety authority. Reliable independently commanded joints
are a reasonable execution substrate once feedback, limits, and serialization
are in place.

Reference: <https://docs.ros.org/en/jazzy/p/pinocchio/>

## Phase 5: RGB-D targets and manipulation

Keep DepthAI out of process; that boundary already prevents SDK/device failures
from crashing Cerebro. Add a local perception snapshot:

```json
{
  "target_id": "cup-17",
  "class": "cup",
  "confidence": 0.92,
  "rgb_sequence": 123,
  "depth_sequence": 123,
  "position_m": [0.0, 0.0, 0.0],
  "frame_id": "camera_optical_frame",
  "calibration_revision": "sha256:...",
  "captured_at_monotonic_ns": 0
}
```

Then implement `request_pick` locally as:

```text
observe -> choose arm -> pregrasp -> approach -> close -> verify -> retreat
```

Every transition needs fresh perception and joint state, collision checks, a
cancellable executor, and an observed result. Without gripper/object feedback,
report `commanded_unverified`, never “picked up.”

## Privacy and stage operation

Google's Robotics-ER documentation requires notice/consent when identifiable
people are present or interacting and recommends minimizing personal data. At a
public performance, post clear camera/microphone notice, avoid retaining raw
audience media by default, redact logs, and add face blurring if stored frames
are necessary. Use backend-issued ephemeral Live tokens rather than a bundled
API key.

## Validation

Foundation-only stage fixtures:

```bash
swiftc -module-cache-path /tmp/cerebro-swift-module-cache \
  -parse-as-library \
  Cerebro/ROBLocalImprovisationProtocol.swift \
  Tests/ROBImprovisationProviderFixtureStubs.swift \
  Cerebro/ROBStageShowProtocol.swift \
  Cerebro/ROBStageShowCoordinator.swift \
  Tests/ROBStageShowFixtureTests.swift \
  -o /tmp/ROBStageShowFixtureTests

/tmp/ROBStageShowFixtureTests
```

Local-provider and llama.cpp envelope fixtures:

```bash
swiftc -module-cache-path /tmp/cerebro-swift-module-cache \
  -parse-as-library \
  Cerebro/ROBLocalImprovisationProtocol.swift \
  Cerebro/ROBLlamaCppImprovisationProvider.swift \
  Tests/ROBLocalImprovisationFixtureTests.swift \
  -o /tmp/ROBLocalImprovisationFixtureTests

/tmp/ROBLocalImprovisationFixtureTests
```

Unsigned app build:

```bash
xcodebuild -quiet \
  -project Cerebro.xcodeproj \
  -scheme Cerebro \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/CerebroDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Before enabling arm execution, add fixtures for duplicate approvals, rejection
before execution, stop preemption, cancellation races, controller loss,
execution timeout, stale telemetry, gesture allow-listing, resource leases, and
the rule that no terminal completion is emitted before observed stop or target
state.
