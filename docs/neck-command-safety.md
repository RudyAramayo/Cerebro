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
| Backward pan | ±30° | symmetric pan limit at the backward lower-tilt extreme |
| Forward restriction starts | 6823 | first lower-tilt raw target in front of the arm-clearance boundary |
| Forward pan window | −15° to +2.1° | exact asymmetric pan limits at target 6823 and farther forward |
| Full-pan lower band | 5300–6822 | inclusive lower-tilt target band with arm clearance for full pan |
| Pan center | 6000 | raw target treated as 0° |
| Pan targets per degree | 33.3333 | raw-target-to-degree scale |
| Camera counter gain | -1.0 | upper-target correction per lower-target unit |
| Keep camera upright | On | enables coupled upper-camera counter-rotation for lower-neck moves |

The policy's shipped hard command bounds are pan 4000–8000, lower tilt
4375–7675, and upper tilt 4300–7790. The symmetric full-pan capacity is the
smaller distance from pan center to either pan bound, divided by targets per
degree; the shipped suggestions therefore describe ±60°.

Before selecting **Apply**, physically confirm the pan center and scale, the
entire lower-tilt clearance band, both hard ranges, and the counter-gain sign.
Command all three neck channels off and confirm the readouts show
`P OFF`, `L OFF`, and `U OFF`; Cerebro rejects live calibration changes while
any target is nonzero or any readout is `UNKNOWN`. A reconnect changes all
three readouts to `UNKNOWN`, so the operator must issue a fresh all-off command
before Apply is accepted. Applying only validates and saves one versioned
configuration object; it does not submit any neck or arm motion.

Existing V1 and V2 settings retain their common calibration values on upgrade.
V3 adopts the 5300–6822 inclusive full-pan band when it fits the saved lower
hard range, starts the forward window at 6823 (or the saved lower maximum when
necessary), clips −15.0°…+2.1° inward to the saved pan range, and defaults
**Keep camera upright** to on. Every migration is marked unconfirmed, so the
operator must verify all fields and Apply again with all three channels known
OFF.

With no valid confirmed configuration, Cerebro loads the shipped suggestions,
keeps pan inside the tightest configured window, forces the effective counter
gain to zero, and holds automatic lower-neck motion. Only a direct lower-tilt slider or
lower-enable action can authorize an explicitly supervised calibration jog;
touching pan or upper-camera controls cannot qualify. The status identifies
this mode. It does not energize an unverified compensation direction
autonomously.

## Dynamic pan envelope

The pan window is an asymmetric envelope over the commanded lower-tilt target:

- When lower pose is off or unknown, the gateway cannot know which extreme the
  mechanism occupies, so it uses the intersection of every configured window.
  With the shipped values, that fail-closed window is −15.0°…+2.1°.
- At the backward lower hard bound, the same symmetric restriction applies.
- Between the lower minimum and the start of the full-pan band, the allowance
  increases linearly from the symmetric restriction to full pan.
- Inside the full-pan band, full symmetric pan is allowed.
- Between the end of the full-pan band and the configured forward anchor, the
  negative and positive bounds each interpolate toward their independently
  configured forward values. In the shipped configuration those integer
  targets are adjacent: `6822` still permits full pan, while `6823` immediately
  applies the forward window.
- At lower target `6823` and farther forward—including the example target
  `7277`—the shipped configuration clamps pan to exactly −15.0°…+2.1°.
  With the shipped center and scale, those degree endpoints correspond to raw
  pan targets 5500 and 6070.

A request toward a more restrictive lower pose tightens the envelope
immediately. If needed, Cerebro holds lower tilt while it brings pan inside the
new envelope and establishes a usable upper-camera target. A request toward
greater clearance does not expand pan immediately: the commanded lower target
must remain in place for the current 0.75-second settling interval. Pan
recentering—and establishing a usable upper-camera target when that coupled
axis was previously unknown or off—uses the current 1.0-second staging
interval. A direct lower-axis recovery authorization is latched only for its
exact pan/lower/upper demand long enough to complete this staging. These are
command-timing guards, not proof that the mechanism settled.
Every changed pan target starts the same monotonic settling age, including a
pan-only command issued before a later lower request; a pan reversal restarts
the lower-release gate. Repeated identical lower demands do not postpone the
0.75-second clearance-expansion deadline.

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

The reference is the midpoint of the configured full-pan lower band. Changing
the checkbox adopts the currently applied upper-camera command as the new
camera demand, takes a short manual neck lease, and rebases the current lower
target. This prevents the mode change itself from jumping a known active neck
pose and does not submit any arm commands. If any neck command is `OFF` or
`UNKNOWN`, the mode is saved without energizing it. Subsequent lower motion
shifts the upper-camera target in the configured counter direction and clamps
it to the upper hard range. When **Keep upright** is off, the upper target is
still hard-clamped but is not adjusted in response to lower motion.

The gain sign is mounting-specific. A sign that counter-rotates one physical
installation can amplify tilt on another. Confirm under direct supervision
that a positive lower-target change produces the upper motion that keeps the
camera upright. Gain `0` also disables compensation even when the checkbox is
on.

After lower tilt has been OFF or its command state is unknown, Cerebro cannot
infer its physical starting angle. Automatic and gesture lower moves stay
blocked. The first re-enable must be a directly supervised torso-slider
recovery; it establishes a command-space reference, and counter-rotation
applies to subsequent lower moves. Watch and support the camera during that
recovery because there is no sensor data from which to level the first move.

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
