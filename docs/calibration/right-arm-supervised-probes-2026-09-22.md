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
