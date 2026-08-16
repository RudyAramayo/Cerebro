# Amber gateway development deployment

This first deployment keeps both vendor `amber_core` processes unchanged. The
gateway is a persistent adapter between Cerebro and their existing interfaces:

```text
Cerebro -- TCP through SSH --> rob_amber_gateway.py
                                  |-- UDP cmd 4 trajectory --> amber_core L/R
                                  |-- UDP cmd 10/110 mode --> amber_core L/R
                                  |-- UDP cmd 7 gripper calibration --> amber_core L/R
                                  |-- UDP cmd 9 gripper release/hold --> amber_core L/R
                                  `-- LCM ArmStatus <---------- amber_core L/R
                                                              |
                                                           CAN10/CAN11
```

Trajectories continue through the Amber duration-controlled Ruckig path. The
gateway now owns verified inactive, active, and position-mode transitions, but
does not write `launch.json`, publish raw `PosCmd`, or alter
velocity/acceleration/jerk limits.

## Files to transfer

Copy the complete directory from the development Mac:

```text
/Users/rob/dev/Amber-HomeFolder/amber/rob_gateway
```

to this location on the Ubuntu computer:

```text
/home/amber/rob_gateway
```

For example, from the Mac, replacing the host with the Ubuntu computer's
address:

```sh
scp -r /Users/rob/dev/Amber-HomeFolder/amber/rob_gateway amber@amber-master.local:/home/amber/
```

Do not copy the archived `/etc`, SSH keys, shell history, or the complete home
folder back to the robot. Only transfer `rob_gateway`.

## 1. Verify the existing controllers

Log into Ubuntu and confirm both vendor cores and CAN interfaces are already
healthy before installing anything:

```sh
ssh amber@amber-master.local
ip -details link show can10
ip -details link show can11
pgrep -af 'amber_core_L|amber_core_R|amber_core'
ss -lunp | grep -E ':26001|:26002'
```

Do not start the gateway if `can10`, `can11`, port 26001, or port 26002 is
missing. Correct the existing Amber startup first.

## 2. Verify Python and LCM

The copied home folder already contained generated Python LCM types under
`/home/amber/sin_wave/lcmTypes`. Verify that the Ubuntu Python can import both
LCM and the generated status message:

```sh
python3 -c 'import lcm; print(lcm.__file__)'
PYTHONPATH=/home/amber/sin_wave python3 -c 'from lcmTypes.armStatus_t import armStatus_t; print(armStatus_t)'
```

If the first command fails, use the same distribution package or Python
environment that the existing Amber sine-wave demo uses. On a standard Ubuntu
22.04 installation the package is normally installed with:

```sh
sudo apt update
sudo apt install python3-lcm
```

Do not replace the working system Python or vendor `lcmTypes` files.

## 3. Install a gateway token

Create a random token readable only by root and the `amber` service account:

```sh
sudo install -d -o root -g amber -m 0750 /etc/rob-amber-gateway
openssl rand -hex 32 | sudo tee /etc/rob-amber-gateway/token >/dev/null
sudo chown root:amber /etc/rob-amber-gateway/token
sudo chmod 0640 /etc/rob-amber-gateway/token
sudo cat /etc/rob-amber-gateway/token
```

Copy the displayed token into a password manager for the initial Cerebro test.
Do not place it in the Cerebro repository, a show document, shell history, or a
command-line argument on the robot.

The development gateway binds only to `127.0.0.1`. Its token therefore crosses
an SSH tunnel, not the unencrypted robot LAN.

## 4. Run a foreground, telemetry-only test

Do not send a trajectory during this test. Start the gateway manually:

```sh
cd /home/amber/rob_gateway
LCM_DEFAULT_URL='udpm://239.255.76.67:7667?ttl=0' \
  python3 rob_amber_gateway.py --listen-host 127.0.0.1
```

Open a second Ubuntu SSH session and run:

```sh
TOKEN=$(sudo cat /etc/rob-amber-gateway/token)
python3 /home/amber/rob_gateway/test_gateway.py 127.0.0.1 7443 "$TOKEN"
unset TOKEN
```

Expected output is a `challenge`, a `ready` response, a heartbeat acknowledgement,
and telemetry for `left` and `right`. Verify that:

- `sequence` increases;
- `sample_age_ms` normally remains below 250 ms;
- each position, velocity, current, and status array has seven values;
- stationary joint velocities are near zero;
- no arm moves during this test.

Stop the foreground gateway with Control-C.

## 5. Install the systemd unit

```sh
sudo install -o root -g root -m 0644 \
  /home/amber/rob_gateway/rob-amber-gateway.service \
  /etc/systemd/system/rob-amber-gateway.service
sudo systemctl daemon-reload
sudo systemctl enable --now rob-amber-gateway.service
sudo systemctl status rob-amber-gateway.service
journalctl -u rob-amber-gateway.service -n 100 --no-pager
```

Confirm it remains loopback-only:

```sh
ss -ltnp | grep ':7443'
```

The listener should show `127.0.0.1:7443`, not `0.0.0.0:7443`.

Rollback is independent of the Amber cores:

```sh
sudo systemctl disable --now rob-amber-gateway.service
sudo rm /etc/systemd/system/rob-amber-gateway.service
sudo systemctl daemon-reload
```

### Updating an existing gateway install

The allowlisted synchronizer is the preferred way to install a reviewed
gateway update. Run the fake-only tests on the Mac first:

```sh
cd /Users/rob/dev/Amber-HomeFolder/amber/rob_gateway
python3 -m unittest -v test_rob_amber_gateway.py test_rob_amber_recovery.py

cd /Users/rob/dev/Amber-HomeFolder
./scripts/amber-sync.sh push-gateway --restart
./scripts/amber-sync.sh check
```

`push-gateway --restart` installs the reviewed files and restarts only
`rob-amber-gateway.service`; it does not restart `rc-local`, either Amber core,
or either CAN interface. Stop active gestures and controller leases first. The
restart deliberately invalidates the authenticated session, arm-mode cache,
targets, and both session-local gripper calibration acceptances, so reconnect
and query state before issuing another command.

## 6. Connect the SSH tunnel from Cerebro

The normal development path is now Cerebro's diagnostics window. First choose
**Development → Development Mode**, then open **Development → Amber Arm
Diagnostics…**:

1. Save the gateway token and the `amber` SSH password. Cerebro stores both in
   the macOS Keychain rather than user defaults or the repository.
2. Leave the SSH host as `amber-master.local` unless Bonjour is unavailable.
3. Choose **Connect Tunnel**. Cerebro creates the loopback-only SSH forwarding
   session and then authenticates `ROBAmberGatewayClient` to the gateway.
4. Confirm that the window reports **Ready · exclusive controller** and that
   both arms receive fresh telemetry before using any mode control.

The tunnel and gateway connection are deliberately operator-initiated; launching
Cerebro does not activate either arm or issue a mode command.

## 7. Recover the CAN/core stack from Cerebro

The diagnostics window includes **Restart CAN/Core Stack…** for the case where
one USB-CAN adapter or only part of an arm comes back after power-on. This is a
guarded maintenance operation, not an arm-motion command.

Install its reviewed Ubuntu side from the `Amber-HomeFolder` repository first:

```sh
cd /Users/rob/dev/Amber-HomeFolder
./scripts/amber-sync.sh push-gateway
./scripts/amber-sync.sh check
```

That deployment runs fake-only tests and installs a root-owned, no-argument
helper plus its exact sudoers rule. It does not invoke recovery, restart CAN,
restart either core, or activate either arm. Do not broaden the sudoers command
or invoke a script from `/home/amber` through passwordless sudo.

To recover from the GUI:

1. Physically support both arms, clear the workspace, and keep the physical
   E-stop ready. Recovery interrupts torque and feedback.
2. Ensure no gesture or manual command is active and that the Amber SSH password
   has been saved in Keychain.
3. Choose **Restart CAN/Core Stack…** and type the exact confirmation `RESTART`.

Cerebro rechecks the motion interlocks after the confirmation dialog, revokes
all temporary Gemini/controller authority, disconnects the gateway tunnel, and
then asks Ubuntu to perform one fixed ordered recovery. Ubuntu verifies the
protected startup files and both expected USB serial adapters before stopping a
healthy stack. It then stops gateway → CAN/cores, requires a clean baseline,
starts CAN/cores once, verifies both links/processes/UDP listeners and clean
advancing counters, and starts the loopback-only gateway. Any partial failure
rolls back and remains disconnected; there is no automatic retry. A verified
success reconnects telemetry but does not activate an arm, enter position mode,
or restore debug authority.

The helper contract, root-ownership boundary, and non-actuating validation
commands are documented in
`Amber-HomeFolder/docs/amber-stack-recovery.md`. Never invoke
`/usr/local/sbin/rob-amber-recover` merely to test installation because invoking
it performs the real restart.

For troubleshooting, the equivalent manual tunnel from the Mac is:

```sh
ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=3 \
  -L 7443:127.0.0.1:7443 \
  amber@amber-master.local
```

Keep this session open during the development test. Cerebro connects to
`127.0.0.1:7443`; SSH transports it to the gateway's Ubuntu loopback listener.

## 8. Use the native gateway client

The diagnostics window manages this connection for normal supervised testing.
The underlying native client is `ROBAmberGatewayClient.shared`; another local
operator UI can connect using the token read during step 3:

```swift
ROBAmberGatewayClient.shared.connect(
    host: "127.0.0.1",
    port: 7443,
    token: tokenFromSecureOperatorConfiguration
)
```

Observe these notifications:

- `.ROBAmberGatewayStateDidChange`
- `.ROBAmberGatewayTelemetryDidUpdate`
- `.ROBAmberGatewayGripperDidUpdate`
- `.ROBAmberGatewayCommandDidComplete`

Queue-consistent telemetry, target, and verified-mode snapshots are available
through `telemetry(forArm:)`, `targetPositions(forArm:)`, and `modes(forArm:)`.
Each telemetry sample contains joint position, velocity, current, status,
sequence, and age.

The native mode calls are:

```swift
let queryID = ROBAmberGatewayClient.shared.queryMode(forArm: "right")
let activateID = ROBAmberGatewayClient.shared.activateArm("right")
let positionID = ROBAmberGatewayClient.shared.enterPositionMode(forArm: "right")
let holdID = ROBAmberGatewayClient.shared.holdCurrentPosition(forArm: "right")
let deactivateID = ROBAmberGatewayClient.shared.deactivateArm("right")
```

Supervised Vision and named-gesture execution use the gateway-owned lease APIs:

```swift
let moveID = ROBAmberGatewayClient.shared.sendLeasedTrajectory(
    arm: "right",
    positionsRadians: target.map(NSNumber.init(value:)),
    duration: 0.65,
    leaseMilliseconds: 1_000
)
let renewID = ROBAmberGatewayClient.shared.renewLease(
    forArm: "right",
    leaseMilliseconds: 1_000
)
let priorityHoldID = ROBAmberGatewayClient.shared.priorityHold(forArm: "right")
```

`renewLease` extends only the existing gateway watchdog; it does not replay or
change the physical target. A leased trajectory is held from a newly measured pose
when its receipt-time monotonic deadline expires, Cerebro disconnects, the heartbeat
expires, or the gateway shuts down. A priority hold is successful only when its
acknowledgement contains `hold_confirmed:true`; the gateway never activates or
changes mode merely to make a hold possible.

Every nonzero ID identifies an asynchronous request whose result arrives through
`.ROBAmberGatewayCommandDidComplete`. A zero ID means the client rejected it
locally. These methods do not run automatically at application startup.

The native gripper calls use the same authenticated, exclusive gateway session:

```swift
let stateID = ROBAmberGatewayClient.shared.queryGripperState(forArm: "right")
let calibrationID = ROBAmberGatewayClient.shared.calibrateGripper(forArm: "right")
let releaseID = ROBAmberGatewayClient.shared.controlGripper(
    forArm: "right", action: "release", force: 5
)
let holdID = ROBAmberGatewayClient.shared.controlGripper(
    forArm: "right", action: "hold", force: 10
)
let snapshot = ROBAmberGatewayClient.shared.gripperSnapshot(forArm: "right")
```

An accepted calibration acknowledgement means only that the Amber core
accepted vendor command 7 for dispatch. The snapshot therefore remains
`calibrationVerified:false` and `feedbackAvailable:false`, with
`calibrationState:"command_accepted_unverified"`. `lastAction` and `lastForce`
are acknowledged commands, not measured jaw state or force. A zero command ID
means local validation rejected the request.

`gripperSnapshot(forArm:)` and `.ROBAmberGatewayGripperDidUpdate` use the same
camel-case fields: `arm`, `calibrationState`, `calibrationVerified`,
`feedbackAvailable`, `commandInFlight`, `lastAction`, `lastForce`, `forceMin`,
`forceMax`, `forceUnit`, `supportedActions`, and `detail`. The notification
provides those fields both flat and under `snapshot`. Gripper command-completion
notifications additionally provide `operation`, `commandID`, `accepted`,
`amberResponse`, `latencyMilliseconds`, `calibrationCommandAccepted`,
`completionVerified`, and `error`, plus `action`/`force` for control requests.

## 9. First supervised gripper test

Calibration can move the gripper through its travel. Clear hands and objects
from the jaw, keep the physical E-stop available, and test only one gripper at
a time:

1. Connect in **Amber Arm Diagnostics…** and choose **Query** for the selected
   gripper. This query performs no Amber UDP or physical I/O.
2. Choose **Calibrate…** and accept the critical confirmation. Require an
   accepted `gripper_calibrate_ack`; the UI must still say that completion is
   unverified, never that calibration was measured or complete.
3. Start with the diagnostics range 2–20 vendor intensity units. Issue one
   **Release** or **Hold** and require an accepted `gripper_control_ack`.
4. Observe the mechanism directly. The current arm telemetry does not report
   gripper opening, applied force, endpoint, object detection, or calibration
   completion.
5. After a gateway reconnect, heartbeat expiry, restart, or power cycle, query
   again and recalibrate deliberately before another control command.

Amber documents raw intensity 1–300, but the diagnostics and Vision paths use
the smaller 2–20 envelope exercised by the vendor dashboard. The units are not
newtons. There is no evidence-backed stop/cancel primitive; **Release** is a
motion command and is not a substitute for stop. Never auto-calibrate, retry an
ambiguous acknowledgement, or infer success from elapsed time.

## 10. First controlled arm movement test

Perform this only after telemetry has remained live and fault-free:

1. Remove the saber prop.
2. Support the arm or place it at a safe initial pose, clear the workspace, and
   use the physical E-stop operator. The vendor warns that switching modes
   momentarily cuts actuator power; gateway pose capture does not eliminate
   that physical behavior.
3. Enable **Development → Development Mode**, open **Amber Arm Diagnostics…**,
   select one arm, and choose
   **Query Mode**. This is the first read-only physical verification of the new
   mode-query path.
4. Choose **Activate…** and acknowledge the torque-cut warning, then choose
   **Position + Hold…** and acknowledge it again. The latter verifies active
   mode, captures a new measured pose, verifies position mode, and sends that
   captured pose as the initial hold target.
5. Use **Capture Left/Right Measured → Keyframe** so the editable pose starts
   from feedback rather than stale slider values.
6. In the arm keyframe editor, request a very small change to one joint with a
   long duration. Return to diagnostics, approve that immutable pose under a
   clear name, enable the 15-minute Gemini hand-movement authority, and use
   **Run Selected Gesture…** for the deterministic GUI test. The supervised
   executor permits at most 0.35 radian per joint and 0.25 radian/second average,
   in addition to the gateway's joint bounds.
7. Require a positive `leased_trajectory_ack` and measured completion, and observe
   position, velocity, current,
   status, sample age, and tracking error.
8. Return to the starting position using another bounded trajectory or choose
   **Hold Measured Pose**.
9. During a small leased move, release the Vision dead-man and verify a confirmed
   measured hold. Repeat only in the clear with a deliberate Cerebro disconnect and
   confirm the gateway's independent lease/heartbeat watchdog requests a hold.

Use **Deactivate…** only while the arm is physically supported. Deactivation can
remove holding torque and allow the arm to fall; the physical E-stop remains the
authoritative stop.

The native supervised call is:

```swift
let commandID = ROBAmberGatewayClient.shared.sendLeasedTrajectory(
    arm: "right",
    positionsRadians: target.map(NSNumber.init(value:)),
    duration: 0.65,
    leaseMilliseconds: 1_000
)
```

A return value of zero means the client rejected the request locally. The
gateway independently enforces seven finite positions, robot-specific joint
bounds (J1 ±2.4435, J2 ±2.3213, J3–J6 ±2.2863, and J7 ±3.05 radians), a duration
from 0.65 through 10 seconds, a 700–1,500 ms gateway lease, monotonic command IDs,
and a fresh heartbeat. The Amber core then applies its own limits and Ruckig
profile. The non-leased `sendTrajectory` API remains a local diagnostics primitive;
Vision and approved gestures must use leased execution.

## 11. Characterize speed before modifying limits

Run the same small joint displacement with progressively shorter durations,
keeping `launch.json` unchanged. For every run record:

- requested duration;
- gateway acknowledgement latency;
- time until motion begins;
- peak reported joint velocity;
- peak current;
- completion time and final error;
- status values and maximum telemetry age.

If peak velocity stops increasing while requested duration decreases, the
trajectory is hitting a configured or drive limit. If velocity rises slowly and
the move completes without approaching the velocity ceiling, the active
`Max_Jerk: 5000` profile is a likely constraint. Do not edit jerk and velocity in
the same trial: changing one variable at a time is necessary to identify the
actual limiter.

## Current development limitations

- Transport authentication uses a bearer token inside SSH rather than native
  TLS. Keep the gateway loopback-only.
- Commands are joint-space trajectories. Cartesian commands will be added after
  joint telemetry and command acknowledgements are verified.
- The gateway permits one authenticated controller TCP session. A second
  session cannot receive telemetry, query modes, or race commands; close the
  first Cerebro/SSH-tunnel connection before transferring ownership.
- Heartbeat expiry clears session-local gripper calibration acceptance and
  backstops active leased arm trajectories with the gateway's measured-pose
  hold. It cannot cancel a gripper command Amber already accepted because the
  vendor protocol exposes no gripper stop primitive. The physical E-stop
  remains authoritative.
- Only one Cerebro operator should connect during this phase.
- The existing Amber core is binary-only in the supplied home folder, so the
  gateway cannot prove the units or implementation of every configuration
  parameter.
