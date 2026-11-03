# Continuous arm trajectory owner

This is an offline-tested replacement for the **trajectory ownership layer**,
with an inert CAN codec, driver boundary and explicit Linux SocketCAN backend.
It is not an installed Amber driver. The portable tests have no socket I/O;
the Linux integration fixture uses only isolated virtual CAN on a disposable
runner. There are no torque/mode commands, daemon, installer or automatic startup. The running
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
build. CTest also registers the owner, codec and driver-boundary suites plus the
legacy numerical fixture.

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
  two's-complement arithmetic. Quantized counts must lie in the asymmetric
  -32766..32767 domain. In particular, negative -32767 would encode `0x8000`
  and flip sign on decode; it is rejected. An encoded-word roundtrip is also
  checked before returning a batch.
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

`ROBAmberWireCodecTests.cpp` adds eight groups: 14 golden frames across both
arms, signed boundary cases, malformed IDs/DLC/flags, atomic input rejection,
420,014 quantized joint roundtrips with both signs, 917,476 exhaustive integer-
domain roundtrips including both endpoint words and the sign-flip rejection,
owner integration with ideal
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

## Offline driver boundary (2026-11-02)

`ArmDriverBoundary` connects the owner to a supplied fake frame writer. It
implements admission and failure handling without opening a transport. The
tests are the executable integration example; this component is not a daemon
or a deployment switch.

1. A trusted receiver calls `resetSource` with a strictly increasing source
   epoch, then `observe` for each of seven joints with receiver-owned monotonic
   timestamps. Wrong arm/epoch, future/stale/duplicate observations and malformed
   packets are rejected. Each joint retains its timestamp watermark even when
   a bad tag or out-of-bounds position invalidates its observation.
   The boundary samples one injected monotonic clock after acquiring its lock.
   A receive timestamp captured before waiting behind a write is checked for
   actual age, not misclassified as a clock reversal from a stale caller `now`.
2. `begin` needs an explicit external stationary-start grant, a new generation,
   a bounded writer lease and fresh observations for **every** joint. A bounded
   history checks sample count, time span, maximum sample gap and position range.
   The returned zero-derivative seed is an authorized stationary assumption:
   quantized position history cannot prove physical zero velocity, torque or
   safe payload support. A host adapter must establish those conditions before
   granting the start. Reply tag and position-status admission are explicit
   fixture policy, separate from raw decoding; their firmware contract still
   needs commissioning.
3. The thread that called `begin` is the only publication thread. Calls to
   receive, renew, revoke and publish serialize through this instance. The
   complete seven-frame batch is encoded and validated before the first write.
   Publication checks source/lease, every joint's freshness, sample timestamp
   and sequence, finite state, bounds and one shared deadline. Replay and return
   to following after a braking sample are rejected.
4. Each callback reports accepted, definitely rejected, or uncertain. An
   exception is uncertain. Failure, a late return or a clock reversal records
   the attempted/accepted prefix, latches the first fault and sends no retries.
   An accepted frame means transport acceptance, not actuator receipt. Seven
   separately delivered frames are not an atomic robot command.
5. Receive processing itself latches loss of admitted mode, bad tag/range,
   elapsed freshness or lease expiry. A good packet or recovery burst cannot
   hide that loss between owner ticks. Faults clear all stationary history.
   Recovery needs a complete new history and a new explicit generation/grant;
   renewing an expired lease cannot revive it.

The owner handles target expiry and controlled Stop while the driver claim is
still valid. Driver lease/feedback loss revokes publication; it cannot promise
a physical stop when the channel is unavailable. An in-flight batch completes
or faults before `revoke` returns, and no later frame from that claim is sent.
Callbacks must be bounded and nonreentrant. Checking a deadline after a callback
returns **cannot interrupt a blocked write**. The future backend needs bounded
queueing/I/O, OS-level exclusive ownership and an independent watchdog.

There must be one shared boundary instance per physical arm. This mutex does
not exclude another object, process or existing vendor core from CAN. Epochs,
timestamps, grants and the clock are trusted adapter inputs, not client claims.
A future receiver must discard pre-epoch queued data and establish physical
feedback age; assigning a fresh timestamp to an old buffered frame is not proof
of freshness. No physical velocity/current interpretation or mode command is
implemented here.

Eleven boundary regression groups cover admission, timestamp watermarks,
transient feedback loss, source restart, replay, leases, thread ownership,
concurrent receive/revoke, and every failure position in a seven-frame batch.
The 35 write-fault cases inject rejection, uncertainty, exception, late return
and backward clock at each of seven frames. An integrated 200 Hz owner with
20 Hz ideal quantized feedback emits 8,127 recorded frames over 1,161 ticks and
100 targets, renews its lease, then reaches controlled hold after Stop. These
are simulated timing and ideal-feedback results, not a physical motion test.
The full suite has 38 groups (19 owner + 8 codec + 11 boundary), plus the legacy
fixture. Source-bound results are recorded separately under
`docs/calibration/evidence/2026-11-02-arm-driver-boundary/`; the earlier codec
reports remain historical snapshots.

## Kernel receive-clock conversion

`ReceiveClock` keeps Linux kernel realtime receive timestamps and monotonic
clock correlations as signed 64-bit integer nanoseconds. A monotonic/realtime/
monotonic bracket bounds correlation uncertainty. It requires a strictly new
source epoch after clock failure, rejects backwards monotonic time, and admits
only brackets wholly inside the initial offset interval plus the configured
variation allowance. Packet age uses the earliest possible offset in that
entire interval. Using only the current offset can make queued packets appear
younger after a small backwards wall-clock step, even when that step is inside
the allowed tolerance.

The policy assumes the offset stays inside that expanded interval throughout
the epoch. Measurements cannot prove that an unobserved excursion between
correlation samples did not happen. The conservative allowance can delay new
source admission and reject otherwise usable borderline packets. Old-epoch,
future and stale packets are rejected without relabelling dequeue time as
receipt time. Four regression groups include permitted positive/negative clock
steps, overflow, restart, and an exact one-nanosecond age boundary at a modern
realtime epoch; floating-point absolute realtime cannot preserve that boundary.

This measures **kernel receipt age**, not actuator sample age. The serial CAN
adapter, USB/TTY queues and firmware may add delay before the kernel sees a
frame. The upstream Linux 5.15 slcan driver does not provide hardware receive
timestamps or decode bus-error frames. An error-frame filter alone therefore
cannot prove bus-off detection on the installed transport. Those capabilities,
queue behavior and independent watchdog still need supported bench evidence.
See the primary [Linux timestamping documentation](https://docs.kernel.org/networking/timestamping.html)
and [5.15 slcan source](https://github.com/torvalds/linux/blob/v5.15/drivers/net/can/slcan.c).

The Ubuntu 22.04 CI job uses a disposable GitHub-hosted runner with a read-only
repository token. It builds the same pinned source without robot access and
reports virtual-CAN module availability separately from test success. An absent
vcan module is not a passing transport integration test.

## Explicit Linux SocketCAN backend

`SocketCanTransport` construction opens nothing. `open` needs a new source
epoch and defaults to a kernel-verified virtual interface with transmission
disabled. A trusted future lifecycle may select physical interfaces only via
the existing physical-side mapping; setting an option is not proof of exclusive
ownership, commissioning or motion authority. No hardware instance has been
opened during development.

The backend binds one nonblocking, close-on-exec raw socket, exact standard
joint filters, error-frame subscription, nanosecond kernel timestamps and
overflow reporting. It checks the current `SO_MEMINFO` receive-drop counter
before and after reading and before every send. Ancillary drop metadata alone
can be stale when earlier queued frames predate an overflow. Bounded receive
batches, queue age, address/ID/DLC, truncated control data and clock errors all
fail closed. Rtnetlink virtual-interface verification checks the kernel sender
and truncation, not just an interface name.

Each position write is one nonblocking call with a deadline check and no retry.
The socket's allocated transmit memory is a backpressure threshold, not a
device FIFO length, delivery deadline or motor acknowledgement. CAN_RAW's
target 5.15 implementation does not provide a socket-level `SIOCOUTQ` handler;
the backend uses `SO_MEMINFO` instead. Its receive-address minimum covers the
family and interface index, matching the shorter address returned by CAN_RAW.

The backend records kernel-accepted frames separately from the boundary's
Accepted-reported count. If a post-send clock read fails, the return is
Uncertain while the backend can still record a known kernel acceptance. A
lifecycle must retain both diagnostics; it must never replay that write.
Accepted traffic may remain in serial/device queues after software faults.
The slcan limitations and independent watchdog requirements above still apply.

`test-amber-linux-isolation.py` refuses non-hosted environments and hosts with
existing CAN devices. It creates only its own virtual fixture, checks both a
socket opened before the namespace move and a new host bind, then runs the
backend tests in the private namespace. The fixture verifies virtual type
before sending any frame. Passing this does not prove that the real slcan
interface can be moved or that old physical-controller sockets are excluded;
those remain supervised cutover checks. Linux compilation and native integration
results are recorded by CI, separately from portable simulation results.
