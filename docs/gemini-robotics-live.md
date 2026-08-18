# Gemini Robotics Live integration

## What is integrated

Cerebro now uses a persistent WebSocket session for
`models/gemini-robotics-er-2-streaming-preview`.

The media and response path is:

```text
ROBSpeechBox microphone tap
  -> copied hardware PCM
  -> bounded serial conversion to mono PCM16 at 16 kHz
  -> Gemini realtimeInput.audio

CameraManager main-camera sample buffer ─┐
                                         ├─> latest fresh views, fixed labeled 1024x1024 composite
Insta360 stitched preview JPEG ──────────┘   -> no more than 1 JPEG/second total
  -> Gemini realtimeInput.video

Gemini serverContent model text or outputTranscription
  -> coalesced through turnComplete
  -> ROBMainViewController
  -> on-screen ROB transcript
  -> existing [ROBSpeechBox sayIt:]
```

The implementation is intentionally half-duplex. While `ROBSpeechBox` is
speaking, microphone frames are withheld and `audioStreamEnd` is sent after the
already queued microphone frames. This prevents the robot's synthesized voice
from being sent back to Gemini before acoustic echo cancellation is available.

The existing on-device Apple speech recognizer remains active for local
transcription, wake handling, and local stop phrases. Its transcript is not
submitted again while the Gemini raw-audio session is ready, preventing
duplicate turns. When raw audio is disabled, the local transcript uses
`realtimeInput.text` immediately. Cerebro enables server-side input
transcription so `Gemini Robotics heard:` in the Xcode console confirms what
Gemini understood independently of Apple's local transcript.

The ER2 streaming preview returns spoken output through
`serverContent.outputTranscription` even when its accepted setup modality is
`TEXT`. Cerebro coalesces that transcription, waits for `turnComplete`, and
passes the completed reply to `ROBSpeechBox`. This preserves ROB's configured
system voice and existing half-duplex echo suppression. A missing response no
longer blocks every later request. Text turns retain a 15-second response-start
deadline and a 120-second absolute completion deadline. A locally recognized
raw-microphone turn is acknowledged immediately, sends an explicit audio-stream
boundary, and uses a six-second response-start deadline with a 45-second
absolute deadline. Cerebro retains that on-device transcript only long enough
to answer locally if Live times out or completes silently; it is never
submitted to Gemini as duplicate input.

Gemini Live exposes one realtime video blob rather than separately identified
camera tracks. Cerebro therefore sends one deterministic two-panel observation:
**MAIN FORWARD CAMERA** on top and **INSTA360 STITCHED 360 PANORAMA** below.
The labels and each panel's LIVE/WAITING/STALE/DISABLED state are burned into
the JPEG. Frames older than 2.5 seconds are never reused. The Insta360 decoder
is a headless service consumer while that source is enabled; opening its debug
window is not required.

The panorama can reveal people outside the forward camera's view. Its
robot-relative yaw begins uncalibrated, so Gemini is instructed not to call a
panorama region "behind" based on image position alone. An operator can set the
horizontal position of ROB's forward direction in **Settings → Perception**;
the composite then burns in FRONT and REAR markers. Horizontal handedness is
not calibrated; the neutral 90° and 270° ruler ticks remain image coordinates. Even after
calibration, neither camera is a range, clearance, or action-completion sensor.
Controller approval and local motion-safety systems remain authoritative.

Ordinary dialogue falls back in this order: Apple Foundation Models, native
Swift MLX, then a deterministic spoken recovery response. Local providers have
no robot-action tools and cannot enter a tread, servo, arm, or controller path.
Stage-show turns keep their existing authored/local cue fallback, and any turn
that produced a Gemini tool call is never replayed through a dialogue model.
Two provider failures inside 60 seconds temporarily divert new conversation to
local models for 90 seconds; a successful Gemini response or an operator
reconnect resets the circuit.

## Authentication

No Gemini credential should be committed to source code, the application
bundle, or an Xcode scheme. Cerebro reads a long-lived development key from the
macOS login Keychain when no credential environment override is present.

For a personal installation, open **AI Provider Control & Diagnostics**, paste
the Gemini key into the secure field, and choose **Save in Keychain**. Relaunch
Cerebro once so `ROBAI` can create the live session. A key installed through
this explicit in-app action enables Gemini without an Xcode scheme or launch
script. The UI never reads the secret back into a visible field.

Install the local key using the secure hidden-input helper:

```sh
./Scripts/set-gemini-api-key.sh
```

Managed and development deployments may keep an explicit enablement flag in
the Xcode scheme:

```text
GEMINI_ROBOTICS_ENABLED=true
```

`GEMINI_API_KEY` remains supported as an explicit environment override for CI
or isolated development, but it must not be saved in a tracked scheme.

For a deployed robot, prefer a backend-issued, model- and configuration-bound
ephemeral token:

```text
GEMINI_EPHEMERAL_TOKEN=<short-lived token>
GEMINI_ROBOTICS_ENABLED=true
```

When both are present, the ephemeral token takes precedence and Cerebro uses
the constrained WebSocket endpoint. Rotate the Gemini key that was previously
committed to `ROBAI.swift`; removing it from the current source does not revoke
it or erase it from Git history.

`GEMINI_EPHEMERAL_TOKEN` is currently read once when `ROBAI` is created. A
production deployment therefore needs a backend token provider and an in-app
refresh/reconnect path before relying on short-lived tokens continuously; the
current development path requires restarting Cerebro with a fresh token.

An environment credential still requires explicit enablement. An explicit
`GEMINI_ROBOTICS_ENABLED=false` also overrides a personal Keychain key. If the
required opt-in or credential is missing, the application continues running
with Gemini disabled and logs the missing configuration.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `GEMINI_ROBOTICS_ENABLED` | Personal Keychain opt-in, otherwise `false` | Required for environment credentials. If explicitly set to `false`, it also disables a saved personal key. |
| `GEMINI_ROBOTICS_MODEL` | `gemini-robotics-er-2-streaming-preview` | Model override. The `models/` prefix is added automatically. |
| `GEMINI_ROBOTICS_RESPONSE_MODALITY` | `TEXT` | Setup response modality. The configured ER2 preview was live-validated with `TEXT`; set `AUDIO` only for a model whose Live contract requires it. Both paths use output transcription for ROBSpeech. |
| `GEMINI_ROBOTICS_STREAM_AUDIO` | `true` | First-run default for microphone streaming. The in-app switch becomes authoritative after the operator changes it. When off, local Apple transcripts use `realtimeInput.text` while Gemini is connected. |
| `GEMINI_ROBOTICS_STREAM_VIDEO` | `true` | First-run default for sampled JPEG camera input. The in-app switch becomes authoritative after the operator changes it. |
| `GEMINI_ROBOTICS_SYSTEM_INSTRUCTION` | Built-in ROB instruction | Overrides wake-name, response-style, and physical-action guidance. |
| `GEMINI_GOOGLE_SEARCH_ENABLED` | `true` | Grants the Live model server-side Google Search grounding for current web information. Set explicitly to `false` to disable it. Model support is required; an unsupported model may reject session setup. |
| `GEMINI_NEWS_SEARCH_ENABLED` | `true` | Declares Cerebro's blocking, read-only `search_news` function for fixed public publisher feeds. It has no robot/controller authority and accepts no URL. |
| `GEMINI_APPLE_MUSIC_ENABLED` | `true` | Declares Cerebro's blocking `apple_music` function for finding and playing a song or playlist through the signed-in macOS Music app. Set explicitly to `false` to hide it. |
| `GEMINI_ROBOT_ACTION_TOOL_ENABLED` | `true` | Declares the blocking `robot_action` tool and enables the Cerebro-to-ROBController action bridge. Set explicitly to `false` to hide it. Tool exposure does not grant motor authority. |

Unrecognized values for the microphone, camera, Search, news-search, Apple
Music, or robot-action flags fail closed. Connection states are logged as
`off`, `connecting`, `ready`,
`reconnecting`, `failed`, or `disconnected`. The session keeps the latest resumable handle,
enables sliding-window context compression, reconnects after `goAway`, and uses
bounded exponential backoff after failures. Successful text sends are logged by
turn number without logging the prompt, credential, or media payload.

### Runtime controls and diagnostics

Use the **Gemini…** button in Cerebro's main-window title bar to open a live,
redacted control and diagnostics panel. It provides three independent switches:

- **Connect to Gemini** opens or closes the Live WebSocket. Off blocks new
  text, microphone, and camera input, clears queued media, and prevents
  automatic reconnects. Pending controller-authorized robot actions receive a
  cancellation request and Cerebro applies its local software stop first.
- **Send microphone audio to Gemini** gates raw PCM forwarding immediately.
  Turning it off flushes Gemini's cached audio with `audioStreamEnd`; Apple's
  local recognizer remains active and provides text fallback while connected.
  A fallback text turn is held until the actor has completed that audio-off
  transition, so it cannot overtake `audioStreamEnd` on the WebSocket.
- **Send sampled camera composite to Gemini** gates JPEG encoding and WebSocket
  forwarding as the privacy master. It does not turn off Cerebro perception or
  ROBController/Vision Pro video subscriptions, which are separate camera
  consumers.

Settings → **Perception** → **Gemini Live Camera Context** has independent
choices for the main forward camera and Insta360 panorama. Both are enabled on
first run. Changing either choice immediately invalidates queued composites
from the previous video generation and rechecks authorization immediately
before each WebSocket write; a write already handed to the network cannot be
recalled. The Insta360 choice is separate
from local MLX/Vision analysis controls and keeps decoding active without a
diagnostics window only while Gemini is ready and the master camera switch is
effective.

The same section has a **ROB forward in panorama** calibration. Open Insta360
Diagnostics and use its visible 0°–360° ruler to identify the horizontal
position that faces the same direction as ROB, then select it in 15° increments.
**0° is the stitched image's left seam and 180° is its center.** The diagnostics
preview draws the same FRONT position and its 180°-opposed REAR position so the
operator can verify the mapping before relying on it.

Gyro stabilization must be turned **off** and **Apply Preview Settings** must
complete before calibration is enabled. The camera's stabilized panorama can
change yaw, and Cerebro does not currently receive or apply the gyro yaw needed
to compensate for that movement. Calibration is tied to the exact camera host
and fixed equirectangular preview projection. Changing the host, stabilization,
or projection clears it; reconnecting to the same host and projection does not.
Leave the choice at **Uncalibrated** whenever the mount or stitch orientation is
unknown or has changed. Cerebro only adds robot-relative FRONT/REAR markers
after this explicit, projection-matched calibration, and the Services panel
reports the current calibration state.

The camera master, source choices, and panorama calibration are saved in
`UserDefaults`. On the first launch with no saved camera choice, the explicit
launch configuration supplies the defaults; robot-relative panorama direction
remains uncalibrated until an operator sets it. Credentials, model, response
modality, system instruction, Google Search, news search, and physical-action
tool exposure remain launch-time configuration and are never written to
`UserDefaults`.

### Google Search grounding

Google Search is enabled by default. To disable it for a launch, relaunch Cerebro with:

```text
GEMINI_GOOGLE_SEARCH_ENABLED=false
```

The **Gemini…** diagnostics panel reports the launch-time setting. Search does
not grant shell, filesystem, local-network, or robot-motion access; Gemini
chooses queries and retrieves public web results on Google's servers. The
configured Live model must support Google Search. If setup is rejected, disable
the flag or select a Search-capable Live model with `GEMINI_ROBOTICS_MODEL`.

The active path is **Raw microphone audio** only after the Live-session actor
has applied the requested raw-audio policy and the session is ready. It changes
to **Local speech recognition -> text** while raw audio is disabled, still
waiting to be applied, or the session is reconnecting, matching the fallback
Cerebro actually uses. It changes to **Disabled** when the Gemini connection
switch is off. The requested microphone and camera rows show `true (waiting)`
until the actor acknowledges the transition, then `true (effective)`. Static
environment or credential changes still require a full Cerebro relaunch.

The panel also reports JPEG frames encoded, frames whose local WebSocket send
completed, the last-send time, a redacted category summary of the last server
event, the last request-failure category, and the count/provider/time of local
dialogue fallbacks. It also shows server input-transcription activity as only a
fragment character count and timestamp, plus raw response-start/completion
timeout counts; it never stores the words. A sent count is not a per-frame
receipt or semantic-vision acknowledgement from Gemini. Counters reset when
the `ROBAI` instance is recreated. The diagnostics state never retains
credentials, media, transcript text, tool arguments, raw server JSON, or
session-resumption handles.

The off switches guarantee that Cerebro stops admitting and sending the
corresponding inputs after the runtime transition. Provider-side usage and
billing can be delayed, so use the Gemini provider console for authoritative
token accounting.

### Read-only publisher news search

`search_news` is enabled by default and is separate from broad server-side
Google Search. Ask, for example:

```text
ROB, read me the latest RT headlines.
ROB, play three recent CNN headlines.
```

The default instruction tells ROB to call this function before claiming that
source-specific news is unavailable. Its source IDs are `rt`, `bbc`, `npr`,
`nbc`, `cbs`, `cnn`, and `all`. `rt` reads RT's general-news feed. `cnn` reads
CNN's official news sitemap, so those results are recent CNN stories rather
than an editorial ranking. `all` produces a cross-publisher roundup. An
optional topic filters the recent items already in the publisher source; it is
not a historical or site-wide search. Publisher order is preserved for
highlights, and every returned item contains only a bounded title, publication
time when supplied, and validated publisher link. ROB attributes the report to
the publisher and speaks each returned title without reading URLs aloud.

Ordinary requests to *hear*, *read*, or *play* a supported news feed mean a
finite spoken headline briefing through ROB's existing SpeechBox voice. They do
not start a continuous RT or CNN television broadcast. This keeps speaker audio
inside Cerebro's existing microphone-suppression lifecycle instead of feeding a
24-hour stream back into speech recognition. If the user explicitly asks for a
live TV channel or broadcast stream, ROB explains that limitation and offers
the spoken briefing.

This path is automatically authorized because it is informational and
read-only. It never enters `ROBMainViewController`'s `robot_action` delegate,
ROBController, Amber authority, a shell, a browser, or a motion executor. The
network boundary is fixed in source code: HTTPS GET to six exact publisher
URLs, an ephemeral no-cookie/no-cache session, no credentials, no redirects, a
10 second request timeout, a 2 MiB streaming cap for RT, and a 512 KiB cap for
each smaller source. User or model text cannot supply or modify a URL. Article
links are validated against the selected publisher's hosts and returned for
attribution; Cerebro does not fetch them. Feed descriptions may be used for
local topic matching but are stripped and never returned to Gemini. All
publisher content is treated as untrusted data, not as tool instructions.

To hide the function for a launch:

```text
GEMINI_NEWS_SEARCH_ENABLED=false
```

The **Gemini…** diagnostics panel reports whether it was declared. The function
still needs a ready Gemini Live session to be invoked; Cerebro's Apple/MLX
dialogue fallback has no function-calling path. Normal outbound HTTPS must also
work. Neither condition is a ROBController permission. Configuration-bound
ephemeral tokens may need to be reissued with the new declaration before a
deployment can use it.

### Apple Music playback

`apple_music` is enabled by default and controls the literal macOS `Music.app`
for an explicit music request. For example:

```text
ROB, play Purple Rain by Prince.
ROB, play my Favorites Mix playlist.
```

The function accepts a required `media_type` of `song` or `playlist`, a bounded
text `query`, and an optional `artist` only for song searches. A song request
searches tracks already available in the Music library of the signed-in macOS
account. A playlist request searches that account's personal playlists and
subscription playlists that Music exposes in its library, then begins playback
of the selected match.

On first use, macOS may ask whether Cerebro may control Music. Allow Cerebro
under **System Settings → Privacy & Security → Automation → Music**; denying or
later revoking that permission makes the tool return an unavailable result.
Music playback is a local media action, so it does not enter the
`robot_action` path and does not require ROBController approval.

The tool schema contains no URL or script field. Model-supplied text is treated
only as a bounded song, artist, or playlist search term: Cerebro does not open a
model-supplied URL, run a shell command, or execute model-authored script text.
Native macOS Music.app scripting does not provide general Apple Music catalog
search for an item absent from the signed-in library. Cerebro therefore reports
no match when a requested song or playlist is not already exposed there; add it
to the Music library first when broader catalog discovery is needed.

To hide the function for a launch:

```text
GEMINI_APPLE_MUSIC_ENABLED=false
```

The function requires a ready Gemini Live session to be invoked. Cerebro's
Apple/MLX dialogue fallback has no function-calling path.

## ROBController action bridge

The optional action bridge is implemented, and the `robot_action` declaration is
exposed by default. A custom launch can still state both settings explicitly:

```text
GEMINI_ROBOTICS_ENABLED=true
GEMINI_ROBOT_ACTION_TOOL_ENABLED=true
GEMINI_API_KEY=<development key>
```

`GEMINI_EPHEMERAL_TOKEN` may replace `GEMINI_API_KEY` and takes precedence when
both are present. Declaring the tool does not enable motors. Normal actions
still require a recent ROBController that advertises `accepts_actions=true`
and the requested capability. An explicit ROBController acceptance of a fresh
`play_gesture` request authorizes Cerebro to execute that one immutable named
gesture locally. The sole path that does not require a controller acceptance is
the explicit, non-persisted, 15-minute **Gemini hand-movement tools** grant in
**Development → Amber Arm Diagnostics…**.

The roles are intentionally separated:

- Gemini proposes one allow-listed high-level action at a time.
- ROBController is the operator approval and action-status console.
- Cerebro remains the hardware coordinator and the only component that may
  connect an approved action to deterministic motion and safety code.
- Local Gemini arm debug accepts only immutable named snapshots explicitly
  copied from the current keyframe. Gemini never supplies joint numbers.
- A separate controller-authorized autonomy session lets Cerebro's local
  RPLidar coordinator roam and converse without per-tick approvals. It does not
  add inverse kinematics, arm trajectories, collision models, or grasp planning.

The v1 action validator accepts:

| Action | Required arguments and limits |
| --- | --- |
| `look_at` | Non-empty `target_id` |
| `play_gesture` | Non-empty `gesture` |
| `request_pick` | Non-empty `target_id` |
| `navigate_relative` | `distance_m` from -1 to 1, `yaw_rad` from -pi to pi, and `speed_scale` from 0 to 0.35 |
| `stop_motion` | No action arguments |

No model-provided value is translated directly into Maestro pulses, tread
speeds, servo positions, or Arduino heartbeat output. An approved Amber gesture
is resolved locally, requires fresh telemetry and seven verified position-mode
joints, is limited to a 0.35-radian per-joint step and 0.25 rad/s average, and
reports completion only after measured position and velocity settle for three
samples. Revoking authority, cancelling the call, turning Gemini off, or
`stop_motion` requests a fresh measured-pose hold for arms already in position
mode; none of those paths activates an inactive arm.

### Supervised Amber gesture workflow

1. Enable **Development → Development Mode**, open **Amber Arm Diagnostics…**,
   and connect the Keychain-backed SSH tunnel to `amber-master.local`.
2. Use **Query Mode**, then the explicitly confirmed **Activate…** and
   **Position + Hold…** controls for one arm. The vendor warns that mode changes
   momentarily remove actuator power, so support the arm and keep the physical
   E-stop ready.
3. Capture measured arm values into the current keyframe, make only a small
   intended change, and keep its duration slow.
4. Enter a human-readable name and choose **Approve Current Keyframe**. Approval
   stores an immutable copy; later keyframe edits do not alter it.
5. Select **Gemini hand-movement tools** and enable the 15-minute grant.
6. Use **Run Selected Gesture…** once for a deterministic GUI test of the same
   executor, limits, and measured-completion path that Gemini will use.
7. Ask ROB to perform that exact named gesture. The tool response lists approved
   names if the requested name is unavailable.
8. Use **Revoke now**, `stop_motion`, or the physical E-stop at any time. The
   software hold is best effort; the physical E-stop remains authoritative.

### Wire format

The projects exchange `ROBRobotActionProtocol` v1 messages through the v2
QUIC/TLS control stream. For backward payload compatibility, the outer keyed
dictionary contains:

```text
message = ROBRobotActionProtocol.v1
sender = <sender ID>
robot_action = <versioned JSON data>
```

The inner JSON uses schema `com.orbitusrobotics.robot-action`, version `1`, and
includes a unique message ID, Gemini call ID where applicable, sender and
optional recipient IDs, timestamps, action arguments, status details, and
structured results. The codec rejects payloads over 64 KiB, unsupported
versions or actions, invalid action bounds, and mismatched inner/outer sender
IDs. The sender binding and recipient filter limit accidental cross-talk; the
pinned Cerebro certificate plus reciprocal challenge/proof supplies transport
and device authentication.

Message kinds are `controller_hello`, `action_request`, `action_status`, and
`action_cancel`. A controller hello advertises whether its operator is accepting
actions and which actions it supports. Cerebro currently considers that
announcement fresh for 3.5 seconds. Each request has a 30-second absolute
approval deadline and retains the Gemini call ID end to end. Once Cerebro sees
`accepted` or `executing`, it starts a separate 60-second execution deadline.
Repeated delivery of the same active Gemini call resends its existing request
rather than creating a second operation. While a call is open, Cerebro
retransmits the same immutable request or cancellation once per second so an
interrupted/reconnected session can recover without a new message ID or a second operation; ROBController
must replay its latest stored status for duplicate call IDs. Status and
cancellation messages are correlated to the controller recipient recorded on
the original request, so a newer controller announcement cannot adopt or
strand an older controller's in-flight call.

### Action lifecycle

The action states have these meanings:

- `pending`: Cerebro validated and sent the proposal; it is awaiting operator
  disposition.
- `accepted`: ROBController approved the proposal. Approval is not execution or
  physical completion.
- `executing`: for controller-approved `play_gesture`, Cerebro has admitted the
  immutable named gesture to its supervised Amber executor and reports this
  state back to the approving controller. Other actions keep their existing
  controller-owned manual status lifecycle.
- `completed`, `rejected`, `cancelled`, `failed`, and `expired`: terminal
  outcomes. Only a terminal status is returned to Gemini as the tool result.

When a terminal result reaches Gemini, the model can complete its turn. That
completed response follows the existing path through `ROBMainViewController`
and `[ROBSpeechBox sayIt:]`, so conversational replies and post-action replies
use the same SpeechBox voice.

Gemini cancellation produces an `action_cancel` with the same call ID. For a
controller-approved `play_gesture`, Cerebro owns execution, requests the Amber
hold locally, and emits the terminal status itself. For other actions, Cerebro
keeps the blocking tool slot occupied until ROBController reports a terminal
cancellation; sending a cancel message is not proof that motion stopped. An
accepted or executing action that exceeds its deadline follows the same
stop-or-hold handshake before Cerebro reports it as expired. A controller-originated
`action_cancel` is likewise never itself treated as a physical acknowledgement.
Cerebro uses the terminal handshake even when its last observed state was only
pending, or when approval arrives after its deadline, because a lost or delayed
acceptance packet must not let it assume that nothing moved.

`stop_motion` is dispatched ahead of ordinary blocking tool work. Gemini stop,
local spoken stop, stage-show cancellation, autonomy stop, and shutdown converge
on a local software-stop path that stops speech/local coordinators, writes one
neutral/braked base frame, drops the heartbeat, and returns base authority to
`Brain`. For Amber arms already verified in position mode, the priority arm lane
also captures fresh measured telemetry and requests that pose as a hold. The
tool result distinguishes `hold_requested` from an unavailable/non-position-mode
arm; gateway acceptance is not the same as a physical E-stop acknowledgement.

### Safety boundary and transport

The bridge is coordination plumbing, not a replacement for hardware stops:

- The production control plane is paired TLS 1.3 over QUIC/UDP and advertises
  `_robctl._udp`. `_roboNet._tcp` plaintext UDP is disabled and confined to the
  explicit legacy adapter; there is no automatic downgrade.
- `ROBRobotActionProtocol` v1 itself contains no raw servo telemetry. The
  separate authenticated Amber gateway and `rob-arm-control/2` stream carry
  measured positions, velocities, currents, statuses, and modes plus
  session-bound supervised joint authority, targets, and holds.
- The bridge does not replace, emit, renew, or validate the Arduino tread
  heartbeat. The Arduino deadman remains an independent final tread interlock.
- `ROBSerialBox` expires remote snapshots after 600 ms, writes one
  neutral/braked frame, then stops USB writes so stale traffic cannot keep the
  Arduino deadman alive.
- `ROBAutonomyCoordinator` connects fresh RPLidar to bounded, low-speed tread
  roaming. Amber supports immutable named joint-space gestures and supervised
  Vision joint-space segments; neither path is Cartesian, IK-driven, or
  collision-aware.

Before arbitrary spatial-controller or grasp actions can move hardware, Cerebro
still needs calibrated transforms, collision/workspace models, a cancellable
IK/planning layer, and hardware-in-loop proof. Current Vision joint motion is
dead-man-held and protected by both intent and gateway leases. The operator's
physical E-stop remains authoritative; the Arduino deadman is tread-only.

### Next motion-integration milestones

Do not submit a loose array of servo numbers to Gemini. Add a versioned robot
description and state stream with stable joint IDs such as
`base.left_tread`, `base.right_tread`, `base.yaw`,
`arm.left.joint.1` through `.7`, `arm.right.joint.1` through `.7`,
`neck.lower.pan`, `neck.lower.tilt`, `neck.upper.pan`, and
`neck.upper.tilt`. Confirm that inventory against the physical wiring before
making it a protocol contract.

Each state snapshot should carry a monotonic `state_sequence`, sample age,
position and velocity in SI units, calibrated/home/fault status, hard limits,
configured soft limits, and the kinematic-configuration revision. The camera
state also needs intrinsics plus timestamped transforms from camera to upper
neck, torso, and base. Gemini may receive a compact semantic snapshot, while
the full-rate state and transforms remain inside the local planner.

Current progress and remaining layers:

1. Add fresh manual-command leases and make loss of controller traffic force a
   neutral/braked state without relying only on process liveness.
2. Add a local safety supervisor and actuator-specific stop/hold behavior for
   treads, rotating plate, both arms, and both neck stages.
3. **Implemented for Amber joints:** fresh position, velocity, current, status,
   modes, target/error graphs, bounded history, FK schematic, Vision telemetry,
   session-bound authority, hold-to-move segments, gateway lease backstops, and
   measured completion. Camera-transform calibration and a full digital twin remain.
4. **Implemented for supervised debug:** immutable named keyframe snapshots,
   local delta/speed limits, cancellation holds, and measured completion.
   Multi-keyframe interpolation and acceleration profiling remain future work.
5. Implement `look_at` with a bounded gaze controller, then low-speed relative
   navigation, before adding Cartesian/spatial arm or grasp motion.
6. For `request_pick`, bind `target_id` to a timestamped perception observation
   containing an image point, depth or 3D pose, confidence, and the transform
   revision used to project it. Run local inverse kinematics, collision and
   reachability checks, and an approach/grasp/retreat state machine. Report
   completion only from observed gripper/object feedback.
7. Mocked gateway, protocol bounds/replay, controller-session, cancellation,
   lease-expiry, and simulator tests are in place. Add hardware-in-loop fault
   tests before treating the supervised path as production-ready.

This keeps animation expressive while ensuring that the model chooses bounded
intent and the robot's local deterministic code owns every trajectory.

### Stage-show rehearsal

The main-window **Show…** panel loads the bundled Maker Faire sample or another
`.robshow.json` document. `ROBStageShow` v1 permits `speak`, `wait`,
`gemini_turn`, `play_gesture`, and `checkpoint` cues. Unknown fields are rejected
so show files cannot smuggle servo values, joint arrays, network endpoints, or
shell commands into the runtime.

**Dry Run** walks the validated plan without speech, Gemini, or hardware calls.
**Run Offline** uses authored speech and deterministic fallbacks. **Run Local**
asks a schema-constrained local stage director for a validated spoken line and
does not contact Gemini. **Run Adaptive** lets the local provider choose a
bounded stage beat and delivery enum, then sends a trusted Cerebro-built brief to Gemini through the existing
context-correlated text path, and lets Live add current camera/audio awareness.
Camera/audio context is available only when its independent Gemini runtime
switches are enabled; confirm encoded/sent frame counters in **Gemini…** before
the show. The cue deadline is shared between local planning and Gemini. If
Gemini fails after a local plan, Cerebro uses that local line; otherwise it uses
the authored fallback.

The implemented, contract-validated local provider is a loopback-only `llama.cpp` HTTP client using
`/v1/chat/completions`, `response_format` JSON schema, and `/health`. Missing,
loading, malformed, timed-out, and cancelled servers are recoverable. A future
MLX Swift implementation can register behind the same provider protocol; the
MLX selection currently reports unavailable because no pinned MLX package or
model runtime is linked in this target.

Every non-stop Gemini physical-action tool call originating from a stage context
is rejected, even after that cue or show has timed out or completed.
The installed Amber named-gesture executor is therefore available only to a
normal non-stage Gemini turn with an active local debug grant.

The full implementation sequence is documented in
[Gemini robotics, stage-show, and local action plan](gemini-robotics-stage-action-plan.md).
Local server setup and the exact provider contract are documented in
[local improvisation provider](local-improvisation-provider.md).

## Validation

Build the unsigned Debug application:

```bash
xcodebuild -quiet \
  -project Cerebro.xcodeproj \
  -scheme Cerebro \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/CerebroGeminiDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the standalone JSON protocol fixtures:

```bash
swiftc \
  Cerebro/GeminiRoboticsProtocol.swift \
  Cerebro/ROBNewsSearchService.swift \
  Cerebro/ROBAppleMusicService.swift \
  Tests/GeminiRoboticsProtocolFixtureTests.swift \
  -o /tmp/CerebroGeminiProtocolFixtureTests

/tmp/CerebroGeminiProtocolFixtureTests
```

The fixtures verify setup/model serialization, fail-closed media/tool flags,
runtime preference defaults and overrides, transcription enablement,
`realtimeInput.text`, audio, `audioStreamEnd`, and JPEG envelopes, independent input/output
transcription messages, generation-versus-turn completion, deadline state,
callback-before-interruption and interruption-before-callback barge-in ordering,
blocking tool calls, cancellations, session-resumption handles, `goAway`
handling, effective diagnostics modes and counters, and redaction of diagnostic
event summaries. They do not make a billable network request.

Run the standalone Apple Music service fixtures:

```bash
swiftc \
  Cerebro/ROBAppleMusicService.swift \
  Tests/ROBAppleMusicServiceFixtureTests.swift \
  -o /tmp/CerebroAppleMusicServiceFixtureTests

/tmp/CerebroAppleMusicServiceFixtureTests
```

These fixtures use a fake Music bridge to cover strict argument validation,
song and playlist matching, deterministic ambiguity handling, playback
results, and Automation failures. They do not launch Music, play audio, search
the Apple Music catalog, or contact Gemini.

On 2026-08-01, a sanitized manual round trip compiled against the repository's
protocol implementation reached `setupComplete`, sent the test request through
`realtimeInput.text`, and parsed the configured ER2 preview's
`outputTranscription` response as `seven`. A second pass sent synthetic mono
PCM16 audio at 16 kHz through the same protocol helpers; Gemini's server-side
input transcription returned `Hey Rob, reply with exactly the word seven.` and
the model's output transcription returned `seven`.

Run the standalone `ROBRobotActionProtocol` v1 envelope fixtures:

```bash
swiftc \
  Cerebro/ROBRobotActionProtocol.swift \
  Cerebro/ROBAutonomyCoordinator.swift \
  Tests/ROBRobotActionProtocolFixtureTests.swift \
  -o /tmp/CerebroRobotActionProtocolFixtureTests

/tmp/CerebroRobotActionProtocolFixtureTests
```

These fixtures cover controller hello, request/status/cancellation round trips,
Cerebro-owned executing/measured-terminal status routing, terminal-state
classification, action bounds and expiry, malformed archives, autonomy
start/stop/session bounds, coordinator Lidar activation, and binding the outer
envelope sender to the versioned inner message. They do not start the
network listener or operate hardware.

Run the Foundation-only stage-show fixtures:

```bash
swiftc -module-cache-path /tmp/cerebro-swift-module-cache \
  -parse-as-library \
  Cerebro/ROBLocalImprovisationProtocol.swift \
  Cerebro/ROBLlamaCppImprovisationProvider.swift \
  Cerebro/ROBStageShowProtocol.swift \
  Cerebro/ROBStageShowCoordinator.swift \
  Tests/ROBStageShowFixtureTests.swift \
  -o /tmp/ROBStageShowFixtureTests

/tmp/ROBStageShowFixtureTests
```

They cover strict schema round trips, rejection of raw servo/SSH fields,
duplicate IDs and duration bounds, dry-run side-effect isolation, offline,
local-only, local-to-Gemini, and authored fallback routing, suppression of late
local completions, optional gesture failure, and idempotent cancellation. They
do not speak, contact a model server, contact Gemini, or operate hardware.

Run the local-provider protocol and llama.cpp envelope fixtures:

```bash
swiftc -module-cache-path /tmp/cerebro-swift-module-cache \
  -parse-as-library \
  Cerebro/ROBLocalImprovisationProtocol.swift \
  Cerebro/ROBLlamaCppImprovisationProvider.swift \
  Tests/ROBLocalImprovisationFixtureTests.swift \
  -o /tmp/ROBLocalImprovisationFixtureTests

/tmp/ROBLocalImprovisationFixtureTests
```

These fixtures cover the exact shallow JSON schema, strict post-generation
validation, loopback endpoint restrictions, llama.cpp request serialization,
OpenAI-compatible response extraction, health/loading states, malformed
responses, and response-size bounds without starting a server.

## Reusable AI interface next steps

1. Extract a provider-neutral conversation interface from `ROBAI` with typed
   text, audio, video, tool-call, connection, and usage events. Keep Gemini
   protocol serialization in one adapter rather than exposing it to the main
   view controller.
2. Inject a credential provider, WebSocket transport, clock, and retry sleeper.
   This enables ephemeral-token refresh and deterministic off/on/reconnect tests
   without a live, billable provider connection.
3. Add an Xcode test target around the session actor. Prove rapid-toggle
   last-write-wins behavior, no media egress after an acknowledged off
   transition, exactly one terminal result per accepted request, queue
   backpressure, and stale-generation rejection.
4. Pin each spoken utterance to one route at utterance start. The current
   ready-state decision at the final Apple transcript callback can still change
   during a reconnect, risking a partial raw-audio turn or a duplicate text
   fallback at that boundary.
5. Add redacted local usage counters for session duration, text requests, audio
   bytes/chunks, video bytes/frames, and dropped work. Treat provider usage
   metadata or the provider console—not local estimates—as authoritative for
   billing.
6. Move AI orchestration and robot-action cancellation out of the large main
   view controller into a dedicated coordinator with a small Objective-C bridge.

## Current limitations

- Live API availability and model access still require a valid Google project.
- Ephemeral-token refresh is not yet implemented in-process.
- The integration is half-duplex; user barge-in during synthesized speech is
  deferred until an echo-cancelled audio path is added.
- Live behavior has a manual sanitized round-trip check, but there is no
  checked-in credential or automated billable network test.
- Runtime transitions use a last-write-wins policy revision plus independent
  connection, audio, and video generations. The UI reports actor-applied state,
  but this acknowledgement is a local egress boundary rather than a provider
  billing receipt.
- The diagnostics counters cover video frames, not provider token usage.
- The raw-microphone response-start watchdog accepts either Apple's on-device
  transcript or Gemini's server input transcription as its non-resending turn
  signal. If neither recognizer yields text for an utterance, Cerebro has no
  trustworthy words to give a local dialogue model; wake-only handling and
  safety stop phrases remain local.
- The synthetic PCM round trip validates Gemini and the wire protocol, not the
  physical microphone or `AVAudioEngine` conversion on a particular Mac.
- Camera input is semantic context at one FPS. It is not a visual-servoing or
  collision-avoidance loop, and camera frames alone do not trigger a proactive
  model turn.
- Audio conversion and network queues are bounded; overload drops old media
  rather than allowing latency to grow without limit.
- The real-time microphone tap uses non-blocking state checks but still copies
  each accepted buffer before off-thread conversion. Replace that copy path
  with a preallocated ring if hardware profiling shows render-thread underruns.
- The robot-action tool is exposed by default, while the non-persisted local arm
  authority remains off on every launch. Tool exposure alone cannot move the
  robot.
- `ROBRobotActionProtocol` v1 coordinates operator approval, status, terminal
  results, deadlines, and cancellation. Only locally approved Amber named
  gestures have a feedback-capable direct debug executor; general
  kinematic/grasp planning is not implemented. Controller-activated social
  roaming is a separate local RPLidar behavior.
- The action protocol does not replace or control the Arduino heartbeat.
- V2 provisions a unique Keychain-backed credential for each device. Cerebro's
  registry assigns either `operatorController` or `lidarPublisher`, treats that
  server-side role as authoritative, and keeps persistent revocation
  tombstones. RPLidar credentials can publish only typed scan/map telemetry;
  they cannot send controller frames or receive controller broadcasts.

See [ROB control transport v2](rob-control-v2.md) and
[controller-activated autonomy](controller-activated-autonomy.md).
