# Arm motion work queue

Requested by Rob on 2026-10-21. Preserve this order; calibration is deferred
until the current test and controller workflow are finished.

1. **In progress — supervised left-arm social pose.** J3/J5 extension,
   forward camera and recorded wave have completed supervised trials. J6
   centering and the higher J2 handoff/lower face camera received positive
   operator feedback. The J2 +1.30 / J6 −0.70…−0.60 wave completed after a fresh approval
   following an accidental spoken stop. Rob requested more vertical J5 and a
   larger J6 swing. Candidate v6 stages J5 to −0.80 and waves J6 −0.90…−0.60,
   retaining the accepted handoff. The first speed revision remained too slow and two live attempts held
   on lease/freshness faults while the renderer stalled the main thread. V7
   freezes the ×4 preview on execution, updates only changed mesh transforms,
   and caps display work. At Rob's request the timing is now 4× the old low
   approach pace and 6× the old front pace. Collinear increments are joined;
   every path corner/reversal is retained. A full ghost wave schedules 14.6 s.
   New angles and pace still require a completed supervised trial.
   Confirm physical clearance before calling the added angles taught. See [arm trials](arm-startup-and-grab.md).
2. **Implemented, live verification in progress — ghost motion editor.** Reuse the
   existing robot model and URDF joint names. Show the original robot with a
   translucent blue proposed robot and animate the entire proposed path.
   Support Amber joints and other mapped URDF servos. Bind the reviewed model,
   calibration, path and durations to one immutable proposal; approve in the
   input window, execute the same proposal through Cerebro's controller
   authorization, and associate its measured current/position recording.
   The new editor compiles bounded physical-left proposals for controller approval;
   other named axes remain preview/save-only until their mappings are commissioned.
   The [head-angle cloud correction](controller-depth-cloud.md) improved live
   alignment. Rob identified the frozen model neck; v6 now articulates model and
   camera through shared URDF FK. Check the integrated display after loading.
   A supervised hanging-arm camera view was established at pan +30° / lower
   6011 / upper 5650: Rob confirmed the hanging arm is visible at J2, with distal
   joints still cropped. A small lower-neck refinement to 6200 was applied. This is
   supplementary visual evidence, not a complete independent pose verification.
3. **Deferred until 1 and 2 are complete — camera-to-URDF calibration.** Capture
   synchronized fresh camera/depth observations and encoder readings during
   small, approved independent joint movements. Fit camera extrinsics, arm
   mounting transforms, joint origins/axes, driver directions and encoder
   offsets separately. Use observed gripper/joint positions to correct the
   canonical geometry and regenerate the matching controller and Cerebro
   assets. Validate on held-out poses, report uncertainty and compare predicted
   versus measured hand displacement and tread clearance. Preserve previous
   calibration versions and evidence hashes. Do not change link lengths or
   origins merely to obtain a desired reach height, and do not promote
   unobservable rotations to measured calibration. This is queued work, not
   an automatic future motor operation or a calendar schedule.
