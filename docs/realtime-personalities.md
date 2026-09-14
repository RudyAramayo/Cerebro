# Gemini, OpenAI and Dual Personality

Implemented September 14, 2026. The running Cerebro process was not restarted
during this change, and no hardware commands were exercised by the tests.

## Operator setup

After a coordinated launch of the updated build, open **Settings → AI
Personalities**. Save each provider's API key with the provider selector and
**Save in Keychain**. Keys are separate and the field never displays a saved
secret. The OpenAI API uses its own account/billing; a ChatGPT subscription or
this coding conversation does not supply its credential or conversation memory.

Choose **Gemini**, **OpenAI**, or **Dual Personality**. In Dual Personality,
choose the driver explicitly. Set character descriptions, installed macOS
voices, and the exchange length, then press **Apply & Switch Driver**. Applying
ends the current show, issues the existing software stop/hold path, cancels
pending AI gestures and replaces the provider sessions. Finish a current
physical move before applying. This resets the cloud conversations.

| Mode | Wake-gated raw microphone | Enabled sampled camera composite | Action proposer |
| --- | --- | --- | --- |
| Gemini | Gemini | Gemini | Gemini |
| OpenAI | OpenAI | OpenAI | OpenAI |
| Dual Personality | Selected driver | Both providers | Selected driver only |

The connection, microphone and camera controls are shared operator preferences
across modes. Camera source selection remains in **Settings → Perception**.
With raw microphone streaming off, the existing Apple Speech path submits
recognized text. Cameras still carry the same freshness and orientation labels;
neither provider can derive a calibrated grasp or collision clearance from
those labels alone.

**Start Banter** begins the fictional Orbit/Atlas exchange. Ordinary driver
replies also start an exchange in Dual Personality. Each character has its own
cloud conversation and voice preference. ROB finishes speaking one line before
relaying quoted text to the other model. The default is three total spoken
lines, configurable from two to six, with a 90-second deadline for scheduling
further lines.
**Stop Banter**, an interruption, a new user turn, a show start, or a driver
switch ends the exchange. Missing peer credentials or a peer failure ends the
exchange; it never silently transfers motion ownership.

## OpenAI adapter

`ROBOpenAIRealtimeSession` uses the documented GA WebSocket API and defaults to
`gpt-realtime-2.1`. The model is editable, or set with
`OPENAI_REALTIME_MODEL`. This is an OpenAI Realtime model, not GPT-6 Astra.

The adapter resamples Cerebro's 16 kHz mono PCM16 input to 24 kHz, uses server VAD
with explicitly owned responses, and sends the existing JPEG composite at most
once per second. It retains only two standalone image items in the OpenAI
conversation. This is sampled image input, not a native continuous video stream.
Responses use **text output and ROB's local speech queue**, including the two
character voices. Streaming OpenAI audio output is not enabled.

Implementation references: [Realtime conversations and GA event examples](https://developers.openai.com/api/docs/guides/realtime-conversations),
[Realtime model modalities](https://developers.openai.com/api/docs/models/gpt-realtime-2.1).
Conversation latency and grasp accuracy have not been compared on ROB.

`OPENAI_API_KEY` takes precedence over the OpenAI Keychain entry. An explicit
false `OPENAI_REALTIME_ENABLED` disables loading that provider. These flags
default to enabled:

- `OPENAI_REALTIME_STREAM_AUDIO` and `OPENAI_REALTIME_STREAM_VIDEO`: initial
  input defaults when OpenAI is the driver; saved shared Settings take precedence.
- `OPENAI_ROBOT_ACTION_TOOL_ENABLED`: exposes the existing robot and loiter tools.
- `OPENAI_NEWS_SEARCH_ENABLED` and `OPENAI_APPLE_MUSIC_ENABLED`: expose the
  existing local services. OpenAI has no Google Search tool in this adapter.

Keys are sent only in the Authorization header to `api.openai.com`; the endpoint
cannot be overridden through a model string. Diagnostics record generic failure
details rather than raw server payloads or credentials. Event-specific counters
currently describe Gemini; frame counters aggregate enabled sessions in Dual
Personality and reset on reload.

## Motion and Show ownership

The router namespaces provider call IDs within ROBController's wire limit and
returns each result to its originating provider and raw call ID. Only the
selected driver reaches the existing action executive. Every duet-context tool
call is rejected, including a tool call from the driver during its comedy line.
OpenAI also sets `tool_choice: none` on duet responses. Camera text, character
descriptions and quoted peer dialogue cannot grant physical permissions.

Priority stop/pause remains independent of ordinary tool sequencing. Other
actions still need the existing controller authorization, reference checks,
leases and measured completion. OpenAI does not inherit a Gemini-only arm-debug
grant. Neither model gets raw servo authority or an uncalibrated chess-pick tool.
Cancelled/failed physical requests are not replayed through the other provider.

Show's existing cloud improvisation route now follows the selected driver.
Historical `geminiTurn` cue names and delegate selectors remain compatible;
authored cues, local Foundation Models/MLX direction, timeouts and offline
fallback still use the existing coordinator. Show replies retain their exact
request context and never start background dual banter. Authored motion cues
remain separate from dialogue generation.

## Verification and remaining rehearsal

Run `bash Scripts/test-realtime-adapters.sh` for socket-fixture tests of GA
envelopes, settings, PCM chunk continuity, turn/tool correlation, concurrent
tool-result delivery, microphone barge-in, wake-gate closure, camera revocation,
provider routing, peer rejection and bounded playback-driven dialogue. These
tests use no cloud services and link no robot hardware runtime.

The full macOS build and the existing Show/Foundation/loiter/Gemini, settings,
speech and camera checks are also part of validation. No OpenAI credential was
available in the process environment or Cerebro's OpenAI Keychain entry during
implementation, so an authenticated cloud session, acoustic echo behavior and
physical motion still need a coordinated rehearsal. Start with dialogue and
camera descriptions, then separately authorize loiter and named gestures. Chess
execution continues to wait for the commissioned URDF and measured calibration
described in [the September 25 demo assessment](maker-faire-2026-robot-intelligence.md).
