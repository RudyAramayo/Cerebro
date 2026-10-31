# ROB incidents, mistakes and operating lessons

This is the durable recall ledger for the recycling/animation sessions through
October 31, 2026. Start with the [current handoff](calibration/session-handoff-2026-10-31.md).
**No further arm motion is currently authorized.** Historical instructions and
successful moves below are evidence, not permission to replay them.

Dates come from repository steering and saved tests where available. Earlier
events without timestamped records are explicitly operator reports. "Fixed"
means the named implementation was changed and checked; it does not mean every
physical failure in that subsystem is explained. Current detection and geometry
limitations apply even when a test reported native target completion.

## Incident ledger

### ROB-01 - Whole-system power loss and right J5 smell

Earlier session, operator report: the computer restarted and an arm fell. Rudy
suspected overload/brownout on the 24 V supply feeding downstream converters;
he distinguished that from an arm-only 48 V loss or computer-only 12 V loss.
He also reported a slight burning smell at RIGHT J5, then confirmed inspection
and successful testing. No synchronized supply voltage/current trace established
the electrical cause. Do not state that the converter rating was conclusively
exceeded, or that later CAN/motion incidents share this cause. Power loss while
raised can drop an arm; software hold cannot be assumed to survive it.

### ROB-02 - CAN interruptions, connectors and ambiguous reset state

Repeated left/right motor and gripper reply losses required operator service or
power cycles. Rudy reported weak connectors, applied DeoxIT, later serviced the
right gripper and explicitly finished service before Test 11. Left J5-J7/jaw
losses and all-right feedback absence were observed in different episodes.
Connection restoration is not proof of reliable contact, jaw calibration, pose
reference or payload release. Retain per-node ages and original timestamps.
Never restart cores, set zero or replay a trajectory merely because an old mode
cache is empty. On October 31 Stop had 68.272-second-old right feedback; report
"Stop requested; not measured" rather than claiming the bus confirmed a hold.

### ROB-03 - Position-mode re-entry caused both arms to drop and rebound

October 30: the arms were already in position mode, but after app relaunch the
cache did not know it. Reissuing position mode sent ACTIVE -> POSITION -> Hold.
Rudy observed both arms briefly shut down, drop hard, and bounce back. This was
a commanded mode-entry error, separate from later trajectory faults. Commit
`ed6736a` added read-only mode refresh and avoided redundant mode entry.
Never use a torque-changing command to answer a state question. Even an app
restart that does not itself power off the arms must not trigger mode replay.

### ROB-04 - Bow and folded-hands paths hit the treads / twisted an arm

October 29: Rudy reported a right gripper/tread collision with a current spike
during the bow; later the left arm twisted after the lift. Hands Folded Up at
about 50% also collided with the treads. He stopped/reset the arms. Entry order
was wrong: shoulder/elbow clearance must precede wrist twisting/inward folding.
The revised shared entry retains J3/J5-J7 through the lift, then changes wrist
orientation at the raised hold. Rudy reported slow playback worked and asked to
narrow excessive width; preserve his saved 25% speed rather than infer a new
setting from the verbal "10%." A pitch-only variant was rejected for modeled
torso proximity. Physical narrow-path commissioning remains distinct from
passing a model check. A functioning current trip is useful evidence, not proof
that contact or subsequent repetitions are acceptable.

### ROB-05 - Animation scheduling and violent handoff/reversal

The generic error "Animation target/rate/feedback changed before dispatch;
increase transition time if needed" occurred after outward motion. The scheduler
could advance before actual arrival and used planned instead of measured start
values. It was changed to wait for actual duration/settling and size the next
paired transition from fresh feedback, preflighting both arms before either.

October 30 separately recorded physical LEFT J6 moving from roughly +0.34 rad
toward -1.84 rad after a handoff whose new target was +1.05 rad. This was not a
successful grasp. Rudy described simultaneous-command behavior as violent and
said similar motion had previously snapped an arm cable. The exact reversal
cause remains unknown. Running cores used separate DualArmL/DualArmR extracts;
their on-disk URDF velocity numbers were 1,000,000, not the assumed modest limits.
Launch constraints, firmware behavior and Cerebro's rate ceiling are distinct.
Untimestamped Drake/core logs do not prove a kinematic-collision cause.

The [October 31 controller investigation](calibration/arm-transition-review-2026-10-31.md)
subsequently found detached per-target Ruckig workers and unsynchronized
commanded-state derivative sampling in the installed binary. Its isolated
Ruckig 0.9.2 experiment reproduced a large backward excursion when a forward
target was seeded with a hypothetical missed-sample acceleration. The original
internal seed was not recorded, so this does not prove the historical cause.
A persistent planner retained coherent derivatives through 155 moving target
changes in a bounded offline test. No production controller/model fix was
deployed; the physical head-strike/model mismatch remains separate.

Operational mitigation: one coordinated target at a time, measured completion
before another, no independent command interleaving. Compatible joints and both
arms may belong to the same reviewed target. The local rate ceiling was raised
to 0.30 rad/s in `20aeab5`; this is not a firmware reversal fix. Faster movement
does not justify removing arrival/current/feedback checks.

### ROB-06 - Mirror, roll direction and pose geometry assumptions

LEFT J5 and several wrist adjustments moved in the wrong apparent direction.
Rudy specified the existing Mirror L10 -> R11 and reverse logic. An intervening
J5-only sign assumption was not established calibration. Anatomical clockwise
depends on viewpoint; command direction must be tied to the actual joint and
observed result. The startup hanging pose varies; do not infer identical encoder
zero from visual hanging. Diagnostic arm lines were corrected from straight-arm
to hanging-reference geometry in `2feb590`; that display fix did not commission
the physical arm/camera transform.

The October 29 raised camera image is the alignment reference. Keep diagnostic
joint snapshots but do not make them an automatic calibration pose. Later saved
tucked gestures are authored assets, not a replacement for that image.
Test 11 predicted a horizontal gripper that was physically vertical; an observed
local J7 correction was needed. This discrepancy remains evidence to investigate.

### ROB-07 - Over-limit wrist target added after planning

October 31, stage 162: an extra 60-degree J7 amendment after IK produced about
171.05 degrees, beyond the private planner's 120-degree range. Feedback stopped
near 120 degrees; settling timed out after 14.754 s and correctly prevented an
automatic next segment. The agent bypassed its own final-range review by editing
the target after planning. The private dispatch helper now rejects nonfinite
arm values and values outside +/-120 degrees **after every edit**; inert checks
covered boundaries, NaN/infinity and the failing target. This helper is outside
Git, not an installed native fix. Native raw limits are broader, so that mismatch
is still open. Do not widen bounds to make a rejected move run.

### ROB-08 - Right arm struck its face during the lift

October 31, stage 164, 13:27:32-13:27:35 PDT. Rudy explicitly confirmed the strike
occurred during the upward lift. Seven joints were dispatched together and
followed to native completion; no next arm target, position-mode re-entry or
core restart was sent during it. The agent's model clearance assessment was
wrong for the physical robot. Replay of 25 measured samples still predicts no
head/arm intersection; maximum joint-line deviation was about 0.531 degrees.
The wrist fills the end image, limiting observation. The 110 mm modeled tool
offset is unmeasured; camera gravity disagreement is 16.224 degrees with body
lean/mounting ambiguity. No exact URDF-axis/zero/firmware diagnosis is established.

Rudy recovered RIGHT to powered-on hanging/reset, blue status. The second can
was not verified retained. Detailed times, measurements and limitations are in
the [handoff](calibration/session-handoff-2026-10-31.md) and
[numerical audit](calibration/evidence/2026-10-31-test11/lift-audit.json).
The failed target is retained as forensic evidence only. Do not replay it.

### ROB-09 - Later unchecked neck sweep and an unshipped false-positive fix

After ROB-08, neck targets were sent without reviewing the held-arm sweep; a
third target was sent after right feedback had gone stale. Offline review of
the first neck movement predicts new camera/arm overlaps up to about 51 mm.
This is a separate admission defect, **not the cause of the earlier initial
strike**. An early explanation wrongly emphasized the neck before the timing
was known; that attribution is withdrawn.

A candidate native asynchronous sweep check compiled, but a normal hanging-arm,
small-pan fixture still failed (`upper_neck_link / left_one_Link`) after convex
shape refinement. It was not installed and was removed from shipping source.
Private source/tests are preserved for investigation. Neither a passing compile
nor a conservative bounding-box collision establishes a working physical fix.
Do not relax overlaps to get a green test or claim the shipped CLI now guards
neck/arm sweeps; it does not contain this candidate.

### ROB-10 - Jaw acknowledgments, startup calibration and crushed/stuck cans

Hold/Release acknowledgments repeatedly failed to correspond to visible jaw
movement, especially after arm resets. Empty startup calibration closed with
substantial force and may have caused some crushing; intensity alone was not
measured as the cause. Rudy restored normal Hold 2 / Release 10 values, with
optional Hold 1 remaining available. Intensity is a vendor parameter, not force
feedback. Passive startup avoids automatic full-travel jaw calibration.

October 30: after a shutdown with a can held, Rudy specifically authorized
in-place calibration over the bucket and Hold/Release recovery. He confirmed the
can was crushed during calibration and then dropped successfully. Preserve
possible payload through reconnect; this supervised empty-can recovery is not
a general procedure for arbitrary objects or a reason to recalibrate every grip.

October 31: multiple Hold 2 acknowledgments did not establish retention. Empty
calibration and an isolated native RIGHT Hold 5 / Release 10 visibly operated
the correct jaw. Passive trace put node-8 Hold 5 on CAN10 only. Rudy confirmed
there were no manual jaw changes. The agent's earlier visual swapped-arm routing
hypothesis was wrong and was retracted; do not swap CAN mappings. The ordinary
CLI still accepts Hold 1 or 2 only; native panel Hold 5 is not a new CLI setting.

An earlier crushed can caught on one jaw released after the wrist was rolled
in the direction appropriate to that particular catch. The first roll was the
wrong direction. Do not turn that incident into a universal wrist-roll rule.

### ROB-11 - Missed grasp geometry, nudges and poor return paths

Several near reaches were 2-4 inches short by operator observation; fallen
cans required angled approaches, not necessarily strictly vertical ones. In
Test 11 a fingertip was mistaken for the center between both pads. Repeated
approaches nudged the can away or toward the table edge. Reacquire after contact
or an operator relocation; do not keep approaching the old point. Requested
left J2 lifting was cancelled when Rudy moved the can; the cancelled target was
not sent. A closure needs a short observed retention check before transport.

A generic post-drop lift approached a shelf. Return directly along a checked
path to grasp-ready when possible rather than automatically going higher. A
drop that bounced off the backpack and landed was operator-confirmed success,
but is not an acceptable placement model. Favor low releases above the opening;
accepted Release is not measured opening or a verified landing.

### ROB-12 - Torso controls, untrusted counts and startup deadlines

Earlier UI energize/deenergize and slider/takeover behavior prevented direct
control. Native controls and direct count targets were added; the full rotation
test was eventually operator-confirmed successful. Early endpoints were short
(about 50 degrees when 90 was expected); manual fine trims and count reset are
historical commissioning, not a current reference. The initial observations
were about -8907 for left 90 degrees and +9091 on the other side from zero.

Rudy confirmed a 3000 pulses/second TIC ceiling. A "step" in that API is an
issued pulse/microstep count, not independently measured table rotation. The
rough 400:1 gearing estimate must not be applied again to an empirical counts
calibration. Too-fast motion skipped/stalled; an excessively slow taper also
hesitated. Preserve a reliable ceiling and verify physical travel.

Blocked steppers can lose count alignment. Homing wiring/limit sensing is not
commissioned; use an observed software reference, not a claim of homing. A
slipring permits rotation, but temporary 16-foot debug cables need unwinding.
Hanging grippers can catch the treads; body rotation is not safe simply because
the stepper can turn. Focus-loss used to cancel finite turns; retain manual
held-input release behavior while distinguishing it from a bounded command.

Test 11: USB setup consumed the initial supervision deadline before movement.
Hiding windows did not fix it. `d492753` renews only the same finite target through
energize/status setup, publishes actual preflight feedback and checks zero speed.
Subsequent physical turns succeeded. Later independent 500 ms TIC freshness
expiry and count-jump interruptions remain unresolved. A software reference is
invalidated by uncertainty; count arrival alone is not physical angle evidence.

### ROB-13 - Tread traction, SLAM drift, elevated obstacles and LACT

Rudy observed that roughly 30-50% tread demand may be needed for traction and
requested gentle/medium/aggressive acceleration modes, slower than a 150 ms
step. A gentle ramp took about 0.96 s to reach 40%; tiny presses could be mostly
below useful traction. In Test 11 AX clicks/short keyboard holds did not prove
travel; foreground coordinate holds did, with video evidence. A 20-second
passive monitor is not a 20-second drive command. Do not derive travel solely
from SLAM corrections, especially after manual base rotation.

Fixed RPLidar maps the tread base/walls, not torso yaw or tall table collision
clearance. Combine fresh map localization with elevated RGB-D and reobserve
after body changes. A table can block raised arms even when the floor route is
open. Native markerless torso registration failed this scene; count-92 forward
was an agent visual estimate corroborated by history, not certified alignment.

Floor pickup required retreat, elbow folding with upright grippers, LACT lean,
neck adjustment, extension and small base/torso corrections. The first proposed
retraction/lean approached the table; Rudy corrected it. A claimed LACT action
had not actually pressed its control; operator pressing worked. Later return
used his explicit 3-second then 1-second holds. Keep actual durations/direction
in the ledger. LACT lacks position feedback; timed output and published actuator
speed do not measure lean angle or guarantee a symmetric return under load.

### ROB-14 - Attention, false spoken stops and assistant speech feedback

Repeated shoulder inspection continued after the arms were already ready,
wasting time and taking the view away from cans/grippers/bucket. A Head Tracking
checkbox also reasserted face tracking after local neck targets. Head ownership
must follow the task while respecting whole-robot geometry; accepted targets
are not measured arrival. Under-table work benefited from lower/upper neck
coordination rather than assuming the current camera could see the target.

Background conversation containing "Hold" or "Stop" interrupted recycling; Rudy
explicitly identified several as not directed at ROB. Do not treat those past
clarifications as permission to ignore a future direct Stop. The latest issue is
external `say`/`sayit` feeding assistant updates back into Gemini/local ASR.
The speech CLI was unfinished at the original handoff. The continuation now
implements [`speech.say` / `speech.status`](local-control.md#assistant-status-speech),
with explicit assistant provenance and suppression of both microphone consumers
through speech and its acoustic tail. Verify the running operation list before
use. Native ordinary `sayIt` mutes Gemini audio but local negative Stop still
listens, so merely wrapping it is insufficient. Do not inject announcements as
user input, arm authorization or new Gemini requests. Keep microphone history
and assistant-output provenance separate.

### ROB-15 - Debug latency, recording, crashes and handoff failures

The user requested DEBUG/Development Mode age budgets of 1200 ms for camera and
arm/gripper feedback; normal limits and timestamps remain intact. Torso control
has an independent 500 ms debug interval: substituting 1200 ms caused its
validator to reject commands. Do not globally replace every timeout.

Diagnostics materially reduced sample cadence. Closing them often raised video
from roughly 4 fps to 18-20 distinct fps; some later clips fell back to 13-14 or
4.36 fps. Recorders request 24 fps and retain real exposure timing with audio.
Never duplicate frames to claim the requested rate. The first-can delivered
clips have approximately 18-19 fps and 48 kHz AAC sound. Stage 069 recorder failure
and a trace file hitting its size cap are known evidence gaps, not missing
successes to invent. Unavailable Insta360/belly streams cannot supply clearance.

Rudy reported several Codex/process crashes or restarts during earlier work;
the precise causes were not captured. Context compaction also caused a long
gap during Test 11. Reconstruct from a durable checkpoint before acting; never
interpret lost conversation context as robot reset or task completion. Save
the current task, current instruction, last dispatched action, measured result,
pose/payload uncertainty, unresolved causes, build and next non-actuating work.

Test 11 took 165m47.5s for one verified transfer. Native arm and torso windows
were only about 174s and 82s; still fetch time was about 3.35s. These do not make
the remaining wall time measured camera latency. Track planning, perception,
communication, builds, retries and human wait separately. Pair grasps when
feasible, use torso shuttling to reduce base travel, overlap provisional depth
with preparation, and minimize unnecessary target boundaries **after geometry
and control are reliable**. `48b96bf`/`8f01130` supply local overlap/perception
work; Test 11 stage 030 actually overlapped 13 depth-region calculations with
wrist travel. Earlier stage 011 did not and gets no overlap credit.

### ROB-16 - Repeated approvals, tiny probes and excessive decision gaps

Earlier recovery work replaced the requested full coordinated lift with tiny
roughly 3 mm checks and returns. Rudy explicitly rejected that behavior and
asked for the complete grasp-ready movement, with the sweep cleared and his
authorization already given. Adding another arbitrary micro-step restriction
after being asked to remove the first did not satisfy the task. Manual gripper
and torso controls also unexpectedly requested voice authorization when a local
operator was already using the access panel. Respect explicit local task scope;
do not repeatedly ask the same permission or invent a spoken grant to satisfy
an implementation bug. Explain a concrete unresolved physical/state problem
when one exists, and fix routine command plumbing in software.

The user repeatedly requested larger coordinated moves at a reliable speed,
paired grasps, fewer camera-settling delays and less shoulder inspection. Prefer
native execution of a complete reviewed segment, local computation and observed
completion over a long sequence of LLM-issued nudges. This lesson is compatible
with the later explicit no-motion instruction: prompt execution of an authorized
task never means ignoring a subsequent stop or pretending unresolved geometry
has been commissioned. Distinguish slow planning/interaction from slow motors
when reporting optimization progress.

## Durable design lessons

| Topic | Rule to retain |
| --- | --- |
| State and evidence | Distinguish requested, acknowledged, joint-arrived, physically clear, jaw moved, can retained and can landed. Each is a different observation. |
| Local controls | An authorized access-panel/CLI task should not repeatedly demand a voice grant. Keep task identity, ownership and Stop; do not manufacture spoken authorization. The current explicit no-motion instruction still governs. |
| Animation data | Stable pose/clip/sequence IDs and revision checks replace table-row identity. Sparse channel masks allow one-arm edits. Clips own snapshots; import/edit/ghost preview never actuate. |
| Playback timing | Ghost Play/Loop and 0.25x-4x preview speed do not imply robot looping. Per-sequence 25-200% arm timing is separate from the native 0.30 rad/s cap and from timed LACT output. |
| Other tracks | Include neck, appropriately named Maestro channels, torso and timed LACT without reassigning Bubble-owned Maestro 6-9. Do not call command estimates position feedback. |
| Greeting animations | Japanese bow entry must satisfy the same lift-before-twist geometry. Greeting after successful completion only; cancelled/previewed animations do not speak or resume hardware. |
| Local/offline execution | Keep perception workers free of actuator access; let bounded native executors own motion/feedback. Pixel/depth files and structured status avoid expensive UI sampling. End-to-end autonomous offline paired recycling is not yet demonstrated. |
| Sharing and privacy | Current destination is direct God, overriding old God Squad entries. Verify destination and delivery; inspect images before sharing. Keep raw camera/audio/log material outside Git; commit sanitized findings for recall. |
| Software validation | A compiled app, passing inert fixture or clear modeled path is not physical commissioning. Record failed candidates and unresolved causes; never present them as installed fixes. |

## Adding the next event

Give each incident a stable ID; record date/time/timezone, actual user report,
command ID and source revision when known, pre-command feedback age/mode, exact
observed outcome, stop/recovery action, and a private evidence path/hash. Separate
operator observation, recorded telemetry, model inference and hypotheses. State
what was changed, how it was validated, whether installed, and what remains
unproven. Correct earlier attributions explicitly when new timing/evidence arrives.
Add a fresh-session checkpoint before context transfer; do not replace this
ledger with only a chat summary.
