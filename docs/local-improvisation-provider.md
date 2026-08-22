# Local improvisation provider

## What is implemented

Cerebro now has a model-neutral local improvisation provider and an implemented,
contract-validated `llama.cpp` HTTP client. Its first job is deliberately narrow: act as a
local stage director for `gemini_turn` show cues.

```text
validated stage cue + authored fallback
                  |
                  v
 schema-constrained local stage director
                  |
                  | ROBLocalImprovisationPlan v1
                  v
       +----------+-----------+
       |                      |
       | Run Local            | Run Adaptive
       v                      v
 validated offline line   trusted brief from enums
       |                      |
       v                      v
  ROBSpeechBox            Gemini Live + current
                          camera/audio context
                                  |
                                  v
                            ROBSpeechBox
```

The local plan contains only an allow-listed beat, delivery style, and short
offline spoken line. Cerebro validates the generated JSON a second time and
rejects unknown fields and obvious control language. Only the two enums—not
free-form local model text—enter the Gemini brief that Cerebro constructs. A
local plan is never turned into joints, gestures, SSH, shell commands, or robot
actions.

The stage coordinator preserves the cue's total deadline. Local inference gets
at most 35 percent of an adaptive cue, capped by the configured local timeout;
Gemini receives the remaining time. Late local completions are correlated and
discarded after timeout, cancellation, or cue advancement. Timed-out Gemini
stage turns are cancelled by context identifier so they cannot leave the queue
after fallback.

## Start a llama.cpp server

Cerebro does not download a model, install `llama.cpp`, or launch a server. This
avoids a multi-gigabyte surprise at app launch and keeps an inference failure
outside the Cerebro process.

With a compatible GGUF chat model already present, a typical launch is:

```bash
llama-server \
  --model /absolute/path/to/model.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  --alias cerebro-local \
  --ctx-size 4096
```

The official server defaults to `127.0.0.1:8080`; keeping the explicit host is
useful during show setup. Do not bind a Cerebro stage model to `0.0.0.0`.

References:

- <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>
- <https://github.com/ggml-org/llama.cpp/blob/master/docs/install.md>

## Configure Cerebro

1. If the adaptive line should use live sight or sound, open **Settings →
   Gemini**, connect the session, enable the desired camera/microphone inputs,
   and verify the video encoded/sent counters before opening the show.
2. Open **Show…** from the main window.
3. Enable **Use local stage director**.
4. Select **llama.cpp server**.
5. Enter `http://127.0.0.1:8080` and model alias `cerebro-local`.
6. Leave the initial timeout at three seconds.
7. Choose **Save Local**, then **Test Local**. The test checks `/health`, requests
   a harmless schema-constrained rehearsal plan, and validates the result. A
   loading or incompatible server is reported without terminating Cerebro.
8. Use **Run Local** to verify offline speech before using **Run Adaptive**.

The panel reports provider state, request/success/fallback counts, last latency,
and a sanitized error category. It does not retain prompts, responses, audience
transcripts, camera frames, credentials, or raw server bodies.

The endpoint is restricted to the literal loopback addresses `127.0.0.1` or
`::1`, using the server root, `/v1`, or `/v1/chat/completions`. DNS hostnames and
HTTP redirects are rejected. Response bytes are bounded while they arrive (64
KiB for chat and 4 KiB for health), so an unhealthy local process cannot make
Cerebro buffer an unbounded body. The concrete provider sends a
non-streaming `POST /v1/chat/completions` request with a shallow JSON schema in
`response_format` and checks readiness through `GET /health`.

The same settings can be supplied before app launch:

```text
ROB_LOCAL_IMPROV_ENABLED=true
ROB_LOCAL_IMPROV_PROVIDER=llama_cpp
ROB_LLAMA_CPP_ENDPOINT=http://127.0.0.1:8080
ROB_LOCAL_IMPROV_MODEL=cerebro-local
ROB_LOCAL_IMPROV_TIMEOUT_SECONDS=3
ROB_LOCAL_IMPROV_TEMPERATURE=0.6
```

Environment values take precedence when the effective configuration is loaded.

## Runtime modes and fallbacks

| Mode | Local model | Gemini Live | Spoken fallback order |
| --- | --- | --- | --- |
| Dry Run | No | No | None; no side effects |
| Run Offline | No | No | Authored show line |
| Run Local | Yes | No | Validated local line when available; otherwise authored line |
| Run Adaptive | Optional | Yes | Gemini line; if unavailable, local line when available, otherwise authored line |

If the local provider is disabled or fails during **Run Adaptive**, Cerebro sends
the original authored scene goal to Gemini for the remaining cue time. If
Gemini is disconnected, fails, or times out after a valid local plan, Cerebro
speaks that plan's offline line. The required `fallback_text` in the show file
is always the terminal fallback.

Cerebro attaches the originating text-turn context to Gemini tool events and
rejects every non-stop `robot_action` whose context begins `stage:`. That gate
still applies if the cue or show has already timed out or completed.
`stop_motion` remains available through the priority stop lane.

## Schema contract

The local server is constrained to this logical shape:

```json
{
  "schema": "com.orbitusrobotics.local-improvisation-plan",
  "version": 1,
  "beat": "robot_joke",
  "delivery": "deadpan",
  "offline_line": "My comedy module is local, but the applause still uses the cloud."
}
```

The llama.cpp server documents schema-constrained JSON for the OpenAI-compatible
chat endpoint. Grammar enforcement is a generation aid, not a trust boundary,
so Cerebro independently checks document size, exact fields, enum values, and
the offline line's length, single-line shape, and prohibited control terms.

## Native MLX Swift path

`ROBLocalImprovisationProviding` is independent of HTTP. A future target can
register an MLX implementation through
`ROBLocalImprovisationProviderRegistry.registerMLXFactory` and reuse the same
request, plan validation, deadlines, diagnostics, stage routing, and fallbacks.
Selecting **MLX Swift (adapter)** today reports that the adapter is not linked
instead of crashing.

Apple's MLX project now places reusable LLM/VLM implementations in
`mlx-swift-lm`. The future provider should use its guided-generation product for
the same JSON schema, prewarm grammar compilation off the main thread, pin an
explicit package/model version, and preferably keep model loading in a helper
process so a Metal/model failure cannot terminate Cerebro.

References:

- <https://github.com/ml-explore/mlx-swift>
- <https://github.com/ml-explore/mlx-swift-lm>
- <https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXGuidedGeneration>

## Validation

Protocol and llama.cpp envelope fixtures:

```bash
swiftc -module-cache-path /tmp/cerebro-swift-module-cache \
  -parse-as-library \
  Cerebro/ROBLocalImprovisationProtocol.swift \
  Cerebro/ROBLlamaCppImprovisationProvider.swift \
  Tests/ROBLocalImprovisationFixtureTests.swift \
  -o /tmp/ROBLocalImprovisationFixtureTests

/tmp/ROBLocalImprovisationFixtureTests
```

These fixtures validate the schema, HTTP contract, limits, and failure handling
with deterministic responses; they are not a model-quality or live-server test.
Use **Test Local** with your selected GGUF model for the real loopback round
trip before a show.

Stage routing, fallback, cancellation, and late-response fixtures:

```bash
swiftc -module-cache-path /tmp/cerebro-swift-module-cache \
  -parse-as-library \
  Cerebro/ROBLocalImprovisationProtocol.swift \
  Cerebro/ROBLlamaCppImprovisationProvider.swift \
  Cerebro/ROBStageShowProtocol.swift \
  Cerebro/ROBStageShowCoordinator.swift \
  Tests/ROBStageShowFixtureTests.swift \
  -o /tmp/ROBStageShowFixtureTests

/tmp/ROBStageShowFixtureTests
```
