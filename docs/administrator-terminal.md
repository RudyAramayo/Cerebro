# ROBController administrator PTY host

Cerebro owns every shell shown in ROBController's **Terminal** tab. It starts `/bin/zsh`
as an interactive login shell in `~/dev` (falling back to the user's home directory),
with `TERM=xterm-256color`. That makes the installed `codex` command and the user's normal
login-shell configuration available without copying credentials into the controller app.

Access requires both layers below:

1. The incoming ROBControl connection is a mutually authenticated, server-authorized
   `operatorController` connection.
2. The encrypted face gallery contains a completed Administrator profile whose
   `trustedEnrollmentReference` exactly matches that authenticated controller device ID.

The face itself is not accepted as a network credential. A known-person profile, an
incomplete enrollment, a revoked controller, a legacy connection, or a lidar publisher
cannot open a PTY.

Each controller can own at most eight shell processes. Every terminal has independent
request/response sequences, bounded frame sizes, current rows and columns, and a 512 KiB
reconnect backlog. Replies are targeted to the exact controller and authenticated network
session rather than broadcast. Credential revocation and Cerebro shutdown terminate all
affected shells.

## Verification

```sh
swiftc Tests/ROBVideoTransportCompileStub.swift \
  Cerebro/AutoNet/AutoNetShared/AutoNetDataTransferProtocol.swift \
  Tests/ROBAdministratorTerminalProtocolFixtureTests.swift \
  -o /tmp/ROBAdministratorTerminalProtocolFixtureTests
/tmp/ROBAdministratorTerminalProtocolFixtureTests
python3 Tests/ROBAdministratorTerminalSecurityStaticTests.py
xcodebuild -project Cerebro.xcodeproj -scheme Cerebro \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```
