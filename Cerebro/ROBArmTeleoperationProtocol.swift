import Foundation

/// Physical Cartesian input has a separate wire identity from preview and joint jogging.
/// Shared verbatim with ROBControllerVision. Metres, radians, quaternion xyzw.
public struct ROBArmTeleoperationCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case clutch, pose, release }
    public let action: Action
    public let arm: String
    public let clutchID: UUID
    public let authorityID: UUID
    public let tracking: ROBShadowTrackingSample?
    public let translationScale: Double

    public init(action: Action, arm: String, clutchID: UUID, authorityID: UUID,
                tracking: ROBShadowTrackingSample? = nil, translationScale: Double = 0.2) {
        self.action = action; self.arm = arm; self.clutchID = clutchID
        self.authorityID = authorityID; self.tracking = tracking; self.translationScale = translationScale
    }
    public var isValid: Bool {
        ["left", "right"].contains(arm) && [0.2, 1.0].contains(translationScale)
            && (action == .release ? tracking == nil :
                tracking?.isValid == true && tracking?.quality == "tracked" && (tracking?.ageMilliseconds ?? .infinity) <= 150)
    }
}

public struct ROBArmTeleoperationRequest: Codable, Equatable, Sendable {
    public let protocolName: String
    public let controllerID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let issuedAt: Double
    public let command: ROBArmTeleoperationCommand
    public init(controllerID: UUID, sessionID: UUID, sequence: UInt64,
                command: ROBArmTeleoperationCommand, issuedAt: Double = Date().timeIntervalSince1970) {
        protocolName = ROBArmTeleoperationProtocol.name; self.controllerID = controllerID
        self.sessionID = sessionID; self.sequence = sequence; self.command = command; self.issuedAt = issuedAt
    }
}

public struct ROBArmTeleoperationResponse: Codable, Equatable, Sendable {
    public let protocolName: String
    public let controllerID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let arm: String
    public let clutchID: UUID
    public let status: String
    public let detail: String
    public init(request: ROBArmTeleoperationRequest, status: String, detail: String) {
        protocolName = ROBArmTeleoperationProtocol.name; controllerID = request.controllerID
        sessionID = request.sessionID; sequence = request.sequence; arm = request.command.arm
        clutchID = request.command.clutchID; self.status = status; self.detail = detail
    }
}

public enum ROBArmTeleoperationProtocol {
    public static let name = "rob-arm-teleoperation/1"
    public static let maximumBytes = 8192
    public static func claims(_ data: Data) -> Bool {
        // Consume malformed and future versions before any legacy command parser.
        String(decoding: data.prefix(maximumBytes), as: UTF8.self).contains("rob-arm-teleoperation/")
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw invalid() }; return data
    }
    public static func request(_ data: Data, now: Double = Date().timeIntervalSince1970) throws -> ROBArmTeleoperationRequest {
        let object = try dictionary(data)
        guard Set(object.keys) == Set(["protocolName", "controllerID", "sessionID", "sequence", "issuedAt", "command"]),
              let command = object["command"] as? [String: Any],
              Set(command.keys).isSubset(of: Set(["action", "arm", "clutchID", "authorityID", "tracking", "translationScale"])) else { throw invalid() }
        if let sample = command["tracking"] as? [String: Any] {
            guard Set(sample.keys) == Set(["trackingID", "sampleID", "ageMilliseconds", "quality", "pose"]),
                  let pose = sample["pose"] as? [String: Any], Set(pose.keys) == Set(["position", "quaternion"]) else { throw invalid() }
        }
        let value = try JSONDecoder().decode(ROBArmTeleoperationRequest.self, from: data)
        guard value.protocolName == name, value.sequence > 0, value.command.isValid,
              value.issuedAt.isFinite, now.isFinite, (-0.1...0.25).contains(now - value.issuedAt),
              (value.command.tracking?.ageMilliseconds ?? 0) + max(0, now - value.issuedAt) * 1000 <= 150 else { throw invalid() }
        return value
    }
    public static func response(_ data: Data) throws -> ROBArmTeleoperationResponse {
        _ = try dictionary(data)
        let value = try JSONDecoder().decode(ROBArmTeleoperationResponse.self, from: data)
        guard value.protocolName == name, value.sequence > 0, ["left", "right"].contains(value.arm),
              ["clutched", "following", "held", "blocked"].contains(value.status), value.detail.count <= 1500 else { throw invalid() }
        return value
    }
    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid() }
        return object
    }
    private static func invalid() -> NSError {
        NSError(domain: "ROBArmTeleoperation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid or stale Cartesian controller input."])
    }
}
