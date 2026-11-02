# Neck startup suppression and mount damage — November 2, 2026

Rudy reported that automatic neck startup no longer ran and the upper camera
servo mount snapped during his recovery attempt. He first shut down upper tilt,
then pan and both tilts. No motor command, power change, calibration, live
preference edit, app installation or restart was performed for this repair.
Keep the neck shut down until the mount is repaired and Rudy explicitly resumes.

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
Do not install/restart, turn power back on, or treat these software checks as
proof of physical clearance until Rudy resumes with the repaired mechanism.

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
It has not been installed or launched.

The live saved servo catalog hash observed during the repair was
`199860f7011e55009e14c774d13bf04740f592481d9dcdba55bf6ef078b6cc38` (SHA-256).
The installed Debug dylib was
`c690b91840604ade399336764f36f211031d9605af99739144319ffb7242a16c`.
These identify the retained live configuration/app, not the new staged build.
