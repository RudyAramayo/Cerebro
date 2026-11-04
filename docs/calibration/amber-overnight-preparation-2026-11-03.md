# Amber overnight preparation, November 3

Rudy authorized deployment and prerequisites for the detached-worker fix, then
said he was going to bed and would reconvene in the morning. Continue development
and inactive staging. Do not activate motors, change modes, restart cores or
Cerebro, move/reset CAN, or automatically resume a saved motion. The camera/head
mount is unfinished; Rudy explicitly permits later arm tests without it.

## Recovery plan and read-only verification, November 4

Rudy requested a traceable PDF and a backup plan before starting the takeover.
The eight-page fillable plan covers current readiness, whole-disk recovery,
exclusive CAN handoff, rollback, stop commissioning and an execution log. All
12 execution gates remain Pending. The staged executable still cannot transmit
to physical motors; the protected takeover is not installed or commissioned.

Fresh read-only checks identify a 64,023,257,088-byte HOGE SSD with separate EFI,
boot and LVM/root partitions. The existing 43,686,735-byte controller archive
has 48 payload files; every payload hash was rechecked. It is not a full disk
image or a demonstrated boot restore. A new local archive captures seven
readable startup/recovery files with hashes and original ownership/mode metadata.
At PDF creation, the live sudoers file was unreadable without authenticated
sudo, so that initial seven-file archive is explicitly partial.
The original core and rc.local hashes still match the prior baseline.

**Follow-up at 17:51 UTC:** Rudy asked to use the existing login password for
sudo and copy the protected policy. The SSH password already saved in the
Cerebro Keychain authenticated sudo successfully. A single read-only root
command copied `/etc/sudoers`, the complete `/etc/sudoers.d` tree and all source
paths reported by `visudo -c`; no persistent `su` shell was needed. The three
regular files are sudoers, the directory README and `rob-amber-recovery`.
All three payload hashes and their numeric ownership/mode metadata verify
locally; extended attributes are recorded in the private manifest. Existing
sudoers syntax validates successfully. The password was neither printed nor
written to backup files, and no source policy was modified.

The 2,320-byte supplemental archive is
`amber-sudoers-baseline-20261104T175132Z.tar.gz` in the private backup-review
directory below, with SHA-256
`9b2c27411331a845af1c221c9b36deea0c3c23d1277a0b2c8e717eb6db7a6ce0`.
Both archive and manifest are owner-only (`0600`). This closes the PDF revision
1 protected-file gap; that PDF and its original evidence remain an unchanged
snapshot. It does not complete a full disk image, full system-state inventory
or restore test. No motor, service, startup or CAN operation was performed.

The preferred next maintenance procedure is to image the entire unmounted
original disk, verify an independent second image copy, restore onto an
identified compatible spare and prove that spare boots with motor power off
and CAN disconnected. Develop on the clone and keep the original SSD labelled
and disconnected. Preserve UEFI settings separately; a host image does not
back up actuator EEPROM. Physical media selection, offline imaging, restoration
and boot testing have not been performed.

The report generator is `Scripts/build-amber-takeover-plan.py`. Private source
evidence and backups are under `Documents/ROB Test Reports/2026-11-04/amber-backup-review`;
the finalized PDF and its manifest are under that date's `output/pdf` directory.
[Sanitized report and backup evidence](evidence/2026-11-04-amber-recovery-plan/)
records the hashes and PDF checks. All eight rendered pages were visually
inspected; 41 canonical form fields match 41 widgets with appearance streams,
and a disposable fill/save/reopen check passed without changing the original.
No new controller test results are implied by this report-only change.

No reboot, disk restore, protected install, service/core restart, CAN reset or
namespace move, mode change or motor command occurred. Messages native access
still fails with `Sky Computer Use native pipe startup failed`; no group delivery
or inbox check is claimed. The PDF is delivered in chat, not claimed as a Messages
attachment. Physical testing remains paused until Rudy resumes it.

## Two spare masters and likely V1/X-hub arms, November 4

Rudy has two additional Ubuntu master boxes with two older arms. He believes
they are the first B1/X-hub generation. One spare loses power when its cord moves;
the other is the preferred bootable clone/development host. Both are in storage,
so neither has been inspected or reached over SSH. Keep the unstable-power box
out of the recovery chain until the fault is repaired and verified. Rudy prefers
moving the extra arms to USB-CAN, with the investigation and software work handled
here rather than making him reverse engineer the hardware.

Rudy subsequently reports that the arm wiring is the same: two wires emerge
from J1, and both generations use the same four-wire CAN plugs. He identifies
the visible difference at the controller connection: an RJ-style/telephone-like
plug on the current USB-CAN adapters versus the CAN plug on the old X-hub. The
exact RJ connector type and pin count are not yet identified. This makes a common
motor-side CAN bus with different bridge/cable packaging a useful working
hypothesis. The Ethernet-side transport does not exclude CAN on the arm side.
Prioritize verifying that hypothesis and preparing a documented adapter cable;
do not presume that the arms need different actuator electronics. Matching
connectors still do not establish supply pins, polarity, voltage, bitrate,
motor protocol or joint/profile compatibility. Do not label the two J1 wires
as power or data without identification.

The follow-up read-only `/proc` and USB-sysfs inspection found two adapters
advertising Openlight Labs CANable2 `b158aa7`, VID/PID `16d0:117e`. Both active
slcand command lines use `-s8`: ttyACM1 -> can10 and ttyACM0 -> can11. The pinned
[firmware command reference](https://github.com/normaldotcom/canable2-fw/blob/b158aa7ab106bc018715cd4d5f02f544f9de1830/README.md)
defines S8 as 1 Mbit/s. This establishes the configured high-speed CAN rate;
it is not a fresh bus waveform measurement or verification of the spare arms.
No CAN or serial command was sent for this observation.

Rudy recalls a jumper labelled for CAN_H/CAN_L. Its physical function remains
unidentified. The [CANable guide](https://www.canable.io/getting-started.html)
describes termination and bootloader controls. Other CANable-compatible RJ45
boards such as [CANchovy](https://github.com/fred314159265/CANchovy) have separate
solder jumpers that route CAN_H, CAN_L and reference ground to connector pins.
These are examples, not identification of Rudy's board. Keep the working jumper
positions unchanged until the exact board and labels are inspected. CAN_H and
CAN_L are used together; neither a termination jumper nor a bootloader control
selects one of those bus wires. Termination is also separate from high-speed
versus low-speed CAN and from a motor Stop command.

The vendor documentation distinguishes the V1/X-hub system from V2/Mini-Hub.
The [V1 wiring guide](https://github.com/MrAsana/AMBER_B1_ROS2/wiki/AMBER-B1%E2%80%90%E2%80%90V1-version-hardware--quickstart)
and its diagrams show Master LAN2 connected to the X-hub, with a separate
six-pin arm cable and power circuit. This does not establish that cable's signal
pinout. The pinned [V1 launcher](https://github.com/MrAsana/AMBER_B1_ROS2/blob/407451125c2adb2dbac8a9c823b54f7cfee4a71a/Scripts/b1.sh)
starts `amber_b1_hw_gui_ethercat.launch.py`. An EtherCAT-related transport is
therefore a source-based inference, not verified identification of these spare
units or the X-hub's internal motor bus. The
[V2 initializer](https://github.com/MrAsana/AMBER_B1_Robotic_Arm_V2/blob/2b8c6ce97fd7b662d99aac048c607756481150a3/scripts/initCAN.sh)
instead uses ttyACM/SLCAN. A generic USB-CAN adapter is not yet an established
replacement for a V1 X-hub. CAN_H/CAN_L are differential bus connections, not
selectable pin modes that translate Ethernet/EtherCAT into CAN.

There are concrete single-instance assumptions in the old software: the V1
launcher kills processes matching `ros` and starts its web backend on port 8080;
the [vendor Python status example](https://github.com/MrAsana/Python_API/blob/6d65f6086a504fcd6dc894230a85330483ca75f0/cmd_01_get_status.py)
binds local UDP 12321 and sends to one master IP on UDP 25001. These are candidates
for multi-arm isolation work, not proof of the cause of Rudy's earlier failures.
The example also declares length 44 for an eight-byte status request, whereas
the [protocol](https://github.com/MrAsana/UDP-Protocol-API/wiki/Robotic-Arm-API-based-on-UDP-Protocol)
specifies eight. No downloaded script was executed. Do not assume the V1 binary
has the same detached-worker implementation until its actual code is examined.

The revised sequence is to preserve the stable spare's original V1 disk/software,
then capture the current Amber's entire offline boot disk and restore a verified
copy onto a distinct, identified destination SSD for the stable spare. A backup
image stored on that box is useful but does not itself make the box a bootable
clone. Keep a separate immutable image copy and the original disk; the working
development clone is not the sole backup. Before joining it to the same LAN,
review hostname, network/machine identity, credentials and disabled controller
startup. Motor links remain disconnected during boot validation. The current
Mac has approximately 28 GiB available, below the conservative 70 GB raw-image
budget; check real destination capacity or use separate storage before imaging.
The existing 64,023,257,088-byte source disk must fit the chosen restore target.

Once accessible, inventory the spare's OS, disk and boot mode, NICs, original ROS
workspace, launch/configuration files and exact driver/binary dependencies without
starting the vendor launcher. Determine its actual link protocol from source,
configuration and a controlled passive capture before any adapter purchase or
rewiring. Passive electrical identification, if needed, requires identified pins
and appropriate instruments; do not attach a USB-CAN adapter to guessed pins.
If CAN is established, select a documented Linux/SocketCAN adapter with suitable
physical layer, bitrate, isolation, termination and bounded/error-visible queues.
Keep each arm on an independent bus unless IDs and topology have been verified.

The intended software rollout uses the shared persistent trajectory owner,
one owner per arm and one coordinated client layer. Hardware transport, joint
identity, sign/zero, limits, feedback and stopping profiles stay specific to each
arm revision. Fixing current CAN workers does not validate a V1 transport, and
streaming through the old UDP command 4 would retain the legacy worker risk.
Inert candidate staging can be copied, but only a commissioned release may be
enabled for motion on a clone. The candidate remains physically inert; no spare
imaging, installation, CAN or EtherCAT operation, adapter probing or motor command
occurred in this review.

[Source pins and findings](evidence/2026-11-04-amber-spares/)
preserve the investigation. Downloaded vendor diagrams and scripts are stored
privately under `Documents/ROB Test Reports/2026-11-04/amber-spare-box-review`.

## Actual host observations and deployment

**Final inactive release:** source `d98ebd3791b9509249212e2c754f4061f78458f9`,
staged at `/home/amber/rob-controller-staging/d98ebd3`. All nine manifest files
verified remotely. The 355,069-byte archive SHA-256 is
`3628a1d4bc60aeacc40fb9fc3930ebb65419a019f3afe730c5734853fd9a909e`.
Controller SHA-256:
`f023a0f3ece4e6a3a8c9c3ba4c66c2f4b511a16f4865917d8241dc6f860cb73b`.
Rehearsal SHA-256:
`98afe3785ff1d1c40154dbe5fe118e55f7525f69cda465ea6c8afa5c6133f7e7`.

[Linux validation run 41787018510](https://github.com/RudyAramayo/Cerebro/actions/runs/41787018510)
passes Release and ASan/UBSan: 53 existing portable groups, five new rehearsal
groups, seven preflight checks, eight native transport groups and eleven process
groups (84 total). Both executable process runs exercise eleven switches while
moving and twelve velocity reversals, with one thread/generation. The 58 portable
C++ groups also pass local TSan. All reported source hashes and both tested binary
hashes were checked independently. Both ELF dependency closures resolve against
the verified Amber library backup, with no missing strong imports or versions.

On Amber, self-check and all five inert rehearsals pass. `strace -f` with network
syscalls selected records **zero network calls** from the rehearsal. Legacy cores
remain PIDs 974/975, with unchanged original hashes. Background CAN TX counters
advanced during the read-only work; the robot was not a silent bus, and those
counters are not motor acknowledgements. No candidate activation, service install,
namespace move, mode change, motor command or vendor-core restart occurred.

Ownership prerequisite source `7c3b2449936a017c5f7049f6d562764a9fdb3f94` is staged at
`/home/amber/rob-controller-staging/ownership-7c3b244-complete`. All nine files verify
and all 27 offline recovery/initializer tests pass on Ubuntu. The privileged
installed helpers and startup files are unchanged. The first staging bundle
omitted two test fixtures; the complete bundle corrects this and was retested.
Earlier Linux test iterations were also rejected before packaging: a timer could
switch near zero velocity, and an early reversal had insufficient travel. The
final fixture uses observed motion, a finite program and unchanged controller
guards/grant limits. It passes both Linux variants; failed iterations were never
deployed as controllers.

See [sanitized, source-bound evidence](evidence/2026-11-03-amber-overnight/).

Initial observations before the final release:

- Both original core files match SHA-256
  `554e7088b94b98f03f152f394c5e5b1d1ecfd16dacd470889e65dc83c36d2100`.
  The rc.local baseline is
  `2369a9576604b945df2c8bb4913967430ea0d3790eca196102ecdbdc5ebe37b9`.
- Vendor cores and slcand remain running. The old package was extracted into
  `/home/amber/rob-controller-staging/039b722`; all seven manifest files verified.
  `--self-check` passed with physical transmission unavailable.
- Three-second passive observations on each canonical arm interface received
  zero frames and attempted/accepted zero transmissions. All seven joint records
  were null. This establishes neither a current pose nor powered/off state.
- Local Cerebro status returned no RPC socket. No app restart was attempted.
- General unattended sudo is unavailable. The no-argument root recovery helper
  is authorized by sudoers but **must not be used** to obtain privileges or
  refresh telemetry: it restarts the CAN/core stack.
- Rudy reports that the current failure stops motion. This is operator evidence,
  not a measured firmware watchdog timeout or proof about retained torque.
- Messages access fails with `Sky Computer Use native pipe startup failed`.
  Status speech works; group delivery and new God replies cannot be verified.
  Do not work around the separate Finder/Preview app approval denials.

Private full records are under `Documents/ROB Test Reports/2026-11-03/amber-deployment`.
No camera artifacts, credentials or full host logs belong in Git.

## New development

The finite rehearsal links the same `ArmSession`, `ContinuousArmController` and
wire codec as the controller, with only a fake sink and ideal quantized feedback.
It makes a five-degree simulated native-J2 move, then twelve reversals; eleven
target switches occur while moving. Separate runs exercise Stop, disconnect,
shutdown, stale-target braking and feedback loss. The limits are simulation
settings. This does not select a physical lift joint or sign and does not prove
drive stopping. The new Linux process fixture exercises the sequence over the
actual Unix IPC/vcan path and verifies one thread/generation and rejection after
Stop. Status now includes accepted/applied target sequences and replan counters.

The read-only preflight records manifest integrity, unchanged vendor files,
legacy processes, CAN namespace visibility, serial device write access, service
state and the recovery entry point. It can never turn an inventory into motion
authority. A quiet bus or absent process also cannot satisfy its physical gates.

Amber-HomeFolder adds a persistent inhibit at
`/etc/rob-amber-gateway/continuous-controller.block` to recovery, CAN initialization
and rc.local. These are source/staging changes only. The eventual cutover must
hold the existing recovery lock, install/verify protected guards, set the durable
inhibit, prevent legacy service launches and raw serial bypass, and keep CAN in
a pinned namespace. No PID expiry or process crash should clear the inhibit.
Virtual-CAN isolation does not establish real slcan/adapter queue behavior.

### Adapter source identification

The USB product strings advertise CANable2 `b158aa7`. That resolves to public
source commit `b158aa7ab106bc018715cd4d5f02f544f9de1830`; treating it as the installed
source lineage is an inference, not verification of the flashed image.

The header allocates 64 transmit slots; the ring reserves one slot, yielding
63 usable entries. Entries contain CAN headers/data, with no command generation
or expiry field. The transmitter defaults to automatic retransmission and
`can_disable()` does not explicitly reset this software queue. A channel-close
or kernel-link operation therefore has not been established as a complete
old-traffic flush. These are source findings, not observed motor behavior.
[Queue definition](https://github.com/normaldotcom/canable2-fw/blob/b158aa7ab106bc018715cd4d5f02f544f9de1830/inc/can.h),
[transmit/disable implementation](https://github.com/normaldotcom/canable2-fw/blob/b158aa7ab106bc018715cd4d5f02f544f9de1830/src/can.c).

The serial parser discards the return value of `can_tx`, and the README says
serial commands receive no ACK/NACK. Kernel send acceptance is consequently
not evidence of adapter acceptance or motor delivery. No adapter query, reset,
configuration or firmware update was performed; source files and hashes were
saved privately for review.
[Parser](https://github.com/normaldotcom/canable2-fw/blob/b158aa7ab106bc018715cd4d5f02f544f9de1830/src/slcan.c),
[firmware protocol](https://github.com/normaldotcom/canable2-fw/blob/b158aa7ab106bc018715cd4d5f02f544f9de1830/README.md).

## Morning test progression

1. Rudy resumes testing. Check other robot sessions, fresh all-joint feedback,
   the actual empty-arm posture and physical shutdown switch. Begin with RIGHT
   as the proposed arm unless current evidence or Rudy selects LEFT. Physical
   RIGHT is CAN10/L-10; LEFT is CAN11/R-11. Legacy names are misleading.
2. Confirm the native joint/sign that makes a gentle raise from that day's
   measured start. Keep the wrist and other joints unchanged. The five-degree
   rehearsal is a candidate small excursion, not an executable saved pose.
   Review the whole sweep and stop reserve against the actual body, other arm,
   table, floor and people; do not reuse the failed face-strike model as proof.
3. Establish supported-arm mode/status, drive-stop behavior, per-joint bounds,
   current interpretation and bounded transport age. A manual cutoff helps the
   supervised test but cannot be recorded as proof of an automatic watchdog.
4. Perform and verify the coordinated exclusive-driver cutover with arms
   supported/inactive. No active-hold takeover and no automatic rollback into
   the old core. The present release still has no physical transmit mode; these
   observations must inform a commissioned hardware adapter/profile.
5. Give the immediate specific **Start filming now** cue through speech and the
   verified God Squad thread before any movement, after all planning/checks.
   Perform the small raise first, measure Stop, then a finite set of slow target
   changes while moving. Record original timestamps, feedback, commanded PVA,
   current/status, generation/sequence, queue diagnostics and actual outcomes.
6. Keep production UDP-command-4 routes behind measured completion until the
   replacement passes. Never stream the new controller's samples into command 4.

## Face pointing and VR follow-on

Use the same sole owner and latest-target mailbox. Face sensing produces a
timestamped target in a calibrated camera/body frame; continuous IK must start
from coherent current joint state, preserve identity, reject stale/occluded
observations and validate the entire motion/stop. Point toward the face from a
bounded standoff; do not treat a face position as a contact goal. No face-directed
motion until camera mounting, transform and pointing direction are checked.

VR input follows through a clutch/deadman, explicit session generation, original
sample age, bounded rates and the same IK/path guards. Releasing the clutch,
disconnecting or losing fresh tracking requests a controlled stop; reattachment
does not replay buffered poses. No independent VR or face controller may open
CAN or acquire a second trajectory worker. Neither live integration is claimed
ready before the sensors, mapping and physical adapter are commissioned.
