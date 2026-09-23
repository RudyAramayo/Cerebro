# Right-arm command failure, September 22, 2026

The operator reported that the physical right arm stopped responding near the
end of a manual pose setup. Both USB adapters continued pulsing rapidly. Robot
commands remained on hold during this investigation. Initial evidence came
from Cerebro's existing UI, local macOS logs, and the shipped Python resources;
the operator then authorized read-only SSH diagnostics and passive CAN capture.
Times are local PDT. The physical right arm is L10, UDP port 26001.

## Observed failure

- At 19:31:14, the manual position script requested J6 = 1.395038 rad while
  its preceding controller readback reported J6 = 1.135963559 rad. Repeated
  requests through 19:31:59 included J6 = 1.603285 and 1.560260 rad; the
  returned seven-joint position vector remained identical. Mode replies still
  reported all seven joints in position mode. These replies prove controller
  communication at those times, not fresh communication with every motor.
- At 19:32:15 and again at 19:32:45/19:33:05, Deactivate failed with
  `AttributeError: 'Amber_Robot' object has no attribute 'set_inactive_mode'`.
  At 19:32:20, Activate failed for the corresponding `set_active_mode` method.
  Neither requested mode change was sent by those failed scripts.
- The local log recorded an L10 shutdown task at 19:32:35, and the existing
  right-arm console contained another core startup banner. Subsequent mode
  readbacks included `[2, 0, 0, 0, 0, 0, 0]`, `[0, 0, 0, 0, 0, 2, 2]`, and,
  by 19:35:51, `[2, 2, 2, 2, 0, 0, 0]`.
- Cerebro's process remained running. The most recent macOS Cerebro crash
  report at inspection was from 18:46, preceding this incident.

The exact frozen controller vector was approximately
`[0, -0.207121417, 0.922706187, -0.560959518, 0.556323528, 1.135963559, 0]`.
It is historical readback, **not a verified current pose or a replay target**.
The saved “R arm almost up” keyframe contains requested slider values and a
higher J6 target; it must not be mistaken for a measured achieved pose.

## Confirmed software defects and correction

The app's `amber_api.zip` and the repository copy were identical (SHA-256
`b71344a1110edf825d7492d167d695ceb38884d94818596e31e096eb6c9823c3`). Its
`Amber_Robot` class has `set_mode`, but neither activation convenience method.
The unbundled SDK tree differs, so checking only that tree misses the defect.

The manual mode scripts now use the bundled `set_mode` API, require its
acknowledgement, and poll for all seven expected mode values. Position/current
transitions stop if the preceding active-mode transition is incomplete. They
do not automatically retry a mode-changing packet, deactivate on failure, or
send any pose. The vendor convenience functions previously continued after
their active-mode wait failed.

Manual joint-position commands now reject mixed modes and invalid numeric
inputs, recheck modes before sending, and report SDK rejection or missing
acknowledgement as failures. An acknowledgement is explicitly not described as
proof of physical motion. Python failures appear in the appropriate arm's
existing console as well as the macOS log.

`Tests/ROBAmberManualCommandTests.py` runs the actual scripts against the
actual bundled SDK with a fake UDP socket. It covers both arms' port routing,
mode sequencing, partial modes, readback failure, lost acknowledgements,
invalid targets, and rejection without automatic retry. No hardware is used.

## Authorized read-only Amber inspection

At 19:42:20 and 19:43:50, both core processes and the gateway were running.
The kernel journal records a segmentation fault in `amber_core_L` at 19:35:25,
during the later controller-stack restart. This is after the initial 19:31
feedback freeze, so it does not by itself explain the original failure.

Each of two independent two-second passive captures showed:

- Right/can10: **no `0x91` receive frames**; IDs `0x92` through `0x98`
  each supplied approximately 400 frames. The controller was still transmitting
  the command stream for servo 1 (`0x11`).
- Left/can11: IDs `0x91` through `0x98` each supplied approximately 400 frames.
- The exposed interface error/drop counters remained zero. These counters
  did not reveal the missing servo; aggregate USB/CAN activity is insufficient.

The deployed core's `canRecv::convertfromCan` subtracts `0x90` from the CAN
identifier, confirming that the absent `0x91` feedback belongs to actuator 1.
The inspected binary matches SHA-256
`554e7088b94b98f03f152f394c5e5b1d1ecfd16dacd470889e65dc83c36d2100`.
No CAN/UDP packets, mode changes, restarts or position commands were sent by
these diagnostics. The operator reported a cable interruption and replugging.

## Feedback returned after the operator's reboot

The operator later confirmed that right servo 1 did not respond while servos
2–7 still moved. After opening the robot, they observed red LEDs on servo 1 of
both arms; after rebooting, those LEDs were blue.

At 19:58:38, a new two-second passive capture received 401 `0x91` frames on
right/can10 and 400 on left/can11. Every actuator feedback ID `0x91`–`0x98`
was present on both interfaces at approximately 200 Hz. Interface error/drop
deltas were zero. The final payloads were `ff00000000000000`; these frames
establish restored communication in that sample, not verified position,
motion, calibration, or continued reliability. The diagnostic sent zero CAN
or UDP commands and performed no restart.

## Reversed gripper controls

The operator reported that Left gripper control moved the physical right
gripper and Right gripper calibration moved the physical left gripper. The
Diagnostics window had interpreted the gateway's legacy `left`/`right` core
keys as physical robot sides. On this installation, `left` is L10/can10/UDP
26001 on ROB-right; `right` is R11/can11/UDP 26002 on ROB-left.

Diagnostics now converts physical sides at the gateway boundary for commands,
telemetry, gripper snapshots, mode controls, targets, and measured keyframe
capture. Labels and action confirmations include the physical side, core,
and UDP port. The Vision gripper bridge uses the same conversion for commands
and state. The gateway protocol, core configuration, and stored keyframe keys
are unchanged. Hardware-free fixtures exercise both directions, independent
per-side calibration gates, and acknowledgement/state routing.

## Updated app connection verification

The signed app was rebuilt and installed at its existing development app path.
At 20:44:15, Diagnostics authenticated successfully through the SSH tunnel and
reported an exclusive gateway session. Both physical-side telemetry streams
were arriving at approximately 20 Hz. Explicit mode queries at 20:44:40 and
20:44:51 reported all seven joints inactive on ROB-left/R11 and ROB-right/L10,
respectively. These checks sent read-only mode/gripper-state queries, with no
activation, position, or gripper-actuation commands.

The app also fixes an initial TCP refusal race while SSH is still opening its
local port. Real loopback Network.framework fixtures passed delayed-listener
recovery, disconnect cancellation, and bounded failure. Compatibility and
physical-side routing fixtures passed, as did the signed macOS build. The
diagnostic display now redraws at 2 Hz while retaining every received sample.

## Still unresolved

These defects explain the ineffective Activate/Deactivate buttons and the
unreported partial mode transitions. They do **not** establish why motor
feedback originally froze or whether the missing servo feedback will recur.
The operator subsequently authorized takeover. App connection recovery and
passive feedback inspection have not yet established a calibrated pose or
validated a motion route. The new manual-mode guards verify what the controller
reports;
they do not turn its cached mode values into per-motor freshness evidence.
The camera calibration and folded endpoints must not bypass that distinction.

This side-mapping correction covers Diagnostics and the Vision gripper bridge.
Before commissioning automatic whole-arm control, audit the remaining raw
side-string boundaries in `ROBArmControllerBridge.swift`,
`ROBWakeUpCalibrationWindowController.swift`, and `ROBAmberArmReference.swift`.
They are not certified by the gripper routing fixtures. Existing reference
and verified-velocity gates remain closed; no live startup calibration or
folding route has been commissioned.
