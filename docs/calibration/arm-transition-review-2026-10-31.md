# Arm command handoff investigation — October 31, 2026

The strongest new explanation for the command-during-motion reversal is the
vendor controller's trajectory handoff. Its new trajectory is seeded from a
commanded position and independently estimated velocity/acceleration. A pure
math test using Amber's installed Ruckig library reproduces a large backward
excursion from a forward target when given a plausible missed-sample estimate.
The exact internal state was not recorded during the historical event, so this
is a reproduced failure mechanism and a strong diagnosis candidate, not proof
that every reported incident had this cause.

No arm/jaw movement test, mode transition, encoder reset, core restart,
firmware or model change was requested by this investigation. The concurrent
pouring/perception task owns live robot operations; Cerebro installation/restart
requires an explicit handoff. The
head-strike/model mismatch described in the [session handoff](session-handoff-2026-10-31.md)
is still unresolved and is distinct from the overlap reversal.

## Evidence from Amber

Both installed executables are vendor core V0.2.0 with identical SHA-256:
`554e7088b94b98f03f152f394c5e5b1d1ecfd16dacd470889e65dc83c36d2100`.
The live processes had CWDs `/home/amber/L-10` and `/home/amber/R-11`.
Their launch files and startup logs select these models:

| Physical arm | Vendor core / gateway label | Selected model | Tip |
| --- | --- | --- | --- |
| RIGHT | L-10 / `left` / CAN10 | `urdf/dual_b1/DualArmL.urdf` | `Lseven_Link` |
| LEFT | R-11 / `right` / CAN11 | `urdf/dual_b1/DualArmR.urdf` | `Rseven_Link` |

The file audit is not a dump of Drake's in-memory plant. Launch paths, CWDs,
startup logs and file hashes agree; no active core was attached to a debugger.
Both cores link `/opt/ros/humble/lib/x86_64-linux-gnu/libruckig.so`, installed
package `ros-humble-ruckig 0.9.2-1jammy.20231117.163632`. Each exposed 19 threads;
a process snapshot showed roughly 179–180% CPU each on a four-CPU machine.
That snapshot and untimestamped `DELAY` logs support investigating timing, but
do not quantify scheduling at the original incident.

The private raw reads/disassembly are under
`/private/tmp/rob-arm-transition-20261031/`. Sanitized configuration, hashes and
numerical results are in [the evidence record](evidence/2026-10-31-arm-transition/summary.json).

## What the installed command path actually does

Gateway `AmberUDPTransport._move_joints_blocking` sends UDP command 4 containing
seven positions and a duration. Its per-arm mutex covers the request/ACK, not
the physical trajectory. A successful ACK therefore permits a later command
while the previous movement is still executing. The gateway has no continuous
position/velocity/acceleration streaming interface.

Disassembly of the actual installed binary establishes:

| Location | Observed behavior |
| --- | --- |
| `UdpServer::setTwoPointPositionTaskLCM`, `0x80c4e` | Converts radians to degrees (factor at `0xa9e38`), publishes `simplePositionTask_t` directly. No Drake/URDF solver call on this path. |
| `RuckigController::Handler::handleMessage`, `0x880ba` | Writes shared target arrays, sets terminal velocity/acceleration to zero, stores requested minimum duration and timestamp, launches and detaches a new `std::thread` for every target. |
| `RuckigController::RuckigControl`, `0x86ba1` | Creates a fresh planner at 0.005 s. Reads current position from `directControl::jointPositionTarget`, velocity from `speedoMeter::target_approxSpeed`, and acceleration from `speedoMeter::target_approxAcceleration`. |
| `speedoMeter::spin`, `0x98ec7` | Separately samples shared commanded positions and finite-differences them for velocity, then acceleration, using its own elapsed microseconds. The samples and derivatives are separate writes; no coherent snapshot is taken by the new worker. |
| Worker `0x86f55` through `0x87024` | Checks whether its timestamp is older, then writes seven shared position targets and passes its output to its own next input. There is no join or lock around replacement and publication. |

The old worker can pass its cancellation check before the new command arrives,
then publish afterward. A new worker can also assemble position/velocity/
acceleration from different sampler moments. These are concrete concurrency
hazards in the inspected code. Each uninterrupted worker does use
`output.pass_to_input`; the discontinuity is introduced at worker replacement.

The launch limits are copied directly into the planner. In this path's degree
coordinates they are 5400 deg/s on J1–J4, 4200 deg/s on J5–J7, 90000 deg/s² and
5000 deg/s³. These are configured numbers, not verified physical ratings.
The requested duration is a **minimum duration**, not a bound on instantaneous
joint speed, acceleration, or excursions needed to satisfy the seed state.
The wrapper initializes no URDF position limits in the Ruckig input.

## Reproduction without motor access

[The executable fixture](../../Tests/ROBAmberTrajectoryHandoffSimulation.cpp)
contains only trajectory math and standard output; it has no socket, CAN,
robot API, mode or actuator calls. It was compiled in a private `/tmp` directory
on Amber against the installed 0.9.2 headers/library, then exited. The production
cores and gateway remained running and unchanged.

For J6, start `+0.34 rad`, target `+1.05 rad`, requested duration 2 s:

| Seed used by planner | Minimum planned J6 | Outcome |
| --- | --- | --- |
| Coherent `v=+0.20 rad/s`, `a=0` | `+0.340 rad` | Forward throughout |
| Hypothetical missed sampler update: `v=0`, `a=−40 rad/s²` | `−5.262596 rad` | Large backward swing before reaching the same positive target |
| Stationary `v=0`, `a=0` | `+0.340 rad` | Forward throughout |

The bad acceleration follows directly from `(0 − 0.20) / 0.005`. Independent
200 Hz timers can miss a producer update even when its underlying trajectory
is smooth. Ruckig correctly integrates the supplied acceleration while limiting
jerk; it is being told a dramatically different motion state. The simulated
excursion exceeds the physical/model bounds. A real motor may clamp, fault or
behave differently; this is not a claim of a measured −5.26 rad physical turn.
The historical reversal toward approximately −1.84 rad is **not** used as a
fitted parameter, and its exact cause remains uninstrumented.

This also explains why waiting until motion settles can mask the defect:
independently estimated derivatives approach zero. Settling is an interim
containment measure, not a requirement of smooth robotic animation.

## What needs to change in the models and constraints

The selected URDFs each contain eight links: a base and one arm's seven links.
They have no explicit ROB torso, head, other-arm, jaw, tabletop or floor links.
The base mesh bounds are about 0.095 × 0.2975 × 0.1309 m, so it should not be
described as a model of the whole room/table. A floor or table shown by another
viewer may be added outside these files. All seven URDF joints use ±2.09 rad,
`velocity=1000000`, `effort=100000`; these do not express credible commissioned
dynamic limits. Their collision meshes alone do not establish active collision
checking on the direct joint-command path.

Cerebro's full preview model has 45 links, including both arms, torso, tracks,
neck and cameras. It is a better starting structure but has placeholder zero
effort/velocity tags and a simulation-only reference. Its joint-specific limits
and the gateway's raw limits are wider than the vendor model (J7 ±3.05 rad
versus ±2.09). The observed 120-degree clamp is separate physical evidence.
Reference offsets, solver signs `[1,-1,1,-1,1,-1,1]`, negative URDF axes on
J2/J4/J6, and the reversed vendor/physical arm labels must all be accounted for.
Do not fix this by guessing signs, widening bounds, or copying a 45-link model
into a seven-DOF core.

Required model work is:

1. Validate shoulder mounts, encoder-to-model transforms, both jaw envelopes,
   measured tool offsets and head/neck/body pose using independent observations.
   The unmeasured 110 mm tool offset and earlier head strike remain open.
2. Maintain a complete robot collision model plus a separate current world
   scene (table, floor, cup, people and carried payload), with conservative
   collision meshes and measured camera registration.
3. Define one commissioned limit profile with explicit units and per-joint
   position, velocity, acceleration and jerk bounds. Transform positions and
   signs correctly at each interface; enforce limits on every generated sample,
   including braking and post-IK target amendments.
4. Keep compatible seven-DOF extracts for the vendor's per-arm solver if it
   remains in use. Validate FK against the full model and measured poses before
   any guarded deployment. URDF edits alone do not change the raw cmd-4 path.

The read-only audit script now exposes link/collision scope and launch dynamics
alongside URDF bounds so these separate constraint sources can be compared.
No model values were deployed during this investigation.

## Continuous animation and Vision Pro control

Use one persistent local trajectory owner on Amber. VR sends the **latest
desired tool pose**, never a backlog of complete moves. On each 200 Hz tick the
owner takes one coherent position/velocity/acceleration state, updates its
target, generates the next bounded state and publishes once. Preserve its
generated derivatives with `pass_to_input`; reconcile measured tracking error
through a bounded observer rather than independently redifferentiating commands
when packets arrive. Use a generation/sequence mailbox, not detached per-target
workers, and use a monotonic clock for expiry/cancellation.

The same math fixture includes this proposed persistent-owner loop with
20 Hz target updates and illustrative 0.30 rad/s, 0.60 rad/s² and 2.0 rad/s³
limits. It changed target **155 times while already moving**, respected all
three limits, bounded every 5 ms step to 0.0015 rad, and reached its final target
without a settle-before-update gate. This is an offline joint-space prototype,
not a deployed transport, full robot collision test or physical commissioning.

For headset operation, retain measured clutching, a held grip/dead-man,
latest-sample expiry, exclusive ownership and reconnect invalidation. Local
Cartesian IK should stay near the current solution, bound wrist/elbow branch
changes, use continuous quaternion orientation, slow near singularities/joint
limits and check both arms plus body/payload and the world scene. Losing the
controller stream should request a validated local deceleration/hold, not a
torque-mode reset. Normal online retargeting need not settle; final placement,
grasp and pouring can still require measured arrival or low velocity.

`ROBControllerVision` already sends latest tracked samples on a nominal 50 ms
loop. The separate `Cerebro-vision-teleop` branch converts those samples into
0.7 s trajectories and waits for the existing arm run before dispatching again.
The currently running `Cerebro-current` build does not contain that Cartesian
teleoperation implementation. Sending the headset's 20 Hz stream straight to
the existing cmd-4 gateway would multiply the suspect handoffs.

Before physical streaming, obtain/rebuild the vendor core with the persistent
owner fix and instrumentation, or commission a separate driver that preserves
the existing watchdog/hold/ownership protections. The original vendor wrapper
sources were not found on Amber; the inspected artifacts were binaries and
object files. Do not binary-patch an active core or bypass its guards through
an unvalidated direct-position command. Instrument time, command generation,
seed/output PVA, sample ages, tracking error and planner result first. Validate
bursts, stale/reordered targets, tracking loss, cancellation, braking envelopes,
limits and collisions offline, then use a bounded supervised empty-arm trial.

The design is consistent with the primary
[Ruckig online-state documentation](https://docs.ruckig.com/tutorial.html) and
[MoveIt Servo's continuous control checks](https://moveit.picknik.ai/main/doc/examples/realtime_servo/realtime_servo_tutorial.html).
Those references support the proposed architecture; the diagnosis above comes
from this robot's files, executable and isolated numerical experiment.

## Native speech delivery and coordinated app update

The requested local assistant speech route is implemented and installed:
[`speech.say` and `speech.status`](../local-control.md#assistant-status-speech).
It records assistant provenance, suppresses local recognition and Gemini audio
through the utterance and acoustic tail, and does not reopen the Gemini wake
window. Local voice Stop is suppressed in that interval too; UI/controller/
hardware Stop remain live. Ordinary ROB speech keeps its existing local Stop.

Validation passed 17 extracted-method assistant-speech runtime checks, 43 normal
Stop checks, the protocol/real Unix-socket/encoder suite and the signed native
Debug build. A final signing failure caused by low disk space was resolved by
removing only this task's generated compiler/index caches. The first build's
existing aggregate install step copied the app into Applications without
restarting PID 4121. Later verification builds explicitly disabled installation.

After the pouring task explicitly handed off runtime control and stayed in
software planning, fresh telemetry confirmed both arms inactive and no active
motion/mission. The final signed app was installed, normally quit and relaunched
with passive hardware startup preserved. New PID 10187 exposed the speech RPC;
the live smoke changed `queued` to `finished` with microphone suppression true
during output and false afterward. The UI recorded `Codex assistant status` and
showed no new microphone user turn in the follow-up check. A synthesizer finish
callback does not independently prove speaker audibility.

The final read reported unchanged arm positions, inactive modes and fresh
feedback. Amber core PIDs 990/991 were unchanged. Neck software pose became
unknown after reconnect; previous targets were not reissued. That limitation
and the replacement app identity were handed back to the pouring task, with no
further install/restart planned. Sanitized validation and installed binary
hashes are in [the speech validation record](evidence/2026-10-31-arm-transition/speech-validation.json).
