# Vision Pro → Mac Drake shadow IK

This development milestone moves **one virtual gripper**, ROB-left / R-11, using
tracked left-controller poses or small XYZ buttons. It cannot execute a robot
trajectory. The base, torso, neck, right arm and every other joint remain fixed at
the approved scan reference. The existing physical arm panel still performs
supervised joint jogging through its separate protocol.

## Operator flow

1. Build the updated Cerebro and ROBControllerVision apps. On the Mac, run
   `Scripts/setup-shadow-planner.sh` once to install the isolated Drake 1.57.0
   runtime in `~/Library/Application Support/Cerebro/ShadowPlanner/venv`.
2. Connect Vision Pro to the updated Cerebro using its existing paired control
   session. Leave drive control and both arm authorities disarmed. Open **Shadow
   IK** in the control deck toolbar, then **Load scan reference**.
3. Point the left Sense controller approximately level in the direction that
   should mean ROB-forward; choose **Align controller forward**. Up maps to ROB +Z
   and left to ROB +Y. This is a virtual control alignment, not physical camera / AR
   registration. Turning the headset does not redefine these axes.
4. Release, then hold the left grip. The current controller pose is clutched to the
   current ghost tool without a jump. Translation follows the controller and wrist
   orientation follows its relative rotation. Precision maps 10 cm of hand motion
   to 2 cm of target motion. Its scale is captured on each new clutch.
5. Release to hold the ghost and reposition your hand. XYZ buttons request 2 mm
   precision steps or 10 mm normal steps, with tool orientation held. They also
   allow Mac IK testing before a tracked controller is available.

The grey kinematic proxy is the **scan estimate**, cyan is the IK ghost, and orange
marks the requested target. Neither grey nor cyan is a live visual observation.
The display shows numerical target residual and Mac solve time. Those numbers
describe the model solve, not ROB's physical positioning accuracy.

## Implementation and isolation

`rob-shadow-ik/1` is a strict, independently versioned JSON protocol carried over
the existing authenticated `robctl/2` connection. Requests bind controller UUID,
control-session UUID, preview UUID, request UUID, monotonically increasing sequence
and issuance time. Non-start requests identify the exact derived URDF hash; an end
request may omit that hash so closing during startup can still terminate a worker.
Replies echo request identity and include model/reference hashes and named FK
frames. The schema permanently requires `hardwareOutputEnabled=false`,
`referenceSource=approved_scan_estimate` and `collisionStatus=not_checked`.

`AutoNetServer` consumes claimed shadow messages before the historical motion
parser, including malformed and future versions. Only authenticated operator
sessions can reach `ROBShadowPlannerBridge`; replies go only to that same session.
The bridge launches the bundled Python worker over stdin/stdout, without a listening
port. Neither the bridge nor worker imports an Amber driver or holds an actuator
interface. Session loss terminates the process. There is one in-flight request and
at most one replacement; release/end supersede pending previews.

Opening the Vision preview consumes controller inputs before the tread, neck,
gripper or joint-jog input paths. The sheet is available only while live drive and
arm controls are disarmed. The ordinary physical-control infrastructure remains
separate; preview mode does not claim that physical motors are powered off.

ARKit anchor timestamps determine observation age; repeated button polls do not
refresh it. Low-accuracy tracking is retained as low accuracy and cannot drive IK.
The worker checks pose age plus conservative network age (150 ms), tracking origin,
sample sequence, discontinuities and input gaps. A stale controller heartbeat is
not treated as a released grip. Recovery requires an actual release and re-clutch;
origin changes require forward alignment again. Wrist/position jumps invalidate
alignment. Late or superseded replies cannot resurrect a released gesture.

## Model and solver boundaries

`Scripts/prepare-shadow-model.py /path/to/ROB-Approved-Geometry-2026-09-19` derives
the bundled mesh-free URDF and reference manifest. It preserves all source joint
origins, axes and limits and records both original hashes. It removes visual,
collision and inertial data solely for the kinematic worker; the approved handoff
is unchanged. SHA-256 validation occurs before loading the worker model.

Only the seven left-arm coordinates are optimization variables with motion freedom.
All other coordinates are locked. Active-arm bounds intersect the URDF bounds with
the provisional centered ±120° range and ±0.15 radian continuity around the previous
solution. Position tolerance is 0.5 mm per axis; orientation tolerance is 0.015 rad.
An independent post-solve check rejects invalid results, fixed-joint drift and
deadline overruns. An infeasible target leaves the last ghost pose unchanged. A
downward 5 mm request from the almost fully hanging pose is intentionally blocked
by the provisional travel envelope.

The right J2 scan reference remains +120.417°, outside the provisional +120° range.
It stays fixed and is never silently clamped or enabled. Cable-safe travel, TCP
measurements, visual state estimation, collision/path clearance and hardware model
to motor mapping are **not commissioned**. No shadow result is a safe-to-execute
certificate. This milestone does not implement gesture recording or live playback.

## Verification and next device test

```sh
Scripts/test-shadow-planner.sh
```

This runs actual Drake FK/IK and process-boundary fixtures: clutch alignment,
relative wrist/translation mapping, XYZ targets, fixed joints, range rejection,
stale/uncertain/replayed tracking, origin changes, session/model binding, failed
workers and explicit no-execution response invariants. The Vision repository adds
package tests and `Scripts/test-shadow-preview-model.sh` for the input latch,
late replies, startup cancellation and timeout recovery.

The first headset test should compare forward/left/up and small wrist rotations
against the displayed ghost, test release/re-clutch and tracking loss, and inspect
reachable versus blocked targets. It requires no arm authority. Next, add a
registered, timestamped visual joint-state estimator and clearance validation before
considering physical execution through the existing leased gateway.

These are development builds. No installed live Cerebro process, Amber boot model,
motor mode or public/store distribution is replaced by the setup/test scripts.
