# Physical right-arm recycling and fixed-head trials

The recycling executor now selects the physical arm explicitly. Physical right
is **L10 / gateway `left`**; physical left remains R11 / gateway `right`.
`right_recycle_can` attempts one can and `right_recycle_two_cans` attempts two
successive transfers. `right_recycle_three_cans` covers the three-can tabletop
trial under one task approval and stops immediately if a grasp is uncertain. Each can gets a fresh search, measured scene and complete
path review. One spoken or controller approval covers the described task.
A left-arm rehearsal session does not authorize the right task.

The right task may establish stationary measured holds on both arms, while only
the physical right arm receives trajectory targets. Deferred startup jaw setup
can finish without an arm-raising route when both arms are already measured
hanging and empty: deactivate at that existing pose, initialize the stationary
jaws and retain the ordinary startup checks. A raised arm is not silently
returned to initialize grippers.

## Model and calibration identity

The right model uses its actual URDF mount, `right_joint1` through
`right_joint7`, `right_tool` and right collision hulls. Its hanging reference is
the separately recorded right scan prior. It is not a reflected left trajectory
or a measured absolute seven-joint calibration. The previously exercised right
shoulder inspection endpoint `[1.05, -0.60, 0, 0, 0, 0, 0]` is a planning goal;
a fresh dynamic connector must clear the complete arm before reaching it.

Mapping fingerprints and saved reach files are side-specific. A measured
camera registration does not inherit the old provisional-frame left reach,
tabletop-height or bucket-release corrections. Missing measured-frame residuals
start at zero in measured robot XYZ. Explicit later corrections are saved under
`RightArmCalibration/RegisteredReach/<registration hash>.json`, bound to the
model, mapping, tool, registration and local XYZ region. They preserve the
historical `can-reach.json` file.

## Visual checks and changed targets

Before closing, a fresh detector observation and aligned depth must still agree
with the frozen can. A significant displacement stops closing. The task may
hold, reacquire and completely replan once under its existing approval; it does
not chase an unobserved target or continue toward its old position.

After closing, only the already-planned small vertical verification lift may
continue. Carrying and release require the visual verifier to support the grasp
from three advancing RGB-D observations at the exact registered head view.
The can texture must move coherently with the tool projected from measured arm
feedback while background anchors remain stationary. Failed or unknown evidence
stops the task in a hold. The executor does not automatically reopen a possible
payload or continue to the second can. Pixel evidence supports a grasp; it does
not measure jaw force or guarantee that the released can landed in the bucket.

Intentional contact is limited to the freshly measured can cylinder and the
selected tool or matching carried-object envelope, with frozen grasp/release
stages and exact map/frame provenance. It does not erase the can from the map
or exempt the table, another arm link, another can or unrelated unknown space.
The carried envelope is a tight oriented box derived from the observed cylinder
in the actual grasp tool frame, rather than an enlarged sphere.

## Separate empty right-arm probe

Ordinary right-arm travel still rejects a modeled hanging tool/tread overlap.
`right_estimated_preview` instead prepares one separate EMPTY-arm commissioning
experiment from fresh near-zero feedback. It passively captures the current
registered head view without moving the neck or arms. Stable active-mode
feedback is accepted only for this passive capture; moving-neck scans retain
their holding/inactive requirements.

`right_estimated_trial` requests one explicit physical-right approval for a
**4-second J2 −0.039 rad step, followed by hold**. Verified full-hull travel is
capped at 30 mm. Actual convex-hull support-plane clearance must never worsen
and must strictly improve each initial near-tread deficit. Occupied workspace
checks and the explicitly reviewed local unknown-space volume remain active.
It sends no jaw command, performs no automatic return and cannot chain another
probe from its endpoint. It does not satisfy the ordinary 30 mm tread clearance
or authorize a full grasp. Camera and joint-model errors remain explicitly
estimated until their measured observations validate them.
