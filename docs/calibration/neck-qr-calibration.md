# Fixed-target neck and camera calibration

Use **Testing Sandbox > Neck / QR calibration** with the printed
[`ROB:TABLE:001` target](targets/README.md). The operator measured its symbol
side as **120 mm** on October 23, 2026 and confirmed that it was taped down.
Keep the table, target and ROB's base stationary throughout a capture.

## Capture and fit

1. **Capture current QR view** reads three fresh frames without commanding the
   neck. Use this when the target is already visible.
2. **Run neck-only sweep** starts at the existing table-inspection view and
   records twelve settled views, with three frames per view. After the first
   detection it centers the remaining small pan/tilt sweep on the marker.
   Four views are reserved for independent validation. This operation claims
   both arms only to prevent another operation from using them; it sends no
   arm activation, jaw, waypoint or encoder-reset command.
3. **Fit recorded views** estimates camera-to-neck and target-to-base transforms
   from the raw neck model and measured QR corners. The worker uses OpenCV's
   planar square pose solver and hand-eye fitting, with a relative-motion
   rigid-fit fallback when the installed OpenCV lacks its hand-eye binding.
   Fit and held-out marker drift are reported separately. Available center
   depth is checked against the pose-derived depth and disagreements are
   reported rather than silently changing the fit.
4. **Show calibration folder** opens the private capture directory. **Stop
   calibration** cancels capture and further neck targets or terminates the
   offline fit. The neck executor retains its existing command bounds; Stop
   does not claim measured physical shaft stopping.

The capture uses Vision's four QR corners, aligned depth dimensions and the
intrinsics attached to the transformed RGB frame. Older SDKs without that
metadata use a labeled EEPROM fallback; malformed metadata is rejected. The
DepthAI producer requests the EEPROM RGB lens position before starting the
pipeline, when available, and records both requested and reported frame focus.
Missing focus calibration is reported without inventing a lens position or
writing EEPROM. These changes remove uncontrolled capture variables; they do
not by themselves establish RGB/depth alignment accuracy.

It records raw articulated camera/neck transforms, advancing frame
sequences, capture times and accepted neck targets. It rejects replaced camera
streams, changed neck settling epochs, invalid framing and malformed geometry.
Every accepted sample has a local RGB image and aligned unsigned 16-bit
little-endian depth file. A normal full sweep has 36 samples.

Files live under
`~/Library/Application Support/Cerebro/NeckQRCalibration/<capture-id>/`:

- `capture.json`: metric target definition, corner measurements, raw transforms,
  training/validation assignments and capture context.
- `view-*.jpg` and `view-*.depth-u16le`: private source observations.
- `fit.json` and `fit.log`: estimated transforms, errors and fit diagnostics.

## Meaning of the result

This is commissioning evidence. Neck poses are **accepted command estimates**,
not measured shaft feedback. The saved 7-inch/15-degree display correction is
excluded from the raw fitting inputs to avoid applying it twice. A fit never
sets measured registration, modifies arm references or grants actuator access.
The current world map and arm admission continue to use their existing rules.

QR corners must retain a consistent physical correspondence across the sweep.
Vision's named rectangle corners are recorded; arbitrary camera roll or a
corner-order change requires checking that correspondence before accepting a
fit. A stationary marker moving between fitted views can indicate neck-model,
timestamp, corner-order or camera calibration error, not merely depth noise.

Next, validate held-out marker drift, table/floor orientation and independent
measured positions, then align the room scan and robot base. Only after those
checks should a commissioned transform replace the provisional depth placement
and be used for physical grasp planning.

## October 23 commissioning checkpoint

Three complete sweeps and their private source captures are summarized in
[`evidence/2026-10-23-neck-qr/validation.json`](evidence/2026-10-23-neck-qr/validation.json).
The first two runs had held-out drift of 46.7 mm and 56.4 mm. The third run
reported matching factory/frame focus position 124 in all 36 samples, but
held-out drift remained 56.3 mm. Locking focus did not resolve the residual.
No fitted transform or neck-angle gain has been applied. The installed signed
Debug build and source hashes are recorded with the evidence. Startup gripper
calibration and the single wake-session offer were restored after temporarily
disabling them for the final camera-only reload. No arm task was run.

Exploratory training-only angle scaling reduced the first capture's held-out
drift to about 14.9 mm, but RGB pose versus depth still disagreed by about
54 mm. That gain is a diagnostic estimate, not measured servo calibration.
Known-square/depth-plane fits also failed to identify a stable replacement
intrinsic matrix. Do not combine these estimates with the provisional 15-degree
correction to claim measured registration.

The next capture should add a rigid, measured target board with depth-visible
edges at multiple distances and image positions, or independently measured
board/base coordinates in the planned room scan. This separates RGB framing
and depth alignment from neck command-to-angle error before arm planning.
