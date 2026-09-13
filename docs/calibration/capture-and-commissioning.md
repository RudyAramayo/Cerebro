# ROB scan and calibration handoff

The September 13, 2026 workbench is a simulation and measurement tool. It does
not command arms, servos, treads, grippers, or the LACT. The numerical body and
mount estimates are not a commissioned robot model.

## What the existing evidence tells us

The front, side and high-angle lightsaber photographs show shoulder assemblies
canted outward and arms folded down beside the torso. The single-arm B1 URDF
provides link geometry and joint-axis relationships. It does not provide ROB's
mounting transforms, encoder references, tool-center points, or camera mounts.

The photo-layout profile approximates that appearance. Its mounting angles and
joint-2/joint-4 angles are explicitly illustrative. They were not recovered as a
metric solution from calibrated photographs. Cylinder symmetry also leaves
rotation about a cylinder's axis ambiguous without a key, bolt pattern, or
other directional landmark.

The vendor `DualArm.urdf` header says its L/R labels are reversed relative to the
physical robot and that joints 2, 4 and 6 receive direction corrections in the
driver. We therefore instantiate the single-arm model twice with ROB-left and
ROB-right prefixes. We do not transfer the dual model's mount offsets or driver
signs into a presumed physical calibration.

## The hanging startup reference

Rodolfo reports that the arms settle under gravity beside the robot before
initialization. Joints 2 and 4 then differ from the URDF's expected zero pose;
the other joints appear to remain in their initialization positions.

Keep these quantities separate:

1. **Mount transform:** a fixed six-dimensional transform from the torso to each
   physical B1 base. It should not change at each boot.
2. **Physical joint angle:** the URDF angle of each joint in an observed pose.
3. **Vendor reference:** the raw feedback reported in that observed pose during
   this specific controller session.

For each joint, once direction and physical pose are independently established,
and vendor feedback has been converted to radians using its verified unit scale:

```text
q_model = q_model_at_observed_park
          + direction * (q_vendor - q_vendor_at_observed_park)
```

`direction` is +1 or -1 after verification, not a guess from a side name. The
raw vendor reference must be captured again after a boot or loss of the valid
session. A model angle of zero must never be assumed merely because telemetry
reports zero. Do not command a guessed “home” to resolve the ambiguity.

Cerebro already implements this separation in `ROBAmberArmReferenceTransform`
and `ROBAmberArmReferenceStore`. References are bound to an active session;
the Geometry Lab deliberately does not populate or arm that store. Its preview
angles can become input to an observed park calibration only after measurement
and independent validation. Gravity, payload, joint friction and support can
change a hanging pose, so photograph and label its actual power/support state.

## Capture the first dataset

Use the iPhone 16 Pro for detailed original photographs and compare an iPhone
scan with an iPad scan of the same stationary arrangement. The iPad Pro M4 has
a LiDAR scanner, but the scanner specification is not a millimeter accuracy
certificate. [Apple's M4 iPad specifications](https://support.apple.com/en-us/119892).

1. Keep ROB in one stable supported pose for each complete scan. Keep the arms,
   waist, lean, flippers and neck unchanged between views. Record whether
   motors are off, holding, or in gravity compensation. Avoid power-cycling or
   reinitializing just to take the pictures.
2. Use ordinary even lighting, with bright decorative lights off. Keep the
   original unfiltered images and EXIF. Avoid portrait blur, panoramas, digital
   zoom, and changing lenses during a photo sequence. Take a fresh sequence if
   anything moves.
3. Include rigid measured scale bars in different directions. A ruler must lie
   in the same local plane as the feature being measured from a photo. Keep
   some known distances out of the fitting process to check the result later.
4. Label **ROB's** left and right. Use identifiers such as `L_BASE_A`,
   `L_BASE_B`, `L_BASE_C`, `L_BASE_CHECK`, and equivalent right-side labels.
   Spread landmarks widely; use a fourth or fifth point off the same line or
   plane where practical. Record what each mark physically refers to.
5. Capture front, rear, both direct sides and higher views around ROB. A fixed
   camera height improves repeatability; it does not eliminate perspective.
   Add close-ups of mounting plates, visible shaft ends, neck pivots, turntable,
   LACT pins, flipper axle, last arm flange, gripper fingertips and camera cases.
6. Export a real mesh as **USDZ** or **OBJ + MTL + textures**. A conventional
   PLY point cloud is also useful. A Gaussian splat alone is not a collision
   mesh. Retain the scan app's original project and the original photos.
   [Scaniverse documents mesh capture as a separate output](https://www.nianticspatial.com/docs/scaniverse/quickstart/).

A sticker on a motor cover is a landmark, not automatically the shaft center.
Measure the marker-to-axis offset or use a known CAD surface. A scan can provide
the outer envelope while repeated observed joint poses identify the rotation
axis. Those later poses should be acquired one supported joint at a time under
operator supervision, after the current reference and stop behavior are known.

Compare devices using errors on the same independent measured distances and
landmarks. Do not select the scan solely because its texture looks sharper.
Keep units explicit. A field showing `0.1 mm` does not demonstrate that accuracy.

## Most useful measurements

Use millimeters in `measurements.md` and record the instrument and uncertainty.
Leave unknown values blank rather than filling them with zero.

- Ground plane, track length/width/separation, and a repeatable chassis datum.
- Center and direction of the body lean axis and turntable yaw axis; confirm
  their mechanical parent order.
- Each shoulder plate's center, normal, and a directional key or bolt pattern.
  Measure both sides independently, including height and fore/aft position.
- Lower-neck, pan and upper-neck shaft centers and axes; confirm mechanical
  order and measure offsets to the camera bodies. Source maps Maestro 0 to
  pan, 1 to lower tilt and 2 to upper tilt; that is not a measured PWM-to-angle
  conversion or physical position feedback.
- Both LACT pin centers and several observed pin-to-pin lengths versus lean
  angle. Stroke drives a linkage; it is not equivalent to moving the torso
  straight up or forward. Keep rod/cylinder clearance in the collision model.
- Flipper axle, link envelope, and coupling. Source sends one M3 flipper
  command; confirm which pieces move together and their axis signs. The draft
  exposes separate geometry coordinates for fitting, not two proven actuators.
- Gripper flange-to-tool-center transform, open/closed fingertip spacing and
  payload envelope. The vendor seven-link model does not describe the complete
  installed gripper and every cable.
- OAK identity, active image resolution, intrinsics, optical frame and camera
  timestamp. Label each physical camera's role; remove any unused draft camera
  frame. Insta360 stitched images require their own projection/orientation
  model and must not inherit an OAK pinhole calibration.

## Use Robot Geometry Lab

Build the offline app with `Scripts/build-robot-geometry-lab.sh`. The same view
is available in a current Cerebro build at **Development → Robot Geometry Lab
(Simulation)**. Opening that view does not grant motion authority.

1. Open `robot_description/rob_photo_layout_estimate.json` for an illustrative
   folded-arm layout, or `rob_geometry_draft.json` for the URDF-zero preview.
2. Load the original single-arm `Amber URDF/amber_b1.urdf` to display the real
   vendor arm meshes. Both prefixed arms share those mesh assets.
3. Select a mount, adjust XYZ in millimeters and roll/pitch/yaw in degrees, and
   apply. The file stores meters/radians. Adjust preview **q** separately.
   Edit child collision envelopes without changing the arm's vendor mesh.
4. Import the scan, establish scale from known distances, then register it to
   the base. Turn off the model to inspect scan points. Clicking displays base,
   local and selected-parent coordinates. The floor grid is 100 mm.
5. Fit fixed mounts using a landmark JSON array with `localMeters` in the child
   mount frame and `parentMeters` in its parent frame. For scan fitting,
   `localMeters` means scan coordinates **after** the scale conversion and
   `parentMeters` means `base_link`. Mark independent points
   `validationOnly: true`. They do not influence the fit.
   The profile retains the input correspondences, residuals and preview/scale
   context so the fit can be reproduced; editing its transform invalidates it.
6. Keep both fit and held-out errors. A low fit residual alone does not verify
   metric scale, camera calibration, axis signs or shaft centers. Recheck with
   independent poses and record uncertainty before accepting the geometry.
7. Adjust neck frames and LACT anchors. Move only the **preview** sliders and
   confirm each child frame follows the correct parent and axis.
8. Save the profile, then export to a new bundle folder. It contains the URDF,
   calibration JSON, shared vendor meshes when loaded, and limitations.

`landmarks-format-example.json` is synthetic format documentation, never ROB
measurement data. A useful real set has at least three non-collinear fitting
points and additional independent validation points.

## Depth and collision limitations

The new Cerebro view deprojects supplied aligned depth with supplied camera
intrinsics. It does not invent a focal length when calibration is absent. The
cloud is optional, bounded, and hidden when stale. Its transform follows the
**preview** camera pose: it is not evidence that live servo shafts occupy that
pose. Neck command values currently do not provide measured shaft feedback.

The old controller-input SceneKit view remains a diagnostic illustration; it
uses a nominal field of view and fixed offsets and should not be used as the
metric calibration reference.

Envelope overlap in the lab is a broad-phase AABB warning. It may produce false
positives, and absence of a warning is not a verified collision-free trajectory.
The exported vendor meshes are retained for a proper collision planner. Body,
neck, tools, cables, payload and environment geometry need review. LACT closes
a mechanical loop, so the URDF tree represents the driven lean pivot; pin
anchors in the profile define the actuator-length calculation. A linear mimic
joint is not substituted for that nonlinear relationship.

The URDF intentionally has zero motion-limit placeholders and no robot-specific
dynamics or actuator mapping. It is an input to calibration, not an executor
configuration. Do not use it to authorize motion.

## First physical exercises after calibration

For the September 25 demonstration, prove a small set of repeatable behaviors:

1. Verify frame transforms and encoder direction/zero with independent held-out
   poses. Keep joint feedback, camera timestamps and calibration revision bound
   to the same run. Resolve unobservable wrist orientation with a tool marker.
2. With the base fixed, use one arm and a large soft ball in a simple fixture.
   First verify approach and retreat without grasping. Then test a supervised
   low-force grasp with cancellation and observed feedback. The lab's ball
   button is position-only IK, not a grasp or time-parameterized path.
3. Test follow separately in a cleared area: current authenticated controller,
   fresh selected-person image, valid main depth, belly safety view, lidar and
   stop behavior. Target loss and stale sensors must stop the base.
4. Add bounded gestures after their swept paths and stopping envelopes pass.
   Chess adds small-object localization, orientation and grasp precision.
   Handshakes additionally require validated contact-force/compliance behavior.

Human approval does not make an uncalibrated trajectory geometrically correct.
Physical execution remains a separate, supervised commissioning stage.

## Follow-mode recovery findings

The current repositories contain `ROBFollowPersonCoordinator` and the iOS
`ROBFollowTargetViewController`. On iPhone/iPad the route is **Admin → Follow →
Refresh Main-Camera Preview → select an outlined person → Authorize Selected
Person**. This uses a fresh camera selection, not an arbitrary old photo from
the photo library. Authorizing can initiate physical motion; it was not done
during this inspection.

The installed `/Applications/Cerebro.app` is dated August 24, 2026 at 09:30 and
does not contain the follow coordinator, including in its debug dylib. The
coordinator was added at 11:53 that day, after the installed build. A current
source build succeeds and includes it. Updating the installed runtime and checking the actual phone
build are still required before a physical follow test. The iPhone's paired
device tunnel was unavailable during the read-only version check.

The new full Cerebro build has not been launched against ROB or installed over
the existing runtime. The standalone Geometry Lab is available independently.
No arms, neck, treads, flippers, torso or LACT were moved during this work.
