# Follow from iPhone without a robot monitor

The iPhone is the stage operator interface. In ROBController build 2, use
**Auto → Open Follow Mode**. The existing **Admin → Follow** route also works.
Opening the screen is navigation only; it does not authorize movement.

1. Connect the paired iPhone to the robot's network and wait for its authenticated
   Cerebro connection. Complete pairing and camera/local-network permissions
   during setup, before taking the monitor away.
2. Open Follow and tap **Refresh Main-Camera Preview**.
3. Select the outlined person in that fresh image. Review the selection, then
   explicitly authorize only when ready for physical movement.
4. Keep Follow status visible and use **STOP FOLLOW MODE** to revoke the target.
   Rehearse manual takeover, target loss, sensor loss, phone backgrounding and
   network disconnection in the actual stage configuration.

The phone now shows its build number on the Follow screen. If a preview never
arrives, it reports a timeout instead of waiting indefinitely. A current
Cerebro reports main-camera failure and expired selections to the phone.

## Camera operation without Mac windows

Follow now owns a main-camera capture request independently of diagnostics,
recording, Gemini, remote video and optional detector settings. A preview
request starts this camera consumer. It remains active while the selection is
valid and throughout authorized following. Stop, controller disconnect,
shutdown, missing-frame timeout, failed person detection and selection expiry
release it. Replacing a valid preview with active tracking does not restart the
camera. Other camera consumers retain their own requests.

This change does not authorize motion when a preview is requested. Existing
explicit target authorization, neck-clearance preparation, depth, belly RGB-D,
authenticated lidar and stop gates remain in force. Camera capture alone is
not evidence that those gates have passed.

## Mac startup is a separate requirement

Cerebro must already be running for the iPhone's Follow, Terminal and Desktop
screens to reach it. They cannot bootstrap their own unavailable server.

`Scripts/install-cerebro-launch-agent.sh` configures the existing supervisor to
start the installed Cerebro app in the robot user's Aqua session at login. It
does not log into or unlock macOS. Establish the login and launch arrangement
before rehearsal, and verify a complete startup with the monitor disconnected.
Do not assume that unplugging a monitor proves a cold boot will work.

At the start of the September 13 inspection, the LaunchAgent file existed but
its service was not loaded, Cerebro was stopped, and its installed binary
predated Follow. After the operator confirmed ROB was physically ready,
Apple Development signed Cerebro 1.0 build 2, built from clean commit `590e83c`,
was installed at `/Applications/Cerebro.app` and started through this supervisor.
The prior app is preserved at
`~/Downloads/Cerebro Before Follow - 2026-09-13.app`.

The running app passed signature verification and remained running through the
startup observation. Its read-only System Services panel reported synchronized
main-camera RGB-D streaming and the QUIC/TLS controller listener ready. Both
depth-camera workers reported streaming. No controller was connected during
this observation; the installed iPhone build 2 still needs a live connection
and supervised Follow rehearsal. No Follow target was selected or authorized.
Normal Cerebro startup and its existing camera-tracking settings can initialize
or move hardware; this was not a motion-free startup test.

Insta360 had no frames and reported connection errors. The depth-camera log
also reported a missing configured `yolov8_chess_6shave.blob` model and disabled
that neural-network stage while RGB-D capture continued. These observations do
not establish complete perception or physical Follow readiness.

## Validation

- Current Cerebro and signed ROBController iPhone builds compile.
- The real Follow coordinator runs in an isolated fixture with hardware services
  replaced by test doubles. Seventeen checks cover camera acquisition without
  a window, no preview motion authority, release on Stop and disconnect, missing
  camera timeout, and protection against an old timeout releasing a newer
  request. Run `Scripts/test-follow-headless-camera.sh`.
- Existing follow safety and phone UI checks pass. Main-camera headless checks
  pass after correcting three stale source-matching assumptions in that test.

These are development builds and software checks, not a public store release
or an end-to-end physical rehearsal.
