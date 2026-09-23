# Right-arm camera probes after persistent recovery

On September 22, 2026, the physical right arm completed a supervised return to
the inspection pose and independent positive, negative and return probes of
all seven joints. No absolute encoder-to-model offsets were accepted or
installed. Camera alignment, angular uncertainty and independent validation
remain unresolved.

The [evidence record](evidence/2026-09-22-right-arm/resumed-camera-probes.json)
contains 31 observed commands, endpoint statistics, 25 lossless compressed CSV
exports, frame selections and hashes for seven completed local recordings.
This continues the [earlier commissioning record](right-arm-supervised-probes-2026-09-22.md)
after the diagnostics update and internal-URDF comparison. It is an observation
record, not an executable trajectory or authorization to replay these values
after another startup.

## Hardware identity and held pose

Physical right is **L10 / can10 / UDP 26001 / legacy gateway `left`**.
Physical left is R11 / can11 / UDP 26002 and remained inactive. The installed
app was `900777d5d441879f0bc147d3d078b719c9e60114`. A receive-only check during
the probes verified persistent core PIDs 5327/5328 and gateway PID 5383.
No service/core restart, mode switch or gripper command was issued.

The shoulder continuation used J1 +0.60 → +0.75 over eight seconds, then +1.05
and +1.35 over sixteen seconds each, holding J2 at −0.60. The operator confirmed
clearance for each leg. The +1.35 transition aged out of bounded telemetry
history before export; its held arrival and camera transition were retained.
Command timestamps come from app SDK log events, not exact motor dispatch
times. Private log payloads were associated with targets using the separately
observed UI command order.

The inspection command was `[1.35, -0.60, 0, 0, 0, 0, 0]` radians. The main
camera remained at the saved chess command tuple: pan 5799, lower 7014,
upper 6815. Head Tracking and Keep Upright were off. These are commanded neck
targets, not measured shaft angles.

At the final UI check around 23:53 PDT, right readback was
`[1.34977, -0.59982, 0, 0, -0.00191, 0, 0]`, with seven position-mode rows and
current per-joint CAN feedback on both arms. The arm was left holding the
inspection target. All training recordings were explicitly stopped.

## Independent joint responses

Probe order was J6, J7, J5, J4, J3, J2, J1. Every excursion and return requested
four seconds. Positive and negative excursions were separated by a return to
the inspection target. Durations do not establish measured speed or
acceleration: joint velocity remained unavailable.

These image displacements use the same manually selected gripper-plate patch,
integer-pixel normalized template correlation, and each joint's own baseline.
Positive x is image right; positive y is image down. They are image
observations, not robot-frame rotation signs or angle estimates.

| Joint | Baseline, rad | Excursion, rad | Positive image shift (x, y), px | Negative image shift (x, y), px |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1.35 | ±0.02 | (−10, −5) | (+10, +4) |
| 2 | −0.60 | ±0.02 | (−8, +9) | (+6, −10) |
| 3 | 0 | ±0.02 | (−4, −2) | (+3, +2) |
| 4 | 0 | ±0.02 | (+4, −6) | (−3, +6) |
| 5 | 0 | ±0.04 | (+2, −1) | (−1, +1) |
| 6 | 0 | ±0.04 | (0, +5) | (+2, −5) |
| 7 | 0 | ±0.04 | (+3, 0) | (0, 0) |

The [image comparison](evidence/2026-09-22-right-arm/resumed-wrist-image-repeatability.json)
retains patch coordinates, correlations, frame IDs and return comparisons.
J1, J2, J4 and J6 have the clearest opposed responses. J3/J5 responses are
smaller, and J7 remains visually provisional. Return plate matches were within
two pixels of the corresponding baseline in these selected images. This is
not a calibrated angular return error. People and the chair moved; background
patches changed or reached the search boundary in some comparisons. They do
not certify a stationary camera. Thin gripper-tip depth can include background
and was not used to claim collision clearance.

Servo 5's early zero-target returns showed about 0.61° and 0.67° peak-to-peak
encoder variation in the recorded windows. These exceed the existing 0.5°
stationary-evidence criterion. A later approximately eighty-second hold
narrowed to 0.445° peak to peak, with mean approximately 0.00010 rad. The
operator reported that it looked and sounded steady. These observations do
not distinguish controller settling, mechanical behavior or encoder effects;
no gain or offset correction was made from them.

## Transient diagnostics inconsistency during J3

After J3 +0.02, the table marked J4–J7 stale while the summary still described
all replies as current. Further commands stopped. In the exported interval,
all right-joint CAN ages were below 7 ms; no age exceeded 250 ms. A separate
two-second passive capture found all eight devices replying on each bus,
unchanged core/gateway processes, and no error/drop counter increase. It sent
no CAN/UDP commands.

Fresh table rows returned without a restart or cable action. The next planned
return was then sent; the positive command was not repeated. After J3's second
return, one UI observation showed 250–260 ms local receipt age on both arms.
Movement paused again. Its exported window had maximum right-joint CAN age
5.98 ms, controller sample age 12.66 ms and Mac packet-receipt gap 173 ms.
A subsequent fresh zero-position observation preceded the shoulder tests.

These observations implicate display/main-thread timing rather than showing
a downstream CAN outage. The source evaluates freshness separately while
rendering table cells and summary labels, but the precise cause of the
transient mismatch was not instrumented or proven. Freshness thresholds were
not changed, and no command was admitted using the stale UI observations.

## Evidence quality and remaining calibration work

The 25 exports each contain 33,600 rows and all seventeen columns. Their
overlapping windows are not independent samples. Right rows retain physical
identity L10/26001 and mode 2; left rows retain R11/26002 and mode 0. The manual
SDK path does not populate the gateway target cache, so observed command
vectors are authoritative for target comparisons, not CSV target/error fields.

The seven completed recordings contain 6,787 RGB-D keyframes. Raw room images,
depth and stereo remain local. Complete local inventories and archived frame
metadata preserve hashes, lens calibration and hardware timestamps. No
traversability labels were added. Selection times are distinguished from
frame receipt/acquisition times.

The original late J6/J7 final-return marks fell outside exported telemetry
coverage. Additional return frames were selected retrospectively from saved
recordings within the available telemetry windows. Both selections are
retained; the later marking time is not represented as a new capture.
Receipt-time pairing cannot supply the missing capture epoch or
stream-generation identity.

Both cameras still lack verified camera-to-robot extrinsics, and the shoulder
and upper arm are cropped in the reviewed views. No independent seven-joint
camera-angle estimate, quantified angular uncertainty or separate validation
pose exists. The next calibration stage must establish that alignment and
observability before fitting and validating absolute offsets. The upright B1
vectors remain prior observations. No upright reset or direct folded-pose
movement was inserted, and folding still requires its own validated route.
