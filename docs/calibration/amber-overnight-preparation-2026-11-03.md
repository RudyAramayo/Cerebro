# Amber overnight preparation, November 3

Rudy authorized deployment and prerequisites for the detached-worker fix, then
said he was going to bed and would reconvene in the morning. Continue development
and inactive staging. Do not activate motors, change modes, restart cores or
Cerebro, move/reset CAN, or automatically resume a saved motion. The camera/head
mount is unfinished; Rudy explicitly permits later arm tests without it.

## Actual host observations and deployment

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
