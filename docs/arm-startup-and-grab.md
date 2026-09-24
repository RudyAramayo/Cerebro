# Arm startup, relax and front-pose grasp attempts

Settings → Arms contains **Calibrate arms on startup** (off until selected),
Run startup now, Prepare to grab, Relax arms and Stop + hold. Enabling startup
requests one controller-approved attempt after launch or system wake. Failure ends that attempt;
there is no indefinite retry or delayed activation after the 90-second limit.
Explicit `arm_control` prepare/grab/hold/relax/wave/teach/replay commands are available independently
of that preference. Direct chat and addressed local speech also recognize simple
commands, including “relax”, “grab this” and “hold this”. Negations, quoted text,
“hold on”, and discussion about grabbing are not local motion commands.

Every complete startup, prepare/grab/hold, or relax operation now requires **one
Approve decision on the connected Vision Pro or iPhone**, including both gripper
calibrations where needed. The approval now explicitly covers operator-supervised
travel on the already taught route despite incomplete camera visibility. It asks
the operator to confirm physical hanging at zero for a new session, clear the
route, watch the arms and keep Stop + hold ready. This scope lasts only for the
approved operation and authenticated controller session. No arm-mode or gripper confirmation opens on the
droid's monitor. Stop + hold is immediate. See [headless arm approval](headless-arm-approval.md)
for connection, timeout and cancellation behavior.

Both physical arms use the following taught corridor. The right column uses
L10, gateway `left`, UDP 26001. Physical left uses the negated vectors through
R11, gateway `right`, UDP 26002. J3–J7 remain zero throughout:

| Waypoint | Right J1 | Right J2 |
| --- | ---: | ---: |
| Hanging | 0 | 0 |
| 1 | 0 | −0.15 |
| 2 | 0.15 | −0.30 |
| 3 | 0.30 | −0.45 |
| 4 | 0.45 | −0.60 |
| 5 | 0.75 | −0.60 |
| Front | 1.05 | −0.60 |

Both arms are dispatched together. Segment duration is the maximum of 0.8 s,
maximum joint displacement / 0.075 rad/s, and 4 × (displacement / 0.3)^(1/3).
This preserves the nominal longest-segment timing scale while reducing the
short 0.15-radian segments to about 3.175 s. Planned hanging-to-front travel is
20.7 s, plus camera, gripper and arrival checks. One controller-approved live
trial measured approximately 22 s of paired forward travel, as recorded below;
this does not establish total startup/gripper timing. Three distinct stable measured position
samples spanning at least 150 ms are still required; they can accumulate during
the segment instead of adding an unconditional delay afterward. There is no
measured peak speed, acceleration, jerk or torque claim. Missing vendor velocity
is never replaced by zero.

Startup verifies measured encoder zero and uses the controller operator's
explicit confirmation of physical hanging for the authenticated session. An
ordinary approval without the supervised-route wording still requires camera
confirmation. It preserves the commissioned B1/URDF references. This is a
bounded startup readiness routine, **not a new seven-joint visual offset fit**.
The separately recorded folded pose is not part of this route. An unknown pose,
off-route wrist/elbow or new session away from hanging blocks motion.
Interrupted positions on the taught segments can return along that
same corridor within the verified session.

Cerebro Speech announces sustained arm-feedback loss locally, even during
manual SDK commands or when Gemini, diagnostics and the controller are not
open. Spoken names use the robot's physical side: Amber gateway `left` / L10
is the **right arm**. Warnings identify missing joints/gripper or a missing
controller stream. One second of continuous loss triggers one announcement;
one second of healthy samples permits a recovery announcement and a later new
fault. The initial connection has a three-second sample grace period. These
speech delays do not change the existing 250 ms motion-admission limit.
A lost gateway receives one shared connection warning rather than falsely
assigning a broken motor; deliberate disconnect and shutdown are silent.
Warnings interrupt queued speech and are retained in the Main AI transcript.
They do not restart, zero, activate or move hardware. Settings → Arms → **Test
spoken arm warning** exercises the local voice with an explicitly labeled test.
`bash Scripts/test-arm-feedback-alerts.sh` validates side mapping, partial bus
loss, stale/frozen telemetry, debounce, recovery and reconnect behavior without
hardware.

Every `prepare`, `startup`, `grab` and `hold` requests **both grippers open**
once the arms are measured in front, whether or not calibration was needed.
Preparation queries the gateway's current session state, including calibration
accepted through manual diagnostics. It no longer uses a separate private
calibration flag or confines Release to the first calibration attempt. Missing
or revoked calibration still requires the existing empty-jaw camera assessment.
Only grippers whose acceptance is missing are calibrated.

The single controller summary explicitly includes opening both jaws and asks
the operator to support any held object and clear the jaws. Already calibrated
opening uses the live RGB-D/hand detector and measured front/mode checks without
waiting for MLX to label the jaws. Prepare/startup returns
`gripper_release: accepted_unverified` and `jaw_opening_verified: false` after
both acknowledgements. It does not claim measured opening. Grab/hold still
requires the stationary visual object/jaw assessment before closing. Greetings
and replay leave the jaws unchanged under their supervised route approval.

The main face RGB-D camera owns arm inspection and runs independently of preview
visibility and optional detector settings. The belly stream is not required or
included in an arm observation. The current RGB-D stream and independent
person/hand detector remain active during travel, but an explicitly supervised
taught route does not wait for the language model to judge the whole route or
reject travel because a hanging arm is cropped. The operator observes clearance;
absence of a detection is not proof of no collision. During a routine the main camera requests 640×400,
then restores normal capture demand.
An explicit recording resolution retains priority. Once the arms are stationary
in front, a read-only local MLX inspection requires both grippers to be visible,
hands clear and empty jaws before calibration. A cropped hanging route does not
invalidate a stationary jaw assessment. The input frames retain their
capture times and sequence, old inference is rejected, and scene changes veto
the result. Inspection acquires the vision model/GPU slot before selecting
pixels, then waits for three new frames captured after settling began, spanning
at least 300 ms. It allows up to three seconds for this steady view. This avoids
comparing a frame from the neck's final movement with the settled viewpoint or
aging an image while another model holds the GPU.

If the scene changes while the model is answering, the answer is discarded and
one fresh, settled inspection is attempted under the same controller approval.
The existing 2.5% thumbnail-change veto, 700 ms current-frame bound, eight-second
inspection-image bound and 90-second operation deadline remain in place. No
brightness correction or weaker collision criterion is introduced. A second
changed view, missing depth, stale/frozen stream or cancellation
still stops the operation. Status messages show the reinspection; failure
results include camera health and the last measured change fraction/source age.

The vision prompt includes the complete JSON schema and requests a compact
answer with a 320-token ceiling. The decoder accepts one complete JSON object,
optionally enclosed in a single Markdown JSON fence. It never invents missing
facts, converts strings/numbers into booleans, extracts a favourable object from
prose, or accepts duplicate keys. A malformed/incomplete response gets one fresh
inspection with a format reminder, sharing the same two-attempt budget as scene
changes. A valid negative or low-confidence assessment is never retried to seek
a more favourable answer. Camera freshness, hand/person vetoes, measured motor
feedback, ownership, route/timing bounds, cancellation and controller liveness
remain mandatory. Decode failures record a bounded, single-line model response and
specific failure code in camera health and the local log. User-visible failures
distinguish an unreadable model reply from missing route visibility, clearance,
or confidence; they no longer call a JSON decoding failure an ambiguous scene.

`python3 Tests/ROBArmInspectionRuntimeTests.py` runs the production inspector with
synthetic frames and an inert model, including GPU wait ordering, settling,
discarding a changed-scene answer, the single retry limit, stale/frozen frames,
missing depth, cancellation/epoch changes and the independent hand veto. It also
runs the response-codec fixtures and checks wrapper handling, strict field/type
validation, duplicate-key rejection, the shared retry budget and preservation
of negative/low-confidence observations.
`bash Scripts/test-arm-routines.sh` checks the controller-approved coordinator
without hardware. These fixtures do not establish physical clearance.

On 2026-09-23 the signed build and inspection/routine fixtures passed. The build
phase installed the update in `/Applications/Cerebro.app`, and Cerebro was
restarted to load it. The supervised Prepare retry ended before inspection with
“Connect Vision Pro or iPhone and enable Action Approvals.” No new arm motion
ran; successful physical preparation remains unverified for this change.

The subsequent supervised-route build passed the production coordinator,
controller approval, show rehearsal and camera response fixtures, including
taught travel with an obscured semantic view and refusal of unseen jaw motion.
It was installed and restarted from `/Applications/Cerebro.app`. The first
supervised Prepare request also ended before motion because no connected
controller offered Action Approvals; physical execution still requires the
operator's live controller decision.

The next controller-approved trial passed camera admission but stopped on
`Amber rejected active mode request (0)`. Read-only telemetry showed physical
right (gateway `left` / L10) fully active at zero and physical left (gateway
`right` / R11) fully inactive at zero, with fresh CAN feedback. No taught
waypoint ran. The gateway now reconciles a zero mode reply only when all seven
mode readbacks and a new fresh joint-status sample confirm the requested mode;
the original response is retained. Cerebro admits a uniformly active arm for
verified position-mode entry, so this interrupted state can be recovered under
a new whole-operation controller approval. Mixed modes remain blocked.

The recovery fixture starts with one active and one inactive arm and passes
the complete simulated startup with two gripper calibrations. The signed build
passed, was installed by the build phase and relaunched from
`/Applications/Cerebro.app`. Installed debug-library SHA-256:
`999fa81d65fd5007785933ef055472fb07b7f031aacbf01707543d99a2919fca`.
These fixtures and installation do not establish physical route completion.

After installing ROBController's persisted receive-request preference on
Onix16, a new Prepare request was delivered to an authenticated controller
offering approvals, but expired without an Approve response. An 80-second
passive capture recorded no joint-position change: physical right remained
active and physical left inactive, both at reported zero. The live main-camera
preview was visible but did not show the hanging arms. Automatic preparation,
gripper calibration and physical travel timing remain unverified for this build.

The subsequent live trial verified both arms entering position mode. A taught
forward run held at an intermediate pose on person/hand detection; the operator
later reported a nearby bystander, so this was not established as a false
positive. After clearance and a new phone approval, both arms reached the front
endpoint: physical right `[1.05, -0.60, 0, 0, 0, 0, 0]`, physical left the
mirrored pose, with fresh per-motor feedback. The stationary jaw assessment
blocked gripper commands. The main-camera preview clipped one gripper at its
right edge, and the operator observed the neck pointing about 10 degrees left.

**Settings → Arms → Arm inspection camera pan** now offers Center, 10° right,
and 10° left. Center is the default. The selected correction is captured in the
whole-operation phone request and cannot change that operation after approval.
The neck uses the existing calibrated pan conversion, upright clearance
staging, collision policy and settling checks. Inspection and motion monitoring
require the exact selected pan target at lower 6011 / camera 5650. Values beyond
the offered trims are not admitted. The existing combined look-and-greet path
retains its centered inspection pose.

Neck output fixtures verify the right trim, exact-target readiness and rejection
of out-of-range/nonfinite angles without serial writes. Arm routine fixtures,
the 45 controller approval checks and the signed macOS build passed. The
requested 10° right setting and both gripper calibrations require a live trial
after the application is reloaded from a verified hanging pose.

The following controller-approved Relax attempts moved back along the taught
corridor but held on main-camera freshness failures (712 and 726 ms) and then
on controller cancellation/disconnection. Fresh CAN feedback continued during
each hold. The main camera helper was already running at 640×400; these stops
were not caused by accidentally selecting the belly camera or a larger capture
resolution. Those partial returns did not establish completed torque-off or
validate the new inspection pan.

Inspection admission now charges its 200 ms sampling interval only after a
frame passes the input checks. Previously a rejected stale frame, missing
timestamp or missing depth also consumed that interval and could discard an
immediately following fresh frame. The production-offer regression covers all
three cases. The 400 ms incoming-frame bound, 700 ms analyzed-frame bound,
depth requirement and person/hand checks are unchanged. This removes an
avoidable sampling delay; it does not establish the cause of every live stall.

The inspection runtime suite and signed macOS build passed with that fix, and
the build phase installed `/Applications/Cerebro.app` (debug-library SHA-256
`9e2edd6e595c4d5e5985acd78bbaffcb9706646b53914a52be7a9cc5f3a30483`).
That build initially remained unloaded: the controller disconnected during the
return, with passive feedback at approximately physical right
`[0.052, -0.204, 0, 0, 0, 0, 0]` and mirrored physical left. All fourteen
statuses remained position mode 2 with fresh feedback. A later request reported
no controller offering Action Approvals, so no further motion was started.
Startup calibration remains disabled.

After the operator reconnected and approved a new Relax request, the app
reported completed hanging and deactivation. Independent fresh CAN feedback
confirmed physical right `[-0.001, -0.004, 0, 0, 0, 0, 0]`, physical left
`[0, 0.006, 0, 0, 0, 0, 0]`, and all fourteen modes inactive. Cerebro was
then reloaded, its dedicated-key SSH tunnel started automatically, and the
10° right inspection preference was selected. The first Prepare request
expired without approval; no new arm or gripper movement ran.

Delivered phone requests now allow 90 seconds for review to reduce repeated
resends. Hardware admission is still performed after the operator accepts,
and a lost controller still cancels the request. The 48 approval fixtures
cover acceptance after 60 seconds, refusal at the exact expiry, unchanged
identity/session binding and the existing 30-second no-controller timeout.

The next accepted Prepare reached position mode on all fourteen motors but
stopped at zero with the mode/fault monitor message before observable taught
travel. Passive feedback then remained fresh in mode 2. The coordinator now
waits up to two seconds for a newer, fresh mode-2 telemetry sample from each arm
after the mode acknowledgements, before sending the first waypoint. A previous
inactive/active sample can arrive before the stream reflects the acknowledged
transition. The fixture now models that lag and also verifies that missing
confirmation sends no waypoint or calibration. Continuous mode/fault monitoring
still applies throughout motion.

After loading the mode-feedback fix (installed debug-library SHA-256
`e9cfd10fa8970c4f2920b9ad47a91249902eb4674b0d8a1983ce06bc9acb0dbe`),
controller-approved paired travel reached an intermediate pose, then held on
a 707 ms main-camera frame. A newly approved continuation reached the measured
front endpoint, physical right approximately `[1.05, -0.60, 0, 0, 0, 0, 0]`
and mirrored physical left, with all fourteen statuses in mode 2. The 10° right
inspection trim brought both gripper regions into the preview. The subsequent
jaw assessment did not authorize calibration. Legs and a chair were visible
near the grippers; after the operator cleared them, a new approved attempt
stopped on camera freshness at 712 ms. No new calibration ran in these trials.

A controlled optional-background-analysis test improved idle camera timing,
but another approved stationary inspection still stopped at 729 ms. The
setting was restored. Profiling and a production-factory benchmark then found
the Debug RGB conversion loop exceeding the camera's frame interval. The
[CPU-vectorized conversion and measurements](depth-camera.md#application-side-rgb-conversion)
address that measured bottleneck without changing camera age limits. These
interrupted runs do not establish continuous forward timing or a completed
automatic gripper sequence. Startup calibration remains disabled.

The vectorized-camera build was installed, then loaded only after a new
controller-approved Relax completed the reverse route and independent CAN
feedback confirmed hanging zero with all fourteen motors inactive. The
post-reload camera-only check stayed below the freshness limit. The next
approved Prepare stopped before activation on nearby-person/hand detection;
the current main-camera preview showed legs and a chair directly ahead.
Both arms remained hanging and inactive until the workspace was cleared.

After clearance and a new phone approval, the updated build completed paired
forward travel without a camera-freshness stop. A passive 5 Hz capture recorded
departure from the hanging tolerance at 16:47:10.550 PDT and both arms within
0.01 rad of the front endpoint at 16:47:32.202, approximately 21.7 seconds apart.
All 109 samples in that interval had fresh CAN feedback and all fourteen motors
in mode 2. This measures one supervised trajectory, excluding approval, mode
entry, final settling and gripper inspection; it does not certify every route
or peak joint dynamics.

The stationary gripper check still rejected jaw movement. A read-only
`robot_capabilities` query through Gemini reported a decoded assessment with
zero confidence and all facts false. Its `motion_block_reason` misleadingly
described complete-route visibility even though this was a gripper assessment.
The operator identified an object beside the right gripper as the intended
ball and then removed it for empty-jaw calibration. No new automatic gripper
calibration or ball grasp has been established by this trial.

The gripper prompt now excludes the complete-route criteria and defines its
visual requirement as both working ends and both finger tips visible; cropped
or obscured jaws still fail. Full-arm route assessment retains its separate
criteria. Measured front pose, 90% model confidence, current independent
person/hand and depth checks, empty jaws, scene stability and controller
supervision remain mandatory. Diagnostics and the operator status now report
gripper confidence, visibility and hand-clearance facts, instead of attributing
a jaw-assessment failure to the hanging route. Negative assessments still do
not trigger retries to obtain a favourable answer. This prompt correction
requires a new live trial; fixtures do not establish recognition accuracy.

The signed jaw-scope build passed the inspection and complete arm-routine
fixtures, was installed by the build phase, and passed strict signature
verification. Debug-library SHA-256:
`549c04057ca028afaa9138218d9d7f2b753ef1efc347b3ce73c4cc683fb68c03`.
It was loaded after another approved Relax returned both arms to measured
hanging zero and deactivated all fourteen motors. A new Prepare reached front,
then stopped after two changed-scene assessments. A stationary retry returned
0% confidence with gripper visibility and hand clearance both false. Neither
automatic attempt sent calibration commands. The prompt correction therefore
has not established dependable automatic gripper recognition.

At the operator's explicit request to calibrate without waiting for image
recognition, calibration then used the existing manual Amber diagnostics path.
The operator confirmed the ball removed, both jaws empty and hands clear; the
arms remained at the measured front pose. Each existing manual control sent its
own authenticated phone request, with the full-travel/empty-jaw warning and
live gateway/session/feedback/ownership interlocks. This is supervised manual
calibration, not a successful automatic camera assessment or a general vision
override. Physical right/L10 command 193 was submitted at 17:01:09.011 PDT and
accepted with vendor response 1; physical left/R11 command 194 was submitted at
17:01:37.814 and accepted with vendor response 1. Both per-session diagnostics
now show calibration accepted. Jaw position, force and mechanical completion
remain unreported by Amber. No ball close/grasp was commanded. Manual
calibration does not establish completion of the automatic prepare/grab flow.

A separate Vision hand detector, current depth coverage, stationary
neck view, current per-motor CAN replies and a 1.5-second gateway lease supervise
motion. These checks are conservative observations, **not a certified geometric
collision model**. An unprepared neck or unavailable vision model ends the run
with a visible reason. Text seen by cameras cannot supply motion instructions.
The neck uses the existing reviewed upright clearance staging, then moves only
camera tilt to the inspection view. Head tracking pauses during inspection.
Passive torso slider refreshes cannot overwrite that pose; explicit manual
neck input retains priority and a changed view stops the arm routine.
Models can now propose contextual actions without a second transcript-derived
grant. The authenticated Vision Pro or iPhone must still approve the complete
operation before any activation. Camera content and stage dialogue cannot grant
that authority. Treads, flippers and linear-actuator output are held at zero with
brakes during the physical routine; torso arming is refused. Neck view changes
invalidate the camera check and stop the arm route.

Supervised `wave`, recorded replay and the arm part of look-and-greet move only
the taught waypoints and leave the grippers unchanged. The approval explicitly
asks the operator to confirm empty jaws. These gestures do not wait for a VLM
route or jaw assessment. Startup/prepare/grab still perform their camera-checked
gripper work after measured arrival in front. If the jaw check fails, the arms
remain in front without a blind calibration or close.

Only after both arms arrive in front does the routine calibrate the physical
right and left grippers, one at a time, then open them at vendor intensity 10.
It reports calibration as `accepted_unverified`: Amber has no measured jaw
position or force/completion telemetry. Open jaws must subsequently be observed.
Calibration is reused only within that same session, avoiding recalibration
around an object during the next grab request.

Grab/hold attempts use the same preparation. A close is attempted only when the
requested object is already visible between exactly one open gripper's jaws and
hands are clear. A subsequent image checks whether the object remains between
closed jaws. `grip_attempted` is never a claim of a force-verified secure grasp.
`ready_for_object` means the arms are prepared, with no object in closing reach.
General reaching, lifting, automatic force escalation and the unvalidated folded
animation remain unavailable until camera-to-arm geometry and complete routes
are validated.

Relax follows the reverse corridor, checks both measured hanging targets, then
deactivates both arms and verifies all fourteen modes inactive. A failed return
requests a measured hold; it never drops torque early or opens a held object.
An already inactive pair at zero remains inactive. Stop cancels pending startup
and active work and requests a hold; it does not initiate a relax movement.

## Automatic opening correction and interrupted wrist teaching — September 23

Prepare previously dispatched Release only inside the first-calibration branch.
The routine also tracked calibration separately from diagnostics. This allowed
subsequent preparation to omit opening, or repeat the empty-jaw inspection even
after both manual calibration commands had been accepted. Preparation now queries
the authoritative gateway state and dispatches both Release commands every time.
Gemini/OpenAI instructions and Settings describe opening as automatic preparation,
with command acceptance distinguished from measured jaw completion.

`Scripts/test-arm-routines.sh` exercises repeated opening after manual calibration,
partial calibration reuse, rejected opening, stale feedback, a hand arriving after
preflight, revoked calibration and refusing a close when jaw inspection fails.
Protocol fixtures passed. The signed Debug build was installed automatically at
`/Applications/Cerebro.app`; the installed `Cerebro.debug.dylib` SHA-256 is
`0332003284426f7e2c703c4002c1e9585c13fb3a60010fb6dd4ae607eb711f60`
(includes the spoken-feedback alerts).
The running process was initially kept in place while the arms were forward
and right-wrist feedback was unavailable. After the operator rebooted the right
arm, all sixteen device replies returned and all fourteen joints reported
inactive at zero; Cerebro was then restarted to load the opening correction.
The final signed build with spoken-feedback alerts was also loaded while both
arms remained inactive at zero. The Settings voice-test button dispatched its
explicitly labeled test through Cerebro Speech; the operator confirmed it was
clearly audible. Automatic opening on the new
binary has not yet been verified on hardware.

In the same session the operator requested palms upward. Three right-wrist
requests went through real phone approval with J1/J2 held at +1.05/−0.60:

| Request | J5 target | J6 target | Requested seconds | Observation |
| --- | ---: | ---: | ---: | --- |
| Initial direction trial | +0.25 | −0.15 | 4 | Operator requested the opposite J5 direction |
| Direction correction | −0.25 | −0.15 | 8 | Fresh feedback reached the corrected endpoint |
| Continue palm-up | −0.55 | −0.30 | 4 | Wrist feedback was lost; arrival unverified |

The operator specified negative J5 and clockwise/negative J6 for this physical
right arm, then reported that the wrist LEDs remained lit. Receive-only CAN
inspection confirmed replies from right J1–J4 but none from J5–J7 or the gripper;
the left bus still replied from all eight devices. The last cached J5/J6 values
were approximately −0.547/−0.238 rad. They are not a verified final pose. Stop +
hold was requested; a right-arm hold cannot be claimed without current feedback.
Later telemetry changed to zero coordinates with mixed cached right modes and
left inactive; no new physical hanging datum was accepted.

[The commissioning record and passive traces](calibration/evidence/2026-09-23-palms-up/trial.json)
retain targets, user observations, raw sample times and hashes. No left-wrist
trial, new startup waypoint, secure grasp, connector fault diagnosis or completed
palm-up rendition is claimed. The data loss must be resolved and current physical
pose re-established before continuing; no reset or additional wrist target was
sent by Codex after the loss.

## Physical observation on 2026-09-23

With Rob's authorization, both grippers were calibrated while both arms were
in front. Physical left/R11 accepted command 11 at 11:37:36.757 PDT; physical
right/L10 accepted command 12 at 11:37:58.323 PDT. Jaw movement was observed;
vendor completion/force was not measurable.

The two arms returned together from right `[1.05, −0.60, 0, 0, 0, 0, 0]` and
its physical-left mirror through the listed reverse waypoints, four seconds per
segment, checking camera clearance and current individual joint CAN feedback.
Physical right accepted deactivation command 13 at 11:41:24.957 PDT and physical
left command 14 at 11:41:35.971 PDT. Final telemetry showed all fourteen joints
at `0.00000` radians, all fourteen inactive, with current per-motor CAN replies.
These were supervised manual operations preceding the new software build; they
are not evidence that the new automatic routine or general reaching was tested
on hardware.

Run `bash Scripts/test-arm-routines.sh` for the production coordinator with
asynchronous simulated hardware. No robot sockets or SDK are linked. It covers
startup ordering, physical-side binding, calibrated grab reuse, stale camera
hold, return-before-deactivation, unknown poses and missing CAN feedback.

## Software validation on 2026-09-23

The signed macOS Debug build and isolated arm routine fixtures passed, as did
the gateway compatibility, arm binding, Gemini protocol, realtime adapter and
neck output and camera preview fixtures. The neck output fixture reproduces stale torso sliders
during inspection, verifies that they cannot undo camera positioning, and
verifies that an explicit manual neck command still takes priority. The 31
Python regression checks and neck structural checks also passed.

The gateway initial-refusal/recovery loopback fixture timed out in this
environment with both the changed client and the unchanged client from
`cc3d916`. This is a known validation failure, not a passing check. Live SSH
connection and current per-motor telemetry were subsequently verified through
the app; a transient SSH authentication failure cleared on a manual reconnect.

The installed build passed `codesign --verify --deep --strict`. Its
`Contents/MacOS/Cerebro.debug.dylib` SHA-256 is
`ce70f41fbb8d449db966deaaad1a001d34bac6e0c2f0cf37a542b1b3f64ab929`.
The unrelated pre-existing storyboard label changes were preserved locally
and excluded from this source change.

Live checks verified that the inspection neck pose now survives the passive
torso renderer. The new Relax command returned “Both arms are measured at
hanging zero and inactive” with live gateway feedback. This tested the
already-hanging case; the new automatic moving return is covered by fixtures,
with the route itself exercised manually as recorded above.

**Earlier automatic attempts, before the main-camera change below, were blocked.**
One check reported a forward frame age of 324 ms with 97% usable depth, while
belly frames arrived 689 ms old and failed the 400 ms input-age limit. A further
check with 640×400 capture still reported belly input age 931 ms. The cameras
were visibly streaming; streaming alone did not satisfy capture freshness.
Both arms remained inactive throughout those attempts. There was no automatic
forward motion, new automatic gripper calibration, or physical grab completion
to report. Startup preference remains off. Clear full-path camera coverage and
the existing missing camera-to-arm extrinsics also remain requirements for
broader reaching; the taught route does not resolve those limitations.

## Live model binding and camera update

See [live model motion](live-model-motion.md) for the shared Gemini/OpenAI tool
contract, camera teaching and bounded replay. `wave` is a small paired front-arm
greeting; it does not run a free-form wrist pose. `teach` is camera-only and
`replay` needs one controller approval. Replay cannot carry an object.

Main-camera inspection retains the 400 ms incoming-age limit, 700 ms current
frame limit, usable depth, hand/person vetoes, scene stability, advancing frame
sequences and measured motor checks. It does not silently substitute stale belly
pixels or waive full-path visibility. See [camera measurements](depth-camera.md#2026-09-23-latency-measurements).
This revision was validated with simulated arm hardware and real camera-only
capture. No automatic arm trajectory, new grip or human demonstration replay was
performed on the robot during this update. Startup preference remains off.
