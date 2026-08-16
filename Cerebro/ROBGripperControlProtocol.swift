import Foundation

enum ROBGripperControlProtocol {
    static let name = "rob-gripper-control/1"
    static let schemaVersion = 1
    static let maximumMessageBytes = 4 * 1_024

    // The Amber API documents 1...300 raw intensity units. Vision deliberately
    // exposes only the smaller range exercised by the vendor dashboard.
    static let visionForceRange = 2 ... 20
}

enum ROBGripperAction: String, Codable, CaseIterable {
    case release
    case hold
}

enum ROBGripperCalibrationState: String, Codable, CaseIterable {
    case required
    case commandAcceptedUnverified = "command_accepted_unverified"
}

enum ROBGripperDispositionKind: String, Codable, CaseIterable {
    case dispatchAcknowledgedUnverified = "dispatch_acknowledged_unverified"
    case rejectedAuthorityDisabled = "rejected_authority_disabled"
    case rejectedCalibrationRequired = "rejected_calibration_required"
    case rejectedDeadMan = "rejected_dead_man"
    case rejectedIdentityMismatch = "rejected_identity_mismatch"
    case rejectedSessionInactive = "rejected_session_inactive"
    case rejectedExpired = "rejected_expired"
    case rejectedStaleSequence = "rejected_stale_sequence"
    case rejectedBusy = "rejected_busy"
    case rejectedInvalid = "rejected_invalid"
    case gatewayRejected = "gateway_rejected"
}

struct ROBGripperStateEnvelope: Codable, Equatable {
    let protocolName: String
    let schemaVersion: Int
    let type: String
    let messageID: UUID
    let arm: ROBArmSide
    let sequence: UInt64
    let sampledAtUnixMilliseconds: Int64
    let calibrationState: ROBGripperCalibrationState
    let calibrationVerified: Bool
    let feedbackAvailable: Bool
    let commandInFlight: Bool
    let lastAction: ROBGripperAction?
    let lastForce: Int?
    let detail: String

    init(
        messageID: UUID = UUID(),
        arm: ROBArmSide,
        sequence: UInt64,
        sampledAtUnixMilliseconds: Int64,
        calibrationState: ROBGripperCalibrationState,
        calibrationVerified: Bool,
        feedbackAvailable: Bool,
        commandInFlight: Bool,
        lastAction: ROBGripperAction?,
        lastForce: Int?,
        detail: String
    ) {
        protocolName = ROBGripperControlProtocol.name
        schemaVersion = ROBGripperControlProtocol.schemaVersion
        type = "state"
        self.messageID = messageID
        self.arm = arm
        self.sequence = sequence
        self.sampledAtUnixMilliseconds = sampledAtUnixMilliseconds
        self.calibrationState = calibrationState
        self.calibrationVerified = calibrationVerified
        self.feedbackAvailable = feedbackAvailable
        self.commandInFlight = commandInFlight
        self.lastAction = lastAction
        self.lastForce = lastForce
        self.detail = detail
    }

    var validationError: String? {
        guard protocolName == ROBGripperControlProtocol.name,
              schemaVersion == ROBGripperControlProtocol.schemaVersion,
              type == "state", sequence > 0, sampledAtUnixMilliseconds > 0 else {
            return "invalid gripper-state envelope"
        }
        // Current Amber hardware exposes only command acknowledgements. A
        // future measured implementation must use a new protocol revision.
        guard !calibrationVerified, !feedbackAvailable else {
            return "protocol v1 cannot claim measured gripper feedback"
        }
        guard lastForce.map({ (1 ... 300).contains($0) }) ?? true,
              !detail.isEmpty, detail.count <= 256 else {
            return "invalid gripper-state detail or force"
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case schemaVersion = "schema_version"
        case type
        case messageID = "message_id"
        case arm, sequence
        case sampledAtUnixMilliseconds = "sampled_at_unix_ms"
        case calibrationState = "calibration_state"
        case calibrationVerified = "calibration_verified"
        case feedbackAvailable = "feedback_available"
        case commandInFlight = "command_in_flight"
        case lastAction = "last_action"
        case lastForce = "last_force"
        case detail
    }
}

struct ROBGripperCommandIntentEnvelope: Codable, Equatable {
    let protocolName: String
    let schemaVersion: Int
    let type: String
    let messageID: UUID
    let senderID: UUID
    let sessionID: UUID
    let sequence: UInt64
    let issuedAtUnixMilliseconds: Int64
    let leaseMilliseconds: UInt32
    let arm: ROBArmSide
    let action: ROBGripperAction
    let force: Int
    let deadManHeld: Bool

    init(
        messageID: UUID = UUID(),
        senderID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        arm: ROBArmSide,
        action: ROBGripperAction,
        force: Int,
        deadManHeld: Bool
    ) {
        protocolName = ROBGripperControlProtocol.name
        schemaVersion = ROBGripperControlProtocol.schemaVersion
        type = "command_intent"
        self.messageID = messageID
        self.senderID = senderID
        self.sessionID = sessionID
        self.sequence = sequence
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.leaseMilliseconds = leaseMilliseconds
        self.arm = arm
        self.action = action
        self.force = force
        self.deadManHeld = deadManHeld
    }

    var boundsValidationError: String? {
        guard protocolName == ROBGripperControlProtocol.name,
              schemaVersion == ROBGripperControlProtocol.schemaVersion,
              type == "command_intent", sequence > 0,
              issuedAtUnixMilliseconds > 0,
              (100 ... 1_000).contains(leaseMilliseconds),
              ROBGripperControlProtocol.visionForceRange.contains(force) else {
            return "invalid gripper command bounds"
        }
        return nil
    }

    func freshnessValidationError(nowUnixMilliseconds: Int64) -> String? {
        guard issuedAtUnixMilliseconds <= nowUnixMilliseconds + 5_000 else {
            return "gripper command timestamp is too far in the future"
        }
        let expiry = issuedAtUnixMilliseconds.addingReportingOverflow(Int64(leaseMilliseconds))
        guard !expiry.overflow, nowUnixMilliseconds <= expiry.partialValue else {
            return "gripper command lease expired"
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case schemaVersion = "schema_version"
        case type
        case messageID = "message_id"
        case senderID = "sender_id"
        case sessionID = "session_id"
        case sequence
        case issuedAtUnixMilliseconds = "issued_at_unix_ms"
        case leaseMilliseconds = "lease_ms"
        case arm, action, force
        case deadManHeld = "dead_man_held"
    }
}

struct ROBGripperCommandDispositionEnvelope: Codable, Equatable {
    let protocolName: String
    let schemaVersion: Int
    let type: String
    let messageID: UUID
    let requestMessageID: UUID
    let recipientID: UUID
    let sessionID: UUID
    let arm: ROBArmSide
    let receivedAtUnixMilliseconds: Int64
    let disposition: ROBGripperDispositionKind
    let terminal: Bool
    let detail: String
    let calibrationState: ROBGripperCalibrationState
    let calibrationVerified: Bool
    let feedbackAvailable: Bool
    let action: ROBGripperAction?
    let force: Int?

    init(
        messageID: UUID = UUID(),
        requestMessageID: UUID,
        recipientID: UUID,
        sessionID: UUID,
        arm: ROBArmSide,
        receivedAtUnixMilliseconds: Int64,
        disposition: ROBGripperDispositionKind,
        detail: String,
        calibrationState: ROBGripperCalibrationState,
        calibrationVerified: Bool = false,
        feedbackAvailable: Bool = false,
        action: ROBGripperAction? = nil,
        force: Int? = nil
    ) {
        protocolName = ROBGripperControlProtocol.name
        schemaVersion = ROBGripperControlProtocol.schemaVersion
        type = "command_disposition"
        self.messageID = messageID
        self.requestMessageID = requestMessageID
        self.recipientID = recipientID
        self.sessionID = sessionID
        self.arm = arm
        self.receivedAtUnixMilliseconds = receivedAtUnixMilliseconds
        self.disposition = disposition
        terminal = true
        self.detail = detail
        self.calibrationState = calibrationState
        self.calibrationVerified = calibrationVerified
        self.feedbackAvailable = feedbackAvailable
        self.action = action
        self.force = force
    }

    var validationError: String? {
        guard protocolName == ROBGripperControlProtocol.name,
              schemaVersion == ROBGripperControlProtocol.schemaVersion,
              type == "command_disposition", receivedAtUnixMilliseconds > 0,
              terminal, !calibrationVerified, !feedbackAvailable,
              !detail.isEmpty, detail.count <= 256,
              force.map({ (1 ... 300).contains($0) }) ?? true else {
            return "invalid gripper disposition"
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case schemaVersion = "schema_version"
        case type
        case messageID = "message_id"
        case requestMessageID = "request_message_id"
        case recipientID = "recipient_id"
        case sessionID = "session_id"
        case arm
        case receivedAtUnixMilliseconds = "received_at_unix_ms"
        case disposition, terminal, detail
        case calibrationState = "calibration_state"
        case calibrationVerified = "calibration_verified"
        case feedbackAvailable = "feedback_available"
        case action, force
    }
}

enum ROBGripperControlDecodedMessage: Equatable {
    case state(ROBGripperStateEnvelope)
    case commandIntent(ROBGripperCommandIntentEnvelope)
    case commandDisposition(ROBGripperCommandDispositionEnvelope)
}

enum ROBGripperControlWireError: Error, Equatable {
    case oversized
    case malformed
    case unknownType
    case unexpectedFields
    case invalid(String)
}

enum ROBGripperControlWireCodec {
    private static let maximumRoutingInspectionBytes = 4 * 1_024 * 1_024
    private static let rawProtocolKey = Array("\"protocol\"".utf8)
    private static let rawProtocolValue = Array("\"rob-gripper-control/1\"".utf8)
    private static let stateKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "arm", "sequence",
        "sampled_at_unix_ms", "calibration_state", "calibration_verified",
        "feedback_available", "command_in_flight", "last_action", "last_force", "detail",
    ]
    private static let intentKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "sequence", "issued_at_unix_ms", "lease_ms", "arm", "action", "force",
        "dead_man_held",
    ]
    private static let dispositionKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "request_message_id",
        "recipient_id", "session_id", "arm", "received_at_unix_ms", "disposition",
        "terminal", "detail", "calibration_state", "calibration_verified",
        "feedback_available", "action", "force",
    ]

    static func claimsProtocolForRouting(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumRoutingInspectionBytes else { return false }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return dictionary["protocol"] as? String == ROBGripperControlProtocol.name
        }
        return containsRawProtocolMember(Array(data))
    }

    static func decode(
        _ data: Data,
        nowUnixMilliseconds: Int64 = currentUnixMilliseconds(),
        requireFreshIntent: Bool = true
    ) throws -> ROBGripperControlDecodedMessage? {
        guard !data.isEmpty else { return nil }
        guard data.count <= ROBGripperControlProtocol.maximumMessageBytes else {
            throw ROBGripperControlWireError.oversized
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        guard dictionary["protocol"] as? String == ROBGripperControlProtocol.name else {
            return nil
        }
        guard let type = dictionary["type"] as? String else {
            throw ROBGripperControlWireError.malformed
        }
        let decoder = JSONDecoder()
        switch type {
        case "state":
            try requireKeys(dictionary, allowed: stateKeys, required: stateKeys.subtracting(["last_action", "last_force"]))
            let value: ROBGripperStateEnvelope = try decode(data, decoder: decoder)
            if let error = value.validationError { throw ROBGripperControlWireError.invalid(error) }
            return .state(value)
        case "command_intent":
            try requireKeys(dictionary, allowed: intentKeys, required: intentKeys)
            let value: ROBGripperCommandIntentEnvelope = try decode(data, decoder: decoder)
            if let error = value.boundsValidationError
                ?? (requireFreshIntent
                    ? value.freshnessValidationError(nowUnixMilliseconds: nowUnixMilliseconds)
                    : nil) {
                throw ROBGripperControlWireError.invalid(error)
            }
            return .commandIntent(value)
        case "command_disposition":
            try requireKeys(dictionary, allowed: dispositionKeys, required: dispositionKeys.subtracting(["action", "force"]))
            let value: ROBGripperCommandDispositionEnvelope = try decode(data, decoder: decoder)
            if let error = value.validationError { throw ROBGripperControlWireError.invalid(error) }
            return .commandDisposition(value)
        default:
            throw ROBGripperControlWireError.unknownType
        }
    }

    static func encode(_ value: ROBGripperStateEnvelope) throws -> Data {
        guard value.validationError == nil else {
            throw ROBGripperControlWireError.invalid(value.validationError ?? "invalid state")
        }
        return try encodeBounded(value)
    }

    static func encode(
        _ value: ROBGripperCommandIntentEnvelope,
        nowUnixMilliseconds: Int64 = currentUnixMilliseconds()
    ) throws -> Data {
        guard value.boundsValidationError == nil,
              value.freshnessValidationError(nowUnixMilliseconds: nowUnixMilliseconds) == nil else {
            throw ROBGripperControlWireError.invalid("invalid or expired gripper intent")
        }
        return try encodeBounded(value)
    }

    static func encode(_ value: ROBGripperCommandDispositionEnvelope) throws -> Data {
        guard value.validationError == nil else {
            throw ROBGripperControlWireError.invalid(value.validationError ?? "invalid disposition")
        }
        return try encodeBounded(value)
    }

    static func currentUnixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private static func requireKeys(
        _ dictionary: [String: Any],
        allowed: Set<String>,
        required: Set<String>
    ) throws {
        let keys = Set(dictionary.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw ROBGripperControlWireError.unexpectedFields
        }
    }

    private static func decode<T: Decodable>(_ data: Data, decoder: JSONDecoder) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ROBGripperControlWireError.malformed }
    }

    private static func encodeBounded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw ROBGripperControlWireError.malformed }
        guard data.count <= ROBGripperControlProtocol.maximumMessageBytes else {
            throw ROBGripperControlWireError.oversized
        }
        return data
    }

    private static func containsRawProtocolMember(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index + rawProtocolKey.count <= bytes.count {
            guard bytes[index ..< index + rawProtocolKey.count].elementsEqual(rawProtocolKey) else {
                index += 1
                continue
            }
            var cursor = index + rawProtocolKey.count
            while cursor < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[cursor]) {
                cursor += 1
            }
            guard cursor < bytes.count, bytes[cursor] == 0x3A else {
                index += 1
                continue
            }
            cursor += 1
            while cursor < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[cursor]) {
                cursor += 1
            }
            if cursor + rawProtocolValue.count <= bytes.count,
               bytes[cursor ..< cursor + rawProtocolValue.count].elementsEqual(rawProtocolValue) {
                return true
            }
            index += 1
        }
        return false
    }
}
