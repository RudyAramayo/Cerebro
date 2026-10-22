# Local recycling task and spoken arm sessions

Rob requested this experimental empty-Coke-can cleanup task on October 22, 2026.
It is implemented for the physical left arm (R11 / gateway `right`), with the
base stationary. Software validation is separate from live commissioning.

## Authorization and startup

Cerebro automatically prepares the saved Amber tunnel at launch and wake. A
late robot startup or transient network failure now retries telemetry with
2/4/8/16/30-second backoff; authentication/key/configuration failures remain
visible and do not loop. Disconnect and sleep cancel retries. Reconnection never
replays motion, preserves an old gateway generation, or restores jaw calibration.

Settings → Arms offers a 15-minute supervised left-arm rehearsal session.
Launch/wake offers this session once by default (the preference can be disabled).
ROB asks exactly “Can I move my arms?” and accepts one final local microphone
acknowledgement such as “yes, proceed,” or an authenticated iPhone/Vision Pro
approval. The complete pending scope remains in Settings/controller details. Accepting
the session prepares the empty left arm. Covered preparation, local searches,
reviewed gestures, empty-can recycling at intensity 2 and empty-arm lowering
then execute without additional approvals or Continue buttons. Standalone task
motions also accept one spoken or controller approval for the complete operation.
Rob additionally authorized empty-arm return to hanging without any new approval,
for both `left_relax` and paired `relax`. The registered reverse route, fresh
feedback, ownership, camera, deadline, Stop and measured hanging before torque-off
still apply. Already hanging inactive arms are not energized for a left return.

Spoken authorization is accepted only by SpeechBox's final on-device recognition
delegate while ROB is not speaking. A stable candidate endpoints the current
utterance after 750 ms so continuous dictation does not delay approval until its
minute-long timeout; only the resulting final transcript can grant it.
Partial recognition, typed/controller text,
serial transcripts, camera text, quoted/conditional acknowledgements and model
output cannot authorize. A pending scope expires after 90 seconds. Sessions are
memory-only, expire after 15 minutes and end on Stop, sleep/restart, ownership
loss or motion failure. A controller-authorized session retains controller
freshness; a microphone-authorized session does not require a connected phone.
There is no per-waypoint authorization. Diagnostics raw commands remain outside
the reusable session.

Local commands include “start an arm session,” “recycle the can,” “find the
orange bucket,” “check your arms are hanging,” “lower your left arm,” and
“end the arm session.” Stop remains immediate and revokes session authority.

## Search and pointing

`left_search_workspace` searches without activating or moving either arm and
does not require arm authorization, a gateway connection or arm CAN feedback.
`left_check_hanging` has the same neck-only admission and inspects hanging-arm
visibility independently; an unobserved arm is reported as unconfirmed, never
used to reset encoder zero. An inspection failure does not issue arm hold,
mode or jaw commands. An active/pending arm operation still owns the workspace.

The shared service sweeps 32 views through the normal mechanical envelope,
command ramps and manual-priority rules. Pan advances in 15-degree intervals,
with table, lower-workspace/floor and upper rows. It pauses 1.5 seconds after the
neck reports ready, then requires advancing fresh frames spanning at least
300 ms. This is a settling/focus allowance, not a measured focus guarantee.
Transient camera/view failures get one settled retry; delayed camera delivery
gets up to two seconds to advance, without changing capture timestamps.

Object search uses a dedicated offline OWLv2 detector, rather than asking a
generative model to write detections. The previous local VLM repeated the
all-absent example in 16 live observations despite a visible Coke can. The new
worker returns typed boxes and raw scores for cans/buckets and distractor
queries for mugs, bottles, keyboards and staplers. Native code uses a 0.35 raw
score threshold without inflating scores; VLM JSON cannot lower its own threshold.
Bucket queries include a general shape query because color-qualified text alone
was weak on the actual camera view. Every bucket candidate must also contain at
least 18% red/orange pixels (R ≥ 50, R > 1.25G, R > 1.5B); this rejects the nearby
blue container without lowering the raw model threshold. This appearance check
does not establish a bucket opening or release geometry.
The native service loads the model before capturing an image, matches request
IDs to results, bounds output and timeouts, and terminates cancelled inference.
It has no robot-control interface. Hanging inspection still uses local MLX.

Two distinct RGB-D observations must agree within 5 cm. Missing factory
intrinsics, missing/mixed depth or uncertain detections cannot become targets.
Search does not require the entire scene to be motionless: the neck view and
individual target confirmations govern it. Older discoveries are re-observed.
Views outside the current calibrated neck envelope are skipped immediately.

The legacy hanging observation decoder accepts a single complete JSON object with optional
Markdown wrapping or a short preamble. It rejects invalid coordinates, extra
answers and trailing instructions. A format failure gets one fresh-image retry;
invalid geometric values do not. Reports include bounded actual model replies
and decode errors. If every view fails inference, the outcome is
`vision_unavailable`, rather than claiming that the objects are absent.

If an object is missing, ROB addresses the nearest visible person's view (or the
forward view if none was measured), asks them to point, and watches for a stable
extended-index gesture. The projected 2D finger direction selects a bounded
camera neighborhood at several pan/tilt intervals and finger-ray extensions,
clamped to the current neck calibration. A stable pointing gesture observed
during the main scan is followed immediately once; it need not wait for the
whole scan to finish. If necessary ROB asks again after the raster scan.
It is an approximate search hint, not a
calibrated 3D pointing ray or proof of the object. The object must still receive
two fresh visual confirmations; a transfer additionally requires depth/rim
localization. A search-only operation ends when both objects are visually
confirmed and reports `visually_found`, without claiming a bucket release
position. ROB reports found/not found aloud.

Each search saves observations, capture times, sequences, view targets, found
positions and the actual outcome in Application Support/Cerebro/WorkspaceSearch.
Progress is saved after each view, including interruptions; an interrupted
search never claims object absence. These historical reports never authorize
later motion. The latest exact detector input is retained locally as
WorkspaceDetector/latest-input.jpg for debugging and overwritten by the next input.

Install once with `python3 Scripts/setup-workspace-detector.py`. This creates a
separate WorkspaceDetector virtual environment and downloads Google's
[OWLv2 model](https://huggingface.co/google/owlv2-base-patch16-ensemble) at revision
`cfd3195ba4ea9592eec887ded089f4c08eff231d`, using safetensors. Runtime loading is
local-only with Hugging Face network/telemetry disabled. Dependencies and model
weights remain outside the app/repository in Application Support/Cerebro.
See the [official detector API](https://huggingface.co/docs/transformers/model_doc/owlv2).

The detector replay correctly boxed the visible can at raw score 0.576
and accepted no can/bucket in a target-free keyboard/chair crop. A second replay
boxed the actual bucket at 0.713 and rejected a crop of the blue container; all
accepted bucket boxes agreed with the manually checked bucket region. The first live
native run confirmed the can in two RGB-D frames and reported its provisional
position; warmed MPS inference was about 1.1–1.5 seconds. The orange bucket was
not confirmed, and Rob reported pointing/search coverage was inadequate. The
32-view settling raster completed its main sweep, then followed a stable human
pointing hint and confirmed the bucket in two distinct frames near pan +21°,
upper target 5757. This diagnostic was deliberately stopped after both objects
were visible to load the classification correction; its report retains an
`interrupted` outcome and does not claim a completed transfer. These few local
scenes/crops are not a broad accuracy benchmark.

The final installed build completed a new search with `visually_found` and
“I found the Coke can and orange bucket.” It used eight raster positions plus a
can refresh (18 decoded observations), confirming the bucket at pan 0°, upper
target 5650 with raw scores 0.499 and 0.514. No reach, grip or carry was sent.
The [detector validation record](calibration/evidence/2026-10-22-recycling/object-detector-validation.json)
links the live outcomes, replay checks and build/source hashes. Camera pixels
remain local and are not included in these committed records.

A can box currently supplies its side-wall center. A bucket box establishes
visual identity only; it does not invent an opening/rim release point. Rim/depth
localization remains required for automatic transfer; a taught five-anchor task
can be used for a fixed station.

## Pick and place

### Detected-can ghost rehearsal

Settings → Arms → **Preview can grab** opens the controller-input SceneKit view,
runs a new RGB-D search and labels the measured can center in the same robot
coordinate frame as the mesh. The panel shows X forward / Y left / Z up, capture
sequence and age. The marker remains while editing the ghost; observations older
than 60 seconds are explicitly marked historical, and a new rehearsal requires
a fresh confirmed target.

The arm selector defaults to **Left arm**, honoring Rob's report that the table
blocks the right arm. Object-side proximity alone must not choose an arm. The
left ghost presents, raises before crossing, approaches above the can and tries
the grasp pose. The preview includes wrist joint 7 and constrains the provisional
tool approach (+Z) and captured jaw-opening (+Y) axes to horizontal. The narrow
local X dimension is the gripper plane normal, not the jaw-opening direction.
The final approach uses short Cartesian stages with the same orientation target
and the nearest equivalent wrist-roll branch, avoiding an end-of-approach flip.
A grasp requires both
position error ≤12 mm and tilt ≤5°; position-only arrival cannot imply a usable
grasp. Bounded alternate shoulder seeds help solve a cross-body reach.
The target is never moved to make the simulation succeed. If the model cannot
reach it, the displayed gap remains and no closing/lift is simulated. Otherwise
the animation shows symbolic jaw closure and a 6 cm lift when that pose solves.
The cyan path and labeled target can be scrubbed or replayed with **Play ×4**.

This rehearsal uses a separate non-executable data type, leaves the other arm and
original/measured robot unchanged, and never requests an arm grant or sends arm
or jaw commands. Table collision geometry and the actual gripper/tool-axis mapping
remain unverified; this is a model preview, not a commissioned physical route.

The SceneKit viewport stays visible and interactive through searches, pending
approval and arm operations. There are no blocking viewport snapshots or image
overlays. It renders at 30 FPS normally and 15 FPS during physical arm operations;
depth-cloud work stays on the existing background queue, with one pending frame
per camera and publication capped at 8 Hz normally / 2 Hz during arm operations.
Fresh capture, neck/base placement checks and explicit captured-world history
labels remain; arm-operation flags alone no longer blank the cloud. This display
change does not alter actuator feedback, grants, watchdogs or perception gates.
The [ghost validation record](calibration/evidence/2026-10-22-recycling/can-ghost-validation.json)
includes the completed native camera test, exact build/source hashes and the
plan, live-render and depth-publication fixture results. The fixture checks
horizontal jaw orientation between the final approach waypoints, not just at
the last pose. No camera images, grants or physical grip claims are included.

`left_recycle_can` covers search, pointing assistance if needed, planning and
execution under the original authorization, bounded to ten minutes to allow the
deliberate search and settling intervals (the executor stops at 590 seconds).
A local IK
planner generates five anchors: pickup approach, grasp, 6 cm test lift, release
12 cm above the observed bucket rim, and retreat. The proposal includes exact
targets, timing, model/mapping/session IDs and jaw-action boundaries. Only the
single current step can reach the gateway. Taught approach travel uses the
existing five segments. Arbitrary camera/model joint values are never admitted.

Before each jaw action the executor drains motion leases, requires a confirmed
position hold and fresh settled joint feedback. Empty calibration occurs only at
the initial front preparation, never around the can. Grip/release use vendor
intensity 2. There are no manual readiness stages, automatic force escalation,
blind retries or automatic torque-off. Stop/faults request hold and cancel later
steps. A task that may have gripped an object never offers the old empty-arm
automatic recovery path.

The existing ghost editor also supports teaching and saving five tabletop
anchors for a fixed station. `left_pick_place` executes that saved route. All
edits remain preview-only until the full task is authorized.

Joint paths are checked against URDF/transport limits and provisional tread
clearance, but camera mounting, encoder mapping and full table/bucket collision
geometry are not yet commissioned. Position-only IK does not certify gripper
orientation. The small lift is a supervised test, not a force/slip detector.
Jaw position, grip force and retention are unmeasured. Completion therefore
reports measured arm arrival and accepted jaw commands with
`placement_verified=false`; it does not claim the can entered the bucket.

## Validation

The plan, approval/session, executor, camera/model rendering and tunnel fixtures
run without hardware. They check typed/invalid observations, depth projection,
distinct-frame confirmation, pointing direction, IK path and jaw boundaries,
tampering, one authorization, loss of feedback after grip, session expiry,
spoken rejection and late startup retry. These checks do not establish a live
successful recycling task. Record the actual commissioning result separately.

The first live session prepared the left arm in 19.8 seconds, scanned, then
returned the empty arm to inactive hanging in 15.6 seconds under the same grant.
The VLM replies failed decoding, so no reach/grip/carry occurred. A later
preparation stopped on an expired gateway motion lease, with a 1.3-second gap in
application recording just before the stop. The independent lease watchdog is
unchanged. See the [live evidence](calibration/evidence/2026-10-22-recycling/first-live-session.json).
