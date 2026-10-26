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

For the standing local can trial, an unknown-cell rejection during the initial
empty retreat now starts a bounded neck-only recovery before any arm mode,
trajectory or jaw command. The diagnostic identifies the actual link and voxel.
The planner projects the complete cell into candidate camera views, selects a
distinct view with additional parallax, waits for the normal neck settling
checks, and appends two advancing synchronized depth exposures. It retains the
same scene and every original obstacle return, then repeats the complete arm
review from fresh measured feedback. At most two additional views share a
30-second deadline and the original scan's 60-second acquisition bound.

This fallback does not run after arm travel, jaw setup, possible possession,
mode changes, Stop, feedback loss or a source/body/context change. Occupied
obstacles do not trigger it. Missing depth remains unknown; projecting a cell
inside the image does not prove visibility through ROB's own hardware. A depth
hole can therefore remain unresolved after both attempts. The private trial
recording gets a `coverage-recovery.json` audit with the attempted views,
before/after cell states and map fingerprints. Capture diagnostics also retain
bounded same-frame depth statistics for the projected cell region. None of
these records grants motion or claims camera-to-arm registration.
The adjacent `coverage-stages.log` records capture phases before and after
settling, seeding, each append, ROI inspection and freezing, so an aborted
process can be distinguished from an ordinary rejected observation.

Hardware-free validation uses `Tests/ROBLeftArmCoverageRecoveryRuntimeTests.py`,
`Tests/ROBWorkspaceBlockerCoverageCaptureRuntimeTests.py` and
`Scripts/test-workspace-depth-map.sh`. These exercise the actual recovery,
capture and mapper paths with inert camera/robot seams; they do not establish a
successful physical grasp.

After an interrupted job, possible possession remains separate from task
authorization. An actual written user observation that **both grippers are
empty** may be recorded using the sandbox's private empty-hand observation
template/import actions. The receipt binds the current app, campaign, exact
standing state, previous job and a unique expiring observation challenge. It
accepts the user's observation text and hash, records an immutable object-state
audit, and leaves the same campaign paused. It does not approve motion, start a
job, calibrate/open jaws, credit a transfer or replay a waypoint. Fresh feedback,
scene and complete path review still precede a later Run. A changed job/state,
replayed or stale observation, non-user source or active manipulation rejects
the import. This is an operator observation rather than a camera verification.

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
held head view without moving the neck or arms. Stable active-mode
feedback is accepted only for this passive capture; moving-neck scans retain
their holding/inactive requirements.

`right_estimated_trial` requests one explicit physical-right approval for a
**4-second two-joint outward retreat: J1 −0.030 rad and J2 −0.030 rad, followed by hold**. Verified full-hull travel is
capped at 30 mm. Actual convex-hull support-plane clearance must never worsen
and must strictly improve each initial near-tread deficit. Occupied workspace
checks and the explicitly reviewed local unknown-space volume remain active.
It sends no jaw command, performs no automatic return and cannot chain another
probe from its endpoint. It does not satisfy the ordinary 30 mm tread clearance
or authorize a full grasp. Camera and joint-model errors remain explicitly
estimated until their measured observations validate them.

The previous J2-only direction approached a retained table-margin cell by
0.732 mm. The replacement was derived from the actual occupied geometry and
then checked by the complete existing proof. A historical, read-only audit of
five TABLE frames at P6111/L6011/U6235 retained both raw and corrected depth
endpoints for every original frame through the production mapper, carved free
space only to the nearer return, and applied no measured self-mask. The
27,063 occupied cells remained intact. The two-joint proposal passed all
19 sampled poses with 27.248 mm maximum full-hull travel; all four initially
close occupied pairs moved monotonically farther away by 8.214–10.611 mm.
Tool/track signed separation improved from −6.713 to 18.862 mm and tool/idler
from −14.714 to 9.514 mm. These remain below ordinary 30 mm clearance.

The numerical audit artifact `rob-estimated-right-table-production-union-zeroD.json`
has SHA256 `fa32b06a42c4003b47c78f8d95128bf1e3503054271ee25addd2a33d1bf3767b`.
It uses an explicitly estimated neck model and pinned torso/base pose, not a
verified camera-to-arm registration. It is historical evidence, not live
admission: a new scene, unchanged body/head/camera context, freshly measured
joints, the complete proof and actual controller/spoken approval are required
before one physical retreat. Body motion invalidates even an unregistered
estimated map. No private images are published with this record.
