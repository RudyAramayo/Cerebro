# Local recycling task and spoken arm sessions

Rob requested this experimental empty-Coke-can cleanup task on October 22, 2026.
It is implemented for the physical left arm (R11 / gateway `right`), with the
base stationary. Software validation is separate from live commissioning.

## Authorization and startup

Cerebro automatically prepares the saved Amber tunnel at launch and wake. A
late robot startup or transient network failure now retries telemetry with
2/4/8/16/30-second backoff; authentication/key/configuration failures remain
visible and do not loop. Disconnect and sleep cancel retries. Reconnection never
replays motion, preserves an old gateway generation, or restores jaw calibration.

Settings → Arms offers a 15-minute supervised left-arm rehearsal session.
Launch/wake offers this session once by default (the preference can be disabled).
ROB describes the scope and accepts one final local microphone acknowledgement
such as “yes, proceed,” or an authenticated iPhone/Vision Pro approval. Accepting
the session prepares the empty left arm. Covered preparation, local searches,
reviewed gestures, empty-can recycling at intensity 2 and empty-arm lowering
then execute without additional approvals or Continue buttons. Standalone tasks
also accept one spoken or controller approval for the complete operation.

Spoken authorization is accepted only by SpeechBox's final on-device recognition
delegate while ROB is not speaking. A stable candidate endpoints the current
utterance after 750 ms so continuous dictation does not delay approval until its
minute-long timeout; only the resulting final transcript can grant it.
Partial recognition, typed/controller text,
serial transcripts, camera text, quoted/conditional acknowledgements and model
output cannot authorize. A pending scope expires after 90 seconds. Sessions are
memory-only, expire after 15 minutes and end on Stop, sleep/restart, ownership
loss or motion failure. A controller-authorized session retains controller
freshness; a microphone-authorized session does not require a connected phone.
There is no per-waypoint authorization. Diagnostics raw commands remain outside
the reusable session.

Local commands include “start an arm session,” “recycle the can,” “find the
orange bucket,” “check your arms are hanging,” “lower your left arm,” and
“end the arm session.” Stop remains immediate and revokes session authority.

## Search and pointing

`left_search_workspace` searches without activating or moving either arm and
does not require arm CAN feedback. `left_check_hanging` inspects hanging-arm
visibility independently; an unobserved arm is reported as unconfirmed, never
used to reset encoder zero.

The shared service sweeps bounded neck pan/tilt views through the normal
mechanical envelope, command ramps, settling and manual-priority rules. It uses
the installed on-device MLX vision model, not a cloud conversation. Its only
output schema contains observed object boxes, aiming/rim pixels and hanging-arm
facts. Two distinct RGB-D observations must agree within 5 cm. Missing factory
intrinsics, missing/mixed depth or uncertain detections cannot become targets.
Search does not require the entire scene to be motionless: the neck view and
individual target confirmations govern it. Older discoveries are re-observed.

If an object is missing, ROB addresses the nearest visible person's view (or the
forward view if none was measured), asks them to point, and watches for a stable
extended-index gesture. The projected 2D finger direction selects a bounded
camera view and two adjacent views. It is an approximate search hint, not a
calibrated 3D pointing ray or proof of the object. The object must still receive
two fresh visual/depth confirmations. ROB reports found/not found aloud.

Each search saves observations, capture times, sequences, view targets, found
positions and the actual outcome in Application Support/Cerebro/WorkspaceSearch.
These historical reports never authorize later motion.

## Pick and place

`left_recycle_can` covers search, pointing assistance if needed, planning and
execution under the original authorization, bounded to six minutes. A local IK
planner generates five anchors: pickup approach, grasp, 6 cm test lift, release
12 cm above the observed bucket rim, and retreat. The proposal includes exact
targets, timing, model/mapping/session IDs and jaw-action boundaries. Only the
single current step can reach the gateway. Taught approach travel uses the
existing five segments. Arbitrary camera/model joint values are never admitted.

Before each jaw action the executor drains motion leases, requires a confirmed
position hold and fresh settled joint feedback. Empty calibration occurs only at
the initial front preparation, never around the can. Grip/release use vendor
intensity 2. There are no manual readiness stages, automatic force escalation,
blind retries or automatic torque-off. Stop/faults request hold and cancel later
steps. A task that may have gripped an object never offers the old empty-arm
automatic recovery path.

The existing ghost editor also supports teaching and saving five tabletop
anchors for a fixed station. `left_pick_place` executes that saved route. All
edits remain preview-only until the full task is authorized.

Joint paths are checked against URDF/transport limits and provisional tread
clearance, but camera mounting, encoder mapping and full table/bucket collision
geometry are not yet commissioned. Position-only IK does not certify gripper
orientation. The small lift is a supervised test, not a force/slip detector.
Jaw position, grip force and retention are unmeasured. Completion therefore
reports measured arm arrival and accepted jaw commands with
`placement_verified=false`; it does not claim the can entered the bucket.

## Validation

The plan, approval/session, executor, camera/model rendering and tunnel fixtures
run without hardware. They check typed/invalid observations, depth projection,
distinct-frame confirmation, pointing direction, IK path and jaw boundaries,
tampering, one authorization, loss of feedback after grip, session expiry,
spoken rejection and late startup retry. These checks do not establish a live
successful recycling task. Record the actual commissioning result separately.
