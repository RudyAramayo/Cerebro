# Controller scene depth cloud

The controller input scene projects aligned RGB-D points through the camera's
accepted neck command estimates. It does not assume that the head is level.

- The original robot's lower neck, pan, upper neck and attached camera meshes
  follow accepted neck command estimates. The untouched blue head follows the
  same pose; explicitly edited ghost neck angles remain preview-only overrides.
- The optical transform comes directly from that articulated URDF camera frame.
  The cloud uses the mesh's exact FK, optical mount, basis and presentation scale,
  without a separate pivot rotation. Accepted upright lower 6011 and level upper
  6906 map to zero URDF neck angles. The captured lean-back scan's lower/upper
  reference rotations are no longer retained at upright. Each accepted joint
  target moves its own model joint; optional camera-leveling compensation does
  not set the display mapping or suppress lower-neck movement. The existing
  mounting-direction and 33.333-targets/degree priors are retained. At lower
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
  Candidates come from the lower image, within 0.30 m of expected ground and
  outside the robot footprint. Bounded RANSAC and covariance refitting reject
  insufficient coverage/support, walls, elevated planes, excessive residual
  noise and competing floor levels. Geometry does not identify wood or prove
  that a low surface is the floor; the operator's flat-floor assumption and
  near-ground gates are required. With insufficient evidence the cloud stays
  raw, and the HUD gives the reason. A valid fit shows support, residual RMS and
  angular correction for each camera.
  Fits are per-frame: a correction is never reused after changing the view or
  losing visible floor. Existing camera/neck freshness checks remain, and a
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
  commands, motion in progress, changed targets during projection, invalid
  depth buffers and missing mount data hide the cloud instead of displaying
  a fabricated horizontal pose.

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
and that an untouched ghost head matches the original. All fixtures are isolated
from cameras and actuators. The signed macOS build checks integration.
`bash Scripts/test-depth-floor-rectification.sh` checks noisy tilted floors,
outliers, rigid distance/height preservation, sparse/line/wall/table/ambiguous
plane rejection, numerical inputs and bounded sampling without camera access.
`python3 Tests/ROBDepthFloorIntegrationRuntimeTests.py` compiles the actual
frame-processing method with inert application state. It verifies physical
scale, floor/object heights, RGB indexing, the point cap, stale-frame hiding,
changed neck/base pose rejection and raw-cloud fallback without hardware.
