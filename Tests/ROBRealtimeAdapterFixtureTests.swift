import Foundation

private enum TestFailure: Error { case failed(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
    if !condition() { throw TestFailure.failed(detail) }
}
private func eventually(_ detail: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw TestFailure.failed(detail)
}
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ROBRealtimeEvent] = []
    func add(_ event: ROBRealtimeEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var values: [ROBRealtimeEvent] { lock.lock(); defer { lock.unlock() }; return storage }
    var texts: [String] { values.compactMap { if case .completedText(let text, _) = $0 { return text }; return nil } }
    var calls: [GeminiRoboticsAttributedToolCall] { values.flatMap { if case .toolCalls(let calls) = $0 { return calls }; return [] } }
    var speeches: [(String, ROBRealtimeProvider, String)] {
        values.compactMap { if case .personalityText(let text, let provider, let id) = $0 { return (text, provider, id) }; return nil }
    }
}
private final class FakeSocket: ROBRealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var outgoing: [[String: Any]] = []
    private var holdsToolOutputs = false
    private var toolOutputCompletions: [String: (Error?) -> Void] = [:]
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    init() {
        var sink: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { sink = $0 }
        self.stream = stream; continuation = sink; iterator = stream.makeAsyncIterator()
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        do {
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            lock.lock()
            outgoing.append(json)
            if holdsToolOutputs, let item = json["item"] as? [String: Any],
               item["type"] as? String == "function_call_output", let id = item["call_id"] as? String {
                toolOutputCompletions[id] = completion
                lock.unlock()
            } else { lock.unlock(); completion(nil) }
        } catch { completion(error) }
    }
    func receive() async throws -> Data {
        guard let data = try await iterator.next() else { throw ROBOpenAIRealtimeProtocol.Failure.disconnected }
        return data
    }
    func close() { continuation.finish() }
    func push(_ message: [String: Any]) throws { continuation.yield(try JSONSerialization.data(withJSONObject: message)) }
    var sent: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return outgoing }
    func holdToolOutputs() { lock.lock(); holdsToolOutputs = true; lock.unlock() }
    func completeToolOutput(_ id: String) {
        lock.lock(); let completion = toolOutputCompletions.removeValue(forKey: id); lock.unlock()
        completion?(nil)
    }
}
private actor FakeSession: ROBRealtimeSession {
    struct Request { let text: String; let context: String? }
    let event: (ROBRealtimeEvent) -> Void
    var requests: [Request] = []
    var results: [(String, String, [String: Any])] = []
    var cancellations: [String] = []
    var audioChunks = 0
    var images = 0
    init(event: @escaping (ROBRealtimeEvent) -> Void) { self.event = event }
    func emit(_ value: ROBRealtimeEvent) { event(value) }
    func applyRuntimePolicy(_ policy: GeminiRoboticsRuntimePolicy) {
        event(.runtimePolicyApplied(policy)); event(.connectionState(.ready, nil))
    }
    func stop(connectionState: ROBRealtimeConnectionState, failureDetail: String?, invalidatePendingPolicies: Bool) {}
    func setMicrophoneConversationAuthorized(_ authorized: Bool, generation: UInt64) {}
    func enqueueAudioPCM16(_ data: Data, generation: UInt64) { audioChunks += 1 }
    func enqueueAudioStreamEnd(generation: UInt64) {}
    func sendVideoJPEG(_ data: Data, generation: UInt64) -> Bool { images += 1; return true }
    func sendTextTurn(_ text: String, imageJPEG: Data?, contextID: String?, localFallbackPrompt: String?,
                      fallbackSource: GeminiConversationTranscriptSource, generation: UInt64, minimumPolicyRevision: UInt64) {
        requests.append(Request(text: text, context: contextID))
    }
    func cancelTextTurn(contextID: String) { cancellations.append(contextID) }
    func noteMicrophoneTurnAwaitingResponse(transcript: String, generation: UInt64,
                                            transcriptIsCumulative: Bool, source: GeminiConversationTranscriptSource) {}
    func sendToolResponse(callID: String, name: String, result: [String: Any]) { results.append((callID, name, result)) }
    func confirmToolCallCancellation(callID: String) {}
}
private final class SessionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ROBRealtimeProvider: FakeSession] = [:]
    func make(_ provider: ROBRealtimeProvider, _ event: @escaping (ROBRealtimeEvent) -> Void) -> FakeSession {
        let session = FakeSession(event: event)
        lock.lock(); sessions[provider] = session; lock.unlock()
        return session
    }
    func get(_ provider: ROBRealtimeProvider) -> FakeSession {
        lock.lock(); defer { lock.unlock() }; return sessions[provider]!
    }
}

@main struct ROBRealtimeAdapterFixtureTests {
    static func configuration() -> ROBOpenAIRealtimeConfiguration {
        ROBOpenAIRealtimeConfiguration.load(preferences: ROBRealtimePreferences(),
            environment: ["OPENAI_API_KEY": "fixture-only-not-a-key"])!
    }
    static func policy() -> GeminiRoboticsRuntimePolicy {
        .init(settings: GeminiRoboticsRuntimeSettings(configuration: configuration().runtime), revision: 1,
              connectionGeneration: 1, audioGeneration: 1, videoGeneration: 1)
    }
    static func main() async throws {
        try testProtocolAndSettings()
        try testResampling()
        try await testSocketLifecycle()
        try await testMicrophoneInterruption()
        try await testConcurrentToolDelivery()
        try await testRouterAndDialogue()
        try await testOpenAIDriverModes()
        print("Realtime fixtures passed: GA envelopes, PCM resampling, turn/tool correlation, cancellation, media gates, provider routing and bounded dual dialogue")
    }
    static func testProtocolAndSettings() throws {
        let config = configuration()
        let request = ROBOpenAIRealtimeProtocol.request(configuration: config)
        try expect(request.url?.host == "api.openai.com" && request.url?.scheme == "wss", "Credential destination changed")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-not-a-key", "Missing auth header")
        try expect(!request.url!.absoluteString.contains(config.apiKey), "Credential leaked into URL")
        let session = ROBOpenAIRealtimeProtocol.sessionUpdate(configuration: config)["session"] as! [String: Any]
        try expect(session["output_modalities"] as? [String] == ["text"], "Speech playback ownership changed")
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        try expect((input["format"] as! [String: Any])["rate"] as? Int == 24000, "Incorrect Realtime audio rate")
        try expect((input["turn_detection"] as! [String: Any])["create_response"] as? Bool == false, "Unowned automatic responses enabled")
        let tools = session["tools"] as! [[String: Any]]
        let loiter = tools.first { $0["name"] as? String == "loiter_control" }!
        try expect((loiter["parameters"] as! [String: Any])["type"] as? String == "object", "Google schema was not converted")
        try expect(loiter["behavior"] == nil, "Google-only function field leaked")
        let noTools = ROBOpenAIRealtimeConfiguration.load(preferences: ROBRealtimePreferences(),
            environment: ["OPENAI_API_KEY": "fixture", "OPENAI_ROBOT_ACTION_TOOL_ENABLED": "false",
                          "OPENAI_NEWS_SEARCH_ENABLED": "false", "OPENAI_APPLE_MUSIC_ENABLED": "false"])!
        let disabled = ROBOpenAIRealtimeProtocol.sessionUpdate(configuration: noTools)["session"] as! [String: Any]
        try expect((disabled["tools"] as! [Any]).isEmpty, "Disabled tools were exposed")
        let response = ROBOpenAIRealtimeProtocol.response(token: "duet", dialogueOnly: true)["response"] as! [String: Any]
        try expect(response["tool_choice"] as? String == "none", "Peer response allowed tools")
        let suite = "ROBRealtimeFixtures." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ROBRealtimePreferences()
        preferences.mode = .dual; preferences.dualDriver = .openAI; preferences.maximumDialogueLines = 4
        preferences.save(to: defaults)
        try expect(ROBRealtimePreferences(defaults: defaults) == preferences, "Provider preference round trip changed")
        try expect(!ROBRealtimePreferences.validModel("gpt-6-astra"), "Non-Realtime model accepted")
        try expect(!ROBRealtimePreferences.validModel("gpt-realtime&key=secret"), "Malformed model ID accepted")
        let bad = ["output": [["type": "function_call", "name": "robot_action", "call_id": "bad", "arguments": "[]"]]]
        do { _ = try ROBOpenAIRealtimeProtocol.output(bad); throw TestFailure.failed("Nonobject tool arguments accepted") }
        catch is ROBOpenAIRealtimeProtocol.Failure {}
    }
    static func testResampling() throws {
        let values: [Int16] = (0..<1600).map { Int16(12_000 * sin(Double($0) * 0.13)) }
        let input = values.withUnsafeBytes { Data($0) }
        var once = ROBRealtimePCMResampler(), chunks = ROBRealtimePCMResampler()
        let whole = once.convert16To24(input)
        var split = Data()
        for offset in stride(from: 0, to: input.count, by: 128) {
            split.append(chunks.convert16To24(input.subdata(in: offset..<min(input.count, offset + 128))))
        }
        try expect(abs(whole.count - 4800) <= 4, "Wrong PCM duration after resampling")
        try expect(abs(split.count - whole.count) <= 2, "Chunk boundaries changed audio duration")
        func samples(_ data: Data) -> [Int16] {
            data.withUnsafeBytes { raw in stride(from: 0, to: raw.count, by: 2).map { raw.loadUnaligned(fromByteOffset: $0, as: Int16.self) } }
        }
        try expect(zip(samples(whole), samples(split)).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "Chunk boundaries discontinuously changed PCM")
        chunks.reset()
        try expect(chunks.convert16To24(Data([1])).isEmpty, "Odd PCM byte count accepted")
    }
    static func testSocketLifecycle() async throws {
        let socket = FakeSocket(), log = EventLog(), current = policy(), gate = GeminiVideoAuthorizationGate()
        gate.update(policy: current)
        let session = ROBOpenAIRealtimeSession(configuration: configuration(), policy: current, videoGate: gate,
            diagnostics: GeminiRoboticsDiagnosticsStore(configuration: configuration().runtime),
            socketFactory: { _ in socket }, event: log.add)
        await session.applyRuntimePolicy(current)
        try socket.push(["type": "session.created"])
        try await eventually("Session setup not sent") { socket.sent.contains { $0["type"] as? String == "session.update" } }
        try socket.push(["type": "session.updated"])
        try await eventually("Session never ready") { log.values.contains { if case .connectionState(.ready, _) = $0 { return true }; return false } }
        await session.sendTextTurn("ROB, report readiness", contextID: "fixture:turn", localFallbackPrompt: nil,
                                  fallbackSource: .typedText, generation: 1, minimumPolicyRevision: 1)
        func creation() -> [String: Any] { socket.sent.last { $0["type"] as? String == "response.create" }!["response"] as! [String: Any] }
        let metadata = creation()["metadata"] as! [String: Any]
        try socket.push(["type": "response.created", "response": ["id": "r1", "metadata": metadata]])
        try socket.push(["type": "response.done", "response": ["id": "wrong", "status": "completed", "output": []]])
        let call: [String: Any] = ["type": "function_call", "call_id": "c1", "name": "loiter_control", "arguments": "{\"command\":\"status\"}"]
        let done: [String: Any] = ["type": "response.done", "response": ["id": "r1", "status": "completed", "output": [call]]]
        try socket.push(done); try socket.push(done)
        try await eventually("Tool was not emitted") { log.calls.count == 1 }
        try expect(log.calls[0].contextID == "fixture:turn" && log.calls[0].provider == .openAI, "Tool lost its initiating context or provider")
        await session.sendToolResponse(callID: "c1", name: "wrong", result: ["status": "completed"])
        try expect(socket.sent.filter { $0["type"] as? String == "response.create" }.count == 1, "Mismatched tool reply released slot")
        await session.sendToolResponse(callID: "c1", name: "loiter_control", result: ["status": "active", "measured_completion": false])
        await session.sendToolResponse(callID: "c1", name: "loiter_control", result: ["status": "active"])
        try expect(socket.sent.filter { $0["type"] as? String == "response.create" }.count == 2, "Tool result resumed zero or multiple times")
        try socket.push(["type": "response.created", "response": ["id": "r2", "metadata": metadata]])
        try socket.push(["type": "response.done", "response": ["id": "r2", "status": "completed", "output": [
            ["type": "message", "content": [["type": "output_text", "text": "Ready for your instructions."]]]
        ]]])
        try await eventually("Final response not delivered") { log.texts.count == 1 }
        try expect(log.texts[0] == "Ready for your instructions.", "Unexpected final text")
        let accepted = await session.sendVideoJPEG(Data([255, 216, 255, 217]), generation: 1)
        try expect(accepted, "Authorized frame was not sent")
        gate.revoke()
        let rejected = await session.sendVideoJPEG(Data([255, 216]), generation: 1)
        try expect(!rejected, "Revoked video gate leaked a frame")
        await session.cancelTextTurn(contextID: "cancel-before-enqueue")
        let before = socket.sent.count
        await session.sendTextTurn("late", contextID: "cancel-before-enqueue", localFallbackPrompt: nil,
                                  fallbackSource: .typedText, generation: 1, minimumPolicyRevision: 1)
        try expect(socket.sent.count == before, "Cancelled context reentered the queue")
        await session.stop(connectionState: .off, failureDetail: nil)
        await session.applyRuntimePolicy(current)
        try expect(log.calls.count == 1 && log.texts.count == 1, "Lifecycle emitted duplicate terminal work")
    }
    private static func connectedSession() async throws -> (ROBOpenAIRealtimeSession, FakeSocket, EventLog) {
        let socket = FakeSocket(), log = EventLog(), current = policy(), gate = GeminiVideoAuthorizationGate()
        gate.update(policy: current)
        let session = ROBOpenAIRealtimeSession(configuration: configuration(), policy: current, videoGate: gate,
            diagnostics: GeminiRoboticsDiagnosticsStore(configuration: configuration().runtime),
            socketFactory: { _ in socket }, event: log.add)
        await session.applyRuntimePolicy(current)
        try socket.push(["type": "session.created"])
        try socket.push(["type": "session.updated"])
        try await eventually("Fixture connection failed") { log.values.contains { if case .connectionState(.ready, _) = $0 { return true }; return false } }
        return (session, socket, log)
    }
    static func testMicrophoneInterruption() async throws {
        let (session, socket, log) = try await connectedSession()
        func responseCount() -> Int { socket.sent.filter { $0["type"] as? String == "response.create" }.count }
        func metadata() -> [String: Any] {
            (socket.sent.last { $0["type"] as? String == "response.create" }!["response"] as! [String: Any])["metadata"] as! [String: Any]
        }
        await session.setMicrophoneConversationAuthorized(true, generation: 1)
        await session.enqueueAudioPCM16(Data(repeating: 1, count: 3200), generation: 1)
        try await eventually("Microphone not sent") { socket.sent.contains { $0["type"] as? String == "input_audio_buffer.append" } }
        try socket.push(["type": "input_audio_buffer.speech_started"])
        try socket.push(["type": "input_audio_buffer.committed"])
        try await eventually("First microphone response missing") { responseCount() == 1 }
        let firstMetadata = metadata()
        try socket.push(["type": "response.created", "response": ["id": "mic1", "metadata": firstMetadata]])
        await session.enqueueAudioPCM16(Data(repeating: 2, count: 3200), generation: 1)
        try await eventually("Second microphone input missing") {
            socket.sent.filter { $0["type"] as? String == "input_audio_buffer.append" }.count == 2
        }
        try socket.push(["type": "input_audio_buffer.speech_started"])
        try await eventually("Barge-in did not cancel response") { socket.sent.contains { $0["type"] as? String == "response.cancel" } }
        try socket.push(["type": "response.done", "response": ["id": "mic1", "status": "completed", "output": [
            ["type": "function_call", "call_id": "stale-motion", "name": "robot_action", "arguments": "{\"action\":\"play_gesture\"}"]
        ]]])
        try socket.push(["type": "input_audio_buffer.committed"])
        try await eventually("Barge-in lost the new microphone request") { responseCount() == 2 }
        let secondMetadata = metadata()
        try expect(firstMetadata["cerebro_turn"] as? String != secondMetadata["cerebro_turn"] as? String, "Barge-in reused old turn ownership")
        try socket.push(["type": "response.created", "response": ["id": "mic2", "metadata": secondMetadata]])
        try socket.push(["type": "response.done", "response": ["id": "mic2", "status": "completed", "output": [
            ["type": "message", "content": [["type": "text", "text": "I heard your correction."]]]
        ]]])
        try await eventually("Barge-in response missing") { log.texts == ["I heard your correction."] }
        try expect(log.calls.isEmpty, "Interrupted response dispatched stale motion")
        // Closing admission finishes already accepted input, without sending
        // new raw audio or generating endless synthetic end-of-stream chunks.
        await session.enqueueAudioPCM16(Data(repeating: 3, count: 3200), generation: 1)
        try await eventually("Final admitted input missing") {
            socket.sent.filter { $0["type"] as? String == "input_audio_buffer.append" }.count == 3
        }
        await session.setMicrophoneConversationAuthorized(false, generation: 1)
        try await eventually("Wake gate closure did not finish input") {
            socket.sent.filter { $0["type"] as? String == "input_audio_buffer.append" }.count == 4
        }
        await session.enqueueAudioStreamEnd(generation: 1)
        await session.enqueueAudioPCM16(Data(repeating: 4, count: 3200), generation: 1)
        try socket.push(["type": "input_audio_buffer.committed"])
        try await eventually("Wake gate discarded an admitted response") { responseCount() == 3 }
        try expect(socket.sent.filter { $0["type"] as? String == "input_audio_buffer.append" }.count == 4, "Closed gate leaked audio or repeated stream end")
        await session.stop(connectionState: .off, failureDetail: nil)
    }
    static func testConcurrentToolDelivery() async throws {
        let (session, socket, log) = try await connectedSession()
        await session.sendTextTurn("ROB, pause loiter and report status", contextID: "two-tools", localFallbackPrompt: nil,
                                  fallbackSource: .typedText, generation: 1, minimumPolicyRevision: 1)
        let metadata = (socket.sent.last { $0["type"] as? String == "response.create" }!["response"] as! [String: Any])["metadata"] as! [String: Any]
        try socket.push(["type": "response.created", "response": ["id": "tools", "metadata": metadata]])
        try socket.push(["type": "response.done", "response": ["id": "tools", "status": "completed", "output": [
            ["type": "function_call", "call_id": "pause", "name": "loiter_control", "arguments": "{\"command\":\"pause\"}"],
            ["type": "function_call", "call_id": "status", "name": "loiter_control", "arguments": "{\"command\":\"status\"}"]
        ]]])
        try await eventually("Priority and ordinary calls were not both dispatched") { log.calls.count == 2 }
        socket.holdToolOutputs()
        let pause = Task { await session.sendToolResponse(callID: "pause", name: "loiter_control", result: ["status": "paused"]) }
        let status = Task { await session.sendToolResponse(callID: "status", name: "loiter_control", result: ["status": "active"]) }
        try await eventually("Both tool outputs were not submitted") {
            socket.sent.filter { ($0["item"] as? [String: Any])?["type"] as? String == "function_call_output" }.count == 2
        }
        socket.completeToolOutput("pause")
        await pause.value
        try expect(socket.sent.filter { $0["type"] as? String == "response.create" }.count == 1, "Follow-up began before all tool outputs completed")
        socket.completeToolOutput("status")
        await status.value
        try expect(socket.sent.filter { $0["type"] as? String == "response.create" }.count == 2, "Follow-up did not resume exactly once")
        await session.cancelTextTurn(contextID: "two-tools")
        await session.stop(connectionState: .off, failureDetail: nil)
    }
    static func testRouterAndDialogue() async throws {
        let pool = SessionPool(), log = EventLog()
        var preferences = ROBRealtimePreferences(); preferences.mode = .dual; preferences.maximumDialogueLines = 3
        let router = ROBRealtimeRouter(preferences: preferences, policy: policy(), factory: pool.make, event: log.add)
        await router.applyRuntimePolicy(policy())
        let gemini = pool.get(.gemini), openAI = pool.get(.openAI)
        try await eventually("Router not ready") { log.values.contains { if case .connectionState(.ready, _) = $0 { return true }; return false } }
        await router.enqueueAudioPCM16(Data([0, 0]), generation: 1)
        _ = await router.sendVideoJPEG(Data([1]), generation: 1)
        let audioCounts = await (gemini.audioChunks, openAI.audioChunks)
        let imageCounts = await (gemini.images, openAI.images)
        try expect(audioCounts == (1, 0) && imageCounts == (1, 1), "Input destinations violated selected roles")
        let raw = GeminiRoboticsToolCall(id: String(repeating: "x", count: 256), name: "robot_action", arguments: ["action": "play_gesture", "gesture": "wave"])
        await gemini.emit(.toolCalls([.init(call: raw, contextID: nil)]))
        await openAI.emit(.toolCalls([.init(call: raw, contextID: nil)]))
        try await eventually("Driver action missing") {
            let count = await openAI.results.count
            return log.calls.count == 1 && count == 1
        }
        let routed = log.calls[0]
        try expect(routed.provider == .gemini && routed.call.id != raw.id && routed.call.id.count <= 128, "Provider call namespace exceeded the controller wire contract")
        await router.sendToolResponse(callID: routed.call.id, name: raw.name, result: ["status": "completed", "measured": true])
        let result = await gemini.results.first
        try expect(result?.0 == raw.id, "Tool result returned to wrong provider/ID")
        await router.startDialogue()
        let initial = await gemini.requests.last!
        try expect(initial.context?.hasPrefix("duet:") == true, "Banter opening not restricted")
        await gemini.emit(.completedText("I booked us one body and two opinions.", contextID: initial.context))
        try await eventually("First character did not speak") { log.speeches.count == 1 }
        let requestsBeforePlayback = await openAI.requests.count
        try expect(requestsBeforePlayback == 0, "Peer replied before speech playback finished")
        await router.finishPersonalitySpeech(utteranceID: "stale", finished: true)
        let requestsAfterStalePlayback = await openAI.requests.count
        try expect(requestsAfterStalePlayback == 0, "Stale speech completion started a peer turn")
        await router.finishPersonalitySpeech(utteranceID: log.speeches[0].2, finished: true)
        let second = await openAI.requests.last!
        await openAI.emit(.toolCalls([.init(call: raw, contextID: second.context)]))
        await openAI.emit(.completedText("The opinions were clearly over budget.", contextID: second.context))
        try await eventually("Peer line missing") { log.speeches.count == 2 }
        try expect(log.calls.count == 1, "Peer comedy gained motion authority")
        await router.finishPersonalitySpeech(utteranceID: log.speeches[1].2, finished: true)
        let third = await gemini.requests.last!
        await gemini.emit(.toolCalls([.init(call: raw, contextID: third.context)]))
        await gemini.emit(.completedText("At least we split the maintenance bill.", contextID: third.context))
        try await eventually("Driver comeback missing") { log.speeches.count == 3 }
        await router.finishPersonalitySpeech(utteranceID: log.speeches[2].2, finished: true)
        let peerRequestCount = await openAI.requests.count
        try expect(peerRequestCount == 1 && log.calls.count == 1, "Dialogue exceeded line or authority budget")
        await openAI.emit(.completedText("late stale reply", contextID: second.context))
        await router.startDialogue()
        let cancelled = await gemini.requests.last!
        await router.cancelDialogue()
        await gemini.emit(.completedText("should not speak", contextID: cancelled.context))
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(log.speeches.count == 3, "Cancelled dialogue spoke a late reply")
        await router.stop(connectionState: .off, failureDetail: "fixture ended")
        await router.applyRuntimePolicy(policy())
        await gemini.emit(.toolCalls([.init(call: raw, contextID: nil)]))
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(log.calls.count == 1, "Stopped router forwarded motion")
    }
    static func testOpenAIDriverModes() async throws {
        for mode in [ROBRealtimeMode.openAI, .dual] {
            let pool = SessionPool(), log = EventLog()
            var preferences = ROBRealtimePreferences(); preferences.mode = mode; preferences.dualDriver = .openAI
            let router = ROBRealtimeRouter(preferences: preferences, policy: policy(), factory: pool.make, event: log.add)
            await router.applyRuntimePolicy(policy())
            try await eventually("OpenAI driver not ready") { log.values.contains { if case .connectionState(.ready, _) = $0 { return true }; return false } }
            let driver = pool.get(.openAI)
            await router.enqueueAudioPCM16(Data([0, 0]), generation: 1)
            let receivedAudio = await driver.audioChunks
            try expect(receivedAudio == 1, "OpenAI driver did not receive microphone input")
            let raw = GeminiRoboticsToolCall(id: "openai-action", name: "loiter_control", arguments: ["command": "status"])
            await driver.emit(.toolCalls([.init(call: raw, contextID: nil)]))
            try await eventually("OpenAI driver tool missing") { log.calls.count == 1 }
            try expect(log.calls[0].provider == .openAI, "OpenAI action inherited Gemini identity")
            if mode == .dual {
                let peer = pool.get(.gemini)
                await peer.emit(.toolCalls([.init(call: raw, contextID: nil)]))
                try await eventually("Gemini peer action was not rejected") { await peer.results.count == 1 }
                let peerAudio = await peer.audioChunks
                try expect(log.calls.count == 1 && peerAudio == 0, "Gemini peer inherited driver permissions")
            }
            await router.stop(connectionState: .off, failureDetail: nil)
        }
    }
}
