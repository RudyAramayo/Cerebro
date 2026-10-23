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
reviewed gestures, empty-can recycling (closing at intensity 2; opening at 10) and empty-arm lowering
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

A pending question starts a fresh microphone utterance so an earlier conversation
cannot remain prefixed to “yes, proceed.” If unheard, ROB repeats “Hey! Can I move
my arms?” at 20 and 45 seconds. These reminders neither grant authorization nor
extend the original 90-second deadline, and stop once authorization is accepted.

Preparation can recover a confirmed-empty arm from a recent failed recycling
attempt by reversing only its recorded, actually executed proposal prefix to the
front pose. The old proposal is revalidated against the same model/mapping, the
fresh measured pose must lie on that executed prefix, and a new authorized
preparation supplies authority. Unvisited targets, old grants, jaw actions and
arbitrary return paths are excluded. The return remains bounded to 80 steps /
100 seconds, with transport and sampled tread-clearance limits.

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

Search now starts with durable last-seen views for the requested objects. The
per-model `WorkspaceSearch/recall-v1.json` records a twice-confirmed box, camera
view, confidence and original capture time. Existing search reports seed the
first recall file. Search checks the original successful camera view first, then
its recentered view before falling back to the raster;
partially visible objects get up to four additional centered looks. Hints expire
after 24 hours and a changed robot model invalidates them. No remembered position,
old detection, saved permission or confidence value satisfies a live confirmation.
ROB says “Checking where I last saw them” and still takes two new observations.

Depth confirmation retains valid observations across neck views within the same
search. Two distinct, advancing RGB-D measurements must agree within 5 cm and
30 seconds; bucket opening radii must also agree within 2 cm. A missing depth
frame supplies no measurement and does not erase the last valid one. A view with
a visible but unconfirmed target gets up to four frames before continuing the
raster. The October 22 live trace showed two valid bucket fits 3.53 cm apart,
7.77 seconds apart, from adjacent neck views; per-view state had discarded that
agreement. An explicit final refresh clears the previous pair and still requires
new measurements before reaching. Historical coordinates never complete a pair.

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

Confirmed discoveries also get brief spoken progress: “I see the can. I'm still
looking for the bucket,” followed by “I see the bucket” when it is confirmed.
Each object is announced only once per search, after the existing two-frame
confirmation. Repeated observations and refreshes do not repeat the announcement.
The report records these messages; seeing a bucket still does not establish its
opening or a measured drop position.

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

A can box supplies its side-wall center. A bucket box first establishes visual
identity. Opening localization additionally fits a measured floor plane, corrects
the provisional neck-camera vertical for that frame, and fits the orange rim in
aligned depth. Floor support must cover at least 35% of the sampled scene, stay
within 35° of the prior and put camera height at 0.8–1.3 m. The rim requires at
least 25 points, 65% inliers within 12 mm, at least 160° of observed circumference
and a 6–28 cm radius. At least 80% of 12 or more interior samples must lie 4 cm
below it. A lid, short arc, clipped box or inconsistent depth supplies no drop
position. Two independent frames must still agree within 5 cm. This corrects a
local camera prior; it does not commission the arm mapping or environment model.
The last bucket RGB image, aligned depth and calibration are retained locally as
`WorkspaceDetector/last-bucket-*` for diagnosis; they are not publication assets.

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

An out-of-reach can prompts “Please bring the can closer.” The ghost panel keeps
that request and the rescan instruction visible. After moving the can, **Find
Coke can + ghost grab** acquires new RGB-D observations and recomputes the reach;
the old target is never shifted or reused as the new position. An orientation-only
failure does not ask for a closer can. Executable task planning similarly asks
for the can or bucket whose position failed the reach check, before any reaching
or gripping. This assistance does not drive the treads or create an arm grant.
Automatic base approach is future work.

The [assistance validation record](calibration/evidence/2026-10-22-recycling/can-assistance-validation.json)
records the signed local build, passing fixtures and a native search that
announced the can and bucket once each. After Rob moved the can closer, the
native left ghost solved the grasp with 0.2 mm displayed error, horizontal jaws
and a simulated 6 cm lift. No physical pickup or placement was run.

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
Before searching, it returns the confirmed-empty left arm along its registered
route to measured hanging and deactivates, so the presented hand cannot occlude
the floor bucket. This return stays inside the task's single authorization.
The inactive neck-only phase retains ownership, gateway generation, unchanged
hanging/inactive state, deadline and Stop. Delayed arm telemetry cannot authorize
motion: fresh motor/gripper feedback, a new mode query and hanging baseline are
required again before planning is admitted to physical execution. Feedback and
lease limits for energized arms remain unchanged.
A local seven-joint IK planner now compiles the horizontal-jaw ghost approach
into physical steps: registered empty-arm presentation, leveling, raised
cross-body approach, grasp, 6 cm test lift, high carry, gravity release and upward
retreat. Wrist roll follows the same nearest-branch solution as the preview.
The hand releases at a reachable height above the opening; it does not descend
to a floor bucket. The drop point may move up to 4 cm toward the hand within the
observed opening while retaining 5.5 cm of rim clearance for the can and fit error.
Release stays at least 12 cm above the rim. Grip and release are frozen into the
`recycling` proposal, distinct from the legacy five-anchor taught `tabletop` task.
The proposal includes exact
targets, timing, model/mapping/session IDs and jaw-action boundaries. Only the
single current step can reach the gateway. Taught approach travel uses the
existing five segments. Arbitrary camera/model joint values are never admitted.
All seven joints retain URDF/transport bounds; interpolated post-leveling poses
retain horizontal jaw axes within 8°, sampled tread clearance remains 30 mm,
and one proposal is limited to 80 steps / 135 scheduled seconds. Planning and
depth fitting run off the main thread so they cannot block control monitoring.

Before each jaw action the executor drains motion leases, requires a confirmed
position hold and fresh settled joint feedback. Empty calibration occurs only at
the initial front preparation, never around the can. After newly dispatched
empty calibration, the arm remains held and monitored for 10 seconds before
opening. Two seconds proved insufficient in a live preparation; a later separate
opening worked. The longer interval is a conservative timing change, not measured
calibration completion or jaw-open feedback. Recycling and Present/open use fixed
opening intensity 10; gentle recycling closing remains 2. Legacy taught tabletop
and handoff actions retain their existing settings. There are no manual readiness stages, automatic force escalation,
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

An optional local `LeftArmCalibration/can-reach.json` stores an explicitly
operator-measured XYZ translation bound to the robot's model/reference/mapping.
Absent means zero correction; an invalid or mismatched existing file blocks.
Each component is bounded to 15 cm. Rob's approximately 5-inch overshoot report
on October 22 supplied the experimental can-only correction `[-0.127, 0, 0]` m.
It shifts the can approach/grasp/lift, leaving the raw detection and bucket
position unchanged. The ghost shows the raw can marker and a separate corrected
reach marker. This does not establish camera-to-arm or tool-center calibration.

After the complete 39-step physical run, Rob observed closed jaws during approach,
a grasp 4–5 inches above the can, and a release needing 20° farther toward ROB's
left. The local experimental correction therefore adds −11.43 cm in Z (the
4½-inch midpoint), retaining the earlier −12.7 cm X correction. Optional
`bucketYawDegrees` rotates the model release center about the left shoulder's
vertical axis, keeping measured rim height/radius and raw bucket observations
unchanged; it is bounded to ±30°. The next commissioning sequence verifies a
separate stationary opening with already accepted calibration before reaching.
Stationary release10 and release20 were subsequently acknowledged but stayed
closed. Rob manually recovered it with additional close/open commands and
confirmed the jaws open. Confirmed-EMPTY preparation now primes the jaws with
a stationary gentle close at2, waits1.5seconds, then issues the caller's fixed
opening command. This runs before reaching and never during payload release;
command directions and grip force are unchanged. The one complete operation
scope includes this initialization. No successful pickup is inferred from
accepted jaw commands.

After trial `71623360`, Rob reported the can was knocked over and the jaws
contacted the table. The release was above the bucket, with a requested
1½-inch shift toward ROB. The next experimental calibration raises the
can approach by 2½ inches (+6.35 cm), changing net Z from −11.43 cm to −5.08 cm,
while keeping X −12.7 cm and bucket yaw 20°. Optional `bucketInwardMeters`
shifts the calibrated bucket center 3.81 cm toward the left shoulder before
the existing opening-fit offset. It is finite and bounded 0–8 cm; measured
sightings, rim height and radius stay unchanged. This physical trial did
not pick up or recycle the can.

A return after this table-contact report must also avoid its old low section.
Optional `recoveryGraspClearanceMeters` (finite 0–15 cm) sets a minimum tool
height above the previous frozen grasp. The local 8.89 cm value combines
the requested 6.35 cm raise with a 2.54 cm return margin. Low recorded targets
are skipped, and every connecting segment is checked above this height and
against tread, joint and timing limits. All retained targets must have been
visited in the recorded operation. This reviewed return needs a new spoken
or controller grant; it does not extend the approval-free hanging exception.

The first corrected preflight exposed a separate planning defect: hanging J7
retained a small 0.002727 rad residual in the preview's front pose, exceeding
the compiler's strict 0.001 rad front check. Copy all seven registered front
joints into this target, then choose the nearest horizontal wrist branch.
The measured-hanging regression uses that residual and the actual new
observations; the full corrected route passes without relaxing any limit.

The first confirmed recycle was trial `DA779E5C`: the can was visibly lifted
in the gripper, and Rob confirmed it landed inside the orange bucket. The
48-step operation took 264.66 seconds, including about 169 seconds searching.
Its telemetry and frozen proposal are archived as `first-confirmed-recycle`.

For subsequent positions on the same table, optional `canOutwardMeters` adds
a bounded horizontal correction along the fresh can vector from ROB (0–3 cm;
local setting 1 cm). Rob reported the successful grasp was near the bottom.
The new `tabletopCanBaseHeightMeters` mode instead targets the measured can's
middle: the local base datum plus half its measured height. The 0.798035 m
datum comes from that successful low grasp; it is a conservative operator
calibration, not a measured table plane. It replaces the temporary fixed
`tabletopGraspHeightMeters` setting. Both height modes cannot be enabled together.
The datum is local to this table/model, bounded to 0.30–1.40 m, and the
resulting correction still must stay within ±15 cm. Other table heights need
recalibration. Camera/arm transforms and whole-gripper table clearance remain
provisional.

The local detector retains up to eight distinct can instances. Three robust
RGB-D body bands locate each upright can's top, middle and base; clipped boxes,
missing/inconsistent depth and implausible dimensions cannot authorize a
middle grasp. Two fresh agreeing observations are still required. A base-height
check excludes floor/bucket cans in this commissioned scene. The ghost view
labels TOP, MIDDLE and BASE and shows the separate calibrated reach target.

After a scene rotation, an empty valid recall file clears the old attention
directions without migrating old reports. Search checks six broad views before
the full raster, uses confirmed recall on subsequent searches, and skips
attention hints for targets already found. Camera settling and fresh depth
checks are unchanged. Two cans can be recycled as successive complete routines
within one live 15-minute left-arm session; confirm the first release/empty hand
before starting its registered recovery. This does not infer success from a
completed motor sequence.

## Validation

The plan, approval/session, executor, camera/model rendering and tunnel fixtures
run without hardware. They check typed/invalid observations, depth projection,
distinct-frame confirmation, pointing direction, IK path and jaw boundaries,
tampering, one authorization, loss of feedback after grip, session expiry,
spoken rejection and late startup retry. These checks do not establish a live
successful recycling task. Record the actual commissioning result separately.

The installed middle-can detector completed a neck-only visual search in 54 seconds
with 12 observations. It distinguished both table cans, kept the same selected
instance, and measured its height consistently at 11.09–11.35 cm. The calibrated
middle target includes the requested 1 cm outward correction. Both objects were
visually confirmed, but bucket depth was unconfirmed; this visual-only timing is
not directly comparable to the earlier 169-second depth-required search. The arm
session request expired without authorization, so no new reach or recycling was
attempted. Physical validation of the middle grasp and two-can sequence remains
pending. See the [middle-can search validation](calibration/evidence/2026-10-22-recycling/middle-can-search-validation.json).

The first live session prepared the left arm in 19.8 seconds, scanned, then
returned the empty arm to inactive hanging in 15.6 seconds under the same grant.
The VLM replies failed decoding, so no reach/grip/carry occurred. A later
preparation stopped on an expired gateway motion lease, with a 1.3-second gap in
application recording just before the stop. The independent lease watchdog is
unchanged. See the [live evidence](calibration/evidence/2026-10-22-recycling/first-live-session.json).

### Delayed telemetry notifications and automatic control readiness

The next physical recycling request stopped during its neck scan, before arm
travel, with “Invalid or stale left-arm current recording.” Its CSV retained
261 complete samples at zero over 14.0 seconds, including a 0.73-second gap in
recorded samples. That gap alone does not establish whether motor data or UI
delivery paused. Subsequent diagnostics showed current CAN feedback; Rob then
manually deactivated/activated the left arm, which reported active mode at zero.

The hardware-free regression reproduces the same error by delaying an otherwise
valid telemetry notification 700 ms while the gateway already holds a newer,
fresh packet. The recorder now retains this historical current sample, its
actual delivery age and any current jump only when its controller/joint feedback
was valid at receipt AND a strictly newer live motor/gripper sample is within
the existing 250 ms limit. Source-stale packets, loss of current feedback,
invalid values and current-jump limits still stop. Results report delayed sample
count and maximum delivery age. Live motion admission and the gateway watchdog
are unchanged; historical receipt age never authorizes motion.

Configured telemetry transport already reconnects automatically after transient
gateway loss, reusing a healthy SSH tunnel. Feedback recovery is reported by the
existing health monitor. The next authorized preparation changes active (green)
or inactive mode to position control itself and waits for measured mode feedback;
no manual deactivate/activate cycle is needed. Recovery does not replay a failed
movement, restore a previous grant, or deactivate a potentially loaded arm.

The installed fix completed a physical empty-left preparation in 21.4 seconds
(422 seven-joint samples, maximum recorded feedback age 35.2 ms), without another
manual mode toggle. The same spoken session then scanned for recycling for
67.2 seconds before the live motor/gripper freshness check stopped it. That is a
different check from the delayed-recording notification regression; its underlying
transport/hardware/scheduling cause remains unconfirmed. No reaching or gripping
occurred in that scan. Once feedback was available, the registered empty return
ran without a new grant, reached hanging and deactivated in 15.7 seconds
(310 complete samples). This validates preparation and return, not can placement.
Future live-feedback stops include separate motor/gripper ages and sequence.
The [telemetry recovery validation record](calibration/evidence/2026-10-22-recycling/telemetry-recovery-validation.json)
includes the failing baseline, passing regression/transport fixtures, exact build
hashes and all four native CSV traces. Reconnection was observed after the final
reload without pressing Connect; a read-only mode query confirmed the left arm
inactive with current CAN replies. The scan's feedback-freshness fault and the
unfinished physical pickup/drop implementation remain explicit blockers.
