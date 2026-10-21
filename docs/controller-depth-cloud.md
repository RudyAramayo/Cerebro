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
- Deprojection uses the aligned frame's `fx`, `fy`, `cx` and `cy` when valid.
  Missing calibration retains the previous 69° FOV estimate and is labeled
  **estimated intrinsics** in the scene HUD.
- Display work is capped at 30 scene frames/second and eight cloud submissions
  per second per camera. Unchanged mesh transforms do not start transactions;
  requesting execution captures an embedded snapshot and hides the live 3D view
  until the operation ends. Physical motion also suspends cloud submissions and
  mesh updates. The same window remains open; live 3D resumes after completion,
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
