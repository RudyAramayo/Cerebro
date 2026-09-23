# Right-arm inspection commissioning — September 22, 2026

The physical right arm was brought forward from hanging under direct operator
supervision. Positive servo 1 moved forward; negative servo 2 lifted outward.
The final shoulder-inspection target was `[1.35, -0.60, 0, 0, 0, 0, 0]` radians.
During the held two-camera recording, the controller readback means were
`[1.349869, -0.599821, 0, 0, 0, 0, 0]`, with all seven reported modes `2`
(position). A subsequent J6 +0.04 probe exposed missing downstream CAN replies:
those seven-value packets were not proof of seven current measurements.
Physical left remained reported inactive. No gripper commands were sent.

This is a commissioning record, **not an executable trajectory, a fitted
calibration, or an approved folding animation**. The current controller
coordinates and operator clearance observations cannot authorize another
startup session automatically.

## Supervised movement record

The [JSON record](right-arm-supervised-probes-2026-09-22.json) contains command
times, operator observations, endpoint statistics, transport identity, and
hashes for the archived CSV exports. Physical right is L10 / can10 / UDP 26001
and uses the legacy gateway label `left`. The running app was commit
`8eff7b835a15ec3675d90f6b6eac44f95f166cd4`.

In steps 1–14 only servos 1 and 2 changed targets; servos 3–7 were commanded to
remain at zero. The final wrist probe is recorded separately below.

| Step | Servo 1, rad | Servo 2, rad | Requested duration, s |
| ---: | ---: | ---: | ---: |
| 1 | 0.00 | -0.02 | 4 |
| 2 | 0.00 | -0.06 | 4 |
| 3 | 0.04 | -0.06 | 4 |
| 4 | 0.04 | -0.15 | 6 |
| 5 | 0.15 | -0.15 | 6 |
| 6 | 0.15 | -0.30 | 8 |
| 7 | 0.30 | -0.30 | 8 |
| 8 | 0.30 | -0.45 | 8 |
| 9 | 0.45 | -0.45 | 8 |
| 10 | 0.45 | -0.60 | 8 |
| 11 | 0.60 | -0.60 | 8 |
| 12 | 0.75 | -0.60 | 8 |
| 13 | 1.05 | -0.60 | 16 |
| 14 | 1.35 | -0.60 | 16 |

The operator requested four times the prior 0.15-radian forward increment
after step 12. The resulting 0.60-radian move was split into two 16-second
legs. At step 13, the gripper first appeared at the belly image's right edge.
The arm held there until the operator confirmed clearance from their body
and the chair for the remaining leg. At step 14, the wrist and gripper were
clearly visible. These durations do not establish peak speed or acceleration;
measured velocity remains unavailable.

The operator changed the lighting and moved the droid after step 9. Raw
transitions for steps 9 and 13 aged out of the bounded telemetry buffer;
their exports retain later held-pose samples. Step 12 has an observed UI
readback but no archived CSV sample window. These gaps are explicit in JSON.
CSV `target_rad` and `error_rad` retain the earlier gateway hold target because
the Torso manual SDK path does not update the gateway target cache. Use the
JSON command vectors when comparing these movements with controller readbacks.
The old `sample_age_ms` measured LCM receipt age only; it did not establish
per-joint CAN freshness. Exact dropout onset is unknown. Operator observations
support J1/J2 motion and clearance, not freshness of the unchanged joints.

## Interrupted wrist probe and recovery

At 21:32:11.336 PDT, step 15 requested `[1.35, -0.60, 0, 0, 0, 0.04, 0]` over
four seconds. J6 continued reporting zero. No wrist movement was verified and
the planned return command was **not sent**. Further arm commands stopped.

Two receive-only CAN captures at 21:34:54 and 21:37:19 showed only `0x91`
(J1) replying on right / can10. J2–J7 and the gripper were absent, although the
core continued transmitting setpoints and publishing all seven cached joint
values. Left / can11 still had all eight replies. Interface error/drop
counters did not increase; that did not establish a healthy downstream chain.
The [CAN evidence](evidence/2026-09-22-right-arm/can-loss-and-recovery.json)
retains counts, payloads, process identities and hashes of the local captures.

The operator confirmed the right arm was supported and powered off, then
reported rebooting Draco. At 21:44:57 the right core had a new PID (4331,
previously 2706); the left core and gateway had not restarted. Both buses then
had all eight replies with inactive payloads. No motor command was sent by
the diagnostic check. This verifies controller restart and returned replies,
not the root cause of the outage or independent proof that every retained
motor target was erased. No calibration was resumed automatically.

The software correction requires independent per-device CAN receive ages,
marks missing feedback stale, and rejects new motion based on cached values.
It cannot cancel an already dispatched vendor trajectory or move an
unreachable motor to a safe pose. The failed probe and earlier unverified
downstream readbacks are excluded from any offset fit.

The [deployment verification](evidence/2026-09-22-right-arm/feedback-fix-deployment.json)
records the installed gateway/app commits, signed build, 51 gateway tests on
both hosts, client/manual runtime checks and a post-update CSV. Only the gateway
service restarted; core PIDs were unchanged. After a follow-up interval with
no left replies, the live app again showed all 16 device replies current.
Read-only mode queries showed all 14 joints inactive; final two-second sample
ages were below 10 ms. No motion was sent during installation/verification.
The operator then reported the right arm hanging and clear after applying
DeoxIT and reconnecting the connectors. Cable treatment is an operator report,
not an established root-cause diagnosis or durability test.

## Post-recovery lift interrupted by controller exit

The separate [post-recovery trial](evidence/2026-09-22-right-arm/recovery-lift-controller-exit.json)
began after the operator reported hanging/clear. Position-mode entry returned
a rejection code, but a subsequent mode query and the operator both confirmed
position mode. The mode switch was not repeated. A fresh zero-vector hold was
accepted at 22:03:05, then a four-second J2 −0.06 target was dispatched at
22:04:08.975. Head tracking had been disabled again after app startup.

J2 moved to a last reported −0.054677893 rad. At 22:04:13 the right core's
sequence stopped at 66918 and its process disappeared. Both buses still had
all eight CAN replies; right-core setpoint transmissions stopped. The new
gateway kept individual CAN ages current while correctly marking the stopped
controller sample stale. No further movement command was sent.

The right core's SSH session closed at the same time. The operator reported
touching nothing. No kernel crash/OOM entry or core dump was found; the exact
exit cause is unproven. The legacy Torso starter runs a core in the foreground
of SSH, while the installed guarded stack recovery uses the persistent
`rc.local` startup with redirected logs. After the operator confirmed both
arms supported and reported restarting the core, the UI showed successful
guarded recovery at 22:13:03. No additional restart was issued. This failed
lift is not accepted calibration evidence.

## Persistent recovery and resumed clearance steps

The [persistent recovery record](evidence/2026-09-22-right-arm/persistent-core-recovery.json)
contains seven compressed telemetry exports and the subsequent read-only
checks. Both cores remained in `rc-local.service`, with stdout/stderr going
to their respective `core.log` files. All eight devices on each CAN bus
replied during passive captures, with no error/drop counter increase. The
right arm reported position mode and a new zero reference; the left remained
inactive. The operator confirmed hanging/clear before further movement.

Nine separate slow shoulder steps reached `[+0.45, −0.60, 0, 0, 0, 0, 0]`.
The operator checked clearance at the intermediate poses. Settled controller
readbacks differed from their targets by less than 0.001 rad across the
recorded two-second endpoint windows, with current individual CAN feedback.
This is an encoder target-arrival check, not an absolute visual calibration.

At 22:27:08 the attempted J1 +0.60 step was blocked before SDK dispatch by
the 250 ms freshness check. The arm stayed at the previous target. Both cores
and the CAN devices remained alive. The display ingested telemetry in bursts;
pausing the diagnostic drawings reduced the median interval to 51 ms, with
one gap over 250 ms in approximately 35 seconds. The comparison with drawings
running had 215 such gaps over approximately 122 seconds, including CSV export.
Those CSV receipt times were assigned on the main thread, so these figures
measure display ingestion delay, not proven network transit delay.

A short Mac process profile showed substantial main-thread graph drawing;
source inspection also confirmed synchronous CSV formatting/writing. A
heartbeat expiry at 22:29:14 coincided with that profile, which may have
contributed. Reconnecting only the gateway session restored connectivity at
22:30:33 without restarting either core or sending a motor command. Movement
remained suspended for the display/receipt-time investigation. The rejected
target was not replayed, and this route is not a taught folding animation.

The diagnostics follow-up moves CSV formatting/writing and graph preparation
off the main thread. Graph requests coalesce while busy; each time bucket
preserves endpoints and extrema, and missing samples break the line. The
full history remains available in CSV with unchanged column names and
round-trip numeric precision. New CSV wall times come from telemetry decoding
on the gateway queue instead of later UI ingestion. They are still Mac receipt
times, not camera exposure times or synchronized robot acquisition times.

Hardware-free runtime checks exercise narrow positive/negative spikes,
missing velocity/targets, line breaks, obsolete plot results, live history
mutation during export, main-loop responsiveness and delayed notification
delivery. The full 33,600-row export fixture completed in 1.52 seconds with
82 main-loop timer callbacks. The existing mode/command freshness limits
remain unchanged; rejection text now distinguishes gateway ages from local
time since receipt. These tests do not establish that the earlier connection
faults have been eliminated, and the visual calibration remains incomplete.

The [live deployment record](evidence/2026-09-22-right-arm/diagnostics-responsive-deployment.json)
verifies installed app commit `900777d`, the signed binary hashes and three
complete 33,600-row exports. With live graphs enabled, the first two traces
had median receipt intervals of 51 ms and maxima of 309 ms and 283 ms. The
five-second window spanning the first export had a maximum receipt interval
of 84 ms. These are gateway-queue decode timestamps; they do not measure every
UI callback. Occasional gaps still exceed the unchanged 250 ms admission limit.
Both persistent cores and the gateway retained their PIDs; all eight devices
on each bus replied in a passive capture with no error/drop count increase.

After the operator reconfirmed presence and clearance, a new eight-second
joint-space request moved J1 from +0.45 to +0.60 while holding J2 at −0.60 and
J3–J7 at zero. In the two-second endpoint window, the maximum readback error
was 0.000776 rad and all individual CAN ages were below 5.25 ms. The next
+0.75 target was staged but not sent, then cleared from the sliders when the
operator raised the Amber-internal Drake model question. The arm remains at
the completed `[+0.60, −0.60, 0, 0, 0, 0, 0]` target. No new camera capture or
absolute offset fit accompanied this step.

The [internal-model review](amber-internal-model-review-2026-09-22.md) records
the configured vendor URDFs and their differences from the whole-robot model.
No Amber model, launch setting, solver parameter or core process was changed
as part of that comparison.

## Camera references

The following completed recordings remain local under
`~/Library/Application Support/Cerebro/Recordings/Training/`. Raw room images,
depth and stereo images are not committed. The JSON record retains their
manifest hashes and the paths/hashes of complete local artifact inventories.
No traversability labels were added during these captures.

| Session | Held camera configuration | Saved RGB-D frames |
| --- | --- | ---: |
| `20260923T042114Z_8517d521` | Belly camera; arm at step 14 | 73 belly |
| `20260923T042728Z_76e1127c` | Main camera at saved `chess_board` pose; belly camera; arm unchanged | 46 main + 46 belly |
| `20260923T043151Z_1c1c557e` | Same camera configuration; failed J6 probe | 279 total; diagnostic evidence only |

For the second capture, Head Tracking was turned off. The existing neck
sequencer applied the saved `chess_board` command tuple: pan `5799`, lower
`7014`, upper `6815`. The exact commanded tuple was verified after staging.
Keep upright was already off and remained off. These are Maestro command
targets, not measured shaft angles; no neck calibration settings were changed.

The downward main-camera view provides another view of the wrist/gripper and
distal arm. The shoulder and upper arm remain outside the reviewed image at
this arm pose. Holding the neck still makes the reference more repeatable,
but does not establish the camera-to-robot transform or seven-joint
observability. Both recorded cameras have valid lens intrinsics and aligned
depth, but their saved camera-to-robot extrinsics are null.

The [offline belly registration check](evidence/2026-09-22-right-arm/camera-registration-check.json)
used the first, middle and last frames of the belly-only recording. Using the
existing markerless depth sampling and registration, each had more than
14,000 usable depth points but zero visible projected base/torso registration
surface points. All three were rejected with `Camera cannot see enough of
ROB's base and torso to register the scan`. This checks stored pixels and
does not claim a live, fresh observation. The main-camera capture has not
been passed off as a successful full-arm fit.

Camera/encoder pairing currently uses Mac receipt times only. The recording
does not preserve camera capture epoch time or stream-generation identity,
which the startup trial fitter requires. During the two-camera capture,
maximum nearest telemetry receipt skew was approximately 127 ms for main and
107 ms for belly; the nominal calibration criterion is 100 ms acquisition
skew. The recorded steady arm pose is useful reference evidence, but these
files are not an accepted synchronized startup calibration trial.

## Remaining calibration work

Re-establish live feedback and a supervised hanging startup before further
movement. Establish camera alignment from independently verified mount geometry or
observed fixed robot landmarks; account for the main camera's neck pose.
Retain capture-time and stream-generation provenance when pairing frames
with encoder samples. Then verify sufficient arm coverage and observable
joint response during independent positive, negative and return probes, with
a separate validation pose. No signs beyond the observed J1/J2 directions,
absolute offsets, seven-joint visual fit, or automatic correction have been
accepted. The saved B1 vectors remain priors, and no return to B1 zero was
inserted.
