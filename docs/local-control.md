# Local robot control and overnight profiling

`Scripts/cerebroctl.py` talks directly to the running Cerebro app over a private
Unix socket. It uses the existing native executors and camera streams; no
accessibility extraction, extra video window, cloud request or new Amber
connection is involved. An LLM or a human script can use the same interface.

The app must be running. The local robot LAN, Amber gateway, camera services and
RPLidar remain necessary for their respective hardware operations. Internet is
not needed for this interface or the local mission loop. On-device vision model
weights and Python dependencies must already be installed.

## Observe first

```sh
Scripts/cerebroctl.py status
Scripts/cerebroctl.py camera.demand --params '{"front":true,"panorama":true,"seconds":120}'
Scripts/cerebroctl.py camera.frame --params '{"camera":"front","depth":true}'
Scripts/cerebroctl.py camera.frame --params '{"camera":"panorama"}'
Scripts/cerebroctl.py animation.list
Scripts/cerebroctl.py mission.status
```

`status` returns measured arm positions, currents, feedback ages, mode/status
values, torso state, current motion/mission status, visible windows and camera
throughput. `service_ms` measures handling after the main queue receives the
request; client round-trip timing also includes queueing and socket transfer.
It is not motor response time. `rpc_timings` retains the latest 120 timings per
operation. A submitted target is not measured arrival.

In a DEBUG build with Development Mode enabled, arm motor and gripper feedback
admission allows up to 1200 ms during stationary planning, jaw setup and motion.
This is the operator's October 30 debugging setting. Original packet timestamps,
pose/mode/current checks and Stop remain active. Mode-off and Release retain
250 ms active and 350 ms stationary limits. Other timing values are unchanged.

The torso UI timer retains its separate 500 ms debug / 250 ms normal interval;
it does not inherit the arm-feedback age. TIC freshness and watchdogs are unchanged.

`camera.demand` keeps the requested streams running for up to 120 seconds.
Renew it while needed. It neither points the neck nor moves another actuator.
It is separate from recording, task and UI demand, so expiry releases only this
interface's demand. Front observation uses the 640×400 realtime profile unless
another consumer needs a higher-priority profile. Insta360 retains its normal
panorama preview and decoding cost even with diagnostics closed.

Frame replies are saved as `rgb.jpg`, optional `depth-u16le.raw`, and
`metadata.json` under a private capture directory. `--output /path/to/capture`
selects another directory. Stdout contains paths and metadata, not image base64.
Use the RGB file as LLM image input and the raw depth plus intrinsics for local
geometry. Depth is unsigned 16-bit little-endian millimeters; zero is invalid.
RGB, depth and intrinsics come from the same frame. A snapshot is encoded only
on request; only the latest frame is retained and encodes never accumulate.

Front/belly timestamps remain the original capture times. Snapshot admission
defaults to 1200 ms and can be chosen from 50–2000 ms using `maximum_age_ms`.
This is an observation-download budget; it does not relax any motion admission
limit. Insta360's timestamp is decoder receipt, **not sensor exposure**. Its
stitched image has no depth or calibrated robot-relative yaw. Images do not
establish robot/camera registration or collision clearance.

## Explicit native commands

The following operations can actuate and should be issued only for the intended
physical task. They use the same native ownership, feedback, current, joint/rate
bounds and Stop paths as Cerebro. They do not ask for another spoken approval.

| Operation | Parameters and behavior |
| --- | --- |
| `motion.move` | `values`: sparse Animation Studio channels; `seconds`: 0.65–600. One coordinated linear clip from fresh native state. Omitted channels retain their values. |
| `animation.play` | Exact `sequence_id` and current `revision` from `animation.list`; freezes that saved sequence for native playback. |
| `arm.mode` | Physical `arm`: `left`/`right`; `action`: `position`/`deactivate`. CLI deactivation requires fresh measured hanging. |
| `gripper.command` | Physical `arm`, `action`: `hold`/`release`. Hold defaults to vendor intensity 2; optional `intensity` accepts 1 or 2. Release stays 10. No full-travel calibration or automatic force escalation. Accepted jaw dispatch is unverified travel/retention. |
| `neck.pose` | Integer `pan`, `lower`, `upper` Maestro targets through the native coupled neck gateway; returns submitted, not measured arrival. |
| `torso.configure` | `source`: `tic_counts`. Selects native count feedback without energizing, resetting the counter or asserting alignment. |
| `torso.reference` | `observed_degrees`: actual observed torso-to-base angle, −180…180, with fresh stopped feedback. Sets only the host's software reference. |
| `torso.turn` | `heading_degrees` relative to the tread base. Requires the native hardware mode/reference already configured, both-arm clearance and fresh feedback. Returns submitted, not arrived. |
| `mission.start` | Starts the native bounded local Recycle Cans loop described below. |
| `stop` | Cancels native mission, animation, arm and torso owners; stops base demand and holds active position-mode arms. Does not energize inactive arms. |

Arm channel names are `arm.right.j1` through `j7`, and `arm.left.j1` through
`j7`, in vendor **radians**. Physical RIGHT is Amber L10/gateway `left`; the CLI
handles this mapping. Other channels are `maestro.N` in quarter-microseconds,
`torso.heading` in degrees, and `lact.speed` in signed timed percent. Use the
canonical Animation Studio channel limits. Maestro 6–9 remain owned by Bubble
controls. LACT is timed output, not measured lean position.

The operator restored the previous can-grip intensity 2 on October 30 after
identifying startup jaw calibration as a possible cause of crushing. Automatic
startup calibration remains disabled by passive startup. Intensity is a vendor
command, not measured pressure; local camera observations must verify retention.
Explicit intensity 1 remains available, and a failed grasp does not automatically
escalate force.
`status.navigation` exposes authenticated SLAM pose and map freshness; those
fields alone do not certify a travel corridor.

For example, feed a reviewed sparse target file containing `values` and
`seconds` into `Scripts/cerebroctl.py motion.move --params -`. Do not substitute
saved hanging joint values for the operator's accepted camera alignment image.

Straight arm targets now use native segments up to four nominal seconds,
instead of splitting every trajectory into roughly 0.8-second pieces. A tested
3.2-second linear clip uses one native trajectory. Smooth authored curves,
corners, holds and LACT timing retain their separate treatment. Native rate
limits can lengthen arm travel; increasing speed does not bypass them. Actual
endpoint feedback and Stop remain active throughout.

## Native offline mission and remaining commissioning

### Overlap preparation with depth work

`Scripts/cerebro_prepare.py` sends one already-reviewed arm-only preparation
target through `motion.move` and processes selected RGB-D regions while that
trajectory runs. Both arms can share the same target. A single depth worker
samples at 2 Hz; it never queues frames behind a slow calculation. Status and
the native feedback/current/settling guards remain active. No cloud call or
diagnostic window is needed.

The plan JSON contains `baseline` (all 14 freshly measured `arm.left.j1` through
`arm.right.j7` values), sparse target `values`, and `seconds`. Review the complete
path and surroundings before dispatch, as for any explicit local arm command.
This script does not certify a route or treat stored values as calibration.
The regions JSON maps names to `[x0, y0, x1, y1]` integer pixels in the fixed
front-camera view, with exclusive upper bounds. For example:

```sh
python3 Scripts/cerebro_prepare.py --plan /private/path/ready.json \
  --regions /private/path/can-regions.json --output /private/path/new-run \
  --maximum-age-ms 1200
```

Use 1200 ms only for the current debug workflow; the script defaults to 350 ms
and cannot relax native motion limits. Output contains original exposure times,
valid-depth fractions, range spread and optical-frame XYZ estimates. These are
region statistics, not detected object identities or calibrated robot targets.
An arm can occlude a region while it moves. The final handoff therefore uses a
new exposure after native measured completion, without an arbitrary settling
sleep. Changed camera streams, app/gateway sessions, neck targets, torso counts
or arm feedback invalidate the run. SLAM updates are recorded separately; an
optical depth calculation does not use or validate a world-frame transform.
Lost motor replies are never retried; an owned unfinished operation is stopped,
and a manual takeover is preserved. Camera reads can retry a shared encoder's
busy response for up to 1.2 seconds without queuing more work.

`events.jsonl` separates overlapping depth calculations from motion completion.
The final RGB-D files and `result.json` are ready for the next local calculation
or visual inspection. No subsequent arm target or jaw command is dispatched.
This preparation tool is available now; it is not yet wired into the native
Recycle Cans mission state machine and does not claim autonomous grasp success.

One explicit local command can own the bounded mission after the CLI exits:

```sh
Scripts/cerebroctl.py mission.start --params '{"maximum_cans":4,"duration_seconds":1800,"radius_meters":5,"maximum_tread_demand":0.4}'
```

The command starts work and can move hardware. It uses the existing local map,
search, can-targeted base repositioning and stationary right-arm transfer
executor. Both arms must already be in a checked raised working pose for base
or torso travel; this entry point does not automatically raise hanging arms.
The local loop does not depend on a connected phone or a cloud LLM
heartbeat. Remote-controller missions retain their own authenticated ownership.
Sleep/restart, Stop, manual takeover and failed runtime checks end the current
run; the old route never automatically replays. Status includes per-phase time.

**The complete room-wide carry-to-a-distant-bucket route and paired-arm pickup
are not commissioned.** This update does not wire a held-can transport phase
into the mission. The executor can pause when the bucket is unreachable or
possession is uncertain. `remote_bucket_transport_commissioned` stays false.
Offline control fixtures are not evidence of a physically successful transfer.

`mission.plan` provides a read-only torso-first shuttle proposal:

```sh
Scripts/cerebroctl.py mission.plan --params '{"table_x":0.5,"table_y":0.1,"bucket_x":-0.5,"bucket_y":0.1,"heading_degrees":0}'
```

Coordinates are meters in the tread-base frame. The proposal uses a coarse
reach annulus and ready-tool bearing, labels them as estimates, prefers a shared
base anchor, and reverses debug torso travel to unwind cables. It is explicitly
`executable=false` and `collision_checked=false`. Full arm/payload clearance,
table height, fused lidar/RGB-D travel routes, grasp possession and bucket
opening must be observed for execution. It does not infer a safe drive distance
from tread percent or reset the torso counter.

For an inactive mission whose payload uncertainty has been physically resolved,
`mission.confirm_empty` accepts its exact `mission_id`. This records the local
operator's observation only; it sends no jaw command and adds no transfer credit.

## Quiet, passive overnight operation

The **Servos** menu opens **Torso Servo Controls…** (arms, Maestro channels and
Animation Studio) and **Torso Rotation…** (stepper power, alignment and motion).
Reopening the servo panel reuses its existing controls and edits. These windows
remain available when automatic diagnostic windows are suppressed.

```sh
Scripts/cerebroctl.py runtime.profile --params '{"quiet_diagnostics":true,"passive_startup":true}'
python3 Scripts/profile-robot-runtime.py --hours 10 --interval 30 --camera-profile both --output '/path/to/private/samples.jsonl'
```

Quiet mode closes selected diagnostic windows and suppresses their automatic
opening on the next launch. Hidden Amber diagnostics skip redraw work. Arm
consoles retain a 4096-character live tail and bounded backing buffers; full
controller logs remain on Amber. Camera/task consumers run independently.

Passive hardware startup is also in **Settings → Arms and motion**. It skips
automatic neck/mount positioning, jaw setup and arm startup offers at launch or
reconnect. Relay OFF outputs remain active. Explicit local controls and explicit
stationary empty-jaw setup still work normally. Changing the preference does not
move anything or stop an already-running task; use Stop for that. It can be set
before launch with:

```sh
defaults write com.orbitusrobotics.Cerebro ROBPassiveHardwareStartup -bool YES
defaults write com.orbitusrobotics.Cerebro ROBLowOverheadDiagnostics -bool YES
```

The sampler has a hard duration limit of 12 hours (10 by default), renews camera
demand and records status, process CPU/RSS, uptime, stream ages/FPS and errors.
It sends **no motor commands** and does not save continuous video. `both` keeps
front RGB-D and Insta360 in the measured processing load. It cannot measure
electrical watts or guarantee that the supply stays on. A power loss stops the
logger too; its final record and subsequent boot time bound the interruption.
Run it as a detached process when it must outlive a terminal/LLM session.

## Protocol and validation

The socket is `~/Library/Application Support/Cerebro/LocalControl/control.sock`.
Its directory is 0700, the socket 0600, and peer UID must match Cerebro. There is
no TCP listener or arbitrary shell operation. Requests are versioned JSON lines,
at most 32 KiB, with UUID ID, original send time and an operation allowlist.
Mutations bind to the current app-launch token; duplicate IDs and expired
requests are rejected. The CLI gets the token automatically. Stop requires no
token or preliminary status request. A lost mutation reply is never retried:
query status to resolve the outcome.

`bash Scripts/test-local-control.sh` exercises the production policy, real Unix
socket and Python CLI with inert dispatch, plus actual JPEG/depth encoding of
synthetic frames. Animation, mission and scan-staging fixtures cover longer
linear trajectories, disconnected-controller local mission ownership, measured
endpoint gates, unknown-map rejection and the original settling fallback.
Gripper startup and Bubble fixtures verify passive reconnect and explicit
controls separately. Hardware commissioning remains a separate daytime test.

The October 29 passive live check used the installed optimized Debug build with
both cameras running and the arms inactive. Twenty status calls had a median
1.11 ms client round trip; four front RGB-D snapshots had a 13.75 ms median and
four panorama snapshots 3.01 ms. All succeeded. These are a short local sample,
not a sustained throughput guarantee or measured movement/transfer duration.
Private images, per-call measurements and overnight logs stay under the local
control support directory, outside Git.
