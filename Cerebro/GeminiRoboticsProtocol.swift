//
//  GeminiRoboticsProtocol.swift
//  Cerebro
//
//  JSON protocol helpers for the Gemini Robotics ER 2 streaming API.
//

import Foundation
import Security

enum ROBRealtimeProvider: String, CaseIterable {
    case gemini
    case openAI = "openai"

    var displayName: String {
        switch self {
        case .gemini: return "Gemini Live"
        case .openAI: return "OpenAI Realtime"
        }
    }

    var keychainService: String {
        "com.orbitusrobotics.Cerebro.\(rawValue)"
    }

    /// Continuous camera frames are currently a Gemini capability. OpenAI's
    /// Realtime API accepts image inputs rather than a native video stream, so
    /// a future OpenAI adapter must sample frames without changing this claim.
    var supportsContinuousVideo: Bool { self == .gemini }
    var supportsRealtimeAudio: Bool { true }
}

enum ROBProviderCredentialStore {
    static let apiKeyAccount = "api-key"

    static func apiKey(for provider: ROBRealtimeProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: apiKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func saveAPIKey(_ apiKey: String, for provider: ROBRealtimeProvider) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            throw ROBProviderCredentialStoreError.emptyKey
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: apiKeyAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ROBProviderCredentialStoreError.keychain(updateStatus)
        }
        var item = identity
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ROBProviderCredentialStoreError.keychain(addStatus)
        }
    }

    static func removeAPIKey(for provider: ROBRealtimeProvider) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: apiKeyAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ROBProviderCredentialStoreError.keychain(status)
        }
    }
}

enum ROBProviderCredentialStoreError: LocalizedError {
    case emptyKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Enter an API key before saving."
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ??
                "Keychain returned error \(status)."
        }
    }
}

enum GeminiRoboticsCredentialStore {
    static func apiKey() -> String? {
        ROBProviderCredentialStore.apiKey(for: .gemini)
    }
}

enum GeminiRoboticsCredential {
    case apiKey(String)
    case ephemeralToken(String)

    var queryItem: URLQueryItem {
        switch self {
        case .apiKey(let value):
            return URLQueryItem(name: "key", value: value)
        case .ephemeralToken(let value):
            return URLQueryItem(name: "access_token", value: value)
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .apiKey:
            return "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        case .ephemeralToken:
            return "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
        }
    }
}

struct GeminiRoboticsConfiguration {
    static let defaultModel = "models/gemini-robotics-er-2-streaming-preview"
    static let defaultSystemInstruction = """
    You are ROB, Cerebro's embodied conversational assistant. Respond when someone addresses ROB, Robbie, Robot, or clearly continues an active conversation. Once you recognize an addressed or continuing user turn, always return at least a brief spoken acknowledgement; never complete a recognized user turn silently. Ignore indistinct background noise that is not a recognizable turn. Return plain spoken text without Markdown, normally one or two concise sentences unless the user requests detail. When Google Search is available, use it for current public information such as weather, news, schedules, and recent facts. Google Search is already authorized by Cerebro and never requires ROBController approval. Physical actions require ROBController approval or Cerebro's explicit, short-lived local Arm Debug Authority. Camera frames are observations, not proof that a physical action completed. Use only declared tools for physical actions and never claim an action succeeded until its matching tool response confirms measured completion. For play_gesture, supply only a named gesture; never invent or request raw joint values. If a requested physical-action tool is not declared, explain that the physical capability is not currently enabled.
    """

    let credential: GeminiRoboticsCredential
    let model: String
    let systemInstruction: String
    let streamsAudio: Bool
    let streamsVideo: Bool
    let exposesRobotActionTool: Bool
    let enablesGoogleSearch: Bool
    let responseModality: String

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> GeminiRoboticsConfiguration? {
        let environmentToken = environment.nonemptyValue(for: "GEMINI_EPHEMERAL_TOKEN")
        let environmentAPIKey = environment.nonemptyValue(for: "GEMINI_API_KEY")
        let keychainAPIKey = GeminiRoboticsCredentialStore.apiKey()
        let credential: GeminiRoboticsCredential
        if let token = environmentToken {
            credential = .ephemeralToken(token)
        } else if let apiKey = environmentAPIKey ?? keychainAPIKey {
            credential = .apiKey(apiKey)
        } else {
            return nil
        }

        // An explicit environment switch remains authoritative for managed
        // deployments. Personal installations need no launch script: a key
        // deliberately saved in Keychain opts Gemini in automatically.
        if environment["GEMINI_ROBOTICS_ENABLED"] != nil {
            guard environment.booleanValue(for: "GEMINI_ROBOTICS_ENABLED", default: false) else {
                return nil
            }
        } else {
            guard environmentToken == nil,
                  environmentAPIKey == nil,
                  keychainAPIKey != nil else {
                return nil
            }
        }

        let configuredModel = environment.nonemptyValue(for: "GEMINI_ROBOTICS_MODEL") ?? defaultModel
        let model = configuredModel.hasPrefix("models/") ? configuredModel : "models/\(configuredModel)"
        let configuredResponseModality = environment
            .nonemptyValue(for: "GEMINI_ROBOTICS_RESPONSE_MODALITY")?
            .uppercased()
        let responseModality = configuredResponseModality == "AUDIO" ? "AUDIO" : "TEXT"

        return GeminiRoboticsConfiguration(
            credential: credential,
            model: model,
            systemInstruction: environment.nonemptyValue(for: "GEMINI_ROBOTICS_SYSTEM_INSTRUCTION") ?? defaultSystemInstruction,
            // Media and physical-action flags fail closed when a value is
            // present but malformed. A typo such as "flase" must never turn
            // a privacy- or safety-sensitive capability on.
            streamsAudio: environment.booleanValue(
                for: "GEMINI_ROBOTICS_STREAM_AUDIO",
                default: true,
                invalid: false
            ),
            streamsVideo: environment.booleanValue(
                for: "GEMINI_ROBOTICS_STREAM_VIDEO",
                default: true,
                invalid: false
            ),
            exposesRobotActionTool: environment.booleanValue(
                for: "GEMINI_ROBOT_ACTION_TOOL_ENABLED",
                default: true,
                invalid: false
            ),
            enablesGoogleSearch: environment.booleanValue(
                for: "GEMINI_GOOGLE_SEARCH_ENABLED",
                default: true,
                invalid: false
            ),
            responseModality: responseModality
        )
    }

    func webSocketURL() throws -> URL {
        guard var components = URLComponents(string: credential.defaultEndpoint) else {
            throw GeminiRoboticsProtocolError.invalidEndpoint
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "key" || $0.name == "access_token" }
        queryItems.append(credential.queryItem)
        components.queryItems = queryItems

        guard let url = components.url,
              url.scheme == "wss",
              url.host == "generativelanguage.googleapis.com" else {
            throw GeminiRoboticsProtocolError.invalidEndpoint
        }
        return url
    }
}

/// Persisted operator intent for the current Cerebro process. Credentials,
/// model selection, response modality, and tool exposure remain immutable
/// launch configuration; only these token- and privacy-sensitive switches can
/// change while the app is running.
struct GeminiRoboticsRuntimeSettings: Equatable {
    static let connectionEnabledDefaultsKey = "com.orbitusrobotics.cerebro.gemini.connection-enabled"
    static let audioStreamingDefaultsKey = "com.orbitusrobotics.cerebro.gemini.audio-streaming-enabled"
    static let videoStreamingDefaultsKey = "com.orbitusrobotics.cerebro.gemini.video-streaming-enabled"

    var connectionEnabled: Bool
    var streamsAudio: Bool
    var streamsVideo: Bool

    init(
        configuration: GeminiRoboticsConfiguration?,
        storedConnectionEnabled: Bool? = nil,
        storedAudioStreamingEnabled: Bool? = nil,
        storedVideoStreamingEnabled: Bool? = nil
    ) {
        guard let configuration else {
            connectionEnabled = false
            streamsAudio = false
            streamsVideo = false
            return
        }

        // Preserve existing deployments on first launch of this version, then
        // let explicit UI choices take precedence on later launches.
        connectionEnabled = storedConnectionEnabled ?? true
        streamsAudio = storedAudioStreamingEnabled ?? configuration.streamsAudio
        streamsVideo = storedVideoStreamingEnabled ?? configuration.streamsVideo
    }

    init(configuration: GeminiRoboticsConfiguration?, defaults: UserDefaults) {
        self.init(
            configuration: configuration,
            storedConnectionEnabled: Self.storedBool(
                forKey: Self.connectionEnabledDefaultsKey,
                defaults: defaults
            ),
            storedAudioStreamingEnabled: Self.storedBool(
                forKey: Self.audioStreamingDefaultsKey,
                defaults: defaults
            ),
            storedVideoStreamingEnabled: Self.storedBool(
                forKey: Self.videoStreamingDefaultsKey,
                defaults: defaults
            )
        )
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(connectionEnabled, forKey: Self.connectionEnabledDefaultsKey)
        defaults.set(streamsAudio, forKey: Self.audioStreamingDefaultsKey)
        defaults.set(streamsVideo, forKey: Self.videoStreamingDefaultsKey)
    }

    private static func storedBool(forKey key: String, defaults: UserDefaults) -> Bool? {
        (defaults.object(forKey: key) as? NSNumber)?.boolValue
    }
}

enum GeminiRoboticsPrompt {
    static func spokenText(_ text: String, speechWordiness: Int) -> String {
        switch speechWordiness {
        case 0:
            return "Answer in one concise spoken sentence: \(text)"
        case 1:
            return "Answer in at most two concise spoken sentences: \(text)"
        default:
            return text
        }
    }
}

struct GeminiRoboticsToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

enum GeminiRoboticsToolPolicy {
    static func isStageContextID(_ contextID: String?) -> Bool {
        contextID?.hasPrefix("stage:") == true
    }

    /// A stop request is a safety signal, not ordinary queued work. It may be
    /// dispatched while another blocking tool call is awaiting an operator or
    /// executor result. The receiver still returns a normal correlated tool
    /// response, but it must apply the local software stop first.
    static func requiresPriorityDispatch(_ call: GeminiRoboticsToolCall) -> Bool {
        guard call.name == "robot_action",
              let action = call.arguments["action"] as? String else {
            return false
        }
        return action == "stop_motion"
    }
}

struct GeminiRoboticsServerEvent {
    var setupComplete = false
    var textFragments: [String] = []
    var inputTranscription: String?
    var outputTranscription: String?
    var generationComplete = false
    var turnComplete = false
    var interrupted = false
    var toolCalls: [GeminiRoboticsToolCall] = []
    var cancelledToolCallIDs: [String] = []
    var resumptionHandle: String?
    var isResumable: Bool?
    var shouldReconnect = false
    var serverError: String?
}

enum GeminiRoboticsDiagnosticsInputMode: String, Equatable {
    case disabled
    case localText
    case rawAudio

    var displayName: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .localText:
            return "Local speech recognition -> text"
        case .rawAudio:
            return "Raw microphone audio"
        }
    }
}

struct GeminiRoboticsDiagnosticsSnapshot: Equatable {
    let isConfigured: Bool
    let isConnectionEnabled: Bool
    let model: String?
    let streamsAudio: Bool
    let streamsVideo: Bool
    let isAudioStreamingApplied: Bool
    let isVideoStreamingApplied: Bool
    let exposesRobotActionTool: Bool
    let enablesGoogleSearch: Bool
    let responseModality: String?
    let connectionState: String
    let inputMode: GeminiRoboticsDiagnosticsInputMode
    let videoFramesEncoded: UInt64
    let videoFramesSent: UInt64
    let lastVideoSendDate: Date?
    let lastServerEvent: String?
    let lastServerEventDate: Date?
    let lastRequestFailureCategory: String?
    let lastRequestFailureDate: Date?
    let serverInputTranscriptionEventCount: UInt64
    let lastServerInputTranscriptionCharacterCount: Int?
    let lastServerInputTranscriptionDate: Date?
    let rawTurnTimeoutCount: UInt64
    let lastRawTurnTimeoutKind: String?
    let lastRawTurnTimeoutDate: Date?
    let localFallbackCount: UInt64
    let lastLocalFallbackProvider: String?
    let lastLocalFallbackDate: Date?
}

/// Thread-safe, redacted runtime telemetry for the diagnostics UI. This store
/// intentionally never retains credentials, media, transcripts, tool
/// arguments, raw server JSON, or session-resumption handles.
final class GeminiRoboticsDiagnosticsStore {
    private let lock = NSLock()
    private let isConfigured: Bool
    private let model: String?
    private var isConnectionEnabled: Bool
    private var streamsAudio: Bool
    private var streamsVideo: Bool
    private var isAudioStreamingApplied = false
    private var isVideoStreamingApplied = false
    private let exposesRobotActionTool: Bool
    private let enablesGoogleSearch: Bool
    private let responseModality: String?
    private var connectionState: String
    private var videoFramesEncoded: UInt64 = 0
    private var videoFramesSent: UInt64 = 0
    private var lastVideoSendDate: Date?
    private var lastServerEvent: String?
    private var lastServerEventDate: Date?
    private var lastRequestFailureCategory: String?
    private var lastRequestFailureDate: Date?
    private var serverInputTranscriptionEventCount: UInt64 = 0
    private var lastServerInputTranscriptionCharacterCount: Int?
    private var lastServerInputTranscriptionDate: Date?
    private var rawTurnTimeoutCount: UInt64 = 0
    private var lastRawTurnTimeoutKind: String?
    private var lastRawTurnTimeoutDate: Date?
    private var localFallbackCount: UInt64 = 0
    private var lastLocalFallbackProvider: String?
    private var lastLocalFallbackDate: Date?

    init(
        configuration: GeminiRoboticsConfiguration?,
        runtimeSettings: GeminiRoboticsRuntimeSettings? = nil
    ) {
        let effectiveSettings = runtimeSettings ?? GeminiRoboticsRuntimeSettings(
            configuration: configuration
        )
        isConfigured = configuration != nil
        model = configuration?.model
        isConnectionEnabled = effectiveSettings.connectionEnabled
        streamsAudio = effectiveSettings.streamsAudio
        streamsVideo = effectiveSettings.streamsVideo
        exposesRobotActionTool = configuration?.exposesRobotActionTool ?? false
        enablesGoogleSearch = configuration?.enablesGoogleSearch ?? false
        responseModality = configuration?.responseModality
        if configuration == nil {
            connectionState = "unavailable"
        } else {
            connectionState = effectiveSettings.connectionEnabled ? "not started" : "off"
        }
    }

    func noteRuntimeSettings(_ settings: GeminiRoboticsRuntimeSettings) {
        lock.lock()
        isConnectionEnabled = settings.connectionEnabled
        streamsAudio = settings.streamsAudio
        streamsVideo = settings.streamsVideo
        lock.unlock()
    }

    /// Records policy that the Live-session actor has actually applied. Keep
    /// this separate from requested settings so diagnostics and microphone
    /// routing never claim a rapid toggle took effect before the transition
    /// (including `audioStreamEnd`) completed.
    func noteRuntimeSettingsApplied(_ settings: GeminiRoboticsRuntimeSettings) {
        lock.lock()
        isAudioStreamingApplied = settings.connectionEnabled && settings.streamsAudio
        isVideoStreamingApplied = settings.connectionEnabled && settings.streamsVideo
        lock.unlock()
    }

    func noteConnectionState(_ state: String) {
        lock.lock()
        connectionState = state
        lock.unlock()
    }

    func noteVideoFrameEncoded() {
        lock.lock()
        if videoFramesEncoded < UInt64.max {
            videoFramesEncoded += 1
        }
        lock.unlock()
    }

    func noteVideoFrameSent(at date: Date = Date()) {
        lock.lock()
        if videoFramesSent < UInt64.max {
            videoFramesSent += 1
        }
        lastVideoSendDate = date
        lock.unlock()
    }

    func noteServerEvent(_ event: GeminiRoboticsServerEvent, at date: Date = Date()) {
        let summary = GeminiRoboticsProtocol.diagnosticsSummary(for: event)
        lock.lock()
        lastServerEvent = summary
        lastServerEventDate = date
        lock.unlock()
    }

    func noteRequestFailure(_ detail: String, at date: Date = Date()) {
        let normalized = detail.lowercased()
        let category: String
        if normalized.contains("queue is full") {
            category = "queue_full"
        } else if normalized.contains("without a usable spoken response") {
            category = "empty_response"
        } else if normalized.contains("microphone") && normalized.contains("within 6 seconds") {
            category = "raw_response_start_timeout"
        } else if normalized.contains("microphone") && normalized.contains("did not finish") {
            category = "raw_completion_timeout"
        } else if normalized.contains("within 15 seconds") {
            category = "text_response_start_timeout"
        } else if normalized.contains("did not finish") {
            category = "text_completion_timeout"
        } else if normalized.contains("turned off") || normalized.contains("disabled") {
            category = "disabled"
        } else if normalized.contains("credential") || normalized.contains("configuration") {
            category = "configuration"
        } else if normalized.contains("resume") {
            category = "resumption_failed"
        } else if normalized.contains("reconnect") {
            category = "server_reconnect"
        } else if normalized.contains("send") {
            category = "send_failed"
        } else if normalized.contains("connection") || normalized.contains("session") {
            category = "connection_ended"
        } else {
            category = "other"
        }
        lock.lock()
        lastRequestFailureCategory = category
        lastRequestFailureDate = date
        lock.unlock()
    }

    func noteServerInputTranscription(
        characterCount: Int,
        at date: Date = Date()
    ) {
        lock.lock()
        if serverInputTranscriptionEventCount < UInt64.max {
            serverInputTranscriptionEventCount += 1
        }
        lastServerInputTranscriptionCharacterCount = max(0, characterCount)
        lastServerInputTranscriptionDate = date
        lock.unlock()
    }

    func noteRawTurnTimeout(kind: String, at date: Date = Date()) {
        lock.lock()
        if rawTurnTimeoutCount < UInt64.max {
            rawTurnTimeoutCount += 1
        }
        lastRawTurnTimeoutKind = String(kind.prefix(40))
        lastRawTurnTimeoutDate = date
        lock.unlock()
    }

    func noteLocalFallback(provider: String, at date: Date = Date()) {
        lock.lock()
        if localFallbackCount < UInt64.max {
            localFallbackCount += 1
        }
        lastLocalFallbackProvider = String(provider.prefix(80))
        lastLocalFallbackDate = date
        lock.unlock()
    }

    func snapshot() -> GeminiRoboticsDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let inputMode: GeminiRoboticsDiagnosticsInputMode
        if !isConfigured || !isConnectionEnabled {
            inputMode = .disabled
        } else if isAudioStreamingApplied && connectionState == "ready" {
            inputMode = .rawAudio
        } else {
            inputMode = .localText
        }

        return GeminiRoboticsDiagnosticsSnapshot(
            isConfigured: isConfigured,
            isConnectionEnabled: isConnectionEnabled,
            model: model,
            streamsAudio: streamsAudio,
            streamsVideo: streamsVideo,
            isAudioStreamingApplied: isAudioStreamingApplied,
            isVideoStreamingApplied: isVideoStreamingApplied,
            exposesRobotActionTool: exposesRobotActionTool,
            enablesGoogleSearch: enablesGoogleSearch,
            responseModality: responseModality,
            connectionState: connectionState,
            inputMode: inputMode,
            videoFramesEncoded: videoFramesEncoded,
            videoFramesSent: videoFramesSent,
            lastVideoSendDate: lastVideoSendDate,
            lastServerEvent: lastServerEvent,
            lastServerEventDate: lastServerEventDate,
            lastRequestFailureCategory: lastRequestFailureCategory,
            lastRequestFailureDate: lastRequestFailureDate,
            serverInputTranscriptionEventCount: serverInputTranscriptionEventCount,
            lastServerInputTranscriptionCharacterCount: lastServerInputTranscriptionCharacterCount,
            lastServerInputTranscriptionDate: lastServerInputTranscriptionDate,
            rawTurnTimeoutCount: rawTurnTimeoutCount,
            lastRawTurnTimeoutKind: lastRawTurnTimeoutKind,
            lastRawTurnTimeoutDate: lastRawTurnTimeoutDate,
            localFallbackCount: localFallbackCount,
            lastLocalFallbackProvider: lastLocalFallbackProvider,
            lastLocalFallbackDate: lastLocalFallbackDate
        )
    }
}

struct GeminiTurnDeadlineTracker {
    enum Expiration: Equatable {
        case responseNotStarted(turnID: UInt64)
        case turnNotCompleted(turnID: UInt64)
    }

    let responseStartTimeout: TimeInterval
    let turnCompletionTimeout: TimeInterval

    private(set) var activeTurnID: UInt64?
    private var startedAt: TimeInterval?
    private var responseStarted = false

    init(responseStartTimeout: TimeInterval = 15, turnCompletionTimeout: TimeInterval = 120) {
        self.responseStartTimeout = responseStartTimeout
        self.turnCompletionTimeout = turnCompletionTimeout
    }

    mutating func begin(turnID: UInt64, now: TimeInterval) {
        activeTurnID = turnID
        startedAt = now
        responseStarted = false
    }

    mutating func noteResponse(turnID: UInt64) {
        guard activeTurnID == turnID else { return }
        responseStarted = true
    }

    mutating func complete(turnID: UInt64) {
        guard activeTurnID == turnID else { return }
        activeTurnID = nil
        startedAt = nil
        responseStarted = false
    }

    func expiration(turnID: UInt64, now: TimeInterval) -> Expiration? {
        guard activeTurnID == turnID, let startedAt else { return nil }
        let elapsed = now - startedAt
        if elapsed >= turnCompletionTimeout {
            return .turnNotCompleted(turnID: turnID)
        }
        if !responseStarted, elapsed >= responseStartTimeout {
            return .responseNotStarted(turnID: turnID)
        }
        return nil
    }
}

/// Small provider-health circuit used by ROBAI admission. It never changes the
/// operator's saved Gemini setting; it only diverts new conversational turns to
/// the private local fallback during a short burst of provider failures.
struct GeminiFailureCircuitBreaker {
    let failureThreshold: Int
    let failureWindow: TimeInterval
    let cooldown: TimeInterval

    private var recentFailures: [TimeInterval] = []
    private(set) var openUntil: TimeInterval?

    init(
        failureThreshold: Int = 2,
        failureWindow: TimeInterval = 60,
        cooldown: TimeInterval = 90
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.failureWindow = max(1, failureWindow)
        self.cooldown = max(1, cooldown)
    }

    mutating func isOpen(now: TimeInterval) -> Bool {
        if let openUntil, now >= openUntil {
            self.openUntil = nil
            recentFailures.removeAll()
        }
        return openUntil.map { now < $0 } ?? false
    }

    @discardableResult
    mutating func recordFailure(now: TimeInterval) -> Bool {
        if isOpen(now: now) { return true }
        recentFailures.removeAll { now - $0 > failureWindow }
        recentFailures.append(now)
        guard recentFailures.count >= failureThreshold else { return false }
        openUntil = now + cooldown
        recentFailures.removeAll()
        return true
    }

    mutating func recordSuccess() {
        recentFailures.removeAll()
        openUntil = nil
    }

    mutating func remainingCooldown(now: TimeInterval) -> TimeInterval? {
        guard isOpen(now: now), let openUntil else { return nil }
        return max(0, openUntil - now)
    }
}

struct GeminiTranscriptionAccumulator {
    private(set) var text = ""

    mutating func append(_ fragment: String) {
        text += fragment
    }

    mutating func reset() {
        text = ""
    }
}

struct GeminiMicrophoneTurnAssociation {
    enum TranscriptDisposition: Equatable {
        case beginAwaitingResponse
        case associateWithActiveResponse
        case beginOrRefreshInterruptedFollowup
    }

    private(set) var modelResponseIsActive = false
    private(set) var transcriptNoticePendingAfterInterruption = false
    private(set) var awaitingInterruptedTurnCompletion = false

    mutating func noteModelResponseStarted() {
        modelResponseIsActive = true
    }

    mutating func noteLocalTranscript(hasTrackedTurn: Bool = false) -> TranscriptDisposition {
        if awaitingInterruptedTurnCompletion {
            return .beginOrRefreshInterruptedFollowup
        }
        guard modelResponseIsActive else {
            if hasTrackedTurn {
                transcriptNoticePendingAfterInterruption = true
            }
            return .beginAwaitingResponse
        }
        // The callback may belong to the current input or to barge-in audio
        // that Gemini is about to report as an interruption. Associate it with
        // the current response now, but retain enough state to arm the next
        // turn if the interruption event follows.
        transcriptNoticePendingAfterInterruption = true
        return .associateWithActiveResponse
    }

    mutating func noteInterruption() -> Bool {
        let shouldArmFollowup = transcriptNoticePendingAfterInterruption
        modelResponseIsActive = false
        transcriptNoticePendingAfterInterruption = false
        awaitingInterruptedTurnCompletion = true
        return shouldArmFollowup
    }

    mutating func consumeInterruptedTurnCompletion() -> Bool {
        guard awaitingInterruptedTurnCompletion else { return false }
        awaitingInterruptedTurnCompletion = false
        modelResponseIsActive = false
        transcriptNoticePendingAfterInterruption = false
        return true
    }

    mutating func reset() {
        modelResponseIsActive = false
        transcriptNoticePendingAfterInterruption = false
        awaitingInterruptedTurnCompletion = false
    }
}

enum GeminiRoboticsProtocolError: LocalizedError {
    case invalidEndpoint
    case invalidJSONObject
    case invalidServerMessage

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Gemini Robotics WebSocket endpoint is invalid."
        case .invalidJSONObject:
            return "A Gemini Robotics message could not be encoded as JSON."
        case .invalidServerMessage:
            return "The Gemini Robotics server returned an invalid JSON envelope."
        }
    }
}

enum GeminiRoboticsProtocol {
    static func diagnosticsSummary(for event: GeminiRoboticsServerEvent) -> String {
        var categories: [String] = []
        if event.setupComplete {
            categories.append("setup complete")
        }
        if !event.textFragments.isEmpty {
            categories.append("model output (\(event.textFragments.count) part\(event.textFragments.count == 1 ? "" : "s"))")
        }
        if event.inputTranscription != nil {
            categories.append("input transcription")
        }
        if event.outputTranscription != nil {
            categories.append("output transcription")
        }
        if event.generationComplete {
            categories.append("generation complete")
        }
        if event.turnComplete {
            categories.append("turn complete")
        }
        if event.interrupted {
            categories.append("interrupted")
        }
        if !event.toolCalls.isEmpty {
            categories.append("tool calls (\(event.toolCalls.count))")
        }
        if !event.cancelledToolCallIDs.isEmpty {
            categories.append("tool cancellations (\(event.cancelledToolCallIDs.count))")
        }
        if event.isResumable != nil {
            categories.append("session resumption update")
        }
        if event.shouldReconnect {
            categories.append("go away")
        }
        if event.serverError != nil {
            categories.append("server error")
        }
        return categories.isEmpty ? "message received" : categories.joined(separator: ", ")
    }

    static func setupMessage(configuration: GeminiRoboticsConfiguration, resumptionHandle: String?) -> [String: Any] {
        var setup: [String: Any] = [
            "model": configuration.model,
            "generationConfig": [
                "responseModalities": [configuration.responseModality]
            ],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
            "systemInstruction": [
                "parts": [["text": configuration.systemInstruction]]
            ],
            "sessionResumption": resumptionHandle.map { ["handle": $0] } ?? [:],
            "contextWindowCompression": [
                "slidingWindow": [:]
            ]
        ]

        var tools: [[String: Any]] = []
        if configuration.enablesGoogleSearch {
            // Google Search is a server-side Live tool. Gemini performs the
            // search itself; Cerebro never receives arbitrary URLs to open.
            tools.append(["googleSearch": [:]])
        }
        if configuration.exposesRobotActionTool {
            tools.append([
                "functionDeclarations": [robotActionToolDeclaration]
            ])
        }
        if !tools.isEmpty {
            setup["tools"] = tools
        }

        return ["setup": setup]
    }

    static func realtimeAudioMessage(_ pcm16Data: Data) -> [String: Any] {
        [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": pcm16Data.base64EncodedString()
                ]
            ]
        ]
    }

    static func audioStreamEndMessage() -> [String: Any] {
        ["realtimeInput": ["audioStreamEnd": true]]
    }

    static func realtimeVideoMessage(_ jpegData: Data) -> [String: Any] {
        [
            "realtimeInput": [
                "video": [
                    "mimeType": "image/jpeg",
                    "data": jpegData.base64EncodedString()
                ]
            ]
        ]
    }

    static func realtimeTextMessage(_ text: String) -> [String: Any] {
        [
            "realtimeInput": ["text": text]
        ]
    }

    static func toolResponseMessage(callID: String, name: String, result: [String: Any]) -> [String: Any] {
        [
            "toolResponse": [
                "functionResponses": [[
                    "id": callID,
                    "name": name,
                    "response": ["result": result]
                ]]
            ]
        ]
    }

    static func jsonString(from object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw GeminiRoboticsProtocolError.invalidJSONObject
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw GeminiRoboticsProtocolError.invalidJSONObject
        }
        return string
    }

    static func parseServerMessage(_ data: Data) throws -> GeminiRoboticsServerEvent {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let envelope = object as? [String: Any] else {
            throw GeminiRoboticsProtocolError.invalidServerMessage
        }

        var event = GeminiRoboticsServerEvent()
        event.setupComplete = envelope["setupComplete"] != nil

        if let serverContent = envelope["serverContent"] as? [String: Any] {
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                event.textFragments = parts.compactMap { $0["text"] as? String }
            }
            if let transcription = serverContent["inputTranscription"] as? [String: Any] {
                event.inputTranscription = transcription["text"] as? String
            }
            if let transcription = serverContent["outputTranscription"] as? [String: Any] {
                event.outputTranscription = transcription["text"] as? String
            }
            event.generationComplete = serverContent["generationComplete"] as? Bool ?? false
            event.turnComplete = serverContent["turnComplete"] as? Bool ?? false
            event.interrupted = serverContent["interrupted"] as? Bool ?? false
        }

        if let toolCall = envelope["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            event.toolCalls = functionCalls.compactMap { call in
                guard let id = call["id"] as? String,
                      let name = call["name"] as? String else {
                    return nil
                }
                return GeminiRoboticsToolCall(
                    id: id,
                    name: name,
                    arguments: call["args"] as? [String: Any] ?? [:]
                )
            }
        }

        if let cancellation = envelope["toolCallCancellation"] as? [String: Any] {
            event.cancelledToolCallIDs = cancellation["ids"] as? [String] ?? []
        }

        if let resumption = envelope["sessionResumptionUpdate"] as? [String: Any] {
            event.isResumable = resumption["resumable"] as? Bool
            if event.isResumable == true {
                event.resumptionHandle = resumption["newHandle"] as? String
            }
        }

        event.shouldReconnect = envelope["goAway"] != nil

        if let error = envelope["error"] as? [String: Any] {
            event.serverError = error["message"] as? String ?? "Gemini Robotics server error"
        }

        return event
    }

    private static let robotActionToolDeclaration: [String: Any] = [
        "name": "robot_action",
        "description": "Propose a high-level robot action. ROBController normally approves it; an explicit short-lived Cerebro Arm Debug Authority may execute an immutable locally approved named gesture. Cerebro's measured safety/motion layer reports the physical outcome. Approval is not completion.",
        "behavior": "BLOCKING",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "action": [
                    "type": "STRING",
                    "enum": ["look_at", "play_gesture", "request_pick", "navigate_relative", "stop_motion"]
                ],
                "target_id": [
                    "type": "STRING",
                    "description": "Stable ID of a target from the current perception snapshot. Required by look_at and request_pick."
                ],
                "gesture": [
                    "type": "STRING",
                    "description": "Immutable locally approved gesture name. Required by play_gesture. Never provide joint values. If a name is rejected, the result may list the available names."
                ],
                "distance_m": [
                    "type": "NUMBER",
                    "description": "Signed relative travel in metres, limited to one metre per approved request.",
                    "minimum": -1.0,
                    "maximum": 1.0
                ],
                "yaw_rad": [
                    "type": "NUMBER",
                    "description": "Signed relative yaw in radians.",
                    "minimum": -Double.pi,
                    "maximum": Double.pi
                ],
                "speed_scale": [
                    "type": "NUMBER",
                    "description": "Local motion speed fraction. Cerebro may reduce it further.",
                    "minimum": 0.0,
                    "maximum": 0.35
                ]
            ],
            "required": ["action"]
        ]
    ]
}

private extension Dictionary where Key == String, Value == String {
    func nonemptyValue(for key: String) -> String? {
        guard let value = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    func booleanValue(
        for key: String,
        default defaultValue: Bool,
        invalid invalidValue: Bool? = nil
    ) -> Bool {
        guard let rawValue = nonemptyValue(for: key)?.lowercased() else {
            return defaultValue
        }
        switch rawValue {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return invalidValue ?? defaultValue
        }
    }
}
