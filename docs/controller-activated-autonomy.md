# Controller-activated autonomy

## Operator model

Autonomy is a separate controller mode, not the existing per-action Gemini
approval console. A paired ROBController starts one versioned session with:

- a unique session ID and monotonic sequence;
- the controller ID and an optional addressed Cerebro ID (the current v2
  certificate pin already selects one exact robot);
- a profile and behavior allow-list;
- an activation-centered zone radius;
- a maximum tread speed scale;
- an absolute duration, capped at 12 hours.

The default controller request is `social_roam`, a 5 meter activation-centered
zone, 0.20 maximum speed scale, and an eight-hour duration. The controller can
stop it explicitly at any time. A manual **Request Control** also ends autonomy.
Physical arm E-stops, the front shutdown switch, and the Arduino tread deadman
remain independent and authoritative.

The session is one operator decision. Cerebro does not ask again for every small
turn, gaze update, idle motion, or conversational response.

## Current social-roam behavior

`ROBAutonomyCoordinator` runs locally at 5 Hz. It:

1. parses the existing RPLidar payload (`x:y:z`, `yaw:pitch:roll`, followed by
   `distance:angle` points);
2. records the first fresh pose after activation as the zone center;
3. refuses to issue tread snapshots when the scan is missing or older than
   750 ms, allowing the existing base heartbeat to drop;
4. drives slowly forward when the front sector is clear;
5. turns toward the clearer side when an obstacle is within 0.8 m;
6. turns back toward the captured center near the zone boundary;
7. adds occasional small course changes for less mechanical-looking motion;
8. supplies occasional bounded social prompts to the existing Gemini Live
   camera/audio conversation, whose text still speaks through `ROBSpeechBox`.

The coordinator writes a fresh `Autonomous` controller model; it does not bypass
`ROBSerialBox` or the Arduino heartbeat. When no fresh model exists,
`ROBSerialBox` sends one neutral/braked packet and becomes silent.

## Nearby OpenStreetMap destination navigation

ROBController's **Start Autonomy…** flow can now search OpenStreetMap and bind a
selected latitude, longitude, and display name into autonomy protocol version 2.
The public Nominatim endpoint is queried only after the operator submits a
search (never as type-ahead), with an identifying User-Agent and visible
OpenStreetMap attribution. Set the `ROBNominatimEndpoint` user default to use a
self-hosted or contracted geocoder.

Cerebro uses its own Core Location fix—the controller phone is not assumed to
be mounted on ROB—and requests a pedestrian route from Valhalla. The default is
`https://valhalla1.openstreetmap.de`; set `ROBValhallaEndpoint` to a deployment
under your control. OpenStreetMap supplies map data, while Valhalla performs the
pedestrian route computation. The initial pilot rejects a route longer than the
controller-authorized 50 m zone.

RPLidar yaw is local rather than north-referenced. At session start, point ROB
along the first route segment; Cerebro records the offset between that segment
and the first fresh local yaw. A production deployment should replace this
provisional alignment with a calibrated compass/IMU or a localization estimate.

OpenStreetMap route geometry is intent, never a collision-safety signal. At each
5 Hz planner tick, destination motion requires all of the following:

- robot location no older than 5 seconds, accuracy of 15 m or better, and a
  route inside the authorized area;
- RPLidar scan/pose and belly RGB-D perception no older than 750 ms;
- at least 0.8 m RPLidar clearance in the candidate heading;
- sufficient valid depth and at least 0.45 m lower-image depth clearance;
- a candidate that resembles terrain ROB has previously crossed under manual
  control.

If any input is stale, uncertain, outside the authorized boundary, or mutually
inconsistent, Cerebro drops the tread heartbeat instead of guessing.

## Automatic traversability learning

The belly RGB-D camera now runs headlessly so learning does not depend on the
diagnostics window. While an operator manually drives ROB, Cerebro keeps compact
directional color, texture, and depth features in memory. A candidate becomes a
positive training example only after RPLidar odometry confirms forward motion
of at least 0.35 m across it with limited lateral drift. This is robot-experience
supervision: no images are saved and no human annotation tool is involved.

The online one-class model persists only counts, running means, and variances at
`Application Support/Cerebro/Navigation/traversability-model-v1.json`. It needs
12 confirmed samples before it can influence navigation. Training is disabled
during autonomous sessions to prevent a self-confirming feedback loop. The
learned score only ranks candidates that already pass both geometric sensors;
it can never overrule an obstacle veto.

This compact model is the dependency-free bootstrap implementation. A later
upgrade can replace its feature vector with DINOv2/Wild Visual Navigation-style
dense embeddings while retaining the same odometry-derived labels, confidence
gate, persistence boundary, and depth/RPLidar vetoes.

## Servo state contract to add next

Do not submit only raw servo pulses to Gemini. Publish a timestamped robot-state
snapshot that separates calibrated joint state from hardware representation:

```json
{
  "schema": "com.orbitusrobotics.robot-state",
  "version": 1,
  "captured_at_ms": 0,
  "base": {"x_m": 0, "y_m": 0, "yaw_rad": 0},
  "joints": [
    {
      "id": "upper_neck.pan",
      "position_rad": 0,
      "velocity_rad_s": 0,
      "commanded_rad": 0,
      "minimum_rad": -1.0,
      "maximum_rad": 1.0,
      "feedback": "measured"
    }
  ],
  "frames": {
    "camera_to_upper_neck": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
  },
  "faults": []
}
```

Inventory stable IDs for both treads, rotating base plate, fourteen arm joints
(seven per arm), both lower-neck axes, both upper-neck/camera axes, and both
grippers. For every axis record units, sign, zero, hard range, normal animation
range, velocity/acceleration limits, controller channel, and whether position is
commanded-only or measured. The current source maps only three neck Maestro
channels, so the missing fourth neck axis must be identified before treating the
camera transform as complete.

Use a single local actuator gateway to convert calibrated radians/meters into
Maestro, Pololu, Arduino, or Amber commands. Gemini should return a named intent
or target pose; it should never emit a raw channel/pulse sequence.

## Pick pipeline

“Pick this up” needs this deterministic pipeline after the state contract:

1. Camera perception assigns a stable target ID and estimates a 3D pose. A
   monocular bounding box alone is not a grasp location; add depth or a
   calibrated multi-view estimate.
2. Transform the target from camera coordinates through upper neck, lower neck,
   torso, and selected arm base.
3. Select an arm and pre-grasp from reachability and current joint state.
4. Solve IK within calibrated joint ranges and collision geometry.
5. Plan a cancellable trajectory: pre-grasp, approach, close, retreat.
6. Execute through the local gateway while publishing action status.
7. Confirm contact/position from feedback. Without feedback, report
   `commanded_unverified`, never physical completion.
8. Keep camera/Lidar perception live during execution so the local coordinator
   can cancel or replan when the target or person moves.

The existing Gemini action/result/cancellation protocol already supplies the
high-level call identity. Until transforms, IK, collision checking, and feedback
exist, Cerebro returns a clear failed result for `request_pick`; this lets Gemini
explain the limitation through the normal SpeechBox response instead of claiming
that an arm moved.

## Validation before increasing speed or enabling arms

- Replay recorded Lidar scans through coordinator fixtures, including empty,
  malformed, stale, close-obstacle, and zone-boundary cases.
- Confirm tread signs and yaw convention with treads lifted or on a fixture.
- Measure the full Wi-Fi-loss to Arduino-deadman stop interval.
- Calibrate and record all joint/channel mappings and transforms.
- Add arm joint feedback, IK, collision models, and cancellation tests.
- Exercise every physical E-stop and front shutdown path with each actuator
  separately before allowing a named gesture or grasp profile.
