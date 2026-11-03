# Amber controller commissioning package

This is a **passive commissioning and isolated virtual-arm release**. It fixes
the source-level ownership and command-handoff design and provides a tested
Linux executable. It does not enable physical continuous control. The robot's
installed vendor cores and Cerebro completion guard remain in service. No
installer, automatic restart, mode command, gripper command or physical transmit
switch is included. A client JSON field cannot change this restriction.

## Artifact and verification

The package targets ELF64 x86_64 on Ubuntu 22.04, matching Amber's read-only OS
inventory (Ubuntu 22.04.3, glibc 2.35). `manifest.json` records the exact source,
binary hashes, ELF dependencies, required symbol versions, licenses and test
reports. Ruckig 0.9.2 is built from commit
`7de6b1035e1cad509251b31b3287d10fbcda6baf`. The JSON parser is the accompanying
MIT-licensed nlohmann 3.10.5 header. The package script requires successful
source-matched Release, native transport and process tests and refuses sanitizer
binaries. Full host library compatibility still requires checking the listed
symbol versions against Amber's installed runtimes before an authorized run.

`rob-amber-controller --self-check` opens no devices. No arguments prints help.
Only an explicit `--observe --arm right|left --duration 10` opens the selected
canonical CAN receive socket. It cannot start a motion session and cannot send
frames. It records kernel timestamp/queue errors, accepted receive counts and
final status. Its `commanded_*` arrays describe the motion owner, never measured
pose; passive mode has no motion owner or inferred stationary authority.

Prepare a separate staging directory, retain the manifest and verify every
hash before any later copy. Do not overwrite `/home/amber/L-10`, `/home/amber/R-11`,
vendor configuration, motor firmware or `/opt/ros` libraries. The service example
has no enable target, uses `Restart=no`, and requires an absent condition file.
It is not an installation script. Stopping or removing this passive candidate
needs no vendor restart. A failed future cutover must leave all motion inactive;
do not automatically revive the old core or replay a prior target.

## Local virtual control protocol

The active fixture requires `ROB_ISOLATED_VCAN_TEST=1`,
`--virtual-fixture --interface VCAN --runtime-dir NEW_ABSOLUTE_DIRECTORY`.
The kernel must identify the device as **vcan** before transmission is possible.
The executable creates a new 0700 directory and a nonblocking Unix
`SOCK_SEQPACKET` endpoint named `control.sock`. It never replaces an existing
directory. Peer credentials must match the process UID. Only one client is
connected at a time. Each connection receives a fresh random 128-bit nonce;
each admitted start receives a new controller generation. These are local
fixture grants, not real robot authorization.

Each packet is one JSON object smaller than 2048 bytes, with exact fields:

| Operation | Required fields |
|---|---|
| `start` | `op`, `nonce`, `generation: 0`, `created_ns` |
| `target` | `op`, `nonce`, granted `generation`, `created_ns`, increasing `sequence`, seven-radian `position` array |
| `heartbeat` / `stop` | `op`, `nonce`, granted `generation`, `created_ns` |

`created_ns` is the creation time on this Linux host's `CLOCK_MONOTONIC`, not
wall time or a headset clock. Age is checked as integer nanoseconds before
conversion. A future headset bridge must preserve or conservatively map the
original pose age across clock/connection changes; it must not stamp buffered
poses as new at dequeue. Duplicate keys, unknown fields, invalid schema,
oversized packets and nonce failures disconnect the client. Replayed sequences,
stale times and wrong generations are rejected. Input batches are bounded;
backpressure or backlog closes the connection and requests a controlled stop.
Heartbeat keeps client presence fresh, not the target pose.

Responses identify `accepted` as admission into the latest-target slot. It is
not a motor acknowledgement or completed movement. Both backend kernel-accepted
and boundary-reported frame counts are retained. No write is retried. After
disconnect or Stop, client authority is gone while the internal bounded writer
lease completes an admissible brake. Fault is distinct from Held. SIGINT/SIGTERM
request bounded shutdown; SIGKILL, scheduling failure, bus loss and queued
actuator traffic cannot be made safe by a userspace process alone.

## Physical commissioning prerequisites

Keep physical testing paused during the neck-mount repair and coordinate the
runtime handoff with the pouring and other robot sessions. No automatic morning
resume is authorized. Before enabling a future physical backend, establish:

1. Verified native joint signs/zeros, ratings, velocity/acceleration/jerk limits,
   mode/status meaning and a stationary-start procedure. The current values are
   simulation limits; vendor URDF velocity `1000000` is not a motor rating.
2. Full robot geometry and measured registration: both arms, open jaws, payload,
   body/head, torso rotation, tread/base approach to the table, table and floor.
   Evaluate every remaining trajectory and stop reserve against fresh observed
   space and other-arm state. The fixture's synthetic joint cage is not that
   world guard. Replacing the vendor URDF alone cannot fix the detached-worker
   race because UDP command 4 bypasses Drake/URDF planning.
3. Exclusive physical driver ownership and drained/rejected old traffic. CI
   verifies old/new socket exclusion after moving **vcan** into a namespace;
   the real slcan interface and old vendor process must be checked separately.
4. Bounded serial/adapter delay and an independently verified motor timeout or
   watchdog stop. Kernel receipt timestamps do not establish the motor sample's
   age, and the audited slcan baseline does not prove physical bus-off reporting.
5. A coordinated supported/no-load commissioning sequence: passive observation,
   one bounded joint motion, measured Stop, small mid-motion retargets, lost
   client/feedback cases, then clutched Vision Pro control with seeded continuous
   IK. Retain measured completion for legacy command-4 routes until this passes.

The source solution removes competing trajectory workers and incoherent
derivative handoffs. Passing simulation does not establish the historical
internal cause of every reversal or certify a physical recovery path. Report
actual observations during the supervised test; do not widen constraints,
change encoder zeros or substitute a flat-table model to get a path admitted.
