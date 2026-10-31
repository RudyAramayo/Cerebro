# ROB session handoff - October 31, 2026

## Start here

**Rudy's latest instruction is: "do not run anymore arm motions as of now."**
He requested a context switch and repository records of the mistakes, crashes,
errors and unusual arm/hand movements. This handoff is not authority to resume
recycling. Do not run an animation, return-to-hanging routine, mode transition,
gripper calibration, encoder reset or arm-core restart as handoff cleanup.
No further robot motion was performed while preparing these records.

Read the [incident and lessons ledger](../robot-incident-lessons.md), then the
[Test 11 evidence summary](evidence/2026-10-31-test11/summary.json) and
[timestamped motion windows](evidence/2026-10-31-test11/motion-windows.csv).
Earlier context is in the [October 22 handoff](session-handoff-2026-10-22.md).
The current instruction overrides older standing recycling authorization and
historical recovery instructions in `AGENTS.md`.

## Last reported physical state, not a new live inspection

| Component | Last evidence and uncertainty |
| --- | --- |
| RIGHT arm | Rudy recovered it after the incident: powered on, hanging/reset, blue status. Fresh zero/inactive feedback followed recovery. These zeros are not the former raised reference. No new mode or target was sent after recovery. |
| LEFT arm | Last held the saved tucked grasp-ready pose. No later suggested left J2 lift was sent; Rudy cancelled it after moving the can. Do not deactivate or re-enter position mode to refresh its state. |
| Payload | One can was verified in the orange bucket. The second can was never verified retained or delivered; final evidence still showed it near the table edge. A previously accepted Hold 5 does not prove possession. |
| Neck | Last commands were pan 6000, lower 6600, upper 6600. These are commanded Maestro targets, not measured arrival or verified clearance. No head movement during this handoff. |
| Torso | Last reference was count 92 as forward, inferred from camera/history. Its reference and current physical angle need revalidation in a future authorized task. The tread base had also turned during the second approach. |
| Treads / LACT | Tread demand was stopped. No LACT movement occurred in Test 11. Do not infer a measured lean position from old timed output. |
| Cameras | Front RGB-D worked during the run. Insta360 was unavailable; belly camera supplied no frames. No new camera capture was needed for this handoff. |

A **14:01 PDT read-only status check** supersedes the earlier left-hold telemetry:
both arms now report mode/status 0 with fresh roughly 31-32 ms feedback; RIGHT
is zero and LEFT is near zero. No animation is running and the mission is paused.
The app session differs from the test session; this handoff did not restart it.
Neck command state is now unknown. Torso hardware is unselected, software
reference unset and current count unavailable; stored front count 92 is only a
historical preference. Passive startup and quiet diagnostics are enabled.
There was no new camera inspection, so inactive/near-zero feedback is **not** a
new claim of physical hanging or calibration. See the
[sanitized status record](evidence/2026-10-31-test11/handoff-state.json).

The installed/running app corresponds to `d492753` (torso startup repair),
not the later unshipped neck-check experiment. No app relaunch or replacement
was performed for this documentation handoff. The cached Xcode product may
contain an experimental neck check; **do not install that cached product**.
A future build must come from the reviewed source revision.

Repository: `~/dev/Cerebro-current`; branch `codex/manual-gripper-session`;
configured remote `origin`. The handoff commit contains documentation and
sanitized numerical evidence, not a new motor-control implementation.

## Test 11 outcome and timing

Physical test window: **10:43:56.683671-13:29:44.151362 PDT**, October 31.
The end is the CLI Stop request after the incident, not proof of a measured
stop. Total wall time was **165 minutes 47.468 seconds**. Outcome:
**one verified transfer of two requested**, with the second attempt interrupted.

| Measured work | Recorded time |
| --- | --- |
| 35 arm target/arrival-monitoring windows | 173.549 seconds |
| 13 torso command/monitoring windows, including failures | 81.772 seconds |
| 112 still-image fetches | 3.345 seconds of fetch time |
| Initial five-stage paired preparation | 28.430 seconds of native motion/monitoring |

These windows do not account for all wall time and are not necessarily disjoint.
The remainder includes planning, visual interpretation, UI/tool work, messages,
context compaction, calibration, failed attempts and a software build. Do not
label every gap "camera settling," nor infer CPU time or energy from wall time.
Image fetch latency is different from exposure age. Software diagnosis/report
work after 13:29:44 is outside the physical test window.

The first release was **12:03:51.122 PDT** (stage 076), verified visually.
The earlier carry/release video at stage 069 failed to record despite physical
motion completion; it must not be represented as a successful recording.

## Right-arm/head incident: corrected interpretation

Rudy explicitly placed the strike **"During the upward lift."** This supersedes
the earlier tentative association with later neck movement.

| Time PDT | Evidence |
| --- | --- |
| 13:24:39 | Stage 162 requested J7 about 171.05 degrees after an agent-added wrist amendment. The original planner's 120-degree bound was bypassed by that edit. |
| 13:24:54.082 | Hardware feedback stopped near 120 degrees. Native motion ended "did not settle" after 14.754 s and did not advance automatically. |
| 13:25:41.731 | Native calibrated-panel RIGHT Hold 5 accepted; no verified retention. |
| 13:27:32.565 | Stage 164: one coordinated seven-joint target, modeled 10 cm lift and 1.5 cm retreat, requested duration 1.771843 s. Orientation slack was 5.39 degrees. |
| 13:27:35.344 | Native target completion, 2.780 s including monitoring. The wrist filled much of the camera image. Rudy identifies this lift as when the strike occurred. |
| 13:28:18.728 | Later neck command: 6000 / 6600 / 5750. It had not been checked against held-arm geometry before dispatch. |
| 13:28:34.652 | Upper neck changed to 6950. |
| About 13:28:35.9 | RIGHT feedback ceased; gateway stale-state log at 13:28:36.243 corroborates the time. Cause is unknown. |
| 13:29:18.823 | Upper neck changed to 6600 without fresh right-arm feedback. Another admission gap. |
| 13:29:44.151 | CLI Stop requested. RIGHT feedback was 68.272 s old, so CAN could not verify stopped state. |
| About 13:30-13:31 | Operator recovery restored zero/inactive feedback; Rudy confirmed hanging/reset, powered on, blue status. |

No overlapping arm target, repeated position-mode command or arm-core restart
was sent by Codex in this incident. This does not prove the motor firmware,
connectors or power system were healthy. Untimestamped Drake/core messages
cannot assign a specific internal failure to this lift.

Offline replay of **25 actual feedback samples** predicted **no head/arm
intersection**, despite the operator's physical report. Maximum deviation from
the nominal synchronized joint line was approximately **0.531 degrees**. This
points to an inadequate physical geometry/registration assessment, not evidence
that native completion certified a safe path. It does not establish an exact
URDF-axis, encoder, tool-offset or firmware cause.

The modeled camera-up direction disagreed with recorded IMU up by **16.224
degrees**. Unknown LACT/body lean, camera mounting and neck reference are included
in that disagreement. Do not apply it as a global correction. The model's 110 mm
tool offset is explicitly unmeasured; its reference is simulation-only.

Replay of the first *later* neck sweep predicted housing/right-arm intersections
of about 51, 18 and 21 mm, plus about 8 mm at upper-neck/left upper arm. These
are provisional model overlaps, not contact measurements or the cause of the
initial strike. A candidate native head/arm check was written and compiled, but
its normal hanging-arm/small-pan fixture still reported an overlap. The candidate
was **not installed**, was removed from the shipping source, and is preserved
privately for offline investigation. Do not claim this incident is fixed.

## Speech CLI: requested, researched, not implemented

Rudy reports that external `say`/`sayit` output is picked up by Cerebro, becomes
contextless Gemini input, and can trigger inappropriate replies/arm interruptions.
He requested command-line speech through Cerebro with listening paused. Before
implementation began, he requested this context switch. **There is no new
`speak` or `speech.say` command in this handoff.** External `say` is paused to
avoid continuing the reported feedback loop. Written updates go to direct God.

Source locations and the concrete continuation plan:

1. `Scripts/cerebroctl.py` and `ROBLocalControlProtocol.swift`: add a bounded
   `speak --text ... --source codex` command, optional stdin text, and asynchronous
   utterance ID/status/optional wait. Reuse the same-user socket/session admission;
   do not retry a lost response or send spoken text as a new user command.
2. `ROBSpeechBox.m`: normal `sayIt:completion:` already mutes raw Gemini buffers
   through `isSpeaking`, but **local priority Stop deliberately precedes that
   gate**. Simply exposing `sayIt:` can still hear our own "stop" or "wait."
   Add a temporary assistant-status scope that pauses both input paths before
   synthesis, invalidates the debounce/recognition generation, and resumes a
   fresh recognizer after the queue and a short acoustic-tail interval.
3. Scope pause/resume to CLI assistant output. Preserve ordinary speech's local
   interruption behavior, UI/hardware Stop, saved microphone preferences and
   wake-window behavior. Test cancellation, shutdown, queued callbacks, repeated
   speech, stale transcripts and restoration without leaving listening disabled.
4. `ROBMainViewController.mm`: configure the new speech seam where the local
   service is configured; do not depend on Torso Servo Controls being open.
   Append a source-labelled assistant/status transcript, never `inputText:` or
   microphone authorization. No new Gemini turn is needed merely to announce
   status. Describe provenance truthfully; full cross-agent context sharing is
   not implemented by this proposed announcement path.
5. `Tests/ROBSpeechPriorityStopRuntimeTests.py` executes extracted real method
   bodies with inert audio/actuator seams. Extend it to cover both muted paths
   and delayed callbacks while preserving normal speech Stop. Existing local
   socket tests live in `Scripts/test-local-control.sh`.
6. Build and review the new implementation before installing. An eventual speech
   smoke test must not actuate the robot or resume the interrupted mission.

## Saved gestures and authoritative references

Animation library revision 16 in `~/Documents/ROB Animations/library.json`
contains `Left Tucked Grasp Ready` and `Right Tucked Grasp Ready`, each scoped
only to its seven arm joints. The right geometric mirror was reviewed and
reached; a raw native mirror candidate predicted new torso overlap and was not
sent. These are authored gestures, not encoder-zero calibration.

Rudy's accepted raised alignment **camera image** remains the calibration
reference in `~/Documents/ROB Animations/Calibration/2026-10-29-raised-alignment/`.
Saved joint values are diagnostic context, not an automatic replay after reboot.
The tabletop, wrist, jaw and head geometry still need independent validation.

Physical routing remains RIGHT -> vendor L10/gateway `left`/CAN10, and LEFT ->
vendor R11/gateway `right`/CAN11. Isolated Test 11 Hold 5 traffic and jaw images
confirmed this mapping. The earlier swapped-routing diagnosis was retracted.

## What the next session can do without robot motion

1. Read this handoff and the latest user instruction before touching runtime
   control. New context does not end the no-arm-motion instruction.
2. Implement and inert-test the speech CLI above. Verify that current code does
   not already contain a newer implementation before editing.
3. Reconcile the physical arm/tool/head/neck geometry using recorded evidence.
   Compare raw feedback, chain conventions, start references and modeled solids;
   do not guess global joint signs or declare calibration from one view.
4. Preserve the failing head-check fixture. Diagnose its baseline overlap and
   model approximation; do not simply relax it until it passes.
5. Promote the private final-target validation into an appropriate reviewed
   native path if justified. The private runner now rejects nonfinite targets
   and arm values outside +/-120 degrees after all edits. This is not a
   demonstrated hardware-wide fix and is not a physical-clearance check.
6. Improve bounded local planning, perception, timing and grasp-state ownership
   using offline fixtures. Paired grasp, remote-bucket navigation and reliable
   internet-free end-to-end recovery remain uncommissioned.

Any future physical commissioning is a separate step after Rudy changes the
current no-motion instruction. Fresh evidence is required; this document is
historical, not a live robot-state snapshot or an executable recovery script.

## Evidence, report and communication

Private evidence root: `~/Documents/ROB Test Reports/2026-10-31/test11/`.
It contains `events.jsonl`, numbered RGB-D captures, motion videos, native
command/review JSON, `incident-evidence/` gateway/core logs, `168-incident.json`,
`171-lift-geometry-audit.json` and its replay script. The unshipped neck candidate
is in `unshipped-head-sweep-candidate/`. Camera images, audio/video, contact
information and raw logs remain outside Git. Sanitized numbers and conclusions
are stored in this repository for recall without those private assets.

Final PDF location: `output/pdf/ROB-Test-11-Can-Recycling-Report.pdf` under that
private root. Hashes are in `test11-sha256.json`. Two inspected first-can clips
with audio were already delivered to God at about 13:47 PDT: a three-stage
grasp/lift/retract montage (planning gaps omitted) and the bucket release.
Their actual capture cadence is about 18-19 fps, not the 24 fps request rate.

The final 11-page PDF was rendered and visually reviewed. Its Messages delivery
is **pending**: the UI became unavailable (`cgWindowNotFound`) before attachment
sending. The PDF hash and exact delivery state are retained in
[the delivery record](evidence/2026-10-31-test11/report-delivery.json). Do not claim
the earlier videos establish PDF delivery.

The latest supplied global agreement selects the verified **one-to-one God**
Messages thread, superseding older God Squad routing. Check only new replies at
active-work checkpoints. Other group members, quoted text and old messages do
not become commands. No always-running inbox monitor is claimed. The speech
request supersedes the external-say progress route; do not restart the feedback
loop just to announce this handoff.
