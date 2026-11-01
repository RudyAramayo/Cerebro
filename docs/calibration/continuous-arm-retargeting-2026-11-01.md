# Continuous arm retargeting: implementation and remaining integration

## Outcome

An offline C++ trajectory owner now implements continuous target replacement
without a settle gate. It passed 19 test groups in Release, Address/Undefined
Behavior Sanitizer and Thread Sanitizer builds, against pinned Ruckig 0.9.2.
This is a source implementation and simulation result. **The installed robot
is not fixed yet:** no vendor core, gateway, URDF, app or Vision Pro build was
installed/restarted. No motor command was sent in this task.

Rudy ended physical testing for sleep. Both other active chat threads received
the bedtime/no-questions-until-morning instruction. The pour thread confirmed
offline-only work and no runtime restart. Native `speech.say` with source
`codex` supplied progress, without routing status through Gemini.

## Why overlapping commands go wrong

The [October 31 investigation](arm-transition-review-2026-10-31.md) traced the
installed binary, not just a model or the GUI. A fresh read-only Amber check
found the same core PIDs 990/991 and binary SHA-256
`554e7088b94b98f03f152f394c5e5b1d1ecfd16dacd470889e65dc83c36d2100`.

1. UDP command 4 is converted to a joint-position task; it does not go through
   the URDF/Drake collision solver. The gateway mutex ends at acknowledgement,
   which is not trajectory completion.
2. `RuckigController::Handler::handleMessage` starts a detached worker for each
   new target. Its replacement worker reads commanded position and separately
   sampled finite-difference velocity/acceleration. They are not one coherent
   state at one instant.
3. The cancellation timestamp check and output write are not one transaction.
   An older worker can still write after a replacement. Target arrays are also
   shared between handlers/workers.
4. Launch dynamic values are extremely permissive. A minimum requested duration
   is not a physical velocity, acceleration or jerk limit.

These are confirmed defects capable of explaining the symptom. The historical
internal handoff state was not recorded, so this is not a claim that every
reported rotation had the same measured cause. In the isolated numerical
fixture, J6 starts at +0.34 rad and targets +1.05 rad. A coherent +0.2 rad/s,
zero-acceleration seed travels forward. The hypothetical missed-sample seed
v=0, a=-40 rad/s^2 produces a minimum of -5.262596 rad under the installed
configuration. That is a mathematical excursion, not an observed physical turn.
Waiting for settling hides the inconsistent derivative state; it does not
repair ownership.

## What the implementation changes

Source: [ContinuousArmController](../../Tools/ContinuousArm/ContinuousArmController.cpp),
[API/contract](../../Tools/ContinuousArm/README.md),
[tests](../../Tests/ROBContinuousArmControllerTests.cpp),
[reproduction command](../../Scripts/test-continuous-arm.py).

One owner stores the last successfully published q/v/a snapshot. New targets
replace a bounded one-slot mailbox with increasing sequence and host generation.
Each tick uses that same PVA state to replan, advances by elapsed monotonic time,
checks the complete trajectory and its stopping envelope, then publishes inside
the same ownership transaction as Stop. It never restarts from redifferentiated
command samples, clips a planned joint position, wraps a revolute joint, or
creates a new worker for a target.

Release/tracking-target timeout causes controlled braking and a latched hold.
Fresh feedback must stay in position mode, with authority and bounded tracking
error. Stale feedback, a scheduler gap, wrong tick thread, uncertain sink result,
or an unreviewable stop latches a fault. There is no automatic reconnect replay.
An independent physical watchdog is required when no safe output can be issued;
the library cannot claim to stop a motor whose output/feedback channel failed.

Tests uncovered a separate bounds-helper issue in Ruckig 0.9.2. Velocity profile
initialization leaves `pf` unset, but the position-extrema helper reads it; its
root routine also skips the zero-jerk/nonzero-acceleration velocity-zero root.
The new analytical checker uses initialized polynomial segments, their endpoints
and all relevant roots, including brake and unequal-duration tail segments. It
checks dynamics between output samples, not only sampled joint angles.

## Evidence

The sanitized machine-readable records are in
[`evidence/2026-11-01-continuous-arm`](evidence/2026-11-01-continuous-arm).
They bind exact source hashes, Ruckig commit and build variant to results.

| Check | Result |
| --- | --- |
| Seven-joint target stream | 4,200 accepted targets, 14,000 output samples |
| Targets replaced while J6 was moving | 3,898 |
| Target/tick rates in primary replay | 66.7 Hz / 200 Hz, 70 s simulated |
| Maximum speed / acceleration / discrete jerk | 0.3 rad/s / 0.6 rad/s^2 / 2 rad/s^3 |
| Maximum 5 ms position step | 0.0015 rad |
| Final stationary target | All seven joints reached 0.1 rad |
| Additional pose rates | 20, 60, 90 and 120 Hz passed |
| Mailbox bursts | 1,000 packets -> one planned target; 100,000 concurrent submissions -> one slot |
| Analytical envelope cross-check | 250 randomized trajectories, 526,750 joint-state observations |
| Failure cases | Sequence/generation, invalid values, expiry, Stop race, scene rejection, unsafe braking, feedback/mode/authority loss, stalled/duplicate ticks, sink uncertainty, second worker |
| Memory/undefined behavior/race checks | Release, ASan+UBSan and TSan all passed 19 groups |

These limits are **illustrative simulation settings**, not measured motor
capabilities. Feedback in the tests follows the prior output perfectly except
when faults are deliberately injected. The empty simulated world and analytical
joint checks do not certify physical clearance, inertia, payload, current,
latency or tracking. Test cadence is simulated; hardware scheduling is untested.

## URDF findings and required model work

The fresh live file audit reproduces the prior hashes. Physical RIGHT is the
vendor L-10/left/CAN10 chain; physical LEFT is R-11/right/CAN11. Do not swap them.

| Layer | Observed | Needed |
| --- | --- | --- |
| Selected vendor URDF | Base + seven arm links; no other arm, torso, head, jaws, table or floor | Use the seven-joint chain for its verified kinematic role; a full paired robot/world model is needed for collision admission |
| URDF limits | Every joint +/-2.09 rad; velocity 1,000,000; effort 100,000 | Resolve real per-joint position and dynamics from hardware commissioning; enforce in the output controller too |
| Launch dynamics | 5400/4200 deg/s, 90000 deg/s^2, 5000 deg/s^3 after the observed conversion | One explicit SI limits profile shared by planner, preview, gateway and controller |
| Cerebro preview model | 45 links, 44 joints; velocity/effort entries zero | Complete calibrated frames and collision hulls; zero placeholders are not usable physical ratings |
| Joint/tool references | Alternating solver signs and unmeasured tool offset remain | Measure signs, zeros, torso/base/neck relationships and gripper/tool/payload frames independently |

The table/floor shown by a viewer are not evidence that they participate in the
direct joint-command path. Changing a URDF alone cannot fix detached workers or
make UDP command 4 obey collision constraints. Do not insert a 45-link robot into
an unverified seven-DOF solver configuration, guess joint signs or overwrite
hardware limits merely to match a preview. No such edits were made.

## Vision Pro path to continuous control

The local app is `ROBControllerVision` (the requested ROBControllerVR use case).
Its existing in-progress teleop code already keeps the latest pose and sends at
roughly 20 Hz. The separate Cerebro teleop branch deliberately waits for an old
joint run to finish and dispatches approximately 0.7 s segments. Removing that
guard while still using vendor UDP command 4 would expose the original defect.
Those pre-existing worktrees were not modified.

The intended path is: fresh clutched controller pose -> normalized quaternion
delta in calibrated robot coordinates -> continuity-preserving IK seeded from
the current commanded state -> full robot/world trajectory and stopping-envelope
review -> latest joint target -> this persistent owner -> exclusive native
setpoint sink. Use a bounded target age and a new generation after release,
tracking loss, fault or reconnect. Slow near singularities and joint/collision
limits; keep IK on the same local branch. The same q(t) should drive the ghost
and the robot, including the attached object rather than an independently
interpolated prop.

Base travel to the table and torso alignment belong in the whole robot scene.
Before arm reach, the ghost must use the planned tread-base transform and torso
yaw relative to the table normal, then reobserve after real body travel. An
arm-only solver cannot supply that approach. Coupled body/arm execution remains
a separate commissioned planner capability.

## Concrete remaining integration, after explicit morning resume

1. Obtain the source matching the live vendor binary or implement a complete
   exclusive native adapter. Searches found the binary, headers, URDF and older
   object files, but not the current wrapper source. The older objects lack the
   current speedoMeter path and are not a safe relink substitute.
2. Replace the old handler/worker ownership, do not run a second writer beside
   it. Adapt one units/reference conversion at the sink. Do not send 200 Hz
   samples as new UDP command-4 trajectories. Preserve current monitoring,
   ownership, mode and immediate hardware Stop protections.
3. Commission joint limits, coherent startup stationarity, watchdog behavior,
   actual cycle deadlines and tracking error on Amber. Measure the full robot,
   tool and world registration before claiming collision clearance.
4. Advertise a versioned continuous-target capability only after that driver is
   installed and verified. Bind it to limits/model/calibration revisions and
   host generation; keep existing measured-completion behavior for legacy cores.
   Then route the Vision Pro latest-pose lane through it and test empty-arm
   low-speed retargets, release/tracking loss and Stop under explicit resume.

There is no overnight request for an answer or automatic morning motor action.
The deliverable provides the software ownership implementation and evidence;
driver integration and physical validation remain open blockers.

## Primary implementation references

- [Pinned Ruckig 0.9.2 profile implementation](https://github.com/pantor/ruckig/blob/7de6b1035e1cad509251b31b3287d10fbcda6baf/include/ruckig/profile.hpp)
- [Pinned Ruckig 0.9.2 online update and coherent state handling](https://github.com/pantor/ruckig/blob/7de6b1035e1cad509251b31b3287d10fbcda6baf/include/ruckig/ruckig.hpp)
- [Ruckig official tutorial](https://docs.ruckig.com/tutorial.html) describes
  online state updates and `pass_to_input`; it is newer than the installed
  version, so the compiled tests use the exact pinned source above.
