# Messages AI bridge

The Messages bridge lets ROB answer new text messages and optionally analyze a
single still image without speaking in the room. It is intentionally disabled
until an operator configures it locally.

## Setup

1. In Messages, confirm that `rob@orbitusrobotics.com` is signed in and enabled
   as an address that can receive messages.
2. Open **Cerebro → Settings…** (Command-,), then select **Messages**.
3. Keep the receiving account as `rob@orbitusrobotics.com`, or enter the exact
   Messages account Cerebro should monitor.
4. Enter each approved sender's exact Messages email address or phone handle,
   one per line. An empty list rejects every sender.
5. In **System Settings → Privacy & Security → Full Disk Access**, add and
   enable the same Cerebro app build that will run the bridge, then restart it.
6. Click **Request Messages Automation Access**. Cerebro checks the current
   macOS TCC decision, requests consent when it is undecided, and displays an
   explicit granted/required result. Then turn on **Enable replies received by
   ROB in Messages**.
7. To accept images, enable **Allow one image from approved Messages senders**.
   Images remain on the Mac unless you separately enable **Allow approved
   images to be sent to Gemini** and confirm the privacy warning.
8. Open **Services** and verify that **Messages AI Bridge** changes to
   **Listening**. A saved Gemini credential is required for its isolated AI
   sessions.

Bridge startup also performs a non-prompting Automation check and refuses to
enter Listening when Cerebro is not currently authorized to control Messages.

The first successful start records the current Messages database high-water
mark. It does not replay or answer existing conversation history.
Rows are consumed with at-most-once semantics: if Cerebro exits after accepting
a message but before Messages confirms its reply, the sender should send the
request again. If Messages replaces its database and ROWIDs regress, Cerebro
reseeds at the replacement database's current high-water mark rather than
replaying that database as history.

## Isolation and authorization

- Each active chat owns a separate Gemini Live session with text responses,
  microphone and live-camera sources off, Google/news search off, and no
  function or robot-action tools. Approved text is sent to Gemini. A normalized
  still image is sent only when the separate Gemini-image setting is enabled;
  no other Messages history or camera imagery is included.
- Messages replies never call `ROBSpeechBox` and do not appear in the room
  conversation transcript.
- Only incoming plain text, or one JPEG/PNG/HEIC image with optional text, sent
  to the configured receiving account from an exact locally approved handle is
  eligible.
- Only one-to-one chats are accepted. Cerebro rechecks the account, participant
  count, and expected participant handle immediately before Messages sends a
  reply.
- Outgoing messages, self-messages, groups, multiple or non-image attachments,
  stickers, reactions, edits, deletions, service events, stale messages,
  duplicates, oversized text, and unsafe image files fail closed.
- Disabling the bridge or changing its account or allowlist revokes queued
  routes, disconnects the isolated sessions, and prevents their late responses
  from being sent.
- A global five-message-per-minute intake limit bounds automated reply loops.

The inbox adapter opens only `~/Library/Messages/chat.db`, using SQLite
read-only and `query_only` modes. Cerebro never writes that database. Reply text
is sent through the installed Messages scripting interface to the immutable
originating chat; it never falls back to the selected conversation or a new
participant lookup.

Images are accepted only from the Messages attachments directory, limited to
10 MB and 24 megapixels, decoded through ImageIO, resized to at most 2048 pixels
on the longest edge, and re-encoded as metadata-free JPEG before inference.
The normalized bytes are discarded with the completed or cancelled turn.

Gemini is the primary image provider only when cloud image upload is enabled.
Otherwise—or after a Gemini failure—Cerebro runs the image through the on-device
Swift MLX Qwen2-VL model. Apple Foundation Models never receives pixels: it
receives the bounded Swift MLX visual analysis as untrusted data and turns that
analysis plus the sender's text into the final reply. If Apple Intelligence is
unavailable, the bounded MLX response is used directly.

The Messages database and its legacy attributed-text archive are private macOS
implementation details. Cerebro recognizes a narrow, bounded plain-text shape
without instantiating archived classes and fails closed if Apple changes that
shape. Non-image attachments and rich app-message payloads are never decoded.

## Status and troubleshooting

The Services card reports only state, counts, and event age. It does not expose
message bodies, sender handles, account addresses, or provider error payloads.
Expected states include Disabled, Configuration Required, Full Disk Access
Required, Starting, Listening, Processing, Rate Limited, Automation Permission
Required, AI Unavailable, and Error.

If the card remains unavailable:

- **Full Disk Access required:** verify the exact running app is enabled, quit
  Cerebro completely, and reopen it.
- **Automation permission required:** click **Request Messages Automation
  Access**. If access was previously denied, use the alert's **Open Automation
  Settings** action and enable Cerebro → Messages, then click the request button
  again so the bridge rechecks and reloads its configuration.
- **AI unavailable:** save a valid Gemini credential and verify normal Gemini
  connectivity in Services.
- **Listening but no response:** confirm the sender text exactly matches its
  Messages handle, the chat is one-to-one, and the message contains plain text.
- **Services reports a delivery error:** expand **Messages AI Bridge** and read
  **Last delivery error**. It distinguishes Automation denial, send timeout,
  chat/account correlation changes, and Messages AppleScript failures without
  displaying the message body.

## Validation

The deterministic tests use a synthetic WAL-mode `chat.db`, a controlled AI
responder, and a fake reply sender. They do not open the user's Messages data,
contact Gemini, invoke Apple Events, or produce speech.

```sh
xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  Cerebro/ROBMessagesBridge.swift \
  Tests/ROBMessagesBridgeProductionFixtureTests.swift \
  -o /tmp/ROBMessagesBridgeProductionFixtureTests
/tmp/ROBMessagesBridgeProductionFixtureTests

xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  Tests/ROBMessagesBridgeFixtureTests.swift \
  -o /tmp/ROBMessagesBridgeFixtureTests
/tmp/ROBMessagesBridgeFixtureTests

python3 Tests/ROBMessagesBridgeStaticTests.py
```
