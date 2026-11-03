# Amber controller replacement strategy

The practical development route is a small, source-controlled Ubuntu host controller that replaces the installed Amber core's motor-facing role. Preserve the actuator firmware, native joint references and observed wire protocol. Reuse the pinned Ruckig 0.9.2 math under one persistent owner per arm. The existing trajectory owner and new transport-free codec are offline components, not an installed or commissioned motor driver.

Rudy designated this operation high priority and sensitive on 2026-11-02. Physical testing waits for neck servo mount repair and explicit resume. This investigation used read-only SSH, file hashing and static disassembly; no motor packets, mode changes, process attachment, core execution, installation or restart were performed. Existing measured-completion containment remains in place.

## Why the executable must change

The matching live/archived ELF creates a detached Ruckig worker for each position task. Workers seed position from shared commanded state while velocity and acceleration are sampled separately. A cancellation/ownership check is separate from the publication of the next position. This establishes an overlap and incoherent-state hazard; it does not reconstruct the precise internal values during an earlier physical incident.

UDP command 4 converts joint targets into an LCM PosTask and bypasses Drake's IK/URDF path. The raw LCM PosCmd handler writes the same `directControl::jointPositionTarget` array used by Ruckig. Neither interface is a verified exclusive adapter for the replacement planner.

In `main`, ten threads are constructed unconditionally at 0x12ee0-0x12ff1, before the first permanent timer join at 0x13000. Later enable branches guard joins rather than construction. The observed flags therefore do not establish a driver-only mode. Linked `Controller::spin` and `Planner::spin` symbols are not evidence that their separate PosPlan path actually starts; no startup reference was found.

Changing the URDF or replacing `libruckig.so` leaves these host ownership paths in place. Binary patching, `LD_PRELOAD`, or relinking historical objects would require proving every writer, ABI, global and startup invariant; none is the chosen repair route.

## Rebuild feasibility and dependency evidence

Both running cores match the repository ELF SHA-256 `554e7088b94b98f03f152f394c5e5b1d1ecfd16dacd470889e65dc83c36d2100`, build ID `376e8d04f9075e4e7166403f4f50ea3c2a7d740f`. Ubuntu is 22.04.3 LTS, with kernel 5.15.0-153-generic. The library graph was captured from physical RIGHT's PID 974; both core executable hashes were verified, rather than assuming their complete process mappings were identical.

The core directly declares seven libraries:

| Library | Evidence of interface | Treatment in replacement |
|---|---|---|
| `libruckig.so` | 10 Ruckig imports: braking and position/velocity profile calculations | Reuse pinned 0.9.2 math; replace ownership around it |
| `libdrake.so` | 44 Drake imports including plant, transforms, IpoptSolver and Solve | Keep IK/collision planning above the low-level daemon; preserve necessary API behavior through an explicit gateway contract |
| `libdrake_lcm.so` | `lcm_create`, `lcm_destroy`, `lcm_handle`, `lcm_publish`, `lcm_subscribe` | Remove competing command ingress; optional read-only telemetry compatibility |
| `libstdc++.so.6` | C++ runtime, thread construction/join/detach, containers | Keep normal runtime, eliminate per-target worker construction |
| `libm.so.6` | Math imports such as sin/cos/exp | Keep compiler-resolved math runtime |
| `libgcc_s.so.1` | Unwind support | Keep reproducible toolchain runtime |
| `libc.so.6` | Socket/system I/O and C runtime | Bounded I/O with explicit error/deadline handling |

The live graph contains the core plus 42 mapped shared objects (including the loader), 141 declared dependency edges and 235 undefined core symbols. Drake brings Mosek, TBB, BLAS/LAPACK, MUMPS, OpenGL/X11 and support libraries transitively. A mapped library, or a basename-matched export candidate, does not prove that a command exercised that function or which library the loader actually bound. In particular, no direct core Mosek dependency or core-specific Mosek import was found.

The expanded filename search covered 78,325 files under the documented live roots, and the content scan examined 30,572 readable C/C++ files. No matching vendor wrappers were found. Host-only `dual_b1.zip` and examined URDF archives contain model assets, not source. `/root`, service-private temporary directories, excluded private/cache directories and symlink targets were not exhaustively searched. This is a scoped negative result, not proof source exists nowhere.

Historical object files reference `/home/amber/amber_core_dev_O` and older link inputs, including a different Ruckig location; they are not a reproducible build of this ELF. A vendor-source route becomes preferable if the exact revision, all wrappers/generated schemas, CMake/link inputs, dependency versions and protocol/firmware contracts can be obtained. First reproduce a baseline in isolated Ubuntu without robot access, then change worker ownership at source level. No vendor contact has been sent.

## Proposed executable boundary

```text
Cerebro: clutched/fresh pose -> seeded continuous IK -> full robot/world guard
   -> authenticated gateway: physical arm + generation + sequence + target lease
   -> one-slot latest target -> persistent q/v/a owner (one per arm)
   -> deadline-aware exclusive transport adapter -> pure Amber wire codec
   -> SocketCAN -> existing slcand / USB CAN -> unchanged actuator firmware
          ^ per-joint measured frames and receive timestamps return separately
```

The model/world admission must cover the complete remaining trajectory and stopping envelope, both arms, tools, payload, neck, torso and environment. Vendor URDFs contain a base and seven arm links; their +/-2.09 rad limits and very large velocity/effort entries are not commissioned physical ratings. Cerebro's larger model also contains placeholder dynamics. Model editing alone cannot repair the command-4 ownership race. Preserve native references and investigate calibrated frame/sign/offset mismatches rather than guessing zeros or axes.

One owner starts from fresh, proven stationary measured state and maintains coherent **commanded** q/v/a. Ingress updates a latest-target slot; it does not queue trajectories. Stop and generation validation share the publication transaction. Distinguish commanded state, quantized wire targets and actual measured state; never differentiate wire quantization into a new commanded acceleration seed.

The future adapter must validate every joint's receive age and raw fault/status semantics, map timestamps to a monotonic domain, reject replay/foreign generation/expired authority, and constrain every output to commissioned joint and dynamic limits. A cached LCM ArmStatus publication is not new motor feedback. The diagnostic decoder does not manufacture stationary proof, valid mode, authority or physical velocity/current units.

The seven-frame codec result is atomic only in memory. Actual CAN frames transmit sequentially. A partial send, queue overrun, late write or ambiguous syscall result must latch a transport fault with the accepted-frame history, without replaying a possibly accepted batch. Plan deadline/backpressure accounting and independently verified drive response to that failure.

## Motor protocol and transport findings

The position sender at 0x394d8 multiplies native degrees by configured direction and 128, truncates toward zero, adds 65535 to negative integer counts, then sends high byte first. Joint j=1..7 uses CAN ID 0x10+j, DLC 3 and payload `[0x40, high, low]`. The integer negativity test occurs after truncation, so a negative sub-count value encodes zero. This is not normal two's-complement encoding.

The feedback decoder at 0x38d99 uses bytes 1..2 for position /128, bytes 3..4 for raw velocity, bytes 5..6 for current /256, and byte 7 for raw status. Its signed conversion is `raw > 32768 ? raw - 65535 : raw`. Thus `0x8000` becomes +32768 and `0xffff` becomes zero. Physical velocity/current units remain unverified. The arm codec accepts only standard IDs 0x91..0x97 and DLC 8; gripper node 8 and flagged/foreign frames are excluded.

Independent review found a dangerous encoding boundary: count -32767 becomes word 0x8000, whose legacy decode changes sign. The replacement must reject that count as well as -32768, and validate that every accepted encoded word decodes back to the intended count. The unambiguous accepted integer domain is [-32766, 32767], subject to stricter commissioned joint bounds. This is a representation restriction, not a joint-angle operating range.

The original sender opens/binds/writes/closes a raw CAN socket per joint frame. It reports the same return value on its observed success/error paths, while its caller ignores the result. The timer-driven send loop has no observed lease, feedback-age or mode predicate. The live interfaces use `slcand`: ACM1 -> can10, ACM0 -> can11, with transmit queue length 1000. At the captured snapshot, kernel RX counters were zero while TX counters were nonzero. These are transport counters, not actuator acknowledgement, power state or pose evidence.

Physical RIGHT is vendor L-10 / can10 / Left_ / UDP26001. Physical LEFT is vendor R-11 / can11 / Right_ / UDP26002. Preserve explicit routing; do not infer physical arm from a vendor label.

## Ownership, startup and stop requirements

The production process must be the sole motor writer. Remove the old rc.local launches and recovery/manual launch paths during a supported, inactive cutover. Validate service exclusions and an OS-level isolation/permission mechanism that prevents unmodified legacy processes from opening the same motor interfaces. SocketCAN allows multiple sockets; a cooperative lock or successful bind is not enforcement. A private namespace is one candidate to validate with this serial-CAN transport, not an already-implemented guarantee.

Default startup sends no motor command. Fresh inactive/supported conditions and an explicit new stationary generation are required before output. Do not auto-enter position mode, reset encoders, replay a saved target, substitute zero derivatives or take over an active hold.

When the process is alive and feedback remains trustworthy, target expiry or Stop produces a bounded, reviewed brake from coherent commanded q/v/a and latches the session. Unknown feedback, tracking failure, missed timing or uncertain output is a fault, not permission to guess the physical state. The current gateway `_perform_backstop_hold` sends UDP command 4, so it is not an independent drive-side watchdog.

When the process, bus or power fails, safe behavior depends on an independent motor/firmware/hardware contract that has not been established. Torque-off can drop a gravity-loaded arm, and documented vendor mode changes may momentarily remove power. Firmware command timeout, target retention, mode transitions, status bits and independent Stop must be established on supported hardware before commissioning. No software Held/Fault state proves a physical hold.

## Offline deliverables and next gates

`Tools/ContinuousArm` supplies the persistent owner and pure `AmberWireCodec`, with no socket, activation, mode, gripper, calibration, daemon or installer. The codec preserves observed byte conventions, explicit arm/sign mapping, caller-supplied finite bounds and an all-or-nothing in-memory batch. It checks the quantized output against bounds as well as the requested floating-point target. The tests use synthetic, explicitly ideal feedback, not actuator recordings.

The source-hashed Release, ASan/UBSan and TSan reports under `evidence/2026-11-02-amber-codec` are the authority for final test counts. Existing planner tests cover continuous moving retargets, mailbox races, Stop/publication serialization, stale feedback, tracking faults and analytical brake envelopes. New codec tests include independent golden frames, malformed IDs/DLC/flags, signed endpoints, full-domain round trips, quantization bounds and owner-to-recorded-output integration. The latter records 42,000 frames from 6,000 ticks with 1,358 moving retargets, max position quantization error 0.000136344 rad and max wire step 0.00163625 rad. These synthetic metrics do not establish physical smoothness, timing or motor tracking.

Next, build the host adapter against a fake transport and isolated Linux virtual CAN. Exercise partial writes, queue delays, bus errors, late timestamps, wrong-arm frames, missing joints, restart/replay, double-writer startup and process stalls. Use an isolated Ubuntu VM without USB passthrough or robot LAN access for any original-binary differential experiment. Virtual CAN cannot establish physical timing, torque, gravity or firmware watchdog behavior.

After neck repair and explicit resume: supported bench/actuator verification; independent Stop and firmware timeout; measured per-joint limits/units; one empty arm at low bounds; physical collision/model calibration; then paired arms and continuous VR input. No standalone daemon should advertise streaming capability before those gates pass.

## Backup and rollback

A private allowlisted archive was read directly from Amber and verified file by file: both cores, all 42 mapped libraries, both launch configurations, gateway script and rc.local (48 members). Its manifest and archive hash are recorded in `evidence/2026-11-02-amber-protocol/backup-manifest.json`; the 43,686,735-byte archive remains outside Git in local ROB Test Reports. No credential files or histories were copied.

This is a controller baseline backup, not a full OS image or tested boot restore. The available Amber-HomeFolder repository is a home-folder/system-file snapshot. Preserve filesystem permissions/symlinks, package versions, service/boot configuration and model assets in a separately validated full-system backup before installation. Actuator EEPROM and calibration reside beyond this host archive and need their own documented recovery procedure. Roll back only with arms supported/inactive and pending commands cleared; never restart an old controller into a raised or loaded hold.

## Evidence

- [Live identity, startup, source inventory and full library graph](evidence/2026-11-02-amber-executable/manifest.json)
- [Wire disassembly, host transport snapshots and verified backup manifest](evidence/2026-11-02-amber-protocol/manifest.json)
- [Offline owner and wire test reports](evidence/2026-11-02-amber-codec/release.json)
- [Prior controller and URDF investigation](arm-transition-review-2026-10-31.md)
- [Implementation record](continuous-arm-retargeting-2026-11-01.md)
- [Linux SocketCAN documentation](https://docs.kernel.org/networking/can.html)
- [Pinned Ruckig 0.9.2 source](https://github.com/pantor/ruckig/tree/v0.9.2)
- [Vendor arm API](https://github.com/MrAsana/Robotic_arm_api)

The graphical PDF and private original backup live outside Git under `~/Documents/ROB Test Reports/2026-11-02/`. Neither report nor passing simulations certify hardware readiness.
