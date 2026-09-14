# September 25: IK, chess, loiter and performance

Reviewed September 13, 2026. Calibration is in progress. This is the current
implementation assessment; older roadmap documents describe earlier versions.

## Model choice

Keep `gemini-robotics-er-2-streaming-preview` as the demo's live observer and
high-level planner. Google now documents continuous audio/video input, text
output, and low-latency function calls on the Live API. It is an embodied
reasoning model, not a trained motor policy for this particular ROB.
[Google's robotics streaming guide](https://ai.google.dev/gemini-api/docs/robotics-streaming).

GPT-6 Astra supports image input, reasoning, and function calls. It can inspect
selected board images, review plans, and propose the same high-level actions.
It does not natively accept audio/video according to its modality listing.
[Astra model documentation](https://developers.openai.com/api/docs/models/gpt-6-astra).
For an OpenAI live interaction alternative, use the documented Realtime family
with audio and sampled image items. `gpt-realtime-2.1` is the current example in
the Realtime guide. A persistent session can provide a similar conversational
experience, but this is not a latency or grasp-accuracy equivalence claim.
[Realtime guide](https://developers.openai.com/api/docs/guides/realtime),
[model modalities](https://developers.openai.com/api/docs/models/gpt-realtime-2.1).

Cerebro currently implements Gemini's Live socket. `ROBRealtimeProvider` and
Keychain entries for OpenAI are scaffolding, not an OpenAI session adapter.
There is no measured on-robot Gemini-versus-OpenAI comparison yet. Keep one
motion executive and select one active proposer; do not race two providers to
the hardware or replay a failed cloud action on another provider automatically.

Apple Foundation Models already interprets text plus local scene summaries and
backs up conversation. Show mode now offers it explicitly as a local stage
director, using guided generation, semantic validation, timeout, and authored
fallback. This adapter receives script context, not a raw video feed.
[Apple guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation).
MLX Swift remains the local LLM/VLM option: the checked-in defaults are
Llama-3.2-1B-Instruct-4bit and Qwen2-VL-2B-Instruct-4bit. Its camera observations
are sampled at low frequency; neither local model belongs in the servo loop.

## What actually boots

The preserved `/etc/rc.local` starts each executable from its own directory:

| Process directory | Solver selected in launch.json | URDF relative to that directory | Chain |
| --- | --- | --- | --- |
| `/home/amber/L-10` | `Drake` | `urdf/dual_b1/DualArmL.urdf` | `base_link` → `Lseven_Link` |
| `/home/amber/R-11` | `Drake` | `urdf/dual_b1/DualArmR.urdf` | `base_link` → `Rseven_Link` |

These are per-arm extracts of the dual model. The combined `DualArm.urdf` and
the `amber_core/launch.json` single-arm model are not selected by that saved
boot sequence. Live verification was attempted, but `amber-master.local` did
not resolve even outside the sandbox. The saved host configuration was last
reconciled in August, so verify the running host before deployment.

Reproduce the read-only file audit:

```sh
python3 Scripts/audit-amber-kinematics.py --amber-root ../Amber-HomeFolder/amber
```

[Saved model audit](calibration/amber-boot-model-audit-2026-09-13.json) records
the launch/model hashes, ordered chains, transforms and directions. In these
copies:

- Dual L's first joint is at approximately `(0, -0.13364, 0.061738)` with
  roll `+1.138`; dual R uses positive Y and roll about `-1.138`.
- The single B1 chain starts at `(0, 0, 0.0825)` with no first-joint rotation.
- The dual chains use negative local Z axes on J2/J4/J6. The single B1 uses
  positive local Z on all seven joints. The right-dual chain also changes
  intervening translations and origin rotations.
- Both launch files set solver directions to `[1,-1,1,-1,1,-1,1]` while the
  robot driver direction array is all positive. Trace conversions end to end;
  do not negate J2/J4/J6 again merely because another layer also mentions them.
- The dual files use ±2.09 rad for every joint and placeholder-like dynamics
  limits (velocity 1,000,000). These are not commissioned motion limits.

This establishes a representation mismatch, not proof of the sole cause of
every Drake failure. A solver using the wrong root, tip, sign, initial pose,
orientation constraint, or tool offset can fail or solve the wrong task.
Replacing the cloud model cannot fix those inputs. URDF joint origins are in
the parent frame; axes are in the joint frame, independent of visual meshes.
[URDF frame definition](https://docs.ros.org/en/rolling/p/urdfdom_headers/generated/classurdf_1_1Joint.html).

## New URDF pose IK workbench

Open **Robot Geometry Lab → Open URDF Pose IK…**. Alternatively build the
isolated workbench with `bash Scripts/build-robot-geometry-lab.sh`. It links no
serial, Amber, camera, or network-control runtime.

1. Load the exact URDF. Its bytes and SHA-256 are retained until reloaded.
2. Enter the exact base and tip names. The chain is derived from parent/child
   links, not XML order or an assumption that L means ROB-left.
3. Enter seed positions in the displayed chain order, in URDF/model radians
   (meters for prismatic joints). **Inspect FK / Use as Target** computes the
   current tool pose. Invalid/missing/out-of-range seeds are rejected.
4. Supply the measured tip-to-tool-center transform. Zero targets the selected
   link origin and does not establish where the fingertips contact a piece.
5. Edit the target in the selected base frame and choose **Solve IK**. The
   default checks position and orientation. Position-only is an explicit option.
6. Inspect residuals, joint order, source hash and convergence. Copy the JSON
   for calibration comparison. Solver failure preserves a diagnostic candidate;
   it is never an executable success and is not proof of global unreachability.

`ROBSerialChain` implements FK and bounded damped least squares with an analytic
spatial Jacobian, fixed links/TCP offsets, arbitrary signed joint axes, limits,
backtracking, a seed-displacement bound, and time/iteration budgets. Orientation
error uses a shortest quaternion rotation, including half-turns. It can load the
rebuilt URDF without transcribing another set of constants into Swift.

This workbench computes solutions only. It does not replace Amber's deployed
URDF or the existing single-B1 runtime reference gate. It does not perform
collision checking or certify a trajectory. Hardware integration waits for the
commissioned model and independently observed FK checks.

## Calibration and execution contract

Keep three independent transforms explicit:

```text
robot_from_tool = robot_from_arm_base * arm_FK(q_model) * tip_from_tool
arm_base_from_goal = inverse(robot_from_arm_base) * robot_from_goal
q_model = direction * (q_vendor - vendor_at_model_zero)
```

The existing per-boot reference store supplies the last mapping only after its
measured park/reference checks pass. A gravity-hanging boot pose is not URDF
zero. Mount origins, motor-zero offsets and preview slider angles must not be
substituted for one another.

For Vision Pro, the current transport is joint jogging, not Cartesian controller
pose IK. The new `ROBKinematicFrames` helpers provide explicit target-frame
conversion and a clutch alignment whose first target equals the measured robot
tool pose. Follow-up integration must carry target frame, model hash, fresh
measured seed, sequence, deadline, operator lease and dead-man state; then solve
on Cerebro and pass validated joint proposals through the existing gateway.
AR-world pose values cannot be treated directly as ROB X-forward/Y-left/Z-up.

For recorded imitation/Kung Fu, record timestamped measured joints plus source
poses and model/reference identities. Retarget human/controller trajectories to
ROB's workspace; do not copy human joint angles. Validate the complete sequence,
speed/acceleration, collisions and stop/hold behavior before playback. This is
later work, not currently an enabled full-body imitation mode.

## Chess path and September 25 fallback

The operator confirms that manual joint values can grasp and move chess pieces.
That establishes mechanical capability. The located
`~/Documents/ROB KeyframeAnimations/StarWars Droid Battle.keyAnim` has no saved
named keyframes or sequences and only a zero/default current keyframe. No usable
pickup was recovered from that file or the searched application containers.
Photos document behavior but do not recover a unique set of encoder angles.

Use a fixed board and supported, stationary base for the first calibrated demo:
board localization → square/piece pose → approach and grasp frames → seeded IK
→ collision/trajectory validation → leased joint motion → gripper feedback
→ retreat → visual/force verification. The AI should request a stable piece or
square ID; Cerebro owns numeric targets. Keep the base stationary during grasping.
`request_pick` remains unavailable until this executor is commissioned.

Work order before the fair:

1. Freeze frame names, units, arm-side mapping, mount and fingertip geometry.
   Compare FK to several independently measured configurations on both arms.
2. Rehearse one approach/grasp/retreat at a fixed table, then neighboring squares.
   Use conservative continuity and collision bounds; record measured outcomes.
3. Rehearse Show mode and loiter independently, then transitions and stop behavior.
4. Freeze the software/model versions before the event. Measure latency and
   failures on the actual event network. Keep authored offline comedy and local
   loiter available if chess or cloud inference is not reliable.

## Loiter and Show changes

Gemini now has `loiter_control`: `status`, `pause`, `resume`, `turn_left`, and
`turn_right`. It can shape only an existing ROBController-authorized
`social_roam` session. Mutating calls require its exact session ID. Turns expire
after 1.5 seconds; pause persists until explicit resume or session termination.
Calls are idempotent and bounded to 512 distinct accepted mutations per session.
Cancellation of the current AI intent pauses the base; a late cancelled call
cannot restart it or replace a newer accepted intent. Pause bypasses ordinary
queued tools. The tool follows `GEMINI_ROBOT_ACTION_TOOL_ENABLED` (enabled by
default); verify "Robot action tool exposed" in Gemini Diagnostics and start
the social-roam session from ROBController before trying it.
No tool can start autonomy or raise its zone/speed limits. Accepted intent is
reported separately from measured physical completion.

The 5 Hz local planner vetoes missing/stale scans and insufficient front/side/rear
coverage. Obstacle avoidance precedes zone return; at the zone limit it stops.
These are conservative range gates, not a full swept-volume collision planner.
Test tread signs, scanner coverage, braking distance and the footprint on the
actual robot before public loiter. Stage-originated loiter calls are rejected.

All seven existing show scripts remain available. Choose **Run Offline** for
authored dialogue; **Run Local** with Apple Foundation Models, MLX or llama.cpp;
or **Run Adaptive** for Gemini with a local/authored fallback. The model never
invents hardware commands from a skit. The comedy scripts currently contain
dialogue cues; add named `play_gesture` cues at rehearsed beats to animate them.

**Use approved arm cues** authorizes exact, immutable pose revisions named by
the loaded script for one run. Teach/approve them in Amber Diagnostics first.
The measured Amber executor now handles these normal show cues as well as the
separate startup workflow. Editing/re-approving a pose invalidates the old grant.
Optional motion that times out stops the show instead of advancing while motion
might remain active. Old asynchronous gesture completions cannot advance a new
run. Manual takeover and an operator autonomy start cancel an active show.

| Mechanism | Current software boundary |
| --- | --- |
| Both Amber arms | Approved measured poses; generic URDF IK calculation is now available separately |
| Treads | Local bounded social roam; no authored full-body stage choreography yet |
| Neck | Existing local/manual attention and safety policy; stage pose executor still needed |
| Torso/turntable | Existing manual control; calibrated stage limits/feedback mapping needed |
| Flippers | Existing manual direction/brake controls; stage travel/stop calibration needed |
| LACT lean | Existing direction control; linkage/pin measurements and travel feedback needed |
| Grippers/chess | Mechanical capability reported; verified calibrated grasp executor pending |

Legacy keyframe fields exist for these body parts, but field storage is not an
implemented, measured whole-body playback engine. Full-body comedy and Kung Fu
are not enabled by this change.

## Validation

`bash Scripts/test-arm-kinematics.sh` tests 90 six-dimensional targets across
three URDF representations, analytic FK, signed axes, fixed TCP, prismatic
motion, invalid inputs, seed bounds, half-turn error and Vision clutch alignment.
These validate software against models, not physical calibration accuracy.

`bash Scripts/test-demo-controls.sh` covers show run grants, changed revisions,
timeouts/stale callbacks, local guided-output validation/cancellation, and loiter
authorization, replay, zone/obstacle precedence, missing sectors and stale scans.
The fixtures use no robot hardware or cloud services.

The macOS Debug build and the isolated Geometry Lab build passed. The existing
61-check Geometry Lab suite and all seven show documents also passed validation.
The isolated UI was exercised with the exact saved `DualArmL.urdf`: import,
hash display, FK, and a nearby full-pose IK solve completed. This was a software
check; no robot movement, live cloud-model comparison, or grasp trial was run.
