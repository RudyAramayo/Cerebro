# Right-shoulder bubble targeting

Open **Cerebro → Servos → Bubble Targeting…** for calibration and local diagnostics.
Open **ROBController → administrator workspace → Bubbles**, or the **Bubbles** toolbar button in
ROBControllerVision, for the camera, authorization, aiming, and motor controls.

## Confirmed wiring

The operator confirmed this mapping on September 15, 2026. Historical arm names are retained in
Interface Builder; they do not describe the accessories now attached to those outputs.

| Function | Historical IBOutlet | Maestro channel | Rest / OFF |
| --- | --- | --- | --- |
| Tilt | `arm_R_Shoulder_Pan` | 6 | 8000 |
| Pan | `arm_R_Shoulder_Tilt` | 7 | 4000 |
| Fan / Red | `arm_R_Elbow_Tilt` | 8 | 4000 |
| Bubbles / Blue | `arm_R_Wrist_Pan` | 9 | 4000 |

Channel 5 (`arm_R_Elbow_Pan`) is not part of this machine. The legacy rendering timer cannot write
channels 6–9; its sliders and checkboxes now enter the bubble controller. Relay channels bypass servo
speed/acceleration smoothing so the programmed pulse widths switch immediately. The external relay
still takes approximately 0.5 seconds to respond.

The operator also verified **8000 ON / 4000 OFF for both relays**. Existing calibrations using those
exact values receive a one-time wiring confirmation; different saved values are not confirmed.
The runtime never restores authorization or live output mode from disk. On Maestro connection,
it applies the confirmed relay OFF values and the
existing startup tuck: Tilt 8000, then Pan 4000 after 0.75 seconds.

## Operation

1. Open a controller's Bubbles panel. Its dedicated preview shows the **face-camera RGB image**
   about twice per second, independently of Cerebro's visible camera window. Depth is used privately
   for distance; it is not the displayed image. A missing camera never prevents manual authorization.
2. Press **Enable Tilt/Pan** to enable real mount movement, then use **Manual Tilt / Pan**.
   Press **Authorize bubbles** separately to enable real fan/blower commands. These buttons grant
   permission; they do not move the mount or start either motor. A fresh authenticated Cerebro
   connection is required. Mount movement remains available throughout motor cooldown.
   **Simulation only**, available before live outputs are enabled, keeps commands simulated.
   There is no additional hidden live-output switch to find in Cerebro.
3. Tap the desired point in the camera. Vision Pro offers an 11 × 7 grid of native gaze targets: look at
   a cell and pinch. The crosshair represents the selected cell center. The manual sliders offer finer
   adjustment. Eye focus alone never activates a motor.
4. **Start fan** and **Start bubbles** are separate. Bubbles are rejected until the spin command has
   settled for 0.5 seconds. Turning off the fan also turns off bubbles.
5. **Pulse** uses a 0.5-second spin lead, 3 seconds of blower command, then 5 seconds with both off.
   **Continuous** runs until the working budget ends. Neither mode restarts after cooldown.
6. **STOP** disarms and sends both relay OFF values. **Stow laser** stops first, tucks Tilt down, then
   rotates Pan to the saved side. Remote stow requires mount authorization; authorization is
   inhibited during the stow sequence. **Release Tilt/Pan** is always available as an OFF action.

**At Cerebro**, local sliders and buttons are direct operator actions. They enable the appropriate
live outputs without requiring a phone or Vision Pro authorization. A local action takes control
from a remote session; it never grants that remote session permission. Fan/blower controls retain
the relay delay, duty budget, cooldown, and independent watchdog. Closing the local bubble panel
stops motors. The legacy Red and Blue controls use the same policy.

If controls are disabled, the panel distinguishes a missing/stale Cerebro session from missing RGB
or depth. Status callbacks in the iOS transport facade are delivered on the main queue. Session
loss clears the preview, target, and authorization. Cerebro must remain responsive and both devices
must use synchronized clocks for the protocol's two-second freshness check.

On Vision Pro, enable **Use controller X / Y for fan / bubbles** while this panel is open. X toggles
the fan and Y toggles bubbles; these face buttons do not replace the existing grip dead-man or gripper
triggers. A held button cannot activate the machine merely by enabling the option. The OS must expose
X/Y through the controller's physical input profile; hardware mapping still needs a device check.

## Servo release versus removing power

**Release Tilt/Pan** sends target 0 to channels 6 and 7. Unchecking either mount checkbox invokes the
same release and stops the bubble session. This explicit OFF action remains available in dry run.
Both checkboxes reflect the coupled mount state. Moving a slider while unchecked cannot restore
pulses; checking either box enables both axes for direct local control.
Releasing pulses does not cut the servo power rail; loss-of-signal behavior depends on the servo.
Removing supply voltage requires a separate power-switching circuit. Fan/bubble OFF remains 4000,
never target 0. See [Pololu's Set Target protocol](https://www.pololu.com/docs/0J40/5.e) and
[power connections](https://www.pololu.com/docs/0J40/7.a).

## Duty cycle and authorization

Cerebro's **Bubbles** countdown counts only time with the bubble blower commanded on, plus its
0.5-second relay release tail. Fan-only operation, including the initial spin lead, consumes no
bubble budget and starts no bubble cooldown. Brief stops, mode changes, disarming, and reauthorization
do not reset the budget. It reserves 0.6 seconds inside the manual's 120-second limit for relay release
and scheduler margin. After exhaustion it locks activation until the blower has been off for a full
60 seconds. Fan-only operation does not interrupt that cooling time. Maestro connection starts an
initial cooldown when OFF is sent, which prevents a process restart from bypassing a previous run.
Enabling motors later does not restart that cooldown. If OFF has not yet been established,
enabling live motors sends OFF and starts the cooldown first.

Controllers send a heartbeat every 0.5 seconds. Mount permission and motor authorization belong to
that controller session. A lease expires after 2 seconds; late heartbeats cannot revive it. Session
disconnect, app backgrounding, panel closure, or STOP disarms. Local motor operation maintains its
lease on Cerebro's main loop without needing a remote controller. An independent
OFF-only watchdog can stop the relays even if Cerebro's main/UI queue stalls. A stopped or crashed
process cannot run software: configure and physically verify a Maestro serial timeout/error pose
and the relay board's loss-of-signal behavior before relying on unattended operation.

The `ROBBUBBLE1` envelope travels only over authenticated `robctl/2` operator sessions. Device and
session IDs, message direction, bounded fields, timestamps, and monotonically increasing sequence
numbers are checked. Any authenticated operator may STOP. Camera frames and status are returned
only to the requesting authenticated session, never broadcast through the compatibility transport.

## Depth calibration

The client sends a frame UUID and normalized RGB pixel; it cannot supply distance. Cerebro retains
the exact aligned depth and intrinsics for that preview, rejects frames older than two seconds,
samples a 5 × 5 depth neighborhood, and rejects holes, mixed-depth edges, out-of-range distances,
and targets outside servo travel. A pinhole projection yields the point in camera coordinates;
translation to the shoulder origin and a measured rotation produce mount yaw/elevation and servo
targets. This is geometric pointing, not a prediction of bubble flight in air currents.

Use the calibration editor in Cerebro to enter:

- Verified relay values: 8000 ON, 4000 OFF. A different future wiring configuration needs its own
  verification before setting `wiringConfirmed`.
- Measured pan/tilt neutral pulse widths and signed units per degree.
- Mount origin relative to the camera optical frame in meters: X right, Y down, Z forward.
- Camera-to-mount rotation in degrees, applied in roll → pitch → yaw order.
- The camera neck reference, captured using **Capture neck pose**. Set `geometryConfirmed` only
  after measuring the transform at that pose and checking projected targets.

**Load 3D model estimate for simulation** reads the bundled `rob-visual.json` in meters, applying
node transforms without the viewer's 1.2x presentation scale. Its right-arm anchor is approximately
20.8 cm right, 18.1 cm below, and 4.4 cm behind the face-depth-lens midpoint in the neutral model.
This midpoint is an RGB-center proxy; the model does not identify the added bubble nozzle pivot.
Loading these values clears geometry confirmation and the saved neck reference. Compare them with
the Scaniverse measurement before using them as physical calibration.

Neck movement changes both camera translation and rotation relative to the shoulder. The visual
model and `robot_description/rob_geometry_draft.json` explicitly mark the linkage and neck
pulse-to-angle mapping as unmeasured. These files cannot provide calibrated moving-neck aiming.
The initial zero offset/rotation, imported model estimate, and generic servo scale are simulation
values. Live depth aiming requires confirmed geometry and the saved neck command pose both at frame
capture and command application. Moving the camera away from that reference stops an active
calibrated run. No speculative moving-neck transform is substituted for a measurement. Servo position
is commanded, not encoder-verified. Calibrate direction, end stops, clearance, and settling on hardware.

## Cutting mat and red laser observations

Open **Cerebro → Servos → Bubble Targeting… → Grid & laser calibration…**.
The assistant uses a plain line grid; a checkerboard is not required. The default
spacing is **25.4 mm (1 inch)**. Choose a visible rectangular patch on the large mat
and count the **intersections**, including both ends: 9 columns × 6 rows span
8 × 5 squares. The counts and spacing are editable.

1. Place the mat upright and keep it and ROB's base fixed. Begin with the face
   camera looking forward. Establish the neck commands and apply a manual Tilt/Pan
   command so Cerebro has verified command state; wait for the servos to settle.
2. Cover or switch off the laser and press **Capture laser-off reference**.
   Click four intersections in this order: top-left, top-right, bottom-right,
   bottom-left. These are the corners of your chosen patch, not necessarily the
   physical edges of the mat. Mark the physical origin so it stays identifiable.
3. Uncover the laser and press **Detect laser** to see the grid and highlighted
   target. Use the normal ROBController or Cerebro manual Tilt/Pan controls to
   align the dot with that intersection. Let the servos settle and detect again.
   The image freezes for inspection; green marks the detected dot and yellow the
   requested target. Detection does not move the nozzle.
4. Confirm **Dot checked; servos were settled**, then **Save point & next target**.
   The assistant visits a central intersection, four corners, and edge midpoints.
   Saving requires one unambiguous dot within a quarter square of the target.
   The actual detected coordinates and error are saved, never snapped to the grid.
5. After completing the pass, use **New head pose**, move the neck slightly using
   the normal controls, and repeat. Keep the mat fixed and mark the same four
   physical intersections. Each head pose needs its own laser-off reference.

The detector uses OpenCV [HSV thresholds](https://docs.opencv.org/4.13.0/da/d97/tutorial_threshold_inRange.html)
on both sides of red's hue wrap, red-channel excess, laser-off subtraction,
compact connected components, and a perspective transform of the marked plane
([homography documentation](https://docs.opencv.org/4.13.0/d9/d0c/group__calib3d.html)).
The centroid includes a white-hot core surrounded by red evidence. Static red
printing, single-pixel noise, large red patches, and spots outside the selected
patch are filtered. Multiple candidates are reported as ambiguous, without
choosing the brightest reflection. Substantial scene/lighting changes require a
new reference. These defaults need validation with the real laser and camera;
there is no claim that color/shape alone identifies every possible reflection.

**Show saved observations** opens the current session under
`~/Library/Application Support/Cerebro/BubbleCalibration/<session UUID>/`.
Each complete sample is saved as an atomic directory containing:

- Original full-resolution `image.png` and `laser-off.png`.
- OpenCV `overlay.png`, red-evidence `mask.png`, and full `analysis.json`.
- `observation.json`: marked grid, actual dot coordinates in image pixels and
  mat-plane millimeters, requested target, error, capture/admission timestamps,
  frame IDs, head-pose pass ID/name, pan/tilt channels and commanded values,
  neck commands in pan/lower-tilt/upper-tilt order, RGB intrinsics if available,
  and a median 5 × 5 aligned-depth sample at the dot if available.

Pulse values are Maestro quarter-microsecond **commands, not encoder readings**.
Images are admitted only with established mount commands and a known neck pose;
stale frames or commands changed since admission are rejected. The operator's
settling confirmation is necessary because software cannot measure physical
servo arrival. PNG encoding runs on the camera worker only while this assistant
is open. OpenCV runs off the UI thread with a timeout. Opening, detecting, marking,
and saving do not issue actuator commands. Closing this assistant releases its
camera demand without closing the main bubble controls.

These files are observations for fitting and checking the nozzle transform,
servo scales, and moving-neck geometry. Recording them does not modify the live
calibration or bypass its measured-reference-pose requirement. A single planar
pass is not sufficient evidence for accurate aim at all depths: validate at
additional board distances and reserve points for checking the fitted result.
Grid homography assumes a flat mat and does not estimate lens distortion.

The operator's initial directly-ahead observation was **Pan 5836 / Tilt 5191**.
It is one target observation, not a proven neutral or pulse-to-angle scale.
The draft `rob_droid.urdf` exported September 13 has no bubble-nozzle link and
estimated neck geometry. `ROB Scans/IMG_9162.PNG` shows ruler segments of
6¼ inches (158.75 mm) near the camera/neck, 9½ inches (241.3 mm) toward the
right-shoulder assembly, and 6 inches (152.4 mm) along the lower neck region.
These scalar scan annotations constrain a future measured model; perspective
and incompletely identified joint/lens centers prevent treating them directly
as signed camera-to-nozzle X/Y/Z offsets. Preserve the photos and the new
observations when fitting the final nozzle link and neck kinematics.

Run `bash Scripts/test-bubble-laser.sh` for synthetic detector, native capture,
recording, and archive fixtures. Add `--show` to inspect the production SwiftUI
window with a synthetic mat in a separate app containing no hardware/network
implementation. The Python-only tests can also run with
`/usr/bin/python3 Tests/BubbleLaserCalibrationTests.py`; Cerebro uses its selected
Python interpreter with the existing `opencv-python` dependency.

## Validation

`bash Scripts/test-bubbles.sh` in Cerebro exercises the production duty-cycle policy, relay lead,
fan-only budget isolation, blower release tails and cooldown, local control, separate remote permissions,
camera-free movement during cooldown, session ownership,
sequence replay rejection, disconnect, frame identity, synthetic RGB-D projection, model anchors,
dry-run output isolation, pulse release, console freshness, and the watchdog with the main loop blocked. Serial I/O is
replaced by a fake object in these fixtures. Full macOS, iOS Simulator, and visionOS Simulator builds
cover the three app integrations. Wire definitions and the shared console view are copied identically
across the repositories and should remain synchronized.

`python3 Tests/ROBBubbleConnectionTests.py` in ROBController exercises the production delegate
delivery methods from a background queue and checks main-thread delivery and packet order.

The operator verified the relay thresholds. Software tests do not verify nozzle alignment, laser
clearance, controller button mapping, or real cooling performance.
