import Foundation
import CoreFoundation

/// Versioned, local-user RPC. A launch token is not robot authorization from a
/// remote controller: it binds explicit local commands to this app instance.
struct ROBLocalControlRequest {
    let id: UUID
    let operation: String
    let parameters: [String: Any]
    let session: String?
    let sentAt: Double
    static let readOperations: Set<String> = ["status", "speech.status", "camera.frame", "camera.depth", "animation.list", "mission.status", "mission.plan"]
    static let operations = readOperations.union(["speech.say", "camera.demand", "runtime.profile", "motion.move", "arm.mode", "gripper.command", "animation.play", "neck.pose", "torso.configure", "torso.reference", "torso.turn", "mission.start", "mission.confirm_empty", "stop"])
    var mutates: Bool { !Self.readOperations.contains(operation) }

    init(data: Data, now: Double = Date().timeIntervalSince1970 * 1000) throws {
        guard data.count <= 32_768,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys).isSubset(of: ["version", "id", "operation", "parameters", "session", "sent_at_ms"]),
              let version = value["version"] as? Int, version == 1,
              let idString = value["id"] as? String, let id = UUID(uuidString: idString),
              let operation = value["operation"] as? String, Self.operations.contains(operation),
              let sent = value["sent_at_ms"] as? Double, sent.isFinite, abs(now-sent) <= 10_000,
              let parameters = value["parameters"] as? [String: Any] else {
            throw ROBLocalControlError("Invalid, expired or unsupported local request")
        }
        self.id = id; self.operation = operation; self.parameters = parameters
        session = value["session"] as? String; sentAt = sent
    }
    func only(_ keys: Set<String>) throws {
        guard Set(parameters.keys).isSubset(of: keys) else { throw ROBLocalControlError("Unknown parameter") }
    }
    func assistantSpeechText() throws -> String {
        try only(["text", "source"])
        guard parameters["source"] as? String == "codex",
              let raw = parameters["text"] as? String,
              raw.utf16.count <= 2000 else {
            throw ROBLocalControlError("Speech requires source codex and at most 2000 characters")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ROBLocalControlError("Speech text is empty") }
        return text
    }
    func number(_ key: String, default fallback: Double? = nil, range: ClosedRange<Double>) throws -> Double {
        let candidate = parameters[key] as? NSNumber
        if parameters[key] != nil && candidate == nil { throw ROBLocalControlError("\(key) must be numeric") }
        if let candidate, CFGetTypeID(candidate) == CFBooleanGetTypeID() { throw ROBLocalControlError("\(key) must be numeric") }
        guard let result = candidate?.doubleValue ?? fallback, result.isFinite, range.contains(result) else {
            throw ROBLocalControlError("\(key) must be in \(range)")
        }
        return result
    }
}

struct ROBLocalControlError: LocalizedError {
    let errorDescription: String?
    init(_ detail: String) { errorDescription = detail }
}

/// No retries of motor commands, including a lost reply. A caller queries the
/// measured state instead. IDs remain reserved beyond the request age window.
struct ROBLocalControlAdmission {
    let session = UUID().uuidString
    private var commands: [UUID: Double] = [:]
    mutating func admit(_ request: ROBLocalControlRequest, now: Double = Date().timeIntervalSince1970 * 1000) throws {
        // Same-user Stop stays usable after an app restart without a status
        // round trip. It can only cancel/hold, never energize or resume a run.
        if request.operation == "stop" { return }
        guard request.mutates else { return }
        guard request.session == session else { throw ROBLocalControlError("App session changed; inspect status and issue a new command") }
        commands = commands.filter { now-$0.value < 60_000 }
        guard commands[request.id] == nil else { throw ROBLocalControlError("Duplicate command ID; query status instead of replaying motion") }
        guard commands.count < 256 else { throw ROBLocalControlError("Local command rate exceeded") }
        commands[request.id] = now
    }
}
