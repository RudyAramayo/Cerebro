import Foundation

enum ROBOpenAIRealtimeProtocol {
    static func request(configuration: ROBOpenAIRealtimeConfiguration) -> URLRequest {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: configuration.model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func sessionUpdate(configuration: ROBOpenAIRealtimeConfiguration) -> [String: Any] {
        let setup = GeminiRoboticsProtocol.setupMessage(configuration: configuration.runtime, resumptionHandle: nil)
        let body = setup["setup"] as? [String: Any] ?? [:]
        let groups = body["tools"] as? [[String: Any]] ?? []
        let functions = groups.flatMap { $0["functionDeclarations"] as? [[String: Any]] ?? [] }
        let tools: [[String: Any]] = functions.map {
            ["type": "function", "name": $0["name"] ?? "", "description": $0["description"] ?? "",
             "parameters": schema($0["parameters"] ?? [:])]
        }
        return ["type": "session.update", "session": [
            "type": "realtime", "model": configuration.model, "output_modalities": ["text"],
            "instructions": configuration.runtime.systemInstruction, "tools": tools, "tool_choice": "auto",
            "max_output_tokens": 1024,
            "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24000],
                "turn_detection": ["type": "server_vad", "create_response": false,
                                   "interrupt_response": false, "silence_duration_ms": 500]
            ]]
        ]]
    }

    private static func schema(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValues { schema($0) }.merging(
                (object["type"] as? String).map { ["type": $0.lowercased()] } ?? [:],
                uniquingKeysWith: { _, new in new })
        }
        if let values = value as? [Any] { return values.map(schema) }
        return value
    }
    static func userItem(text: String?, image: Data? = nil, id: String = "rob_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")) -> [String: Any] {
        var content: [[String: Any]] = []
        if let text { content.append(["type": "input_text", "text": text]) }
        if let image { content.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + image.base64EncodedString()]) }
        return ["type": "conversation.item.create", "item": ["id": id, "type": "message", "role": "user", "content": content]]
    }
    static func response(token: String, dialogueOnly: Bool) -> [String: Any] {
        var value: [String: Any] = ["output_modalities": ["text"], "metadata": ["cerebro_turn": token]]
        if dialogueOnly { value["tool_choice"] = "none"; value["max_output_tokens"] = 192 }
        return ["type": "response.create", "response": value]
    }
    static func toolOutput(callID: String, result: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return ["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": callID, "output": String(decoding: data, as: UTF8.self)
        ]]
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= 4 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] is String else { throw Failure.invalidEvent }
        return object
    }
    static func output(_ response: [String: Any]) throws -> (String, [GeminiRoboticsToolCall]) {
        let items = response["output"] as? [[String: Any]] ?? []
        guard items.count <= 32 else { throw Failure.invalidEvent }
        var lines: [String] = [], calls: [GeminiRoboticsToolCall] = []
        for item in items {
            if item["type"] as? String == "function_call" {
                guard let id = item["call_id"] as? String, !id.isEmpty, id.count <= 256,
                      let name = item["name"] as? String, name.count <= 100,
                      let arguments = item["arguments"] as? String, arguments.utf8.count <= 32_768,
                      let data = arguments.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Failure.invalidEvent
                }
                calls.append(GeminiRoboticsToolCall(id: id, name: name, arguments: object))
            } else if item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if ["output_text", "text"].contains(part["type"] as? String ?? ""),
                       let text = part["text"] as? String { lines.append(text) }
                }
            }
        }
        guard calls.count <= 8, Set(calls.map(\.id)).count == calls.count else { throw Failure.invalidEvent }
        return (String(lines.joined(separator: "\n").prefix(12_000)), calls)
    }
    enum Failure: LocalizedError {
        case invalidEvent, disconnected
        var errorDescription: String? { self == .invalidEvent ? "OpenAI returned an invalid or oversized event." : "OpenAI Realtime disconnected." }
    }
}

/// Stateful interpolation preserves sample position across microphone chunks.
/// Output is mono signed little-endian PCM16 at the Realtime API's 24 kHz rate.
struct ROBRealtimePCMResampler {
    private var samples: [Double] = []
    private var position = 0.0
    mutating func reset() { samples = []; position = 0 }
    mutating func convert16To24(_ data: Data) -> Data {
        guard data.count % 2 == 0, data.count <= 192_000 else { return Data() }
        data.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 2) {
                samples.append(Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self))))
            }
        }
        var output = Data()
        while Int(position) + 1 < samples.count {
            let i = Int(position), fraction = position - Double(i)
            let value = samples[i] * (1 - fraction) + samples[i + 1] * fraction
            var encoded = Int16(clamping: Int(value.rounded())).littleEndian
            withUnsafeBytes(of: &encoded) { output.append(contentsOf: $0) }
            position += 2.0 / 3.0
        }
        let consumed = min(Int(position), samples.count)
        samples.removeFirst(consumed); position -= Double(consumed)
        return output
    }
}
