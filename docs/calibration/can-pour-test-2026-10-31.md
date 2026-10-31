# Coke can timed-pour test

This is a reproducible **Testing Sandbox → Coke can · timed pour** scenario.
It recomputes a saved scene with the bundled ghost robot model and opens the
result in Cerebro's existing controller-input ghost editor. It sends no motor
commands. The requested physical task remains unfinished: approach the table,
grasp with the right arm, pour half of the remaining liquid, return the can to
support, then slide the glass toward the occupied keyboard seat using the left
arm.

The can is reported half full; half of the remaining contents is one quarter
of full capacity. The user requested a fixed-time tilt/hold/return chain and
said the opening already faces the glass. The scenario preserves that opening
direction instead of silently yawing the can. The user subsequently requested
the test live in Cerebro's native Sandbox and ghost planner.

## Repeat in Cerebro

1. Open **Testing Sandbox**, select **Coke can · timed pour**.
2. Set starting fill, fraction of remaining liquid to pour, fixed hold time,
   hypothetical base approach and grasp height offset.
3. Choose **Run saved pour test + open ghost**. Each run retains its input scene,
   baseline, planner log and report in `~/Library/Application Support/Cerebro/CanPourTests/<run UUID>/`.
4. Scrub the complete native ghost pose sequence. **Play timed pour and return…**
   opens the compiled active pour at real-time playback speed. The full pose
   sequence is a storyboard, not a claim about complete-task execution timing.
5. **Show latest recording** reveals the latest report. Reopening either native
   ghost action loads that saved result, without recomputing or moving hardware.

The run records the exact inputs, model/reference identities, final joint
solutions, timing and clearance results. The bundled scene and baseline are
numerical fixtures, not live observations. No photos or private camera/audio
artifacts are included in the repository.

The same planner can be run headlessly with the existing ShadowPlanner Python
environment:

```sh
python3 Scripts/plan-can-pour.py \
  --scene Cerebro/Resources/ShadowPlanner/fixtures/coke-pour-scene.json \
  --status Cerebro/Resources/ShadowPlanner/fixtures/coke-pour-status.json \
  --base-advance .40 --hold-seconds .35 --output /tmp/pour-report.json
```

## Implemented geometry and checks

- The cylindrical liquid estimate solves the volume below the horizontal plane
  through the opening lip. Defaults assume a 66 mm diameter, 120 mm tall can
  and a lip 25 mm from its axis. The ideal onset is 67.38°; retaining one quarter
  capacity gives 79.30°. Can shoulders, venting, foam and transient flow are not
  modeled. Time or tilt alone does not establish a measured volume.
- The can and tool remain rigidly attached. The opening stays over the cup as
  the entire can pivots. The whole cylinder stays above the protected rim plane.
  Retention and supported release are explicit checkpoints. Jaw ACK is not
  possession; no automatic intensity escalation or loaded jaw calibration is
  added.
- Full seven-joint IK preserves the supplied other-arm and head coordinates.
  Final raw targets and interpolated extrema remain within the conservative
  ±2.09 rad bounds. No post-solver wrist amendment is allowed.
- A smooth quintic clock drives the interpolated joint curve. Analytical
  derivative bounds enforce 0.30 rad/s, 0.60 rad/s² and 2 rad/s³. The return
  retraces the same curve. It is not a stream of overlapping vendor cmd4 calls.
- Full scan hulls, the table proxy, cup and carried can are reviewed. The swept
  self-clearance calculation now bounds each pair's relative motion; fast wrist
  travel no longer inflates a nearly stationary shoulder pair. Existing static
  overlaps and between-endpoint collisions still reject a complete route.
- The tabletop obeys Rudy's horizontal constraint in the Z-up simulation frame.
  A convex outline records the visible table patch; unseen far corners are not
  filled by its bounding rectangle. The same 6 cm thick prism is used for
  collision review and rendering. Frozen pour previews do not inherit a live
  neck display gauge. The input camera/neck prior and its removed tilt remain
  in the report; camera-to-arm translation and body posture remain unverified.
- Native payload rendering applies the complete rigid grasp transform, including
  rotation. A white opening-lip marker stays attached to the can. Imported test
  reports must match the model and carry non-executable
  markers; incomplete/out-of-bounds poses, unsolved IK, tilted tables and invalid
  transforms are rejected. A failed attempt replaces the latest report instead
  of silently retaining a prior passing replay.
  Imported rehearsal never supplies motion approval or enters the grasp executor.

For the corrected 40 cm approach hypothesis with the grasp 20 mm above the can
center, the active portion starts from a prepared 55.81° tilt. It takes about
3.25 s to reach 79.30°, holds 0.35 s, starts returning at 3.60 s, and reaches the
prepared angle again at 6.84 s. Full upright recovery follows separately.
The prepared angle is below the ideal onset; its actual dryness is unverified.
All 328 active-cycle samples pass the model's moving-pair and workspace review.
This does **not** make the complete task executable.

Rudy caught a tilted table in the first native rehearsal. That rehearsal
composed IMU gravity with an unverified neck FK transform, leaving the tabletop
normal about 18° away from model up, and displayed an oversized bounding box.
The earlier 25 cm / 5.07 s result is superseded and must not be reused. A fresh
stationary frame provided a horizontal-plane-constrained visible outline
(7.74 mm residual RMS among retained samples). Transparent-glass depth returned
background, so the glass rim uses its image location and the explicitly assumed
154.6 mm height. This is not a measured glass or camera-to-arm calibration.
The corrected geometry makes the 25 cm and 35 cm candidates fail IK; the 40 cm
candidate solves all poses without relaxing the joint limits.

## Remaining physical failures

The full approach still encounters torso/right-upper-arm overlap and inadequate
upper-arm/forearm clearance. Its first workspace connector exceeds the current
sweep budget. The saved baseline has a roughly 77 mm modeled left-tool /
track overlap. The earlier right-arm/head strike was missed by the model;
camera/body registration, tool offset and open-jaw geometry remain unresolved.
The current base map was stale. The requested left-glass slide is now rejected
by the visible-table support margin; the earlier bounding rectangle had admitted
it. No force-controlled left-arm trajectory is solved or verified. See the
sanitized numerical summary alongside this report.

During this task only neck search commands and read-only torso counter selection
were used. No arm mode, gripper, arm trajectory, base travel or torso-turn command
was sent. The counter read 92, matching the historical front count, but software
alignment remained unset. The occupied keyboard seat was located on ROB's left
using the front camera. The can and ice-filled glass remained on the table in
the final inspected still. Camera artifacts remain private and outside Git.

The other session's native assistant speech work (078d7d7, preserved here by
cherry-pick cb67fde) is retained. Its controller diagnosis remains applicable;
no Amber core change or streaming commissioning is included in this test.

## Validation

- `Scripts/test-can-pour.sh`: cylinder volume, rigid payload/pivot, recovery,
  final interpolation bounds, timing/derivative limits, supported slide geometry,
  current head/other-arm preservation and real collision regressions; also
  compiles the actual native payload rendering transform.
- `Scripts/test-can-pour-native.sh`: reruns the bundled numerical fixture and
  checks native full/timed decoding plus tampered model/authority/pose/time/
  transform rejection.
- Existing `ROBShadowSafetyTests.py` retains the between-endpoints head collision
  and static-overlap regressions. Existing `ROBShadowPlannerTests.py` covers the
  ordinary ghost workflow.

The 14 pour tests and native payload-transform fixture passed, including the
new horizontal-table and clipped-outline support regressions. Native full/timed
decoding and eight invalid-report cases passed against the corrected scene.
The native decoder respects
continuous URDF joints while retaining bounded-joint and final arm limits.
The 14 existing shadow-safety tests and 10 shadow-planner tests also passed.

The combined build preserves the other session's accumulated-surface texture
fix (43e63bb, included here as c9e7e67), in addition to its native speech work.
Its photo-orientation/color fixes do not provide camera-to-arm calibration.

The combined Debug build succeeded and was installed with strict code-signature
verification. A coordinated passive relaunch retained inactive arms and their
unchanged feedback; no neck target was replayed after its command state became
unknown. The native Sandbox run `7D61FA16-4512-41A3-AD94-466C4F9A3933`
completed, opened 64 solved review poses, and saved the corrected horizontal
outline. The table/floor alignment was inspected from two viewing angles.
The native timed action played 328 samples to 6.84 s and showed the final phase
as `return`; execution remained disabled. No physical pour or glass slide was
performed. The earlier browser viewer is retired.

The saved report SHA-256 is
`2810debf87f74bb01f366d4712b956a9fbb4e497faa5ed0746bbb189390192c3`.
The installed `Cerebro.debug.dylib` matches the combined build at
`c5a4f5e91ede34907c43db1dcdf6d9d8fa25be4ac4db70623c6a39530254d7bb`.
Private inputs, complete reports and build logs stay outside Git; the numerical
summary in this directory is sanitized. Offline and UI validation do not
establish physical clearance or metered liquid volume.

Build coordination lesson: pass `CEREBRO_INSTALL_AFTER_BUILD=NO` as an
**xcodebuild setting argument**. An environment assignment alone is overridden
by this project's `YES` setting and can install a bundle passively. The explicit
setting was verified on the final builds; installation and relaunch were then
handled separately.
