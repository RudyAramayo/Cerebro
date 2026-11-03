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

## 2026-11-02 executable feasibility follow-up

Rudy resumed software investigation and requested a deep comparison of rebuilding
the vendor executable with replacing its controller. No adapter, motor command,
installation or restart was performed in this follow-up. The trajectory library
above remains an offline component, not a deployable replacement driver.

The [identity and startup evidence](evidence/2026-11-02-amber-executable/identity-and-startup.json)
binds the analysis to both running executables and the three matching archived
copies: SHA-256 `554e7088b94b98f03f152f394c5e5b1d1ecfd16dacd470889e65dc83c36d2100`,
ELF build ID `376e8d04f9075e4e7166403f4f50ea3c2a7d740f`.

`main` constructs ten threads in the straight-line range `0x12ee0..0x12ff1`,
including Ruckig, RosInterface, UDP, the solver and the CAN sender. The first
`join()` is at `0x13000`. Subsequent enable checks only guard joins; the earlier
UDP-enable check only guards a print. They do not provide a driver-only mode.
RosInterface starts its publisher and direct-position listener unconditionally;
the listener copies seven doubles into `directControl::jointPositionTarget`,
the same array used by Ruckig. Sending the new owner's output through that
existing listener would leave competing writers. Linked `Controller::spin` and
`Planner::spin` symbols have no startup reference identified in this audit;
their presence alone is not evidence of a running PosPlan pipeline.

The [backup inventory](evidence/2026-11-02-amber-executable/source-inventory.json)
examined the current home-folder repository and its complete reachable history.
It contains the matching binaries, URDFs and historical build records, but no
matching project source or disk-image path was found. This does not establish
that a separate Ubuntu image or vendor source is absent elsewhere. Historical
link records refer to `/home/amber/amber_core_dev_O` and a different Ruckig
library path. The live process maps Ruckig 0.9.2 from ROS Humble. These records
support rollback/reference and dependency reconstruction, not a verified source
rebuild. Changing a URDF or replacing `libruckig.so` cannot remove ownership
and worker races compiled into the executable.

Direct Ubuntu inspection extended the search beyond the backup: 78,325 files
across the readable home, opt, source, mounted-volume and temporary trees yielded
no named controller source. A content search of 30,572 readable C/C++ files for
the controller's distinctive identifiers also found none. The large host-only
`dual_b1.zip` and examined URDF archives contain URDF/STL assets, not controller
source. `/root`, private service temporary directories, excluded private/cache
directories and symlink destinations were not searched. The exact scopes and
limitations are recorded in
[host-source-search.json](evidence/2026-11-02-amber-executable/host-source-search.json)
and [the content/archive inventory](evidence/2026-11-02-amber-executable/host-source-content-and-archives.json).

The [live dependency graph](evidence/2026-11-02-amber-executable/shared-libraries-and-imports.json)
records the core plus 42 mapped libraries, their hashes/build IDs, 141 declared
`DT_NEEDED` edges and 235 undefined core dynamic symbols. The core directly
requires Drake, Ruckig, Drake's LCM library and the C/C++ runtimes. It imports ten
Ruckig-specific functions, 44 Drake-specific functions and five LCM functions.
Drake's transitive dependencies include its marker library, TBB, Mosek and other
math/graphics libraries. Being mapped does not prove a solver backend ran; symbol
export candidates do not establish live binding or actual function use. The
replacement boundary is the executable's ownership, ingress and motor-facing
driver code, not the motor firmware or an assumed third-party `.so` patch.

A maintainable rebuild requires the matching source and an isolated baseline
build before replacing every target writer with one owner. Without that source,
a separate controller must replace the vendor executable's motor-facing role
completely and establish CAN encoding, feedback, mode/startup, error handling,
exclusive ownership, Stop and independent watchdog behavior. Neither approach
is ready for installation. Preserve the legacy completion guard until that
integration and physical validation are complete.

## 2026-11-02 offline packet implementation

`Tools/ContinuousArm/AmberWireCodec` now implements the audited position packet
format and a diagnostic joint-feedback decoder without any transport or mode
commands. The [component contract](../../Tools/ContinuousArm/README.md#inert-amber-wire-compatibility-component-2026-11-02)
records physical-side mapping, one SI conversion, the vendor's unusual signed
word convention and explicit finite/range/whole-batch rejection. Both requested
and quantized output positions must satisfy caller-provided bounds. Raw feedback
velocity/current values are not labelled with unverified physical units.

Eight new regression groups cover golden byte values and boundaries, malformed
packets, all-or-nothing rejection, 420,014 quantized joint roundtrips plus
917,476 exhaustive signed-domain roundtrips, output
failure propagation and the owner feeding recorded frames with ideal 20 Hz
quantized feedback. The 30-second simulation records 42,000 frames at 200 Hz,
including 1,358 moving retargets. Its error stays below one 1/128-degree count.
These are software compatibility results, not live motor measurements. No
adapter daemon, exclusive hardware ownership, startup proof or independent
watchdog has been built or enabled. The commissioning prerequisites above remain.

Independent review caught the legacy encoder's asymmetric endpoint: negative
-32767 plus 65535 becomes `0x8000`, which the decoder treats as positive 32768.
The codec now permits only quantized counts -32766..32767 and verifies that the
encoded word decodes to the same count. Full-domain tests cover this beyond the
initial +/-15000-count sweep. This correction was made offline before any
transport or physical test; the intermediate source commit is not a deployment.

## 2026-11-02 offline driver-boundary implementation

The new [ArmDriverBoundary](../../Tools/ContinuousArm/ArmDriverBoundary.cpp)
adds a fake-transport adapter between the persistent owner and inert codec.
Its [contract](../../Tools/ContinuousArm/README.md#offline-driver-boundary-2026-11-02)
separates raw diagnostic decoding from an explicit simulated mode-admission
policy. It requires per-joint fresh observations, receiver-owned epochs and
timestamps, an external stationary-start grant, a new owner generation and a
bounded writer lease. It does not connect to the robot or issue mode commands.
One injected monotonic clock is sampled inside the publication lock; a queued
receive keeps its earlier receive timestamp without causing a false clock fault
merely because another thread finished a write before it acquired the lock.

The boundary validates the whole seven-frame batch before output, serializes
publication with receive/revocation, and checks a shared deadline around each
fake write. It records the accepted/attempted prefix when a write is rejected,
uncertain, late or throws. The first failure stays latched, no retry is issued,
and all stationary history is cleared. Good feedback arriving after a transient
bad mode/tag/position, stale interval or expired lease cannot silently rearm the
old writer between controller ticks. A new stationary history and explicit new
generation/grant are required.

Eleven new groups exercise these boundaries, including 35 injected failures
across all seven output positions and concurrent receive/revocation. The
integrated owner/boundary simulation records 8,127 frames over 1,161 ticks with
100 targets, 20 Hz ideal feedback, lease renewal and controlled Stop. Together
with the prior owner/codec suites there are 38 groups, plus the legacy fixture.
All passed in Release, Address/Undefined Behavior Sanitizer and Thread Sanitizer
builds against pinned Ruckig 0.9.2; the recorded source hashes were rechecked.
Results and exact source hashes are in
[`evidence/2026-11-02-arm-driver-boundary`](evidence/2026-11-02-arm-driver-boundary).

This implements the offline admission/publication layer, not physical driver
exclusivity or watchdogs. A mutex covers one shared instance only; a callback
deadline cannot interrupt blocked I/O. Quantized quiet-position samples do not
prove physical stationarity, and transport acceptance is not motor receipt.
No sockets, backend, service, mode changes, install or restart were added. The
remaining exclusive backend, commissioned feedback/mode/current interpretation,
physical limits, collision calibration, watchdog and supervised tests are still
required before live continuous control. The 14-page report Rudy manually sent
to The God Squad at 22:20 documents the preceding 27-group owner/codec phase; these later
boundary results are recorded here rather than attributed to that PDF.

## Linux commissioning release, 2026-11-03

The subsequent source-controlled implementation now includes the integer-nanosecond
receive clock, bounded native SocketCAN backend, trusted session lifecycle and a
Linux executable. Source `039b722ad869d2fb04d57c4fb1c1f92e58a77897` passes all
71 distinct groups in both Linux Release and ASan/UBSan:
53 portable, eight native transport and ten executable/IPC groups. Local
Release/ASan/UBSan/TSan cover the 53 portable groups. The final
[CI run](https://github.com/RudyAramayo/Cerebro/actions/runs/41600422377),
[source-bound reports](evidence/2026-11-03-amber-runtime/) and
[package/deployment contract](../../Tools/ContinuousArm/DEPLOYMENT.md) are the
current evidence; the preceding sections preserve the earlier milestones.

Session clients carry exact generation tokens and original creation times.
Disconnect, Stop and client expiry remove client control while a bounded
internal writer lease can finish an admissible brake. Every candidate's stopping
reserve must fit the grant, including a check after the external world guard
returns. A final planning-age check prevents late calculations from producing
new output. External faults revoke both owner and boundary with no output;
new history and a new explicit grant are required for rearm. A timeout is Fault,
not a claim of physical hold. Native frame acceptance remains distinct from
motor acknowledgement, with no retry after uncertain or partial publication.

The executable has no physical transmit mode. Physical observation records
per-joint raw frame/native counts and conservative kernel receipt age without
manufacturing calibration, mode validity or stationary authority. Its active
test mode requires kernel-verified virtual CAN, an explicit isolated fixture,
a private UID-checked local socket and a new connection nonce. Packet size,
batching, sequence, generation, original age and schema are bounded; duplicate
keys are malformed. It never exposes mode, gripper or calibration commands.

End-to-end tests verify the exact intended stop reason, rather than merely
observing that output ended. Initial CI failures exposed a simulator filter
that accidentally subscribed to error frames and a test grant that entered
automatic braking before explicit Stop. The filter and test horizon were
corrected, the controller guards were preserved, and final tests require
ClientDisconnected, Stop, Shutdown or Feedback for the respective scenario.

The archive's exact tested executable SHA-256 is
`364e6e1707d541d5d1e55ea6dbc5ce089151323050fd3408db18129150017fc5`;
the archive SHA-256 is
`d74696ec4e4be361d74e0aed41ecf98c3ddf1d7499b67c9fb82a8dcbb59d06fa`.
The package contains its licenses, source/test manifests and an inactive passive
service example. Staging runs only on the disposable hosted runner and performs
no robot install, restart or connection. The observed Amber ABI is Ubuntu
22.04.3 / x86_64 / glibc 2.35. Exact dynamic dependencies and required symbol
versions are recorded, separate from physical CAN/kernel commissioning.

Physical continuous control remains uncommissioned. Preserve the command-4
measured-completion guard. Before enabling a future physical backend, complete
the full robot/world/other-arm collision guard, native signs/zeros and real
joint limits, verified real slcan exclusion/drain, serial/sample-age bounds,
independent motor watchdog and coordinated supported/no-load tests. The world
model includes tread approach and torso alignment to the table; a static
arm-on-table model and placeholder URDF limits cannot supply these constraints.
There is no automatic morning activation or old-target replay.

## Primary implementation references

- [Pinned Ruckig 0.9.2 profile implementation](https://github.com/pantor/ruckig/blob/7de6b1035e1cad509251b31b3287d10fbcda6baf/include/ruckig/profile.hpp)
- [Pinned Ruckig 0.9.2 online update and coherent state handling](https://github.com/pantor/ruckig/blob/7de6b1035e1cad509251b31b3287d10fbcda6baf/include/ruckig/ruckig.hpp)
- [Ruckig official tutorial](https://docs.ruckig.com/tutorial.html) describes
  online state updates and `pass_to_input`; it is newer than the installed
  version, so the compiled tests use the exact pinned source above.
