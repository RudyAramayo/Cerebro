# Arm startup, relax and front-pose grasp attempts

## Simple physical-left trials

Settings → Arms now starts with **Wave left**, **Present / open**, **Grip object**,
**Release to hand**, **Lower arm**, and **Stop + hold**. Each operation needs one
approval on the authenticated iPhone or Vision Pro. The summary describes the
whole operation; no per-waypoint or extra spoken confirmation is needed.

- **Wave left** uses the existing hanging/front route through waypoint 6, then
  stages J3/J5 through −0.30 to −0.60 rad, one joint at a time in 0.10-rad steps.
  J6 stages inward to −0.60; the accepted handoff raises J2 to +1.00.
  The wave raises J2 to +1.30 with J4 −0.60, stages J5 to −1.00,
  then waves J1 −0.90/−1.05 with J6 −0.90/−0.60 twice.
  It leaves the empty arm raised without changing the jaws. These added
  angles require supervised commissioning; they are not a certified route.
- **Present / open** brings the left arm forward, calibrates only its empty jaw
  if needed, then requests opening. Support any held object before using it.
- Put an object between the jaws, clear your fingers, and approve **Grip object**.
  It closes at the existing intensity 10, with no arm travel, reopening or
  recalibration. The arm stays in front while you check retention.
- Support the object in the receiver's hand and approve **Release to hand**.
  It opens the calibrated jaw in place. Release is never timed automatically.
- After removing the object, **Lower arm** unwinds J5 and J3 at the front pose
  before reversing the tested approach, then verifies hanging before
  deactivation. These controls do not grip human hands.

Physical left routes exclusively to R11 / gateway `right` / UDP 26002. Both arms
are reserved during a trial to prevent competing motion; the physical right arm
receives no commands. First arm travel in a new gateway session requires left
hanging at encoder zero, with the operator confirming the physical pose.

These trials use direct operator supervision instead of semantic camera collision
or jaw estimates. Live camera freshness, stationary body/neck, per-device motor
feedback, verified modes, existing route/timing bounds and motion leases remain
required. At Rob's request, the empty-left trial uses 4× the original low approach pace
and 6× the original front pace, with a 0.7-second segment minimum. Ghost paths
join exactly collinear increments and retain all corners and reversals, without
changing the geometric corridor. Measured settling, freshness and the 1500 ms
watchdog remain in place. Exact durations are frozen in the ghost review.
Grip/open acknowledgements are **accepted_unverified**, never measured
force, measured jaw completion, or proof of object retention.

The left controls now center the camera and use the existing upright lower-neck
target 6011 and upper-camera target 6306, about 18° below compensated level.
The legacy paired
inspection retains its downward target 5650. Both go through the existing
center-first clearance policy, command ramp settling, manual priority and
unknown/OFF-state checks. Neck arrival is command-space, not encoder feedback.

Every operation records distinct fresh position/current samples to
`~/Library/Application Support/Cerebro/LeftArmTrials/*.csv`. **Show recording**
reveals the latest file. CSV contains elapsed time, source sequence, physical
and gateway sides, joint number, position, raw current, signed current change,
feedback age and operation phase. The tool result includes the file, sample
count, peak absolute current change and configured cutoff.

**Current jump stop** defaults to 0 (record only). After reviewing real raw
values, the operator may set a positive threshold. The exact threshold is frozen
into the controller approval. A larger absolute sample-to-sample change on any
joint cancels the remaining steps and requests a left-arm hold, retaining the
recording. This app-side monitor uses the available telemetry; it is not a
calibrated collision detector or force limit and cannot prevent initial impact.
The existing hold acknowledgement does not verify physical stopping.

Voice/tool equivalents are `left_wave`, `left_prepare`, `left_grip`,
`left_release` and `left_relax` through `arm_control`. Direct commands include
“wave your left arm”, “open your left gripper”, “hold this with your left hand”,
“return the object” and “lower your left arm”.

Validation: `bash Scripts/test-left-arm-trial.sh` runs the production executor
and real approval broker with isolated fake motors/camera/controller. It covers
approval rejection, correct side, wave/return, calibration reuse, stationary
grip/release, current recording/cutoff, stale feedback, session replacement,
camera loss and Stop. Fixtures and a successful build do not establish a live
robot trial; use the real controller approval and report its actual outcome.

### Revised wave, speed and shared neck model

The J2 +1.30 / J6 −0.70…−0.60 wave completed after an accidental spoken Stop
and a newly reviewed, separately approved continuation. Rob requested more J5
rotation to make the arm vertical and a larger J6 wave. The [v5 evidence](calibration/evidence/2026-10-21-social-left/trial-ghost-wave-v5.json)
retains the measured positions/current trace; the [interrupted trace](calibration/evidence/2026-10-21-social-left/trial-ghost-wave-v5-interrupted.json)
records why motion stopped. Spoken Stop remains active.

Candidate v6 retains the accepted J2 +1.00 handoff, stages raised J5 through
−0.70 to −0.80, and swings J6 between −0.60 and −0.90 with J1 twice. Rob also
requested faster motion. The first 2× front profile still scheduled 75.5 seconds
from hanging, and Rob reported it was extremely slow. Two attempts held on
lease/freshness faults; a main-thread SceneKit transaction stall was observed.
V7 freezes ×4 preview on execution, avoids unchanged mesh transforms, caps the
scene at 30 FPS and clouds at eight updates/second per camera. It also joins
collinear increments while retaining every corner/reversal, and uses 4× low
approach / 6× front timing (0.7 s minimum), scheduling 14.7 seconds from hanging
plus preparation and measured settling. Model tread sweeps pass the 25 mm
margin; provisional full-model warnings remain in [the preview](calibration/evidence/2026-10-21-social-left/model-preview-v6.json),
including reference housing overlaps. They are not physical clearance proof.

The [head/cloud update](controller-depth-cloud.md) now uses one articulated URDF
camera frame for both the model neck/head and depth projection. The untouched
blue head follows accepted commands, with explicit ghost edits retained.
The signed build and isolated model, render, projection, executor and gateway
checks passed; [validation identities](calibration/evidence/2026-10-21-social-left/ghost-wave-v7-validation.json)
record the exact source/build hashes. The previous build returned the physical
left arm to zero and inactive before relaunch. Rob independently confirmed the
physical arm hanging before v7 was loaded. Head-camera inspection was requested
and is being positioned manually through the existing safe neck controls.
The first v7 request ended with “Connect Vision Pro or iPhone and enable Action
Approvals. No arm operation was started.” The physical arm remains inactive;
a new authenticated controller connection and approval are needed for the
14.7-second wave. The next real approval reached the raised J2/J4 pose in 25.45 seconds including
preparation and measured settling, then refused the 0.606-second J5 segment
before submission because transport requires at least 0.65 seconds. The renderer
remained responsive; max recorded feedback age was 78.3 ms. V8 shares the
transport floor with the planner and uses a 0.7-second minimum, with a production
gateway regression for the shortest raised J5 segment. Live completion and
operator gesture acceptance remain pending.

### Embedded preview during execution and more upright J5

With the v8 3D scene open, the first attempt held on stale current feedback
before completing the wave. After Rob confirmed hanging again, a newly approved
full path with the 3D window closed reached both wave positions and ended at
raised rest in 31.43 seconds, including preparation and settling. It recorded
618 complete seven-joint samples with maximum feedback age 36.2 ms; the raw
current jump peak was 2.153 with cutoff still zero. [The trace and manifest](calibration/evidence/2026-10-21-social-left/trial-ghost-wave-v8-closed-scene.json)
preserve this distinction from the [open-scene interruption](calibration/evidence/2026-10-21-social-left/trial-ghost-wave-v8-open-scene-stop.json).

Rob requested more J5 rotation. V9 adds raised J5 −0.90 and −1.00, keeping the
accepted handoff and J6 −0.90/−0.60 wave. [Model tread sweeps](calibration/evidence/2026-10-21-social-left/model-preview-v9.json)
pass, with provisional full-model warnings retained. The prior build returned
through its full reverse route and verified hanging/inactive before reload.

The editor now keeps an embedded snapshot of the reviewed scene during controller
approval and execution. The live SceneKit view, mesh updates and depth-cloud
rendering pause during physical motion, leaving camera capture and the existing
feedback/recording/watchdog limits intact. Completion, refusal or interruption
restores the live scene; editing a pending proposal still cancels it. The isolated
render fixture exercises freeze/thaw and shared head/camera alignment without
any actuator transport. V9 live validation is pending.

### 2026-10-21 installation and trial request

The signed macOS Debug build passed, was installed at `/Applications/Cerebro.app`,
and passed `codesign --verify --deep --strict`. The installed build was launched
and the Arms controls were checked visually. Installed debug-library SHA-256:
`72f64b68406de81a4cb5fc0b6f7ab218405caccecf15248430446ddb6074325f`.

The left-arm executor fixtures, 60 controller-approval checks, Gemini protocol,
both realtime-provider adapter fixtures and show-rehearsal fixtures passed.
The paired-arm suite passed against the staged sources. The original working
tree's paired-arm suite still fails its occluded-jaw assertion because of the
operator's pre-existing disabled camera checks; the same failure was reproduced
on the task's starting sources. Those local edits were preserved outside this
change's commit.

Pressing **Wave left** in the installed app requested real controller approval.
It ended with **“Connect Vision Pro or iPhone and enable Action Approvals. No arm
operation was started.”** No motor trial or live current recording occurred;
actual waving, object retention and handoff remain unverified on hardware.

The next controller-approved wave reached position-mode preparation and recorded
101 fresh telemetry samples over 5.09 seconds, with all measured joint positions
remaining zero. It then ended with **“Gateway refused the left-arm command.”**
The first taught waypoint was rejected locally because the gateway admitted
only the older paired coordinator's running state. The gateway now also admits
an active, specifically approved physical-left trial, bound to its side, session,
camera/mode checks and an operation that permits arm travel. Stationary grip and
release approvals cannot authorize waypoints. Existing adjacency, timing,
feedback and joint bounds are retained.

Regression coverage now exercises the real gateway admission method with the
paired coordinator idle, including wrong-side, stale-session, skipped-waypoint,
short-duration, stale-feedback and revoked-approval rejections. The left-arm
executor fixtures also exercise the real trial authorization check at dispatch.
Both fixture suites and the signed build passed. The installed debug-library
SHA-256 for this correction is
`73391a5387b8963ccda239a2488ce8961b059e29410cedfb669c4d5d0515a0bd`.

After loading that correction, a fresh controller-approved wave completed with
**“Left arm waved twice and is holding in front. Gripper unchanged.”** The live
recording contains the six forward waypoints followed by 5 → 6 → 5 → 6, with
896 distinct telemetry samples over 45.776 seconds including preparation.
Final measured physical-left J1/J2 were −1.045152 and +0.600639 radians, within
the existing front-pose tolerance. The maximum recorded feedback age was
42.657 ms. Current units remain raw and the cutoff was 0 (record only); this
trial establishes measured movement and recording, not collision-force limits.
The local recording is `LeftArmTrials/left_wave-DAD663C6-3B55-47B1-9BC7-90D7696AA8FC.csv`
under Cerebro's Application Support directory. Its SHA-256 is
`976b8ac4770e8ef1411691120b8d29aaff03d9e0a7ce3a8cf47d56f54a422818`.

### 2026-10-21 green Grinch doll handoff

The initial Present / open run attempted calibration and opening, but Rob
reported that the jaws remained closed. A standalone physical-left calibration
was then accepted as command 110 at 13:41:48.670 local time, vendor response 1;
Rob reported no visible motion. A separate Open/Release command 111 was accepted
at 13:42:49.502, response 1, and Rob confirmed that the jaw opened. These results
do not establish mechanical calibration completion or a reliable delay between
calibration and opening. Do not treat either acknowledgement as observed opening.

An early Grip request was approved before an object was placed, producing an
empty close (command 114). The test was stopped and the empty jaw reopened
(command 116). For assisted tests, wait for the operator's explicit report that
the object is positioned before even requesting Grip; controller approval
remains the separate, mandatory runtime authorization. Likewise, confirm that
the receiver supports the object before requesting Release. Never infer either
physical condition from an acknowledgement or from a generic request to test.

After Rob explicitly reported the object in place, the stationary left-grip
operation accepted command 119 at 13:45:08.748, response 1. Rob confirmed that
the left gripper held a green Grinch doll. After Rob confirmed a hand supporting
the doll, stationary Release accepted command 122 at 13:46:57.683, response 1.
Rob then confirmed that the doll was back in hand and clear of the jaws. This
establishes an operator-observed grasp, hold and return with the arm in front;
it does not establish measured grip force or autonomous object placement.

The arm remained near J1 −1.046379, J2 +0.600093 radians. The jaw was left open
and no lower-arm command was sent. Automatic current cutoff remained 0 (record
only). The recordings contain the seven **arm-joint** currents, not measured
gripper current, jaw opening or grip force:

- `LeftArmTrials/left_grip-8E5F54AD-D769-4621-9730-FC93A22C612F.csv`:
  133 samples over 6.834 s; SHA-256
  `33471fad008d849038d97cd7e2f1f3fb31306d5655cd1a3f574a3c25ea113b6c`.
- `LeftArmTrials/left_release-D0408A99-05EA-452A-B674-C83F9D4B7825.csv`:
  125 samples over 6.581 s; SHA-256
  `b6d48b22eb6e25ec0f63f553f5eb47f68650cb471534840891fb775aff975541`.

### 2026-10-21 front-only J3/J5 trial

The empty left arm returned to measured hanging and inactive before relaunch.
The next real controller-approved wave used the tested approach, stepped J3 then
J5 to −0.30 rad, waved J1 between −0.90 and −1.05 rad twice, and held in front.
The camera used centered pan, lower 6011 and forward upper 6906. Rob confirmed
the position was better and clear of the treads, then requested further rotation
and a slightly downward camera because the gripper was visible at belly-camera
height but outside the head-camera image.

The recording contains 1,152 distinct samples over 59.413 s. Final J3/J5 were
−0.299569/−0.299978 rad; maximum feedback age was 35.868 ms. The current cutoff
remained 0 (record only). [Trial metadata](calibration/evidence/2026-10-21-social-left/trial.json)
includes the original CSV hash and compressed archive. The installed signed
debug library SHA-256 was
`5e8d36cb760c25808ada063493b496491248c8a6d4d1e61ad9dc268ad82f0ccc`.

The [model preview](calibration/evidence/2026-10-21-social-left/model-preview.json)
uses the bundled scan URDF/hulls and the recorded upright-coordinate prior,
with explicit positive driver-sign assumptions. It predicts approximately
42 mm additional hand height and 46 mm forward reach. The added segments pass
the model's tread-only swept check at 25 mm margin. Full-model checks flag
housing overlaps, including an unchanged right-arm/torso overlap and a
left-arm housing warning already present at the previously tested front pose.
These warnings remain in the record. No physical collision certificate,
calibrated force limit, or measured camera/model agreement is claimed.

Reproduce a model-only preview with the existing ShadowPlanner venv Python:
`Scripts/preview-left-interaction.py --output /private/tmp/left-interaction-preview.json`.
The script compiles the production waypoint table rather than maintaining
another copy of the targets. See the [ordered work queue](arm-motion-work-queue.md)
for ghost-motion review/approval and deferred camera-to-URDF calibration.

Following Rob's observation, the next candidate preserves all approach and
initial extension points, then adds another 0.30 rad on J3 and J5, one at a
time in 0.10-rad steps. It holds J1/J2 at −1.05/+0.60 until the new wave at
J3/J5 −0.60/−0.60. Reverse travel unwinds the complete extension before lowering.
The camera tilts down 300 Maestro target units from level to 6606, retaining
lower 6011 and all existing clearance/stationary checks. Stationary jaw actions
also accept either earlier tested front pose without moving a held object.
[The second model preview](calibration/evidence/2026-10-21-social-left/model-preview-v2.json)
retains the same explicit calibration assumptions and full-model warnings.

The initial return request was cancelled when Rob switched controller apps.
After the first new pose trial, a return stopped at the front during J5 unwind
because the camera/stationary-view interlock was lost. It requested hold at
approximately `[−1.049652, +0.599821, −0.299569, 0, −0.113446, 0, 0]` rad.
No new movement was dispatched automatically: a new controller-approved return
was requested from the measured point on the route. App replacement waits for
measured hanging and inactive status.

That approved retry reached measured hanging and inactive. After relaunch, the
larger controller-approved wave completed in 75.211 s with 1,476 distinct
position/current samples. Final J3/J5 were −0.599957/−0.607047 rad, inside the
target tolerance; maximum recorded feedback age was 48.366 ms. The camera used
centered pan, lower 6011 and upper 6606. No jaw command was part of the wave.
[Second-trial metadata and current archive](calibration/evidence/2026-10-21-social-left/trial-v2.json)
retain the full phase sequence, hashes and installed signed-library identity.
Current cutoff remains 0 (record only). The runtime reports the wave complete
and holding in front. Rob reported the test was running really well, then
requested inward J6 centering and an above-shoulder wave using J2/J4.

### Controller-input ghost gesture editor

Open **Settings → Arms → Ghost gestures…**, or **Development → Open Controller
Input Scene…**. The existing controller-input scene shows the captured robot
with fresh left encoder estimates and a translucent blue proposed robot. The
same segmented scan used to generate the pinned URDF collision surfaces is
bundled as `ShadowPlanner/robot-visual-rig.json`; its SHA-256 must equal the
surfaces' source hash before rendering. Other joints use the scan reference.
The upright encoder mapping is an explicit prior, not a measured calibration.

- **Center hand** adds J6 −0.10…−0.60 rad at the previously tested front pose.
  The first completed trial placed the modeled hand near the torso centerline
  (Y ≈ +0.034 m). Following operator feedback, the next candidate raises J2
  through +0.70…+1.00 rad, predicting another 0.186 m of height to Z ≈ 0.933 m.
- **Wave above shoulder** continues J2 to +1.30 and J4 −0.10…−0.60,
  then waves J1 twice with a J6 −0.70/−0.60 bend. The model predicts
  Z ≈ 1.276 m versus shoulder ≈ 0.947 m.
  Centering/lowering reverses every raised waypoint before unwinding J6/J5/J3.
- Select any named movable URDF joint for preview, or move the left-hand XYZ
  target with fields/2 cm nudges. **Add pose**, **Save gesture**, **Review path**,
  then play at ×4 or scrub the complete proposed route.
- Physical custom execution currently supports only the left arm inside the
  supervised front workspace. Other servos can be previewed/saved; execution
  rejects unmapped axes. Custom paths return through their approved points to
  center. Do not use these empty-arm gestures to carry a held object.
- **Request execution of reviewed path** asks the authenticated iPhone/Vision
  controller to approve the exact proposal hash. Keep that controller open.
  Editing cancels this editor's pending request; changed feedback/session/model
  requires review again. Requests bind URDF, scan geometry, mapping, initial
  measured angles, all targets and durations. The gateway admits only the
  currently authorized proposal ID and step; neither UI nor gateway callers
  can replace its targets. Playback changes no actuator state.
- **Stop + hold** cancels further targets immediately. **Review stopped return**
  offers a newly approved reverse of the remembered path in the same session;
  it never automatically resumes or invents a path after relaunch.
- Each execution records seven measured arm currents/positions to CSV and the
  exact proposal to a matching `.proposal.json`. **Replay current recording…**
  animates measured positions, approved targets and the largest per-sample
  current change, with all seven current values at the cursor. Incomplete or
  non-finite data is rejected. Missing manifests hide the approved ghost.

The total scheduled path is capped at 135 seconds, with a 170-second executor
and 180-second controller execution limit for ghost operations and supervised
left-arm travel. The longer handoff/wave route needs this allowance for camera
preparation and settling. Jaw-only, other manual operation and approval-review
deadlines are unchanged. Fresh camera,
feedback/modes, ownership, session binding, leased motion and holds remain.
Current cutoff **0 remains record-only**, not collision/force protection.

[The new model-only sweep](calibration/evidence/2026-10-21-social-left/model-preview-v5.json)
retains full-model warnings, including provisional neck/arm margins at the
raised pose; tread-only sweeps pass 25 mm. The images and model do not certify
physical clearance. Test J6 centering first, then the raised wave with direct
supervision. Camera-to-URDF calibration remains queued after this workflow.

The first controller-approved ghost **Centered handoff** completed 24 steps in
89.098 s (75.715 s scheduled), recording 1,640 distinct seven-joint samples.
Final J6 was −0.5870 rad within tolerance of −0.60; maximum feedback age was
172.330 ms and peak current change 1.6171875 raw units. Jaws stayed unchanged.
Rob reported that it looked great, requested more J2 height and a lower face
camera, and confirmed the embedded controller window stayed stable while
resizing. [The exact proposal and current archive](calibration/evidence/2026-10-21-social-left/trial-ghost-center.json)
retain the hashes and signed-build identity. The next candidate adds the J2
handoff lift and changes the interaction camera from upper 6606 to 6306
(about 18° below compensated level), preserving lower 6011 and centered pan.
The separate controller-approved higher handoff then completed all 28 steps in
100.264 s (87.738 s scheduled), with 1,882 distinct current/position samples.
Final J2/J6 were +0.986793/−0.599412 rad; maximum feedback age was 145.365 ms
and peak raw current change 1.53125. The jaws stayed unchanged.
[Its exact proposal and CSV archive](calibration/evidence/2026-10-21-social-left/trial-ghost-center-higher.json)
retain the signed-build identity and hashes. Operator assessment of this higher
pose/camera pairing was positive: Rob confirmed both height and camera view
look good and described the tested ghost/servo alignment as extremely accurate.

The first raised ghost wave subsequently completed its 10-step path from the
higher handoff in 38.818 s, recording 725 distinct samples with maximum age
113.864 ms. Rob requested a higher J2 and a stronger J6 bend between waves;
this candidate is not the final taught wave. [Its proposal and currents](calibration/evidence/2026-10-21-social-left/trial-ghost-wave.json)
are archived. The next preview increases raised J2 from +1.20 to +1.30 and
adds J6 −0.70 at the outward wave, returning to −0.60 between waves. All
handoff/approach points remain unchanged. The existing 25 mm model-only tread
sweeps pass; provisional full-model neck/arm warnings remain visible.

See [head-angle depth projection](controller-depth-cloud.md) for the correction
requested after the accurate handoff test: the controller cloud now uses the
URDF camera mount, accepted head angle estimates, frame intrinsics and matching
model scale. No URDF calibration or automatic force threshold was inferred from
the operator's positive visual observation.


## Existing paired operations

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
