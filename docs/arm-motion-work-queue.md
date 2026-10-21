# Arm motion work queue

Requested by Rob on 2026-10-21. Preserve this order; calibration is deferred
until the current test and controller workflow are finished.

1. **In progress — supervised left-arm social pose.** J3/J5 extension,
   forward camera and recorded wave have completed supervised trials. Next test
   J6 centering completed with positive operator feedback. Test the added
   J2 handoff lift/lower face camera, then the above-shoulder J2/J4 wave.
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
