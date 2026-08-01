# ROBControl server

`AutoNetServer` is the Cerebro endpoint for the v2 robot-control plane. It
advertises `_robctl._udp` and carries framed application messages over a
reliable QUIC stream protected by TLS 1.3. A connection is not exposed to the
application until certificate validation and the pairing challenge complete.

## Production usage

```swift
let server = AutoNetServer(
    service: ROBControlPairing.serviceType,
    port: 12345,
    dataDelegate: receiver
)
try server.start()
```

`sendMessage(_:)` multicasts only to authenticated operator peers. Each paired
device has a unique secret and an authoritative server-side role.
`lidarPublisher` peers may send only the typed Lidar telemetry frame and never
receive controller broadcasts. Persisted revocation closes matching live
connections immediately; `stop()` closes the listener and all active
connections.

Use Cerebro's **Manage Paired Devices…** control to issue a fresh role-specific
code for each ROBController or RPLidar device and to revoke a device. Never
reuse one device's code for another device.

The historical `_roboNet._tcp` advertisement actually carried plaintext UDP.
It is available only through the explicit legacy transport mode after setting
`ROB_CONTROL_ALLOW_LEGACY_AUTONET=1` (or `ROBControlAllowLegacyAutoNet` in
`UserDefaults`). V2 never falls back to it.
