import Foundation

protocol ROBRealtimeSocket: AnyObject {
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receive() async throws -> Data
    func close()
}

final class ROBOpenAIWebSocket: ROBRealtimeSocket {
    private let task: URLSessionWebSocketTask
    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        task.send(.string(String(decoding: data, as: UTF8.self)), completionHandler: completion)
    }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let value): return Data(value.utf8)
        @unknown default: throw ROBOpenAIRealtimeProtocol.Failure.invalidEvent
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// GA Realtime WebSocket adapter. Text output uses ROB's existing speech queue;
/// microphone input is resampled to 24 kHz and camera input is bounded JPEGs.
actor ROBOpenAIRealtimeSession: ROBRealtimeSession {
    typealias SocketFactory = (URLRequest) -> any ROBRealtimeSocket
    private struct Turn {
        let token: String
        let context: String?
        var fallback: String?
        var source: GeminiConversationTranscriptSource
        var text: String?
        var image: Data?
    }
    private let configuration: ROBOpenAIRealtimeConfiguration
    private let videoGate: GeminiVideoAuthorizationGate
    private let diagnostics: GeminiRoboticsDiagnosticsStore
    private let event: (ROBRealtimeEvent) -> Void
    private let socketFactory: SocketFactory
    private var policy: GeminiRoboticsRuntimePolicy
    private var socket: (any ROBRealtimeSocket)?
    private var reader: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var retryCount = 0
    private var ready = false
    private var retired = false
    private var microphoneAuthorized = false
    private var resampler = ROBRealtimePCMResampler()
    private var audioQueue: [(Data, UInt64)] = []
    private var audioDrain: Task<Void, Never>?
    private var hasAudio = false
    private var admittedAudio = false
    private var microphoneSpeechActive = false
    private var latestTranscript: String?
    private var lastMicrophoneCompletion: TimeInterval = 0
    private var pending: [Turn] = []
    private var turn: Turn?
    private var responseID: String?
    private var responseDone = false
    private var responseRequested = false
    private var cancellationInProgress = false
    private var cancellationEventIDs = Set<String>()
    private var toolRounds = 0
    private var toolQueue: [GeminiRoboticsToolCall] = []
    private var pendingTools: [String: String] = [:]
    private var deliveringTools = Set<String>()
    private var activeTool: String?
    private var completedToolIDs = Set<String>()
    private var cancelledContexts = Set<String>()
    private var cancelledOrder: [String] = []
    private var lastImageTime: TimeInterval = 0
    private var imageIDs: [String] = []

    init(configuration: ROBOpenAIRealtimeConfiguration, policy: GeminiRoboticsRuntimePolicy,
         videoGate: GeminiVideoAuthorizationGate, diagnostics: GeminiRoboticsDiagnosticsStore,
         socketFactory: @escaping SocketFactory = { ROBOpenAIWebSocket(request: $0) },
         event: @escaping (ROBRealtimeEvent) -> Void) {
        self.configuration = configuration; self.policy = policy; self.videoGate = videoGate
        self.diagnostics = diagnostics; self.socketFactory = socketFactory; self.event = event
    }

    func applyRuntimePolicy(_ next: GeminiRoboticsRuntimePolicy) async {
        guard !retired, next.revision >= policy.revision else { return }
        let connectionChanged = next.connectionGeneration != policy.connectionGeneration
        let audioChanged = next.audioGeneration != policy.audioGeneration
        let videoChanged = next.videoGeneration != policy.videoGeneration
        policy = next
        if audioChanged {
            audioQueue = []; resampler.reset(); hasAudio = false; admittedAudio = false
            microphoneSpeechActive = false
            if ready { try? await send(["type": "input_audio_buffer.clear"]) }
        }
        if videoChanged { lastImageTime = 0 }
        guard next.revision == policy.revision else { return }
        if connectionChanged || !next.settings.connectionEnabled {
            retire(detail: "Realtime was turned off before this request completed.")
        }
        event(.runtimePolicyApplied(next))
        guard next.settings.connectionEnabled else { event(.connectionState(.off, nil)); return }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !retired, policy.settings.connectionEnabled, reader == nil else { return }
        epoch &+= 1
        let generation = epoch
        ready = false
        let connection = socketFactory(ROBOpenAIRealtimeProtocol.request(configuration: configuration))
        socket = connection
        event(.connectionState(retryCount == 0 ? .connecting : .reconnecting, "OpenAI Realtime"))
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let data = try await connection.receive()
                    guard let self else { return }
                    try await self.receive(ROBOpenAIRealtimeProtocol.decode(data), epoch: generation)
                }
            } catch {
                await self?.connectionFailed(epoch: generation, detail: "OpenAI Realtime connection failed. Check the key, model access and network.")
            }
        }
        armTimeout(seconds: 12, token: nil, epoch: generation)
    }

    func stop(connectionState: ROBRealtimeConnectionState, failureDetail: String?, invalidatePendingPolicies: Bool) {
        if invalidatePendingPolicies { retired = true }
        retire(detail: failureDetail ?? "Realtime was turned off.")
        event(.connectionState(connectionState, nil))
    }

    private func retire(detail: String) {
        epoch &+= 1; ready = false
        timeout?.cancel(); timeout = nil; reconnect?.cancel(); reconnect = nil
        reader?.cancel(); reader = nil; socket?.close(); socket = nil
        audioDrain?.cancel(); audioDrain = nil
        audioQueue = []; resampler.reset(); hasAudio = false; admittedAudio = false; latestTranscript = nil
        microphoneSpeechActive = false; cancellationInProgress = false; cancellationEventIDs = []
        imageIDs = []; lastImageTime = 0
        if !pendingTools.isEmpty { event(.cancelledToolCalls(Array(pendingTools.keys))) }
        let failures = (turn.map { [$0] } ?? []) + pending
        turn = nil; pending = []; responseID = nil; responseDone = false; responseRequested = false
        pendingTools = [:]; deliveringTools = []; toolQueue = []; activeTool = nil; completedToolIDs = []
        for request in failures { fail(request, detail: detail) }
    }

    private func connectionFailed(epoch generation: UInt64, detail: String) {
        guard generation == epoch else { return }
        retire(detail: detail)
        event(.connectionState(.failed, detail))
        retryCount += 1
        guard policy.settings.connectionEnabled, retryCount <= 3 else { return }
        let expected = epoch, delay = UInt64(1 << retryCount) * 1_000_000_000
        reconnect = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.retry(epoch: expected)
        }
    }
    private func retry(epoch expected: UInt64) {
        guard epoch == expected else { return }
        reconnect = nil; startIfNeeded()
    }

    func setMicrophoneConversationAuthorized(_ authorized: Bool, generation: UInt64) {
        guard generation == policy.audioGeneration else { return }
        microphoneAuthorized = authorized
        if !authorized {
            audioQueue = []
            // Close an admitted utterance even if the wake window closes
            // before the encoder's stream-end callback reaches this actor.
            if hasAudio { enqueueAudioStreamEnd(generation: generation) }
        }
    }
    func enqueueAudioPCM16(_ data: Data, generation: UInt64) {
        guard ready, policy.settings.streamsAudio, microphoneAuthorized,
              generation == policy.audioGeneration, !data.isEmpty, data.count <= 192_000 else { return }
        if audioQueue.count >= 10 { audioQueue.removeFirst() }
        audioQueue.append((data, generation))
        hasAudio = true
        startAudioDrain()
    }
    func enqueueAudioStreamEnd(generation: UInt64) {
        guard ready, hasAudio, policy.settings.streamsAudio, generation == policy.audioGeneration else { return }
        // Let server VAD commit once, rather than racing its commit with a
        // second client commit of an already-empty buffer.
        audioQueue.append((Data(repeating: 0, count: 19_200), generation))
        hasAudio = false
        startAudioDrain()
    }
    private func startAudioDrain() {
        guard audioDrain == nil else { return }
        let generation = epoch
        audioDrain = Task { [weak self] in await self?.drainAudio(epoch: generation) }
    }
    private func drainAudio(epoch generation: UInt64) async {
        defer { if epoch == generation { audioDrain = nil } }
        while generation == epoch, ready, !audioQueue.isEmpty {
            let (data, audioGeneration) = audioQueue.removeFirst()
            guard audioGeneration == policy.audioGeneration, policy.settings.streamsAudio else { continue }
            let encoded = resampler.convert16To24(data)
            guard !encoded.isEmpty else { continue }
            admittedAudio = true
            do { try await send(["type": "input_audio_buffer.append", "audio": encoded.base64EncodedString()]) }
            catch { connectionFailed(epoch: generation, detail: "OpenAI microphone send failed."); return }
        }
    }
    func noteMicrophoneTurnAwaitingResponse(transcript: String, generation: UInt64,
                                            transcriptIsCumulative: Bool, source: GeminiConversationTranscriptSource) {
        guard ready, generation == policy.audioGeneration, microphoneAuthorized,
              ProcessInfo.processInfo.systemUptime - lastMicrophoneCompletion > 1 else { return }
        if turn?.text == nil, turn != nil {
            let previous = transcriptIsCumulative ? "" : ((turn?.fallback ?? "") + " ")
            turn?.fallback = String((previous + transcript).prefix(4000))
            turn?.source = source
        } else {
            let previous = transcriptIsCumulative ? "" : ((latestTranscript ?? "") + " ")
            latestTranscript = String((previous + transcript).prefix(4000))
        }
        // Local recognition also supplies a deadline if provider VAD never
        // commits, so a quiet network failure cannot leave ROB silent.
        if turn == nil { armTimeout(seconds: 10, token: nil, epoch: epoch) }
    }

    func sendVideoJPEG(_ data: Data, generation: UInt64) async -> Bool {
        guard ready, policy.settings.streamsVideo, generation == policy.videoGeneration,
              videoGate.allows(generation: generation), !data.isEmpty, data.count <= 4 * 1024 * 1024 else { return false }
        guard ProcessInfo.processInfo.systemUptime - lastImageTime >= 1 else { return true }
        let connection = epoch
        do { try await sendImage(data, generation: generation); return true }
        catch { connectionFailed(epoch: connection, detail: "OpenAI image send failed."); return false }
    }
    private func sendImage(_ data: Data, generation: UInt64) async throws {
        let id = "robimg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let expected = epoch
        try await send(ROBOpenAIRealtimeProtocol.userItem(text: nil, image: data, id: id), videoGeneration: generation)
        guard epoch == expected else { return }
        imageIDs.append(id); lastImageTime = ProcessInfo.processInfo.systemUptime
        diagnostics.noteVideoFrameSent()
        while imageIDs.count > 2 {
            let old = imageIDs.removeFirst()
            try await send(["type": "conversation.item.delete", "item_id": old])
        }
    }

    func sendTextTurn(_ text: String, imageJPEG: Data?, contextID: String?, localFallbackPrompt: String?,
                      fallbackSource: GeminiConversationTranscriptSource, generation: UInt64,
                      minimumPolicyRevision: UInt64) async {
        if let contextID, cancelledContexts.contains(contextID) { return }
        let request = Turn(token: UUID().uuidString, context: contextID, fallback: localFallbackPrompt,
                           source: fallbackSource, text: String(text.prefix(32_000)), image: imageJPEG)
        guard generation == policy.connectionGeneration, minimumPolicyRevision <= policy.revision,
              policy.settings.connectionEnabled, ready, !text.isEmpty, pending.count < 5,
              imageJPEG == nil || (policy.settings.streamsVideo && imageJPEG!.count <= 4 * 1024 * 1024) else {
            fail(request, detail: "OpenAI Realtime is unavailable or its queue is full."); return
        }
        pending.append(request)
        await beginNext()
    }
    private func beginNext() async {
        guard ready, turn == nil, !cancellationInProgress, !microphoneSpeechActive, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        turn = request; responseID = nil; responseDone = false; toolRounds = 0
        let generation = epoch
        do {
            if let image = request.image { try await sendImage(image, generation: policy.videoGeneration) }
            guard epoch == generation, turn?.token == request.token else { return }
            if let text = request.text { try await send(ROBOpenAIRealtimeProtocol.userItem(text: text)) }
            guard epoch == generation, turn?.token == request.token else { return }
            try await createResponse()
        } catch { connectionFailed(epoch: generation, detail: "OpenAI could not submit the turn.") }
    }
    private func createResponse() async throws {
        guard let turn else { return }
        responseID = nil; responseDone = false; responseRequested = true
        armTimeout(seconds: 45, token: turn.token, epoch: epoch)
        try await send(ROBOpenAIRealtimeProtocol.response(token: turn.token, dialogueOnly: turn.context?.hasPrefix("duet:") == true))
    }

    func cancelTextTurn(contextID: String) async {
        if cancelledContexts.insert(contextID).inserted {
            cancelledOrder.append(contextID)
            if cancelledOrder.count > 1024 { cancelledContexts.remove(cancelledOrder.removeFirst()) }
        }
        pending.removeAll { $0.context == contextID }
        if turn?.context == contextID {
            await interruptTurn(detail: "The OpenAI turn was cancelled.")
            await beginNext()
        }
    }

    /// Realtime supports scoped response cancellation. Drop ownership before
    /// awaiting network I/O; terminal events from the old response cannot
    /// acquire the new turn's token or dispatch a tool. Keep the socket and
    /// newly admitted microphone audio alive for barge-in.
    private func interruptTurn(detail: String) async {
        guard let interrupted = turn else { return }
        let generation = epoch
        let shouldCancel = responseRequested && !responseDone
        let interruptedResponseID = responseID
        let unresolved = pendingTools
        cancellationInProgress = true
        turn = nil; responseID = nil; responseDone = false; responseRequested = false
        timeout?.cancel(); timeout = nil
        pendingTools = [:]; deliveringTools = []; toolQueue = []; activeTool = nil
        if !unresolved.isEmpty { event(.cancelledToolCalls(Array(unresolved.keys))) }
        if let context = interrupted.context, !cancelledContexts.contains(context) {
            event(.requestFailed(detail, contextID: context, localFallbackPrompt: nil))
        }
        do {
            if shouldCancel {
                let id = "rob_cancel_" + UUID().uuidString
                if cancellationEventIDs.count >= 32 { cancellationEventIDs.removeAll() }
                cancellationEventIDs.insert(id)
                var cancel: [String: Any] = ["type": "response.cancel", "event_id": id]
                if let interruptedResponseID { cancel["response_id"] = interruptedResponseID }
                try await send(cancel)
            }
            for (id, _) in unresolved {
                guard epoch == generation else { return }
                completedToolIDs.insert(id)
                try await send(ROBOpenAIRealtimeProtocol.toolOutput(callID: id, result: [
                    "status": "cancelled", "detail": "The user interrupted this turn. Do not replay its actions."
                ]))
            }
            guard epoch == generation else { return }
            cancellationInProgress = false
        } catch { connectionFailed(epoch: generation, detail: "OpenAI could not cancel the previous response.") }
    }

    func sendToolResponse(callID: String, name: String, result: [String: Any]) async {
        guard ready, pendingTools[callID] == name, !completedToolIDs.contains(callID) else { return }
        let generation = epoch, token = turn?.token
        // Remove before suspension, so retransmission cannot submit twice.
        pendingTools.removeValue(forKey: callID)
        completedToolIDs.insert(callID)
        deliveringTools.insert(callID)
        do {
            try await send(ROBOpenAIRealtimeProtocol.toolOutput(callID: callID, result: result))
            guard generation == epoch else { return }
            deliveringTools.remove(callID)
            guard turn?.token == token else { return }
            if activeTool == callID { activeTool = nil }
            dispatchTool()
            if pendingTools.isEmpty && deliveringTools.isEmpty && toolQueue.isEmpty && responseDone { try await createResponse() }
        } catch { connectionFailed(epoch: generation, detail: "OpenAI tool-result delivery failed; the action will not be replayed.") }
    }
    func confirmToolCallCancellation(callID: String) {
        // Socket retirement already clears this adapter's blocking slot.
    }
    private func dispatchTool() {
        guard activeTool == nil, !toolQueue.isEmpty else { return }
        let call = toolQueue.removeFirst()
        activeTool = call.id
        event(.toolCalls([GeminiRoboticsAttributedToolCall(call: call, contextID: turn?.context, provider: .openAI)]))
    }

    private func receive(_ message: [String: Any], epoch generation: UInt64) async throws {
        guard generation == epoch else { return }
        switch message["type"] as? String {
        case "session.created":
            try await send(ROBOpenAIRealtimeProtocol.sessionUpdate(configuration: configuration))
        case "session.updated":
            guard !ready else { return }
            ready = true; retryCount = 0; timeout?.cancel(); timeout = nil
            event(.connectionState(.ready, "OpenAI Realtime • microphone + sampled images • local ROB speech"))
            await beginNext()
        case "input_audio_buffer.speech_started":
            guard ready, policy.settings.streamsAudio, admittedAudio else { return }
            microphoneSpeechActive = true
            latestTranscript = nil
            await interruptTurn(detail: "New microphone input interrupted the previous response.")
            event(.interrupted)
        case "input_audio_buffer.committed":
            guard ready, policy.settings.streamsAudio, admittedAudio else { return }
            admittedAudio = false; hasAudio = false; microphoneSpeechActive = false
            guard pending.count < 5 else {
                connectionFailed(epoch: generation, detail: "OpenAI microphone turn queue is full."); return
            }
            pending.insert(Turn(token: UUID().uuidString, context: nil, fallback: latestTranscript,
                                source: .appleSpeech, text: nil, image: nil), at: 0)
            latestTranscript = nil
            await beginNext()
        case "response.created":
            guard let response = message["response"] as? [String: Any],
                  let token = (response["metadata"] as? [String: Any])?["cerebro_turn"] as? String,
                  token == turn?.token, responseID == nil else { return }
            responseID = response["id"] as? String
        case "response.done":
            guard let response = message["response"] as? [String: Any],
                  let id = response["id"] as? String, id == responseID, !responseDone, let request = turn else { return }
            responseDone = true
            responseRequested = false
            guard response["status"] as? String == "completed" else {
                connectionFailed(epoch: generation, detail: "OpenAI did not complete the requested response."); return
            }
            let (text, calls) = try ROBOpenAIRealtimeProtocol.output(response)
            if !calls.isEmpty {
                toolRounds += 1
                guard toolRounds <= 8, completedToolIDs.count < 1024 else {
                    connectionFailed(epoch: generation, detail: "OpenAI reached the bounded tool limit."); return
                }
                armTimeout(seconds: 180, token: request.token, epoch: generation)
                for call in calls {
                    guard pendingTools[call.id] == nil, !completedToolIDs.contains(call.id) else { continue }
                    pendingTools[call.id] = call.name
                    if GeminiRoboticsToolPolicy.requiresPriorityDispatch(call) {
                        event(.toolCalls([GeminiRoboticsAttributedToolCall(call: call, contextID: request.context, provider: .openAI)]))
                    } else { toolQueue.append(call) }
                }
                dispatchTool()
            } else {
                turn = nil; responseID = nil; timeout?.cancel(); timeout = nil
                if request.text == nil { lastMicrophoneCompletion = ProcessInfo.processInfo.systemUptime }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fail(request, detail: "OpenAI completed without a spoken response.")
                } else { event(.completedText(text, contextID: request.context)) }
                await beginNext()
            }
        case "error":
            if let error = message["error"] as? [String: Any],
               error["code"] as? String == "response_cancel_not_active",
               let id = error["event_id"] as? String, cancellationEventIDs.remove(id) != nil {
                return // The response completed at the same instant as cancellation.
            }
            connectionFailed(epoch: generation, detail: "OpenAI rejected a Realtime event. Check model access and the selected settings.")
        default: break // Deltas are not spoken; only a correlated terminal output is delivered.
        }
    }

    private func send(_ message: [String: Any], videoGeneration: UInt64? = nil) async throws {
        guard let socket else { throw ROBOpenAIRealtimeProtocol.Failure.disconnected }
        let data = try JSONSerialization.data(withJSONObject: message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let submit = { socket.send(data) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            } }
            if let videoGeneration {
                if !videoGate.performIfAllowed(generation: videoGeneration, submit) {
                    continuation.resume(throwing: ROBOpenAIRealtimeProtocol.Failure.disconnected)
                }
            } else { submit() }
        }
    }
    private func fail(_ request: Turn, detail: String) {
        guard request.context.map({ !cancelledContexts.contains($0) }) ?? true else { return }
        event(.requestFailed(detail, contextID: request.context,
                             localFallbackPrompt: request.fallback.map { GeminiLocalFallbackPrompt(text: $0, source: request.source, providerTurnID: nil) }))
    }
    private func armTimeout(seconds: UInt64, token: String?, epoch generation: UInt64) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            await self?.timedOut(token: token, epoch: generation)
        }
    }
    private func timedOut(token: String?, epoch generation: UInt64) {
        guard epoch == generation, token == nil || turn?.token == token else { return }
        if turn == nil, let latestTranscript {
            event(.requestFailed("OpenAI microphone turn timed out.", contextID: nil,
                                 localFallbackPrompt: GeminiLocalFallbackPrompt(text: latestTranscript, source: .appleSpeech, providerTurnID: nil)))
        }
        connectionFailed(epoch: generation, detail: "OpenAI Realtime exceeded its response deadline.")
    }
}
