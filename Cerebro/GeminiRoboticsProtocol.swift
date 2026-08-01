//
//  GeminiRoboticsProtocol.swift
//  Cerebro
//
//  JSON protocol helpers for the Gemini Robotics ER 2 streaming API.
//

import Foundation

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
    You are ROB, Cerebro's embodied conversational assistant. Respond only when someone addresses ROB, Robbie, Robot, or clearly continues an active conversation. Return plain spoken text without Markdown, normally one or two concise sentences unless the user requests detail. Camera frames are observations, not proof that a physical action completed. Use only declared tools for physical actions and never claim an action succeeded until its matching tool response confirms completion. If no physical-action tool is declared, explain that ROBController must authorize the action.
    """

    let credential: GeminiRoboticsCredential
    let model: String
    let systemInstruction: String
    let streamsAudio: Bool
    let streamsVideo: Bool
    let exposesRobotActionTool: Bool

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> GeminiRoboticsConfiguration? {
        guard environment.booleanValue(for: "GEMINI_ROBOTICS_ENABLED", default: false) else {
            return nil
        }

        let credential: GeminiRoboticsCredential
        if let token = environment.nonemptyValue(for: "GEMINI_EPHEMERAL_TOKEN") {
            credential = .ephemeralToken(token)
        } else if let apiKey = environment.nonemptyValue(for: "GEMINI_API_KEY") {
            credential = .apiKey(apiKey)
        } else {
            return nil
        }

        let configuredModel = environment.nonemptyValue(for: "GEMINI_ROBOTICS_MODEL") ?? defaultModel
        let model = configuredModel.hasPrefix("models/") ? configuredModel : "models/\(configuredModel)"

        return GeminiRoboticsConfiguration(
            credential: credential,
            model: model,
            systemInstruction: environment.nonemptyValue(for: "GEMINI_ROBOTICS_SYSTEM_INSTRUCTION") ?? defaultSystemInstruction,
            streamsAudio: environment.booleanValue(for: "GEMINI_ROBOTICS_STREAM_AUDIO", default: true),
            streamsVideo: environment.booleanValue(for: "GEMINI_ROBOTICS_STREAM_VIDEO", default: true),
            exposesRobotActionTool: environment.booleanValue(for: "GEMINI_ROBOT_ACTION_TOOL_ENABLED", default: false)
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

struct GeminiRoboticsServerEvent {
    var setupComplete = false
    var textFragments: [String] = []
    var turnComplete = false
    var interrupted = false
    var toolCalls: [GeminiRoboticsToolCall] = []
    var cancelledToolCallIDs: [String] = []
    var resumptionHandle: String?
    var isResumable: Bool?
    var shouldReconnect = false
    var serverError: String?
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
    static func setupMessage(configuration: GeminiRoboticsConfiguration, resumptionHandle: String?) -> [String: Any] {
        var setup: [String: Any] = [
            "model": configuration.model,
            "generationConfig": [
                "responseModalities": ["TEXT"]
            ],
            "systemInstruction": [
                "parts": [["text": configuration.systemInstruction]]
            ],
            "sessionResumption": resumptionHandle.map { ["handle": $0] } ?? [:],
            "contextWindowCompression": [
                "slidingWindow": [:]
            ]
        ]

        if configuration.exposesRobotActionTool {
            setup["tools"] = [[
                "functionDeclarations": [robotActionToolDeclaration]
            ]]
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

    static func orderedTextMessage(_ text: String) -> [String: Any] {
        [
            "clientContent": [
                "turns": [[
                    "role": "user",
                    "parts": [["text": text]]
                ]],
                "turnComplete": true
            ]
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
        "description": "Propose a high-level robot action. ROBController must approve it and Cerebro's local safety/motion layer must report the physical outcome. Approval is not completion.",
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
                    "description": "Allow-listed gesture name. Required by play_gesture."
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

    func booleanValue(for key: String, default defaultValue: Bool) -> Bool {
        guard let rawValue = nonemptyValue(for: key)?.lowercased() else {
            return defaultValue
        }
        switch rawValue {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}
