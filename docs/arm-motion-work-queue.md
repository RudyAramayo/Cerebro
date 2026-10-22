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
   The new `left_object_cycle` composes raise/open, stationary grip at intensity
   2, release into a supporting hand, then empty return/deactivation under one
   controller approval. Object-placed, receiver-supporting and object-clear
   Continue controls advance readiness inside that same bounded operation;
   they never create new approvals or automatically release on timeout. This
   composed cycle requires a fresh physical trial after CAN recovery.
   On leaving for several hours, Rob requested development without further
   live tests or approval requests. Keep the running robot untouched; finish
   software validation and commit/push, and defer physical verification until
   his return. [Object-cycle development evidence](calibration/evidence/2026-10-21-object-cycle/validation.json)
   records that distinction.
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
   A later display fix refreshes the embedded preview once after the accepted
   neck pose settles, before arm position entry/travel. Previously the snapshot
   taken before approval retained an older neck pose throughout execution.
   Current lower/upper targets and optical FK tilt now remain visible separately;
   no neck calibration constants or URDF origins changed. Isolated model/render
   checks pass; the running robot still needs visual verification after reload.
   Rob explicitly confirmed **6011/6906** for the physical vertical neck and
   level front camera. He accepted the blue head geometry and requested the
   normal model match it and follow servo changes. Both models now share the
   approximate mechanical reference shapes for five neck/head links, including
   the independent 20° backward Insta visual mount. The normal head follows
   accepted commands; explicit ghost edits affect only the blue preview. The
   captured asset is unchanged on disk, but its former normal head rendering
   is replaced. Shared FK, OAK projection, driver safety references and motor
   commands are unchanged. Visual review of the updated normal model is pending;
   full measured calibration remains queued. See [shared neck model evidence](calibration/evidence/2026-10-21-flat-floor/shared-neck-model.json),
   [comparison](calibration/evidence/2026-10-21-flat-floor/shared-neck-model.png),
   [reference evidence](calibration/evidence/2026-10-21-flat-floor/neck-reference-preview.json)
   and the [earlier blue-only comparison](calibration/evidence/2026-10-21-flat-floor/neck-reference-preview.png).
   The live current replay was verified, and a +2 cm XYZ ghost pose was saved as
   **Centered hello +2cm** and reviewed; it has not been physically executed.
   Check neck orientation against the physical robot after loading.
   A supervised hanging-arm camera view was established at pan +30° / lower
   6011 / upper 5650: Rob confirmed the hanging arm is visible at J2, with distal
   joints still cropped. A small lower-neck refinement to 6200 was applied. This is
   supplementary visual evidence, not a complete independent pose verification.
3. **Deferred until 1 and 2 are complete — camera-to-URDF calibration.**
   Rob's wooden floor is now the flat reference for a display-only plane fit:
   level each supported cloud rigidly against `y=0`, retaining object geometry
   and raw depth. This does not change URDF origins or replace the independent
   camera/servo calibration below. After Rob returned, the signed development
   build was loaded with both arms freshly measured near zero and inactive.
   A restored torso sequence-table indexing crash was fixed without changing
   motor/slider handling. Live diagnostics identified the floor candidate gate
   clipping the belly floor to a 14 cm strip; the corrected selection admits
   the existing 30° fit bound. Belly fits measured approximately 18° correction,
   66–69% support and 9 mm RMS. Rob observed level/raw oscillation at the noise
   cutoff; the display noise budget was adjusted from 9 to 10 mm for the
   measured 9.0–9.1 mm floor residual. Accepted geometry also has a bounded
   250 ms noise hold, then hides rather than automatically returning to raw.
   Rob accepted the resulting belly floor. He reported that the head cloud
   appears on the ceiling while the physical camera faces forward, and lower
   neck changes are absent from the model. Investigation found that both pitch
   servos used the same display sign despite their opposing mechanisms. The
   lower display sign is now corrected: L7014/U7790 predicts 3.6° down instead
   of 56.6° up. Pure model/render regressions pass, including lower-pivot motion
   when upper compensation keeps the optical ray level. The signed build is
   loaded; live L7014/U7698 now reports about 6° down and the head cloud is
   forward in the scene. Operator neck-posture acceptance remains pending.
   See [neck direction evidence](calibration/evidence/2026-10-21-flat-floor/neck-direction.json).
   Rob requested that the last published head cloud stay visible until replaced,
   removing the earlier three-second expiry. Its vertices remain fixed at the
   capture pose, with **HEAD DEPTH HELD** showing the actual age to 0.1 s.
   Failed/missing input, neck settling and rejected floor fits do not replace or
   refresh it. New geometry still requires a frame no older than 700 ms,
   settled neck commands and matching targets. Arm operations or base changes
   clear it immediately; belly's existing 250 ms noise hold and normal freshness
   timers are unchanged. Historical head points are visual only, never motion,
   collision or force evidence. See [persistent-display evidence](calibration/evidence/2026-10-21-flat-floor/head-persistent-display.json)
   and the [earlier bounded-history record](calibration/evidence/2026-10-21-flat-floor/head-persistence.json).
   See [live floor evidence](calibration/evidence/2026-10-21-flat-floor/live-install.json).
   The separately running
   torso-stepper terminal process was left unchanged. No arm test was performed.
   Capture
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
