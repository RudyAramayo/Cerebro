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
properties. The wake-up dry run therefore checks both B1 telemetry streams and
the deterministic OAK-D/QR visual-registration snapshot. Camera-frame,
camera-pose, and arm-pose producer ages must each be no more than 500 ms. The
workflow does not invent or execute a resting pose.

The repository photo of the current robot shows the B1 arms hanging almost
vertically beside the torso. Before telemetry arrives, Amber Diagnostics draws
a muted, dashed **reference silhouette** in that orientation. It is explicitly
labeled as a photo-derived visual reference and is never used as feedback or an
actuator target. There is no checked-in measured seven-angle resting pose, and
the vendor all-zero command pose is not evidence of ROB's physical rest pose.

To create a real wake pose, place and support each arm in the intended resting
configuration, use **Capture Left Measured → Keyframe** and
**Capture Right Measured → Keyframe** in Amber Diagnostics, validate the
calibrated mount transform and tool endpoint, and approve the result as an
immutable named gesture. Gemini may
select that local name and narrate the motion; it may not supply joint arrays
or decide that visual registration succeeded.

## Current calibration boundaries

| Mechanism | Current observation | Bounded stop and measured outcome | Wake-up behavior today |
| --- | --- | --- | --- |
| Amber B1 left/right | Seven positions, velocities, currents, statuses, and modes | Available through the named Amber gesture executor | Snapshot/readiness check only until a measured rest/wake gesture is locally approved |
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

## Intended character sequence

The future physical sequence should reuse Cerebro's stage-show coordinator for
timing, speech, checkpoints, cancellation, and dry runs, while each movement is
delegated to a typed local adapter:

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

Keep the wake-up plan in dry-run mode until each requested mechanism has its
adapter. Then validate one mechanism and one small movement at a time with the
robot supported, the exclusion zone clear, and the physical E-stop in hand.
Record commanded values, measured values, settle time, cancellation behavior,
and restart behavior. Only after those tests should a locally approved adapter
be added to the opt-in character sequence.

Amber gateway deployment and the first supervised gripper procedure are in
[Amber gateway deployment](amber-gateway-deployment.md). Vision arm authority,
leases, and measured completion are in
[Vision Pro supervised Amber arm control](vision-pro-arm-control.md).
