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
