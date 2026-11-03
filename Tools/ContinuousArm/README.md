# Continuous arm trajectory owner

This is an offline-tested replacement for the **trajectory ownership layer**,
not an installed Amber driver. It contains no sockets, CAN, LCM, torque/mode
commands, hardware adapter, daemon, installer or automatic startup. The running
vendor cores and Cerebro's measured-completion containment remain unchanged.
See the [investigation and integration handoff](../../docs/calibration/continuous-arm-retargeting-2026-11-01.md).

`ContinuousArmController` retains one coherent commanded position/velocity/
acceleration (PVA) state per arm. `submit` replaces one latest-target slot;
`tick` plans from the last published PVA and advances by elapsed monotonic time.
It never differentiates independently sampled positions or spawns a worker per
target. A target can change while velocity is nonzero.

All joint angles are **native-reference radians**, time is seconds, velocity is
rad/s, acceleration is rad/s^2 and jerk is rad/s^3. Limits and policy are required
constructor arguments; the values in the tests are illustrative, not motor
ratings or a commissioned robot profile.

## Reproduce without connecting to a robot

Use a clean checkout of upstream Ruckig v0.9.2 at
`7de6b1035e1cad509251b31b3287d10fbcda6baf`, matching the installed version:

```sh
git clone --depth 1 --branch v0.9.2 https://github.com/pantor/ruckig.git /tmp/rob-ruckig-0.9.2
python3 Scripts/test-continuous-arm.py \
  --ruckig-source /tmp/rob-ruckig-0.9.2 \
  --build-dir /tmp/rob-continuous-arm \
  --summary /tmp/rob-continuous-arm-results.json \
  --trace /tmp/rob-continuous-arm-trace.csv
```

Repeat in a distinct build directory with `--sanitizer address,undefined` or
`--sanitizer thread`. The wrapper rejects a changed or wrong-version checkout.
The CMake project can alternatively link an installed exact Ruckig 0.9.2 package.
It disables the online/cloud client, examples and Python bindings for a source
build. CTest also registers both the new suite and the legacy numerical fixture.

## Ownership and integration contract

- `start` requires a host-authorized, strictly increasing generation and a
  fresh, proven stationary PVA state matching feedback. It refuses active
  takeover. A boolean position-mode report does **not** prove stationarity:
  the adapter must establish it from valid measured history. Do not fabricate
  zero derivatives because the current gateway does not expose verified speed.
- Call `tick` from the same thread that called `start`. Other threads can submit
  targets, stop, and read a locked status snapshot. The library creates no
  threads. All callbacks must be bounded and must not reenter the controller.
- The path guard must review the entire remaining trajectory, with the current
  full robot, other arm, payload and world. It receives the starting trajectory
  time and a braking flag. A missing guard is rejected. The tests deliberately
  supply simulated geometry; they do not validate the real room.
- Every proposed sample must have a feasible reviewed stop envelope. Analytical
  position, velocity and acceleration extrema, jerk, finite values, joint bounds
  and output continuity are checked before the sink. Never clamp the output or
  wrap revolute joints after planning. No `minimum_duration` speed surrogate.
- The sink and Stop share one mutex transaction, so a cancelled target cannot
  publish afterward. Only subsequent controlled-braking samples can publish.
  The sink must perform one bounded, generation-checked write, not queue another
  trajectory. Its false return or exception is uncertain output and latches a
  fault; no automatic resend is permitted.
- Target expiry/release clears the pending target and brakes from coherent PVA.
  It stays held until a new explicit stationary generation. Feedback loss,
  tracking error, wrong owner thread, timing violation, unreviewable stop or
  uncertain output latches a fault before further output. **No software-output
  claim is a physical emergency stop.** An independent motor-side watchdog and
  physical Stop remain required, including when callbacks or the process stall.
- The configured timing and tracking bounds must be commissioned on Amber.
  A mutex and an offline 200 Hz simulation do not establish hard real-time
  scheduling, motor tracking, current limits or torque behavior.

## Installed Ruckig version detail

In v0.9.2, `Profile::set_boundary_for_velocity` does not set `pf`, while
`get_position_extrema` reads `pf`. Its extremum helper also omits a velocity-zero
root when jerk is zero and acceleration is nonzero. The owner therefore uses
`envelope`, integrating the initialized profile segments and checking roots of
velocity and acceleration, their endpoints, brake phases and unsynchronized
tails. It does not read `pf`. The suite verifies 250 randomized trajectories
against 526,750 dense joint-state observations plus an exact constant-
acceleration interior-maximum fixture.

## Hardware integration is outstanding

The [2026-11-02 executable audit](../../docs/calibration/evidence/2026-11-02-amber-executable/identity-and-startup.json)
rules out treating the existing configuration flags as a driver-only mode.
The matching live/archived executable constructs ten threads unconditionally,
including Ruckig, direct-position LCM, UDP and the solver. Its later enable
checks guard `join()`, after construction; they do not disable those workers.
The direct-position LCM handler writes the same target array as Ruckig. This
library must therefore not be connected to that handler alongside the old core.

Replace the installed vendor worker/handler with this ownership pattern or
build a fully exclusive commissioned driver. Do not run this beside the old
workers, feed samples to UDP command 4, or publish raw LCM/CAN around Cerebro's
guards. The source corresponding to the live core binary was not found; older
object files are not a safe rebuild substitute. No continuous-stream capability
should be advertised to ROBControllerVision until that integration, measured
limits, collision calibration and watchdog commissioning pass.

## Inert Amber wire compatibility component (2026-11-02)

`AmberWireCodec` is a pure packet encoder/diagnostic decoder. It has no network
or SocketCAN implementation, mode/gripper/calibration command, daemon, lease,
startup behavior or watchdog. Encoding a batch does not authorize transmission.
The executable audit above and the matching `positionCanSender::sendPosition`
(`0x394d8`) / `canRecv::convertfromCan` (`0x38d99`) disassembly define its
compatibility target, not a claim that motor firmware has been validated.

- Physical RIGHT maps to vendor L-10 / CAN10 / `Left_`; physical LEFT maps to
  R-11 / CAN11 / `Right_`. Explicit per-joint directions must be +1 or -1.
- Seven native-reference radian positions become seven standard CAN frames,
  IDs `0x11..0x17`, DLC 3, opcode `0x40`, big-endian position word. Conversion
  applies radians-to-degrees once, then direction and 128 counts/degree.
- The audited sender truncates to an integer **before** checking the sign.
  Negative integers add 65535, not 65536. Sub-count negative values therefore
  encode `0x0000`. The decoder preserves `0x8000 => +32768`,
  `0x8001 => -32766`, and `0xffff => 0`; it does not silently substitute ordinary
  two's-complement arithmetic. Encoder inputs outside the unambiguous
  -32767..32767 count domain are rejected before integer conversion.
- Every input and its quantized result must lie inside explicit caller bounds.
  NaN, infinity, invalid bounds/signs/arm, overflow or any invalid joint rejects
  the whole batch. There is no clipping, wrapping or partial output.
  This is atomic batch construction, not atomic bus delivery: a future transport
  must separately handle failure after only some of seven frames were written.
- Diagnostic feedback accepts only exact standard joint IDs `0x91..0x97` and
  DLC 8. It retains the reply tag, raw status and signed velocity/current counts.
  The observed current `/256` value is named vendor-scaled, not amperes. Reply
  tag semantics, physical speed/current units, timestamps, authority, stationary
  startup proof and firmware behavior are not established by this decoder.

`ROBAmberWireCodecTests.cpp` adds seven groups: 14 golden frames across both
arms, signed boundary cases, malformed IDs/DLC/flags, atomic input rejection,
420,014 quantized joint roundtrips with both signs, owner integration with ideal
quantized feedback, and a rejected batch that latches the owner's output fault.
The integration records 42,000 frames over 6,000 owner ticks with 20 Hz ideal
feedback and 1,358 retargets while moving. No packets leave the process.

One position count is about 0.000136354 rad. Quantized wire steps can exceed the
continuous curve's step by one count; their finite differences are not the
continuous PVA or measured motor speed/jerk. This matters for future drive
commissioning. Do not reinitialize the planner's PVA from quantized setpoints.
The test script runs this suite alongside the existing 19 owner groups and the
legacy numerical reproduction. Results and source hashes are under
`docs/calibration/evidence/2026-11-02-amber-codec/`.
