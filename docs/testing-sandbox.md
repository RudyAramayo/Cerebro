# Testing Sandbox

Open **Development → Testing Sandbox…**, or **Settings → Arms → Open Testing Sandbox…**. Select a test from the list to see its description, custom parameters and actions. New experiments belong in this catalog rather than adding more object-specific controls to Settings.

## Robot preferences and tests

The Arms preferences contain persistent robot behavior: automatic empty-gripper calibration after connecting, offering an arm session at launch/wake, the optional arm startup route and the inspection camera's pan. They also retain status and Stop + hold.

The sandbox catalog contains these independent test items:

| Test | Actions |
| --- | --- |
| Recycle can | Run the physical test, search with the neck camera, preview the grasp |
| Grip and return | Complete the supervised left-arm object handoff |
| Stationary gripper setup | Explicitly set up empty grippers while hanging and inactive |
| Arm preparation and return | Present/open, grip, release, inspect hanging, startup route, empty-arm return |
| Ghost motion rehearsal | Open the ghost editor, preview a wave, open motion rehearsal |
| Body demonstration | Record, replay and front-arm greeting |
| Spoken feedback | Test the spoken warning without arm movement |

Status is shared across the sandbox. The scrollable status area shows the complete pending operation scope; the spoken prompt remains **“Can I move my arms?”**. Stop + hold stays available regardless of the selected test.

## Startup gripper setup

**Calibrate empty grippers after connecting** is enabled by default. The first authenticated Amber connection after app launch starts stationary setup. Both arms must have fresh, advancing feedback and be stationary, hanging and inactive. Setup reserves both arms, calibrates the jaws serially, waits for calibration settling, then commands the established gentle close/open initialization. It does not raise the arms or turn on arm holding torque.

Keep both jaws empty and clear during startup. Amber acknowledges command dispatch; Cerebro does not have measured jaw opening or calibration completion. Stop prevents subsequent setup commands, but an already accepted vendor calibration may finish. Sleep, connection loss, ownership loss or invalid feedback cancels setup. A reconnect does not silently replay the startup sequence or restore a motion authorization.

If startup setup was deferred because the arms were not hanging, recycling can complete the same stationary setup after parking the empty arm, within the selected task. The sandbox's separate stationary setup item supports explicit inspection and testing. It is not a mandatory arm-raising preparation step.

## A supervised test session

1. Start the 15-minute left-arm session and give one real on-device spoken or authenticated controller approval.
2. Choose a test and save its parameters. Start the selected operation.
3. Observe actual clearance, jaw opening and the result. Use Stop + hold when needed.

Starting a session only requests the bounded authorization. It does **not** automatically run Present/open, raise the arm or repeat gripper calibration. Recycling owns its own necessary presentation and grasp path. Present/open remains available as an explicit preparation test.

One active session covers its included routines and waypoints; there are no extra approvals for each arm segment. Neck-only search and hanging inspection need no arm authorization. Returning an empty arm along its registered route to hanging also needs no new approval. Stop, expiry, sleep/restart, ownership loss or failed motion ends the session. A typed sandbox command never supplies spoken approval.

## Recycling parameters

Test timing parameters are saved in `~/Library/Application Support/Cerebro/TestingSandbox/recycling.json` and snapshotted for the next run. Editing is disabled during an active or pending operation, including startup jaw setup.

| Parameter | Default | Supported range |
| --- | --- | --- |
| Motion pace | 1.25× | 1.0–1.25× |
| Jaw settling time | 1.5 seconds | 1.0–2.0 seconds |
| Maximum path adjustment | 3 mm | 0–5 mm |

Pace reduces extra timing padding while retaining the existing motion-duration minimum. Path adjustment can join nearby travel segments after checking the resulting route against the original path, robot model, tread clearance and horizontal-jaw limits. It preserves the registered presentation route, jaw action boundaries and their neighboring targets. Zero path adjustment disables segment joining.

On the regression fixture, the default parameters produced **33 motion steps instead of 48**, with **26.869 seconds instead of 37.369 seconds of scheduled motion**. These are compiled-plan measurements. They are not measured physical execution times, and exclude camera search, planning, jaw settling, calibration and feedback waits.

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

## Adding a test

`ROBTestingSandboxWindowController` owns the test catalog, its parameter forms and actions. Add a catalog entry with a stable test identifier, description and supported actions; add the appropriate bounded parameter form when needed. Physical actions continue through `ROBArmRoutineCoordinator.performCommand`, with the existing runtime approval, ownership, feedback and Stop behavior. Keep persistent behavior preferences in `ROBArmRoutineSettingsViewController` and changing commissioning tests in this window.
