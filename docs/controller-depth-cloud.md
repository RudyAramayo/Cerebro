# Controller scene depth cloud

The controller input scene projects aligned RGB-D points through the camera's
accepted neck command estimates. It does not assume that the head is level.

- Head camera and neck pivot origins come from the same pinned URDF reference
  as the ghost robot. Upper tilt, pan and lower tilt rotate the optical points
  around their respective pivots; upper/lower counter-rotation uses the existing
  neck calibration. At lower 6011 / upper 6306 / centered pan, the display uses
  an approximately −18° head pitch.
- Points, original robot and blue ghost share the AppKit robot's presentation
  scale and base transform. The belly camera stays attached to its body mount
  and is independent of head movement.
- Deprojection uses the aligned frame's `fx`, `fy`, `cx` and `cy` when valid.
  Missing calibration retains the previous 69° FOV estimate and is labeled
  **estimated intrinsics** in the scene HUD.
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

`bash Scripts/test-depth-cloud-projection.sh` exercises the production transform
without cameras or actuators: mount/scale placement, tilt/pan direction, a
stationary surface reconstructed across neck poses, fixed belly geometry and
invalid inputs. The signed macOS build and ghost-render fixture check the
integrated camera-frame and scene APIs.
