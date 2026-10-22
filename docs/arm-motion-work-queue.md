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
   every path corner/reversal is retained. A full ghost wave schedules about 15 s.
   V8 reached both wave positions with the 3D window closed, in 31.43 seconds
   including preparation/settling (max feedback age 36.2 ms). Rob requested
   further J5 rotation; v9 stages it to −1.00 and automatically holds an embedded
   preview snapshot during motion so the controller window can stay open.
   V9 completed with that window open in 33.11 seconds (651 seven-joint samples,
   maximum feedback age 43.6 ms). Rob requested more J5; v10 proposes −1.40,
   retaining handoff and J6. Its model tread sweeps pass. The authenticated live attempt lost CAN feedback
   during approach before reaching raised J5; hold was unconfirmed. Recovery and
   live acceptance remain pending. Do not weaken freshness checks to proceed.
   Rob recovered the arms and completed a Coke-can grip: intensity10 held but
   slightly deformed it; intensity2 held securely with no additional deformation.
   The can was returned and confirmed clear. This does not commission raised
   J5 −1.40 or establish calibrated grip force. The lease-to-gripper transition
   now requires a confirmed hold before calibration; real jaw opening still
   requires observation. See [can evidence](calibration/evidence/2026-10-21-coke-can/can-grip-trial.json).
   The first revision joined normal controls' straight increments as the ghost compiler does:
   handoff 28→9 segments, full wave 46→15, corners/reversals preserved. A live
   preparation reached endpoint 18 in 18.17 seconds (previous 31.16) but lost CAN
   feedback entering J6; the complete faster handoff was then unverified. Physical
   recovery then passed verification, and a fresh approved nine-segment trial
   completed after Rob confirmed hanging: handoff 22.24 seconds vs 44.68 previously,
   full preparation 26.66 seconds with fresh feedback. Rob reported **“Clear, but
   still too choppy or slow.”** Preserve that nine-segment trial as historical
   evidence. The next candidate uses five center endpoints `1,4,6,18,28` and
   11 full-wave segments: J3/J5 move together on 6→18, then J2/J6 on 18→28.
   The two new sweeps pass 25/30 mm model tread margins (172.4/327.0 mm
   conservative lower bounds), with no new arm/body/self warning pairs versus
   the canonical subpaths. Existing rigid-model overlaps remain; this is not
   physical clearance certification. The five-segment live trial is pending.
   After an app/Xcode session restart, Lower was blocked by the new-session
   hanging reference. Rob manually used Zero and confirmed hanging; telemetry
   showed zero in mode 2. Support was confirmed; controller-approved
   physical-left Deactivate succeeded with all seven joints inactive. Rob then
   confirmed hanging and empty before the new build was loaded. The first
   five-step ghost request expired without a connected approval controller;
   no movement started. Both arms later showed stale CAN replies while inactive,
   so authenticated recovery and a fresh trial remain pending. See
   [smooth-route checks](calibration/evidence/2026-10-21-smooth-left/validation.json)
   and [five-segment model evidence](calibration/evidence/2026-10-21-smooth-left/five-segment-model.json).
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
   camera through shared URDF FK. V10 removes scan neck offsets at upright and
   makes lower display rotation independent of the optional leveling gain.
   The live current replay was verified, and a +2 cm XYZ ghost pose was saved as
   **Centered hello +2cm** and reviewed; it has not been physically executed.
   Check neck orientation against the physical robot after loading.
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
   origins merely to obtain a desired reach height. Check the existing hanging
   left-tool/track overlap in the rigid model as well as the camera offsets.
   Do not promote
   unobservable rotations to measured calibration. This is queued work, not
   an automatic future motor operation or a calendar schedule.
