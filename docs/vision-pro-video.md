# Vision Pro video transport contract

This document defines the initial camera-streaming contract between Cerebro and
the ROBController Vision Pro application. Normative requirements use **MUST**,
**SHOULD**, and **MAY**.

## Transport boundary

Video uses a data plane that is independent of robot control:

```text
_robctl._udp / robctl/2        safety, robot control, live-session authority
_robvideo._udp / robvideo/1    video auth, negotiation, feedback, and media
```

- The video service **MUST** use TLS 1.3 QUIC, Bonjour type
  `_robvideo._udp`, UDP port 12346, and ALPN `robvideo/1`.
- It **MUST** reuse Cerebro's persistent TLS identity and the controller's exact
  certificate pin, but use a video-specific authentication transcript domain.
- No control, autonomy, Lidar, cancellation, or emergency-stop message may use
  the video connection. Video congestion or failure must not delay or close the
  `_robctl._udp` connection.
- Video capabilities, subscribe/response, unsubscribe, receiver feedback,
  codec configuration, access units, and stream-ended events all use the
  authenticated `_robvideo._udp` connection in the current implementation.
- The initial data plane is one ordered, reliable QUIC stream. QUIC datagrams
  are not advertised until both applications implement and test them.

## Authentication and session binding

Only a paired `operatorController` may authenticate to the video service. A
`lidarPublisher`, legacy plaintext peer, revoked credential, or invalid proof
**MUST** be rejected.

1. The video connection pins Cerebro's existing certificate and proves
   possession of the paired device secret using a fresh challenge/proof whose
   HMAC domains are specific to `robvideo/1`.
2. After reciprocal authentication, Cerebro sends `ROBVideoCapabilities` on the
   video connection.
3. The same operator must also have a live authenticated `_robctl._udp` session.
   Its 16-byte control session ID is represented on the video wire as a UUID.
4. Every `ROBVideoSubscriptionRequest` supplies that `sessionID`. Cerebro accepts
   the request only when it exactly matches the live control session registered
   for the authenticated video connection's controller ID and that session has
   the `operatorController` role.
5. A connection may own at most one active subscription. Cerebro permits at
   most two authenticated video controllers and two total streams.

Loss or replacement of the matching control session, unsubscribe, credential
revocation, role change, video disconnect, or application shutdown **MUST** end
the associated stream. A video connection does not count as a second control
session.

There is currently no one-time video-channel grant. Adding a short-lived,
single-use grant bound into the video proof is optional future hardening. A
second optional future design may move video capabilities and
subscribe/response/unsubscribe/feedback onto authenticated `robctl/2`, leaving
`robvideo/1` media-only. Neither behavior is part of the current wire contract.

### Video authentication bytes

All UUIDs below are their 16 RFC 4122 bytes. Authentication payloads start with
version byte `1` and use these fixed layouts:

| RVID message | Bytes after version | Total bytes |
|---|---|---:|
| `authenticationChallenge` | channel ID (16), server nonce (32), robot ID (16) | 65 |
| `authenticationProof` | channel ID (16), controller ID (16), client nonce (32), client MAC (32) | 97 |
| `authenticationAccepted` | channel ID (16), controller ID (16), server MAC (32) | 65 |

The transcript is the UTF-8 bytes `robvideo/1\0`, followed by the complete
65-byte challenge, controller-ID bytes, and client nonce. The client MAC is
HMAC-SHA-256 with the pairing secret over
`ROBVIDEO-AUTH-V1/CLIENT-PROOF\0 || transcript`. The server MAC covers
`ROBVIDEO-AUTH-V1/SERVER-ACCEPTED\0 || transcript || clientMAC`. A proof is
single-use because each connection receives a fresh random channel ID and
server nonce.

## Negotiated initial profile

The first production profile intentionally uses a conservative per-viewer
resource budget:

- codec: H.264, constrained-baseline where supported;
- representation: AVCC length-prefixed NAL units, never Annex-B start codes;
- maximum dimensions: 960 x 540, preserving aspect ratio with letterboxing;
- maximum frame rate: 20 frames per second;
- maximum average bitrate: 1,500,000 bits per second;
- frame reordering/B-frames: disabled;
- key-frame interval: no more than one second.

The subscription response reports request limits clamped to the server maxima
above, with dimensions rounded down to even values. Neither side may assume the
requested values were accepted unchanged. Receiver feedback may later lower the
active encoder bitrate within that accepted limit, but it does not renegotiate
the stream descriptor. This version does not dynamically reduce dimensions or
frame rate in response to camera capability or encoder load.

## Message contract

### Authenticated video negotiation

- `ROBVideoCapabilities` describes the current `front` camera and its supported
  H.264 reliable-stream limits. Cerebro sends it immediately after video
  authentication.
- `ROBVideoSubscriptionRequest` carries plain UUID `sessionID` and `id` fields,
  a camera ID, ordered codec preferences, delivery mode, and maximum width,
  height, frame rate, and bitrate.
- `ROBVideoSubscriptionResponse` either rejects the request with a typed reason
  or accepts it with a `ROBVideoStreamDescriptor`. It carries no channel grant.
- `ROBVideoReceiverFeedback` carries the same UUIDs, bounded loss, jitter,
  decoded frame rate, an optional desired bitrate, and an optional key-frame
  request. Cerebro clamps bitrate between 250,000 bits per second and the
  negotiated bitrate, and applies bitrate changes no more than once per second.
- `ROBVideoUnsubscribeRequest` carries the same UUIDs. A matching request ends
  the active stream; a request received when no stream exists has no effect.
- `ROBVideoStreamEnded` reports the session ID, subscription ID, and bounded
  reason string.

These negotiation messages are JSON payloads capped at 64 KiB and travel only
on `_robvideo._udp`. Cerebro rejects unknown JSON fields, validates decoded
stream descriptors through the same limits as locally constructed values, and
normalizes receiver loss/jitter/frame-rate feedback before it reaches the
encoder.

### Encoded media

- `ROBVideoCodecConfiguration` carries plain UUID session/subscription IDs,
  codec, positive configuration generation, raw SPS and PPS NAL units, and the
  AVCC NAL-length field width. It precedes media for a new generation and is
  resent with a requested recovery key frame.
- `ROBVideoEncodedAccessUnit` carries the same UUIDs, codec, positive sequence,
  capture and presentation timing, duration, key-frame flag, configuration
  generation, AVCC length width, and one complete AVCC access unit.

Receivers **MUST** reject session, stream, codec, generation, ordering, or size
mismatches before creating decoder state. Current hard limits are 64 KiB for
raw codec parameter-set bytes and 2 MiB for one access unit. Both media
structures use a fixed, network-byte-order `RBVD` v1 binary header; H.264
payloads remain AVCC and must not be converted to Annex-B on the wire.

The `RBVD` header is 92 bytes: magic `RBVD` (4), version (1), kind (1), codec
(1), flags (1), header length (2), reserved zero (2), payload length (4),
session UUID (16), subscription UUID (16), sequence (8), capture Unix
milliseconds (8), presentation timestamp (8), duration (8), timescale (4),
configuration generation (4), NAL-length width (1), parameter-set count (1),
and reserved zero (2). Integers are big-endian. Configuration payload entries
are kind (1), three zero bytes, byte length (4), and the raw NAL bytes.
Parameter-set kinds are `1` VPS, `2` SPS, and `3` PPS.

The outer ordered-stream `RVID` frame is 32 bytes: magic `RVID` (4), version
(1), header length (1), message kind (2), payload length (4), four reserved
zero bytes, monotonic connection sequence (8), and eight reserved zero bytes.
Message-kind values are `1` challenge, `2` proof, `3` accepted, `4` rejected,
`5` capabilities, `6` subscribe, `7` subscription response, `8` unsubscribe,
`9` feedback, `10` codec configuration, `11` access unit, and `12` stream
ended. Media kind values inside `RBVD` are `1` configuration and `2` access
unit; codec value `2` is H.264 and flag bit zero marks a key frame.

## Backpressure and safety

Cerebro retains only the latest offered raw camera sample while server work is
pending. Each subscribed connection permits one encoder output pending and
exactly one media send in flight; there is no encoded-access-unit backlog.
Camera capture and encoding never wait for network capacity.

If a connection is still encoding or a media send is in flight, Cerebro drops
the newer unencoded raw frame silently. Replacing an unencoded raw frame does
not break the decoder chain and does not require an IDR. An actual VideoToolbox
drop, an encoded output that cannot be delivered, changed codec state, or an
explicit receiver recovery request forces an IDR; codec configuration is
resent with that recovery frame.

Every `RVID` send has a 10-second completion deadline, and the complete
configuration-plus-access-unit media chain is bounded by the same interval. A
peer that stops reading is disconnected instead of retaining a subscription or
accumulating media. If a stream ends while its configuration is in flight,
Cerebro suppresses the retired access unit and will not start a replacement
stream until that bounded send has drained.

Video listener, connection, encoder, and feedback work run on queues separate
from the main and control queues. There is no synchronous dispatch from video to
control. The total configured video bitrate remains capped because both QUIC
connections still share the physical network.

## Lifecycle

The video listener may remain available for the Cerebro application lifetime,
but camera encoding is demand-driven and starts only for an accepted, bound
subscription. The camera capture owner must be independent of camera-window
visibility: Cerebro keeps capture running while either the preview is visible
or at least one remote subscription is active, without restarting capture for
redundant demand notifications. Camera callbacks are bound to their DepthAI or
AVFoundation capture run; queued callbacks are invalidated and drained across
stop/restart so a frame produced by a retired run cannot enter a new stream.

While the camera manager's current state is `unavailable`, a newly authenticated
connection's one-time capabilities message omits the camera, new subscriptions
receive `cameraUnavailable`, and an active stream is ended. Cerebro treats
`stopped`, `connecting`, and `reconnecting` as unknown availability: it may
advertise and accept a subscription so demand can restart capture. Capability
changes are not pushed on an already authenticated connection. A newly accepted
subscription has 15 seconds to produce its first encoded frame, and no later
encoded-frame gap may exceed 15 seconds. Cerebro sends `ROBVideoStreamEnded` and
releases camera demand after either startup or mid-stream camera stalls instead
of reserving an indefinite black stream.

Shutdown stops new subscriptions, ends active streams best-effort, discards
queued media, invalidates encoders, closes video connections and the video
listener, then stops the control listener. Shutdown must not wait for a blocked
media send. A video-listener or camera failure disables video only; robot
control remains available.

## Sender validation

Run these from the Cerebro repository root:

```bash
xcrun swiftc -swift-version 5 -warnings-as-errors \
  -module-cache-path /tmp/CerebroVideoModuleCache \
  Cerebro/ROBVideoProtocol.swift Tests/ROBVideoProtocolFixtureTests.swift \
  -o /tmp/ROBVideoProtocolFixtureTests
/tmp/ROBVideoProtocolFixtureTests

xcrun swiftc -swift-version 5 -warnings-as-errors \
  -module-cache-path /tmp/CerebroVideoEncoderModuleCache \
  Cerebro/ROBVideoProtocol.swift Cerebro/ROBCameraH264Encoder.swift \
  Tests/ROBCameraH264EncoderSmokeTests.swift \
  -framework AVFoundation -framework VideoToolbox \
  -framework CoreMedia -framework CoreVideo \
  -o /tmp/ROBCameraH264EncoderSmokeTests
/tmp/ROBCameraH264EncoderSmokeTests

xcodebuild -quiet -project Cerebro.xcodeproj -scheme Cerebro \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/CerebroVideoDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The encoder smoke test creates a synthetic BGRA camera sample, scales it to
NV12, asks VideoToolbox for H.264, and validates the resulting IDR, SPS/PPS, and
AVCC access unit through the same wire model used by the server.

## Initial limitations

- H.264 reliable streaming only; no HEVC, JPEG-frame, or QUIC-datagram delivery.
- One monoscopic camera source; no stereo, spatial-video, depth, or audio track.
- At most two authenticated video controllers, with one stream per controller.
- Live viewing only; no recording, replay, or server-side retention.
- Reliable delivery can cause head-of-line delay within video after packet loss,
  although it cannot block the separate control connection.
- Video access requires the full `operatorController` role; a future view-only
  role requires a separate authorization-policy change.
- The current video proof authenticates the paired operator but is not itself
  bound to a control session or single-use grant; the subscription's exact
  session-ID check supplies the live-control authorization boundary.

## Vision Pro adapter next steps

1. Declare and browse `_robvideo._udp`, filter Bonjour results by the paired
   robot ID, require ALPN `robvideo/1`, and reuse the existing certificate pin.
2. Implement the `robvideo/1` challenge/proof and reciprocal acceptance using
   the video-specific HMAC domains, then decode capabilities from that same
   connection.
3. Encode subscribe/feedback/unsubscribe and decode subscription responses and
   stream-ended events on `_robvideo._udp`, not on the control connection.
4. Map Cerebro's plain UUID wire fields explicitly: use the live control-session
   UUID directly and convert any Vision-side subscription wrapper to and from
   its UUID `rawValue`. Do not encode wrapper structs where the wire expects a
   JSON UUID string or 16 raw UUID bytes.
5. Adapt `ROBVideoCodecConfiguration` and `ROBVideoEncodedAccessUnit` into the
   Vision pipeline's decoder models, validate the `RBVD` header and AVCC payload,
   and feed the H.264 display surface.
6. Send periodic bounded feedback, request a key frame after decoder loss, and
   unsubscribe when the view disappears, the scene is suspended, or the control
   session changes.
7. Add localhost tests for wrong pin/secret, mismatched or stale control-session
   UUIDs, malformed or oversized media, reconnect cleanup, two-controller
   capacity, and a stalled video receiver while safety traffic continues on the
   control connection.
