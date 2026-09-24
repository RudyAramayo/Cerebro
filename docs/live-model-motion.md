# Live model motion

Gemini Live and OpenAI Realtime use the same function declarations and shared
motion instruction. OpenAI adapts the schema casing; it does not have a separate
motion backend. [Realtime function calling](https://developers.openai.com/api/docs/guides/realtime-mcp)
returns intent to Cerebro, which supplies the correlated execution result.
No provider can send raw joints, speed, force, shell commands or direct gateway
packets through these tools.

`robot_capabilities {}` reports current arm/gateway/camera state, controller
approval state, approved gesture names and stored demonstration clip IDs.
Its `show_paths` field reports configuration-bound rehearsal availability; see
[show rehearsal](show-motion-rehearsal.md) for live status and evidence. Read the
capabilities before selecting a new behavior. Availability is narrower than the
robot's mechanical range:

| Actuator | Live model path | Current limits |
| --- | --- | --- |
| Arms and grippers | `arm_control` | Fixed hanging/front corridor, paired execution, camera and measured feedback; one controller approval per operation |
| Treads | `loiter_control` | Only an existing controller-authorized social-roam session; Lidar/zone vetoes, bounded turns, no measured relative-distance claim |
| Approved recorded gestures | `robot_action` / `play_gesture` | Immutable local catalog and authenticated controller approval |
| Neck | Local inspection preset, controller head tracking, and rehearsed `show.*` IDs via `play_gesture` | Fixed supervised scan/greeting paths require a matching rehearsal receipt; no general `look_at` or measured neck shaft feedback |
| Torso yaw | Controller camera-feedback velocity control | No general live-model tool; camera registration and combined arm/body collision coverage are not validated |
| Forward/back body lean | Controller/manual reviewed mechanisms | No model body-lean executor; neck posture presets are not measured body lean |

The capability response explicitly marks unsupported body executors. Existing
`look_at` or `navigate_relative` proposals must not be narrated as completed just
because a controller accepted them. Arbitrary human-pose IK remains preview-only:
the scanned self-collision reference still has unresolved geometry conflicts;
see [shadow IK](vision-pro-shadow-ik.md).

## Arm vocabulary

- `prepare`: move both arms in front, reuse current gateway calibration (including
  manual diagnostics), calibrate empty grippers only when required, and request
  both jaws open on every preparation. Opening is automatic, with no separate
  release command. The controller summary covers supporting any held object.
  The result distinguishes accepted release commands from measured jaw opening;
  calibration and closing retain their stationary camera assessments.
- `grab` / `hold`, with `object`: prepare and attempt a low-intensity close only
  when the requested object is already between exactly one open gripper's jaws.
  No arbitrary reaching or secure-force grasp claim.
- `relax`: follow the taught return route to measured hanging zero, then verify
  all fourteen arm modes inactive. A failed return holds instead of dropping torque.
- `wave`: prepare, then make a small symmetric front-arm greeting along four
  corridor segments, ending in front. This is not an anatomical wrist wave.
- `teach`, with optional `object` as a clip name: record five seconds of one
  person's visible shoulders, hips and wrists through the main camera. No motor
  activation, neck positioning or controller approval occurs during capture.
- `replay`, with `clip_id` or `last`: execute the selected bounded rendition.
- `status`: inspect state without motion. `stop`: request immediate holds without
  waiting for controller approval or the ordinary model tool queue.

Examples: “copy my pose”, “replay that movement”, “wave at Sam”, “hold this” and
“relax”. Local text/speech shortcuts and both providers reach the same executor.

Teaching preserves the order of coarse relative lifts, not a person's timing,
exact joint pose, independent arm motion or hand shape. Both wrists contribute
to one symmetric height. Stable height bins map only to existing corridor
waypoints 4–6; waypoints between bins are inserted, and every rendition returns
to waypoint 6. Tracking gaps, stale frames, low confidence, multiple bodies and
large changes in body position/scale reject the recording. This continuity
check is not biometric identity tracking. Clips contain at most eight adjacent
segments and no arbitrary motor values or camera image. Stored clips are bounded
in size and count and pinned to the corridor revision; invalid clips are ignored.

## Local execution and authority

A contextual model decision is a proposal, not a motion grant. The authenticated
Vision Pro or iPhone approves one summary covering preparation, both grippers
and the entire rendition. The clip is captured immutably before requesting
approval. There are no desktop dialogs or per-waypoint model calls.

The local coordinator owns timing, camera checks, arm reservations, fresh
per-motor CAN feedback, 1.5-second renewable gateway leases and the 90-second
whole-operation deadline. Both arms dispatch together; short segments use
bounded distance-based timing. Planned hanging/front travel is about 20.7 s;
one supervised live forward trial measured about 22 s, excluding checks and
gripper work (see [recorded evidence](arm-startup-and-grab.md)). Treads/flippers/body lean
are held still during physical arm work, and torso re-arming is refused.
Explicit neck input invalidates the stationary inspection view.

Main-camera RGB-D must be current. Explicit controller approval permits
operator-supervised travel on the taught route with incomplete camera coverage;
gripper motion still requires a stationary jaw assessment. Camera evidence can
veto motion; it is not a certified geometric model of the environment,
people, cables or held objects. Empty grippers are required for greetings and
replay. General reaching and full body imitation remain unavailable.

## Validation

`Scripts/test-arm-routines.sh` executes the production planner/coordinator with
isolated asynchronous gateway and controller fixtures. It covers startup and
both-gripper order, lift mapping and stored clip validation, measured greeting
arrival, stale-camera holds, off-route rejection, calibrated grab reuse and
return-before-deactivation. Realtime adapter and Gemini fixtures check the same
commands, capability tool and stop priority for both providers. Torso fixtures
check that arm ownership blocks torso activation. Camera ingress fixtures check
that a stalled session queue discards 999 older frames rather than replaying them.

Real cameras were measured without motor operations; results are in
[depth camera integration](depth-camera.md#2026-09-23-latency-measurements).

The earlier live-motion macOS Debug build passed and was installed at `/Applications/Cerebro.app`.
`codesign --verify --deep --strict` passed. The app relaunched successfully;
Settings showed the teaching/replay/greeting controls, startup calibration off
and “Arms idle”. Live main-camera imagery was inspected. Application-level
capture-age logging was not available from this launch, so the latency numbers
above are the separate camera-only measurements, not an in-app timing claim.
No controller approval was synthesized and no automatic arm motion was tested.

That earlier build's `Cerebro.debug.dylib` SHA-256:
`63d9471ad6f0b405123505c114766fce5c9bc184f85f49832a2052c15f5eb31f`.
Installed `Webcam_color.py` SHA-256:
`6c0b62a4676d179721e97712332c6e354f7f0331d15b6c4da13b6d5a51c013b8`.
The pre-existing storyboard label changes were retained locally and are excluded
from this commit. The prior app is backed up at
`/private/tmp/Cerebro-before-live-motion-20260923.app`.
