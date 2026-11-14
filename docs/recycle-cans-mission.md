# Recycle Cans mission

Open **ROBController → Map → Missions → Recycle Cans**. The saved destination is
**Orange bucket**. Choose a search radius (1–10 m) and up to eight cans. Start
authorizes one 30-minute mission, with gentle acceleration and a 40% maximum
tread demand. It does not request another arm approval at each stop or waypoint.

The mission surveys the immediate right and left table areas, then uses the
existing right-arm recycling executor when it finds a can. If perception proves
that no arm or jaw command was sent and no payload is possible, it can move to
another observation stop and search again. Stops come from reachable free cells
in the accumulated RPLidar room map. The radius remains anchored to the initial
SLAM position; satellite-overlay rotation/scale and GPS are not used.

A visible but unreachable can now produces a **can-targeted base approach**,
not an unrelated exploration stop. The planner searches reachable floor cells
for a stopping pose and final base yaw that place the can beside the taught
horizontal ready gripper. It checks position IK at the observed can height,
uses the scanner's fixed offset, and keeps torso alignment separate from SLAM
base yaw. A pink route and final heading appear under **Controller Input Scene
→ Plan base approach to can**. This button only previews; it sends no motor command.

The proposal reports the torso correction to the tread-base front. Alignment
can come from live base-relative vision or an explicit stationary software base
reference in Torso Rotation. An uncertain raw TIC count alone is insufficient.
Both arms must be raised before that torso correction. Reacquire the can after
any torso/base motion; source timestamps are matched against SLAM history so a
manually moved base cannot reuse a can in the old frame. A new map revision
rechecks the displayed floor corridor. Elevated RGB-D clearance remains required
before live travel; a floor route is not a 3D clearance certificate.

Floor planning validates the selected can's own timestamp, enrolled depth frame,
camera, arm connection, projection and body identity. Older unrelated survey
frames do not expire that target early. This does not revive the collision map;
arm execution retains its complete-scene checks and reacquires before grasping.
The front-table ghost scan also recognizes a fresh position-mode grasp-ready
hold and skips the hanging-arm shoulder survey, keeping its captures on the table.
The completed preview keeps the task camera stream for at most 60 seconds, until
Stop, or until another operation takes it over. Finishing a survey therefore
does not immediately change resolution and invalidate its source. Observation
ages and all motion checks still apply during that preview period.

Tread rotation sensors are not connected. Travel progress is checked from SLAM,
with Gentle acceleration; PWM and elapsed time are not treated as odometry.

Movement checks the measured model envelope of both arms and the base, inflated
map clearance, live lidar and fresh RGB-D availability. Unknown cells remain
blocked. New grid revisions replan the route; SLAM jumps stop tread output and
trigger a fresh survey. Traction is measured from pose changes, not inferred
from PWM duration. The model envelope and RGB-D checks are not a certified
collision system or a measured mounting calibration.

Cerebro's [Controller Input Scene](controller-depth-cloud.md#room-map-and-laser-layers)
shows this same accumulated map and SLAM pose under the depth scan, with live
laser points at scanner height. It preserves the distinction between a lidar-free
floor cell and an elevated table obstacle. The overlay is diagnostic; it does not
replace the mission's depth admission with floor-map clearance.

The mission currently delegates **stationary can-to-bucket transfers** to the
native arm executor. It does not add a body-motion continuation while carrying
a can. If pickup leaves a possible payload or the destination cannot be reached
by that checked arm route, the mission holds and reports the native result.
The native executor still reports bucket landing as unverified; this result
pauses the mission and credits zero transfers. The mission advances its count
only when placement, empty jaws and transfer completion are all verified.
These are explicit manipulation capability limits, not additional permission
prompts. Room-wide pickup/carry/drop completion has not been physically validated.

**Stop and hold** cancels the native phase, replaces the cached tread command
with stopped/braked input and ends the grant. Manual tread/controller takeover,
disconnect, timeout, sleep or shutdown also end it. Reconnection restores status
and Stop access; it cannot replay the old path. A controller's explicit
**I inspected the gripper: it is empty** records an operator observation after
intervention; it cannot actuate, credit a transfer or resume a route.

## Transport and runtime

- `ROBRecycleMission.v1` carries bounded Start, Stop, query, status and explicit
  empty-gripper observations through authenticated operator sessions only.
  The server consumes these before legacy motor parsing and returns status only
  to the requesting peer. Duplicate/replayed Start messages cannot execute again.
- `ROBRoomMapFragment` copies the native SDK occupancy raster into 20,000-byte
  chunks within authenticated RLS2 scans. V1 scan encoding remains unchanged.
  Device identity, existing replay/freshness checks and the telemetry-only role
  remain enforced. Complete maps require matching epoch, revision, dimensions,
  resolution, origin and capture time; incomplete or mixed maps cannot plan.
- Update RPLidar and Cerebro together. An old Cerebro does not understand RLS2.
  The controller mission requires the new Cerebro runtime. Publishing a map
  never authorizes motion, and an app restart never starts a mission.

Run `bash Scripts/test-recycle-mission.sh` and
`bash Scripts/test-controller-arm-approval.sh`. Fixtures use socket-free adapters
for lifecycle tests, production map/scan/protocol codecs, metric route planning,
and the production arm approval broker. No fixture sends a hardware command.
