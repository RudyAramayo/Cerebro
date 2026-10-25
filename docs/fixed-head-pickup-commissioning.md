# Fixed-head pickup commissioning

The sandbox separates a measured camera view from a general neck calibration.
One validated view can support a local experiment without claiming that every
neck angle or arm encoder offset is commissioned.

## Optional runtime stereo calibration

The camera worker can load a device-specific stereo correction into **RAM** at
startup. It does not flash EEPROM, rescale depth or change RGB intrinsics,
distortion, focus, the right-camera-to-RGB anchor, IMU data or specification
translations. The approved changes are the raw left-to-right rotation and
translation plus the two stored rectification rotations. The loader checks the
original B→C→A camera graph, unchanged unrelated fields, proper bounded rotations
and translations, and consistency between the raw pair and rectification.

Keep profiles, requested calibration JSON and commissioning evidence outside the
repository. The worker reads this activation pointer once; restart the camera
worker after changing it:

`~/Library/Application Support/Cerebro/DepthCamera/RuntimeStereoCalibration/{role}-active.json`

The pointer has `schemaVersion: 1`, `kind: "runtime_stereo_calibration_activation"`,
`cameraRole`, an absolute `profilePath`, and that immutable file's `profileSHA256`.
The referenced profile has these required fields:

| Field | Required value |
| --- | --- |
| `schemaVersion`, `kind` | `1`, `runtime_stereo_calibration_profile` |
| `cameraRole`, `actualDeviceMXID` | Exact camera role and device |
| `platform`, `sdkVersion` | `RVC2`, `3.8.0` |
| `factoryEEPROMSHA256` | SHA256 of the original EEPROM JSON export bytes |
| `requestedCalibrationPath`, `requestedCalibrationSHA256` | Absolute immutable JSON path and byte SHA256 |
| `requestedCalibrationSemanticSHA256` | SHA256 after normalizing `cameraData` to a socket-keyed object |
| `candidateSHA256` | SHA256 of the approved candidate evidence |
| `validationEvidencePath`, `validationEvidenceSHA256` | Absolute commissioning-summary path and byte SHA256 |

Calibration exports and semantic canonicalization use sorted keys, two-space
indentation and a final newline; semantic canonicalization first normalizes
only the camera-table ordering. File hashes always pin the actual saved bytes.
The summary records measured results and their
limits; pinning it does not create a global metric pass or arm authorization.

A missing or rejected profile sends no calibration override. Diagnostics call
the observed data **FACTORY** only when it equals EEPROM; an unrelated prior RAM
calibration remains identified as **OBSERVED_EXISTING_RUNTIME**. Both paths
retain actual effective-runtime provenance. Once an override is attempted, an
apply/readback mismatch aborts capture and restores the prior effective RAM
calibration rather than silently continuing. Restoration and unchanged EEPROM
are checked **before** pipeline teardown, because SDK 3.8 closes the device when
the pipeline stops.

Auto-calibration is explicitly OFF for factory and profile workers. An applied
profile also explicitly disables all three specification-translation policies.
The packet's `runtime_calibration` binds device, role, SDK, factory EEPROM hash,
effective-runtime semantic hash, actual HOST stereo-policy hash and optional
candidate/profile hashes. `runtime_calibration_identity` hashes the prefix
`runtime-camera-calibration-v1` followed by those eight fields in that order,
joined by LF with no final LF; absent candidate/profile values use `-`. HOST
configuration is not a firmware-strategy observation. Identity changes start a
new camera generation and invalidate dependent scenes and registrations.

The October 24 single-RGB, RGB-aligned 640×400 standard-stereo TABLE check still
measured a **+10.7–12.7 mm center optical-Z residual** against the 120 mm RGB
target pose. No constant correction was applied. Preserve this local residual
in the commissioning uncertainty; do not generalize it to another range or
view. Correcting stereo geometry does not establish camera-to-body or
camera-to-arm registration. A fresh independently validated body reference and
ordinary path admission remain necessary, and this camera test claims no grasp
or bucket-delivery success.

A later check at P6015/L6411/U5813 found a larger off-axis error on the
120 mm left-floor square: standard depth read its center 54.5–55.6 mm farther
than RGB PnP at approximately 1.03 m. Subpixel reduced depth banding but did not
remove that bias. The central table result therefore does not validate the
image field or nearby body surfaces. Body registration remains unaccepted;
native stereo and RGB alignment are being checked separately. No uniform depth
scale or arm-registration exemption was applied.

CPU-only profile, identity and restoration fixtures run with
`python3 -B Scripts/test-runtime-stereo-calibration.py` in the calibration Python
environment. They do not open a camera or actuate ROB.

## Capture and registration

Open **Testing Sandbox → Camera-to-arm registration → Open fixed-head
calibration**. Choose the physical arm whose model mapping will be used. Hold a
head view containing visible base-fixed and torso surfaces and choose **Capture
+ fit current head pose**. This captures five actual RGB-D frames after a
one-second delivered-frame warmup. It never activates, positions or calibrates
an arm. Both arms are reserved against competing operations during acquisition.

The automatic fitter uses the pinned robot CAD only as a physical surface
reference and initial pose hypothesis. It fits distinct spatial patches on the
first frame, checks separate patches on later frames, compares optimizer
starts, and evaluates six-degree-of-freedom observability. A planar or ambiguous
view, missing depth, excessive residuals or unstable fit produces a diagnostic
result rather than an executable transform.

The explicit CAD reference uncertainty is an assumption supplied to the test;
the image residual cannot measure manufacturing or CAD error. The default
allowance is 20 mm. The Swift validator independently recomputes the transform,
held-out errors and delete-one sensitivity over the requested local volume.
It rejects a total allowance above 50 mm. These are conditional engineering
allowances, not statistical confidence or proof of perfect grasp precision.

The saved measurement binds exact raw pan/lower/upper targets, model and
geometry hashes, physical-arm mapping, camera and gateway generations,
intrinsics and manual display-correction identity. Moving outside that scope
requires another measurement. Raw aligned depth uses the fitted optical-to-robot
matrix directly; the provisional display translation/pitch is not applied again.
Registered search retains the exact measured pan, lower and upper targets.
It waits for fresh frames without invoking legacy neck preparation or broadening
one pose into a neck sweep. Losing that registration blocks the fixed search.

Private captures and recomputable input artifacts are under
`~/Library/Application Support/Cerebro/FixedHeadRegistration/`. RGB and raw depth
stay local. A saved input is refitted on load; a `verified` label cannot create
registration authority. Calibration does not create an arm-motion grant.

## Right-arm recycling

**Recycle can · right arm** selects physical right, Amber L10 / gateway `left`.
The model uses the right URDF joints, hulls, tool and independent mapping prior.
It never reflects a left trajectory or inherits left reach residuals. The
remaining encoder mapping is explicitly a prior; visual commissioning must
establish actual accuracy before claiming a general arm calibration.

Set **Number of cans** to a whole number from **1 through 8**, then run the
selected recycling test. One approval covers the stated complete batch: both
arms may enter stationary holds at their current measured positions, and only
the selected right arm travels. The spoken prompt remains **“Can I move my arms?”**.
Each can receives fresh observation, depth, scene admission and a reviewed path.
An existing left-only session cannot authorize the right task. A failure or
uncertain grasp stops the batch in a hold before the next reach. Existing time,
feedback, scene and Stop limits still apply. A completed transfer path records a
commanded gravity release; it does not by itself verify landing inside the bin.

The count-based API commands are `left_recycle_cans` and `right_recycle_cans`,
with the decimal count supplied in `target`. Existing one-can, two-can and
right-three-can command names retain their original counts.

The can's visible wall is distinguished from its estimated cylinder axis. Side
grasp geometry uses measured top, middle and bottom bands plus a radius offset
away from the camera. Intentional contact applies only to the selected tool and
carried object, inside the identified can cylinder and authorized route stages.
It does not remove table returns, hide another obstacle, waive other-link
clearance or make unobserved space free. See [intentional can contact](intentional-can-contact.md).

## Live grasp evidence and moving targets

Immediately before closing, the task uniquely reacquires the selected can,
checks source-to-current image continuity and measures its current registered
3D sections. A displacement greater than 12 mm invalidates the old close point.
The existing frozen approach is not silently changed while executing.

After closing, only the reviewed short verification lift may run. Carrying and
release require several advancing observations in which the can's texture,
image displacement and depth follow the measured tool, with stable background
and head pose. Occlusion, identity ambiguity or missing depth leaves possession
unknown and causes a hold. Pixel change alone is insufficient. This is visual
support for possession, not a jaw-position or force measurement. See
[visual grasp evidence](visual-grasp-evidence.md).

Following a continuously moving can needs a later receding-horizon controller:
short collision-checked motion increments, local target tracking, velocity and
latency bounds, and fresh alignment before closure. The present target-shift
veto prevents stale closure; it does not claim successful moving-target pursuit.
Useful trial metrics include perception-to-command latency, relative target/tool
error, motion-induced replans, grasp success and verified bucket delivery.

## Validation record

The tracked `CerebroCommissioning` Xcode scheme builds the signed local Debug
app without requiring a developer's private scheme. Its launch settings do not
silently enable cloud sessions or an action tool. This commissioning install is
not a production release or an update to public distribution channels.

For the physical trial, build with `SWIFT_OPTIMIZATION_LEVEL=-O`; runtime guards
and preconditions remain enabled. The right-probe fixture measured about 4.0
seconds to build the checked proof with optimization, versus 36.5 seconds at
`-Onone`. These are fixture timings. The runtime reuses an exact internally
verified immutable proof only while its map, model, resource hashes, measured
start and fixed-head context still match. Imported proofs retain full validation.

Record the actual capture result, installed binary hash, source commit, held-out
error allowance, physical trial observations and outcome separately from the
synthetic fixtures. Passing a fixture or a model path never proves that a can
was picked up or delivered.


### Physical camera check, 23 October 2026

The signed commissioning app enabled the face OAK-D Pro dot projector at 0.5,
with the flood LED and belly dot projector off. The reloaded worker recorded
both face SDK commands as accepted. Five frames per treatment at the same
P6000/L6011/U5300 pose and intrinsics increased mean native nonzero depth
coverage from 22.00% to 51.69%; a manually bounded body region increased from
2.00% to 49.70%. These are coverage measurements, not depth accuracy. Some floor
pixels gained implausibly near returns and the minimum valid depth stayed
316 mm. Extended disparity was not enabled.

Automatic registration at that pose and a second P6000/L6495/U5698 view did
not pass known base/torso surface admission. No measured transform was installed,
no physical arm trial executed, and no cans delivered in this commissioning
run. The remaining blocker is a genuinely validated optical-to-robot reference,
plus ordinary path admission from the modeled hanging pose.

The [numerical record](commissioning/2026-10-23-fixed-head-ir.json) contains input
and raw-depth hashes and the signed executable hash. Private RGB/depth captures
remain local.
