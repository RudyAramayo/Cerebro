# Legacy AutoNet client adapter

This folder is not the production controller implementation. It contains the
only adapter allowed to reproduce the historical `_roboNet._tcp`-advertised,
plaintext-UDP behavior for a deliberate compatibility session.

Before constructing `LegacyAutoNetClient`, set
`ROB_CONTROL_ALLOW_LEGACY_AUTONET=1` or enable the matching
`ROBControlAllowLegacyAutoNet` `UserDefaults` key. Without that explicit opt-in,
the adapter refuses to start.

```swift
let client = try LegacyAutoNetClient()
client.dataDelegate = receiver
client.start()
```

Production control lives in ROBController and uses `_robctl._udp`, QUIC/TLS
1.3, an exact Cerebro certificate pin, and the reciprocal pairing challenge.
There is no automatic downgrade from v2 to this adapter.
