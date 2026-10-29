# Headless arm authorization

Arm operations requested by Cerebro may be authorized on the connected **Vision
Pro or iPhone controller**, or by a **final local microphone acknowledgement**
after ROB asks exactly **“Can I move my arms?”** The complete pending scope is
shown in **Testing Sandbox/controller details**. Rob requested spoken approval
and a 15-minute left-arm rehearsal session on October 22, 2026. One session covers
its included preparation, local searches/recycling, reviewed gestures and
empty-arm lowering without more approvals. Accepting a session only authorizes
it: it does **not** raise the arm or run a preparation/calibration sequence.
Stop, expiry, sleep/restart, ownership loss or a failed motion ends the session.
A perception-only rejection that sent no arm motion can retain the existing
bounded session, but cannot bypass geometry checks. Ordinary typed/model/camera/
serial text cannot authorize. The narrowly scoped local-file exception below
does not add a chat or model authorization endpoint. See [current sandbox behavior](testing-sandbox.md).

## Current four-can local session approval

On October 25, 2026, Rudy explicitly approved this session's job of recycling
four empty Coke cans into the orange bucket without another verbal approval.
He separately permitted a best-available, explicitly unmeasured visual-calibration
trial, with camera checks of possession and delivery. This is a job-specific
exception, not a global approval disable or a verified transform.

In the selected recycling test, save **Number of cans = 4**, then use **Prepare
approved session job**, **Export approval template…**, and **Import session
approval…**. Preparation freezes the physical arm, plural recycling command,
count, summary and current camera/body/connection context without a spoken
prompt. Export and import remain available while this receipt-only request waits.
The exported template is invalid until the actual user instructions and their
UTF-8 SHA-256 hashes are added to the private receipt. Exact private source text
stays outside Git and MainAI context. Only the dedicated local OS file-selection
action imports it; controller, coordinator and model strings cannot do so.

The receipt must be an OS-user-owned private regular file, bind this app session
and exact pending scope, and allow at most 12 hours to begin. An exclusive private
audit record rejects replay; no grant reloads after a crash or restart. Execution
still has its 600-second limit. One grant covers both arms holding stationary
and the selected arm's checked travel and gripper actions. It excludes treads,
torso motion and arbitrary/manual gestures. Stop, feedback or ownership/context
loss, a material motion failure, completion and expiry revoke or consume it.
Only a proven no-travel/no-jaw perception rejection may retain the same exact job.

**Assumed visual error (mm)** is a sandbox-only local-trial parameter (25–150,
default 50), not measured calibration. It is applied before preparation and bound
into the summary/context. Editing it revokes a retained receipt; pending controls
are locked, and a new assumption requires a new exact receipt. Ordinary tests
do not use this allowance.

When current wall depth cannot describe a reflective can, this lane may use an
explicit 120 mm × 66 mm upright Coke-can prior anchored to the same frame's RGB
silhouette and local table plane. It requires independent confirming exposures
and records the assumed shape separately from measured depth bands. A bucket
opening prior likewise records its RGB contour, surrounding floor and admitted
shape/scale range; gravity release must fit their common inset opening. These
priors do not certify a camera transform or enter ordinary registered trials.
Before closing, reacquire the can in fresh pixels; after lifting, inconclusive
possession evidence holds the arm instead of continuing to carry.
If the destination cannot be admitted, this explicit trial may check just the
approach, grip and 6 cm verification lift, then hold. That partial attempt has
no carry, release or automatic return and never counts as a recycled can.

The additional default-off **One slow empty-arm commissioning step** option is
a separate nominal-model experiment. Its receipt freezes that extra permission.
It permits one four-second outward step, at most 60 mm of full-hull travel and
0.20 rad per joint, then measured hold and camera inspection. Original occupied
returns remain checked for nominal contact. Current robot geometry is assumed
from the model; no sensor return is removed or classified as measured self.
Local unseen regions and the assumed
calibration error are recorded as unverified; nominal clearance is not a claim
of physical clearance after that error. No jaw command, grasp, payload, carry,
release, automatic return or chained reach occurs. It records zero transfers.

The separate visual-trial planner must recheck the live receipt before dispatch,
keep the transform unmeasured, and retain observed-obstacle, unknown-space,
whole-arm, payload, joint-bound and Stop checks. An approval or camera detection
does not certify alignment. Feedback loss ends the test; it never permits blind
commands or a claimed successful grasp/delivery.

## Spoken and controller operations

### Direct manual panel control

Native **Amber Arm Diagnostics** and **Torso Servo Controls** buttons take
manual control immediately without asking “Can I move my arms?”. The local
operator's click authorizes its captured arm mode, joint/Cartesian target or
gripper command. **Take manual control** stops automatic motion and requests
hold without sending a new movement; it is optional because each command also
performs that takeover. **Stop + hold** cancels pending manual work and automatic
motion. Neither button lowers the arms or opens a gripper.

The handoff cancels automatic owners before dispatch. Each command remains
bound to the current gateway session and checks original motor/gripper feedback
ages and ownership. Ownership cleanup can wait up to two seconds; a feedback
loss rejects the command instead of queuing it for reconnection. Stop cancels
the wait and delayed SDK dispatch. Targets and gripper intensity are captured
at the click, so later edits cannot change an in-flight command.

Hold/Release uses the selected bounded intensity (2–20) and current-session
calibration acceptance. Calibrate is also a direct local command. Support the
arm before removing torque, clear the jaw travel before calibration or Hold,
and support any payload before Release. An acknowledgement does not verify
physical motion, grasp force or completion. Lost acknowledgements expire and
are reported as unverified outcomes.

Local commands never manufacture voice/controller replies or create a reusable
automatic-motion grant. The older controller-authorized manual session API,
the separate left-arm rehearsal session, and controller-stack recovery retain
their existing scopes; autonomous/model requests cannot inherit a local click.

The droid does not open an arm activation, deactivation, gripper, gesture or
CAN/core recovery confirmation dialog. Enable **Action Approvals** on the paired
controller. Its existing panel shows the immutable operation summary and
Approve, Reject and Cancel controls. The real on-device microphone can also
supply the final human approval; a desktop or model-generated acknowledgement
cannot substitute for it.

One approval covers the complete described operation and its bounded waypoints
and jaw actions. It does not cover unrelated future operations or arbitrary
reaching, and no additional approval is requested per waypoint or per gripper.
Rob explicitly authorized **empty-arm return to hanging and deactivation without
another approval**. Neck-only object search, workspace depth scanning and hanging
inspection also need no arm grant. Measured hanging is still required before
removing holding torque; these exceptions never authorize lowering a payload.

For current **LEFT-arm trials**, every travel segment needs fresh scene
admission, including presentation, approach, carrying and an empty return.
The arms stay stationary while the neck captures RGB-D geometry. A taught,
previously successful or recorded route gets no collision exemption, and the
arm must not park or lower blindly to improve visibility. The complete dynamic
path is checked against observed space, the whole arm/open-gripper envelope and
the carried object when applicable. Unknown space, stale or changed scene,
camera/session context and missing measured camera-to-arm registration block
travel. Operator supervision or an incomplete camera view cannot waive these
checks. A provisional neck transform, floor fit, can-target correction or
self-reported registration success does not provide independently measured
registration and error evidence. Ordinary provisional maps remain visualization
only. The explicit four-can visual-trial lane above is separate and uses a
declared assumed spatial allowance, not measured registration uncertainty.

Automatic empty-gripper setup is a separate, explicitly authorized startup
behavior: after the first authenticated Amber connection, calibrate and perform
the gentle close/open initialization while both arms are freshly measured
stationary, hanging and inactive. It does not lift or activate the arms and needs
no new approval. Recycling reuses this initialization, then opens at the planned
position instead of adding a front-pose calibration pre-step. Stop, loss of
feedback/ownership or connection changes cancel setup; reconnecting does not
silently replay it. Jaw completion remains unmeasured. Explicit preparation and
gripper checks remain separate sandbox tests.

Settings contains persistent behavior preferences. Object-specific trials,
parameters, previews, recordings and session controls live in **Testing Sandbox**.
The launch/wake preference offers the bounded session once; no grant persists
across restart or sleep. The legacy paired-startup preference still requests its
own operation approval. **Paired legacy coordinator routes are not globally
collision-certified by the new left-arm planner**; their existing transport and
route checks must not be described as full-arm depth clearance.

Unheard pending questions repeat with “Hey!” at 20 and 45 seconds, without
changing scope or the 90-second deadline. Each question starts a new microphone
utterance; only a final human transcript can authorize. The current left-session
scope names fixed opening at 10 and gentle can closing at 2. Recorded trajectories
remain review evidence, not automatic recovery permission or clearance. A held,
confirmed-empty arm needs a current measured reference and a freshly checked
dynamic connector before returning; an old executed prefix cannot restore a
grant or exempt the return from the present environment.

The supervised **Grip and return** (`left_object_cycle`) operation uses one
immutable controller approval for the complete physical-left handoff: present the
empty arm, open, grip at raw intensity 2, release into a supporting hand, then
return the empty arm and deactivate. Every arm transition uses the current
scene checks rather than assuming the historical five-segment approach is clear.
Jaw setup is bounded by the selected test; accepted calibration does not prove
jaw opening. Right-arm motion is excluded. The complete execution remains
bounded to 180 seconds by its approval, with the executor's stricter 170-second
deadline.

Three Continue controls record readiness within that active operation: object
placed with fingers clear; receiver supporting the object; object clear of the
jaws. They do not create a second approval or expand the approved path. Only the
currently displayed stage can advance, once. Closing and releasing never happen
on a timer. Until object-clear readiness, the arm stays at the front handoff;
no object-carrying descent is attempted. Stop, controller loss, stale feedback,
camera loss, a changed gateway session or timeout requests hold and ends the
cycle. It does not automatically release a possibly held object. The cycle
records currents throughout, including its waits. Intensity 2 retained the Coke
can in the recorded test, but is not a calibrated force or a measured grasp.

Diagnostics and legacy Torso controls use the broker's explicit local-panel
entry points. Arm side, targets and gripper intensity are captured at the click;
gateway session and hardware interlocks are checked again at dispatch.
The LIVE Startup Test button uses the existing controller-owned startup lane.
The local Gemini debug checkbox no longer bypasses controller approval.
An authenticated Vision controller's fresh gripper intent with both grip buttons
held is already an explicit operator command and needs no desktop grant.

Read-only queries and Stop + hold remain immediate. Cancelling an active arm
operation requests hold; it does not release torque. The fixed CAN/core recovery
script, once begun, is allowed to finish its recovery steps rather than being
killed halfway through CAN setup. Cancellation cannot claim that physical
stopping was verified. The gripper API has no stop command or measured jaw force;
calibration/control acceptance is reported as unverified mechanical completion.

## Transport and failure behavior

Cerebro automatically opens its Amber SSH tunnel and authenticates the gateway
on launch and after system wake when the gateway token is saved in Keychain and
either `~/.ssh/cerebro_amber_ed25519` is readable or an SSH password is saved.
This prepares telemetry without activating either arm. No Diagnostics window
or terminal login is needed. The dedicated key uses direct, noninteractive SSH
with `IdentitiesOnly=yes` and `BatchMode=yes`; it requires neither a saved SSH
password nor `sshpass`. Without that key, the existing `sshpass` path uses the
saved password through an anonymous pipe. A rejected key is reported explicitly
instead of silently falling back to a password. The SSH attempt and initial gateway retries are bounded;
failure remains visible in Amber Diagnostics and an approved operation can make
a fresh attempt. There is no indefinite reconnect loop or motion replay.

On 2026-09-23 the dedicated Ed25519 public key was installed for `amber`,
preserving the robot's existing authorized keys. Its fingerprint is
`SHA256:DUsivvUse1PZfcP22O1aL46/zSQCpygoaIWUvM39YLw`. Private key material
remains in the Mac's `.ssh` directory and is not part of this repository.
The local SSH configuration selects it for `amber`, `amber-master.local` and
`10.0.0.26`. Passwordless login was verified through both hostname and IP, as
was forwarding to the gateway's challenge without authenticating another
gateway controller or taking motor ownership. The key disables agent and X11
forwarding; the local gateway tunnel remains available.

The tunnel runtime fixtures also verify key-only startup with no saved SSH
password, direct SSH arguments, readiness only after gateway authentication,
and key-specific failure reporting. After the controller-approved Relax
completed, passive feedback confirmed hanging within 0.006 radians and all
fourteen motors inactive. Cerebro was reloaded and automatically opened the
dedicated-key tunnel without a password prompt.

Before sleep, Cerebro cancels pending arm approval/routines, requests hold and
closes the tunnel. Wake starts a new gateway session and restores no arm grant.
The optional legacy paired-arm startup route requires a fresh operation approval;
it is separate from stationary empty-gripper setup. A hold request is not proof
of physical stopping; the gateway's motion lease/watchdog remains authoritative.

The iPhone controller now calls attention to pending approvals with a persistent
orange banner, countdown, two-note sound and warning haptic, plus one reminder
after ten seconds. Tapping the banner opens the existing review controls; it
does not approve. The controller must be active with Action Approvals enabled.
ROBController remembers the receive-requests preference across authenticated
reconnects and foreground transitions (default On); explicit Off persists.
Pending requests are cancelled on disconnect/background and cannot be revived
by restoring the preference. Operations outside an active bounded session need a
fresh controller or final local-microphone approval.

Startup/notice update verified on 2026-09-23: tunnel lifecycle fixtures passed,
including missing credentials and repeated startup/wake calls; the approval
broker passed 39 checks. Signed macOS and iOS builds passed. Cerebro was installed
and relaunched, and Diagnostics showed an authenticated gateway without pressing
Connect Tunnel. Startup calibration remained off and no arm operation was run.
Both arm controller streams arrived at about 19.7 Hz, but motor CAN feedback was
stale after relaunch, so motor readiness was not established by this check.
Installed Cerebro debug-library SHA-256:
`59be42a0a97e1b1e5337f5dbdc42f01fd4d1eb4daadb6df0dbabd951bf8a871c`.
ROBController was installed and launched on Onix16. Onix11 refused installation
because it was locked. Alert lifecycle and wire-protocol fixtures passed; actual
phone sound/vibration still needs operator observation using the Settings test.

The existing `com.orbitusrobotics.robot-action` v1 envelope now supports
`arm_operation` with exactly `operation`, physical `arm`, and `summary` fields.
This is a Cerebro-created request; it is excluded from model-proposable actions.
Both controller apps advertise this capability and leave execution and terminal
hardware outcomes to Cerebro.

The broker receives messages only after the control transport authenticates an
operator. It targets the most recently available compatible controller and binds
approval to its device, transport session, sender identity, recipient, and unique
call ID. A duplicated or late Accept cannot start another run. A replacement
session cannot reuse approval. There are no saved broad grants.

If no compatible controller enables approvals within 30 seconds, the request
ends without arm dispatch. A delivered request expires after 90 seconds, giving
the operator time to notice the phone banner and review the whole sequence.
The expiry is fixed when sent; there is no automatic approval or renewal. A
disconnect, withdrawn opt-in, or missing controller hello for 15 seconds cancels
pending work and requests hold for active work. Execution has a 120-second outer
limit; the arm routine retains its stricter 90-second bound. Rejection or expiry
does not silently queue an operation for later execution.

## Validation

- `bash Scripts/test-controller-arm-approval.sh`: production broker and wire
  protocol, with hardware-free tests for identity/session binding, replay,
  rejection, timeout, disconnect, opt-in withdrawal and gateway generation changes;
  local receipt scope, expiry, private import, crash replay and retained-job state.
- `python3 -B Tests/ROBLocalRecyclingSandboxRuntimeTests.py`: dedicated four-can
  UI routing, receipt controls while ordinary edits are disabled, source-text
  privacy and Stop revocation, without opening UI or hardware.
- `bash Scripts/test-arm-routines.sh`: production routine with simulated
  controller approval, gateway acknowledgements, cameras and measured settling.
- `python3 Tests/ROBAmberManualAdmissionRuntimeTests.py`: actual Objective-C
  dispatch method with a simulated approval console and harmless process runner.
- Controller protocol fixtures and Vision `RobotSessionActionApprovalTests`
  verify that approval does not assert physical completion.

The three apps must be updated together. Older controllers do not advertise
`arm_operation` and cannot authorize these new requests. Build/fixture validation
does not substitute for a supervised device-to-robot trial.

### 2026-09-23 validation and installation

The signed macOS, iOS and visionOS builds passed. The 37 broker checks, arm
routine fixtures, manual SDK admission/cancellation fixtures, arm/gripper routing
fixtures, stage/Gemini protocol fixtures and iPhone protocol fixtures passed.
The Vision package passed 121 tests, including the three Cerebro-owned approval
lifecycles. No live arm motion was requested during this change.

Installed and reopened `/Applications/Cerebro.app`; its Arms settings display
the controller approval policy and startup calibration remains off. Installed
ROBController on Onix16. Installation on Onix11 was blocked because the device
was locked; the Vision Pro was unavailable. Their builds are ready for deployment.
Installed Cerebro executable SHA-256:
`3e55a22e4098eaaee90dea5c6b6f0ce1e05d9147bdcf0d76fb27f6cfdef2b404`.
