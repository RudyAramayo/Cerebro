# Administrator remote desktop host

Cerebro exposes its main macOS display to **Admin → Desktop** in ROBController without
enabling macOS VNC or opening a password-authenticated RFB port.

The display is a demand-driven source on the existing TLS 1.3 QUIC video service. It is
advertised as camera ID `desktop`, supports JPEG frames for ROBController and H.264 for
existing ROB video clients, and stops capture when the last subscription ends. Capture
is latest-only at up to 960 × 540 and six frames per second.

Authorization requires all of the following:

1. A mutually authenticated, non-revoked `operatorController` credential.
2. The exact live `robctl/2` session UUID on the independent `robvideo/1` connection.
3. A completed encrypted Administrator face profile whose trusted enrollment reference
   exactly matches that controller ID.
4. macOS Screen Recording permission for viewing and Accessibility permission for input.

Input frames are claimed before historical robot command parsing. Coordinates are
normalized and bounded; text is valid UTF-8 capped at 4 KiB; only an explicit key
allowlist and modifier mask are accepted. Revocation, server shutdown, tab closure, or
session replacement releases a held primary mouse button. Text becomes synthetic Unicode
keyboard events for the focused app—it is never evaluated as a shell command by Cerebro.

## Verification

```sh
swiftc Tests/ROBVideoTransportCompileStub.swift \
  Cerebro/AutoNet/AutoNetShared/AutoNetDataTransferProtocol.swift \
  Tests/ROBRemoteDesktopControlProtocolFixtureTests.swift \
  -o /tmp/ROBRemoteDesktopControlProtocolFixtureTests
/tmp/ROBRemoteDesktopControlProtocolFixtureTests
swiftc Cerebro/ROBVideoProtocol.swift Tests/ROBVideoProtocolFixtureTests.swift \
  -o /tmp/ROBVideoProtocolFixtureTests
/tmp/ROBVideoProtocolFixtureTests
python3 Tests/ROBRemoteDesktopSecurityStaticTests.py
xcodebuild -project Cerebro.xcodeproj -scheme Cerebro \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```
