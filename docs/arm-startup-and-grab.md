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
20.7 s, plus camera, gripper and arrival checks. These timings have not been
verified automatically on hardware. Three distinct stable measured position
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
requested 10° right setting and both gripper calibrations still require a live
trial after the application is reloaded from a verified hanging pose.

The following controller-approved Relax attempts moved back along the taught
corridor but held on main-camera freshness failures (712 and 726 ms) and then
on controller cancellation/disconnection. Fresh CAN feedback continued during
each hold. The main camera helper was already running at 640×400; these stops
were not caused by accidentally selecting the belly camera or a larger capture
resolution. Torque-off and the new inspection pan must not be recorded as
verified until the remaining return and a reloaded-app trial complete.

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
The app has not yet been restarted: the controller disconnected during the
return, with the latest passive sample at approximately physical right
`[0.052, -0.204, 0, 0, 0, 0, 0]` and mirrored physical left. All fourteen
statuses remained position mode 2 with fresh feedback. A later request reported
no controller offering Action Approvals, so no further motion was started.
Startup calibration remains disabled.

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
