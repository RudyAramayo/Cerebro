# Camera-referenced torso rotation

Cerebro's Keyboard Controls waist slider now commands **turn speed**. The
**Torso Rotation…** button opens a panel with a spring-centered speed slider and
a separate circular destination control. Tic counts and the slider's previous
value never establish ROB's orientation. No homing, controller reset, or
synthetic position-zero command is issued by this control path.

## Try the controls

1. Build Cerebro and open **Keyboard Controls → Torso Rotation…**. The panel
   starts in **Rehearsal**, which produces no motor commands.
2. Select **Arm rehearsal**. Hold and drag the speed slider to turn; releasing
   it returns the slider to zero and ramps the requested speed down.
3. Set a destination with the circular dial or degree field, then select
   **Turn to heading**. The shortest circular route is used: +179° to −179°
   is a 2° turn. The heading display wraps; there are no slider end stops for
   torso position. The speed slider can continue rotating across this wrap.
4. Adjust **Speed limit** to change the maximum rate. Changing the limit disarms
   the control and requires another explicit arm. The initial profile is 8°/s
   maximum with 8°/s² acceleration and deceleration. The adjustable maximum is
   1–20°/s; these are provisional values for supervised calibration.

Near a destination, the speed request follows a smooth quadratic taper over
25° and a stopping-distance bound. Acceleration and direction reversals are
limited. Arrival tolerance is the greater of 0.75° or twice the camera's
estimated angular uncertainty. **Stop**, Escape, window closure, or loss of
local application focus drops motion authority. Releasing just the speed
slider stops the turn while retaining arming and holding torque.

## Use live camera feedback

Install the existing runtime with `Scripts/setup-shadow-planner.sh` if needed.
Disconnect Pololu Tic Control Center before using Cerebro; both applications
cannot own the same USB controller. Select **Live camera**, wait for a confirmed
heading, then explicitly select **Arm torso**. Selecting live mode or acquiring
a camera estimate alone cannot energize the controller.

The markerless worker fits the approved scan's base, tracks, lean structure,
RPLidar mount and torso to synchronized OAK-D depth. It estimates camera pose,
torso yaw and body lean separately. The scan supplies search hypotheses;
commanded joint values, Tic counts and the home sensor do not confirm position.
Angles refer to the URDF torso joint relative to the base, rather than a world
compass heading. A global search covers the yaw circle before local tracking.

Confirmation requires visible base **and** torso surfaces, adequate independent
geometric constraints, agreement among candidate fits, three consistent frames,
at most 12 mm surface residual and at most 2° estimated yaw/lean uncertainty.
The accepted camera is retained while fresh. Switching camera streams rebases
the estimate and requires re-arming. **Refresh camera estimate** stops control
and restarts acquisition; it does not move ROB to a starting pose.

Capture age is carried from the camera service through the socket and fitting
process. It is derived from the oldest synchronized RGB/depth timestamp using
the SDK's own host clock, as described in [Luxonis' clock documentation](https://docs.luxonis.com/software-v3/depthai/depthai-components/device).
Unknown-age or already-delayed frames cannot authorize motion. An older camera
service without this timestamp can still display video but cannot confirm joints.

An onboard camera looking only out into the room cannot infer torso-versus-base
rotation through this fitting method. The required self-view has not yet been
validated on ROB. Such a view reports **Unconfirmed** and prevents arming; an
appropriate camera view or a separately validated visual odometry/base reference
is required. This implementation adds no external-camera capture route and uses
no printed markers. Synthetic scan fits are not measurements of real accuracy.

## Motion and fault behavior

- Camera evidence expires after 750 ms. Stale, missing, ambiguous, or invalid
  evidence removes motion authority and requests a controlled stop.
- A large unexpected visual correction updates the estimated pose, stops
  movement, and requires explicit re-arming. Unobserved requested travel or
  observed movement in the opposite direction reports a fault. These checks
  detect disagreement; they do not diagnose a broken joint or a missed step.
- One serialized Tic transport sends only the newest velocity demand. It
  refreshes zero-speed holding commands as well, so a steady target does not
  accidentally starve the watchdog. An expired queued demand cannot execute.
- Preflight verifies the saved controller identity, Tic 36v4/full-step serial
  configuration, safe start, a 100–1000 ms command watchdog, decelerate-to-hold
  error response, voltage and active fault status. Arming first replaces any old
  target with zero velocity and applies the runtime speed/acceleration limits.
  Regular updates never clear safe start or automatically resume a fault.
- The existing scale is 36,800 pulses per torso revolution. Physical polarity
  and scale still require a supervised low-speed camera comparison. The live
  UI does not certify cable freedom, clearance or unlimited physical turns.

The existing Vision Pro torso demand now becomes a circular heading offset from
the fresh camera yaw at activation, rather than from the debug slider. It
requires the live camera control to be explicitly armed in Cerebro. The existing
controller authority still applies; stale VR demands stop the turn after 600 ms.
No Vision Pro wire-protocol change is required.

This estimator and controller are separate from arm Shadow IK. They do not
certify a moving torso for arm collision planning. The shadow arm solver still
pins body joints to its review pose, and its previously reported scan-envelope
overlaps remain unresolved. Whole-body physical IK execution is not enabled by
this change.

## Verification

Run `Scripts/test-torso-control.sh` and `Scripts/test-shadow-planner.sh`.
Fixtures cover circular wrap, taper and settling, reversal, slow and fast
unobserved motion, opposite direction, stale/replayed evidence, camera rebase,
Tic fault latching and watchdog updates, canceled arming, rehearsal isolation,
VR reference selection and synthetic markerless recovery. The actual UI can be
compiled with the coordinator fixture's `--show` option; its injected transport
cannot access USB. A development Cerebro build and this inert UI were checked.
No physical motor was energized or moved for these checks.
