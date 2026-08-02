//
//  ROBAI.swift
//  Cerebro
//
//  Gemini Robotics ER 2 live-session facade for Objective-C callers.
//

import AVFoundation
import CoreImage
import Foundation
import ImageIO

@objc public protocol ROBAIDelegate: AnyObject {
    @objc optional func robAI(_ robAI: ROBAI, didReceiveResponseText text: String)
    @objc optional func robAI(_ robAI: ROBAI, didReceiveInputTranscription text: String)
    @objc optional func robAI(_ robAI: ROBAI, didFailRequestWithDetail detail: String)
    @objc optional func robAI(_ robAI: ROBAI, didChangeConnectionState state: String, detail: String?)
    @objc optional func robAIWasInterrupted(_ robAI: ROBAI)
    @objc optional func robAI(_ robAI: ROBAI, didReceiveToolCall call: ROBAIRobotToolCall)
    @objc optional func robAI(_ robAI: ROBAI, didCancelToolCallIDs callIDs: [String])
}

@objcMembers public final class ROBAIRobotToolCall: NSObject {
    public let callID: String
    public let name: String
    public let arguments: NSDictionary

    init(callID: String, name: String, arguments: [String: Any]) {
        self.callID = callID
        self.name = name
        self.arguments = arguments as NSDictionary
        super.init()
    }
}

@available(macOS 10.15, *)
@objcMembers public final class ROBAI: NSObject {
    public weak var delegate: ROBAIDelegate?

    public var isConfigured: Bool { configuration != nil }
    public var streamsMicrophoneAudio: Bool { configuration?.streamsAudio ?? false }
    public var streamsCameraVideo: Bool { configuration?.streamsVideo ?? false }
    public var isLiveSessionReady: Bool {
        statusLock.lock()
        defer { statusLock.unlock() }
        return liveSessionReady
    }

    private let configuration: GeminiRoboticsConfiguration?
    private let statusLock = NSLock()
    private var liveSessionReady = false
    private var liveSession: GeminiRoboticsLiveSession?
    private var audioEventStream: GeminiOrderedAudioEventStream?
    private var audioEncoder: GeminiPCM16Encoder?
    private var videoEncoder: GeminiJPEGEncoder?

    public override init() {
        let configuration = GeminiRoboticsConfiguration.fromEnvironment()
        self.configuration = configuration
        super.init()

        guard let configuration else {
            return
        }

        let session = GeminiRoboticsLiveSession(configuration: configuration) { [weak self] event in
            self?.handle(event)
        }
        liveSession = session

        if configuration.streamsAudio {
            let audioEventStream = GeminiOrderedAudioEventStream(session: session)
            self.audioEventStream = audioEventStream
            audioEncoder = GeminiPCM16Encoder(
                didEncode: { [weak audioEventStream] data in
                    audioEventStream?.enqueuePCM16(data)
                },
                didEndStream: { [weak audioEventStream] in
                    audioEventStream?.enqueueStreamEnd()
                }
            )
        }

        if configuration.streamsVideo {
            videoEncoder = GeminiJPEGEncoder { [weak session] data in
                Task { await session?.sendVideoJPEG(data) }
            }
        }
    }

    deinit {
        audioEventStream?.finish()
        let session = liveSession
        Task { await session?.stop() }
    }

    public func start() {
        guard let liveSession else {
            notifyConnectionState("disabled", detail: "Set GEMINI_ROBOTICS_ENABLED=true and provide GEMINI_EPHEMERAL_TOKEN or GEMINI_API_KEY to enable streaming.")
            return
        }
        Task { await liveSession.start() }
    }

    public func disconnect() {
        statusLock.lock()
        liveSessionReady = false
        statusLock.unlock()
        audioEncoder?.reset()
        let session = liveSession
        Task { await session?.stop() }
    }

    public func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // This method is called by AVAudioEngine's real-time tap. Never wait
        // for session-state contention; dropping one buffer is preferable to
        // blocking the audio render thread.
        guard statusLock.try() else { return }
        let isReady = liveSessionReady
        statusLock.unlock()
        guard isReady else { return }
        audioEncoder?.enqueue(buffer)
    }

    public func sendAudioStreamEnd() {
        guard isLiveSessionReady else { return }
        audioEncoder?.endStream()
    }

    /// Records that the on-device recognizer heard an utterance while Gemini
    /// owns the microphone. The text is deliberately not resent: this only
    /// gives the raw-audio turn a bounded response deadline.
    public func noteMicrophoneTurnAwaitingResponse() {
        let session = liveSession
        Task { await session?.noteMicrophoneTurnAwaitingResponse() }
    }

    public func sendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isLiveSessionReady else { return }
        videoEncoder?.enqueue(sampleBuffer)
    }

    public func sendText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let session = liveSession
        Task { await session?.sendTextTurn(trimmedText) }
    }

    public func sendText(_ text: String, speechWordiness: Int) {
        // Preserve ROB's wake/address phrase: the system instruction uses it
        // to decide whether a new conversation should receive a response.
        sendText(GeminiRoboticsPrompt.spokenText(text, speechWordiness: speechWordiness))
    }

    public func sendToolResponse(
        callID: String,
        name: String,
        result: NSDictionary
    ) {
        let swiftResult = result as? [String: Any] ?? [:]
        let session = liveSession
        Task {
            await session?.sendToolResponse(callID: callID, name: name, result: swiftResult)
        }
    }

    /// Releases the Live session's blocking tool slot only after the local
    /// robot coordinator has confirmed that a cancelled action is no longer
    /// using physical resources. A Gemini cancellation by itself is not proof
    /// that motion has stopped.
    public func confirmToolCallCancellation(_ callID: String) {
        let session = liveSession
        Task { await session?.confirmToolCallCancellation(callID: callID) }
    }

    private func handle(_ event: GeminiRoboticsLiveSession.Event) {
        switch event {
        case .connectionState(let state, let detail):
            statusLock.lock()
            liveSessionReady = state == .ready
            statusLock.unlock()
            notifyConnectionState(state.rawValue, detail: detail)

        case .completedText(let text):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.robAI?(self, didReceiveResponseText: text)
            }

        case .inputTranscription(let text):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.robAI?(self, didReceiveInputTranscription: text)
            }

        case .requestFailed(let detail):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.robAI?(self, didFailRequestWithDetail: detail)
            }

        case .interrupted:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.robAIWasInterrupted?(self)
            }

        case .toolCalls(let calls):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for call in calls {
                    let bridgedCall = ROBAIRobotToolCall(
                        callID: call.id,
                        name: call.name,
                        arguments: call.arguments
                    )
                    self.delegate?.robAI?(self, didReceiveToolCall: bridgedCall)
                }
            }

        case .cancelledToolCalls(let callIDs):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.robAI?(self, didCancelToolCallIDs: callIDs)
            }
        }
    }

    private func notifyConnectionState(_ state: String, detail: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.robAI?(self, didChangeConnectionState: state, detail: detail)
        }
    }
}

private actor GeminiRoboticsLiveSession {
    enum ConnectionState: String {
        case connecting
        case ready
        case reconnecting
        case disconnected
        case failed
    }

    enum Event {
        case connectionState(ConnectionState, String?)
        case completedText(String)
        case inputTranscription(String)
        case requestFailed(String)
        case interrupted
        case toolCalls([GeminiRoboticsToolCall])
        case cancelledToolCalls([String])
    }

    private enum AudioQueueItem {
        case pcm(Data)
        case streamEnd
    }

    private struct ToolResponsePayload {
        let callID: String
        let name: String
        let result: [String: Any]
    }

    private enum ToolCallState {
        case pending(name: String)
        case cancelling(name: String)
        case completed(ToolResponsePayload)
        case cancelled
    }

    private let configuration: GeminiRoboticsConfiguration
    private let eventHandler: (Event) -> Void
    private var shouldRun = false
    private var setupIsComplete = false
    private var connectionTask: Task<Void, Never>?
    private var audioDrainTask: Task<Void, Never>?
    private var videoDrainTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var resumptionHandle: String?
    private var resumptionHandleDate: Date?
    private var responseText = ""
    private var outputTranscription = GeminiTranscriptionAccumulator()
    private var microphoneTurnAssociation = GeminiMicrophoneTurnAssociation()
    private var audioQueue: [AudioQueueItem] = []
    private var pendingTextTurns: [String] = []
    private var textTurnIsInFlight = false
    private var inFlightTextTurn: String?
    private var inFlightTextTurnID: UInt64?
    private var nextTextTurnID: UInt64 = 0
    private var turnDeadlineTracker = GeminiTurnDeadlineTracker()
    private var responseStartDeadlineTask: Task<Void, Never>?
    private var turnCompletionDeadlineTask: Task<Void, Never>?
    private var microphoneTurnDeadlineTracker = GeminiTurnDeadlineTracker()
    private var microphoneResponseStartDeadlineTask: Task<Void, Never>?
    private var microphoneTurnCompletionDeadlineTask: Task<Void, Never>?
    private var inFlightMicrophoneTurnID: UInt64?
    private var nextMicrophoneTurnID: UInt64 = 0
    private var microphoneTurnHasResponse = false
    private var lastModelTurnCompletionTime: TimeInterval?
    private var pendingVideoJPEG: Data?
    private var lastVideoSendTime: TimeInterval = 0
    private var toolCallLedger: [String: ToolCallState] = [:]
    private var toolExecutionQueue: [GeminiRoboticsToolCall] = []
    private var activeToolCallID: String?
    private var pendingToolResponses: [String: ToolResponsePayload] = [:]
    private var pendingToolResponseOrder: [String] = []
    private var runGeneration: UInt = 0
    private let maximumQueuedAudioItems = 10

    init(configuration: GeminiRoboticsConfiguration, eventHandler: @escaping (Event) -> Void) {
        self.configuration = configuration
        self.eventHandler = eventHandler
    }

    func start() {
        guard connectionTask == nil else { return }
        shouldRun = true
        runGeneration &+= 1
        let generation = runGeneration
        connectionTask = Task { [weak self] in
            await self?.connectionLoop(generation: generation)
        }
    }

    func stop() {
        runGeneration &+= 1
        shouldRun = false
        setupIsComplete = false
        resetResponseState()
        audioQueue.removeAll()
        pendingTextTurns.removeAll()
        textTurnIsInFlight = false
        inFlightTextTurn = nil
        inFlightTextTurnID = nil
        cancelTextTurnDeadlines()
        turnDeadlineTracker = GeminiTurnDeadlineTracker()
        cancelMicrophoneTurnDeadlines()
        microphoneTurnDeadlineTracker = GeminiTurnDeadlineTracker()
        inFlightMicrophoneTurnID = nil
        microphoneTurnHasResponse = false
        lastModelTurnCompletionTime = nil
        pendingVideoJPEG = nil
        resumptionHandle = nil
        resumptionHandleDate = nil
        toolCallLedger.removeAll()
        toolExecutionQueue.removeAll()
        activeToolCallID = nil
        pendingToolResponses.removeAll()
        pendingToolResponseOrder.removeAll()
        audioDrainTask?.cancel()
        audioDrainTask = nil
        videoDrainTask?.cancel()
        videoDrainTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        eventHandler(.connectionState(.disconnected, nil))
    }

    func enqueueAudioPCM16(_ data: Data) {
        guard setupIsComplete, !data.isEmpty else { return }
        if audioQueue.count >= maximumQueuedAudioItems {
            guard let oldestPCMIndex = audioQueue.firstIndex(where: { item in
                if case .pcm = item { return true }
                return false
            }) else {
                return
            }
            audioQueue.remove(at: oldestPCMIndex)
        }
        audioQueue.append(.pcm(data))
        startAudioDrainIfNeeded()
    }

    func enqueueAudioStreamEnd() {
        guard setupIsComplete else { return }
        while audioQueue.count >= maximumQueuedAudioItems,
              let oldestPCMIndex = audioQueue.firstIndex(where: { item in
                  if case .pcm = item { return true }
                  return false
              }) {
            audioQueue.remove(at: oldestPCMIndex)
        }
        audioQueue.append(.streamEnd)
        startAudioDrainIfNeeded()
    }

    func sendVideoJPEG(_ data: Data) async {
        guard setupIsComplete, !data.isEmpty else { return }
        pendingVideoJPEG = data
        startVideoDrainIfNeeded()
    }

    func sendTextTurn(_ text: String) async {
        guard !text.isEmpty else { return }
        if pendingTextTurns.count >= 5 {
            pendingTextTurns.removeFirst()
        }
        pendingTextTurns.append(text)
        await sendNextTextTurnIfPossible()
    }

    func noteMicrophoneTurnAwaitingResponse() {
        guard setupIsComplete,
              configuration.streamsAudio else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let hasTrackedTurn = textTurnIsInFlight || inFlightMicrophoneTurnID != nil
        let disposition = microphoneTurnAssociation.noteLocalTranscript(
            hasTrackedTurn: hasTrackedTurn
        )
        // A raw-audio callback during a queued text response can represent a
        // barge-in. Preserve that ordering signal, but never run both deadline
        // owners concurrently.
        if textTurnIsInFlight {
            return
        }

        // A final on-device transcription callback can arrive just after a
        // very fast Gemini response. Do not turn that late callback into a
        // phantom request failure. ROBSpeech keeps capture half-duplex during
        // the remainder of the response, so this window cannot mask a real
        // follow-up utterance.
        let responseAlreadyStarted = disposition == .associateWithActiveResponse
        if disposition == .beginAwaitingResponse,
           let lastModelTurnCompletionTime,
           now - lastModelTurnCompletionTime < 1.0 {
            return
        }
        if let turnID = inFlightMicrophoneTurnID {
            guard !microphoneTurnHasResponse else { return }
            microphoneTurnDeadlineTracker.begin(turnID: turnID, now: now)
            if responseAlreadyStarted {
                microphoneTurnHasResponse = true
                microphoneTurnDeadlineTracker.noteResponse(turnID: turnID)
            }
            beginMicrophoneTurnDeadlineTasks(
                turnID: turnID,
                responseAlreadyStarted: microphoneTurnHasResponse
            )
            return
        }

        nextMicrophoneTurnID &+= 1
        let turnID = nextMicrophoneTurnID
        inFlightMicrophoneTurnID = turnID
        microphoneTurnHasResponse = false
        microphoneTurnDeadlineTracker.begin(turnID: turnID, now: now)
        if responseAlreadyStarted {
            microphoneTurnHasResponse = true
            microphoneTurnDeadlineTracker.noteResponse(turnID: turnID)
        }
        beginMicrophoneTurnDeadlineTasks(
            turnID: turnID,
            responseAlreadyStarted: microphoneTurnHasResponse
        )
        NSLog("Gemini Robotics microphone turn %@ detected", String(turnID))
    }

    func sendToolResponse(callID: String, name: String, result: [String: Any]) async {
        guard let state = toolCallLedger[callID] else { return }
        switch state {
        case .cancelled:
            return
        case .cancelling:
            // Gemini no longer expects a tool response for this call. The
            // bridge must separately confirm the physical cancellation before
            // another blocking action can be dispatched.
            return
        case .completed(let response):
            queueToolResponse(response)
            await flushPendingToolResponsesIfPossible()
            return
        case .pending(let expectedName):
            guard name == expectedName else { return }
        }

        let response = ToolResponsePayload(callID: callID, name: name, result: result)
        toolCallLedger[callID] = .completed(response)
        queueToolResponse(response)
        if activeToolCallID == callID {
            activeToolCallID = nil
        }
        await flushPendingToolResponsesIfPossible()
        dispatchNextToolCallIfPossible()
    }

    func confirmToolCallCancellation(callID: String) {
        guard case .cancelling? = toolCallLedger[callID] else { return }
        toolCallLedger[callID] = .cancelled
        if activeToolCallID == callID {
            activeToolCallID = nil
        }
        dispatchNextToolCallIfPossible()
    }

    private func connectionLoop(generation: UInt) async {
        var retryAttempt = 0

        while shouldRun, generation == runGeneration, !Task.isCancelled {
            do {
                eventHandler(.connectionState(retryAttempt == 0 ? .connecting : .reconnecting, nil))
                try await runConnection(generation: generation)
                retryAttempt = 0
            } catch is CancellationError {
                break
            } catch {
                guard shouldRun, generation == runGeneration, !Task.isCancelled else { break }
                failInFlightTextTurn(
                    detail: "The Gemini connection ended before the request completed. Please try again."
                )
                failInFlightMicrophoneTurn(
                    detail: "The Gemini connection ended before the microphone request completed. Please try again."
                )
                eventHandler(.connectionState(.failed, error.localizedDescription))
                retryAttempt += 1
            }

            guard shouldRun, generation == runGeneration, !Task.isCancelled else { break }
            eventHandler(.connectionState(.reconnecting, "Reconnecting to Gemini Robotics"))
            let cappedAttempt = min(retryAttempt, 5)
            let baseDelay = min(pow(2.0, Double(cappedAttempt)), 30.0)
            let jitteredDelay = baseDelay + Double.random(in: 0 ... 0.5)
            do {
                try await Task.sleep(nanoseconds: UInt64(jitteredDelay * 1_000_000_000))
            } catch {
                break
            }
        }

        guard generation == runGeneration else { return }
        setupIsComplete = false
        socket = nil
        connectionTask = nil
        if !shouldRun {
            eventHandler(.connectionState(.disconnected, nil))
        }
    }

    private func runConnection(generation: UInt) async throws {
        if let handleDate = resumptionHandleDate,
           Date().timeIntervalSince(handleDate) >= 7_100 {
            resumptionHandle = nil
            resumptionHandleDate = nil
        }
        let attemptedResumption = resumptionHandle != nil
        let url = try configuration.webSocketURL()
        let webSocket = URLSession.shared.webSocketTask(with: url)
        socket = webSocket
        setupIsComplete = false
        resetResponseState()
        audioQueue.removeAll()
        webSocket.resume()

        let setup = GeminiRoboticsProtocol.setupMessage(
            configuration: configuration,
            resumptionHandle: resumptionHandle
        )
        try await send(setup, over: webSocket)

        defer {
            webSocket.cancel(with: .goingAway, reason: nil)
            if generation == runGeneration, socket === webSocket {
                socket = nil
                setupIsComplete = false
            }
        }

        while shouldRun, generation == runGeneration, !Task.isCancelled {
            let message = try await webSocket.receive()
            let data: Data
            switch message {
            case .data(let receivedData):
                data = receivedData
            case .string(let string):
                guard let stringData = string.data(using: .utf8) else {
                    throw GeminiRoboticsProtocolError.invalidServerMessage
                }
                data = stringData
            @unknown default:
                continue
            }

            let serverEvent = try GeminiRoboticsProtocol.parseServerMessage(data)
            if let serverError = serverEvent.serverError {
                if !setupIsComplete && attemptedResumption {
                    resumptionHandle = nil
                    resumptionHandleDate = nil
                    failInFlightTextTurn(
                        detail: "Gemini could not resume the request. Please try again."
                    )
                    resetResponseState()
                }
                throw NSError(
                    domain: "GeminiRoboticsLiveSession",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: serverError]
                )
            }

            if serverEvent.setupComplete {
                setupIsComplete = true
                eventHandler(.connectionState(.ready, nil))
                await flushPendingToolResponsesIfPossible()
                await sendNextTextTurnIfPossible()
            }

            if serverEvent.isResumable == true,
               let handle = serverEvent.resumptionHandle,
               !handle.isEmpty {
                resumptionHandle = handle
                resumptionHandleDate = Date()
            } else if serverEvent.isResumable == false {
                resumptionHandle = nil
                resumptionHandleDate = nil
            }

            if let inputTranscription = serverEvent.inputTranscription,
               !inputTranscription.isEmpty {
                eventHandler(.inputTranscription(inputTranscription))
            }

            // Live may deliver `interrupted` and the old turn's `turnComplete`
            // in separate envelopes. Discard that old tail without allowing it
            // to finalize or clear the new raw-microphone watchdog.
            if microphoneTurnAssociation.awaitingInterruptedTurnCompletion,
               !serverEvent.interrupted {
                if serverEvent.turnComplete {
                    _ = microphoneTurnAssociation.consumeInterruptedTurnCompletion()
                    resetResponseBuffers()
                    await sendNextTextTurnIfPossible()
                }
                if !serverEvent.cancelledToolCallIDs.isEmpty {
                    handleToolCallCancellations(serverEvent.cancelledToolCallIDs)
                }
                if serverEvent.shouldReconnect {
                    failInFlightTextTurn(
                        detail: "Gemini requested a reconnect before completing the request. Please try again."
                    )
                    failInFlightMicrophoneTurn(
                        detail: "Gemini requested a reconnect before completing the microphone request. Please try again."
                    )
                    return
                }
                continue
            }

            let hasUsableModelOutput = !serverEvent.textFragments.isEmpty ||
                !(serverEvent.outputTranscription ?? "").isEmpty ||
                !serverEvent.toolCalls.isEmpty
            if hasUsableModelOutput || serverEvent.generationComplete {
                microphoneTurnAssociation.noteModelResponseStarted()
                noteInFlightTextTurnResponse()
                noteInFlightMicrophoneTurnResponse()
            }

            if serverEvent.interrupted {
                let shouldArmMicrophoneFollowup = microphoneTurnAssociation.noteInterruption()
                lastModelTurnCompletionTime = nil
                resetResponseBuffers()
                completeInFlightTextTurnDeadline()
                completeInFlightMicrophoneTurnDeadline()
                textTurnIsInFlight = false
                inFlightTextTurn = nil
                inFlightTextTurnID = nil
                eventHandler(.interrupted)
                if shouldArmMicrophoneFollowup {
                    beginNewMicrophoneTurn(now: ProcessInfo.processInfo.systemUptime)
                }
                if serverEvent.turnComplete {
                    _ = microphoneTurnAssociation.consumeInterruptedTurnCompletion()
                    await sendNextTextTurnIfPossible()
                }
            } else {
                responseText += serverEvent.textFragments.joined()
                if let fragment = serverEvent.outputTranscription {
                    appendTranscriptFragment(fragment)
                }
                if serverEvent.turnComplete {
                    await finalizeCompletedTurn()
                }
            }

            if !serverEvent.interrupted, !serverEvent.toolCalls.isEmpty {
                await handleToolCalls(serverEvent.toolCalls)
            }
            if !serverEvent.cancelledToolCallIDs.isEmpty {
                handleToolCallCancellations(serverEvent.cancelledToolCallIDs)
            }
            if serverEvent.shouldReconnect {
                failInFlightTextTurn(
                    detail: "Gemini requested a reconnect before completing the request. Please try again."
                )
                failInFlightMicrophoneTurn(
                    detail: "Gemini requested a reconnect before completing the microphone request. Please try again."
                )
                return
            }
        }
    }

    private func sendNextTextTurnIfPossible() async {
        guard setupIsComplete,
              !textTurnIsInFlight,
              inFlightMicrophoneTurnID == nil,
              !pendingTextTurns.isEmpty,
              let socket else {
            return
        }

        let text = pendingTextTurns.removeFirst()
        nextTextTurnID &+= 1
        let turnID = nextTextTurnID
        textTurnIsInFlight = true
        inFlightTextTurn = text
        inFlightTextTurnID = turnID
        beginTextTurnDeadlines(turnID: turnID)
        do {
            try await send(GeminiRoboticsProtocol.realtimeTextMessage(text), over: socket)
            NSLog("Gemini Robotics text turn %@ sent", String(turnID))
        } catch {
            failInFlightTextTurn(
                detail: "Cerebro could not send the request to Gemini. Please try again."
            )
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func appendTranscriptFragment(_ fragment: String) {
        guard !fragment.isEmpty else { return }
        outputTranscription.append(fragment)
    }

    private func finalizeCompletedTurn() async {
        let modelText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcribedText = outputTranscription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let completedText = modelText.isEmpty ? transcribedText : modelText
        let hadTextTurn = textTurnIsInFlight
        let hadMicrophoneTurn = inFlightMicrophoneTurnID != nil

        completeInFlightTextTurnDeadline()
        completeInFlightMicrophoneTurnDeadline()
        lastModelTurnCompletionTime = ProcessInfo.processInfo.systemUptime

        resetResponseState()
        textTurnIsInFlight = false
        inFlightTextTurn = nil
        inFlightTextTurnID = nil

        if !completedText.isEmpty {
            eventHandler(.completedText(completedText))
        } else if hadTextTurn || hadMicrophoneTurn {
            eventHandler(.requestFailed("Gemini completed the request without a usable spoken response."))
        }
        await sendNextTextTurnIfPossible()
    }

    private func resetResponseState() {
        resetResponseBuffers()
        microphoneTurnAssociation.reset()
    }

    private func resetResponseBuffers() {
        responseText = ""
        outputTranscription.reset()
    }

    private func beginTextTurnDeadlines(turnID: UInt64) {
        turnDeadlineTracker.begin(
            turnID: turnID,
            now: ProcessInfo.processInfo.systemUptime
        )
        responseStartDeadlineTask?.cancel()
        turnCompletionDeadlineTask?.cancel()

        let responseDelay = turnDeadlineTracker.responseStartTimeout
        responseStartDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
            } catch {
                return
            }
            await self?.handleTextTurnDeadline(turnID: turnID)
        }

        let completionDelay = turnDeadlineTracker.turnCompletionTimeout
        turnCompletionDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(completionDelay * 1_000_000_000))
            } catch {
                return
            }
            await self?.handleTextTurnDeadline(turnID: turnID)
        }
    }

    private func noteInFlightTextTurnResponse() {
        guard let turnID = inFlightTextTurnID else { return }
        turnDeadlineTracker.noteResponse(turnID: turnID)
    }

    private func completeInFlightTextTurnDeadline() {
        if let turnID = inFlightTextTurnID {
            turnDeadlineTracker.complete(turnID: turnID)
        }
        cancelTextTurnDeadlines()
    }

    private func cancelTextTurnDeadlines() {
        responseStartDeadlineTask?.cancel()
        responseStartDeadlineTask = nil
        turnCompletionDeadlineTask?.cancel()
        turnCompletionDeadlineTask = nil
    }

    private func handleTextTurnDeadline(turnID: UInt64) {
        guard textTurnIsInFlight, inFlightTextTurnID == turnID else { return }
        guard let expiration = turnDeadlineTracker.expiration(
            turnID: turnID,
            now: ProcessInfo.processInfo.systemUptime
        ) else {
            return
        }

        let detail: String
        switch expiration {
        case .responseNotStarted:
            detail = "Gemini did not start a response within 15 seconds. Please try again."
        case .turnNotCompleted:
            detail = "Gemini did not finish the response. Please try again."
        }
        if failInFlightTextTurn(detail: detail) {
            socket?.cancel(with: .goingAway, reason: nil)
        }
    }

    @discardableResult
    private func failInFlightTextTurn(detail: String) -> Bool {
        guard textTurnIsInFlight else { return false }
        completeInFlightTextTurnDeadline()
        resetResponseState()
        textTurnIsInFlight = false
        inFlightTextTurn = nil
        inFlightTextTurnID = nil
        eventHandler(.requestFailed(detail))
        return true
    }

    private func beginMicrophoneTurnDeadlineTasks(
        turnID: UInt64,
        responseAlreadyStarted: Bool
    ) {
        microphoneResponseStartDeadlineTask?.cancel()
        microphoneTurnCompletionDeadlineTask?.cancel()

        if !responseAlreadyStarted {
            let responseDelay = microphoneTurnDeadlineTracker.responseStartTimeout
            microphoneResponseStartDeadlineTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
                } catch {
                    return
                }
                await self?.handleMicrophoneTurnDeadline(turnID: turnID)
            }
        } else {
            microphoneResponseStartDeadlineTask = nil
        }

        let completionDelay = microphoneTurnDeadlineTracker.turnCompletionTimeout
        microphoneTurnCompletionDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(completionDelay * 1_000_000_000))
            } catch {
                return
            }
            await self?.handleMicrophoneTurnDeadline(turnID: turnID)
        }
    }

    private func beginNewMicrophoneTurn(now: TimeInterval) {
        nextMicrophoneTurnID &+= 1
        let turnID = nextMicrophoneTurnID
        inFlightMicrophoneTurnID = turnID
        microphoneTurnHasResponse = false
        microphoneTurnDeadlineTracker.begin(turnID: turnID, now: now)
        beginMicrophoneTurnDeadlineTasks(turnID: turnID, responseAlreadyStarted: false)
        NSLog("Gemini Robotics microphone turn %@ detected after interruption", String(turnID))
    }

    private func noteInFlightMicrophoneTurnResponse() {
        guard let turnID = inFlightMicrophoneTurnID else { return }
        microphoneTurnHasResponse = true
        microphoneTurnDeadlineTracker.noteResponse(turnID: turnID)
        microphoneResponseStartDeadlineTask?.cancel()
        microphoneResponseStartDeadlineTask = nil
    }

    private func completeInFlightMicrophoneTurnDeadline() {
        if let turnID = inFlightMicrophoneTurnID {
            microphoneTurnDeadlineTracker.complete(turnID: turnID)
        }
        cancelMicrophoneTurnDeadlines()
        inFlightMicrophoneTurnID = nil
        microphoneTurnHasResponse = false
    }

    private func cancelMicrophoneTurnDeadlines() {
        microphoneResponseStartDeadlineTask?.cancel()
        microphoneResponseStartDeadlineTask = nil
        microphoneTurnCompletionDeadlineTask?.cancel()
        microphoneTurnCompletionDeadlineTask = nil
    }

    private func handleMicrophoneTurnDeadline(turnID: UInt64) {
        guard inFlightMicrophoneTurnID == turnID else { return }
        guard let expiration = microphoneTurnDeadlineTracker.expiration(
            turnID: turnID,
            now: ProcessInfo.processInfo.systemUptime
        ) else {
            return
        }

        let detail: String
        switch expiration {
        case .responseNotStarted:
            detail = "Gemini did not start a response to the microphone input within 15 seconds. Please try again."
        case .turnNotCompleted:
            detail = "Gemini did not finish the microphone response. Please try again."
        }
        if failInFlightMicrophoneTurn(detail: detail) {
            socket?.cancel(with: .goingAway, reason: nil)
        }
    }

    @discardableResult
    private func failInFlightMicrophoneTurn(detail: String) -> Bool {
        guard inFlightMicrophoneTurnID != nil else { return false }
        completeInFlightMicrophoneTurnDeadline()
        resetResponseState()
        eventHandler(.requestFailed(detail))
        return true
    }

    private func startVideoDrainIfNeeded() {
        guard videoDrainTask == nil else { return }
        videoDrainTask = Task { [weak self] in
            await self?.drainVideoQueue()
        }
    }

    private func drainVideoQueue() async {
        while setupIsComplete, pendingVideoJPEG != nil, !Task.isCancelled {
            let elapsed = ProcessInfo.processInfo.systemUptime - lastVideoSendTime
            if elapsed < 1.0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
                } catch {
                    break
                }
            }

            guard setupIsComplete,
                  let data = pendingVideoJPEG,
                  let socket else {
                break
            }
            pendingVideoJPEG = nil
            do {
                try await send(GeminiRoboticsProtocol.realtimeVideoMessage(data), over: socket)
                lastVideoSendTime = ProcessInfo.processInfo.systemUptime
            } catch {
                pendingVideoJPEG = data
                socket.cancel(with: .goingAway, reason: nil)
                break
            }
        }
        videoDrainTask = nil
    }

    private func handleToolCalls(_ calls: [GeminiRoboticsToolCall]) async {
        for call in calls {
            if let existingState = toolCallLedger[call.id] {
                switch existingState {
                case .completed(let response):
                    queueToolResponse(response)
                case .pending, .cancelling, .cancelled:
                    break
                }
                continue
            }

            toolCallLedger[call.id] = .pending(name: call.name)
            toolExecutionQueue.append(call)
        }

        await flushPendingToolResponsesIfPossible()
        dispatchNextToolCallIfPossible()
    }

    private func handleToolCallCancellations(_ callIDs: [String]) {
        for callID in callIDs {
            toolExecutionQueue.removeAll { $0.id == callID }
            if activeToolCallID == callID {
                switch toolCallLedger[callID] {
                case .pending(let name):
                    // Keep the blocking slot occupied until Cerebro receives a
                    // cancellation result from its local action coordinator.
                    toolCallLedger[callID] = .cancelling(name: name)
                case .cancelling:
                    // A repeated cancellation is an idempotent retransmission.
                    break
                case .completed, .cancelled, .none:
                    toolCallLedger[callID] = .cancelled
                    activeToolCallID = nil
                }
            } else {
                toolCallLedger[callID] = .cancelled
            }
        }
        eventHandler(.cancelledToolCalls(callIDs))
        dispatchNextToolCallIfPossible()
    }

    private func dispatchNextToolCallIfPossible() {
        guard activeToolCallID == nil, !toolExecutionQueue.isEmpty else { return }
        let call = toolExecutionQueue.removeFirst()
        activeToolCallID = call.id
        eventHandler(.toolCalls([call]))
    }

    private func queueToolResponse(_ response: ToolResponsePayload) {
        pendingToolResponses[response.callID] = response
        if !pendingToolResponseOrder.contains(response.callID) {
            pendingToolResponseOrder.append(response.callID)
        }
    }

    private func flushPendingToolResponsesIfPossible() async {
        guard setupIsComplete, let socket else { return }
        while let callID = pendingToolResponseOrder.first,
              let response = pendingToolResponses[callID] {
            do {
                try await send(
                    GeminiRoboticsProtocol.toolResponseMessage(
                        callID: response.callID,
                        name: response.name,
                        result: response.result
                    ),
                    over: socket
                )
                pendingToolResponseOrder.removeFirst()
                pendingToolResponses.removeValue(forKey: callID)
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                break
            }
        }
    }

    private func startAudioDrainIfNeeded() {
        guard audioDrainTask == nil else { return }
        audioDrainTask = Task { [weak self] in
            await self?.drainAudioQueue()
        }
    }

    private func drainAudioQueue() async {
        while setupIsComplete, !audioQueue.isEmpty, !Task.isCancelled {
            let item = audioQueue.removeFirst()
            let message: [String: Any]
            switch item {
            case .pcm(let data):
                message = GeminiRoboticsProtocol.realtimeAudioMessage(data)
            case .streamEnd:
                message = GeminiRoboticsProtocol.audioStreamEndMessage()
            }

            guard let socket else { break }
            do {
                try await send(message, over: socket)
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                break
            }
        }
        audioDrainTask = nil
    }

    private func send(_ object: [String: Any], over socket: URLSessionWebSocketTask) async throws {
        let json = try GeminiRoboticsProtocol.jsonString(from: object)
        try await socket.send(.string(json))
    }
}

private final class GeminiOrderedAudioEventStream {
    private enum Event {
        case pcm16(Data)
        case streamEnd
    }

    private let continuation: AsyncStream<Event>.Continuation
    private let stateLock = NSLock()
    private var consumerTask: Task<Void, Never>?
    private var streamEndIsBuffered = false

    init(session: GeminiRoboticsLiveSession) {
        var capturedContinuation: AsyncStream<Event>.Continuation!
        // The encoder calls this stream from one serial queue, preserving PCM
        // and streamEnd order. Keep the bridge bounded as well as the session.
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(16)) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
        consumerTask = Task { [weak self, weak session] in
            for await event in stream {
                guard let session else { break }
                switch event {
                case .pcm16(let data):
                    await session.enqueueAudioPCM16(data)
                case .streamEnd:
                    await session.enqueueAudioStreamEnd()
                    self?.markStreamEndConsumed()
                }
            }
        }
    }

    deinit {
        finish()
    }

    func enqueuePCM16(_ data: Data) {
        stateLock.lock()
        guard !streamEndIsBuffered else {
            stateLock.unlock()
            return
        }
        continuation.yield(.pcm16(data))
        stateLock.unlock()
    }

    func enqueueStreamEnd() {
        stateLock.lock()
        guard !streamEndIsBuffered else {
            stateLock.unlock()
            return
        }
        streamEndIsBuffered = true
        continuation.yield(.streamEnd)
        stateLock.unlock()
    }

    func finish() {
        continuation.finish()
        consumerTask?.cancel()
        consumerTask = nil
    }

    private func markStreamEndConsumed() {
        stateLock.lock()
        streamEndIsBuffered = false
        stateLock.unlock()
    }
}

private final class GeminiPCM16Encoder {
    private let queue = DispatchQueue(label: "com.orbitusrobotics.cerebro.gemini.audio-conversion")
    private let pendingLock = NSLock()
    private let didEncode: (Data) -> Void
    private let didEndStream: () -> Void
    private var pendingBufferCount = 0
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let maximumPendingBuffers = 12
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    init(didEncode: @escaping (Data) -> Void, didEndStream: @escaping () -> Void) {
        self.didEncode = didEncode
        self.didEndStream = didEndStream
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        guard pendingLock.try() else { return }
        guard pendingBufferCount < maximumPendingBuffers else {
            pendingLock.unlock()
            return
        }
        pendingBufferCount += 1
        pendingLock.unlock()

        guard let copiedBuffer = Self.copy(buffer) else {
            decrementPendingCount()
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.decrementPendingCount() }
            guard let data = self.convert(copiedBuffer), !data.isEmpty else { return }
            self.didEncode(data)
        }
    }

    func endStream() {
        queue.async { [weak self] in
            self?.didEndStream()
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.converter = nil
            self?.converterInputFormat = nil
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converterInputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converterInputFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = ceil(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedFrames)
        ) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return input
        }

        guard conversionError == nil,
              status != .error,
              output.frameLength > 0 else {
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        var data = Data()
        for buffer in buffers {
            guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            data.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
        }
        return data
    }

    private func decrementPendingCount() {
        pendingLock.lock()
        pendingBufferCount = max(0, pendingBufferCount - 1)
        pendingLock.unlock()
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }
        destination.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData else {
                return nil
            }
            let byteCount = min(sourceBuffer.mDataByteSize, destinationBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, Int(byteCount))
            destinationBuffers[index].mDataByteSize = byteCount
        }
        return destination
    }
}

private final class GeminiJPEGEncoder {
    private let queue = DispatchQueue(label: "com.orbitusrobotics.cerebro.gemini.video-encoding")
    private let throttleLock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let didEncode: (Data) -> Void
    private var lastAcceptedFrameTime: TimeInterval = 0
    private let minimumFrameInterval: TimeInterval = 1.0
    private let maximumDimension: CGFloat = 768

    init(didEncode: @escaping (Data) -> Void) {
        self.didEncode = didEncode
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        throttleLock.lock()
        guard now - lastAcceptedFrameTime >= minimumFrameInterval else {
            throttleLock.unlock()
            return
        }
        lastAcceptedFrameTime = now
        throttleLock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        queue.async { [weak self, pixelBuffer] in
            guard let self else { return }
            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let largestDimension = max(sourceImage.extent.width, sourceImage.extent.height)
            let scale = largestDimension > self.maximumDimension
                ? self.maximumDimension / largestDimension
                : 1.0
            let image = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let qualityKey = CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String
            )
            let options: [CIImageRepresentationOption: Any] = [qualityKey: 0.72]
            guard let jpegData = self.context.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: options
            ) else {
                return
            }
            self.didEncode(jpegData)
        }
    }
}
