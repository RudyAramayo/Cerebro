# Neck startup suppression and mount damage — November 2, 2026

Rudy reported that automatic neck startup no longer ran and the upper camera
servo mount snapped during his recovery attempt. He first shut down upper tilt,
then pan and both tilts. During the initial offline repair, no motor command,
power change, calibration, live preference edit, installation or restart occurred.
Rudy subsequently authorized installation and launch with servo power off;
that deployment is recorded below. Keep neck power off until the mount is
repaired and Rudy explicitly resumes physical testing.

## Confirmed software cause

Commit `41c59e9` (October 30, 00:01 PDT), **Add local robot control and passive
overnight profiling**, made `ROBPassiveHardwareStartup` bypass
`startSafeNeckStartup` in the Maestro connection handler. It persists in
UserDefaults, so it affects every subsequent launch and reconnect. It is not
limited to the profiling session. The October 31 handoff already recorded it
enabled. Read-only inspection on November 2 again found it `true` in both the
saved preferences and the running local-control status.

The startup catalog was still present as schema 4 with these exact values:

| Phase | Pan | Lower tilt | Upper tilt | Extra hold |
| --- | ---: | ---: | ---: | ---: |
| Lift to upright clearance | 0 (off) | 6011 | 6906 | 0 s |
| Center pan | 5799 | 6011 | 6906 | 0 s |
| Lean forward | 5799 | 7014 | 7698 | 0 s |

These are Maestro command targets, not measured shaft positions. Zero extra hold
does not bypass the existing motion-duration and settling waits. Do not replace
this operator configuration with the newer factory upright final phase.

The main-window connection observer also painted all three enable boxes ON
even when startup was skipped or rejected, and used hardcoded resting slider
fallbacks. This was misleading; it did not demonstrate physical servo power.
The running app displayed commanded values near its lower/upper limits after
the incident, but those cached commands do not establish the powered state,
position, or fracture cause. No synchronized incident trace was available.
The evidence establishes the software suppression, not a new setting change
that day, the actor that enabled it, or a definitive mechanical/electrical cause.

## Repair

- Automatic neck startup is default-on under its own explicit
  `ROBNeckAutomaticStartupEnabled` preference. Passive arm/accessory profiling
  no longer suppresses it. Disabling this specific neck setting prevents new
  automatic startup targets; it does not stop a running sequence or remove
  servo power. Existing Stop/OFF and manual startup behavior remain intact.
- The native connection service still applies Maestro speed/acceleration limits
  before the validated three-phase startup. It retains exact saved targets,
  holds, safety bounds, paired lower/upper writes, settling, cancellation and
  ownership. Camera leveling cannot alter those raw startup phases.
- Unknown/off axes are no longer displayed enabled after skipped/rejected
  startup. UI fallback and manual startup drafts use the saved final phase.
- Read-only local status exposes the automatic-startup setting, progress flag
  and saved phases, so a future disabled startup can be diagnosed directly.

## Laser mount follow-up

Rudy subsequently requested automatic laser servo positioning as well. The same
`41c59e9` passive-startup preference also suppressed the tuck-and-turn sequence
in `ROBBubbleRuntime.maestroReconnected()`. The saved mount calibration remains
tilt channel 6 at 8000, then pan channel 7 at 4000 after 0.75 seconds; both relay
OFF targets remain 4000. Geometry is still unconfirmed. Saved calibration bytes
have SHA-256 `891dfdbfabf3c289f1a4123cde12d36fd2aaa022af92a00581d343b3dda32f3f`.

Laser mount startup now has a separate default-on
`ROBLaserMountAutomaticStartupEnabled` preference and an Arms and motion
checkbox. The passive setting continues to suppress arm offers and automatic
gripper calibration. The mount uses saved targets without rewriting calibration,
records accepted commands in read-only local status, and cancels the pending
pan after Stop, pulse release, manual control or a subsequent reconnect. Relay
OFF and tilt must succeed before pan is dispatched; connection/write failures
report failed startup. Automatic positioning grants no later motor or remote
mount authorization and does not enable laser emission.

The actual runtime fixtures cover default-on startup with passive arms,
non-factory stored targets, exact relay/tilt/pan ordering, persisted opt-out and
re-enable, malformed settings, cancellation, reconnect invalidation and failed
relay/tilt/pan writes. All tests use isolated preferences and inert serial
substitutes. Deployment observations are recorded below after installation.

## Offline verification and deployment

Production-code byte-recorder fixtures exercise the automatic startup gate,
all three ordered phases, cancellation, no connection, no neck writes with
startup disabled, stale UI renders, tracking ownership, explicit OFF and
failure recovery. The real configuration-store fixture covers default-on
behavior, independence from passive profiling, explicit service disable,
invalid settings, exact incident values and persistence across reload.
Native-control fixtures verify accepted phase-1 readouts and disabled/rejected
readouts without opening a window or transport.

The older neck static checker failed on the unmodified parent because it did
not recognize the existing accessory loop's `channel > 2` short circuit. The
checker now recognizes only that exact guarded write inside the allowlisted
animation method; other dynamic writes still fail. No motor gateway was relaxed.
The manual fixture also needed a no-op stub for the existing passive arm UI
refresh before it could compile against current source.

Build command uses a fresh derived-data directory and
`CEREBRO_INSTALL_AFTER_BUILD=NO`. The output is staged outside the installed
application. Physical startup remains untested because the mount is damaged.
The initial deployment hold required Rudy's explicit continuation; the later
installation authorization is recorded below. These checks do not establish
physical clearance, and neck power must remain off pending mount repair.

Passing checks on November 2:

- `Tests/ROBNeckOutputRuntimeTests.py`, including the exact saved safety limits
  with calibration still unconfirmed and camera leveling off.
- `Tests/ROBManualNeckSlidersRuntimeTests.py`.
- `Tests/ROBServoControlStartupMigrationRuntimeTests.py`: 74 checks using
  in-memory preferences only.
- `Tests/ROBSerialSettingsStaticTests.py`, `Tests/ROBNeckSafetyStaticTests.py`
  and `Tests/ROBServoControlStaticTests.py`.
- `Scripts/test-local-control.sh`: policy, image encoding and a temporary Unix
  socket with an inert handler; no robot/device dispatch.
- Full Debug app build with installation disabled; macOS `codesign --verify
  --deep --strict` passed using system trust services. The first sandboxed
  verification could not access trust services; no signature or trust setting
  was changed.

Staged application: `~/dev/output/cerebro-neck-startup-20261102/Cerebro.app`.
This was the initial staged artifact; the authorized deployment below followed.

The live saved servo catalog hash observed during the repair was
`199860f7011e55009e14c774d13bf04740f592481d9dcdba55bf6ef078b6cc38` (SHA-256).
The installed Debug dylib was
`c690b91840604ade399336764f36f211031d9605af99739144319ffb7242a16c`.
These identify the retained live configuration/app, not the new staged build.

## Authorized installation and launch — 12:50 PDT

Rudy explicitly instructed: "install and launch, the servos are off anyway until
I fix it." This superseded the initial installation hold, without authorizing
powered physical testing. The signed `f083fdf` app was installed atomically in
`/Applications/Cerebro.app`, the old process quit cleanly, and the new app
launched as PID 5771. A copy of the previous app remains outside Git at
`~/dev/output/cerebro-neck-startup-20261102/Cerebro-before-install.app`.

Installed Debug dylib SHA-256:
`89bb27558d4f1634b679651262af3972ba80e634f7c400cf533a2c9b71c376bc`.
Strict deep signature verification passed. The saved servo catalog retained
the exact hash above. `ROBPassiveHardwareStartup` remained true, and the new
independent automatic neck startup reported enabled.

Read-only local status captured the running app's phases in order:

1. Pan OFF, lower 6011, upper 6906.
2. Pan 5799, lower 6011, upper 6906.
3. Pan 5799, lower 7014, upper 7698.
4. Startup complete by command timing; final targets remained unchanged for
   at least five seconds afterward. Animation stayed idle and mission inactive.

The app automatically emitted the saved neck startup commands on this authorized
launch. No explicit arm, jaw, torso, tread, power or additional neck command
was requested. Servo power remained off according to Rudy; Maestro does not
measure power or shaft position. This verifies deployment and the command
sequence only. Physical startup and clearance after mount repair remain untested.
The private launch observations and deployment manifest are retained alongside
the staged app outside Git.
