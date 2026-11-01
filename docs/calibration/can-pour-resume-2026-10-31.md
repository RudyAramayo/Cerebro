# Resumed Coke pour: physical checkpoint

**Physical testing ended for sleep on November 1.** The second pour delivered
Coke with Rudy catching/repositioning the glass, but he reports asymmetric
wiggle, liquid spilled on the table, and the cup pushed too far back. This was
an assisted delivery with a spill, not an accurate autonomous pour. The can
was returned to its original spot, released standing, and RIGHT retracted
80 mm. No LEFT slide occurred. Rudy is cutting arm power and requests offline
work on selectable object/spout pivots for future sessions. No automatic
motion, activation, calibration, installation or restart is authorized now.
The earlier failed pour and intermediate held-can states below are history.

## Current state and ownership

At the final read-only check, motion was not running and arm feedback was
21–29 seconds stale. Cached mode/status 2 and the old "robot holding" message
do not establish powered holding after shutdown. LEFT's last observed pose
was raised/empty; RIGHT was empty after the verified release and retreat.
Physical work needs explicit resume, fresh feedback and a new scene review.

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

Neck commands are **5700 / 6011 / 6600**, without shaft feedback. Upper neck
was moved from 6200 to 6600 for the loaded-can view. Its observed image shift
was substantially larger than the nominal head model predicted. Automatic
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

### Grasp, failed pour, and wrist adjustment

The later operator-requested 60 mm approach reached a visually accepted grasp
pose. Its ordinary 15 mm nonpad foreground-margin review failed (about 10.6 mm
estimated separation); it was performed as an explicitly scoped, supervised
visual trial with positive estimated separation and full native self review.
Do not relabel that as a routine clearance pass or promote its registration.

The first RIGHT Hold 2 was acknowledged without visible closure. The approved
pose was saved in native Animation Studio as
`D11EB719-41CC-4CDC-8796-2F361AC48F13` at revision 1, review-required. On Rudy's
instruction, RIGHT retreated 60 mm, used the native empty-jaw calibration and
Release 10, then returned to the exact saved pose. Rudy reports calibration
nudged the can 15 mm: the assumed empty clearance was inadequate. No extra
15 mm reach was added. The subsequent Hold 2 visibly closed; Rudy confirmed
success and the can followed a 20 mm retention lift. Never calibrate a loaded
jaw or substitute an acknowledgement for retention.

A larger upright lift and transfer remained retained but exposed further
model error: the fitted can center differed by roughly 6 cm after lifting,
and transfer overshot left by roughly 5 cm. An invalid four-inlier camera fit
was discarded. A recent-frame registration with 246 inliers and 0.461 pixel
RMS supported the local visual correction; this is not global calibration.
Rudy identified the left-side opening, requested a 20 mm move toward the
table back, and confirmed it centered before the pour.

Native sequence `7D1D9B4D-C1F9-4935-A40B-0DE999DE37D4` at revision 2 ran
30° → 55° → nominal 79.3° → 55° → 30° → upright. It retained native measured
completion between clips, fresh feedback, current/Stop guards, and one motion
owner. The authored total was 10.567 s; monitored completion took 21.992 s.
This was not a fixed-time compiled trajectory or a metered liquid delivery.
The model predicted no more than 3.51 mm horizontal spout error during possible
flow, with native self and modeled workspace checks passing. **Rudy reported
zero liquid and approximately 76 mm of real pouring-edge displacement.**
The arm also occluded the can during much of the rotation, and the glass was
moved during the attempt. Native arrival is not physical pouring success.

The can returned upright in motion `0825E784-8A86-41F3-AC42-DCAA191E6100`.
The failed sequence remains as evidence, renamed to identify failure; every
clip now has `needsReview: true` at verified native library revision 3. It must
not be replayed unchanged.

On Rudy's J1/J5/J7 instruction, motion
`C8DD6C04-27E6-43DE-B2E4-395B7513EB0E` backed J1 off approximately 2.86° with
coordinated compensation. The modeled spout moved at most 1.16 mm and can
orientation changed at most 0.18°. The observed upright can-top template moved
one pixel horizontally (correlation 0.970). This supports the small upright
reconfiguration only; it does not validate depth, the opening's pivot, or the
full rotation. The second upright reconfiguration and pour followed later.

An offline fixed-edge continuation approached the J1 bound at 95° and failed
the pose tolerances at 100°. Ninety-six alternate endpoint seeds at four
opening heights found no valid 160° solution for that fixed tilt direction.
This is a search result, not proof that all alternative grasps/postures are
impossible. A separate rigid-root/pad fit still missed independent observations
by up to 16.4 mm at the midpoint and 26.1 mm at an individual pad, with condition
number 118. It was not installed or accepted as calibration. Joint limits,
signs, offsets and native transport guards remain unchanged.

### Assisted second pour, set-down and shutdown

Motion `992F8C89-7EE7-4A46-AC99-1A6B86C78BB4` backed J1 off another roughly
9.5° while coordinating the wrist. Its modeled spout wandered up to 16.47 mm;
the visible can top shifted about 20 pixels right and 19 pixels up. This was
not a fixed physical pivot or a calibration result.

The next private 160° candidate allowed both rotation-plane azimuth and opening
height to vary. Its 14 clips had nominal angles 0, 30, 60, 90, 120, 140, 160,
then the reverse and the original upright hold. A 1.2 s tilt hold was included.
Native self/workspace checks passed, with maximum modeled horizontal opening
error 11.64 mm. J7's target was −2.08 rad inside the unchanged ±2.09 raw bound.
The authored duration was 26.602 s; native measured completion took 50.186 s.
This was a sequence with settling, not a fixed-time continuous motor curve.

Motion `56C06670-B6C5-4E38-86C4-D68C94BC9E83` visibly produced a stream into
the glass while Rudy held/moved it underneath. The can returned upright.
Rudy then reported spill, asymmetric wiggle and cup displacement. The precise
contact mechanism and spilled/delivered volumes were not measured. Outward
and return target arrays alone did not establish symmetric physical motion.
The changing plane/height, interpolation, execution timing and unverified
object attachment must be distinguished; no single root cause is proven.
Sequence `6C284A33-DD1F-4F34-BF9C-3ED4A5AB04C1` is now labelled assisted
with spill, all clips review-required, at verified native library revision 7.

Return `9953C816-359F-439A-A803-4FA7DFF7873B`, final support descent
`8FD87FBF-F06B-4AEE-AC69-350C75CF3E2F`, RIGHT Release 10
`D93C0C82-1FCE-49D0-AE54-716E9F3FC7FF`, then empty 80 mm retreat
`04D15832-87E9-4987-ACF6-E32D2D6CDC9C` completed. Images show the can
standing and the open hand clear. The modeled can base still differed from
visible table support by roughly 50 mm. The return sequence also requires
fresh review. No LEFT or post-pour neck motion was dispatched; the glass
slide and several model-rejected head proposals remained planning only.

Rudy requested an immediate "Start filming now" cue before every motor action.
That rule is saved in home and repository steering and was used for the pour,
return, final descent, release and retreat. It is a notice after preflight,
not another approval request. Shutdown supersedes all pending motion plans.

### Earlier empty-hand preparation

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

The earlier torso fix passed 19 tests plus the native rigid-payload fixture.
The subsequent pivot work, regression cases and reproduction instructions are
recorded in [the object-pivot planner note](object-pivot-pour-2026-11-01.md).

Earlier, the uncorrected current-scene 62-pose pour IK and native self review passed,
but its can-over-cup transfer failed full workspace clearance by about 0.19 mm.
That route is not approved for execution; increase/replan transfer clearance
and rerun the whole payload review, without reducing its margin. Registration,
the full pouring-edge trajectory, the timed controller schedule and a supported
left-hand glass-slide route remain uncommissioned. Actual jaw retention was
later confirmed as described above. Do not replay the old bridge or failed
pour, or describe the assisted spilled delivery as calibrated autonomous service.

Raw RGB-D, scripts and command/feedback logs remain private under
`/private/tmp/rob-coke-pour-20261031/`. Sanitized numerical evidence belongs in
`evidence/2026-10-31-can-pour/`; no images, audio or conversations belong in Git.
