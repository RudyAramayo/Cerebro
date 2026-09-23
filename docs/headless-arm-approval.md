# Headless arm authorization

Arm operations requested by Cerebro are approved on the connected **Vision Pro
or iPhone controller**. The droid does not open an arm activation, deactivation,
gripper, gesture, or CAN/core recovery confirmation dialog. Enable **Action
Approvals** on the paired controller. Its existing panel shows the immutable
operation summary and Approve, Reject, and Cancel controls.

One approval covers the entire startup, prepare, grab/hold, or relax sequence:
mode entry, all taught arm waypoints, both gripper calibrations when needed, and
the intended final action. Relax returns along the taught route to measured
hanging before deactivating. No additional approval is requested per waypoint
or per gripper. The startup preference requests approval after launch/wake;
it does not grant unattended motion authority.

Diagnostics and legacy Torso controls use the same controller approval service.
Arm side, targets, selected gesture and gripper intensity are captured before
review. Gateway session and hardware interlocks are checked again on acceptance.
The LIVE Startup Test button uses the existing controller-owned startup lane.
The local Gemini debug checkbox no longer bypasses controller approval.
An authenticated Vision controller's fresh gripper intent with both grip buttons
held is already an explicit operator command and needs no desktop grant.

Read-only queries and Stop + hold remain immediate. Cancelling an active arm
operation requests hold; it does not release torque. The fixed CAN/core recovery
script, once begun, is allowed to finish its recovery steps rather than being
killed halfway through CAN setup. Cancellation cannot claim that physical
stopping was verified. The gripper API has no stop command or measured jaw force;
calibration/control acceptance is reported as unverified mechanical completion.

## Transport and failure behavior

The existing `com.orbitusrobotics.robot-action` v1 envelope now supports
`arm_operation` with exactly `operation`, physical `arm`, and `summary` fields.
This is a Cerebro-created request; it is excluded from model-proposable actions.
Both controller apps advertise this capability and leave execution and terminal
hardware outcomes to Cerebro.

The broker receives messages only after the control transport authenticates an
operator. It targets the most recently available compatible controller and binds
approval to its device, transport session, sender identity, recipient, and unique
call ID. A duplicated or late Accept cannot start another run. A replacement
session cannot reuse approval. There are no saved broad grants.

If no compatible controller enables approvals within 30 seconds, the request
ends without arm dispatch. A delivered request expires after 30 seconds. A
disconnect, withdrawn opt-in, or missing controller hello for 15 seconds cancels
pending work and requests hold for active work. Execution has a 120-second outer
limit; the arm routine retains its stricter 90-second bound. Rejection or expiry
does not silently queue an operation for later execution.

## Validation

- `bash Scripts/test-controller-arm-approval.sh`: production broker and wire
  protocol, with hardware-free tests for identity/session binding, replay,
  rejection, timeout, disconnect, opt-in withdrawal and gateway generation changes.
- `bash Scripts/test-arm-routines.sh`: production routine with simulated
  controller approval, gateway acknowledgements, cameras and measured settling.
- `python3 Tests/ROBAmberManualAdmissionRuntimeTests.py`: actual Objective-C
  dispatch method with a simulated approval console and harmless process runner.
- Controller protocol fixtures and Vision `RobotSessionActionApprovalTests`
  verify that approval does not assert physical completion.

The three apps must be updated together. Older controllers do not advertise
`arm_operation` and cannot authorize these new requests. Build/fixture validation
does not substitute for a supervised device-to-robot trial.

### 2026-09-23 validation and installation

The signed macOS, iOS and visionOS builds passed. The 37 broker checks, arm
routine fixtures, manual SDK admission/cancellation fixtures, arm/gripper routing
fixtures, stage/Gemini protocol fixtures and iPhone protocol fixtures passed.
The Vision package passed 121 tests, including the three Cerebro-owned approval
lifecycles. No live arm motion was requested during this change.

Installed and reopened `/Applications/Cerebro.app`; its Arms settings display
the controller approval policy and startup calibration remains off. Installed
ROBController on Onix16. Installation on Onix11 was blocked because the device
was locked; the Vision Pro was unavailable. Their builds are ready for deployment.
Installed Cerebro executable SHA-256:
`3e55a22e4098eaaee90dea5c6b6f0ce1e05d9147bdcf0d76fb27f6cfdef2b404`.
