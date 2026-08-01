# Cerebro

Cerebro is the macOS controller and operator interface for the R.O.B. droid.

<img width="2393" height="1063" alt="Screenshot 2025-08-05 at 3 58 58 PM" src="https://github.com/user-attachments/assets/951fcac3-bdcf-470d-927f-fce3f94018d1" />

## Python environment

Cerebro no longer assumes a developer-specific Python path. Open **Settings…**
from the button in the main window title bar or press **Command-,**
to configure the interpreter used by the DepthAI RGB-D service and bundled
Amber arm scripts.

The settings window can:

- select a Python 3.9+ executable or a virtualenv/Conda environment directory;
- use an automatically detected interpreter;
- create an app-managed virtual environment under
  `~/Library/Application Support/Cerebro/PythonEnvironment`;
- install or update the packages declared in
  `Cerebro/PythonRequirements.txt`; and
- validate both Python and the required `depthai` import. The camera service is
  pinned to DepthAI `3.8.0`, whose unified `Depth` node supplies aligned depth.

Package installation only occurs after the operator clicks an install/create
button. If a saved interpreter is deleted or inaccessible, Cerebro keeps
running, skips the affected Python task, and opens Python Settings instead of
raising an `NSTask` launch-path exception. Changing environments restarts the
RGB-D service with the new interpreter. The bundled `amber_api.zip` is added to
`PYTHONPATH` for arm scripts; compatibility between that vendor API and each
robot firmware/script remains a separate runtime requirement.

## Luxonis RGB-D camera

The old camera host exposed one RGB stream through UVC/AVFoundation, so it
could never deliver the OAK camera's calibrated depth image. Cerebro now runs
the DepthAI SDK in a supervised Python helper and receives timestamp-synchronized
RGB plus depth aligned to RGB over a local, user-only Unix socket. RGB enters
the existing `CMSampleBuffer`/Vision/Gemini path. Depth is available in the
same `CameraFrameSet` as little-endian `UInt16` millimeters; zero is invalid.

Keeping DepthAI outside the Cerebro process is deliberate. A missing device,
USB disconnect, SDK exception, malformed IPC packet, or helper termination is
reported as camera state and retried with bounded backoff rather than crashing
robot control. `CameraManager` drops old frames while perception is busy and
retains AVFoundation as an RGB-only fallback for ordinary webcams. Legacy OAK
UVC fallback is explicit opt-in so it cannot race the SDK for exclusive device
ownership. Enabling that legacy option disables the DepthAI helper; only one
provider owns the OAK device at a time.

The integration targets Luxonis DepthAI `3.8.0`, the current stable release as
of 2026-08-01. See [Luxonis RGB-D integration](docs/depth-camera.md) for the
protocol, provider behavior, hardware validation checklist, and the tradeoff
between the current helper and a future native C++/XPC implementation.

## Vision Pro camera streaming

Cerebro can now vend the live RGB camera to a paired Vision Pro controller on
the separate `_robvideo._udp` / `robvideo/1` TLS 1.3 QUIC service. The initial
profile is H.264 AVCC over an ordered reliable stream, capped at 960 x 540,
20 frames per second, and 1.5 Mbps. Encoding starts only after an authenticated
operator requests a stream tied to that operator's currently live
`_robctl._udp` session.

Video has its own network connection, queue, framing, authentication domain,
and bounded send state, so a slow viewer cannot queue camera frames onto the
robot-control path. Camera delivery keeps only the newest pending source frame;
when the media sender falls behind, Cerebro drops unencoded raw frames without
building a backlog. Encoder drops and receiver recovery requests force a new
key frame. See [Vision Pro video transport](docs/vision-pro-video.md) for the
wire contract and the remaining Vision Pro adapter work.

## System tools

At launch, Cerebro also checks for `sshpass`, which is required by the existing
Amber password-authenticated SSH controls. It searches the GUI process `PATH`
and both supported Homebrew locations (`/opt/homebrew` on Apple Silicon and
`/usr/local` on Intel). If `sshpass` is missing but Homebrew is already
installed, Cerebro asynchronously runs `brew install sshpass`; the official
formula is documented at <https://formulae.brew.sh/formula/sshpass>.

Cerebro does not silently bootstrap Homebrew itself. When Homebrew is missing,
the Amber log connections are skipped without crashing and **Settings…** shows
the unmet prerequisite with a link to the official installer. Once installation
finishes, pending Amber SSH operations continue with the resolved executable.
The SSH login password is supplied to `sshpass` through an anonymous pipe
instead of the process argument list. SSH connection attempts also use bounded
connect and keepalive settings so an unreachable robot does not wait forever.

The optional Pololu `ticcmd` controls likewise validate the executable and
report an unavailable tool instead of raising an `NSTask` exception. A custom
path can be supplied with the `ROBTiccmdExecutablePath` user default.
The optional RPLidar companion app is resolved from `/Applications`, the
operator's `Applications` directory, or `ROBRPLidarApplicationPath`; if absent,
its periodic launcher is skipped safely.

Every compiled subprocess launch uses the same final preflight: the executable
path must be absolute, present, not a directory, and executable immediately
before launch. Launch failures and legacy `NSTask` exceptions are converted to
recoverable errors, so a missing optional dependency disables only its feature
instead of terminating Cerebro.

The current development integration streams microphone audio and sampled
camera frames to `gemini-robotics-er-2-streaming-preview`, then speaks completed
model turns through the existing `ROBSpeechBox` voice.

Camera and microphone streaming are disabled unless explicitly enabled with
`GEMINI_ROBOTICS_ENABLED=true` and a credential.

The optional, default-off `robot_action` tool is integrated with
`ROBRobotActionProtocol` v1. Cerebro places its versioned JSON action messages
inside the robot-control envelope. ROBController is the operator approval and
status console; Cerebro remains the hardware coordinator.
Only terminal action results return to Gemini, whose completed response is
spoken through the same `ROBSpeechBox` path.

For supervised action-protocol testing, set all of:

```text
GEMINI_ROBOTICS_ENABLED=true
GEMINI_ROBOT_ACTION_TOOL_ENABLED=true
GEMINI_API_KEY=<development key>
```

`GEMINI_EPHEMERAL_TOKEN` may replace the API key. Enabling the tool does not
enable motors: ROBController must also advertise that it accepts the requested
action.

The robot/controller control plane now defaults to `_robctl._udp`: a reliable
QUIC stream over UDP with TLS 1.3, an exactly pinned Cerebro certificate, and a
fresh challenge/proof using a 256-bit pairing secret. Identity and pairing
material are stored in Keychain.
The old `_roboNet._tcp` name and plaintext UDP framing exist only in an explicit
legacy adapter and are disabled by default. There is no automatic downgrade.

On first launch, Cerebro creates its persistent transport identity and a
server-side device registry. Click **Manage Paired Devices…** below the camera
view and issue a new code for either an operator ROBController or a telemetry-only
RPLidar publisher. Use a fresh code for every device; each has an independent
ID, secret, role, and revocation record. The code is not logged or placed in
Bonjour. Bonjour advertises only the protocol version, ALPN, and non-secret
robot ID, so each client selects its paired robot rather than the first
discovered service.

The RPLidar app accepts only a `lidarPublisher` credential and sends typed scan
and map frames. Cerebro resolves the role from its own Keychain registry, so
editing the role in a copied pairing payload cannot grant control authority.
Revoking a device persists a tombstone, disconnects its live session, and does
not disturb unrelated paired devices.

The separate **Autonomy** control in ROBController authorizes one bounded
session instead of requiring approval for every planner tick or conversational
gesture. The `social_roam` profile uses fresh RPLidar scans, captures the
activation pose as the center of a designated radius, keeps tread speed low,
turns around nearby obstacles, and continues using the existing Gemini
camera/audio/SpeechBox loop to mingle. A manual control request or explicit
Autonomy stop ends the session. Cerebro restart also defaults to autonomy off.

`ROBSerialBox` now expires 5 Hz controller snapshots after three missed updates.
It writes one neutral/braked base frame and then stops USB writes, allowing the
existing Arduino heartbeat deadman to de-energize the treads instead of keeping
it alive with a stale nonzero command.

Picking and general arm motion remain reported as unavailable rather than
pretending success: the repository still lacks calibrated camera-to-arm
transforms, complete four-axis neck mapping, joint feedback, IK, collision
checking, and a verified grasp executor. The session and result protocols are
in place for those capabilities as they are added.

See [Gemini Robotics Live integration](docs/gemini-robotics-live.md) for setup,
configuration, protocol behavior, safety boundaries, and validation commands.
See [ROB control transport v2](docs/rob-control-v2.md) for pairing and migration,
and [controller-activated autonomy](docs/controller-activated-autonomy.md) for
the current behavior and the arm/servo integration roadmap.
