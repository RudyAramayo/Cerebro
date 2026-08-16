# Vision Pro supervised Amber arm control

`ROBControllerVision` can move either or both Amber B1 arms through Cerebro's
authenticated control session. Left and right authority, measured state, selected
joint, target lease, and completion remain independent. The path is deliberately
measured joint-space jogging; tracked controller poses are not Cartesian arm targets
and are not used for IK puppeteering.

```text
Amber measured telemetry + verified actuator modes
    → ROBArmControllerBridge
    → rob-arm-control/2 measured_state
    → authenticated ROBControl v2 application frame
    → RobotSession / Amber Arm Control panel

Vision operator initializes each arm from its measured pose
    → independent authority_intent bound to controller + live session + arm
    → Cerebro captures each fresh baseline and grants a per-arm authority UUID
    → independent screen holds, or both Sense grips + two vertical thumbsticks
    → per-arm target_intent(authority UUID, dead_man_held, short lease)
    → per-arm Cerebro preflight + leased Amber gateway trajectory
    → per-arm accepted / executing / measured-complete disposition
```

The Vision app never activates an arm or changes an actuator mode. Those operations
remain local, explicit Cerebro diagnostics actions because mode changes can remove
torque. The operator must support the arm when appropriate, clear its workspace, and
keep the physical E-stop available.

## Protocol and identity

`rob-arm-control/2` uses strict JSON messages no larger than 8 KiB:

- `measured_state`
- `authority_intent` and `authority_state`
- `target_intent`
- `hold_intent`
- `target_disposition`

Unknown fields, invalid enum values, non-finite numbers, wrong vector lengths, and
schema/version mismatches are rejected. Cerebro also recognizes claimed v1 frames
only to consume and reject them; they cannot fall through to the historical
keyed-archive parser.

Every operator intent carries the paired controller UUID, the exact current control
session UUID, a monotonically increasing sequence, an issued timestamp, and a lease.
`AutoNetServer` routes responses only to the matching authenticated v2 operator
session. Legacy/plaintext and telemetry-only peers cannot receive arm traffic.

## Measured state and authority

Cerebro publishes each arm at no more than 25 Hz. A measured message contains exactly
seven positions, velocities, currents, statuses, and actuator modes plus its source
age and sequence. Consumers add local monotonic elapsed time to the source age, so a
frozen cached sample becomes stale even if wall clocks change.

An authority acquire request is valid for 60–600 seconds. Cerebro grants it only when:

- the exact authenticated operator session is still current;
- no authority or motion executor already owns that arm;
- the Amber gateway is authenticated and exclusively owned;
- a measured sample is no more than 250 ms old; and
- all seven actuator modes are position mode (`2`).

The grant is non-persisted and bound to one controller, session, and arm. It includes
a server authority UUID, expiry, the captured seven-joint baseline, baseline
sequence, and modes. The two arms can hold independent grants concurrently; neither
grant substitutes for the other arm's freshness, mode, lease, or measured-completion
checks. Session replacement, expiry, explicit release, shutdown, or gateway failure
revokes affected authority and requests a measured-position hold when motion may be
active. A delayed grant cannot restore a Vision latch that the operator already
cleared.

## Bounded execution

Vision keeps a separate measured/baseline draft and selected joint for each arm.
Each on-screen hold loop can run independently and changes one selected joint per
segment while taking the other six from current measured feedback. It clamps the
selected target to both:

- the calibrated B1 bounds: J1 ±2.4435, J2 ±2.3213, J3–J6 ±2.2863, and J7 ±3.05
  radians; and
- ±0.08 radian from the measured/baseline position.

Vision sends a 0.65-second segment with a 1,000 ms wire lease only after the operator
holds that arm's dedicated screen control through its visual dwell. Both screen
lanes can run at once. Releasing one screen control requests an ordinary hold for
that arm without interrupting the other arm. Cerebro independently requires the
matching unexpired authority UUID, `dead_man_held=true`, a 50–1,500 ms intent lease,
current session identity, fresh telemetry, seven position-mode joints, at most 0.10
radian target-to-measured change, at most 0.20 radian/second requested average speed,
and no other executor reservation for that arm.

With the arm panel open, paired PSVR Sense jogging additionally requires two
connected controllers, both independent authorities, fresh measured state and
position mode for both arms, and both grip buttons newly held after preflight. The
left and right vertical primary sticks independently jog the matching arm's selected
joint. The pure joint mapper applies a 0.15 dead zone, copies the other six joints
from each latest measured sample, and limits every output to the B1 bounds, no more
than 0.08 radian of measured-relative change, and no more than 0.20 radian/second.
It does not consume controller position or orientation.

After preflight, Cerebro sends `leased_trajectory` to the loopback-only authenticated
Amber gateway. The gateway converts the accepted lease to its own receipt-time
monotonic deadline. It never extends a lease from the sender's wall-clock timestamp.
Cerebro reports `accepted_for_execution`, then `executing`, and reports
`completed_measured` only after three distinct fresh samples settle within 0.04
radian and 0.10 radian/second. Transport acknowledgement alone is never completion.

## Dead-man, holds, and watchdogs

Releasing an on-screen hold sends an ordinary `hold_intent` for that arm. In paired
controller mode, both grip buttons are one dead-man: releasing either cancels both
jog loops and sends ordinary holds for both arms, but retains their authority grants
for a deliberate fresh two-grip resume.

A controller disconnect, more than 250 ms without a fresh controller sample, stale
arm telemetry, position-mode/preflight loss, target timeout or send failure, scene
loss, software E-stop, authority/session/gateway loss, or operator **Priority Hold
Both Arms** takes the stronger priority path and clears both Vision arm latches. A
hold does not require live authority, so it remains usable while authorization state
is uncertain.

Cerebro's `priorityHold` captures a new measured pose and is successful only when the
gateway explicitly returns `hold_confirmed=true`. An unconfirmed hold or execution
failure clears the Vision arm latch and requires a new explicit enable operation.

The gateway independently holds an active leased trajectory when its monotonic lease
expires, the Cerebro TCP session disconnects, its heartbeat expires, or it shuts
down. Named catalog gestures renew the same short gateway lease while Cerebro remains
healthy; a failed renewal requests holds. The gateway never activates an arm to make
a hold possible: if the arm is not already entirely in position mode, the hold is
reported unconfirmed.

The Vision software stop latches locally and sends the primary emergency command
before approval-withdrawal or arm-hold cleanup. It supplements rather than replaces
the independently wired physical E-stop.

## Controller-approved named gestures

The Vision action console can separately approve one immutable `play_gesture`
request. Gemini/controller messages may supply only an approved catalog name, never
raw joint values. Cerebro reserves every participating arm, rechecks the same gateway,
telemetry, position-mode, per-joint step, and average-speed gates, executes with
renewable gateway leases, and owns the `executing` and measured terminal statuses.
Automatic cancellation, deadline, authority loss, or gateway/session failure holds
only the arms reserved by that gesture run, preserving an unrelated arm owner.
Explicit software stop and shutdown use the separate global priority-hold lane.

## Calibrated grippers

Gripper messages use the separate strict `rob-gripper-control/1` protocol on
the same authenticated operator session. Calibration is deliberately performed
locally in **Amber Arm Diagnostics…**, one gripper at a time, because it can
move through full travel. Vision cannot request calibration. A reconnect,
heartbeat expiry, gateway restart, or detected same-arm telemetry outage clears
the session-local calibration acceptance. Fresh feedback does not restore it.
Operators must also recalibrate after every known arm-core power cycle: the
vendor status has no explicit boot-generation signal, so an extremely fast
restart with no observable telemetry gap cannot be detected automatically.

After calibration dispatch is accepted, the Vision arm panel and the matching
PSVR Sense index trigger can request `hold` or `release` at 2–20 raw vendor
intensity units while both controller grip buttons are held. Cerebro rechecks
the live session, local time-limited controller authority, calibration state,
lease, sequence, dead-man, and one-command-at-a-time gate immediately before
calling the Amber gateway.

An accepted result is reported as `dispatch_acknowledged_unverified`. Amber
does not report measured jaw opening, applied force, object detection,
calibration completion, or command completion. The intensity is not newtons,
and no gripper stop/cancel primitive is currently documented. Releasing the jaw
is another movement command, not a stop.

## Deliberate exclusions

- No Vision-initiated arm activation, deactivation, or actuator-mode transition.
- No PSVR/world-transform-to-joint IK, tracked-pose Cartesian puppeteering, collision
  planner, or workspace model. Paired Sense input is measured joint jogging from the
  two vertical thumbsticks only.
- No model-supplied joint arrays in `play_gesture`.
- No simulator claim of physical Amber execution.
- No claim that a software/network hold is equivalent to the physical E-stop.

## Verification

Run the standalone Cerebro fixture:

```sh
fixture_dir="$(mktemp -d /private/tmp/rob-arm-fixture.XXXXXX)"
xcrun swiftc -swift-version 5 -warnings-as-errors \
  -module-cache-path "$fixture_dir/module-cache" \
  Cerebro/ROBArmControlProtocol.swift \
  Tests/ROBArmControlProtocolFixtureTests.swift \
  -o "$fixture_dir/fixture"
"$fixture_dir/fixture"
```

Run the Vision package and app checks:

```sh
swift test --package-path /Users/rob/dev/ROBControllerVision/Packages/ROBControlCore
xcodebuild -project /Users/rob/dev/ROBControllerVision/ROBControllerVision.xcodeproj \
  -scheme ROBControllerVision -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Automated checks cover strict wire schemas, all B1 boundaries, identity/session and
late-grant handling, telemetry/mode/authority gates, bounded targets, hold lifecycle,
gateway watchdog/renewal behavior, and emergency-stop ordering. They do not replace a
two-device hardware-in-loop test of the deployed gateway, both arms, the Vision UI,
network loss, and the physical E-stop.
