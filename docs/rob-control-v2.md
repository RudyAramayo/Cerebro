# ROB control transport v2

## Production path

Cerebro and ROBController use one reliable QUIC stream over UDP:

- Bonjour service: `_robctl._udp`
- ALPN: `robctl/2`
- TLS: 1.3 with a persistent P-256 Cerebro identity and exact leaf pin
- Device authentication: fresh HMAC-SHA-256 challenge/proof with a 256-bit
  pairing secret
- UDP port: 12345 on Cerebro
- Application frame: 40-byte network-byte-order `RCTL` v2 header
- Maximum framed payload: 4 MiB, enforced before delivery

QUIC provides ordered reliable delivery for control, cancellation, results,
Lidar, and UI messages while retaining the correctly advertised UDP transport.
The code intentionally does not use replayable fast-open/0-RTT control data.

Cerebro persists the canonical certificate DER in a uniquely addressed
Keychain record and installs the matching certificate item only once. One
in-process server-identity context supplies the control listener, video
listener, Bonjour robot ID, server authentication material, and every issued
pairing code. Repeated startup or pairing-panel access must therefore neither
create duplicate certificates nor change the pinned leaf fingerprint.

Encoded camera media does not use this stream. Cerebro advertises a separate
authenticated `_robvideo._udp` / `robvideo/1` QUIC service so media congestion
cannot delay robot-control messages. A video subscription must name the exact
live control-session ID owned by the same authenticated `operatorController`;
control disconnect or credential revocation closes the associated video
connection. See [Vision Pro video transport](vision-pro-video.md).

The v2 frame contains magic, protocol and header versions, message kind, flags,
channel, payload length, monotonic stream sequence, and a UUID message ID. Bad
magic/version, unknown kinds, oversized messages, and non-increasing sequences
fail the connection.

## Pairing and device roles

1. Start Cerebro. It creates a persistent P-256 TLS identity and robot ID in
   the macOS Keychain.
2. In Cerebro, choose **Manage Paired Devices…**, then **Pair ROBController**
   or **Pair RPLidar**, and enter a recognizable device name.
3. Cerebro creates a fresh device UUID and 256-bit secret, stores the
   authoritative role in its device registry, and displays a new
   `ROBCTL2:...` enrollment code. The UI does not reveal a reusable global
   credential.
4. Enter that code only on the intended ROBController or RPLidar publisher.
   The receiving app stores the robot ID, device credential ID, exact SHA-256
   leaf certificate pin, role claim, and application secret in its Keychain.
5. Once pinned TLS is ready, Cerebro sends a fresh random session ID and nonce.
   The device returns a transcript-bound HMAC proof, and Cerebro returns its own
   acceptance proof. Application traffic is rejected until both proofs
   succeed; the entire exchange has a five-second monotonic deadline.

The role in the enrollment payload is informational on the client. Cerebro
looks up the authenticated device UUID in its own registry and makes every
authorization decision from that server-side record. Editing a role claim in a
pairing code therefore cannot grant additional authority.

Each device must receive its own code. Never paste one device's code into
another device or copy an installed Keychain item. A copied code clones the
same cryptographic identity, so the copies cannot be distinguished and
revoking one revokes all of them. Existing role-less v2 credentials decode as
`operatorController` for protocol compatibility; rotate any credential that
might have been shared before enrolling additional devices.

The roles are deliberately narrow:

- `operatorController` may send the established controller/action/autonomy
  application frame and receive controller results. It cannot publish Lidar
  telemetry.
- `lidarPublisher` may send only typed Lidar telemetry frame kind `7`. It cannot
  send controller messages, request motion authority, authorize autonomy, or
  receive generic controller traffic.

Unknown roles and role/frame mismatches fail closed. Authentication proves a
device identity; it does not bypass the per-frame authorization check.

Bonjour TXT data contains only `ver=2`, `alpn=robctl/2`, and `robot_id`. The
controller filters for the robot ID in its installed credential and never
connects to an arbitrary first browse result.

## Legacy compatibility boundary

The historical implementation advertised `_roboNet._tcp` while actually using
plaintext UDP and a host-endian length header. Those exact behaviors now live
only in `LegacyAutoNetFramer` / the legacy transport selection.

Legacy mode is disabled unless one of these is deliberately configured:

```text
ROB_CONTROL_ALLOW_LEGACY_AUTONET=1
ROBControlAllowLegacyAutoNet=true   # UserDefaults
```

There is no automatic fallback from v2. Production call sites request only
`_robctl._udp`. `_roboNet._tcp` remains in Bonjour declarations solely so a
deliberately selected compatibility build can browse it.

Old RPLidar publishers must be migrated to `_robctl._udp` and provisioned with
their own `lidarPublisher` credential before they can feed the unified
production connection. Do not give a publisher an `operatorController`
credential. The RPLidar app must filter Bonjour results by the `robot_id` in
its installed credential, pin Cerebro's certificate, complete the reciprocal
pairing proof, and only then publish telemetry.

Lidar scan/map data uses the versioned `ROBLidarTelemetryMessage` envelope and
v2 frame kind `7`, not generic keyed-archive controller data. Cerebro validates
the schema, authenticated device UUID, monotonically increasing publisher
sequence, capture time, payload kind, and payload bounds before delivering a
sample. The publisher UUID in the envelope is never a substitute for the
authenticated connection identity. Replayed, stale, mismatched, or malformed
telemetry is rejected. Scans are limited to 1 MiB and ten samples per second;
maps are limited to 3,100,000 bytes, 16,384 cells per dimension, and one sample
per second. Samples more than two seconds old or more than five seconds in the
future are rejected. Loss of fresh Lidar input continues to make roaming stop
and wait; a sensor credential cannot directly drive the treads.

During migration, run the legacy adapter only as an explicit compatibility
session. Role and revocation guarantees apply to the v2 path, so legacy mode
must remain disabled during normal multi-device operation.

## Revocation and rotation

Cerebro's paired-device UI lists device name, UUID, role, and status without
showing secrets. Revoking a device creates a persistent tombstone instead of
silently deleting its identity. The server rejects that UUID during future
proof validation and immediately cancels every live connection authenticated
as that device. Every application frame is checked against the role bound from
the registry during authentication; the revocation notification closes the
bound session as soon as the tombstone has been persisted.

Revoking an operator makes Cerebro emit a neutral/braked base state, stop the
USB heartbeat, release the master-controller identity, invalidate its action
advertisement, and end active autonomy. Hardware deadman and emergency stops
remain independent. Revoking a Lidar publisher immediately stops its feed and
ends active autonomy, while leaving an unrelated manual controller paired and
usable.

Rotation revokes the old credential before issuing a fresh device UUID/secret.
The old code and every clone remain rejected. Revocation is server-authoritative;
removing a credential only from the client is an unpair operation, not a
substitute for revoking it in Cerebro.

A deliberate server-certificate replacement is a robot-wide re-enrollment
event because every controller and publisher pins the old leaf fingerprint.
Cerebro preserves its robot UUID and server secret when installing a new
canonical certificate, but operators must revoke stale device credentials and
issue fresh codes. The app must never silently generate a new leaf during an
ordinary restart or while opening the pairing UI.

The first launch after adopting canonical certificate storage is the one
intentional exception: when the canonical DER record does not exist, Cerebro
uses its existing tagged P-256 private key to create and persist one replacement
leaf. Any pre-upgrade controller pin is then stale. In **Manage Paired
Devices…**, revoke the old device entry, choose **Pair ROBController**, and
install that newly issued code on ROBController. Historical certificate items
may be removed during this one-time maintenance, but preserve the tagged
private key, server profile, and peer registry; subsequent launches must reuse
the canonical leaf and fingerprint.

## Identity persistence regression fixture

The standalone fixture uses a temporary file-based Keychain, three fresh
identity-store instances, and real Security.framework certificate storage. Run
it from the repository root in a normal macOS Terminal or Xcode environment;
restrictive sandboxes can reject file-based Keychain creation. It asserts that
all loads return one fingerprint and leave exactly one certificate:

```sh
(
set -e
robctl_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/cerebro-robctl-fixture.XXXXXX")"
trap 'rm -rf -- "$robctl_fixture_dir"' EXIT HUP INT TERM

xcrun swiftc -swift-version 5 \
  -module-cache-path "$robctl_fixture_dir/module-cache" \
  -parse-as-library \
  -D ROB_CONTROL_IDENTITY_FIXTURE \
  Cerebro/AutoNet/AutoNetShared/AutoNetDataTransferProtocol.swift \
  Tests/ROBControlTransportIntegrationTests.swift \
  -o "$robctl_fixture_dir/robcontrol-transport-fixture"

"$robctl_fixture_dir/robcontrol-transport-fixture"
)
```

Current SDKs report deprecation warnings for the fixture-only file-based
`SecKeychain` APIs. Production identity storage continues to use the app's
normal login Keychain; the temporary fixture keychain is deleted on exit.

## Apple Watch companion

The ROBController Watch app does not receive the robot credential or connect to
Cerebro directly. It sends bounded, freshness-checked Dictate and one-stick
Drive commands to its paired iPhone with WatchConnectivity. ROBController
validates them and forwards accepted messages over its existing authenticated
`_robctl._udp` connection. Tread snapshots use a dedicated typed envelope whose
version, numeric ranges, brake flag, and speed cap are checked before Cerebro
constructs a controller model; they do not enter the legacy 14-line parser.

Watch voice arrives as `ROBWatchVoiceText` with a separate bounded
`watch.text` value, so dictation never claims tread authority. Watch Drive uses
the normal controller snapshot format plus explicit
`RequestToBeMasterController` and `ReleaseMasterController` messages. Releasing
the joystick or losing the Watch heartbeat sends a braked neutral snapshot;
Cerebro's controller-expiry and Arduino heartbeat deadman remain independent
fallbacks.

## Connection semantics

- Network.framework `.ready` means only that pinned QUIC/TLS is established.
  `isConnected` becomes true only after the challenge and reciprocal proof.
- `.waiting` is recoverable and removes ready state without destroying the
  browser immediately.
- Stop cancels both connection and Bonjour browser.
- Reconnect callbacks are generation-bound so obsolete connections cannot mark
  a replacement ready.
- Cerebro sends and forwards only through application-authenticated connections
  whose active server-side role permits that frame. Generic controller output
  is never multicast to Lidar publishers.
- Server connections cancel and leave the registry on failure or stop.
- Revoked UUIDs remain as tombstones and cannot authenticate after a restart.

## Deployment checklist

1. Issue a unique `operatorController` credential to ROBController. Revoke and
   replace any older code that was copied between devices.
2. Issue a separate `lidarPublisher` credential to each RPLidar publisher and
   migrate it to `_robctl._udp`; never reuse the controller code.
3. Confirm `_robctl._udp` appears in local-network permission prompts and
   Bonjour diagnostics, and confirm `_roboNet._tcp` is absent from production
   publisher configuration.
4. Test wrong-certificate-pin, wrong-secret, malformed-proof, timeout, and
   cross-connection replay rejection; verify no application callback fires.
5. Test the role matrix: a Lidar credential must be rejected for controller
   frames, an operator credential must be rejected for Lidar frames, and Lidar
   peers must not receive controller broadcasts.
6. Revoke each role while it has a live connection. Confirm immediate
   disconnect, persistent tombstone rejection after restart, and no effect on
   other independently paired devices.
7. Test device-ID mismatch, duplicate sequence, stale timestamp, malformed
   payload, and valid scan/map telemetry fixtures.
8. Test Wi-Fi loss while driving: Cerebro must expire the last controller model,
   write one neutral/braked frame, then cease the USB heartbeat before the
   Arduino deadman interval.
9. Test cancel/result recovery and controller reconnection.
10. Disable the legacy environment/default switch for normal operation.
11. Run the identity persistence fixture, restart Cerebro twice, and verify the
    canonical certificate count and public fingerprint remain unchanged.
