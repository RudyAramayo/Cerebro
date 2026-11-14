# Torso rotation and software alignment

Cerebro's Keyboard Controls waist slider now commands **turn speed**. The
**Torso Rotation…** button opens a panel with a spring-centered speed slider and
a separate circular destination control. Live camera estimates and supervised **TIC count estimate** control are separate sources. A count estimate is not measured physical orientation. No homing, controller reset, or
synthetic position-zero command is issued by this control path.

The local speed slider and **Turn to heading** take control directly. There is
no voice approval or prerequisite **Arm torso** click. A drag or destination
click cancels automatic control, checks fresh feedback and both-arm clearance,
and runs the TIC preflight before movement. Release during preflight cancels
the request; it cannot start later. Releasing during movement ramps to a stop.
An old remote heading demand cannot retake control after the local release.
The selected source remains explicit: **Rehearsal** never drives hardware.
The optional Arm button can still prepare the controller separately.

## Explicit motor power

**Energize** and **De-energize** are available in both **R.O.B. Controls** and
**Torso Rotation**. Select a hardware source in Torso Rotation first. Energize
checks the TIC profile and actual zero velocity, replaces any old target with
zero speed, then enables and verifies the driver. It holds at zero speed without
arming rotation, so this stationary power check can be performed with hanging
arms. The normal both-arm tread-clearance check still applies to every turn.
An explicitly energized hold remains powered at idle until De-energize, Stop,
focus loss, window closure, feedback loss, a fault, or application shutdown.
Arming rotation from this hold preserves the requested power state.

De-energize requests a controlled stop, waits for TIC **Current velocity: 0**,
then disables the driver and verifies **Energized: No**. It also works when
another application originally energized the controller. A failed release
remains unconfirmed; the UI never reports power off merely because a command
was requested. These commands follow the [Pololu command reference](https://www.pololu.com/docs/0J71/8);
the command watchdog and safe-start configuration remain enabled.

The panel displays actual driver power, current TIC count, controller speed,
and operating state independently of the selected destination. A fresh
successful read clears an old USB connection error without re-arming motion.
The last failed command remains visible separately, including after status
polling recovers, until another explicit Energize, Arm or manual movement request.
TIC counts and speed are controller estimates, not shaft encoder feedback.
Disconnect TIC Control Center before using Cerebro; an open connection in that
application prevents Cerebro from opening the same USB device.

### Native TIC utility on Apple Silicon

The GUI-bundled Pololu utility is Intel-only on the commissioning Mac. For a
native command path, run `bash Scripts/setup-ticcmd.sh` (requires CMake,
pkg-config and Pololu libusbp-1). An optional argument supplies an existing
unmodified checkout at the script's pinned Pololu revision. The script builds
only the vendor CLI, links its Pololu library statically, and installs it under
`~/Library/Application Support/Cerebro/Tic`. Its validation invokes only
`--help`; installation never issues a hardware command. Vendor sources are
[available from Pololu](https://github.com/pololu/pololu-tic-software).

Discovery and torso control share the same executable selection: an explicit
`ROBTiccmdExecutablePath` setting, then the installed native utility, then the
vendor application's utility. Relaunch Cerebro after installation. No global
library-path change or replacement of the vendor application is required.

Active position and velocity commands request full status in the same process, avoiding a
second process between command renewal and feedback. The coordinator keeps
the 500 ms feedback deadline; command completion remains bounded to 400 ms.
The transport requests macOS latency-critical scheduling while armed or
powered, releasing that activity after a confirmed stop and power-off. UI
updates are coalesced to 10 Hz while the control loop remains 20 Hz. DEBUG
builds retain a bounded local `Caches/Cerebro/torso-usb.log` containing command
durations and state changes. Command arguments are not recorded.

Commissioning on 2026-10-28: the installed native Debug app held the physical
TIC energized at count 0 and zero velocity for 38 seconds through the Torso
Rotation UI, then confirmed power-off from De-energize. The trace contained
373 command completions, median 23 ms and maximum 269 ms, with no timeout.
The live count slider selected −8907 and updated the destination to +90°;
the actual count stayed 0. This verifies power switching and destination
feedback, not physical rotation. Both arms were hanging, and the intermittent
right-arm CAN feedback fault prevented preparing the required raised holds.

Later that session, with both arms in operator-adjusted position holds, the
left endpoint stopped at −8836 counts and was observed at approximately 90°.
The velocity-controlled rightward sweep stopped at +9171 counts (−90.8° by
the provisional calibration), with operator-observed corrective motion.
After switching fixed count turns to TIC position commands, the return
reached +92 exactly with reported velocity zero, then De-energize confirmed
power off. The operator reported that this center still needs a small left
trim. Exact controller arrival does not establish physical base alignment.
The first trim reached +87 exactly. Two attempts at +82 were stopped by
feedback ages above 500 ms before travel. A later UI destination was −283
when dispatched; TIC reached that destination, which was farther left than
the intended trim. Subsequent operator-directed corrections reached −280,
−277 and −265 exactly. Verify the displayed absolute target immediately
before every commissioning move, including after a stopped attempt or
operator UI interaction. The physical center remains unconfirmed; no
software-zero change or controller reset has been made from these trims.

## Try the controls

1. Build Cerebro and open **Keyboard Controls → Torso Rotation…**. The panel
   starts in **Rehearsal**, which produces no motor commands.
2. Select **Arm rehearsal**. Hold and drag the speed slider to turn; releasing
   it returns the slider to zero and ramps the requested speed down.
3. Set a destination with the circular dial or degree field, then select
   **Turn to heading**. Outside Development Mode, the shortest circular route is used: +179° to −179°
   is a 2° turn. In Development Mode, equivalent destinations prefer the tracked starting turn to unwind the temporary monitor/keyboard cables. The heading display wraps; there are no slider end stops for
   torso position. The speed slider can continue rotating across this wrap.
4. Adjust **Speed limit** in pulses/second to change the maximum rate. Changing
   the limit stops and disarms the control. The chosen limit persists across
   source changes and relaunches and is applied to both the host and TIC.
   The upper bound is the operator-confirmed TIC setting of 3000 pulses/s.
   The adjacent estimated table speed uses the observed 35,996 counts/turn,
   giving approximately 30°/s at that ceiling. It is not motor-shaft speed;
   no unverified gearbox ratio is applied again. Acceleration/deceleration
   remain 8°/s², and the fallback before selecting a limit remains 8°/s.

In **TIC count estimate**, a fixed destination uses `--position COUNT`, the
[TIC target-position command](https://www.pololu.com/docs/0J71/8#cmd-set-target-position).
TIC owns acceleration, cruising and braking. Cerebro renews the same target
under fresh supervision, checks both arms and waits for the exact target
count with zero reported velocity. It does not issue Mac-side velocity
corrections near the target. Count entry preserves single-pulse precision;
the rounded degree display does not change the selected count. This is a
movement request, never `--halt-and-set-position`, homing or a counter reset.

Manual hold-and-slide and live-camera heading control retain velocity
commands. Camera heading requests cruise until the stopping-distance bound
requires braking, without the former 25° quadratic taper. Their arrival
tolerance is the greater of 0.75° or twice the observation's estimated
angular uncertainty. **Stop**, Escape, window closure and termination drop
motion authority. Local focus loss stops held manual speed input; an already
started finite heading turn retains its bounded request and feedback checks
while the operator returns to chat. Releasing just the speed
slider stops the turn while retaining arming. Unless **Energize** explicitly
requested a powered hold, Cerebro de-energizes the stepper after the controller
reports zero actual velocity. Reaching a destination follows the same sequence.

## Software reference and debugging cables

The calibrated count field/slider use −8907 for approximately 90° ROB-left,
+9091 for approximately 90° ROB-right, midpoint +92, and 35,996 counts per turn.
These are calibration points, not mechanical stops. The slipring supports full
rotation. The count field selects an orientation through this mapping; the
circular heading/velocity controls remain available beyond the quarter turns.
Dragging the count slider continuously updates the count and degree destination
fields. It previews the target; **Turn to heading** starts the motion. The speed
lever is disabled while rotation is disarmed, with the reason visible in both
control windows. Energizing the motor in TIC Control Center does not arm
Cerebro's rotation control or provide it USB access.

Choose **TIC count estimate** for supervised control when the camera cannot see
the base. Selecting it only polls status; it does not energize or move the motor.
**Physically observed base-relative angle → Set software reference** associates
the current stationary count with an operator-observed angle (0° facing the tread
base front, +90° left, −90° right). It updates a host offset, without homing,
resetting counts, or asserting that the unverified index wire works. The count
slider and front target follow this corrected offset. Counts remain estimates:
a stalled stepper can lose physical alignment without changing reported counts.

Both arm/gripper envelopes must be held above the treads before and throughout
any torso turn, including count control. TIC status must be fresh within 500 ms.
Counter discontinuity or feedback loss stops control and invalidates the software
base reference. A new application/source session requires another actual base
observation; it does not restore an old reference as measured evidence.

Development Mode tracks continuous turns from the selected source and chooses
heading routes toward that starting turn. **Unwind tracked debug turn** explicitly
reverses to that reference, including across ±180°; no automatic extra motion is
issued after a task. Existing cable twist before tracking, missed steps, and
movement during a feedback gap remain unknown. Outside Development Mode, heading
requests use shortest-route circular motion and rate control can keep rotating.

## Use live camera feedback

Install the existing runtime with `Scripts/setup-shadow-planner.sh` if needed.
Disconnect Pololu Tic Control Center before using Cerebro; both applications
cannot own the same USB controller. Select **Live camera**, wait for a confirmed
heading, then hold the speed slider or choose **Turn to heading**. The local
command performs preflight automatically. Optional **Arm torso** preflight
leaves the stepper de-energized unless a powered hold was explicitly selected.
Cerebro otherwise energizes it immediately before each
fresh, authorized nonzero movement request. An armed, idle torso therefore
draws no stepper holding power; the next authorized movement energizes it again.
Selecting live mode or acquiring a camera estimate alone cannot energize the
controller.

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

The depth worker accepts the paired runtime calibration metadata sent by
Cerebro, validates its canonical identity and retains that identity in the
observation. A calibration change requires a new capture stream. This corrects
the former `Invalid depth frame fields` failure with current camera packets;
calibration provenance alone does not confirm a torso angle or camera pose.

An onboard camera looking only out into the room cannot infer torso-versus-base
rotation through this fitting method. The required self-view has not yet been
validated on ROB. Such a view reports **Unconfirmed** and prevents arming; an
appropriate camera view or a separately validated visual odometry/base reference
is required. This implementation adds no external-camera capture route and uses
no printed markers. Synthetic scan fits are not measurements of real accuracy.

## Motion and fault behavior

- Camera evidence expires after 750 ms. Stale, missing, ambiguous, or invalid
  evidence removes motion authority and requests a controlled stop followed by
  power release. Stop, window closure and faults also drop motion authority and
  request this stop-and-release sequence.
- A large unexpected visual correction updates the estimated pose, stops
  movement, and requires explicit re-arming. Unobserved requested travel or
  observed movement in the opposite direction reports a fault. These checks
  detect disagreement; they do not diagnose a broken joint or a missed step.
- One serialized Tic transport sends only the newest velocity demand. An
  expired queued demand cannot execute. On a normal stop it requests zero
  velocity, polls the Tic's actual **Current velocity** until it reaches zero,
  then de-energizes and verifies **Energized: No**. Polling renews the command
  timeout while the motor decelerates. A brief zero-speed demand during a
  direction reversal keeps power enabled so the following movement can proceed.
  USB failures or a failed power-release verification are reported explicitly;
  they are not treated as successful release.
- Application shutdown waits up to five seconds for the USB stop-and-release
  sequence before exiting, and logs an unconfirmed power-off if it cannot
  finish. Explicit Stop can retry a previously failed release.
- Preflight verifies the saved controller identity, Tic 36v4/full-step serial
  configuration, safe start, a 100–1000 ms command watchdog, decelerate-to-hold
  error response, voltage and active fault status. Arming first replaces any old
  target with zero velocity, applies the runtime speed/acceleration limits and
  verifies the driver is de-energized. Arming grants motion authority separately
  from motor power. Normal slider release or heading arrival keeps that
  authority while releasing power; faults require explicit re-arming. Only a
  fresh authorized movement request clears the intentional idle safe start.
  Ordinary updates never automatically resume a fault.
- Zero-speed preflight publishes its own fresh status. An idle status poll
  waiting behind the serialized setup commands does not cancel that setup.
  Rotation and an established powered hold retain the 500 ms count-feedback
  deadline; every velocity demand still has its own short execution lease.
  Preflight gaps discard the old software alignment and cable history rather
  than treating unobserved counts as measured alignment. Stop interrupts setup.
- Status reads use `ticcmd --status --full`, because the abbreviated output
  omits the step mode required by preflight. Current stopping errors are parsed
  separately from historical errors even when ticcmd places the next heading
  immediately afterward. Historical safe-start/timeout entries cannot block a
  new request as though they were current faults. The healthy inline form
  `Errors currently stopping the motor: None` is accepted; an empty or
  contradictory section is rejected. Earlier code expected an indented `None`
  and incorrectly shut power off after a successful Energize. This matches
  [Pololu's status formatter](https://github.com/pololu/pololu-tic-software/blob/master/cli/print_status.cpp).
- The current operator-derived estimate is 35,996 counts per torso revolution,
  with left rotation decreasing counts (0 to −8907 for approximately 90° left,
  approximately +9091 for 90° right). Counts do not establish a measured live heading. A software reference is explicitly operator observed and propagated by counts; it is invalidated on feedback loss/discontinuity. No cable-length-to-turn limit is inferred from the 16 ft cable length.

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
Fixtures cover exact TIC position arrival, five-pulse native count edits,
direct local takeover, release during preflight, asynchronous owner handoff,
remote override without replay,
expired position supervision, circular wrap, bounded braking and settling at slow and full
pulse rates, persisted limits, finite-turn focus behavior, reversal, slow and fast
unobserved motion, opposite direction, stale/replayed evidence, camera rebase,
Tic fault latching and watchdog updates, canceled arming, rehearsal isolation,
VR reference selection and synthetic markerless recovery. Fake Tic fixtures
also check that arming leaves power off, movement energizes before setting a
nonzero target, release waits for zero actual velocity before de-energizing,
normal idle retains arming, reversal retains power, and release failures remain
visible. The actual UI can be compiled with the coordinator fixture's `--show`
option; its injected transport cannot access USB. These fixtures validate
command sequencing without energizing or moving physical hardware. Actual
motor behavior still requires supervised hardware verification.

Power-control regression fixtures additionally exercise the actual native
Energize/De-energize buttons, a stationary powered hold with both-arm rotation
blocked, live count/heading updates from the destination slider, and releasing
a motor energized before the transport acquired ownership. They verify that
power-only requests never emit a nonzero velocity.

### Observed forward counter reset, 2026-10-29

The operator confirmed the stopped torso at count −90 was facing forward relative to the treads and explicitly requested zeroing the TIC counter. With motor power off and velocity zero, `ticcmd -d 00378067 --halt-and-set-position 0` changed the counter without motion. Readback showed count 0, no target and power off. Cerebro’s software front was then set to 0 at that same physical pose. With the existing inferred scale, left/right 90° targets are −8999/+8999. Hardware index/homing remains unverified, and missed steps still require a new physical alignment observation.

During the room survey, delayed idle polling erased that software alignment and blocked can-targeted base planning. A gap up to five seconds now retains the existing datum and cable history only when both samples show motor power off, zero speed and the same count, with matching serial number and continuous controller uptime. This also covers the stopped, power-off portion of rotation preflight. It does not arm or resume motion, freshen a timestamp or establish physical alignment from counts. Missing identity/uptime, changed counts, reboot, active movement and longer gaps retain their invalidation behavior; active 500 ms DEBUG feedback checks and the TIC watchdog are unchanged. The torso readout explicitly distinguishes an operator-referenced estimate from an unconfirmed base datum.
