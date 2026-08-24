# ROB wake-up calibration

ROB's characterful wake-up is an operator-started, supervised workflow. It is
not an application-launch hook and it never runs merely because the Mac,
Cerebro, or the Amber controller rebooted. A startup animation may eventually
narrate and sequence local, named calibration adapters, but it must not turn a
model response into raw actuator values.

Open **Development → ROB Wake-Up Calibration (Dry Run)…** to inspect the
current ordered plan. The window reads existing in-process snapshots, records
local checklist acknowledgements, and sends zero actuator commands. It is the
place to develop the WALL-E-like timing and personality while each physical
adapter is being made independently verifiable.

The same workflow is now available from the **Show Mode** window. Its
**Wake-Up Calibration & Live Startup** card shows the current preflight result,
opens the full ordered checklist, selects a locally approved two-arm wake
gesture, and exposes the separate **Run LIVE Startup Test…** action.

## Supported live startup test

The live action is deliberately narrower than the full checklist. It exercises
everything Cerebro can currently prove through a bounded adapter:

1. Review the first five Wake-Up Calibration steps: physical operator/E-stop
   safety, authenticated exclusive Amber session, fresh left/right B1
   telemetry, and fresh deterministic OAK-D/QR visual registration.
2. Verify both arms are already in position mode. The live workflow never
   activates an arm or changes its control mode.
3. In Amber Diagnostics, approve one immutable keyframe containing both arms as
   the wake gesture. Its targets and durations are copied into the local
   approved catalog.
4. Select that gesture in Show Mode. Cerebro preflights gateway state, current
   modes, telemetry freshness, the 0.35-radian per-joint step limit, and the
   0.25-radian/second average-speed limit without moving anything.
5. Choose **Run LIVE Startup Test…**, read the critical warning, and choose the
   physical-run button. No keyboard entry is required. Cerebro repeats
   preflight after the modal confirmation.
6. ROB speaks the live-test announcement and pauses at a final checkpoint.
   Keep the physical E-stop in hand, clear the exclusion zone, and choose
   **Continue**.
7. The fixed sequence submits only the selected immutable two-arm gesture using
   gateway leases. Completion requires three distinct fresh telemetry samples
   inside position and velocity tolerances. Only then does ROB speak the passed
   message.

For a droid with no attached monitor, use **Arm Remote Start (one-shot)…**
while the same two-arm preflight is ready. This stores only the approved
gesture name; it is not motion authority. When Cerebro sees a fresh
authenticated ROBController or ROBControllerVision session advertising
`run_startup_test`, it sends one immutable request with a 30-second approval
deadline and consumes the persisted latch. On the controller, explicitly
enable action proposals and tap **Approve** with the exclusion zone clear and
the physical E-stop ready. That fresh tap replaces the local GUI checkpoint;
ROB gives an audible warning and runs the same leased, measured two-arm motion.
No droid keyboard or display is needed.

Reject, deadline expiry, loss of the approving controller, **Cancel and Hold**
on the controller, or **STOP + HOLD** in Show Mode prevents or cancels the run
and requests the existing measured-position hold. The request call ID is
one-shot and replay-safe: retransmission reports existing state and cannot
start a second sequence. A rejected or expired request is not automatically
re-armed.

**STOP + HOLD** cancels the sequence, cancels an active Amber gesture, requests
the priority measured-position hold for verified position-mode arms, and uses
the existing Stage Show stop path for speech, autonomy, and base motion. The
physical E-stop remains the emergency control.

This is not a generic “live” mode for loaded `.robshow.json` documents. Only the
fixed locally constructed startup sequence receives the one-shot local operator
context needed to invoke an approved Amber wake gesture. Normal show files
cannot acquire it.

## What works now

### Amber grippers

Each gripper has an independent, session-local lifecycle:

1. Connect Cerebro to the authenticated, exclusive Amber gateway.
2. Open **Development → Amber Arm Diagnostics…**.
3. Clear hands and objects from one gripper, keep the physical E-stop
   available, and choose **Calibrate…** for that arm.
4. Treat the accepted result as **command accepted — unverified**, not as
   measured completion. Repeat for the other arm.
5. In Vision Pro, select a conservative intensity from 2 through 20 vendor
   units. Hold both controller grip buttons, then press or release the matching
   index trigger to request `hold` or `release` for that gripper.

Calibration intentionally remains local to Cerebro because it can move the
full jaw travel and Amber exposes no calibration-complete feedback. Vision can
operate a gripper only after Cerebro reports that the calibration command was
accepted in the current gateway session. Reconnect, heartbeat expiry, gateway
restart, or power cycling invalidates that acceptance and requires deliberate
recalibration.

The value called `force` by the Amber API is an opaque vendor intensity, not
newtons. The gateway accepts the documented raw range 1 through 300; the
diagnostics and Vision interfaces deliberately expose only the smaller 2
through 20 range used by the vendor dashboard. Amber currently reports no jaw
opening, applied force, endpoint, object detection, physical completion, or
gripper stop/cancel primitive. `release` is movement and is never presented as
a stop.

### B1 arms and visual registration

Cerebro can verify fresh seven-joint Amber feedback, actuator modes, bounded
joint targets, gateway leases, and measured settling. Its approved named
gesture executor is the only current motion adapter that has all of those
properties. It now also has a fail-closed physical reference gate between
Amber's boot-relative encoder values and Cerebro's B1 URDF angles. The wake-up
window checks both B1 telemetry streams and the deterministic OAK-D/QR
visual-registration snapshot. Camera-frame, camera-pose, and arm-pose producer
ages must each be no more than 500 ms. Reference commissioning and capture are
read-only; the window does not invent or execute a resting pose.

The repository photo of the current robot shows the B1 arms hanging almost
vertically beside the torso. Before telemetry arrives, Amber Diagnostics draws
a muted, dashed **reference silhouette** in that orientation. It is explicitly
labeled as a photo-derived visual reference and is never used as feedback or an
actuator target. There is no checked-in measured seven-angle resting pose, and
the vendor all-zero command pose is not evidence of ROB's physical rest pose.

Before creating a real wake pose, use **Commission Park Geometry…** in Wake-Up
Calibration to record independently surveyed park angles and verified joint
direction signs for each arm. Then seat and support one arm in that physical
fixture and use **Establish Session Reference…**. Cerebro requires a fresh
authenticated session, a stopped seven-joint sample, uniform verified modes,
aligned OAK-D/QR geometry, and at least three camera-observed joint angles
within the commissioned error bound. The derived encoder offset is memory-only
and expires on reconnect or relaunch.

Once both reference gates are ready, use **Capture Left Measured → Keyframe**
and **Capture Right Measured → Keyframe** in Amber Diagnostics. Those captures
are now stored as physical model angles; legacy boot-relative approved gestures
are isolated under the old catalog version and cannot be executed as referenced
poses. Validate the calibrated mount transform and tool endpoint, and approve
the result as an immutable named gesture. Gemini may
select that local name and narrate the motion; it may not supply joint arrays
or decide that visual registration succeeded.

## Current calibration boundaries

| Mechanism | Current observation | Bounded stop and measured outcome | Wake-up behavior today |
| --- | --- | --- | --- |
| Amber B1 left/right | Seven positions, velocities, currents, statuses, modes, session generation, and deterministic visual pose | Available through the referenced, leased named Amber gesture executor | The Show Mode live startup test remains blocked until both per-arm session references pass. A local run uses click-only critical confirmation plus a GUI checkpoint; a monitorless run uses one fresh authenticated controller approval. Both repeat preflight. |
| Amber grippers | Vendor-core dispatch acknowledgement | No jaw, force, completion, or stop feedback | Calibrate one at a time in Amber Diagnostics; Vision control is then allowed for that gateway session |
| Tread L/R and brake | Legacy open-loop serial/PWM state | Not available | Listed and execution-disabled |
| Flipper arm and brake | Legacy open-loop command; feedback path is incomplete | Not available | Listed and execution-disabled |
| Base lean LACT | Legacy direction/speed command without proven position/limits | Not available | Listed and execution-disabled |
| Torso rotation | Controller position/step command | No approved homing, bounded cancellation, and measured settle adapter | Listed and execution-disabled |
| Maestro head/neck | Servo targets only | No physical encoder/completion contract | Listed and execution-disabled |
| Legacy Maestro arm bank | Superseded by Amber B1 | No authenticated measured adapter | Excluded |

An actuator becomes eligible for the physical wake-up sequence only after its
adapter defines and tests all of the following:

- stable mechanism identity, units, sign, zero/home, hard range, and normal
  animation range;
- fresh measured state and a distinction between commanded and observed state;
- bounded speed, acceleration, travel, duration, and one-command-at-a-time
  ownership;
- a real cancellation/hold/stop behavior that does not depend on the model or
  Vision connection remaining alive;
- a timeout and an evidence-backed terminal result;
- startup, disconnect, stale-feedback, and E-stop behavior; and
- operator confirmation, audit events, and an offline fake test.

## Amber B1 reference implementation and remaining startup design

The arm commissioning procedure and the normal power-on procedure are two
different workflows. Discovering direction, zero, and range is a supervised
commissioning operation performed after mechanical work or a calibration
invalidation. A normal power-on must only restore a previously approved
calibration and run small proof motions. It must never rediscover a hard stop or
sweep the full arm.

The software reference gate is implemented and the existing Show Mode live
startup action now remains motion-disabled until both arms are commissioned and
referenced for the current authenticated controller session. Gateway leases,
fresh telemetry, and measured settling alone are not sufficient. Immediately
before dispatch, model targets are translated into the current vendor frame;
measured completion is translated back into the model frame. The executor
continues checking deterministic camera/model agreement and requests the
existing priority hold if the gate closes during motion.

This does not claim that missing hardware has been installed. Today the local
operator's typed fixture confirmation is the primary park-datum assertion, and
the existing camera fit observes at least three joints but cannot observe the
final wrist rotation. Commissioned joint directions must therefore come from an
independent survey and supervised micro-proof, not from one stationary capture.
Cradle/index switches, orientation-observable wrist markers, signed operating
ranges, collision checking, and the one-degree joint-proof runner below remain
required before treating the broader startup sequence as fully commissioned.

### Implemented reference-gate workflow

1. Open **Wake-Up Calibration** and select one arm.
2. Choose **Commission Park Geometry…**. Enter seven surveyed physical URDF
   park angles, seven verified `+1`/`-1` encoder signs, a camera disagreement
   limit, and the typed commissioning phrase. Editing this record invalidates
   the current session reference.
3. Seat and support the selected arm in its commissioned physical park fixture,
   clear the workspace, keep the E-stop reachable, then choose **Establish
   Session Reference…** and type the arm-specific reference phrase.
4. Cerebro accepts the reference only with a ready/exclusive authenticated
   gateway generation, telemetry no older than 250 ms, all seven joints moving
   no faster than 0.05 rad/s, seven uniformly inactive or position modes, fresh
   aligned RGB-D/QR geometry, and at least three deterministic joint angles
   inside the commissioned visual error.
5. Repeat for the other arm. A reconnect or process restart changes/loses the
   generation-bound memory-only reference and closes the live-startup gate.
6. Capture and reapprove the intended gesture after referencing. The executor
   admits only model-frame targets inside the checked-in B1 outer limits and
   still enforces its 0.35-radian step, 0.25-rad/s average speed, gateway lease,
   verified position modes, fresh telemetry, measured settle, and camera veto.

Amber's published B1 instructions require the arm to be at its zero or safe
posture before power-on. ROB cannot currently satisfy that assumption: without
actuator power the arms fall beside the torso, and the resulting hanging pose is
not the URDF all-zero pose. Sending an all-zero target after boot is therefore
specifically prohibited. Vendor UDP command 7 accepts a joint ID for
calibration, but the available documentation does not establish whether an arm
joint moves, adopts its current encoder position, searches for a datum, or how
the operation can be stopped. Do not expose command 7 for joints 1 through 7
until those semantics and stop behavior are confirmed by the manufacturer or
on an isolated supported fixture.

### Make power-off mechanically repeatable

Software cannot safely recover an unknown pose from an encoder value that was
reset to zero at power-on. ROB needs a passive, gravity-safe arm park on each
side of the torso:

- a padded cradle supports the forearm/gripper and positively locates enough of
  the chain to make the parked pose repeatable;
- independent presence switches identify that the elbow and tool are seated;
- the arm cannot fall into a person, wheel, cable, or the other arm when drive
  power is removed; and
- an operator can support and remove an arm from the cradle without entering a
  pinch point.

A counterbalance or normally-engaged joint brake is preferable if it can be
retrofitted and validated. Until one of these passive protections exists, the
physical startup remains a fixture-only engineering operation. An E-stop that
removes torque but lets the arm collapse is necessary electrical protection,
not a complete safe-state design.

The cradle pose is named `power_off_park`; it is not renamed to Amber zero. Its
seven physical URDF angles are measured and stored independently for the left
and right arm. Normal shutdown moves each referenced arm into its cradle,
confirms the switches and measured pose, and only then permits deactivation.

### Keep vendor and physical coordinates separate

Every value must carry a coordinate frame. For joint `j`, use:

```text
q_model[j] = direction[j] * (q_vendor[j] - vendor_at_model_zero[j])
q_vendor[j] = vendor_at_model_zero[j] + direction[j] * q_model[j]
```

`q_model` is the physical URDF angle used by kinematics, collision checking,
and calibrated limits. `q_vendor` is the current Amber core reading/target.
`direction` is either -1 or +1. `vendor_at_model_zero` is recomputed for each
boot if Amber resets its encoder frame; it is persistent only after testing
proves that the actuator reports a stable absolute position across power cycles.

When the arm is confirmed in the cradle, the startup adapter can derive the
session offset without pretending that the cradle is zero:

```text
vendor_at_model_zero[j] = q_vendor_start[j]
                          - direction[j] * power_off_park[j]
```

This mapping is accepted only when cradle switches, an operator checkpoint,
fresh telemetry, and independent visual pose agree. A disagreement leaves the
arm `UNREFERENCED`; it is not averaged away. The mapping belongs in the gateway
below all motion callers so raw joint UI, named gestures, Cartesian IK, and
manual tools cannot bypass it.

### Every-boot state machine

Only one arm is processed at a time. The other arm remains deactivated and
seated. Every transition has a monotonic deadline, an audit event, and a route
to a latched fault.

1. **`LOCKED_OUT`** — Disable model, Vision, stage-show, and raw UDP motion
   authority. Confirm the base is stationary, the exclusion zone is clear, the
   E-stop operator is ready, both arms are supported, and both cradle switch
   sets have the expected state.
2. **`OBSERVE_ONLY`** — Establish the authenticated exclusive gateway session.
   Collect several increasing telemetry samples for all seven positions,
   velocities, currents, statuses, and modes. Require finite values, sample age
   no greater than 250 ms, near-zero measured motion, and no actuator status
   fault. Record the boot/controller generation. Do not send a target.
3. **`POSE_CONSISTENCY`** — Use the cradle switches and deterministic
   OAK-D/fiducial estimate to compare the physical pose directly with the saved
   cradle pose. Check the measured raw vector for finiteness, stability, and
   plausible wrap continuity without assuming a saved session offset. Seven
   vendor zeros while vision observes a nonzero model pose is classified as an
   expected unreferenced boot, not as Amber zero.
4. **`CAPTURE_AND_HOLD`** — If all joints already report Position mode, capture
   a new raw sample and command exactly that raw pose before any other target.
   If a mode transition is required, the operator physically supports the arm
   while the existing Active -> fresh pose capture -> Position -> captured-pose
   hold transaction runs. The arm may not proceed unless all seven modes and
   the measured hold are confirmed.
5. **`SESSION_REFERENCE`** — Derive the session offset from the confirmed
   `power_off_park` pose. Convert the approved physical hard and operating
   limits into this session's vendor frame. Reject a wrap ambiguity, changed
   joint sign, missing calibration version, or a current pose outside the
   translated envelope.
6. **`JOINT_PROOF`** — With a maintained hold-to-run input, test one joint at a
   time around its current pose. A conservative first-lab proof is at most one
   degree in each permitted direction over 8–10 seconds, returning to the
   captured pose after each excursion. Test distal joints before proximal ones
   by default (J7 toward J1) to limit swept mass, but use the collision model to
   omit or reorder any unsafe excursion. The other six joints must remain
   within following-error bounds. Never test two joints or both arms together.
7. **`VISION_PROOF`** — For each micro-motion, require the observed link motion
   to have the predicted direction and displacement within the commissioned
   uncertainty bound. Require several stable frames before and after the move.
   A stale, occluded, contradictory, or jumping visual fit requests a measured
   hold and latches the arm fault.
8. **`GRIPPER_PROOF`** — With the arm held in a low-energy, visible pose, run the
   gripper workflow below. Gripper failure disables gripping but need not erase
   a valid seven-joint arm reference.
9. **`READY_LIMITED`** — Allow only the conservative operating envelope and
   leased, dead-man-controlled motion. Expanding to the commissioned normal
   envelope requires a separate local operator action after reviewing the proof
   log. `READY` is never inferred from elapsed time or a vendor acknowledgement.

Any dead-man release, stale telemetry, unexpected mode, gateway/session change,
status fault, current anomaly, excessive following error, limit approach,
collision prediction, or visual contradiction requests an immediate measured
hold. If a hold cannot be confirmed, the state changes to `FAULT_LATCHED` and
the physical safety system is used; software does not retry or continue with
the next joint.

### Commission direction, zero, and range

Commissioning occurs with the robot secured to a test fixture, both arms
supported, and only one actuator enabled. The initial software envelope is a
small region around the observed pose, not the broad URDF range.

1. Inventory each actuator identity, firmware/core build, CAN mapping, encoder
   wrap behavior, status bits, rated current, and whether position persists
   across at least three complete power cycles. A dispatch acknowledgement is
   not encoder evidence.
2. Use a mechanical zero fixture or surveyed link fiducials to place a joint at
   a known physical angle. Record its raw value and determine its sign with a
   single hold-to-run micro-motion. Repeat the observation before saving it.
3. Obtain hard travel limits from the arm's mechanical/manufacturer data or
   install dedicated limit/index sensors. Do not find a limit by intentionally
   stalling into an ordinary mechanical stop. Current-rise homing is permitted
   only if the stop and actuator were designed and rated for it and a separate
   low-level stop primitive has been validated.
4. Expand a provisional envelope in small increments. At every sample, check
   the complete interpolated path for self-collision, torso/cradle/camera
   collision, cable wrap, and left/right-arm collision; monitor measured
   velocity, following error, current, status, and vision residual. Return to
   the last proven pose after each sample.
5. Store three ranges, not one: `mechanical_hard`, `commissioning_tested`, and a
   smaller `normal_operating` range with an engineering margin. Runtime targets
   outside `normal_operating` are rejected and faulted, not silently clamped.
6. Repeat the safe pose set in both directions to measure backlash,
   repeatability, gravity sag, and current baseline. A limit is not approved
   from a single pass.

The existing checked-in nominal URDF limits remain an outer model reference:
J1 +/-2.4435 rad, J2 +/-2.3213 rad, J3–J6 +/-2.2863 rad, and J7 +/-3.05 rad.
They must not be treated as ROB's measured mechanical or collision-safe limits.
The current hard-coded gateway bounds must eventually be replaced by the
signed, per-arm commissioned record.

### Validate 3D geometry with the cameras

Vision is an independent plausibility sensor and metrology aid, not the only
stop channel. The current OAK-D/QR implementation estimates points at QR centers
and fits joint-center locations. That can help observe early joints, but it
cannot observe the final wrist rotation and its current 50–60 mm readiness
residuals are too loose to certify fine joint calibration.

For commissioning:

- calibrate RGB/depth intrinsics and the camera-to-ROB transform using at least
  four widely separated surveyed body anchors;
- mount surveyed fiducial rigs on the links and an orientation-observable tag
  rig on the wrist/gripper; estimate full tag pose from corners rather than
  only a depth sample at the tag center;
- capture stationary observations at a diverse set of collision-safe poses,
  with repeated approaches from both directions;
- first solve the fixed arm-mount transform, then joint signs/zero offsets, and
  only then any link-transform corrections. Do not freely optimize every
  parameter in one under-constrained fit;
- validate on held-out poses and store RMS, worst-case error, covariance,
  camera serial/intrinsics version, marker layout version, temperature, and
  sample count; and
- derive acceptance thresholds from stationary repeatability and held-out
  error, with an engineering margin. The existing broad readiness threshold is
  not automatically a calibration threshold.

At runtime compare forward kinematics from calibrated joint telemetry with the
observed link/tool pose. Vision can veto motion or require re-reference. It
cannot override an encoder, limit, collision, current, status, dead-man, or
physical E-stop fault, and an AI visual description is never calibration data.

### Gripper commissioning and startup

Amber command 7 with gripper selector 8 may sweep the jaw through its full
travel. The checked-in interface provides only dispatch acceptance: no measured
jaw aperture, force, endpoint, completion, or stop. Therefore the current
gripper can only reach `COMMAND_ACCEPTED_UNVERIFIED`; it must remain unavailable
for autonomous grasping.

The present supervised procedure is:

1. Hold the selected arm in its referenced low-energy test pose, empty the jaw,
   clear the pinch zone, and confirm the other gripper is idle.
2. Start camera recording and issue one calibration request. Never retry an
   ambiguous acknowledgement.
3. Observe the entire motion locally with the E-stop ready. The camera may log
   jaw travel and gross asymmetry, but cannot make the undocumented operation
   stoppable.
4. Mark only dispatch acceptance and invalidate it on every controller session
   or known power-cycle change.

Measured gripper calibration requires a jaw-position sensor or endpoint
switches plus measured motor current/force (preferably a fingertip load cell)
and a low-level stop command. With those additions, approach the open datum at
limited energy, back off, repeat to establish repeatability, close slowly on a
known gauge, map actuator position to aperture, establish contact and maximum
force thresholds, and verify release/hold/stop before enabling grasping. A
fiducial on each jaw can independently validate aperture but does not replace
the switches, force limit, or stop.

### Calibration record and command boundary

Persist a signed, versioned record per physical arm containing:

- robot/arm/actuator identities, firmware and Amber-core hashes, CAN mapping,
  encoder type/wrap behavior, direction, model-zero offset, and invalidation
  rules;
- `power_off_park`, mechanical/tested/operating ranges, startup proof step,
  velocity/acceleration/jerk caps, current and following-error bounds, and
  collision-model version;
- arm-mount and link/tool transforms with uncertainty and their visual
  calibration provenance;
- gripper sensor/endpoint/aperture/force data, or the explicit
  `feedback_unavailable` state; and
- calibration ID, schema version, timestamp, operator approval, test log hash,
  and checksum.

The boot-derived session offset and boot generation are kept separately from
the persistent physical calibration. A firmware/core change, actuator swap,
mount movement, marker/camera change, checksum failure, implausible park pose,
or failed proof invalidates the affected scope.

Finally, the vendor cores, UDP ports, CAN interfaces, and a dedicated
least-privilege safety gateway must form one isolated service boundary, for
example in a service/network namespace. Sample scripts and UI processes must
not be able to reach ports 26001/26002 directly. Every caller submits
physical-model targets to the same gateway, which rejects unreferenced arms,
stale state, uncalibrated limits, unsafe paths, excessive step/speed, and
concurrent owners before translating to the current vendor frame. This is what
prevents a manual joint packet from bypassing over-rotation protection.

## Character sequence and expansion boundary

The supported live sequence now reuses Cerebro's stage-show coordinator for
timing, speech, its final checkpoint, cancellation, and dry runs, while the
physical movement is delegated to the measured Amber gesture adapter. Future
mechanisms must follow the same shape:

1. ROB greets the operator and waits at a physical E-stop/workspace checkpoint.
2. Cerebro verifies controller identity, feedback freshness, and subsystem
   ownership without energizing anything.
3. One adapter performs one small, named action and proves its terminal state.
4. ROB reacts in character only after that result; a failure stops the sequence
   and names the mechanism that needs attention.
5. The next subsystem begins only after another readiness check.
6. The final checkpoint enables normal Vision/model interaction for only the
   mechanisms that passed.

This preserves the charming staggered boot-up—little looks, pauses, and spoken
reactions—without treating an elapsed timer or an AI description as proof of
motion. Gemini Live owns narration and high-level selection among approved
names. Deterministic geometry owns visual calibration, and the local adapters
own actuation and measured completion.

## First physical validation

Keep each unsupported wake-up mechanism in dry-run/excluded mode until it has
its adapter. Validate one new mechanism and one small movement at a time with
the robot supported, the exclusion zone clear, and the physical E-stop in hand.
Record commanded values, measured values, settle time, cancellation behavior,
and restart behavior. Only after those tests should a locally approved adapter
be added to the opt-in character sequence.

Amber gateway deployment and the first supervised gripper procedure are in
[Amber gateway deployment](amber-gateway-deployment.md). Vision arm authority,
leases, and measured completion are in
[Vision Pro supervised Amber arm control](vision-pro-arm-control.md).

The vendor basis for the pre-power physical-pose requirement and the available
joint/gripper commands is the
[Amber B1 V1 repository](https://github.com/MrAsana/AMBER_B1_ROS2) and the
[Amber UDP protocol](https://github.com/MrAsana/UDP-Protocol-API/wiki/Robotic-Arm-API-based-on-UDP-Protocol).
