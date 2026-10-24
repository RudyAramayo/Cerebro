# Shared neck, marker and gravity fit

`Resources/ShadowPlanner/qr_neck_constrained_bundle.py` is an offline candidate
solver. It cannot move ROB, change a URDF, install registration evidence, or
approve an arm operation. It uses NumPy, OpenCV and SciPy.

The operator-confirmed chain is **pan → lower pitch → upper pitch**. The older
canonical URDF places lower pitch before pan. The new fit uses a virtual
vertical pan-axis frame at the CAD lower-pivot location in `torso_link`,
`[-0.0207044288303, 0, 0.355408962871]` meters, followed by a 155.79mm local-Z
link between parallel pitch axes. This origin is an axis-frame convention;
it does not claim the physical pan motor sits at that height. The torso/pivot
location retains an explicit assumed 20 mm CAD allowance. Pan-to-lower lateral
offset, shaft directions and the link's local-Z direction remain assumptions.
Body lean and torso yaw are not declared physically zero.

The shared parameters are three positive command gains, a lower-angle offset,
one composite camera mount, a gravity direction in the torso frame and a fixed
optical-frame accelerometer bias. Each fixed marker has one nuisance pose.
The upper zero and mount rotation are one composite gauge: the solver does not
claim to identify them separately. Global marker coordinates are not supplied.
The torso frame fixes the global gauge; an unconstrained body/pan transform is
not fitted alongside unconstrained marker poses.

The two floor sheets share a soft plane, and the table normal is parallel to
that plane. Default assumed tolerances are 0.5° for normal alignment and 3 mm
for floor-center coplanarity. These constraints act on marker geometry; raw
depth returns are preserved. Gravity is fitted rather than forced along
torso+Z. Stationary IMU directions use a 2° allowance and one shared bias with
a 0.25m/s² prior. Overlapping stationary windows collapse to one observation
per distinct command. No free camera pose is added per image to absorb jitter.
Fresh captures without IMU remain explicitly marked as lacking that constraint.

The 165 mm upper-servo-center to sphere-center measurement and 96.5 mm sphere to
lens-glass distance imply a 68.5–261.5mm **full 3D center-to-glass distance**.
They do not bound perpendicular distance from the upper rotation axis. The
solver uses this only as a soft datum, with 15 mm optical/glass allowance and
40 mm assumed uncertainty in the physical-center versus virtual-axis datum.
Perpendicular pivot radius is reported separately. This avoids rejecting a
small perpendicular pivot radius merely because its shaft-axis coordinate is
unknown.

Whole command poses remain separated between training and held-out data.
Robust pixel residuals use marker/pose-balanced weights. Surface and IMU
constraints retain their explicit uncertainty units. Fixed intrinsics and
zero output distortion are used for the current undistorted RGB stream. The
factory EEPROM distortion describes the sensor image; it is not evidence that
delivered JPEGs remain distorted. Nonzero distortion requires matching original
per-frame native-output metadata and its immutable hash. Raw depth is checked
afterward and never forced to agree
by flattening the cloud or fitting an unreported scale.

Example, using a private stationary survey manifest:

```sh
python3 Cerebro/Resources/ShadowPlanner/qr_neck_constrained_bundle.py \
  --manifest /path/to/accepted-analysis-manifest.json \
  --output /path/to/private-fit.json \
  --starts 3 --maximum-seconds 120 \
  --predict-pose 0,6495,5900
```

`--validate-manifest` accepts a later stationary survey. That validation freezes
all neck, camera and bias parameters; it fits the new scene's marker poses from
training views only, then reports held-out pixel/depth/marker drift. A new
gravity direction permits changed body posture. It cannot use held-out images
to retune the neck.

Pose predictions include the conditional covariance propagated to camera
position/orientation, the training command convex hull, the observed maximum
held-out marker drift and the CAD allowance. Conditional covariance is not a
physical confidence bound: mount error, model bias, depth bias, servo backlash
and correlated observations remain separate.

For the actual October 23 FBF4 survey, 394 accepted observations covered 51
distinct training and 29 held-out poses. The corrected zero-distortion fit gave
3.444/4.001px training/held-out corner RMS and 1.022/0.968° IMU direction RMS.
The fitted floor normals differed by 1.22°, compared with approximately 7.8°
in the earlier unconstrained analysis. Zero-distortion PnP held-out marker
translation drift was 15.8 mm RMS and 33.1 mm maximum. Raw center depth still
disagreed by 100.4 mm RMS on held-out
views, so this result was not installed as camera-to-arm registration.
Median within-hold corner-coordinate jitter was 0.024 px, with a 0.481 px maximum;
the remaining approximately 4 px error therefore warrants systematic-model
and depth checks rather than attributing it to ordinary image fluctuation.

Run `python3 Tests/test_qr_neck_constrained_bundle.py` with the same scientific
dependencies. Tests cover measured joint order, tilted gravity, metric
recovery, strict held-out isolation, floor height inconsistency, the shaft-axis
distance gauge, prediction sensitivity/extrapolation and frozen-neck fresh-scene
validation. Synthetic recovery does not commission the physical robot.

## Independent Swift RGB evidence

`ROBNeckBundleEvidence.swift` accepts a distinct `neck_bundle` evidence kind;
it does not turn inferred marker poses into surveyed CAD point pairs. The
validator recomputes the measured-order camera transform from raw Maestro
targets and the fitted parameters, using the nominal optical mount supplied
from the pinned model. Its required source verifier must bind original image
and capture-metadata hashes, camera scope, sequence and capture time.

Each observation declares `outputPixelModel` and its
`pixelModelProvenanceSHA256`. Undistorted output rejects any nonzero distortion.
Native-distorted output additionally requires its provenance hash in the
caller's independently verified native-output set; the default set is empty.
A mutable JSON flag or an EEPROM coefficient file cannot enable that mode.

Each supplied PnP candidate is checked for a proper rigid rotation, positive
depth, front-facing QR plane and independent reprojection of its actual
corners using the recorded intrinsics/distortion. Near-equal distinct planar
branches reject. Marker poses are then refitted from training pixels only,
starting from three distinct training views. Held-out pixels cannot change
those fitted poses. The exact requested head pose must occur in the evidence;
this validator does not extend a profile into unobserved head positions.

Current local RGB gates require at least two markers, four training neck poses
and three disjoint held-out poses; every marker needs three training poses.
Shared-chain training/held-out corner RMS must each be at most 4 px, every view
at most 8 px, and held-out marker-center drift at most 30 mm. Independently fitted
floor normals and table/floor normals must agree within 3°, with floor plane
offsets within 30 mm. These are commissioning gates, not a physical safety claim.

The returned RGB allowance is the explicit 20 mm CAD assumption plus maximum
held-out marker drift plus the declared parameter-position allowance. It is
never clamped to fit a consumer's limit. `hasDepthProjectionAuthority` is always
false. A separate independently validated depth proof must cover the relevant
camera view, raw range and source pixels before runtime depth projection or
arm-path admission can use this geometry.

The Swift runtime fixture independently matches the Python articulated
kinematics, checks training-only marker fitting and rejects changed scope,
source verification failure, bad rotations, intrinsics, unobserved heads and
leaked pose splits. The actual final near/floor dataset also passed RGB
recomputation after original JPEG and capture-metadata hashes were re-read;
it retained 2.824/2.184px training/held-out RMS and 16.72 mm maximum marker drift.
With a declared 14 mm parameter allowance, its total RGB allowance was 50.72 mm.
It still had no depth-projection authority.

The initial analysis incorrectly carried a factory-distortion sensitivity
hypothesis into delivered images without proving the output pixel model. Both
the original survey camera source and the current service request
`enableUndistortion=True`, and the captures retain transformed-frame intrinsics.
Those earlier factory-D reports, including the 50.93 mm allowance, are retained
as superseded diagnostics. They were not installed as registration. The
corrected zero-D model follows the stream contract rather than choosing the
distortion hypothesis with the smallest residual.

## Estimated empty-right probe context

The dedicated probe may use this RGB geometry as an explicit estimate alongside
both raw depth and the bounded corrected-depth hypothesis. Its map remains
unregistered, retains every occupied hypothesis from each source frame, and
carves free space only before the nearer endpoint. The existing 150 mm estimated
margin, full-arm sweep, retreat-only overlap checks, live feedback, one-shot
approval and Stop still apply. Ordinary grasp registration is unchanged.

An imported `estimated_fixed_head_raw_corrected_union` package binds its RGB
input, parameter fit, depth report and running camera-service source by hashes.
Each capture must record the actual worker's startup source hash and actual
undistorted-output flag. The importer compares that hash with the independently
read installed service source. Legacy captures without these fields remain
analysis data and fail runtime import. Current head targets, native intrinsics,
camera/gateway generations, model/mapping and body epoch must still match;
importing evidence never grants arm permission.

## Live neck and floor display

`ROBNeckRGBPoseDisplay` loads a per-robot
`NeckQRCalibration/ActiveRGBDisplayProfile.json` from Cerebro's Application
Support directory. The activation file pins the model, geometry, reference,
zero-distortion fit artifact and a separate floor-QR reference by hashes.
It evaluates pan → lower pitch → upper pitch from the actual raw commands;
there is no fixed replacement camera angle. The floor reference supplies a
separate display-up gauge. The physical camera-to-model transform does not
include that gauge.

Ghost uses this fitted chain for its head and face-depth display and avoids
adding the older manual pitch/translation corrections a second time. The
renderer invalidates retained head points when their projection context changes.
Raw depth values remain unchanged. A camera-angle correction cannot establish
depth accuracy, remove a remaining depth-plane tilt or authorize a grasp.

The fixed-head CAD/depth fitter can use the fitted physical camera transform
as an initializer. Its original depth, held-out, spatial-support and uncertainty
checks remain mandatory. A failed fit is still diagnostic.

For fresh runtime probe evidence, `Scripts/export-frozen-neck-probe-evidence.py`
accepts predeclared whole-pose roles and immutable current-worker captures. It
exports the existing frozen neck/depth hypotheses without optimizing them or
changing original metadata. See `--help` for its required artifact inputs.

## Measured head assembly and repaired servo references

The operator subsequently measured 129 mm from the upper servo rotation center
to the RGB lens glass. `--measured-glass-radius-mm 129` makes that a hard
constraint with the explicit `--optical-center-allowance-mm 15`: the optical
center radius must lie between 114 and 144 mm. This mode does not add the
earlier assumed 40 mm virtual-shaft allowance. A fixed lower-zero hypothesis
can be requested separately with `--fixed-lower-offset-degrees`; it is not
selected automatically from held-out scores.

The optional display profile `headMount` contains
`upperCenterToSphereMeters`, `sphereToRGBGlassMeters`,
`upperCenterToRGBGlassMeters`, `opticalCenterAllowanceMeters` and
`sphereAzimuthAssumption: "closest_to_nominal"`. The measured 165/96.5/129 mm
triangle remains rigid through every neck pose. Its remaining sphere azimuth
is assumed; its signed glass-to-optical displacement is not measured. The
renderer rejects an incompatible optical fit instead of moving its optical
origin to satisfy the mesh dimensions. This display option grants no motion
or registration authority.

The neck servos were reinstalled after a break, so historical raw targets 6000
for forward pan and 6011 for lower upright are numerical references rather
than established post-repair mechanical zeroes. Fixed room markers alone do
not establish torso-forward yaw. A separate torso-relative observation must
anchor that gauge. Record approximate operator observations as provisional,
preserve their uncertainty, and retain the original captured commands.
