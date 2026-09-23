# Controller-approved show rehearsal

Settings → Arms → **Motion rehearsal…** prepares the first bounded look and
greeting trials. **Check cameras (no movement)** records five seconds of main
face RGB-D health without issuing neck, arm-mode, joint or gripper commands.
While that check is active, ordinary body motion outputs are inhibited.

The rehearsal buttons request one authenticated iPhone/Vision Pro approval for
the complete described operation. They do not grant motion locally. The existing
`play_gesture` controller protocol carries the immutable summary, so the current
controller apps need no new message type. Stop cancels subsequent steps and
requests arm holds. A neck ramp already sent to the Maestro can finish at its
last commanded target; this interface has no measured neck stop confirmation.

## First paths

| ID | Sequence | Finish |
| --- | --- | --- |
| `show.neck-scan.v1` | Reviewed upright lower/upper targets 6011/6906; saved center, center +333, center, center −333, center | Arms remain hanging; neck holds center |
| `show.look-and-greet.v1` | Same look, then the existing paired front-arm greeting, including camera inspection and calibration/opening of both empty grippers when required in the gateway session | Arms remain in front |

The saved center on the current robot is 5781. Its sequence is therefore
5781 → 6114 → 5781 → 5448 → 5781, approximately ±10° in command space.
The coordinator requires the reviewed upright posture in all three saved
center/left/right presets, the standard pan scale, and containment within the
saved pan limits. It uses the existing supervised operator neck gateway with
its coupled clearance staging. It does not change the neck calibration flag
or enable arbitrary model-supplied targets. This is a bounded audience scan;
it does not yet locate or track a particular person.

Before neck dispatch, both arms must have fresh CAN feedback, seven measured
positions within 0.08 rad of hanging, and uniform inactive or position modes.
The neck must be active with known commanded targets. Base/follow/autonomy are
stopped, torso must be disarmed, and both arm reservations are held. Camera,
gateway generation, configuration, hanging pose and competing neck commands
are checked throughout the neck steps. Each neck step has a ten-second limit;
the neck stage has a fifty-second limit. These are deadlines, not intended
durations. Camera processing and paired arm timing run locally, without a model
round trip or approval at each waypoint.

The arm stage retains its existing inspection, scene-change veto, empty-jaw,
mode, lease, feedback, corridor and ninety-second limits. The parent approval
has a 120-second outer limit. No general reaching, torso yaw or body-lean path
is introduced. Those still require camera/actuator registration and physical
clearance trials.

## Model binding and evidence

Both Gemini Live and OpenAI Realtime discover these IDs under
`robot_capabilities.show_paths`. They may propose `robot_action` with
`{"action":"play_gesture","gesture":"show.look-and-greet.v1"}` only after
that exact path has completed a controller rehearsal with the current
configuration. Every subsequent run still needs one controller approval and
fresh runtime checks. Stage-origin calls and overlapping actions are rejected.

Receipts are written to
`~/Library/Application Support/Cerebro/ShowRehearsals/<UUID>.json`. They contain
the result, configuration fingerprint, camera ages/analysis duration, neck
command targets and arm telemetry samples. The fingerprint includes neck
configuration, saved bounds, servo speed/acceleration and arm corridor revision.
Changes invalidate model availability. No image or invented neck shaft
measurement is saved. `command_path_rehearsed` is not collision certification
or proof that a neck shaft reached its command; physical observation remains
necessary. A completed neck component remains available if the later arm
inspection fails; the failed combined greeting stays unavailable. The first
installed version's receipts can recover that neck component only from its
post-neck-completion result marker and a matching configuration fingerprint.
This restores evidence and never grants motion approval.

## 2026-09-23 validation

The camera-only check in the installed app completed. Across 52 valid samples,
main-camera input age was 244 ms median (210–418 ms), and analyzed-frame age was
377 ms median (244–577 ms). Median analysis duration was approximately 13 ms;
usable depth was approximately 66%. The final frame had 67% usable depth and
passed the freshness gate. The 400 ms incoming-frame and 700 ms analyzed-frame
limits were preserved. This observation points to capture/transport and the
analysis sampling interval contributing more latency than inference in this
five-second check; it does not isolate depth processing from USB/capture time.
The existing motion camera demand uses the smaller realtime profile.

Camera receipt: `280B8593-3EBC-45CA-8F3A-21F45801D171.json`.
Receipt SHA-256:
`22698afcc53b5f3e6df5fa7dcc9aa0c63efd3ff0d72e511f8b182a92a330bef6`.
The first combined request expired while the operator missed the controller
prompt. The original broker collapsed pre-approval terminal replies into
rejection; it now preserves the controller's expiry/cancellation/failure reason.

The operator approved the next combined trial. The complete neck sequence ran
in approximately **10.7 seconds** including preflight. Command targets changed
to center at 0.9 s, left at 2.5 s, center at 4.7 s, right at 6.7 s, and center at
8.7 s, then completed its settling checks. The operator confirmed the movement
looked smooth and clear of cables. This is the first observed neck path; shaft
position remains unmeasured.

The subsequent arm stage positioned the inspection camera, then stopped at
**21.1 seconds** with "Camera inspection was ambiguous; the arms remain held."
Both arms reported zero joint positions and all seven modes inactive throughout
the recorded trial. No arm activation or gripper calibration occurred. Camera
analysis age stayed below 597 ms, so this failure was not the freshness gate.
The live main-camera view showed a nearby person's hands/legs and furniture;
both hanging arms and their complete routes were not clearly visible. The
combined greeting, arbitrary reaching, torso and body lean remain unvalidated.

Live receipt: `0DA4D143-17AC-4AD2-A1BC-86226689DD39.json`.
SHA-256: `af31c9e2b6259849c9d6bd3c2cd6b61c149cd8f71f3f25f48f3efcd2085c79f0`.

Hardware-free validation covers one approval across all neck targets and the
greeting continuation, unrehearsed model rejection, invalid saved posture,
configuration changes, camera loss, manual interruption, Stop, receipt creation,
reservation cleanup, and recovery of a completed look after an arm-stage veto.
Neck runtime fixtures exercise production output code
to verify passive rendering/tracking yields during routine ownership. Existing
arm fixtures cover measured greeting completion and front-before-gripper order;
approval and Realtime adapter fixtures cover authenticated grants and both
provider adapters. These tests do not establish physical clearance.

The macOS Debug build and strict signature verification passed. The previous
installed app is preserved at
`/private/tmp/Cerebro-before-show-rehearsal-20260923.app`.
The final build was installed at `/Applications/Cerebro.app`, relaunched, and
its Arms settings and Motion Rehearsal window were inspected. Arms were idle
and startup arm calibration remained off.
Installed `Cerebro.debug.dylib` SHA-256:
`142c28b43f291ddb8b4b45ced85d52d34c3dc601eb1b3bfc7a3702be8727acc2`.
After relaunch, the window recovered the completed look from the live receipt
and reported the combined greeting still awaiting a successful result.

Passing checks: `test-show-motion.sh`, `test-controller-arm-approval.sh`
(39 checks), `test-arm-routines.sh`, `test-realtime-adapters.sh`,
`test-amber-arm-binding.sh`, `ROBNeckOutputRuntimeTests.py` and
`ROBNeckSafetyStaticTests.py`.
