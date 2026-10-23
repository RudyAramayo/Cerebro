# Fixed-target neck and camera calibration

Use **Testing Sandbox > Neck / QR calibration** with the printed
[calibration targets](targets/README.md). Select the actual decoded ID: table
`ROB:TABLE:001`, floor `ROB:FLOOR:L01` / `ROB:FLOOR:R01`, or right wall
`ROB:WALL:R01`. A capture uses one fixed target; the fitter rejects mixed IDs.
The operator measured the table symbol
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
- `Fits/<run-id>/`: native offline fits, refined diagnostic copies and logs.
  Each run has separate outputs, so cancelling and restarting cannot overwrite
  another run's files. Earlier direct/CLI fits may remain beside `capture.json`.

**Refine QR / fit neck mapping** runs exact-pattern refinement followed by the
bounded shared-kinematics fit locally. Refinement has a 120-second worker limit;
the single-target fit has a separate 45-second limit. Stop remains available
while both run. Accepted and raw-retained refinement counts are explicit.

## Meaning of the result

This is commissioning evidence. Neck poses are **accepted command estimates**,
not measured shaft feedback. The saved 7-inch/15-degree display correction is
excluded from the raw fitting inputs to avoid applying it twice. A fit never
sets measured registration, modifies arm references or grants actuator access.
The current world map and arm admission continue to use their existing rules.
The operator subsequently changed the depth translation to **4 inches toward
ROB** and reported **190 mm from the torso edge to the blue-tape edge**. That
measurement is an operator reference, not a base-origin coordinate: the torso
surface and tape edge still need a common measured frame. New captures record
the actual display correction separately; raw fitting inputs stay uncorrected.

## Checking each upper-neck hold

**Check upper neck forward / reverse** starts from the current readable view
with lower target 6011. It keeps pan and lower fixed, checks the selected QR at
each upper offset `[0, -75, -150, -75, 0, 75, 150, 75, 0]`, and saves three
fresh frames per hold. Interior targets are revisited from both directions.
The raw P/L/U targets appear in the status. Each changed pose uses the normal
staged Servo Control mechanical limits and a further two-second camera settle.
Every accepted frame must still match its requested hold, including after
Vision processing. Loss of the target stops the sequence and retains partial
observations; it does not silently advance to an unchecked pose.

**Start protractor measurements** uses the same nine holds but waits at each
one. Measure the same camera housing/bracket relative to the same level
reference. Enter pitch in degrees, positive nose-up, then choose **Record angle
/ next position**. A blank entry skips a manual reading. This advances the
test within its existing neck-only operation and creates no arm approval.
Stop cancels waiting and further neck targets. Do not move the neck by hand
while measuring it. The holding target can remain energized after Stop.

**Sweep upright / back / forward postures** repeats seven pan/upper views at
lower targets 6011, 5811, 6211 and 6011, for 28 holds / 84 samples when the QR
remains visible. At each changed lower posture, its first QR observation can
recenter subsequent upper targets by at most 150 units using a bounded
visibility prior. Every endpoint is still measured separately. An initial
posture capture lost the target at its seventeenth hold, motivating this
recentring; partial observations were retained. These are bounded raw targets,
not asserted measured angles.
The exact-target Servo Control path disables automatic camera leveling for
these endpoint requests while preserving its staged mechanical checks. Arm
and jaw commands remain outside this calibration lane.

For fixed-pan/lower captures, run the bundled offline diagnostic:

```sh
python3 Cerebro/Resources/ShadowPlanner/qr_upper_neck_report.py \
  /path/to/capture.json /path/to/upper-neck-report.json
```

It reports QR angle changes, repeated-target drift, optional protractor
comparisons and depth-plane slope inside the QR boundary. Candidate upper
angle scales train on first visits to each raw target and validate on return
visits; coverage and held-out errors are explicit. The nominal 0.030 degrees
per target unit is labeled as a model prior. Candidates remain unverified,
with `candidateURDFReady: false`: upper zero and camera mounting offset are
still confounded. It never flattens the full point cloud or applies a candidate
gain or URDF change.
Pan/upper motion provides independent axes for hand-eye fitting; upper-only
checks isolate repeatability but cannot solve the full mounting transform.
[OpenCV's calibration documentation](https://docs.opencv.org/5.0/main_modules/calib.html)
describes the need for nonparallel motions.

For URDF refinement, fit the camera mounting and separate lower/upper/pan
command mappings jointly, retain held-out views and compare the table, floor
and wall references. Use protractor readings and independently measured target
distances as validation. Only validated geometry and command mappings should
replace the current priors; a small training residual alone is insufficient.

QR corners must retain a consistent physical correspondence across the sweep.
Vision's named rectangle corners are recorded; arbitrary camera roll or a
corner-order change requires checking that correspondence before accepting a
fit. A stationary marker moving between fitted views can indicate neck-model,
timestamp, corner-order or camera calibration error, not merely depth noise.

Next, validate held-out marker drift, table/floor orientation and independent
measured positions, then align the room scan and robot base. Only after those
checks should a commissioned transform replace the provisional depth placement
and be used for physical grasp planning.

## Detailed numerical audit

The initial one-target calculations below were completed before the operator
repositioned ROB and placed the floor/wall references. Their inferred room
coordinates belong to that earlier scene. Their image measurements can still
test the camera and articulated neck chain. A later multi-target survey must
use a fresh scene identity and independently fitted target positions.

The reproducible aggregate results and input hashes are in
[`analysis-summary.json`](evidence/2026-10-23-neck-qr/analysis-summary.json).
The [six-panel audit](../../output/calibration/2026-10-23-neck-qr-analysis.png)
and [upper-neck comparison](../../output/calibration/2026-10-23-upper-neck-analysis.png)
contain aggregate measurements only. Original camera images and raw depth
remain private in the capture directory.

### Image coordinates and the apparent focal-length discrepancy

The measured symbol corners are `(-0.06,+0.06,0)`, `(+0.06,+0.06,0)`,
`(+0.06,-0.06,0)` and `(-0.06,-0.06,0)` meters. White margins are excluded.
The perspective intersection of the diagonals gives its center; an arithmetic
average of image corners generally does not.

The older EEPROM resize query returned `fx = fy = 573.6919` pixels. The actual
stream instead reports `fx = fy = 488.8263`. This is explained by framing,
rather than by selecting the focal length that makes a fit look better:

```text
Actual RGB source size: 1352 x 1012 pixels

K_source = [ 1032.645508       0          675.277710 ]
           [     0        1032.645508    515.993896 ]
           [     0            0               1    ]

T_image  = [ 0.473372787      0                0    ]
           [     0        0.473372787    -39.526627 ]
           [     0            0                1   ]

K_frame = T_image K_source
        = [ 488.826294       0          319.658081 ]
          [     0        488.826294     204.730835 ]
          [     0            0               1    ]
```

The source is binned sensor imagery, cropped vertically and resized to
640 x 400. The measured matrix product matches the frame metadata within
0.000012 pixel. The 573-pixel query describes a different crop of the factory
3840 x 2160 calibration window. It must not replace the actual frame matrix.
[Luxonis image-transformation API](https://raw.githubusercontent.com/luxonis/depthai-core/main/include/depthai/common/ImgTransformations.hpp).

With factory principal point and square pixels held fixed, independent
known-square image fitting estimates focal length 485.57 pixels. The reported
488.83 matrix gives 0.1173-pixel held-out per-corner reprojection RMS, versus
0.4163 with the substituted 573.69 matrix. Freely fitting principal point and
both focal lengths remains sensitive: perturbing corners by only 0.1 pixel
produces materially different intrinsic solutions. These perturbation ranges
are sensitivity experiments, not hardware confidence intervals.

### Subpixel QR measurements and repeatability

The offline refinement matches the exact printed 21-module QR pattern using
an ECC homography. It accounts for raster pixel centers versus physical module
boundaries and retains source/image hashes. Bad matches are rejected; original
captures are never overwritten. Rejected observations remain explicitly marked
as raw in diagnostic copies.

For the 84-frame multi-posture capture, within-hold corner RMS changed from
0.424 pixel with Vision rectangles to 0.0325 pixel after template matching.
For the 27-frame upper-neck capture it changed from 0.313 to 0.0335 pixel.
Returning to an earlier commanded pose still produced approximately 1.8 to
2.7 pixels of displacement. That remaining revisit error cannot be removed by
claiming more precise image corners; it includes physical repeatability and
other unmodeled effects.

The isolated upper sweep trains its line on the first visit to each target and
validates on subsequent returns:

| Measurement | Degrees per target unit | Multiple of nominal 0.030 | Return RMS |
| --- | ---: | ---: | ---: |
| Original QR corners | 0.056704 | 1.890 | 0.515 degrees |
| Refined QR corners | 0.055441 | 1.848 | 0.292 degrees |
| Refined-ROI depth-plane angle | 0.056237 | 1.875 | 0.495 degrees |

The QR and depth branches share intrinsics, so their agreement is not an
independent physical angle measurement. No scale in this table has been
applied to the servo driver or URDF.

### Joint neck fitting

The canonical URDF and Swift joint signs define the camera chain:

```text
C_i = A Ry(g_L c (L_i - 6011)) B Rz(g_P p_i pi/180)
        D Ry(-g_U c (U_i - 6906)) X
c   = pi/6000 radians per raw target unit
u_ik = project(K_i, inverse(C_i) M P_k)
```

`A`, `B` and `D` are the URDF origins and reference-body transforms. The fitted
variables are three positive angle scales, the six-parameter camera mounting
transform `X`, and the six-parameter fixed-target pose `M`. This gives 15
parameters for one target. Raw servo zeros 6011/6906 and pan zero are stated
conventions, not newly measured mechanical zeros.

Each distinct training command pose has equal total weight. For `n` repeated
frames at that pose, coordinate residuals are multiplied by `1/sqrt(n)`. The
solver minimizes a Huber loss with delta 2 in those scaled coordinates. Whole
command poses are held out; duplicate poses cannot appear in both splits.
Depth never forces the RGB fit to agree with an incompatible range reading.

For the 82 accepted refined observations, the primary fixed-frame-intrinsics
fit used 13 distinct training poses and 7 held-out poses. Nominal command
ranges were 16.02 degrees in pan, 12.00 in lower neck and 11.25 in upper neck.
It returned conditional gains `g_P=1.660842`, `g_L=1.912592`, `g_U=2.037229`,
with training/held-out corner RMS 3.476/3.455 pixels. The per-pose PnP target
translation drift was 7.65/9.30 mm, while the center-depth disagreement was
48.54/44.58 mm.

An independent SciPy implementation of the same objective agreed with the
dependency-free solver within 0.00000086 in its parameter vector. That checks
the numerical optimizer; it does not validate the assumed robot geometry.
The local Jacobian had rank 15/15 and condition number about 450 under fixed
intrinsics and joint geometry. Its residual-based covariance is explicitly
conditional and must not be reported as physical calibration uncertainty.

The shared kinematic fit remains much worse than independently fitting each
image's QR pose. Adding quadratic command maps lowered training error but
worsened held-out error to 3.816 pixels. Small joint-axis corrections reached
their bounds and produced near-gauge condition numbers around 1e6 to 1e7.
Those extensions are evidence against choosing a more flexible model solely
for its training residual.

### What the images cannot identify separately

An upper-zero change can be absorbed exactly into the camera mount:

```text
Ry(q_U + alpha) X' = Ry(q_U) X, where X' = Ry(-alpha) X.
```

A lower-zero change applies a common rigid transform to every camera pose,
which is absorbed by the unknown target pose in the base frame. A pan-zero
change has a similar ambiguity when lower neck is fixed; varying the lower
neck can break that particular ambiguity when joint axes are fixed.

Consequently, a fixed QR can identify a useful composite camera-motion chain
without uniquely identifying every mechanical zero and mounting offset.
Floor/wall observations, measured gravity and external angle/distance checks
add independent constraints. Even a numerically full-rank fit with fixed
intrinsics does not remove uncertainty in those fixed assumptions.

### Stereo-depth checks

The same held neck pose was tested with eight isolated camera configurations,
ten frames each, without neck or arm commands. On the confirmed RVC2 device:

| Alignment path | QR-plane center Z | Frame SD | RGB-minus-depth Z |
| --- | ---: | ---: | ---: |
| ImageAlign, requested undistortion | 683.188 mm | 0.557 mm | -50.562 mm |
| StereoDepth.inputAlignTo, requested undistortion | 674.284 mm | 0.431 mm | -41.641 mm |

The documented RVC2 StereoDepth alignment path also improved local plane RMS
from 2.526 to 1.814 mm and RGB/depth normal disagreement from 1.047 to 0.472
degrees. This is an approximately 8.9 mm improvement at one pose, not complete
metric calibration. Higher mono resolution, alternate filtering and the
calibrated-versus-spec baseline did not close the remaining gap.
[Luxonis platform-specific alignment example](https://docs.luxonis.com/software-v3/depthai/examples/image_align/depth_align).

The factory stereo baseline is 75.000 mm from design and 74.7488 mm from
calibration, only about 0.34% different. Under the better alignment path, the
known 120 mm square reconstructs as edges 127.95, 128.81, 127.83 and 128.18 mm.
A conditional scale of 0.9361 would match those lengths; this is a diagnostic,
not an independently validated sensor correction. Jointly freeing intrinsics,
depth scale and bias is ill conditioned on the current data.

Raw depth also contains outliers. An unfiltered pixel/ROI range near 7.17 m
was observed in one earlier frame; it was not an accepted application center
depth. Accepted center samples use the existing range/count gate. A locally
flat or low-noise patch must not be equated with accurate distance.

### Independent inertial angle observations

The camera reports a BNO086 IMU and a factory IMU-to-RGB rotation
`diag(1,-1,-1)`. A stationary raw-accelerometer/gyroscope prototype produced
555 post-warmup samples: mean acceleration `[-0.0776,6.6967,6.8012] m/s^2`,
per-axis SD approximately 0.013 m/s^2, and gyro norm approximately 0.0042 rad/s.
The raw acceleration magnitude was 9.545 m/s^2; it has not been forced to 9.81.

The capture records a timestamped stationary accelerometer mean, its scatter,
gyro, source axes and factory rotation. It is an estimated gravity direction
under stationarity, with unknown raw bias/scale. Relative pitch changes can be
checked independently of RGB focal length. Absolute gravity sign/frame and
bias still require validation before using it as a world-orientation reference.
The SDK rejected simultaneous GRAVITY and ACCELEROMETER_RAW requests, so the
implementation uses raw acceleration plus gyro and an explicit host estimate.
[Luxonis IMU report and frame documentation](https://docs.luxonis.com/software-v3/depthai/depthai-components/nodes/imu).

## Four-target survey after ROB was repositioned

The operator placed the floor-left, floor-right and right-wall sheets, then
repositioned ROB for right-arm pickup access. The bucket is beside the left
floor marker and two cans are on the table around its QR. This is a **new
scene**: none of the previous fitted room coordinates were reused. These
layout descriptions are observations, not metric base-frame coordinates.

**Calibrate all four targets** confirms actual IDs in two fresh frames per
settled search view, first on a 35-view grid and then at more intervals if
needed. Discovery evidence has its own folder. Each target then gets its own
fixed-target capture, with stable actual-pose training splits across markers.
Both arms remain reserved against competing use; the routine sends no arm,
jaw or arm-grant command. The initial discovery found all four IDs, including
the right-floor target on the finer retry grid.

The new-scene results are saved in
[`four-target-survey-validation.json`](evidence/2026-10-23-neck-qr/four-target-survey-validation.json):

| Target | Captured holds | Samples | Stationary IMU samples | Outcome |
| --- | ---: | ---: | ---: | --- |
| Table | 37 | 111 | 110 | Complete capture; 109 passed exact-template refinement. |
| Left floor | 13 | 39 | 37 | Partial; ROB's arm obscures part of the printed code. |
| Right floor | 0 | 0 | 0 | ID confirmed in discovery; formal batch lost readability. |
| Right wall | 37 | 111 | 111 | Complete capture; 111 passed exact-template refinement. |

There are also 112 discovery RGB/depth/IMU observations. The floor-left payload
can decode despite partial occlusion, but the full-pattern measurement gate
correctly rejects those views. A decoded ID is not proof that four accurately
measured physical corners are available. New floor/wall print dimensions still
need checking against their rulers; only the original table symbol has an
explicit operator-confirmed 120 mm measurement.

### Independent upper-neck angle calculation

Wide-angle discovery samples permit an inertial calculation independent of
QR corners, RGB focal length and assumed accelerometer magnitude. For each
fixed pan/lower group, the raw accelerometer is modeled as:

```text
a(U) = b + u cos(s (U - U_ref)) + v sin(s (U - U_ref))
```

For a proposed common angle scale `s`, the three vector coefficients are solved
by linear least squares. The constant and ellipse coefficients absorb constant
bias and linear sensor-axis scale effects; `b` is not interpreted as pure
accelerometer bias. Repeated overlapping IMU windows are reduced to one median
observation per command level. Whole upper levels are withheld from fitting.

The wide-angle profile estimates approximately **0.05684 degrees per raw unit**,
or **1.895 times the 0.030 prior**. A local linearized uncertainty calculation
is conditional on this sinusoidal/ellipse model and must not be presented as
physical confidence. Regional upper-response estimates differ by approximately
10%, so one universal multiplier still needs testing for PWM nonlinearity and
direction-dependent repeatability.

The first inertial model comparison also favors placing pan before the pitch
rotations, instead of the canonical `Ry(lower) Rz(pan) Ry(upper)` orientation.
A shared table/wall pixel audit tested 32 fits: both planar pose branches for
each marker, four camera initializations, and two joint orders. Selecting by
training cost, held-out error improved from **15.95 to 4.38 pixels** under the
alternative ordering. Eight starts reproduced its fitted 20.145 mm camera-pivot
radius, inconsistent with the 155.6 mm CAD prior. The discrepancy persists across
the tested initializations. This is a mechanism/frame-order diagnostic, not an
accepted URDF reparenting or camera-to-arm registration.

The canonical visual-rig evidence itself labels the pan location and chain order
provisional because no pan sweep had been observed. Its lower-axis location was
inferred using sagittal/centerline assumptions and 156 mm spacing; upper shaft
direction and visual zero were also estimates. Those priors do not independently
verify the physical mechanism. Software channel mapping remains consistent:
channel 0 pan, channel 1 lower neck, channel 2 upper neck.

### Targeted retakes and remaining physical checks

**Measure selected target** can freshly reverify a saved command hint, keeps
recenter proposals separate from verified views, and uses smaller pan/lower
steps for floor sheets. Lost views get bounded checked reacquisition attempts
and unique retry sample IDs. Raw and partial evidence is retained. The command
hint is never treated as a remembered world pose.

That retry build is installed, but native window access subsequently returned
`cgWindowNotFound` for Cerebro and other applications. The targeted retake was
therefore not started. Offline calculations continued from saved observations.
No calibration-complete claim is made. On return, restore desktop access, move
the left-floor sheet out of the arm's sightline, and move the right-floor sheet
outside direct sunlight/glare with its entire symbol and quiet margin visible.
Both right-floor discovery images decoded but failed strict template corner
refinement, so their corners are not admitted as metric measurements. Verify all
printed rulers and symbol dimensions, then repeat the floor captures.

For the protractor check, measure the same camera housing/bracket against the
same level reference at each held target, including return visits. Also observe
whether the physical pan spindle stays vertical when the lower neck moves.
Measure the lower/upper shaft centers, pan axis and optical lens position before
replacing the canonical pivot geometry. A scaled room scan can then add a dense
independent world reference.

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
