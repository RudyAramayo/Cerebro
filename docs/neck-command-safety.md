# Neck command safety

This document describes the currently implemented command-space contract for
the three Maestro neck channels:

| Channel | Command |
| --- | --- |
| 0 | neck pan |
| 1 | lower-neck tilt |
| 2 | upper camera tilt |

All three channels are sent through one local safety gateway in
`ROBSerialBox`. The torso controls and Vision controller both use that gateway.
Target `0` remains the Maestro off sentinel and is never changed into a minimum
servo target by clamping.

## Commanded targets, not measured position

The `P`, `L`, and `U` readouts in **Torso Servo Controls** show Cerebro's
command state. While that state is valid, these are the last targets Cerebro
successfully wrote. Pan degrees are calculated from the configured center and
target-per-degree scale. They are not encoder, potentiometer, or servo-shaft
measurements. `OFF` means Cerebro successfully wrote target `0` in the current
Maestro session; `UNKNOWN` means it cannot make that claim. Neither state proves
the physical pose. Cerebro currently has no neck position feedback, measured
completion, stall detection, or collision sensor.

On startup, reconnect, disconnection, or a partial neck-write failure, Cerebro
forgets all commanded-pose and leveling assumptions. A successful reconnect
does not query or restore physical position.

## Configuration and calibration

The Head panel's **Safety…** popover exposes these values. The shipped values
are conservative starting suggestions, not a confirmed calibration for every
physical build.

| Field | Shipped suggestion | Meaning |
| --- | ---: | --- |
| Below-5000 pan | ±30° | symmetric pan limit for a known lower-tilt target below the e-stop clearance band |
| Full-pan band | 5000–6495 | fixed inclusive Maestro 24 lower-tilt band that permits complete pan |
| Above-6495 pan | −15° to +2.1° | asymmetric forward pan limits for a known lower-tilt target above the clearance band |
| Unknown/off pan | −15° to +2.1° | fail-safe asymmetric pan limits when lower tilt has no known active command |
| Lower clearance/up | 6011 | fixed lower-neck camera-leveling reference and temporary OFF/unknown startup lift |
| Upper upright | 6073 | fixed neutral upper-neck camera target and Vision tracking center |
| Default forward pan | 5799 | original torso-control forward resting target |
| Default lower rest | 7014 | original safe resting target toward the rear of the robot |
| Default upper rest | 6073 | calibrated upright upper-neck target used by the `upright` camera position |
| Pan center | 6000 | raw target treated as 0° |
| Pan targets per degree | 33.3333 | raw-target-to-degree scale |
| Camera counter gain | -1.0 | upper-target correction per lower-target unit |
| Keep camera upright | On | enables coupled upper-camera counter-rotation for lower-neck moves |

The policy's shipped hard command bounds are pan 4000–8000, lower tilt
4375–7675, and upper tilt 4300–7790. The symmetric full-pan capacity is the
smaller distance from pan center to either pan bound, divided by targets per
degree; the shipped suggestions therefore describe ±60°.

Before selecting **Apply**, physically confirm the pan center and scale, the
inclusive `5000`–`6495` lower-tilt clearance band, clearance/neutral targets
`6011`/`6073`, resting defaults `5799`/`7014`/`6073`, both hard ranges, and
the counter-gain sign.
Command all three neck channels off and confirm the readouts show
`P OFF`, `L OFF`, and `U OFF`; Cerebro rejects live calibration changes while
any target is nonzero or any readout is `UNKNOWN`. A reconnect changes all
three readouts to `UNKNOWN`, so the operator must issue a fresh all-off command
before Apply is accepted. Applying only validates and saves one versioned
configuration object; it does not submit any neck or arm motion.

Existing V1 and V2 settings retain their common calibration values on upgrade.
Their old 5300–6822 band and the old serialized `6823` forward anchor remain
only for V3 settings compatibility; neither defines the active pan envelope or
the upright reference. The fixed Maestro 24 full-pan band is `5000`–`6495`,
and the fixed lower/upper clearance/neutral targets are `6011`/`6073`. The
Head sliders use the safe resting defaults `5799`/`7014`/`6073`. Migration
still clips −15.0°…+2.1° inward to the saved pan range and defaults **Keep
camera upright** to on. Every V1/V2 migration is marked unconfirmed, so the
operator must verify all fields and Apply again with all three channels known
OFF.

With no valid confirmed configuration, Cerebro loads the shipped suggestions,
forces the effective counter gain to zero, and holds automatic lower-neck
motion. Pan starts inside the tightest configured window while lower position
is unknown. A direct lower-tilt slider or lower-enable action can authorize an
explicitly supervised calibration jog. An explicit pan-slider action may
authorize the same exact-demand recovery only when lower tilt is enabled and
its slider target is inside `5000`–`6495`; upper camera controls cannot qualify.
Recognized-person tracking has one separate reviewed clearance request: center
pan, lower `6011`, and upper `6073`. It may establish only that exact tuple
without enabling arbitrary uncalibrated lower motion, and tracking remains
paused until the lower, pan, and upper command deadlines have settled.
After that exact lower target is successfully written and its command-space
settle interval completes, pan uses the corresponding lower-target envelope
even while the separate camera/counter-rotation calibration remains
unconfirmed. The status identifies this mode. It does not energize an
unverified compensation direction autonomously.

## OFF/unknown safe startup

After a Maestro connection has accepted its conservative speed and
acceleration profile, the hardware service automatically starts a validated
three-phase neck sequence. A deliberate enabled-slider or enable-checkbox
action can start the same recovery when one or more axes are `OFF` or
`UNKNOWN`:

1. Pan is commanded `OFF`. Lower and upper are sent together to lower-up
   `6011` and upper upright `6073`.
2. Cerebro waits for the slower of the worst-case lower/upper Maestro ramps
   plus the settling margin. It then commands pan forward to `5799` while
   holding lower at `6011`.
3. Only after the worst-case pan ramp and staging margin expire does Cerebro
   send the `lean_forward` camera pose: lower `7014` and upper `7698` together.
   It waits for both joint deadlines before releasing normal torso control.

The **Servos → Open Servo Control…** window exposes camera positions, servo
sequences, and relative gestures. The shipped camera catalog is
`lean_forward` (`L 7014`, `U 7698`), `upright` (`L 6011`, `U 6073`), and
`lean_back` (`L 4747`, `U 5214`). Sequence phases contain pan, lower, upper,
and post-settle hold values; the sequence table receives the largest share of
the window. Startup edits are accepted only when they still describe exactly
three ordered phases: phase 1 has pan OFF in the full-clearance lower band,
phase 2 holds phase-1 lower/upper while energizing pan, and phase 3 retains the
phase-2 pan. Every phase must also pass the active hard limits without a clamp.
The service copies all three phases before motion begins, so edits cannot alter
an in-flight startup.

The Head sliders mirror each accepted startup target as soon as its command is
issued: lower shows `6011` during the clearance/centering phases and `7014`
once the lean-forward move is issued; upper changes from `6073` to `7698` in
phase 3, and pan shows `5799` once it is energized in phase 2. Because there is
no shaft feedback, these are commanded targets rather than measured
positions. A slider deliberately edited during startup retains that queued
operator value instead and replays it after completion. The three enable
checkboxes are wired as explicit operator actions. Camera
counter-rotation is suspended only for these exact startup poses, then rebased
at the configured phase-3 pose so the next normal render does not jump the
upper servo. Switching
any neck checkbox off cancels the pending sequence and routes the OFF demand
through normal shutdown staging. At an entirely unknown/OFF pose, that OFF
action clears all three checkboxes together so the other checked axes cannot
be energized incidentally.

Pan and lower are deliberately not started simultaneously in the final leg.
With no shaft feedback, lower could leave the `5000`–`6495` clearance band
before pan reached forward center; waiting for the conservative pan deadline
prevents that race. Every arrival in this sequence is inferred from the
configured motion profile and worst-case command distance, not measured.
Once pan has settled, phase 3 sends lower `7014` and upper `7698` together in
one Maestro multiple-target packet. If a safety condition still holds the
lower axis, it also holds the upper target so the camera cannot bend backward
ahead of the lower joint; the complete coupled pose is retried after the hold.

The shipped `YES` gesture alternates positive and negative deltas around the
current upper-neck target to nod. The shipped `NO` gesture does the same around
the current pan target. Each repetition is exactly `+delta` then `-delta`, so
two repetitions run `+delta → -delta → +delta → -delta` and finish at the final
negative extreme without an extra midpoint step. Servo, delta, repetition
count, and interval are editable. Gesture steps and named
camera positions use the same safety gateway as the torso sliders; a clamped
target stops execution and leaves the warning/restricted envelope visible.
One button press owns the complete run: if the gateway first holds lower/upper
while pan settles, the runner waits for that internal deadline and resubmits
automatically. Repeated unresolved safety holds stop after eight resubmissions
and display the final safety status instead of creating an unbounded main-loop
retry. Explicit Servo Control values are raw Maestro targets, so camera
leveling does not transform the configured upper value; the accepted exact
pose becomes the baseline for later normal camera-leveling commands.

## Hardware servo motion profile

The scrollable **Settings → Hardware → Maestro Servo Motion** section enables
a controller-owned speed and acceleration profile for all 24 Maestro channels.
It defaults on with maximum speed `35` and acceleration `3`; lower nonzero
values are gentler. Cerebro persists the profile and sends the Mini Maestro
compact-protocol **Set Speed** (`0x87`) and **Set Acceleration** (`0x89`)
commands for every channel immediately after each verified connection, before
normal target commands. Turning smoothing off explicitly sends zero limits,
which restores the Maestro's unlimited setting. See the [Pololu Maestro serial
servo commands](https://www.pololu.com/docs/0J40/5.e) for the controller's
units and ramp behavior.

On upgrade, a saved speed of `40` or acceleration of `4` is migrated once to
the gentler shipped value. Other saved values are treated as operator
calibration and remain unchanged.

This central controller profile covers manual controls, Vision, gestures, and
arm targets without generating competing UI-side intermediate writes. It
smooths changes between active commanded outputs; it cannot establish the
physical position of an unpowered servo or make an unknown first reference
safe. Startup reference/calibration gates remain necessary.

## Dynamic pan envelope

The pan window is selected from the commanded lower-tilt target:

- When lower pose is off or unknown, the gateway cannot know which extreme the
  mechanism occupies, so it uses the fail-closed unknown/off window. With the
  shipped values, that window is −15.0°…+2.1° (raw pan 5500…6070).
- A known active lower target below `5000` uses the configured symmetric
  restriction. With the shipped values, that is ±30°.
- A known active lower target from `5000` through `6495`, inclusive, gets the
  complete calibrated pan range. With the shipped values this is ±60°, and it
  includes upright `6011`.
- A known active lower target above `6495` uses the asymmetric forward window,
  −15.0°…+2.1° with the shipped values.
- Once a full-clearance lower target is established in the current Maestro
  session, subsequent commands that remain in that region do not inherit the
  unknown/off −15.0°…+2.1° window from stale transition state.
- There is no interpolation at either collision boundary: `4999` is symmetric,
  `5000` and `6495` are full-pan, and `6496` is asymmetric. The gateway's
  settle interlock controls when a widening becomes active.

The pan command readout shows `!` for the entire time the active envelope is
narrower than the full calibrated range, even when the current pan command is
already inside that envelope. Its tooltip labels the envelope `RESTRICTED` or
`FULL`; an actual out-of-envelope request is still clamped and additionally
reported as `PAN LIMITED` in the safety status.

A request toward a more restrictive lower pose tightens the envelope
immediately. If needed, Cerebro holds lower tilt while it brings pan inside the
new envelope and establishes a usable upper-camera target. A request toward
the full-clearance band from an off, unknown, or restricted lower state does not
expand pan immediately: the commanded lower target must remain in place for
its calculated Maestro ramp duration plus the current 0.75-second settling
margin. Once a full-clearance target has already been established, commands
that stay in that region keep full pan without repeating that unknown-pose
delay. Pan
recentering—and establishing a usable upper-camera target when that coupled
axis was previously unknown or off—uses the calculated ramp duration plus the
current 1.0-second staging margin. Selecting a slower Hardware profile while a
neck gate is active can only extend that gate; it never shortens it. A direct
lower-axis recovery authorization is latched only for its
exact pan/lower/upper demand long enough to complete this staging. These are
command-timing guards, not proof that the mechanism settled.
Moving the pan slider counts as that authorization when the lower servo is
enabled and its requested slider target is within `5000`–`6495`. This sends and
settles the exact lower target through the same gateway; it does not assume that
the physical shaft already matches the slider. The authorization lifetime
includes the configured worst-case pan/upper Maestro ramp, so choosing a slower
servo profile cannot make recovery expire before staging finishes.
Every changed pan target starts the same monotonic settling age, including a
pan-only command issued before a later lower request; a pan reversal restarts
the lower-release gate. Repeated identical lower demands do not postpone the
clearance-expansion deadline.

The gateway writes pan first and, only when establishing an unknown/off coupled
axis, may establish the upper camera alone while lower remains held. For an
already established pose, it does not pre-tilt the camera to its destination.
Once the staging gate clears, it sends the final lower and counter-rotated
upper targets together in one contiguous Maestro multiple-target command. The
installed lower and upper joints use the same servo model and matching speed;
with the shipped `-1.0` gain, their target deltas have equal magnitude and
opposite direction. This is the normal-motion basis for keeping the camera
upright throughout the paired move. The gateway holds the lower move when
required camera compensation is enabled but the upper servo is off, or when
compensation would worsen/exhaust the upper-camera range. A move that reduces
an already saturated camera correction is allowed so the mechanism can
recover. Turning lower tilt off is also sequenced: pan is first recentered into
the restricted envelope, the upper target is staged, and lower torque is
released last. Individual pan/upper OFF requests are held while an active lower
joint still depends on them.

## Upper-camera counter-rotation

The Head panel's persistent **Keep upright** checkbox controls this behavior.
When it is on, the pure policy uses this command-space relationship:

```text
upper target = desired upper target
             + counter gain × (lower target − reference lower target)
```

The configured reference is the calibrated lower upright target `6011`; the
neutral upper-camera target is `6073`. Changing the checkbox adopts the
currently applied upper-camera command as the new camera demand, takes a short
manual neck lease, and rebases the current lower target. This prevents the mode
change itself from jumping a known active neck pose and does not submit any arm
commands. If any neck command is `OFF` or `UNKNOWN`, the mode is saved without
energizing it. Subsequent lower motion shifts the upper-camera target in the
configured counter direction and clamps it to the upper hard range. When
**Keep upright** is off, the upper target is still hard-clamped but is not
adjusted in response to lower motion.

The gain sign is mounting-specific. A sign that counter-rotates one physical
installation can amplify tilt on another. Confirm under direct supervision
that a positive lower-target change produces the upper motion that keeps the
camera upright. Gain `0` also disables compensation even when the checkbox is
on.

After lower tilt has been OFF or its command state is unknown, Cerebro cannot
infer its physical starting angle. Automatic and gesture lower moves stay
blocked. With all Head axes enabled, the first deliberate torso slider or
enable-checkbox action runs the fixed startup sequence above; an isolated
manual lower-axis calibration jog remains separately supervised. Either path
establishes only a command-space reference, and counter-rotation applies to
subsequent normal lower moves. Watch and support the camera during recovery
because there is no sensor data from which to level the first move.

## Startup, manual, gesture, and Vision authority

- Startup and every Maestro reconnect clear all neck pose assumptions. The
  passive one-second torso renderer cannot resume neck output by itself; a neck
  slider or enable-checkbox action must establish torso authority. Readouts
  remain `UNKNOWN` until each channel has a successful current-session write.
- A neck operator action owns a two-second manual override. Vision neck input is
  ignored during that interval, and any gesture lease is cancelled. Arm-only UI
  actions and the periodic renderer do not claim manual neck authority.
- A typed local gesture ingress accepts calibrated pan degrees plus raw lower
  and upper Maestro targets. It requires a live Maestro connection, confirmed
  calibration, known active command state for all three axes, targets inside
  the configured joint bounds, main-thread submission, a nonempty source, and
  a renewable 0.1-to-2.0-second lease. An accepted request clears Vision authority and
  prevents passive torso and Vision commands until the lease expires or is
  cancelled. Cancellation releases authority but does not send a new target;
  the last commanded targets remain in effect.
- Fresh Vision controller input takes a renewable 0.35-second neck lease and
  uses the same safety gateway. Vision is ignored until calibration and all
  current-session command state are known and lower tilt is active. It slews
  pan and upper tilt by at most 80 raw target units per 0.1-second controller
  tick. Vision does not command lower tilt.
- Once Vision has taken the neck lease, passive torso updates stay out of the
  way. Returning to torso control requires another explicit neck operator
  action.

The physical E-stop and a clear supervised workspace remain authoritative.

## Autonomous-gesture limitation

The typed gesture ingress and policy are necessary command boundaries, not an
autonomous neck gesture executor. The ingress reports only whether a command
was rejected, written, or held for staging; it cannot report physical arrival.
No current production caller drives it, and Gemini's `play_gesture` workflow is
currently for supervised Amber-arm gestures, not neck gestures. The model is
not allowed to supply raw joint values.

Cerebro still lacks measured neck state, verified lower/upper degree
calibration and camera-to-neck/torso transforms, complete neck-axis mapping,
collision geometry, stall/obstruction detection, bounded cancellation with
measured hold, and hardware-in-loop validation. Matching servos and the paired
command provide the intended normal trajectory, but cannot prove it if either
joint is obstructed or behaves abnormally. Do not connect an autonomous gesture
planner to the typed ingress until it uses an explicit renewable lease and has
supervised calibration, collision checks, cancellation, and measured-outcome
tests.

Relevant regression checks are:

```sh
cc -std=c11 -Wall -Wextra -Werror \
  Cerebro/ROBNeckSafetyPolicy.c Tests/ROBNeckSafetyPolicyFixtureTests.c \
  -lm -o /tmp/ROBNeckSafetyPolicyFixtureTests
/tmp/ROBNeckSafetyPolicyFixtureTests
python3 Tests/ROBNeckSafetyStaticTests.py
```
