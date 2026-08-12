# Private MLX intelligence in Cerebro

Cerebro can now use MLX as an in-process, private/offline alternative to its existing loopback llama.cpp provider. Gemini remains available as the optional remote, higher-capability provider. MLX does not replace deterministic motor control, operator approval, transport validation, or the robot-action state machine.

## Pinned build dependencies

The Xcode project pins tested package releases instead of tracking `main`:

- `mlx-swift` 0.31.3
- `mlx-swift-lm` 3.31.3
- `swift-tokenizers-mlx` 0.3.0 with `swift-tokenizers` 0.5.0
- `swift-hf-api-mlx` 0.2.0 with `swift-hf-api` 0.3.2

MLX compiles Metal shaders. Install Xcode's Metal toolchain if necessary with `xcodebuild -downloadComponent MetalToolchain`, then build through Xcode or `xcodebuild`.

## Models and first-run behavior

The initial LLM is `mlx-community/Llama-3.2-1B-Instruct-4bit`. It fits the requested 1–4B range and is intentionally conservative for the first robot-Mac benchmark. Camera understanding uses `mlx-community/Qwen2-VL-2B-Instruct-4bit`; semantic retrieval uses `TaylorAI/gte-tiny`. Models download into the Hugging Face cache on first use and are then usable locally. Do the first download before an offline performance.

In **Stage Show**, select **MLX Swift (private/offline)**, keep the model identifier above, enable the local director, save, and press **Test Local**. The telemetry row reports model state, measured generation latency, generated tokens per second, MLX active/peak Metal memory, sampled VLM frames, and semantic-memory count. Record warm and cold measurements on the production robot Mac; the values shown are measurements from that machine, not estimates embedded in the code.

## Safety and scheduling

Improvisation output must be one complete JSON document matching the versioned dialogue schema. Model-proposed physical actions must independently match `ROBRobotActionProposalCodec`, which rejects prose, Markdown, missing or extra fields, unknown actions, and out-of-range arguments. A valid proposal becomes only a pending `ROBRobotActionMessage`; it does not bypass authorization or execute itself.

The camera callback only offers a frame. The MLX actor admits at most one selected frame every five seconds (and never faster than three seconds), performs VLM work asynchronously, and produces observational text only. It does not call the motor-control path. The observation may be embedded into the bounded, in-memory semantic store.

Use **Remember** to embed a short local fact and **Retrieve** to rank stored facts by cosine similarity. The current store is intentionally bounded to 200 entries and process-local. Persisting it should be a separate change with encryption, retention, and operator-deletion policy.

## Provider roles

- MLX: private/offline, predictable local availability, small models, measured on-device resource use.
- llama.cpp: existing loopback-compatible local provider and useful process-level isolation option.
- Gemini: optional remote provider for tasks that benefit from a larger model and live multimodal capability.

No provider is placed in the real-time motor loop. Learned motor control is explicitly outside this integration.
