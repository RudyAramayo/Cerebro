# Controller scene depth cloud

The controller input scene projects aligned RGB-D points through the camera's
accepted neck command estimates. It does not assume that the head is level.

- The original robot's lower neck, pan, upper neck and attached camera meshes
  follow accepted neck command estimates. The untouched blue head follows the
  same pose; explicitly edited ghost neck angles remain preview-only overrides.
- Rob confirmed lower **6011 / upper 6906** as the physical upright neck and
  forward, level front-camera reference. The display estimator uses that pair
  explicitly; it does not take its reference from the driver's safety settings.
  The current values coincide, so joint FK and camera projection are unchanged.
- The captured scan has visible neck lean even at zero joint angles. The blue
  ghost uses approximate mechanical reference shapes for the lower neck, pan,
  upper neck, Insta housing and OAK housing/lenses on those same joint frames.
  Its Insta mount has a separate 20° backward visual tilt. The original scan
  remains intact, and the OAK optical frame is independent of that visual tilt.
  These shapes clarify the preview; measured hardware calibration stays queued.
  The confirmed reference and rejected intermediate candidate are recorded in
  [evidence](calibration/evidence/2026-10-21-flat-floor/neck-reference-preview.json),
  with a [model-only comparison](calibration/evidence/2026-10-21-flat-floor/neck-reference-preview.png).
  Final visual acceptance of the loaded preview remains pending.
- The optical transform comes directly from that articulated URDF camera frame.
  The cloud uses the same joint FK, optical mount, basis and presentation scale,
  without a separate pivot rotation. Accepted upright lower 6011 and level upper
  6906 map to zero URDF neck angles. The captured lean-back scan's lower/upper
  reference rotations are no longer retained at upright. Each accepted joint
  target moves its own model joint; optional camera-leveling compensation does
  not set the display mapping or suppress lower-neck movement. The lower neck
  maps increasing Maestro targets to positive URDF rotation; the upper neck
  maps increasing targets to negative rotation. Their opposing mechanical
  directions previously both used a negative sign, incorrectly adding the
  angles. At L7014/U7790 that placed the camera about 56.6° upward instead of
  3.6° downward, consistent with Rob's forward wall view. Both mesh neck joints
  and the optical frame use this corrected mapping. The 33.333-targets/degree
  scale and upright references are retained. At lower
  6011 / upper 6306 / centered pan the optical axis points approximately 18°
  down. These are display mapping priors, not newly measured camera calibration.
- Points, original robot and blue ghost share the AppKit robot's presentation
  scale and base transform. The belly camera stays attached to its body mount
  and is independent of head movement.
- Rob identified the wooden floor as a calibrated flat reference. Each fresh
  head/belly cloud now fits a near-ground plane in physical metres, then applies
  one rigid rotation and vertical translation to the entire cloud so that plane
  coincides with the scene's `y=0` floor. The display's 1.2 scale is removed for
  fitting and reapplied before the existing robot-to-world transform. Object
  shapes, pairwise distances, floor-relative heights and measured depth noise
  remain intact; points are not individually flattened or stretched.
  Candidates come from the lower image and outside the robot footprint. Their
  raw height must be compatible with a floor intercept within 0.35 m and tilt
  within 30°: `abs(y) <= 0.35 + horizontalRadius * tan(30°)`. This admits a tilted
  floor before fitting it. The original fixed ±0.30 m band reduced the live
  belly floor to a 14 cm strip and prevented alignment. The plane's angle,
  height, coverage and support bounds remain unchanged. The live wooden floor
  measured 9.0–9.1 mm residual RMS, so this display uses a 10 mm RMS noise budget
  instead of the pure fitter's 9 mm default. Bounded RANSAC and covariance refitting reject
  insufficient coverage/support, walls, elevated planes, excessive residual
  noise and competing floor levels. Geometry does not identify wood or prove
  that a low surface is the floor; the operator's flat-floor assumption and
  near-ground gates are required. Before the first accepted fit, insufficient
  evidence leaves a labeled raw cloud. Once a camera has aligned, rejected
  frames never automatically replace its cloud with raw points. Belly noise
  rejection can retain its actual accepted geometry for at most 250 ms;
  other belly rejections discard it immediately. At Rob's request, the head
  cloud keeps its last published geometry without an age expiry, until a new
  publishable frame replaces it. Neck movement/settling, missing/stale/invalid
  input and rejected floor fits leave those captured vertices visible.
  These retained head vertices stay fixed at their original world-space capture
  position; newer neck commands move the model, not the old points. The HUD
  labels this **HEAD DEPTH HELD: … s old · fixed at capture pose · display
  history**, showing its actual capture age to 0.1 s. A fresh settled
  frame can replace it; failed input never renews its timestamp or applies an
  old plane to new points. Belly's existing expiry timers still run without
  incoming frames. Arm operations or a changed base transform clear both
  clouds immediately; they remain hidden until new publishable data arrives.
  The historical head cloud is visual only and provides no motion, collision
  or force authority. See [persistent-display evidence](calibration/evidence/2026-10-21-flat-floor/head-persistent-display.json).
  The HUD retains the rejection reason and reports
  held-frame age or hidden state, with RMS to 0.1 mm. A valid fit shows support,
  residual RMS and angular correction for each camera.
  Fits are per-frame: a correction is never applied to another frame after
  changing the view or losing visible floor. Existing camera/neck freshness checks remain, and a
  changed diagnostic base transform rejects a result prepared at an old pose.
  The point display is capped at 20,000 points and fitting at 2,048 candidates.
  This is a display alignment, not persisted camera/URDF calibration or actuator
  collision/force evidence. The original depth frames are unchanged.
- Deprojection uses the aligned frame's `fx`, `fy`, `cx` and `cy` when valid.
  Missing calibration retains the previous 69° FOV estimate and is labeled
  **estimated intrinsics** in the scene HUD.
- Display work is capped at 30 scene frames/second and eight cloud submissions
  per second per camera. Unchanged mesh transforms do not start transactions;
  requesting execution captures an embedded snapshot and hides the live 3D view
  until the operation ends. Once the neck has settled during camera preparation,
  that picture is refreshed once before arm position entry or travel. This fixes
  the earlier picture retaining the preapproval neck angle through the motion.
  It also applies when an operation starts in Arms settings. Accepted command
  changes still update only the five head-chain transforms underneath the static
  picture; arm mesh updates and cloud submissions remain suspended. No repeated
  snapshots compete with the arm watchdog. The sidebar separately displays the
  current accepted lower/upper targets and the optical tilt from the same FK,
  rather than using an older depth frame's direction. The same window remains
  open; live 3D resumes after completion,
  refusal or interruption. Camera capture, encoder monitoring and the motion
  watchdog retain their own timing.
- A frame must follow the neck's conservative command settling time. Frame
  capture timestamps are mapped to the host monotonic clock; absent or unusable
  timestamps get a conservative 400 ms allowance. Old frames do not become
  fresh because they arrive late. Frames older than 700 ms, unknown/off neck
  commands, changed targets during projection, invalid depth buffers and missing
  mount data cannot publish new head geometry. A previously published head
  frame remains visible at its capture pose until replacement or an arm/base
  clear, as described above. This does not admit stale frames as new geometry;
  no fabricated horizontal pose is used.

The Maestro provides commanded targets rather than measured shaft feedback.
The HUD therefore labels this **neck command estimate / URDF mount prior**.
This change sends no servo commands and changes no URDF origin or link length.
Camera extrinsics, mounting/zero errors, timing uncertainty and held-out pose
validation remain in the [deferred calibration task](arm-motion-work-queue.md).

`bash Scripts/test-ghost-motion.sh` checks articulated level/down/pan directions,
upright joint zeros, independent lower-neck rotation/pivot displacement, fixed
belly geometry and invalid commands.
`bash Scripts/test-depth-cloud-projection.sh` checks optical axes, scale,
stationary surface round trips and invalid affine transforms. The render fixture
also verifies that the cloud origin equals the rendered head's optical mount
and that untouched ghost link transforms match the original. It also checks the
blue reference axes and OAK lenses against that shared camera frame. All fixtures are isolated
from cameras and actuators. The signed macOS build checks integration.
`bash Scripts/test-depth-floor-rectification.sh` checks noisy tilted floors,
outliers, rigid distance/height preservation, sparse/line/wall/table/ambiguous
plane rejection, numerical inputs and bounded sampling without camera access.
`python3 Tests/ROBDepthFloorIntegrationRuntimeTests.py` compiles the actual
frame-processing and visibility methods with inert application state. It verifies
physical scale, 8°/25°/29° floors, preserved object heights, elevated tabletop
rejection, RGB indexing, the point cap, persistent captured head geometry,
fresh-frame admission, unchanged belly expiry, arm/base clears and initial
raw-cloud fallback without hardware.
