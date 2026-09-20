# Vision Pro → Mac Drake shadow IK

Both VR controllers now drive their matching virtual arm: ROB-left **R-11** and
ROB-right **L-10**. The Mac also receives live OAK-D depth for **markerless** arm
estimation and checks swept rigid-scan clearance. This remains a development
preview with `hardwareOutputEnabled=false`; it has no actuator API or execution
message. The physical arm panel retains its separate supervised jogging path.

## Use the preview

1. Run `Scripts/setup-shadow-planner.sh` in Cerebro to install the pinned Drake
   1.57.0 / SciPy 1.17.1 runtime, then build both updated apps.
2. Pair Vision Pro with Cerebro. Leave drive and arm authorities disarmed. Open
   **Shadow IK**. **Require live vision** is on by default; load the reference.
3. Select Left / R-11, point that controller level along your intended ROB-forward
   direction, and align. Repeat for Right / L-10. These are independent virtual
   controller alignments, not physical camera registration.
4. Release, then hold each grip to move its matching ghost gripper. Both hands can
   be active; requests alternate through one shared whole-robot state. Releasing
   a grip allows hand repositioning without jumping the target. Precision scales
   translation by 0.2. XYZ buttons operate on the selected arm in 2 or 10 mm steps.
5. Inspect **Vision** and **Clearance** below the view. Grey is the immutable scan
   reference, cyan the proposed ghost, green freshly confirmed arm observations,
   and orange the requested target. Solver error is model error, not measured
   physical accuracy.

To rehearse without cameras, turn off Require live vision *before* loading a new
preview. Scan rehearsal still enforces collision and centered travel limits. It
never presents the scan as a live observation. Closing/reopening resets the mode.

## Markerless estimation and honest limits

`CameraManager` offers its existing synchronized RGB-D frames to
`ROBMarkerlessVisionService` only while preview is open. The service uses aligned
metric depth and calibrated RGB intrinsics; RGB-only fallback cannot confirm
joint positions. It downsamples depth with matching intrinsics, preserves capture
age, and admits one fit at a time to an isolated stdio process. No QR, AprilTag,
printed marker, LLM angle guess, or commanded motor position enters this path.

The worker fits the approved scan's rigid surfaces to the depth cloud. It first
registers camera coordinates to ROB's base using visible base and torso surfaces.
A guessed URDF camera transform is only a search seed. The registration must pass
residual, coverage, and six-dimensional observability checks. Arms alone cannot
resolve camera motion versus arm motion. An onboard camera that cannot see the
required body surfaces will explicitly report registration unavailable. A useful
markerless view must see ROB's base/torso and the arm surfaces; an external RGB-D
view may be necessary. No such live view has been validated in this development
session.

Each seven-joint arm fit uses articulated point-to-point ICP with analytic joint
Jacobians, robust residuals, alternative hanging hypotheses, depth occlusion
checks, and a separate data-only point-to-surface observability test. Neighboring
depth pixels are treated as correlated when estimating angular uncertainty. The
initial gates are 12 mm surface residual, less than 5° estimated joint uncertainty,
per-link support, agreement between alternative fits, and three consistent
observations. These are provisional engineering thresholds, not calibrated
confidence guarantees. Symmetric housings, hidden wrists, cables, sparse depth,
large pose changes outside the local search, or scan mismatch may remain
unobservable. A low residual alone does not confirm seven joint angles.

No confirmed observation may be older than 750 ms. Both arms must be confirmed
before live shadow motion can use arm-arm clearance. Fresh camera estimates
replace a misplaced hanging reference automatically; a cumulative change over
3° rebases the ghost and drops the grip latches. The next motion requires release
and re-clutch. Stale, absent, ambiguous or structurally inconsistent evidence
holds the ghost and reports the reason. A failed fit cannot diagnose a broken
joint by itself, and is never reported as successful physical movement.

The scan body, neck and base joints remain held at the review pose. This estimator
currently confirms **arm angles**, conditional on body registration; it does not
certify all of ROB's joints, camera mounting accuracy or a changing head/torso
configuration. Live physical execution remains outside this milestone.

## Clearance and the concrete geometry blocker

`clearance.py` loads 43 SHA-pinned convex scan envelopes through Drake SceneGraph.
The checked pairs cover arms against head, neck, torso, base/treads, accessories,
the opposite arm, and non-adjacent links in the same arm. Directly connected rigid
assemblies/mounts are exempt. The margin is 25 mm. Every accepted IK segment checks
both endpoints and intermediate configurations with a lever-bound inflation that
covers motion between samples. Query failure or exhausted sweep budget blocks.

**The current scan reference is blocked:** the torso envelope overlaps
`left_two_Link` by about 27.5 mm and `right_two_Link` by about 28.4 mm. These are
provisional convex scan envelopes, so this is not proof of a physical collision.
The automatic rigid cuts and torso concavity need review before these envelopes
can pass clearance. No overlap is auto-exempted and the code does not weaken the
margin to make the pose pass. The generated clearance review lists every affected
pair for that review. Cameras cannot remove this geometry blocker automatically.

The right J2 scan value remains **+120.417°**, beyond the provisional centered
±120° range. Right-controller input is implemented, but motion from that reference
is blocked until a confirmed in-range pose replaces it. It is never clamped.

Clearance describes the rigid model. Unobserved surroundings, carried objects,
flexible cables, missing scan surfaces, physical travel and motor-coordinate
mapping are not certified. The first and other B1 servos have no trusted mechanical
stops; ±120° is a preview bound, not a cable-safe travel claim.

## Process and protocol boundary

`rob-shadow-ik/2` binds each request to controller/session/preview/request UUIDs,
monotonic sequence, timestamp, exact model ID and explicit arm. Old/future or
malformed shadow versions are consumed before the legacy motor parser and never
fall through to it. The Swift schemas remain byte-identical in both repositories.
Replies separate reference/ghost/observed frames and report vision and clearance
status. Closing, session loss, live authority acquisition or scene suspension
ends the preview. There is no motor fallback.

ARKit source timestamps, tracking quality, origin IDs and distinct sample IDs are
checked independently for each hand. The 150 ms controller age and 250 ms input-gap
gates do not reuse camera freshness. Losing tracking or a button heartbeat requires
a real release; losing an origin requires re-alignment. Stale acknowledgements or
responses for the other arm cannot resume a gesture.

Every solve pins the inactive arm and all non-arm joints at their current model
values. Active bounds intersect the source URDF limits with centered ±120° and
±0.15 rad of continuity. IK uses 0.5 mm per-axis position tolerance and 0.015 rad
orientation tolerance, followed by independent limit/residual/clearance checks.
A blocked target preserves the last accepted ghost pose. No model or scan source
file is changed by runtime fitting.

## Rebuild and validate

```sh
Scripts/prepare-shadow-model.py /path/to/ROB-Approved-Geometry-2026-09-19
"$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3" \
  Scripts/prepare-shadow-surfaces.py /path/to/rob-scan-rig.json
Scripts/test-shadow-planner.sh
```

The preparation scripts preserve the approved original URDF and scan. The surface
manifest pins the calibration hash, segment source hash, full convex meshes and
visual point samples. Re-run both preparation steps together after calibration.

Tests cover real Drake solves, tracking and session boundaries, native worker
transport, real scan overlap rejection, a swept head crossing with clear endpoints,
right-hand independence, markerless fit recovery using synthetic full-surface scan
clouds, missing wrist evidence, rank deficiency, stale/replayed depth, failed
registration, visual correction and hold behavior. Isolated IK/mapping tests stub
the clearance result; the dedicated safety tests use the real geometry. Synthetic
fits do not validate real camera noise, occlusion or physical cable limits.

Vision adds package tests and `Scripts/test-shadow-preview-model.sh`, including
right-hand alignment, wrong-arm reply rejection and no restart after tracking loss.
Development Mac, visionOS Simulator and device SDK builds are checked separately.
No installed live app, Amber configuration, signed production download or store
release is replaced by these scripts.

The next physical session should first review the reported collision envelopes,
then open cameras and inspect registration/observability with motors disarmed.
Compare each visible estimated joint against slow hand-positioned poses, obscure a
wrist and confirm an error/hold, then test both VR controllers in shadow mode.
Commission motor mapping, cable travel and supervised movement separately.

Technical references: [Drake signed distance queries](https://drake.mit.edu/doxygen_cxx/classdrake_1_1geometry_1_1_query_object.html)
and [SciPy bounded nonlinear least squares](https://docs.scipy.org/doc/scipy/reference/generated/scipy.optimize.least_squares.html).
