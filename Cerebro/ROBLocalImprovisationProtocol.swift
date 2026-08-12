//
//  ROBLocalImprovisationProtocol.swift
//  Cerebro
//
//  A model-neutral, dialogue-only contract for a local stage director. The
//  local model can shape an improvisation, but it cannot describe hardware,
//  invoke tools, or emit executable robot commands.
//

import Foundation

public enum ROBLocalImprovisationProviderKind: String, CaseIterable {
    case llamaCpp = "llama_cpp"
    case mlxSwift = "mlx_swift"

    public var displayName: String {
        switch self {
        case .llamaCpp: return "llama.cpp server"
        case .mlxSwift: return "MLX Swift (private/offline)"
        }
    }
}

public enum ROBLocalImprovisationBeatKind: String, Codable, CaseIterable {
    case audienceObservation = "audience_observation"
    case robotJoke = "robot_joke"
    case dramaticReveal = "dramatic_reveal"
    case callAndResponse = "call_and_response"
    case sceneTransition = "scene_transition"
}

public enum ROBLocalImprovisationDelivery: String, Codable, CaseIterable {
    case warm
    case playful
    case dramatic
    case deadpan
    case curious
}

public struct ROBLocalImprovisationRequest: Equatable {
    public let showTitle: String
    public let cueID: String
    public let sceneGoal: String
    public let authoredFallback: String

    public init(showTitle: String, cueID: String, sceneGoal: String, authoredFallback: String) {
        self.showTitle = showTitle
        self.cueID = cueID
        self.sceneGoal = sceneGoal
        self.authoredFallback = authoredFallback
    }
}

public struct ROBLocalImprovisationPlan: Codable, Equatable {
    public static let schemaIdentifier = "com.orbitusrobotics.local-improvisation-plan"
    public static let currentVersion = 1

    public let schema: String
    public let version: Int
    public let beat: ROBLocalImprovisationBeatKind
    public let delivery: ROBLocalImprovisationDelivery
    public let offlineLine: String

    enum CodingKeys: String, CodingKey {
        case schema
        case version
        case beat
        case delivery
        case offlineLine = "offline_line"
    }

    public init(
        beat: ROBLocalImprovisationBeatKind,
        delivery: ROBLocalImprovisationDelivery,
        offlineLine: String
    ) {
        schema = Self.schemaIdentifier
        version = Self.currentVersion
        self.beat = beat
        self.delivery = delivery
        self.offlineLine = offlineLine
    }
}

public enum ROBLocalImprovisationPlanCodec {
    public static let maximumDocumentBytes = 16_384
    public static let maximumOfflineLineCharacters = 360

    private static let allowedKeys: Set<String> = [
        "schema", "version", "beat", "delivery", "offline_line"
    ]

    // Generated dialogue is never executable, and stage-originated tool calls
    // are independently rejected. This guard keeps obvious control language
    // out of the only free-form generated field, which is spoken locally.
    private static let prohibitedFragments = [
        "ssh", "sudo", "shell", "/usr/", "/bin/", "servo", "joint", "pwm",
        "robot_action", "navigate_relative", "request_pick", "play_gesture",
        "stop_motion", "tool call", "http://", "https://", "localhost"
    ]

    public static func decode(_ data: Data) throws -> ROBLocalImprovisationPlan {
        guard !data.isEmpty else {
            throw ROBLocalImprovisationError.invalidPlan("The local model returned an empty plan.")
        }
        guard data.count <= maximumDocumentBytes else {
            throw ROBLocalImprovisationError.responseTooLarge
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ROBLocalImprovisationError.invalidPlan("The local model did not return valid JSON.")
        }
        guard let dictionary = object as? [String: Any] else {
            throw ROBLocalImprovisationError.invalidPlan("The local model plan must be a JSON object.")
        }
        let unknownKeys = Set(dictionary.keys).subtracting(allowedKeys).sorted()
        guard unknownKeys.isEmpty else {
            throw ROBLocalImprovisationError.invalidPlan(
                "Unknown plan field(s): \(unknownKeys.joined(separator: ", "))."
            )
        }

        let plan: ROBLocalImprovisationPlan
        do {
            plan = try JSONDecoder().decode(ROBLocalImprovisationPlan.self, from: data)
        } catch {
            throw ROBLocalImprovisationError.invalidPlan("The local plan does not match schema v1.")
        }
        try validate(plan)
        return plan
    }

    public static func encode(_ plan: ROBLocalImprovisationPlan) throws -> Data {
        try validate(plan)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(plan)
    }

    public static func validate(_ plan: ROBLocalImprovisationPlan) throws {
        guard plan.schema == ROBLocalImprovisationPlan.schemaIdentifier else {
            throw ROBLocalImprovisationError.invalidPlan("Unsupported local-plan schema.")
        }
        guard plan.version == ROBLocalImprovisationPlan.currentVersion else {
            throw ROBLocalImprovisationError.invalidPlan("Unsupported local-plan version.")
        }
        try validateGeneratedText(
            plan.offlineLine,
            field: "offline_line",
            maximum: maximumOfflineLineCharacters
        )
    }

    /// The shallow schema intentionally uses only the JSON-Schema subset that
    /// grammar-backed local runtimes reliably support.
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "schema": [
                    "type": "string",
                    "enum": [ROBLocalImprovisationPlan.schemaIdentifier]
                ],
                "version": [
                    "type": "integer",
                    "enum": [ROBLocalImprovisationPlan.currentVersion]
                ],
                "beat": [
                    "type": "string",
                    "enum": ROBLocalImprovisationBeatKind.allCases.map(\.rawValue)
                ],
                "delivery": [
                    "type": "string",
                    "enum": ROBLocalImprovisationDelivery.allCases.map(\.rawValue)
                ],
                "offline_line": [
                    "type": "string",
                    "minLength": 1,
                    "maxLength": maximumOfflineLineCharacters
                ]
            ],
            "required": [
                "schema", "version", "beat", "delivery", "offline_line"
            ],
            "additionalProperties": false
        ]
    }

    public static func geminiHandoffPrompt(
        plan: ROBLocalImprovisationPlan,
        originalSceneGoal: String
    ) -> String {
        """
        STAGE DIALOGUE ONLY. Do not call tools or request physical actions for this turn.
        Use the current Live camera/audio context, when available, to perform one or two concise spoken sentences as ROB.
        Original scene goal: \(originalSceneGoal)
        Selected beat: \(plan.beat.rawValue)
        Delivery: \(plan.delivery.rawValue)
        """
    }

    private static func validateGeneratedText(_ value: String, field: String, maximum: Int) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !value.isEmpty, value.count <= maximum else {
            throw ROBLocalImprovisationError.invalidPlan(
                "\(field) must contain 1 through \(maximum) trimmed characters."
            )
        }
        guard value.rangeOfCharacter(from: .newlines) == nil,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ROBLocalImprovisationError.invalidPlan("\(field) must be a single safe text line.")
        }

        let normalized = value.lowercased()
        if let fragment = prohibitedFragments.first(where: { normalized.contains($0) }) {
            throw ROBLocalImprovisationError.invalidPlan(
                "\(field) contains prohibited control language ('\(fragment)')."
            )
        }
    }
}

public struct ROBLocalImprovisationConfiguration: Equatable {
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8080")!
    public static let defaultModel = "cerebro-local"
    public static let defaultTimeout: TimeInterval = 3
    public static let defaultTemperature = 0.6

    public let isEnabled: Bool
    public let providerKind: ROBLocalImprovisationProviderKind
    public let endpointURL: URL
    public let model: String
    public let timeout: TimeInterval
    public let temperature: Double

    public init(
        isEnabled: Bool,
        providerKind: ROBLocalImprovisationProviderKind,
        endpointURL: URL,
        model: String,
        timeout: TimeInterval = defaultTimeout,
        temperature: Double = defaultTemperature
    ) throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, trimmedModel.count <= 200 else {
            throw ROBLocalImprovisationError.invalidConfiguration(
                "The local model or alias must contain 1 through 200 characters."
            )
        }
        guard timeout.isFinite, (0.5 ... 15).contains(timeout) else {
            throw ROBLocalImprovisationError.invalidConfiguration(
                "The local inference timeout must be between 0.5 and 15 seconds."
            )
        }
        guard temperature.isFinite, (0 ... 1.5).contains(temperature) else {
            throw ROBLocalImprovisationError.invalidConfiguration(
                "The local model temperature must be between 0 and 1.5."
            )
        }
        try Self.validateLoopbackEndpoint(endpointURL)

        self.isEnabled = isEnabled
        self.providerKind = providerKind
        self.endpointURL = endpointURL
        self.model = trimmedModel
        self.timeout = timeout
        self.temperature = temperature
    }

    public static func validateLoopbackEndpoint(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              ["127.0.0.1", "::1", "[::1]"].contains(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ROBLocalImprovisationError.invalidConfiguration(
                "The local endpoint must use literal 127.0.0.1 or ::1 without credentials, query, or fragment."
            )
        }
        if let port = components.port, !(1 ... 65_535).contains(port) {
            throw ROBLocalImprovisationError.invalidConfiguration("The local endpoint port is invalid.")
        }
        let path = components.percentEncodedPath
        let supportedPaths = ["", "/", "/v1", "/v1/", "/v1/chat/completions"]
        guard supportedPaths.contains(path) else {
            throw ROBLocalImprovisationError.invalidConfiguration(
                "Use the server root, /v1, or /v1/chat/completions as the local endpoint."
            )
        }
    }
}

public enum ROBLocalImprovisationSettings {
    public static let didChangeNotification = Notification.Name("ROBLocalImprovisationSettingsDidChange")

    private static let enabledKey = "ROBLocalImprovisation.enabled"
    private static let providerKey = "ROBLocalImprovisation.provider"
    private static let endpointKey = "ROBLocalImprovisation.endpoint"
    private static let modelKey = "ROBLocalImprovisation.model"
    private static let timeoutKey = "ROBLocalImprovisation.timeout"
    private static let temperatureKey = "ROBLocalImprovisation.temperature"

    public static func load(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ROBLocalImprovisationConfiguration {
        let enabled = environmentBoolean(environment["ROB_LOCAL_IMPROV_ENABLED"])
            ?? defaults.bool(forKey: enabledKey)
        let providerRaw = nonempty(environment["ROB_LOCAL_IMPROV_PROVIDER"])
            ?? defaults.string(forKey: providerKey)
            ?? ROBLocalImprovisationProviderKind.llamaCpp.rawValue
        guard let provider = ROBLocalImprovisationProviderKind(rawValue: providerRaw) else {
            throw ROBLocalImprovisationError.invalidConfiguration(
                "Unknown local improvisation provider '\(providerRaw)'."
            )
        }

        let endpointText = nonempty(environment["ROB_LLAMA_CPP_ENDPOINT"])
            ?? defaults.string(forKey: endpointKey)
            ?? ROBLocalImprovisationConfiguration.defaultEndpoint.absoluteString
        guard let endpoint = URL(string: endpointText) else {
            throw ROBLocalImprovisationError.invalidConfiguration("The local endpoint is not a valid URL.")
        }
        let model = nonempty(environment["ROB_LOCAL_IMPROV_MODEL"])
            ?? defaults.string(forKey: modelKey)
            ?? ROBLocalImprovisationConfiguration.defaultModel
        let timeout = environmentDouble(environment["ROB_LOCAL_IMPROV_TIMEOUT_SECONDS"])
            ?? storedDouble(defaults, key: timeoutKey)
            ?? ROBLocalImprovisationConfiguration.defaultTimeout
        let temperature = environmentDouble(environment["ROB_LOCAL_IMPROV_TEMPERATURE"])
            ?? storedDouble(defaults, key: temperatureKey)
            ?? ROBLocalImprovisationConfiguration.defaultTemperature

        return try ROBLocalImprovisationConfiguration(
            isEnabled: enabled,
            providerKind: provider,
            endpointURL: endpoint,
            model: model,
            timeout: timeout,
            temperature: temperature
        )
    }

    public static func save(
        _ configuration: ROBLocalImprovisationConfiguration,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(configuration.isEnabled, forKey: enabledKey)
        defaults.set(configuration.providerKind.rawValue, forKey: providerKey)
        defaults.set(configuration.endpointURL.absoluteString, forKey: endpointKey)
        defaults.set(configuration.model, forKey: modelKey)
        defaults.set(configuration.timeout, forKey: timeoutKey)
        defaults.set(configuration.temperature, forKey: temperatureKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func environmentBoolean(_ value: String?) -> Bool? {
        guard let value = nonempty(value)?.lowercased() else { return nil }
        if ["1", "true", "yes", "on"].contains(value) { return true }
        if ["0", "false", "no", "off"].contains(value) { return false }
        return nil
    }

    private static func environmentDouble(_ value: String?) -> Double? {
        guard let value = nonempty(value) else { return nil }
        return Double(value)
    }

    private static func storedDouble(_ defaults: UserDefaults, key: String) -> Double? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }
}

public struct ROBLocalImprovisationDiagnosticsSnapshot: Equatable {
    public let providerName: String
    public let state: String
    public let redactedEndpoint: String?
    public let model: String?
    public let requestCount: UInt64
    public let successCount: UInt64
    public let fallbackCount: UInt64
    public let lastLatency: TimeInterval?
    public let lastErrorCategory: String?
}

public protocol ROBLocalImprovisationProviding: AnyObject {
    var providerName: String { get }
    var maximumRequestSeconds: TimeInterval { get }

    func generatePlan(
        for request: ROBLocalImprovisationRequest,
        requestID: String,
        timeout: TimeInterval,
        completion: @escaping (Result<ROBLocalImprovisationPlan, Error>) -> Void
    )
    func cancel(requestID: String)
    func checkHealth(
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    )
    func noteFallback()
    func diagnosticsSnapshot() -> ROBLocalImprovisationDiagnosticsSnapshot
}

public enum ROBLocalImprovisationProviderRegistry {
    public typealias MLXFactory = (ROBLocalImprovisationConfiguration) throws -> ROBLocalImprovisationProviding

    private static let lock = NSLock()
    private static var mlxFactory: MLXFactory?

    /// A future target that links MLXLLM plus MLXGuidedGeneration can register
    /// its provider here without making Cerebro's core depend on MLX today.
    public static func registerMLXFactory(_ factory: @escaping MLXFactory) {
        lock.lock()
        mlxFactory = factory
        lock.unlock()
    }

    static func registeredMLXFactory() -> MLXFactory? {
        lock.lock()
        defer { lock.unlock() }
        return mlxFactory
    }
}

public enum ROBLocalImprovisationProviderFactory {
    public static func makeProvider(
        configuration: ROBLocalImprovisationConfiguration
    ) -> ROBLocalImprovisationProviding? {
        guard configuration.isEnabled else { return nil }
        switch configuration.providerKind {
        case .llamaCpp:
            return ROBLlamaCppImprovisationProvider(configuration: configuration)
        case .mlxSwift:
            return ROBMLXImprovisationProvider(configuration: configuration)
        }
    }
}

public enum ROBLocalImprovisationError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidPlan(String)
    case serverUnavailable(String)
    case serverLoading
    case invalidServerResponse
    case responseTooLarge
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return detail
        case .invalidPlan(let detail): return detail
        case .serverUnavailable(let detail): return detail
        case .serverLoading: return "The local model is still loading."
        case .invalidServerResponse: return "The local model returned an invalid response."
        case .responseTooLarge: return "The local model response exceeded the safety limit."
        case .timedOut: return "The local model exceeded its cue deadline."
        case .cancelled: return "The local model request was cancelled."
        }
    }

    public var category: String {
        switch self {
        case .invalidConfiguration: return "configuration"
        case .invalidPlan: return "invalid_plan"
        case .serverUnavailable: return "unavailable"
        case .serverLoading: return "loading"
        case .invalidServerResponse: return "invalid_response"
        case .responseTooLarge: return "response_too_large"
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        }
    }
}

private final class ROBUnavailableLocalImprovisationProvider: ROBLocalImprovisationProviding {
    let providerName: String
    let maximumRequestSeconds: TimeInterval = 1
    private let detail: String

    init(name: String, detail: String) {
        providerName = name
        self.detail = detail
    }

    func generatePlan(
        for request: ROBLocalImprovisationRequest,
        requestID: String,
        timeout: TimeInterval,
        completion: @escaping (Result<ROBLocalImprovisationPlan, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            completion(.failure(ROBLocalImprovisationError.serverUnavailable(self.detail)))
        }
    }

    func cancel(requestID: String) {}

    func checkHealth(timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async {
            completion(.failure(ROBLocalImprovisationError.serverUnavailable(self.detail)))
        }
    }

    func noteFallback() {}

    func diagnosticsSnapshot() -> ROBLocalImprovisationDiagnosticsSnapshot {
        ROBLocalImprovisationDiagnosticsSnapshot(
            providerName: providerName,
            state: "unavailable",
            redactedEndpoint: nil,
            model: nil,
            requestCount: 0,
            successCount: 0,
            fallbackCount: 0,
            lastLatency: nil,
            lastErrorCategory: "not_linked"
        )
    }
}
