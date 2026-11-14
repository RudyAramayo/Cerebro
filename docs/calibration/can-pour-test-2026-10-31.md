# Coke can timed-pour test

**Latest physical continuation:** Rudy resumed after the Halloween pause.
The base/torso have moved and both arms are active empty holds. The grasp,
pour and glass push are unfinished. See the [resumed physical checkpoint and
gripper observations](can-pour-resume-2026-10-31.md); the older pause and saved
fixture below are not the current live state.

**Testing Sandbox → Coke can · timed pour** reproduces the saved scene in
Cerebro's native ghost planner. The current sequence explicitly previews a
25 cm tread approach, a 16.6° torso turn perpendicular to the observed table
front edge, then the right-arm grasp, pour and supported set-down. The table,
can and glass remain fixed in the world during preparation. No motor commands
are sent. The physical pour and subsequent left-arm glass slide remain unfinished.

Rudy requested half of the remaining contents of an already half-full can,
a fixed-time tilt/hold/return, and preservation of the opening's existing
orientation toward the glass. He also requested a reproducible native test,
corrected the initially tilted and overly tall table, and required the drive
and torso turn to appear before the reach. These corrections invalidate the
previous geometry and its timing results.

## Later physical preparation and Halloween pause

Rudy subsequently authorized physical preparation, approach and pouring,
confirmed both arms hanging, and instructed using hanging as the startup
assumption. Fresh inactive near-zero feedback corroborated that start. The
neck gateway established commanded targets 6000 / 6011 / 6200 in two native
safety stages; these are command estimates, not measured shaft positions.
Both arms entered position holds once from hanging. The native hanging scan
had returned no observations because its views were outside the unknown-neck
envelope; it did not establish the arm posture.

Three coordinated targets completed with native arrival/settling: outward
lift with wrists retained, lift above the treads with wrists retained, then
raised wrist orientation. The full paired model review reported no new/deeper
intersections, and an estimated table/cup review passed with 100 mm added
robot/environment padding. Neither result established physical calibration.

After orientation, Rudy reported RIGHT J5 bent backwards. The dispatched J5
targets were **LEFT -1.213675 rad, RIGHT +1.195716 rad**. Fresh RIGHT feedback
reached approximately +1.195 rad; the log does not show an uncommanded J5
reversal or identical left/right J5 values. The chosen physical pose was wrong.
The cause remains unresolved: do not promote a sign, encoder-zero or hardware
diagnosis, or automatically repeat this pose because the numerical review passed.

Native Stop was requested immediately. Rudy restored RIGHT to hanging; fresh
inactive zero feedback followed. He requested LEFT release and then a pause
for Halloween. LEFT Release 10 was accepted and the camera visibly showed its
open jaws. LEFT returned through the reverse staged entry, reached near-zero
hanging, and was deactivated. The reverse path's modeled overlaps near hanging
were the existing hanging-pose proxies, reviewed against the operator-confirmed
hanging endpoint; they were not relabeled as measured collision-free geometry.
RIGHT remained inactive during the return. The requested right-arm retry was
not sent before the subsequent pause.

Final feedback: both arms mode/status 0, approximately 20 ms old; no animation
or mission running; torso count 92 with its software reference still unset.
No tread or torso travel, grasp, pour, or glass slide was performed. **Physical
testing is paused until Rudy resumes it.** The startup hanging assumption must
not replace fresh feedback, contradict an active hold, or reset encoder zero.

[Sanitized targets, timings and final state](evidence/2026-10-31-can-pour/physical-preparation-and-pause.json)
are committed. Private images, command/feedback logs and review scripts are in
`~/Library/Application Support/Cerebro/CanPourTests/physical-2026-10-31-j5-pause/`.
No model, joint mapping, controller limit or application binary was changed
during this physical attempt or recovery.

## Repeat in Cerebro

1. Open **Testing Sandbox**, select **Coke can · timed pour**.
2. Set fill, fraction to pour, hold time, ghost tread approach and grasp offset.
   The revised saved fixture defaults to **25 cm**, not the previous 40 cm.
3. Choose **Run saved pour test + open ghost**. Each run saves its inputs,
   baseline, log and report in
   `~/Library/Application Support/Cerebro/CanPourTests/<run UUID>/`.
4. Scrub the full 90-pose storyboard: drive first, torso alignment second,
   reach third. The storyboard is not a complete physical execution schedule.
5. **Play timed pour and return…** shows the active wrist segment at real time
   from the already prepared base/torso pose. Full upright recovery remains
   part of the complete storyboard. Reopening a report never actuates hardware.

Run the same fixture with the existing ShadowPlanner Python environment:

```sh
python3 Scripts/plan-can-pour.py \
  --scene Cerebro/Resources/ShadowPlanner/fixtures/coke-pour-scene.json \
  --status Cerebro/Resources/ShadowPlanner/fixtures/coke-pour-status.json \
  --base-advance .25 --hold-seconds .35 --output /tmp/pour-report.json
```

## Measured height and remaining registration uncertainty

Three inspected stationary RGB-D captures gave paired floor/table separations
of **0.7172, 0.7250 and 0.7262 m**. The fixture uses the middle observation,
0.724972 m. Its retained floor and tabletop residual RMS are 8.09 mm and
6.49 mm. The independent plane normals disagree by 4.54° in this capture
(3.72–6.07° over the three captures); this is an estimated plane fit, not a
calibrated uncertainty bound. The observed can rim is 118.9 mm above the
plane, consistent with the explicitly assumed 120 mm can height.

`table_planes.py` fits the inspected floor and table regions independently,
checks agreement and spatial support, then fits their stated parallel-plane
constraint. Plane separation supplies height without neck FK. The complete
camera rotation is corrected to observed up and its vertical origin is
anchored to the floor. Every object uses that same transform. Camera XY/yaw,
robot body attitude and camera-to-arm registration remain estimated.

The scene stores optical observations and the camera prior separately; it no
longer accepts the previous precomputed, vertically wrong table anchor.
Native decoding requires the transformed tabletop height to match the paired
plane evidence. Frozen replay also removes the live presentation-only mesh
lift, which must not raise the measured environment.

The table shape is the visible convex patch reconstructed from inspected
boundary rays. Far corners outside the image remain unknown. Renderer and
collision model use the same polygon and assumed 6 cm thickness. Glass depth
returns background; its rim location still uses its image ray and an assumed
154.6 mm glass height. Raw images/depth stay outside Git; fixture annotations,
input hashes and numerical measurements are committed.

To repeat perception on an inspected private capture:

```sh
python3 Scripts/measure-pour-table.py \
  --capture /path/to/private/capture \
  --observations /path/to/inspected-pixel-annotations.json \
  --scene-template Cerebro/Resources/ShadowPlanner/fixtures/coke-pour-scene.json \
  --status Cerebro/Resources/ShadowPlanner/fixtures/coke-pour-status.json \
  --output /tmp/new-pour-scene.json
```

The fixture's `evidence.inspectedImageAnnotations` contains the pixel region
format. Inspect a new image before reusing those regions; they are not an
object detector and do not authorize automatic physical continuation.

## Base, torso and arm planning

The report contains explicit per-pose `worldFromRobot` transforms. The ghost
robot moves toward a stationary table instead of subtracting a base advance
from the displayed table. Both arms retain the baseline during preparation.
Torso yaw is solved against the table front edge, and the model's forward axis
is checked for perpendicularity. Only after base arrival and torso alignment
does arm IK begin. Native validation rejects missing preparation, early arm
motion, inconsistent base transforms and misaligned torso targets.

The saved torso zero is a model prior, not a measured TIC reference. A 25 cm
geometric drive is not a tread duration or motor command. Sampled whole-body
separation from the visible table/cup is recorded; a complete drive corridor,
chair/table legs, cables, stopping distance and current torso reference remain
unverified. `baseRouteChecked` therefore remains false.

The corrected lower table required another IK branch. A numerical descent
from a solved raised grasp supplies a seed for the low grasp; this adds no
physical preparation motion and does not relax collision or joint limits.
20, 25 and 30 cm candidates solved the complete arm pose sequence; 40 cm did
not. The saved 25 cm candidate yields 90 complete body/arm review poses.

The cylinder model assumes a 66 mm diameter, 120 mm height and 25 mm opening
lip radius. Ideal onset is 67.38°; one quarter capacity remaining corresponds
to 79.30°. The opening remains attached to the can and pivots over the cup.
Foam, venting, shoulders and flow transients are not modeled; this is not
metered volume. The entire can clears the protected cup rim plane.

The revised active segment starts at a prepared 55.81° tilt, reaches 79.30° in
**2.193 s**, holds **0.350 s**, starts its reverse at **2.543 s**, and returns to
the prepared angle at **4.736 s**. Its actual dryness is unverified. A quintic
clock and analytical derivative bounds enforce 0.30 rad/s, 0.60 rad/s² and
2 rad/s³; the reverse retraces the same curve. Final interpolated raw targets
remain within ±2.09 rad. No overlapping vendor cmd4 dispatch was added.

## Saved-fixture blockers before the later physical resume

All current poses solve kinematically, but the route is **not collision clear**.
The model reports a baseline left-tool/track overlap of about 77 mm, blocked
torso rotation and inadequate right upper-arm/forearm separation. The active
pour now also fails that self-clearance requirement; the old claim that its
328 samples passed applies only to the invalid-height fixture. The visible
outline rejects the requested left-glass slide's support margin. No verified
left-arm pushing trajectory exists.

The historical right-arm/head strike was missed by the model. Tool offset,
open-jaw geometry, body posture and camera/arm registration remain unresolved.
Native completion and successful IK are not evidence of physical clearance.
The controller handoff investigation and measured-completion guard remain
unchanged; no core or streaming fix was commissioned.

The first scene inherited about 18° of tilt from a nominal neck transform and
used an oversized rectangle. The first correction made it horizontal but
retained a wrong **95.5 cm** anchor, with an additional live mesh display lift.
Rudy identified both failures. The earlier 25 cm / 5.07 s and 40 cm / 6.84 s
results are superseded. The current paired-plane source and native rejection
tests prevent those scenes from being silently replayed as current evidence.

No arm mode, jaw command, arm trajectory, base travel or torso turn was sent
during the initial saved-fixture work described in this section. Earlier neck-only search and read-only torso counter selection
located the can, ice-filled glass and occupied keyboard seat on ROB's left.
Counter 92 matched historical forward count, but software alignment was unset.
Latest inspected frames show the can and glass still on the table.

## Validation and installation

`Scripts/test-can-pour.sh` covers 17 geometry, timing, collision and perception
regressions, including synthetic noisy/outlier plane recovery, independence
from neck-prior height, and drive/torso ordering with stationary arms/world.
It also compiles the actual native rigid-payload rendering transform.
`Scripts/test-can-pour-native.sh` reruns the fixture, checks full/timed native
decoding and rejects sixteen invalid model, authority, pose, time, table-height
and body-preparation cases. Existing full-scan collision tests are preserved.

The combined build retains the other session's native assistant speech and
surface texture fixes (cb67fde, c9e7e67 and 733e0dd). Those changes do not supply
registration. Build verification uses `CEREBRO_INSTALL_AFTER_BUILD=NO` as an
xcodebuild **setting argument**; an environment variable alone is overridden
by the project's install setting. Installation/relaunch must remain coordinated.

The final combined Debug build passed and its strict signature was verified.
All three installed Mach-O hashes match the tested build. Passive relaunches
kept both arms inactive with identical feedback; no neck target was replayed.
Native run `A4A7A35F-7804-43BB-BD0E-75E61603F98E` generated the 90-pose report.
The final renderer visibly showed the entire blue robot at the 25 cm arrival,
then the torso at 16.6°, while the table/can/glass stayed fixed. The 72.5 cm
height and disabled live display offsets were visible in the native panel.

UI inspection caught an extra renderer defect: body translation was initially
applied after ghost-visibility comparison, hiding links whose joints had not
changed. Translation now participates in each link's frame before comparison;
whole-body travel was then verified in the installed app. Frozen fixture world
coordinates are also independent of the live robot/map presentation transform.

The native timed action replayed 222 samples through the final `return` phase
at 4.736118 s. Execution remained disabled. The final running session was
`9BB4F940-7C24-47E0-B1ED-B4309F54FD5A`.
The report SHA-256 is
`211423fb6012bc2639972abb22c36afd970fed36ba7ad7532ae2fc1be3e04f1d`;
the installed `Cerebro.debug.dylib` SHA-256 is
`c690b91840604ade399336764f36f211031d9605af99739144319ffb7242a16c`.
All installed hashes are recorded in the sanitized evidence JSON.
The previous run `7D61FA16-4512-41A3-AD94-466C4F9A3933` and report hash
`2810debf87f74bb01f366d4712b956a9fbb4e497faa5ed0746bbb189390192c3`
are retained only as superseded history. The earlier browser viewer is retired.
