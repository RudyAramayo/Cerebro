# Camera-guided arm startup

Rob's September 22 clarification defines the intended startup sequence:

1. Expect both arms to wake **hanging**. Retain the previously verified B1
   upright vectors as calibration priors; B1 zero is not a startup destination.
2. Bring one arm forward into a camera-visible inspection pose through ordered,
   supervised clearance waypoints from its current measured coordinates.
3. Hold the inspection pose and exercise one servo at a time in both directions,
   returning to the inspection pose between trials. Observe actual encoder and
   camera responses; an accepted command alone is not evidence of movement.
4. Estimate the joint direction and encoder-to-model offset. Compare against
   the prior startup record and account for camera registration separately.
5. Check the result at a separate observed pose that was not used for fitting.
   Retain the old record if the new measurements are ambiguous or inconsistent.
6. Continue to the desired working pose through the separately validated folding
   animation. Do not insert a return to upright zero unless the task needs it.

This replaces a blanket requirement to manually re-measure B1 zero after every
power cycle. Saved calibration and camera evidence remain useful across boots;
the current encoder offset is established from the new observed response.

## Tread clearance and folding animation

Rob clarified that moving the extremities too early or too quickly can catch
the treads. Both presentation and folding need ordered intermediate clearance
poses, controlled joint speed/acceleration, and smooth transitions, like the
neck animation. A safe endpoint does not establish a safe route to it. Simply
subdividing a direct joint-space interpolation can preserve the collision.

Validate the entire swept motion of the forearm, wrist, tool and other links
for each segment. During initial teaching, stop at each waypoint and check
actual encoder/camera arrival and tread clearance before advancing. Select
velocity/acceleration limits only after slow supervised validation; this
offline preview does not implement or certify those live limits. Folding and
unfolding routes each need validation. An automatic reversal must not be
assumed safe after the model offset, starting pose or cable routing changes.

The operator-reported folded endpoint and its mirrored left target are saved
in [arm-folded-endpoints-2026-09-22.json](arm-folded-endpoints-2026-09-22.json).
The intermediate poses are still unrecorded. These endpoints are reference
data, with hardware output disabled and no complete animation attached.

## Measurement accountability

The markerless OAK-D fitter already checks visibility, competing fits, and a
data-only surface Jacobian before reporting seven joint angles. A commanded
pose or a previous image must not be substituted for current observations.
Each fit now retains the camera stream ID, hardware timestamp, intrinsics,
image size, and camera-to-robot transform for comparison across sessions.

The new `Resources/ShadowPlanner/startup_calibration.py` assesses a recorded
trial without connecting to hardware. It pairs each frame with measured encoder
positions and its acknowledged target. Each endpoint requires at least three
distinct frame/telemetry pairs spanning 500 ms, with stationary camera and
encoder positions. It rejects stale or unsynchronized pairs, wrong arm/session
identity, unobserved joints, excessive uncertainty, ignored commands, incorrect
response scale, movement in another joint, and poor return repeatability.

For each joint, it estimates the direction from the measured change:

```text
gain = change_in_camera_angle / change_in_measured_encoder_angle
direction = sign(gain), provided |gain| is close to 1
vendor_at_model_zero = measured_encoder - direction * observed_model_angle
```

The offset is fitted from baseline, positive excursion, negative excursion,
and return observations. A separate held-out frame set checks all seven
mapped angles. Reports include per-joint gain, fit error, return error,
camera uncertainty, validation error, frame count, and an evidence hash.
A previous matching model/arm record adds per-joint offset changes across
controller sessions. It does not count as new measurement evidence.

Current analysis thresholds are explicit engineering criteria, not measured
accuracy claims: at most 100 ms pairing skew, 10 mm camera-registration RMS,
12 mm arm-surface RMS, 1 degree reported angular standard deviation, and
2 degrees fit/validation error. A wiggle must exceed the camera uncertainty;
poor visibility does not authorize automatically increasing its amplitude.

## Physical side and transport identity

| Physical arm | Core | UDP port | Existing gateway label |
| --- | --- | ---: | --- |
| ROB-right | L-10 | 26001 | `left` |
| ROB-left | R-11 | 26002 | `right` |

The record includes this binding explicitly. The tool refuses a conflicting
binding; the gateway routing itself is unchanged.

## Current implementation boundary

The assessment and bounded sequence preview are **offline tools**. They do not
send mode/position commands, install fitted offsets in the running app, or
turn the existing preview model into an autonomous executor. The existing
manual park-reference route remains present until a supervised startup
executor can consume the validated record. The replay tests use synthetic
measurements and do not certify live camera accuracy.

The sequence preview requires named clearance waypoints followed by the
inspection endpoint; a final pose alone is rejected. It preserves their order,
subdivides each segment into at most 3-degree increments, marks each waypoint
for an arrival/clearance check, lists independent 1–5 degree wiggles, and leaves
the validation pose separate. Those generated steps remain subject to
visibility, swept clearance, and measured feedback. Small increments and
preview durations do not certify peak velocity or acceleration.
The reviewed hanging model has existing coarse-mesh overlaps, so its clearance
output currently cannot certify a collision-free real trajectory.

To assess a real, recorded trial with the existing ShadowPlanner environment:

```sh
"$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3" \
  Cerebro/Resources/ShadowPlanner/startup_calibration.py recorded-trial.json \
  --previous previous-report.json --output new-report.json
```

Omit `--previous` for the first trial. The output must be a new file so a failed
trial cannot overwrite the prior report. Keep the source frame/encoder record
alongside the report; its exact JSON content is bound by `evidenceSHA256`.
