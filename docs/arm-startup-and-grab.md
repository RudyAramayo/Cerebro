# Arm startup, relax and front-pose grasp attempts

Settings → Arms contains **Calibrate arms on startup** (off until selected),
Run startup now, Prepare to grab, Relax arms and Stop + hold. Enabling startup
authorizes one attempt after launch or system wake. Failure ends that attempt;
there is no indefinite retry or delayed activation after the 90-second limit.
Explicit `arm_control` prepare/grab/hold/relax commands are available independently
of that preference. Direct chat and addressed local speech also recognize simple
commands, including “relax”, “grab this” and “hold this”. Negations, quoted text,
“hold on”, and discussion about grabbing are not local motion commands.

Both physical arms use the following taught corridor. The right column uses
L10, gateway `left`, UDP 26001. Physical left uses the negated vectors through
R11, gateway `right`, UDP 26002. J3–J7 remain zero throughout:

| Waypoint | Right J1 | Right J2 |
| --- | ---: | ---: |
| Hanging | 0 | 0 |
| 1 | 0 | −0.15 |
| 2 | 0.15 | −0.30 |
| 3 | 0.30 | −0.45 |
| 4 | 0.45 | −0.60 |
| 5 | 0.75 | −0.60 |
| Front | 1.05 | −0.60 |

Each segment takes four seconds, with both arms dispatched together and three
distinct, stable measured position samples spanning at least 150 ms before
advancing. The motion portion is about 26 seconds. Camera inference, gateway
setup and gripper checks add time. Average joint speed is at most 0.075 rad/s;
this is not a measured peak speed or acceleration claim. Missing vendor velocity
is never replaced by zero.

Startup verifies camera-observed hanging at encoder zero for the authenticated
controller session. It preserves the commissioned B1/URDF references. This is a
bounded startup readiness routine, **not a new seven-joint visual offset fit**.
The separately recorded folded pose is not part of this route. An unknown pose,
off-route wrist/elbow, new session away from hanging, or ambiguous view blocks
motion. Interrupted positions on the taught segments can return along that
same corridor within the verified session.

The forward and belly RGB-D streams run independently of preview visibility and
optional detector settings. During a routine they request 640×400 capture to
reduce dual-camera transport latency, then restore the normal capture demand.
An explicit recording resolution retains priority. A read-only local MLX inspection requires visible,
clear arm paths; missing/occluded evidence blocks. The input frames retain their
capture times and sequence, old inference is rejected, and scene changes veto
the result. A separate Vision hand detector, current depth coverage, stationary
neck view, current per-motor CAN replies and a 1.5-second gateway lease supervise
motion. These checks are conservative observations, **not a certified geometric
collision model**. An unprepared neck or unavailable vision model ends the run
with a visible reason. Text seen by cameras cannot supply motion instructions.
The neck uses the existing reviewed upright clearance staging, then moves only
camera tilt to the inspection view. Head tracking pauses during inspection.
Passive torso slider refreshes cannot overwrite that pose; explicit manual
neck input retains priority and a changed view stops the arm routine.
Model tool requests also require a matching recent addressed user transcript;
camera content, stage dialogue and unsolicited model output cannot authorize them.

Only after both arms arrive in front does the routine calibrate the physical
right and left grippers, one at a time, then open them at vendor intensity 10.
It reports calibration as `accepted_unverified`: Amber has no measured jaw
position or force/completion telemetry. Open jaws must subsequently be observed.
Calibration is reused only within that same session, avoiding recalibration
around an object during the next grab request.

Grab/hold attempts use the same preparation. A close is attempted only when the
requested object is already visible between exactly one open gripper's jaws and
hands are clear. A subsequent image checks whether the object remains between
closed jaws. `grip_attempted` is never a claim of a force-verified secure grasp.
`ready_for_object` means the arms are prepared, with no object in closing reach.
General reaching, lifting, automatic force escalation and the unvalidated folded
animation remain unavailable until camera-to-arm geometry and complete routes
are validated.

Relax follows the reverse corridor, checks both measured hanging targets, then
deactivates both arms and verifies all fourteen modes inactive. A failed return
requests a measured hold; it never drops torque early or opens a held object.
An already inactive pair at zero remains inactive. Stop cancels pending startup
and active work and requests a hold; it does not initiate a relax movement.

## Physical observation on 2026-09-23

With Rob's authorization, both grippers were calibrated while both arms were
in front. Physical left/R11 accepted command 11 at 11:37:36.757 PDT; physical
right/L10 accepted command 12 at 11:37:58.323 PDT. Jaw movement was observed;
vendor completion/force was not measurable.

The two arms returned together from right `[1.05, −0.60, 0, 0, 0, 0, 0]` and
its physical-left mirror through the listed reverse waypoints, four seconds per
segment, checking camera clearance and current individual joint CAN feedback.
Physical right accepted deactivation command 13 at 11:41:24.957 PDT and physical
left command 14 at 11:41:35.971 PDT. Final telemetry showed all fourteen joints
at `0.00000` radians, all fourteen inactive, with current per-motor CAN replies.
These were supervised manual operations preceding the new software build; they
are not evidence that the new automatic routine or general reaching was tested
on hardware.

Run `bash Scripts/test-arm-routines.sh` for the production coordinator with
asynchronous simulated hardware. No robot sockets or SDK are linked. It covers
startup ordering, physical-side binding, calibrated grab reuse, stale camera
hold, return-before-deactivation, unknown poses and missing CAN feedback.

## Software validation on 2026-09-23

The signed macOS Debug build and isolated arm routine fixtures passed, as did
the gateway compatibility, arm binding, Gemini protocol, realtime adapter and
neck output and camera preview fixtures. The neck output fixture reproduces stale torso sliders
during inspection, verifies that they cannot undo camera positioning, and
verifies that an explicit manual neck command still takes priority. The 31
Python regression checks and neck structural checks also passed.

The gateway initial-refusal/recovery loopback fixture timed out in this
environment with both the changed client and the unchanged client from
`cc3d916`. This is a known validation failure, not a passing check. Live SSH
connection and current per-motor telemetry were subsequently verified through
the app; a transient SSH authentication failure cleared on a manual reconnect.

The installed build passed `codesign --verify --deep --strict`. Its
`Contents/MacOS/Cerebro.debug.dylib` SHA-256 is
`ce70f41fbb8d449db966deaaad1a001d34bac6e0c2f0cf37a542b1b3f64ab929`.
The unrelated pre-existing storyboard label changes were preserved locally
and excluded from this source change.

Live checks verified that the inspection neck pose now survives the passive
torso renderer. The new Relax command returned “Both arms are measured at
hanging zero and inactive” with live gateway feedback. This tested the
already-hanging case; the new automatic moving return is covered by fixtures,
with the route itself exercised manually as recorded above.

**Full automatic startup and grasp remain blocked in the current camera setup.**
One check reported a forward frame age of 324 ms with 97% usable depth, while
belly frames arrived 689 ms old and failed the 400 ms input-age limit. A further
check with 640×400 capture still reported belly input age 931 ms. The cameras
were visibly streaming; streaming alone did not satisfy capture freshness.
Both arms remained inactive throughout those attempts. There was no automatic
forward motion, new automatic gripper calibration, or physical grab completion
to report. Startup preference remains off. Clear full-path camera coverage and
the existing missing camera-to-arm extrinsics also remain requirements for
broader reaching; the taught route does not resolve those limitations.
