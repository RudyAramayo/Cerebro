# Resumed Coke pour: physical checkpoint

Rudy resumed the task after the Halloween pause. **No can has been grasped,
no liquid poured, and no glass pushed.** This is an ongoing commissioning
record, not an executable route or authority for a second controller.

## Current state and ownership

Both arms are active empty position holds. LEFT remains in the raised outward
posture; RIGHT is being observed outside the table edge. The user-confirmed
startup hanging assumption does not describe these active holds. Do not
re-enter Position to refresh state, reset encoders, release torque while
raised, or restart/install Cerebro without a physical handoff.

The running app remains the native assistant-speech build `8a5723c`, session
`9BB4F940-7C24-47E0-B1ED-B4309F54FD5A`. No app installation or restart occurred
during this continuation. The other session finished offline floor-QR work
at `14caf90` and explicitly yielded runtime/UI/audio; that build is not installed.
The [sanitized numerical checkpoint](evidence/2026-10-31-can-pour/resumed-pour-checkpoint.json)
records the latest sampled pose and motion timings. It always needs a fresh
read before another move.

Treads are stopped. Three 750 ms requested forward button holds, with explicit
Stop, produced RGB-D camera displacement estimates of 7.71, 5.98 and 4.86 cm.
Their sum is about 18.5 cm, not calibrated tread odometry. The first successful
drive's observer had already expired during UI troubleshooting; subsequent
camera/Stop checks established its movement, not continuous coverage.

Torso reached count **-2108**, approximately **22.002°** relative to the
historical visually estimated forward count 92. No software reference or
counter reset was made. The first turn failed supervision; a newly reviewed
retry with heavy diagnostics closed reached the target and de-energized,
then reported a 547 ms feedback expiry while stopped. This reliability fault
remains unresolved. The latest observed table normal is approximately 29.84°,
so exact perpendicularity is not established.

Neck commands are **5700 / 6011 / 6200**, without shaft feedback. Automatic
Head Tracking was explicitly switched off after it changed the camera during
an earlier preflight. A camera taken 1.5 seconds after a pan command was still
short of the later view; commanded target is not measured arrival. Scene-based
relative camera registration was used between those images. Do not reuse
fixed image annotations after neck travel.

Robot updates go to the existing **The God Squad** group under the latest
supplied user agreement, with native `speech.say` source `codex`. Wait for
speech and microphone suppression to finish before actuation. Only new God
messages in that group carry Rudy's task instructions; no persistent listener
is claimed. No camera attachment was sent during this continuation.

## Physical progress and checks

RIGHT was raised retaining startup J5; Rudy confirmed its appearance. He then
reported an approach too close to the belly and requested more outward/right
clearance, which was performed. Both arms subsequently reached matched raised
outward travel postures. J5 remains free to change according to geometry; equal
encoder values are not a mirroring requirement.

The latest same-frame floor/table fit measures **0.73253 m** table height,
7.81 mm floor RMS, 4.59 mm table RMS, 4.58° independent-normal disagreement,
and 2.52° IMU-normal disagreement. Camera/model XY and yaw remain estimated.
The glass rim/base rays suggest approximately 172.7 mm height, not metered
capacity. Can radius 33 mm and height 120 mm remain nominal dimensions.

A direct reach failed the table-edge check. An optimized bridge passed native
whole-model self review and full table/cup/can review; only its first stage
was executed. Its two remaining pregrasp/grasp targets were withheld after
the visible gripper disagreed with the nominal model.

The jaw midpoint was approximately **88 mm** from the nominal tool origin,
including about **76 mm** vertical discrepancy in the first full view.
The lower visible pad was initially near tabletop height. A 0.25 rad empty
J7 roll, an 80 mm upward Cartesian proposal, and a 0.15 rad J6 pitch were
reviewed and executed outside the table. The observed lift was 81.4 mm upward;
its complete translation differed from modeled motion by approximately
5.2 mm. This supports only that local differential observation.

A four-pose fit of a constant translation and fixed local pad coordinates
had 8.5 mm training RMS but a condition number of 37.1; a 5 mm input-error
amplification bound was 53.6 mm. An independent nearby orientation missed
its predicted midpoint by 19.7 mm. **Do not promote this fit, change model
zeros/signs, or use it as global registration.** A separately recalculated
12° camera-guided orientation step held its observed midpoint within about
7.4 mm of the local target; that does not commission a full grasp or pour.
Two further camera-guided orientation steps, 25° and approximately 33.2°,
completed outside the table, with both-arm measured arrival and fresh images.
J5 reached approximately 0.543 rad as part of the solved pose. Neither step
was a mirrored-value prescription or an encoder/model calibration.

Every arm move used one native `motion.move`, fresh both-arm feedback,
unchanged runtime/torso/head context, joint/rate bounds, measured completion,
and camera inspection before another move. Native current/Stop controls remain
unchanged. Observed distal clouds supplemented the full-model table review
for the local outside-table steps; they do not observe hidden arm surfaces.

## Software correction and remaining work

`GhostPourRobot.from_status` previously ignored the current torso angle and
silently kept scan zero. It now propagates a supplied finite, in-range heading
to the camera and both arm chains; invalid live heading is rejected. Saved
fixtures that omit torso state retain their explicit model prior. This does
not make an estimated count reference calibrated. The live private analyses
already supplied the 22° value explicitly, so this omission does not explain
their observed jaw mismatch. The source correction has not been installed.

Validation: `Scripts/test-can-pour.sh` passes 19 tests and the compiled native
rigid-payload rendering fixture. Added cases cover nonzero torso propagation,
unchanged arm coordinates, and invalid-heading rejection.

The uncorrected current-scene 62-pose pour IK and native self review passed,
but its can-over-cup transfer failed full workspace clearance by about 0.19 mm.
That route is not approved for execution; increase/replan transfer clearance
and rerun the whole payload review, without reducing its margin. Registration,
actual jaw retention, the timed controller schedule and a supported left-hand
glass-slide route also remain uncommissioned. Do not replay the old bridge
or declare the requested drink served.

Raw RGB-D, scripts and command/feedback logs remain private under
`/private/tmp/rob-coke-pour-20261031/`. Sanitized numerical evidence belongs in
`evidence/2026-10-31-can-pour/`; no images, audio or conversations belong in Git.
