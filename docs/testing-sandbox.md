# Testing Sandbox

Open **Development → Testing Sandbox…**, or **Settings → Arms → Open Testing Sandbox…**. Select a test from the list to see its description, custom parameters and actions. New experiments belong in this catalog rather than adding more object-specific controls to Settings.

## Robot preferences and tests

The Arms preferences contain persistent robot behavior: automatic empty-gripper calibration after connecting, offering an arm session at launch/wake, the optional arm startup route and the inspection camera's pan. They also retain status and Stop + hold.

The sandbox catalog contains these independent test items:

| Test | Actions |
| --- | --- |
| Recycle can | Run the physical test, search with the neck camera, scan workspace geometry, preview the grasp |
| Recycle can · right arm | Recycle one or two empty cans with physical right/L10, separate reach tuning and visual grasp checks |
| Camera-to-arm registration | Capture, fit and independently validate one fixed head/body view |
| Right-arm calibration step | Passively capture the registered view, review one small empty-arm outward step, run and hold |
| Depth alignment | Adjust head-depth placement toward ROB and the face-camera downward mounting angle, then inspect the live cloud |
| Estimated calibration trial | Build a small estimated empty-arm ghost movement, inspect it, run the reviewed test and hold for observation |
| Grip and return | Complete the supervised left-arm object handoff |
| Stationary gripper setup | Explicitly set up empty grippers while hanging and inactive |
| Arm preparation and return | Present/open, grip, release, inspect hanging, scan workspace geometry, startup route, empty-arm return |
| Ghost motion rehearsal | Open the ghost editor, preview a wave, open motion rehearsal |
| Body demonstration | Record, replay and front-arm greeting |
| Spoken feedback | Test the spoken warning without arm movement |

Status is shared across the sandbox. The scrollable status area shows the complete pending operation scope; the spoken prompt remains **“Can I move my arms?”**. Stop + hold stays available regardless of the selected test.

## Startup gripper setup

**Calibrate empty grippers after connecting** is enabled by default. The first authenticated Amber connection after app launch starts stationary setup. Both arms must have fresh, advancing feedback and be stationary, hanging and inactive. Setup reserves both arms, calibrates the jaws serially, waits for calibration settling, then commands the established gentle close/open initialization. It does not raise the arms or turn on arm holding torque.

Keep both jaws empty and clear during startup. Amber acknowledges command dispatch; Cerebro does not have measured jaw opening or calibration completion. Stop prevents subsequent setup commands, but an already accepted vendor calibration may finish. Sleep, connection loss, ownership loss or invalid feedback cancels setup. A reconnect does not silently replay the startup sequence or restore a motion authorization.

If startup setup was deferred because the arms were not hanging, the selected task may complete the same stationary setup only after an empty-arm return has passed current scene admission and reached inactive hanging. It must map the workspace before that return, rather than parking blindly to improve the view. An unregistered map blocks the return. The sandbox's separate stationary setup item also supports inspection and testing when the arms are already hanging. It is not a mandatory arm-raising preparation step.

## A supervised test session

1. Start the 15-minute left-arm session and give one real on-device spoken or authenticated controller approval.
2. Choose a test and save its parameters. Start the selected operation.
3. Observe actual clearance, jaw opening and the result. Use Stop + hold when needed.

Starting a session only requests the bounded authorization. It does **not** automatically run Present/open, raise the arm or repeat gripper calibration. Recycling owns its own necessary presentation and grasp path. Present/open remains available as an explicit preparation test.

One active session covers its included routines and waypoints; there are no extra approvals for each arm segment. Neck-only search, workspace depth scanning and hanging inspection need no arm authorization. Returning an empty arm to hanging also needs no new approval, while still requiring current collision clearance. Stop, expiry, sleep/restart, ownership loss or failed motion ends the session. A perception-only rejection that sent no arm motion can remain inside the existing bounded session; that grant never substitutes for scene registration. A typed sandbox command never supplies spoken approval.

## Recycling parameters

Test timing parameters are saved in `~/Library/Application Support/Cerebro/TestingSandbox/recycling.json` and snapshotted for the next run. Editing is disabled during an active or pending operation, including startup jaw setup.

| Parameter | Default | Supported range |
| --- | --- | --- |
| Motion pace | 1.25× | 1.0–1.25× |
| Jaw settling time | 1.5 seconds | 1.0–2.0 seconds |
| Maximum path adjustment | 3 mm | 0–5 mm |

Pace reduces extra timing padding while retaining the existing motion-duration minimum. Path adjustment can join nearby travel segments after checking the resulting route against the original path, robot model, tread clearance and horizontal-jaw limits. It preserves jaw action boundaries and their neighboring targets. These timing controls do not exempt presentation, return or any other segment from full-arm scene checks. Zero path adjustment disables segment joining.

On the existing motion-compaction regression fixture, the default parameters produced **33 motion steps instead of 48**, with **26.869 seconds instead of 37.369 seconds of scheduled motion**. These are compiled-plan measurements. They are not measured physical execution times, and exclude camera search, planning, jaw settling, calibration and feedback waits.

When a valid local reach calibration exists, the recycling form also exposes its bounded reach and release parameters:

| Parameter | Supported range |
| --- | --- |
| Reach X/Y/Z correction | −15–15 cm per axis |
| Additional reach toward the can | 0–3 cm |
| Calibrated can-base height, when configured | 30–140 cm |
| Bucket release rotation | −30–30° |
| Release toward the robot | 0–8 cm |

The detected can height places the grasp at its middle above the calibrated base. The legacy Z correction applies only when there is no configured calibrated base height. The base datum is commissioning data for the particular tabletop, not a newly measured table plane. A different table or altered geometry needs appropriate fresh calibration.

Reach settings remain in `~/Library/Application Support/Cerebro/LeftArmCalibration/can-reach.json`. Saving preserves the existing model/reference/mapping identity, source and unknown optional metadata. The sandbox does not manufacture model identities, infer a replacement calibration or change raw visual sightings. The current-jump threshold is recorded separately; zero means record only, and its raw units are not a calibrated force limit.

Recycling still requires fresh confirmed can geometry and bucket-opening depth. A visible bucket can remain unlocalized when depth is invalid; faster arm timing does not remove that search limitation, and no reach should begin without the required target evidence.

## Depth map and complete-path review

Choose **Scan workspace geometry** to collect current neck-camera RGB-D evidence while the arms stay still. This neck-only operation needs no arm approval or arm preparation. Then choose **Inspect depth map / planned route…** in the recycling or ghost-motion test. The SceneKit view can show the current occupied depth cells and animate the last validated path artifact across all seven left-arm joints. **Show depth obstacles** and **Show planned route** control the overlays. The viewport continues rendering during review; no frozen screenshot replaces it.

The sandbox and ghost panel report map capture age, observed frame count, occupied-cell count, model-path clearance when evaluated and the planner's blocked reason. Unknown or unobserved space remains unknown. If no validated route is available, the preview displays the scene and the reason instead of inventing a path.

The last captured scan remains available in memory for read-only inspection when opening a camera window changes the camera stream or the original scene/session expires. The panel then says **“Stored scan preview; rescan before motion.”** Its age remains tied to the original capture; retaining the cloud does not freshen it. Motion continues to use the separate strict current-scene snapshot, with unchanged camera/session/age checks. A stored preview neither restores authorization nor supplies current registration or clearance, and is not persisted across app restarts.

Map visualization alone does not establish a physical camera-to-arm registration. A cloud transformed only by the provisional neck/model prior is labeled **unverified · visualization only** and currently blocks left-arm travel. The planner checks the complete dynamic path from the measured starting pose, including presentation, approach, grasp, carrying and an empty return when requested. It checks the whole arm and open-gripper envelope, plus the carried-object envelope when applicable, rather than checking only the tool near the can. Unknown space remains blocked.

The arms stay stationary while the neck camera collects geometry. Even an empty lowering or a previously successful hanging/front route may now meet a newly positioned table, so it must pass the same checks before moving. There is no blind-parking exemption. A saved route, floor fit or corrected can point does not supply measured camera-to-arm registration or establish that the intervening arm volume is clear.

This admission currently protects the left-arm trial executor. **Paired legacy coordinator paths are not globally certified by this work**; their existing transport checks and tests do not establish full-arm clearance against the new depth map.

This preview is read-only. It never assigns the executable proposal, restores an arm grant or enables execution. Any physical task still goes through the coordinator and the live admission checks against the current scene.

### Current commissioning limits

The default neck-command projection emits an unregistered map. The separate
[fixed-head commissioning test](fixed-head-pickup-commissioning.md) can now fit
raw depth against visible robot surfaces, validate different patches in later
frames, export an error allowance, and bind a local measurement to its exact
head/body, camera, model and connection state. Every projected frame must carry
that evidence for a map to receive measured registration. A small training
residual alone remains insufficient, and the CAD uncertainty is explicitly an
assumption. A fixture result does not commission the physical robot.

The physical right-arm model has a genuine convex-proxy overlap with the track
and upper idler at its hanging reference. The right-arm calibration step is a
separate estimated empty-arm experiment: J2 −0.039 rad over four seconds, with
29.399 mm maximum modeled hull travel. It requires improving existing modeled
self-proxy deficits and fresh local depth, then holds for observation. Its
endpoint still does not meet the ordinary 30 mm tread margin; the step cannot
silently unlock a grasp or chain itself into a reach.

The current hanging-tool collision proxy also enters the model's 3 cm tread margin. This requires checking the measured mounting geometry, tool/reference alignment and conservative proxy shapes; it is not proof that the real hanging arm touches a tread. Camera registration will not fix that model-relative discrepancy. The planner currently uses conservative link boxes and an expanded open-jaw envelope. Measured finger geometry, robot self-volume visibility and intentional contact with the grasped target still need commissioning before a live grasp can be admitted. No physical recycling success is claimed for this planner.

On October 22, the operator reported that the level table appeared 6–8 inches too far from ROB in the depth display, with an upward slope as range increased, while the near table height looked correct. These are approximate observations, not a measured camera transform. The [commissioning evidence](calibration/evidence/2026-10-22-recycling/estimated-calibration-validation.json) records the earlier build and its zero-motion outcome. A Scaniverse reference capture was deferred at the operator's request.

The **Depth alignment** test exposes a horizontal correction in inches and an extra downward face-camera mounting angle in degrees. The current manual estimate is **7 inches toward ROB and 15° down**. The translation alone moves head-camera points along base-frame −X without changing height. The pitch postmultiplies the raw optical frame by an optical-local X rotation of −15° (optical X right, Y down, Z forward), rotating depth rays about the lens rather than flattening individual surfaces. The face-camera housing in the live model receives the same rotation; its lens position, the neck and Insta360 geometry stay unchanged. The separate cloud translation does not move the camera housing. The belly camera is unchanged.

The live head cloud, workspace collision projection, can sections and bucket measurements use the same correction. Each apply clears previous scenes, object locations, motion previews and pending estimated proofs and starts a new camera generation. A fresh scan is required for a new workspace map. Existing saved horizontal-only settings load with zero extra pitch; the 15° angle must be explicitly applied. Translation-only edits preserve the current pitch. The manual mount correction remains provisional until the planned room scan is fitted to a calibration matrix.

The legacy can-reach file remains in its original calibration frame. Its optional `depthTowardRobotMetersAtCalibration` field defaults to zero for existing files; the loader rebases the residual X correction as `storedX + currentDepthShift − calibrationDepthShift`. Thus the earlier −127 mm reach correction becomes +50.8 mm when the head cloud moves 177.8 mm toward ROB, preserving the previously taught can target for a translation-only edit. Saving displayed reach parameters records the current depth shift as their calibration frame. The new pitch changes measured XYZ and is not compensated by that constant translation; the earlier grasp calibration must be checked against fresh measurements during scan commissioning. A manual mount correction does not automatically register a collision map or authorize arm travel.

The 7-inch correction was installed and applied, and the operator confirmed that the table points line up with the real tape. A subsequent authorized recycling attempt recorded twelve workspace observations and located a can, then stopped during stationary scanning when an arm's pose, mode/status or feedback freshness failed the combined hold check. That guard does not retain the failing sample, so the precise cause cannot be recovered from this run. No arm travel or task jaw command was sent, and neither can was removed. See the [applied-alignment evidence](calibration/evidence/2026-10-22-recycling/depth-alignment-validation.json). Stationary search intentionally omits joint CSV rows; its preflight-only recording does not indicate that the search was stuck.

### Estimated calibration trial

Rob explicitly authorized an estimated movement followed by observation and correction, then directed the initial movement away from the table. This separate sandbox test scans current depth, freezes one slow four-second empty-arm retreat, and holds at its endpoint. The selected joint deltas are `[+0.100, +0.025, −0.075, 0, 0, 0, 0]` radians; verified maximum hull travel is about 3.3 cm at the observed hanging pose. It keeps the estimate visibly distinct from measured registration. One native spoken or controller approval covers the bounded test; the spoken prompt remains **“Can I move my arms?”**

The trial checks the occupied depth grid using an explicit estimated alignment margin. Unobserved space is confined to the reviewed local trial volume. Existing model self-proxy overlap must improve throughout the sampled retreat without creating or worsening another pair. Joint limits, live feedback, current scene identity, ownership, leases and Stop remain active. The trial does not grip, carry, recycle, update calibration automatically, or chain successive steps into a reach. The next correction uses the operator's observation and a new proposal.

The fixed shoulder mounting plate is not swept against workspace depth: its fixed torso attachment and zero hull displacement are verified. Every articulated arm link retains the occupied-cell check, including links stationary in the planned step. The map is unchanged. A rejection reports the occupied voxel, sample and hull distance to help diagnose an estimated alignment error.

Expanded link boxes bound the voxel lookup. Occupied candidates then use point-to-surface distance from the verified closed convex arm hulls, including triangle faces, edges and vertices; points inside a hull have zero distance. Newly approached occupancy must retain the full 150 mm estimate margin plus voxel, sweep and jaw allowances. A pre-existing margin overlap may retreat only when its exact hull-to-voxel baseline is at least 100 mm plus jaw allowance, clearance never decreases at any checked pose, and it strictly increases at the endpoint. These pairs and their distances are recorded in the proof. Open, nonmanifold, malformed or nonconvex queried hulls block the trial. Unknown-space checks retain their conservative local envelopes. This remains an operator-supervised experiment around unregistered depth, with no planned table contact.

## Fixture coverage

`Scripts/test-left-arm-trial.sh` now checks the current admission boundary by default: real synthetic RGB-D samples produce a fresh provisional map, neck-only scanning requests no arm approval or movement, and an unregistered map blocks travel before parking, mode changes, waypoints or jaw setup. It also retains stationary-jaw telemetry, fault and authorization checks. The `workspace-gate`, `recycling` and `parked-search` branches exercise this same fail-closed boundary.

The new focused checks are:

- `Scripts/test-workspace-depth-map.sh`: fresh frame/session identity, occupied/free/unknown space, depth holes and occlusion, transform provenance and no promotion of a provisional transform to measured registration.
- `Scripts/test-workspace-collision.sh`: complete-arm and carried-object route checks, rejection of an obstructed historical parking route, a supported dynamic alternative in a simulated registered scene, and invalidation when the map, camera, scene or session changes.
- `Scripts/test-left-arm-trial.sh workspace-gate`: actual provisional depth-map construction, approval-free neck scanning and rejection before arm mode, parking, waypoint or gripper commands; stationary feedback faults and bounded-session behavior remain covered.

Historical travel-positive executor cases remain available behind the explicit `legacy-executor` flag. Their old assumptions are currently unadmitted: the concrete captured map has no measured camera-to-arm registration, and the current hanging model does not satisfy the collision planner's existing 3 cm tread clearance. These are commissioning/model limitations, not proof of physical contact. Those historical cases must not be reported as passing motion coverage or made to pass by inventing registration or relaxing clearance. Pure collision-planner fixtures exercise positive planning from supported front poses with explicit simulated map evidence; the paired-arm coordinator fixtures continue to cover their existing transport behavior.

## Adding a test

`ROBTestingSandboxWindowController` owns the test catalog, its parameter forms and actions. Add a catalog entry with a stable test identifier, description and supported actions; add the appropriate bounded parameter form when needed. Physical actions continue through `ROBArmRoutineCoordinator.performCommand`, with the existing runtime approval, ownership, feedback and Stop behavior. Keep persistent behavior preferences in `ROBArmRoutineSettingsViewController` and changing commissioning tests in this window.
