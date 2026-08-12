# Amber gateway development deployment

This first deployment keeps both vendor `amber_core` processes unchanged. The
gateway is a persistent adapter between Cerebro and their existing interfaces:

```text
Cerebro -- TCP through SSH --> rob_amber_gateway.py
                                  |-- UDP cmd 4 + duration --> amber_core L/R
                                  `-- LCM ArmStatus <---------- amber_core L/R
                                                              |
                                                           CAN10/CAN11
```

Commands continue through the Amber duration-controlled Ruckig path. The
gateway does not write `launch.json`, change actuator modes, publish raw
`PosCmd`, or alter velocity/acceleration/jerk limits.

## Files to transfer

Copy the complete directory from the development Mac:

```text
/Users/rob/dev/AmberHomeFolder/amber/rob_gateway
```

to this location on the Ubuntu computer:

```text
/home/amber/rob_gateway
```

For example, from the Mac, replacing the host with the Ubuntu computer's
address:

```sh
scp -r /Users/rob/dev/AmberHomeFolder/amber/rob_gateway amber@10.0.0.5:/home/amber/
```

Do not copy the archived `/etc`, SSH keys, shell history, or the complete home
folder back to the robot. Only transfer `rob_gateway`.

## 1. Verify the existing controllers

Log into Ubuntu and confirm both vendor cores and CAN interfaces are already
healthy before installing anything:

```sh
ssh amber@10.0.0.5
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

## 6. Create the SSH tunnel from the Mac

From the Mac running Cerebro:

```sh
ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=3 \
  -L 7443:127.0.0.1:7443 \
  amber@10.0.0.5
```

Keep this session open during the development test. Cerebro connects to
`127.0.0.1:7443`; SSH transports it to the gateway's Ubuntu loopback listener.

## 7. Connect Cerebro

The native client is `ROBAmberGatewayClient.shared`. During initial integration,
connect using the token read during step 3:

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
- `.ROBAmberGatewayCommandDidComplete`

Telemetry is also available as `leftTelemetry` and `rightTelemetry`. Each sample
contains joint position, velocity, current, status, sequence, and age.

The client intentionally has no automatic connection or command migration yet.
The existing Stage Show arm path remains active until the gateway is verified on
the physical robot.

## 8. First controlled movement test

Perform this only after telemetry has remained live and fault-free:

1. Remove the saber prop.
2. Clear the workspace and use the physical E-stop operator.
3. Put the selected arm in its normal position mode using the established Amber
   procedure.
4. Record the current seven joint positions from gateway telemetry.
5. Request a very small change to one joint with a long duration.
6. Require a positive `trajectory_ack` and observe position, velocity, current,
   status, sample age, and tracking error.
7. Return to the starting position using another bounded trajectory.
8. Disconnect Cerebro and confirm the gateway stops accepting commands after
   its 2.5-second heartbeat deadline.

The native call is:

```swift
let commandID = ROBAmberGatewayClient.shared.sendTrajectory(
    arm: "right",
    positionsRadians: target.map(NSNumber.init(value:)),
    duration: 3.0
)
```

A return value of zero means the client rejected the request locally. The
gateway independently enforces seven finite positions, an absolute ±3.10-radian
bound, a duration from 0.65 through 10 seconds, monotonic command IDs, and a
fresh heartbeat. The Amber core then applies its own limits and Ruckig profile.

## 9. Characterize speed before modifying limits

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
- Heartbeat expiry rejects new commands but does not currently issue an
  undocumented Amber stop command. The physical E-stop and established Amber
  deactivation procedure remain authoritative.
- Only one Cerebro operator should connect during this phase.
- The existing Amber core is binary-only in the supplied home folder, so the
  gateway cannot prove the units or implementation of every configuration
  parameter.
