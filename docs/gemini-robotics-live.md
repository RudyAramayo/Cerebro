# Gemini Robotics Live integration

## What is integrated

Cerebro now uses a persistent WebSocket session for
`models/gemini-robotics-er-2-streaming-preview`.

The media and response path is:

```text
ROBSpeechBox microphone tap
  -> copied hardware PCM
  -> bounded serial conversion to mono PCM16 at 16 kHz
  -> Gemini realtimeInput.audio

CameraManager sample buffer
  -> latest frame sampled at no more than 1 FPS
  -> resized to at most 768 pixels on the longest edge
  -> JPEG
  -> Gemini realtimeInput.video

Gemini serverContent model text or outputTranscription
  -> coalesced through turnComplete
  -> ROBMainViewController
  -> on-screen ROB transcript
  -> existing [ROBSpeechBox sayIt:]
```

The implementation is intentionally half-duplex. While `ROBSpeechBox` is
speaking, microphone frames are withheld and `audioStreamEnd` is sent after the
already queued microphone frames. This prevents the robot's synthesized voice
from being sent back to Gemini before acoustic echo cancellation is available.

The existing on-device Apple speech recognizer remains active for local
transcription, wake handling, and local stop phrases. Its transcript is not
submitted again while the Gemini raw-audio session is ready, preventing
duplicate turns. When raw audio is disabled, the local transcript uses
`realtimeInput.text` immediately. Cerebro enables server-side input
transcription so `Gemini Robotics heard:` in the Xcode console confirms what
Gemini understood independently of Apple's local transcript.

The ER2 streaming preview returns spoken output through
`serverContent.outputTranscription` even when its accepted setup modality is
`TEXT`. Cerebro coalesces that transcription, waits for `turnComplete`, and
passes the completed reply to `ROBSpeechBox`. This preserves ROB's configured
system voice and existing half-duplex echo suppression. A missing response no
longer blocks every later request: text and locally detected raw-microphone turns
have a 15-second response-start deadline and a 120-second absolute completion
deadline, after which Cerebro speaks a failure notice and reconnects without
automatically replaying a potentially tool-bearing request. The on-device
transcript is used only to arm and debounce the raw-audio deadline; its text is
never submitted as a duplicate request.

## Authentication

No Gemini credential should be committed to source code, the application
bundle, or a shared Xcode scheme. A developer-local scheme variable is suitable
only when that scheme is excluded from Git; production credentials belong in a
backend-issued ephemeral-token flow or another secret store.

For local development, add this environment variable to the Cerebro scheme in
Xcode under **Run > Arguments > Environment Variables**:

```text
GEMINI_API_KEY=<development key>
GEMINI_ROBOTICS_ENABLED=true
```

For a deployed robot, prefer a backend-issued, model- and configuration-bound
ephemeral token:

```text
GEMINI_EPHEMERAL_TOKEN=<short-lived token>
GEMINI_ROBOTICS_ENABLED=true
```

When both are present, the ephemeral token takes precedence and Cerebro uses
the constrained WebSocket endpoint. Rotate the Gemini key that was previously
committed to `ROBAI.swift`; removing it from the current source does not revoke
it or erase it from Git history.

`GEMINI_EPHEMERAL_TOKEN` is currently read once when `ROBAI` is created. A
production deployment therefore needs a backend token provider and an in-app
refresh/reconnect path before relying on short-lived tokens continuously; the
current development path requires restarting Cerebro with a fresh token.

If explicit enablement or a credential is missing, the application continues
running with Gemini disabled and logs the missing configuration.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `GEMINI_ROBOTICS_ENABLED` | `false` | Must be set to `true` before any camera or microphone data is transmitted. |
| `GEMINI_ROBOTICS_MODEL` | `gemini-robotics-er-2-streaming-preview` | Model override. The `models/` prefix is added automatically. |
| `GEMINI_ROBOTICS_RESPONSE_MODALITY` | `TEXT` | Setup response modality. The configured ER2 preview was live-validated with `TEXT`; set `AUDIO` only for a model whose Live contract requires it. Both paths use output transcription for ROBSpeech. |
| `GEMINI_ROBOTICS_STREAM_AUDIO` | `true` | First-run default for microphone streaming. The in-app switch becomes authoritative after the operator changes it. When off, local Apple transcripts use `realtimeInput.text` while Gemini is connected. |
| `GEMINI_ROBOTICS_STREAM_VIDEO` | `true` | First-run default for sampled JPEG camera input. The in-app switch becomes authoritative after the operator changes it. |
| `GEMINI_ROBOTICS_SYSTEM_INSTRUCTION` | Built-in ROB instruction | Overrides wake-name, response-style, and physical-action guidance. |
| `GEMINI_ROBOT_ACTION_TOOL_ENABLED` | `false` | Declares the blocking `robot_action` tool and enables the Cerebro-to-ROBController action bridge. Keep disabled except during supervised protocol testing. |

Unrecognized values for the microphone, camera, or robot-action flags fail
closed. Connection states are logged as `off`, `connecting`, `ready`,
`reconnecting`, `failed`, or `disconnected`. The session keeps the latest resumable handle,
enables sliding-window context compression, reconnects after `goAway`, and uses
bounded exponential backoff after failures. Successful text sends are logged by
turn number without logging the prompt, credential, or media payload.

### Runtime controls and diagnostics

Use the **Gemini…** button in Cerebro's main-window title bar to open a live,
redacted control and diagnostics panel. It provides three independent switches:

- **Connect to Gemini** opens or closes the Live WebSocket. Off blocks new
  text, microphone, and camera input, clears queued media, and prevents
  automatic reconnects. Pending controller-authorized robot actions receive a
  cancellation request and Cerebro applies its local software stop first.
- **Send microphone audio to Gemini** gates raw PCM forwarding immediately.
  Turning it off flushes Gemini's cached audio with `audioStreamEnd`; Apple's
  local recognizer remains active and provides text fallback while connected.
  A fallback text turn is held until the actor has completed that audio-off
  transition, so it cannot overtake `audioStreamEnd` on the WebSocket.
- **Send sampled camera frames to Gemini** gates JPEG encoding and WebSocket
  forwarding. It does not turn off Cerebro perception or ROBController/Vision
  Pro video subscriptions, which are separate camera consumers.

The three choices are saved in `UserDefaults`. On the first launch with no saved
choice, the explicit launch configuration supplies the defaults. Credentials,
model, response modality, system instruction, and physical-action tool exposure
remain launch-time configuration and are never written to `UserDefaults`.

The active path is **Raw microphone audio** only after the Live-session actor
has applied the requested raw-audio policy and the session is ready. It changes
to **Local speech recognition -> text** while raw audio is disabled, still
waiting to be applied, or the session is reconnecting, matching the fallback
Cerebro actually uses. It changes to **Disabled** when the Gemini connection
switch is off. The requested microphone and camera rows show `true (waiting)`
until the actor acknowledges the transition, then `true (effective)`. Static
environment or credential changes still require a full Cerebro relaunch.

The panel also reports JPEG frames encoded, frames whose local WebSocket send
completed, the last-send time, and a redacted category summary of the last
server event. A sent count is not a per-frame receipt or semantic-vision
acknowledgement from Gemini. Counters reset when the `ROBAI` instance is
recreated. The diagnostics state never retains credentials, media, transcript
text, tool arguments, raw server JSON, or session-resumption handles.

The off switches guarantee that Cerebro stops admitting and sending the
corresponding inputs after the runtime transition. Provider-side usage and
billing can be delayed, so use the Gemini provider console for authoritative
token accounting.

## ROBController action bridge

The optional action bridge is implemented, but the `robot_action` tool remains
off by default. To expose it during supervised development, start Cerebro with
a Gemini credential and both enable flags:

```text
GEMINI_ROBOTICS_ENABLED=true
GEMINI_ROBOT_ACTION_TOOL_ENABLED=true
GEMINI_API_KEY=<development key>
```

`GEMINI_EPHEMERAL_TOKEN` may replace `GEMINI_API_KEY` and takes precedence when
both are present. Enabling the tool does not enable motors: a recently seen
ROBController must separately advertise `accepts_actions=true` and list the
requested action in its capabilities.

The roles are intentionally separated:

- Gemini proposes one allow-listed high-level action at a time.
- ROBController is the operator approval and action-status console.
- Cerebro remains the hardware coordinator and the only component that may
  connect an approved action to deterministic motion and safety code.
- A separate controller-authorized autonomy session lets Cerebro's local
  RPLidar coordinator roam and converse without per-tick approvals. It does not
  add inverse kinematics, arm trajectories, collision models, or grasp planning.

The v1 action validator accepts:

| Action | Required arguments and limits |
| --- | --- |
| `look_at` | Non-empty `target_id` |
| `play_gesture` | Non-empty `gesture` |
| `request_pick` | Non-empty `target_id` |
| `navigate_relative` | `distance_m` from -1 to 1, `yaw_rad` from -pi to pi, and `speed_scale` from 0 to 0.35 |
| `stop_motion` | No action arguments |

No action is translated directly into Maestro pulses, arm joint arrays, tread
speeds, servo positions, or Arduino heartbeat output.

### Wire format

The projects exchange `ROBRobotActionProtocol` v1 messages through the v2
QUIC/TLS control stream. For backward payload compatibility, the outer keyed
dictionary contains:

```text
message = ROBRobotActionProtocol.v1
sender = <sender ID>
robot_action = <versioned JSON data>
```

The inner JSON uses schema `com.orbitusrobotics.robot-action`, version `1`, and
includes a unique message ID, Gemini call ID where applicable, sender and
optional recipient IDs, timestamps, action arguments, status details, and
structured results. The codec rejects payloads over 64 KiB, unsupported
versions or actions, invalid action bounds, and mismatched inner/outer sender
IDs. The sender binding and recipient filter limit accidental cross-talk; the
pinned Cerebro certificate plus reciprocal challenge/proof supplies transport
and device authentication.

Message kinds are `controller_hello`, `action_request`, `action_status`, and
`action_cancel`. A controller hello advertises whether its operator is accepting
actions and which actions it supports. Cerebro currently considers that
announcement fresh for 3.5 seconds. Each request has a 30-second absolute
approval deadline and retains the Gemini call ID end to end. Once Cerebro sees
`accepted` or `executing`, it starts a separate 60-second execution deadline.
Repeated delivery of the same active Gemini call resends its existing request
rather than creating a second operation. While a call is open, Cerebro
retransmits the same immutable request or cancellation once per second so an
interrupted/reconnected session can recover without a new message ID or a second operation; ROBController
must replay its latest stored status for duplicate call IDs. Status and
cancellation messages are correlated to the controller recipient recorded on
the original request, so a newer controller announcement cannot adopt or
strand an older controller's in-flight call.

### Action lifecycle

The action states have these meanings:

- `pending`: Cerebro validated and sent the proposal; it is awaiting operator
  disposition.
- `accepted`: ROBController approved the proposal. Approval is not execution or
  physical completion.
- `executing`: the deterministic coordinator reports that execution is in
  progress. The current branch has no automatic coordinator that can produce
  this transition by itself.
- `completed`, `rejected`, `cancelled`, `failed`, and `expired`: terminal
  outcomes. Only a terminal status is returned to Gemini as the tool result.

When a terminal result reaches Gemini, the model can complete its turn. That
completed response follows the existing path through `ROBMainViewController`
and `[ROBSpeechBox sayIt:]`, so conversational replies and post-action replies
use the same SpeechBox voice.

Gemini cancellation produces an `action_cancel` with the same call ID. If the
action was accepted or executing, Cerebro keeps the blocking tool slot occupied
until ROBController reports a terminal cancellation; sending a cancel message
is not proof that motion stopped. An accepted or executing action that exceeds
its deadline follows the same stop-or-hold handshake before Cerebro reports it
as expired. A controller-originated `action_cancel` is likewise never treated
as a physical acknowledgement; Cerebro requires an explicit terminal
`action_status`. Cerebro uses that terminal handshake even when its last
observed state was only pending, or when approval arrives after its deadline,
because a lost or delayed acceptance packet must not let it assume that nothing
moved.

`stop_motion` is dispatched ahead of ordinary blocking tool work. Gemini stop,
local spoken stop, stage-show cancellation, autonomy stop, and shutdown converge
on a local software-stop path that stops speech/local coordinators, writes one
neutral/braked base frame, drops the heartbeat, and returns base authority to
`Brain`. The tool result reports Amber arm disposition as unverified because no
feedback-capable arm hold API exists. This is not a physical E-stop or an arm
stop acknowledgement.

### Safety boundary and transport

The bridge is coordination plumbing, not a replacement for hardware stops:

- The production control plane is paired TLS 1.3 over QUIC/UDP and advertises
  `_robctl._udp`. `_roboNet._tcp` plaintext UDP is disabled and confined to the
  explicit legacy adapter; there is no automatic downgrade.
- There is no servo or joint-position telemetry in `ROBRobotActionProtocol` v1.
- The bridge does not replace, emit, renew, or validate the Arduino tread
  heartbeat. The Arduino deadman remains an independent final tread interlock.
- `ROBSerialBox` expires remote snapshots after 600 ms, writes one
  neutral/braked frame, then stops USB writes so stale traffic cannot keep the
  Arduino deadman alive.
- `ROBAutonomyCoordinator` connects fresh RPLidar to bounded, low-speed tread
  roaming. There is still no kinematic executor for the rotating plate, arms,
  grippers, or general neck commands.

Before arm or grasp actions can move hardware, Cerebro still needs actuator
telemetry; calibrated transforms; joint, velocity, acceleration, collision, and
workspace limits; a cancellable IK/trajectory executor; and hardware-in-loop
proof. Operator emergency stop and the Arduino deadman remain authoritative
regardless of model or bridge state.

### Next motion-integration milestones

Do not submit a loose array of servo numbers to Gemini. Add a versioned robot
description and state stream with stable joint IDs such as
`base.left_tread`, `base.right_tread`, `base.yaw`,
`arm.left.joint.1` through `.7`, `arm.right.joint.1` through `.7`,
`neck.lower.pan`, `neck.lower.tilt`, `neck.upper.pan`, and
`neck.upper.tilt`. Confirm that inventory against the physical wiring before
making it a protocol contract.

Each state snapshot should carry a monotonic `state_sequence`, sample age,
position and velocity in SI units, calibrated/home/fault status, hard limits,
configured soft limits, and the kinematic-configuration revision. The camera
state also needs intrinsics plus timestamped transforms from camera to upper
neck, torso, and base. Gemini may receive a compact semantic snapshot, while
the full-rate state and transforms remain inside the local planner.

Build motion upward in independently testable layers:

1. Add fresh manual-command leases and make loss of controller traffic force a
   neutral/braked state without relying only on process liveness.
2. Add a local safety supervisor and actuator-specific stop/hold behavior for
   treads, rotating plate, both arms, and both neck stages.
3. Add read-only joint and camera-transform telemetry, calibration IDs, and a
   simulator/digital twin. Do not enable actuation from telemetry alone.
4. Convert the existing keyframe animation data into named, versioned gesture
   assets. Interpolate locally with velocity and acceleration limits; Gemini
   selects a gesture name rather than generating joint values.
5. Implement `look_at` with a bounded gaze controller, then low-speed relative
   navigation, before attempting arm motion.
6. For `request_pick`, bind `target_id` to a timestamped perception observation
   containing an image point, depth or 3D pose, confidence, and the transform
   revision used to project it. Run local inverse kinematics, collision and
   reachability checks, and an approach/grasp/retreat state machine. Report
   completion only from observed gripper/object feedback.
7. Add simulation, packet-loss/replay, cancellation-race, and hardware-in-loop
   fault tests before changing `GEMINI_ROBOT_ACTION_TOOL_ENABLED` from its
   default-off posture.

This keeps animation expressive while ensuring that the model chooses bounded
intent and the robot's local deterministic code owns every trajectory.

### Stage-show rehearsal

The main-window **Show…** panel loads the bundled Maker Faire sample or another
`.robshow.json` document. `ROBStageShow` v1 permits `speak`, `wait`,
`gemini_turn`, `play_gesture`, and `checkpoint` cues. Unknown fields are rejected
so show files cannot smuggle servo values, joint arrays, network endpoints, or
shell commands into the runtime.

**Dry Run** walks the validated plan without speech, Gemini, or hardware calls.
**Run Offline** uses authored speech and deterministic fallbacks. **Run Local**
asks a schema-constrained local stage director for a validated spoken line and
does not contact Gemini. **Run Adaptive** lets the local provider choose a
bounded stage beat and delivery enum, then sends a trusted Cerebro-built brief to Gemini through the existing
context-correlated text path, and lets Live add current camera/audio awareness.
Camera/audio context is available only when its independent Gemini runtime
switches are enabled; confirm encoded/sent frame counters in **Gemini…** before
the show. The cue deadline is shared between local planning and Gemini. If
Gemini fails after a local plan, Cerebro uses that local line; otherwise it uses
the authored fallback.

The implemented, contract-validated local provider is a loopback-only `llama.cpp` HTTP client using
`/v1/chat/completions`, `response_format` JSON schema, and `/health`. Missing,
loading, malformed, timed-out, and cancelled servers are recoverable. A future
MLX Swift implementation can register behind the same provider protocol; the
MLX selection currently reports unavailable because no pinned MLX package or
model runtime is linked in this target.

Every non-stop Gemini physical-action tool call originating from a stage context
is rejected, even after that cue or show has timed out or completed.
Named gesture requests also fail closed until an immutable calibrated gesture
catalog and feedback-capable executor are installed.

The full implementation sequence is documented in
[Gemini robotics, stage-show, and local action plan](gemini-robotics-stage-action-plan.md).
Local server setup and the exact provider contract are documented in
[local improvisation provider](local-improvisation-provider.md).

## Validation

Build the unsigned Debug application:

```bash
xcodebuild -quiet \
  -project Cerebro.xcodeproj \
  -scheme Cerebro \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/CerebroGeminiDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the standalone JSON protocol fixtures:

```bash
swiftc \
  Cerebro/GeminiRoboticsProtocol.swift \
  Tests/GeminiRoboticsProtocolFixtureTests.swift \
  -o /tmp/CerebroGeminiProtocolFixtureTests

/tmp/CerebroGeminiProtocolFixtureTests
```

The fixtures verify setup/model serialization, fail-closed media/tool flags,
runtime preference defaults and overrides, transcription enablement,
`realtimeInput.text`, audio, `audioStreamEnd`, and JPEG envelopes, independent input/output
transcription messages, generation-versus-turn completion, deadline state,
callback-before-interruption and interruption-before-callback barge-in ordering,
blocking tool calls, cancellations, session-resumption handles, `goAway`
handling, effective diagnostics modes and counters, and redaction of diagnostic
event summaries. They do not make a billable network request.

On 2026-08-01, a sanitized manual round trip compiled against the repository's
protocol implementation reached `setupComplete`, sent the test request through
`realtimeInput.text`, and parsed the configured ER2 preview's
`outputTranscription` response as `seven`. A second pass sent synthetic mono
PCM16 audio at 16 kHz through the same protocol helpers; Gemini's server-side
input transcription returned `Hey Rob, reply with exactly the word seven.` and
the model's output transcription returned `seven`.

Run the standalone `ROBRobotActionProtocol` v1 envelope fixtures:

```bash
swiftc \
  Cerebro/ROBRobotActionProtocol.swift \
  Cerebro/ROBAutonomyCoordinator.swift \
  Tests/ROBRobotActionProtocolFixtureTests.swift \
  -o /tmp/CerebroRobotActionProtocolFixtureTests

/tmp/CerebroRobotActionProtocolFixtureTests
```

These fixtures cover controller hello, request/status/cancellation round trips,
terminal-state classification, action bounds and expiry, malformed archives,
autonomy start/stop/session bounds, coordinator Lidar activation, and binding
the outer envelope sender to the versioned inner message. They do not start the
network listener or operate hardware.

Run the Foundation-only stage-show fixtures:

```bash
swiftc -module-cache-path /tmp/cerebro-swift-module-cache \
  -parse-as-library \
  Cerebro/ROBLocalImprovisationProtocol.swift \
  Cerebro/ROBLlamaCppImprovisationProvider.swift \
  Cerebro/ROBStageShowProtocol.swift \
  Cerebro/ROBStageShowCoordinator.swift \
  Tests/ROBStageShowFixtureTests.swift \
  -o /tmp/ROBStageShowFixtureTests

/tmp/ROBStageShowFixtureTests
```

They cover strict schema round trips, rejection of raw servo/SSH fields,
duplicate IDs and duration bounds, dry-run side-effect isolation, offline,
local-only, local-to-Gemini, and authored fallback routing, suppression of late
local completions, optional gesture failure, and idempotent cancellation. They
do not speak, contact a model server, contact Gemini, or operate hardware.

Run the local-provider protocol and llama.cpp envelope fixtures:

```bash
swiftc -module-cache-path /tmp/cerebro-swift-module-cache \
  -parse-as-library \
  Cerebro/ROBLocalImprovisationProtocol.swift \
  Cerebro/ROBLlamaCppImprovisationProvider.swift \
  Tests/ROBLocalImprovisationFixtureTests.swift \
  -o /tmp/ROBLocalImprovisationFixtureTests

/tmp/ROBLocalImprovisationFixtureTests
```

These fixtures cover the exact shallow JSON schema, strict post-generation
validation, loopback endpoint restrictions, llama.cpp request serialization,
OpenAI-compatible response extraction, health/loading states, malformed
responses, and response-size bounds without starting a server.

## Reusable AI interface next steps

1. Extract a provider-neutral conversation interface from `ROBAI` with typed
   text, audio, video, tool-call, connection, and usage events. Keep Gemini
   protocol serialization in one adapter rather than exposing it to the main
   view controller.
2. Inject a credential provider, WebSocket transport, clock, and retry sleeper.
   This enables ephemeral-token refresh and deterministic off/on/reconnect tests
   without a live, billable provider connection.
3. Add an Xcode test target around the session actor. Prove rapid-toggle
   last-write-wins behavior, no media egress after an acknowledged off
   transition, exactly one terminal result per accepted request, queue
   backpressure, and stale-generation rejection.
4. Pin each spoken utterance to one route at utterance start. The current
   ready-state decision at the final Apple transcript callback can still change
   during a reconnect, risking a partial raw-audio turn or a duplicate text
   fallback at that boundary.
5. Add redacted local usage counters for session duration, text requests, audio
   bytes/chunks, video bytes/frames, and dropped work. Treat provider usage
   metadata or the provider console—not local estimates—as authoritative for
   billing.
6. Move AI orchestration and robot-action cancellation out of the large main
   view controller into a dedicated coordinator with a small Objective-C bridge.

## Current limitations

- Live API availability and model access still require a valid Google project.
- Ephemeral-token refresh is not yet implemented in-process.
- The integration is half-duplex; user barge-in during synthesized speech is
  deferred until an echo-cancelled audio path is added.
- Live behavior has a manual sanitized round-trip check, but there is no
  checked-in credential or automated billable network test.
- Runtime transitions use a last-write-wins policy revision plus independent
  connection, audio, and video generations. The UI reports actor-applied state,
  but this acknowledgement is a local egress boundary rather than a provider
  billing receipt.
- The diagnostics counters cover video frames, not provider token usage.
- The raw-microphone response-start watchdog uses Apple's on-device transcript
  as its non-resending turn signal. If on-device recognition is unavailable for
  the selected locale, successful Gemini audio turns still work and server
  transcription is still logged, but a silent turn does not get that local
  15-second watchdog.
- The synthetic PCM round trip validates Gemini and the wire protocol, not the
  physical microphone or `AVAudioEngine` conversion on a particular Mac.
- Camera input is semantic context at one FPS. It is not a visual-servoing or
  collision-avoidance loop, and camera frames alone do not trigger a proactive
  model turn.
- Audio conversion and network queues are bounded; overload drops old media
  rather than allowing latency to grow without limit.
- The real-time microphone tap uses non-blocking state checks but still copies
  each accepted buffer before off-thread conversion. Replace that copy path
  with a preallocated ring if hardware profiling shows render-thread underruns.
- The robot-action tool remains default-off and must be explicitly enabled for
  supervised protocol testing.
- `ROBRobotActionProtocol` v1 coordinates operator approval, status, terminal
  results, deadlines, and cancellation, but no automatic action executor or
  kinematic/grasp planner is implemented. Controller-activated social roaming
  is a separate local RPLidar behavior.
- The action protocol has no servo telemetry and does not replace or control the
  Arduino heartbeat.
- V2 provisions a unique Keychain-backed credential for each device. Cerebro's
  registry assigns either `operatorController` or `lidarPublisher`, treats that
  server-side role as authoritative, and keeps persistent revocation
  tombstones. RPLidar credentials can publish only typed scan/map telemetry;
  they cannot send controller frames or receive controller broadcasts.

See [ROB control transport v2](rob-control-v2.md) and
[controller-activated autonomy](controller-activated-autonomy.md).
