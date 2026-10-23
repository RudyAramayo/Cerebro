# ROB session handoff — October 22, 2026

## Saved state

The installed, signed Debug app corresponds to commit `a5758d8`. Its executable
SHA-256 is `247fe469fcb320064f240309dce63c7f1ea5d9bfd0f80f604a79b77177d72c0b`.
Testing Sandbox → Depth alignment stores these provisional settings:

- Head-depth translation: **7 inches toward ROB**, or base-frame X = **−0.1778 m**.
- Face-camera mounting correction: **15° down**, or optical-local **Rx(−15°)**,
  about the lens origin. Model and head-depth projections share the correction.
- Neck, Insta360 and belly-camera geometry were not recalibrated. No measured
  camera-to-arm registration or fitted room calibration matrix exists yet.

The operator confirmed the translated table points line up with the real blue
tape, then identified the camera as physically pointing lower than the old
model. These manual corrections do not establish the entire neck/camera chain.
The legacy grasp correction needs checking after the pitch change.

An earlier single-can trial succeeded, with the operator confirming that the can
landed in the orange bucket. The later attempt on the two newly positioned cans
removed **zero cans**: it located a can during twelve observations, then stopped
before arm travel at the combined stationary-arm pose/mode/freshness guard.
That run did not retain the failing sample, so its exact failure condition
cannot be recovered. Do not describe it as proven stale feedback or successful
recycling.

Evidence: [camera pitch](evidence/2026-10-22-recycling/camera-pitch-validation.json),
[applied translation and failed attempt](evidence/2026-10-22-recycling/depth-alignment-validation.json),
[earlier confirmed recycle](evidence/2026-10-22-recycling/first-confirmed-recycle-validation.json).
Seven unrelated user-modified files remain preserved outside these commits;
inspect `git status` before resuming and do not overwrite them.

## Next session: fixed QR target and room reference

The operator reports that a QR code fixed on the table appears to move in the
model when the cameras are realigned or the neck moves. Pixel coordinates and
camera-relative coordinates are expected to change; the recovered **base/world
position of the stationary marker must remain consistent** across neck poses.
Use that distinction to test the calibration.

1. Fix a known-size QR target to the table and measure its side length and
   reference placement. Keep ROB's base, table and target stationary. Retain
   original images and a Scaniverse room mesh with measured scale references;
   follow [capture and commissioning](capture-and-commissioning.md).
2. At several settled pan **and** tilt poses, record QR corner pixels, aligned
   depth, camera intrinsics, RGB/depth timestamps and neck pose timestamps.
   Prefer measured neck feedback; explicitly label accepted command estimates
   when feedback is unavailable. Record settling and capture latency.
3. Fit the camera mounting transform together with the neck zero offsets,
   rotation axes and motion chain against the fixed target and room reference.
   Check the complete transform chain rather than adjusting each observation
   independently: `world_T_marker = world_T_base × base_T_neck(q) × neck_T_camera × camera_T_marker`.
4. Reserve neck poses and measured distances for independent validation. Report
   marker drift, plane orientation and distance errors on these held-out data.
   Do not call a fit commissioned solely because its fitted views agree.
5. Recheck can top/middle/bottom, table clearance and the prior reach correction
   before resuming the two-can task. Diagnose the arm-state guard with the
   actual failing side, feedback ages, modes/statuses and joint drift retained.

No QR sweep, room scan or new physical arm trial was performed for this handoff.

## Shutdown preparation

Completed before closing Cerebro:

- Testing Sandbox showed no active arm rehearsal session or pending approval.
- Stop + hold was requested. The authorized empty-arm Relax action completed
  with **“Both arms are measured at hanging zero and inactive.”** No new arm
  rehearsal or QR sweep was started.
- Cerebro quit normally. `pgrep -x Cerebro` returned no process. The computer
  itself was left running, prepared for shutdown; power-off was not requested.
- A local backup is saved at
  `~/Documents/ROB Session Backups/2026-10-22-232907-neck-camera/`. It contains
  the persisted 7-inch/15° alignment, can-reach calibration, repository status,
  a binary patch for the seven unrelated user changes and a checksum manifest.
  No arm grant or unrelated account preferences were saved.

On the next launch, keep the fixed table marker and ROB's base stationary for
calibration. Any physical task needs a new runtime arm session; no previous
authorization is restored from this handoff or backup.
