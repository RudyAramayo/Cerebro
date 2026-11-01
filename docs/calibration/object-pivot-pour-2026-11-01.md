# Object-pivot pour planning — November 1, 2026

Rudy requested this offline improvement after an assisted Coke pour spilled
and displaced the glass. Physical testing stopped for sleep. The can is
released on the table; the left slide never ran. This source change neither
restarts Cerebro nor enables playback. See the [physical record](can-pour-resume-2026-10-31.md)
and [sanitized evidence](evidence/2026-10-31-can-pour/resumed-pour-checkpoint.json).

## Reproduce in Cerebro

Testing Sandbox → **Coke can · timed pour** retains the saved scene and adds:

- **Pivot above opening (mm):** 0 selects the lip itself; a positive distance
  selects a point above it in the upright can frame. The actual opening traces
  an arc around an elevated pivot and must remain inside the protected aperture.
- **Can tilt (degrees):** 0 uses the existing static fill estimate; 1–170 requests
  an explicit geometric tilt. Explicit tilt does not predict delivered volume.

Run recomputes the scene, IK, payload/whole-model collision review, linear joint
path and timed-curve reviews. It saves the input and report under
`~/Library/Application Support/Cerebro/CanPourTests/`. Failed geometric attempts
replace the latest report, preventing an older passing result from representing
new parameters. Existing schema-1 previews must be regenerated.

The native ghost shows a cyan fixed pivot/axis and a yellow opening trace.
While attached, the can follows FK of the same interpolated arm joints shown
by the robot. It no longer independently interpolates an ideal can pose that
could hide opening drift. A blocked audit is displayed as blocked; all reports
and previews remain non-executable. Saved scene geometry is not the current
physical table, glass or arm pose.

## Geometry and path contract

`ObjectPivot` accepts an arbitrary finite point and nonzero axis in the initial
object frame. If `p` is that point, `a` the normalized local axis, `R0` the
initial object orientation and `c` the fixed scene anchor:

```
R(theta) = R0 * Exp(a * theta)
t(theta) = c - R(theta) * p
worldFromTool(theta) = worldFromObject(theta) * objectFromTool
```

The full object/tool lever arm contributes to translation. A wrist-only
rotation or holding the object's center fixed does not satisfy this constraint.
The world axis is `R0*a` throughout the motion; neither yaw nor pivot height is
silently relaxed to make an unreachable target solve. A full 160° geometric
path is supported, but a specific grasp may fail IK or clearance.

Scene JSON can supply `rotation.pivotAboveOpeningMeters`, or an explicit
`rotation.pointInObject` three-vector in meters, plus `rotation.axisInObject`
and `rotation.tiltDegrees`. The point and opening-offset forms are mutually
exclusive. For a nominal 120 mm can with lip radius 25 mm, this selects a point
10 mm above the lip:

```json
{"rotation":{"pointInObject":[0.025,0,0.070],"axisInObject":[0,1,0],"tiltDegrees":160}}
```

The cylinder support envelope covers the entire requested angle, including
past horizontal, with a bounded reserve between angular samples. Both the
selected pivot and the actual lip are checked. A 30 mm elevated pivot is
rejected for the regression glass because its opening arc exceeds the margin.

Recovery copies the outward IK joint solutions exactly in reverse. It does
not re-solve identical Cartesian targets into another redundant-joint branch.
The quintic timed curve also reverses the same curve and velocity. Both paths
are audited by FK for pivot drift, aperture containment, fixed-axis deviation
and angular progress. Linear segments are subdivided using joint lever-arm
travel bounds; the timed curve uses its conservative per-joint speed bounds
and sample intervals. Between-sample reserves are included. The default
model pivot tolerance is 5 mm and the landing inset is 15 mm. Raw limits and
existing collision/current/feedback/ownership/Stop guards are unchanged.

The recorded full pour used changing rotation azimuth/height and native
per-clip settling. It did not execute the ideal continuous fixed-time curve.
Exact planned reversal cannot establish symmetric motor tracking. A coherent
trajectory owner and independently observed tracking remain commissioning
requirements; do not implement this by sending overlapping `cmd4` targets.

## Offline validation

```sh
Scripts/test-can-pour.sh
Scripts/test-can-pour-native.sh
CEREBRO_INSTALL_AFTER_BUILD=NO xcodebuild -project Cerebro.xcodeproj \
  -scheme Cerebro -configuration Debug \
  -derivedDataPath /private/tmp/cerebro-pivot-build \
  CEREBRO_INSTALL_AFTER_BUILD=NO build
```

Validation passed: 25 Python geometry/model tests, the compiled native payload
fixture, native replay/parser fixtures, and a full Debug build with installation
disabled. The explicit 160° / 10 mm elevated-pivot saved-scene run solves every
IK target and passes its geometric rotation audit; full task clearance is
still independently blocked.

Geometry regressions cover arbitrary frame/axis transformations, a 160°
elevated-pivot rotation, exact return poses and timed velocity reversal,
invalid axes, unsafe opening arcs, fixed-axis deviation, conservative sample
coverage, and a path whose endpoints are correct but whose middle drifts.
The sanitized historical assisted-pour joint path is rejected for pivot/axis
drift; equal timed endpoints are not treated as a stationary interval unless
the compiler explicitly declares the hold.
Native fixtures verify copied return joint values, joint-derived payload
rendering and rejection of legacy/missing/inconsistent pivot records.

The default saved-scene linear review checks 3,152 poses with a maximum pivot
error bound of 0.589 mm. Its prepared timed curve checks 222 samples with a
4.821 mm bound. These are model bounds including sampling reserves, **not
measured robot accuracy**. Full task clearance and registration remain separate
blockers. The model has already missed physical head clearance and can/table
placement, and the liquid stream is not modeled. Do not promote an exact
equation, saved pose, nominal URDF, or one successful grasp into calibration.

No updated app was installed, no runtime restarted, and no motor command was
sent after the sleep shutdown. Future physical work requires explicit resume,
fresh observation of the moved cup and actual opening/grasp transform, and
the saved immediate filming cue before each motor action.
