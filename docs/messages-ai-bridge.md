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
4. Three administrator handles are always authorized:
   `orbitus@orbitusrobotics.com`, `+1 (925) 323-8322`, and
   `mkierie@gmail.com`. Enter any additional approved sender's exact Messages
   email address or phone handle, one per line.
5. Click **Administrator Commands…** to review the command table. The initial
   `Shutdown` command asks the originating administrator to reply `YES` within
   90 seconds, then runs its locally editable zsh script. The command phrase,
   question, confirmation reply, script, and enabled state are configurable.
6. In **System Settings → Privacy & Security → Full Disk Access**, add and
   enable the same Cerebro app build that will run the bridge, then restart it.
7. Click **Request Messages Automation Access**. Cerebro checks the current
   macOS TCC decision, requests consent when it is undecided, and displays an
   explicit granted/required result. Then turn on **Enable replies received by
   ROB in Messages**.
8. To accept images, enable **Allow one image from approved Messages senders**.
   Images remain on the Mac unless you separately enable **Allow approved
   images to be sent to Gemini** and confirm the privacy warning.
9. Open **Services** and verify that **Messages AI Bridge** changes to
   **Listening**. A saved Gemini credential is required for its isolated AI
   sessions, but administrator commands remain available without an AI provider.
10. Optional: enable **Store encrypted transcript memory** and
   accept the retention/privacy warning. Click **View Transcripts…** in the
   Messages settings tab for the readable people/conversation browser. Use
   **Export…** for a plaintext JSON copy or **Clear…** to permanently remove
   the stored transactions.

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

### Administrator commands

Administrator commands are a separate, deterministic path and never enter an
AI prompt. A trigger must be the entire plain-text message in an eligible
one-to-one chat from one of the three exact administrator handles. Matching is
case-insensitive after trimming surrounding whitespace; attachments, partial
phrases, group chats, stale rows, outgoing messages, and duplicate GUIDs cannot
trigger a command.

Cerebro sends the command's configured confirmation question back to the same
immutable chat. Only the configured exact confirmation reply from the same
sender, receiving account, and chat within 90 seconds can execute the saved
script. A reply already queued before ROB finishes delivering the question is
ignored, and each confirmation is one-shot. Disabling the bridge or changing
Messages/command settings cancels pending confirmations. Authorization is
rechecked on the worker immediately before both the question and script.

Scripts are locally authored in the settings editor and run as the signed-in
Cerebro user with the fixed `/bin/zsh -f -s` interpreter and a 30-second limit.
The script arrives through standard input; no inbound message text is ever
interpolated into a shell command, argument, environment variable, or path.
Because scripts have the user's macOS authority, saving changes presents a
local critical warning. The initial Shutdown script asks System Events to shut
down macOS, which may cause macOS to request Automation access the first time.
Command and confirmation messages are consumed by this deterministic path and
are not supplied to the AI.

- Each active chat owns a separate Gemini Live session with text responses,
  microphone and live-camera sources off. It exposes only read-only publisher
  news search and Gemini's server-side Google Search for current public facts
  such as weather; robot-action, Music, file, and device tools remain off.
  Approved text is sent to Gemini. A normalized still image is sent only when
  the separate Gemini-image setting is enabled. Archived history is included
  only when the separate transcript setting is enabled and only for the exact
  same sender and receiving account; no camera imagery is included.
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

## Encrypted transcript and same-sender memory

Transcript retention is opt-in and defaults off. When enabled, Cerebro records
an accepted inbound turn before inference and records the generated reply
before asking Messages to deliver it. If either required archive write fails,
the reply fails closed and is not sent without a corresponding transaction.
Delivery failures and cancellations remain visible in an export for diagnosis,
but only successfully prepared/delivered history is eligible as model memory.

The archive is stored at
`~/Library/Application Support/Cerebro/MessagesTranscript.sqlite3`. Message
text, reply text, delivery errors, sender/account handles, and chat identifiers
are encrypted individually with AES-GCM. Exact-match indexes use keyed HMACs,
and the random 256-bit encryption key is kept in the login Keychain as a
device-only item. The database and its directory are created with owner-only
permissions. Cerebro stores only an image-present flag and optional caption;
it never stores image pixels in this archive.

Memory lookup is restricted to the same canonical sender and receiving account.
It selects a bounded mix of recent and text-relevant exchanges, labels them as
private/untrusted historical data, and never uses archived text to trigger a
news or weather network lookup; Gemini is explicitly instructed to make that
decision from the current message only. This helps answer sender-specific questions
such as previously shared preferences, but the model is told not to treat the
archive as verified truth. The excerpts may span that sender's one-to-one chats
with the same receiving account, but can never be retrieved for another sender.

If Gemini is the active provider, relevant transcript excerpts are included in
the Gemini prompt and therefore leave the Mac. The local text fallbacks receive
the same bounded text; for images, Apple Foundation Models receives it alongside
Swift MLX's visual analysis. Exported
JSON is deliberately plaintext (with owner-only file permissions), so protect
or delete it separately. **Clear Archive…** deletes all retained transactions;
turning retention off stops future writes but does not silently destroy history.

The **Messages Transcripts** window decrypts records only while displaying them
locally. Its sidebar groups history by remote sender and receiving account; the
search field matches people, inbound messages, replies, delivery states, and
errors. Each transaction shows its date, sender text, ROB reply, delivery state,
and whether an image was attached. Because image pixels are deliberately not
archived, the browser shows the caption and an image-present notice rather than
the original picture.

Gemini is the primary image provider only when cloud image upload is enabled.
Otherwise—or after a Gemini failure—Cerebro runs the image through the on-device
Swift MLX Qwen2-VL model. Apple Foundation Models never receives pixels: it
receives the bounded Swift MLX visual analysis as untrusted data and turns that
analysis plus the sender's text into the final reply. If Apple Intelligence is
unavailable, the bounded MLX response is used directly.
If Gemini or Apple Foundation Models returns a generic acknowledgement,
apology, image-access disclaimer, or a reply with no concrete overlap with the
grounded MLX analysis, Cerebro rejects that rewrite and returns the MLX result
instead.

For text requests that fall back locally, Cerebro recognizes explicit
publisher-news and weather intents before inference. News uses the existing
fixed publisher registry, including CNN's current-news sitemap. Weather uses
fixed Open-Meteo geocoding and forecast endpoints and requires the sender to
name a city, region, or postal code; Cerebro never supplies the Mac's location.
The bounded result is passed to Apple Foundation Models and, if needed, Swift
MLX as untrusted data. Neither model can choose an arbitrary URL. If both local
models are unavailable after a successful lookup, Cerebro returns a bounded,
deterministically formatted result instead of inventing current information.

The Messages database and its legacy attributed-text archive are private macOS
implementation details. Cerebro recognizes a narrow, bounded plain-text shape
without instantiating archived classes and fails closed if Apple changes that
shape. Non-image attachments and rich app-message payloads are never decoded.

## Status and troubleshooting

The Services card reports only state, counts, and event age. It does not expose
message bodies, sender handles, account addresses, or provider error payloads.
Expected states include Disabled, Configuration Required, Full Disk Access
Required, Starting, Listening, Processing, Rate Limited, Automation Permission
Required, AI Unavailable, Transcript Archive Error, and Error.

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
- **Transcript Archive Error:** expand the card and read **Last transcript
  error**. Cerebro does not send a reply when the transaction cannot first be
  persisted. Reopen the login Keychain if it is locked and verify the app can
  write its Application Support directory.

## Validation

The deterministic tests use a synthetic WAL-mode `chat.db`, a controlled AI
responder, and a fake reply sender. They do not open the user's Messages data,
contact Gemini, invoke Apple Events, or produce speech.

```sh
xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  Cerebro/ROBMessagesBridge.swift \
  Cerebro/ROBMessagesTranscriptStore.swift \
  Tests/ROBMessagesBridgeProductionFixtureTests.swift \
  -o /tmp/ROBMessagesBridgeProductionFixtureTests
/tmp/ROBMessagesBridgeProductionFixtureTests

xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  Tests/ROBMessagesBridgeFixtureTests.swift \
  -o /tmp/ROBMessagesBridgeFixtureTests
/tmp/ROBMessagesBridgeFixtureTests

xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  Cerebro/ROBNewsSearchService.swift \
  Cerebro/ROBWeatherSearchService.swift \
  Cerebro/ROBMessagesCurrentInformationService.swift \
  Tests/ROBMessagesCurrentInformationFixtureTests.swift \
  -o /tmp/ROBMessagesCurrentInformationFixtureTests
/tmp/ROBMessagesCurrentInformationFixtureTests

xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  Cerebro/ROBMessagesTranscriptStore.swift \
  Tests/ROBMessagesTranscriptStoreFixtureTests.swift \
  -o /tmp/ROBMessagesTranscriptStoreFixtureTests
/tmp/ROBMessagesTranscriptStoreFixtureTests

xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  Cerebro/ROBMessagesVisionReplyPolicy.swift \
  Tests/ROBMessagesVisionReplyPolicyFixtureTests.swift \
  -o /tmp/ROBMessagesVisionReplyPolicyFixtureTests
/tmp/ROBMessagesVisionReplyPolicyFixtureTests

xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
  Cerebro/ROBMessagesTranscriptStore.swift \
  Cerebro/ROBMessagesTranscriptWindowController.swift \
  Tests/ROBMessagesTranscriptWindowSmokeTests.swift \
  -o /tmp/ROBMessagesTranscriptWindowSmokeTests
/tmp/ROBMessagesTranscriptWindowSmokeTests

python3 Tests/ROBMessagesBridgeStaticTests.py
```
