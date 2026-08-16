import Foundation

enum ROBArmControlProtocol {
    static let name = "rob-arm-control/2"
    static let schemaVersion = 2
    static let jointCount = 7
    static let maximumMessageBytes = 8 * 1_024
    /// Calibrated B1 limits shared with `ROBAmberB1Kinematics` and enforced
    /// again by the authenticated Amber gateway. Keep the joint ordering
    /// J1...J7; a single symmetric maximum is unsafe for J1...J6.
    static let targetJointBoundsRadians: [ClosedRange<Double>] = [
        -2.4435 ... 2.4435,
        -2.3213 ... 2.3213,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -3.05 ... 3.05,
    ]

    static func containsTargetPositions(_ positionsRadians: [Double]) -> Bool {
        positionsRadians.count == targetJointBoundsRadians.count
            && zip(positionsRadians, targetJointBoundsRadians).allSatisfy { position, bounds in
                position.isFinite && bounds.contains(position)
            }
    }
}

enum ROBArmSide: String, Codable, CaseIterable {
    case left
    case right
}

enum ROBArmTargetSource: String, Codable {
    case visionProSpatial = "vision_pro_spatial"
    case visionProJointUI = "vision_pro_joint_ui"
    case testHarness = "test_harness"
}

enum ROBArmTargetDispositionKind: String, Codable, CaseIterable {
    case acceptedForExecution = "accepted_for_execution"
    case executing
    case completedMeasured = "completed_measured"
    case cancelledHeld = "cancelled_held"
    case leaseExpiredHeld = "lease_expired_held"
    case holdConfirmed = "hold_confirmed"
    case holdUnconfirmed = "hold_unconfirmed"
    case failed
    case rejectedAuthorityDisabled = "rejected_authority_disabled"
    case rejectedExpired = "rejected_expired"
    case rejectedIdentityMismatch = "rejected_identity_mismatch"
    case rejectedSessionInactive = "rejected_session_inactive"
    case rejectedStaleSequence = "rejected_stale_sequence"
    case rejectedTelemetryStale = "rejected_telemetry_stale"
    case rejectedPositionModeRequired = "rejected_position_mode_required"
    case rejectedStepLimit = "rejected_step_limit"
    case rejectedSpeedLimit = "rejected_speed_limit"
    case rejectedArmBusy = "rejected_arm_busy"
    case rejectedInvalid = "rejected_invalid"
}

enum ROBArmAuthorityOperation: String, Codable {
    case acquire
    case release
}

enum ROBArmAuthorityState: String, Codable {
    case granted
    case released
    case rejected
    case expired
}

private protocol ROBArmControlEnvelope {
    var protocolName: String { get }
    var schemaVersion: Int { get }
    var type: String { get }
    var messageID: UUID { get }
}

struct ROBArmMeasuredState: Codable, Equatable, ROBArmControlEnvelope {
    let protocolName: String
    let schemaVersion: Int
    let type: String
    let messageID: UUID
    let arm: ROBArmSide
    let sequence: UInt64
    let sampledAtUnixMilliseconds: Int64
    let sampleAgeMilliseconds: Double
    let positionsRadians: [Double]
    let velocitiesRadiansPerSecond: [Double]
    let currents: [Double]
    let statuses: [Double]
    let modes: [Int]

    init(
        messageID: UUID = UUID(),
        arm: ROBArmSide,
        sequence: UInt64,
        sampledAtUnixMilliseconds: Int64,
        sampleAgeMilliseconds: Double,
        positionsRadians: [Double],
        velocitiesRadiansPerSecond: [Double],
        currents: [Double],
        statuses: [Double],
        modes: [Int]
    ) {
        protocolName = ROBArmControlProtocol.name
        schemaVersion = ROBArmControlProtocol.schemaVersion
        type = "measured_state"
        self.messageID = messageID
        self.arm = arm
        self.sequence = sequence
        self.sampledAtUnixMilliseconds = sampledAtUnixMilliseconds
        self.sampleAgeMilliseconds = sampleAgeMilliseconds
        self.positionsRadians = positionsRadians
        self.velocitiesRadiansPerSecond = velocitiesRadiansPerSecond
        self.currents = currents
        self.statuses = statuses
        self.modes = modes
    }

    var validationError: String? {
        guard protocolName == ROBArmControlProtocol.name,
              schemaVersion == ROBArmControlProtocol.schemaVersion,
              type == "measured_state" else { return "unsupported measured-state envelope" }
        guard sequence > 0, sampledAtUnixMilliseconds > 0 else {
            return "invalid measured-state sequence or timestamp"
        }
        guard sampleAgeMilliseconds.isFinite,
              (0 ... 60_000).contains(sampleAgeMilliseconds) else {
            return "invalid measured-state age"
        }
        guard Self.validVector(positionsRadians, absoluteLimit: 4 * .pi),
              Self.validVector(velocitiesRadiansPerSecond, absoluteLimit: 100),
              Self.validVector(currents, absoluteLimit: 1_000),
              Self.validVector(statuses, absoluteLimit: 1_000_000_000),
              modes.count == ROBArmControlProtocol.jointCount,
              modes.allSatisfy({ (0 ... 4).contains($0) }) else {
            return "invalid measured-state joint vector"
        }
        return nil
    }

    private static func validVector(_ vector: [Double], absoluteLimit: Double) -> Bool {
        vector.count == ROBArmControlProtocol.jointCount
            && vector.allSatisfy { $0.isFinite && abs($0) <= absoluteLimit }
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case schemaVersion = "schema_version"
        case type
        case messageID = "message_id"
        case arm, sequence
        case sampledAtUnixMilliseconds = "sampled_at_unix_ms"
        case sampleAgeMilliseconds = "sample_age_ms"
        case positionsRadians = "positions_rad"
        case velocitiesRadiansPerSecond = "velocities_rad_s"
        case currents, statuses, modes
    }
}

struct ROBArmTargetIntentEnvelope: Codable, Equatable, ROBArmControlEnvelope {
    let protocolName: String
    let schemaVersion: Int
    let type: String
    let messageID: UUID
    let senderID: UUID
    let sessionID: UUID
    let authorityID: UUID
    let sequence: UInt64
    let issuedAtUnixMilliseconds: Int64
    let leaseMilliseconds: UInt32
    let arm: ROBArmSide
    let source: ROBArmTargetSource
    let positionsRadians: [Double]
    let durationSeconds: Double
    let deadManHeld: Bool

    init(
        messageID: UUID = UUID(),
        senderID: UUID,
        sessionID: UUID,
        authorityID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        arm: ROBArmSide,
        source: ROBArmTargetSource,
        positionsRadians: [Double],
        durationSeconds: Double,
        deadManHeld: Bool
    ) {
        protocolName = ROBArmControlProtocol.name
        schemaVersion = ROBArmControlProtocol.schemaVersion
        type = "target_intent"
        self.messageID = messageID
        self.senderID = senderID
        self.sessionID = sessionID
        self.authorityID = authorityID
        self.sequence = sequence
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.leaseMilliseconds = leaseMilliseconds
        self.arm = arm
        self.source = source
        self.positionsRadians = positionsRadians
        self.durationSeconds = durationSeconds
        self.deadManHeld = deadManHeld
    }

    var boundsValidationError: String? {
        guard protocolName == ROBArmControlProtocol.name,
              schemaVersion == ROBArmControlProtocol.schemaVersion,
              type == "target_intent" else { return "unsupported target-intent envelope" }
        guard sequence > 0,
              issuedAtUnixMilliseconds > 0,
              (50 ... 1_500).contains(leaseMilliseconds),
              deadManHeld else {
            return "invalid target sequence, timestamp, or lease"
        }
        guard ROBArmControlProtocol.containsTargetPositions(positionsRadians),
              durationSeconds.isFinite,
              (0.65 ... 10).contains(durationSeconds) else {
            return "target exceeds joint-count, position, or duration bounds"
        }
        return nil
    }

    func freshnessValidationError(nowUnixMilliseconds: Int64) -> String? {
        guard issuedAtUnixMilliseconds <= nowUnixMilliseconds + 5_000 else {
            return "target timestamp is too far in the future"
        }
        let nonnegativeAge = max(0, nowUnixMilliseconds - issuedAtUnixMilliseconds)
        guard nonnegativeAge <= Int64(leaseMilliseconds) else {
            return "target lease expired"
        }
        return nil
    }

    func validationError(nowUnixMilliseconds: Int64) -> String? {
        boundsValidationError ?? freshnessValidationError(nowUnixMilliseconds: nowUnixMilliseconds)
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case schemaVersion = "schema_version"
        case type
        case messageID = "message_id"
        case senderID = "sender_id"
        case sessionID = "session_id"
        case authorityID = "authority_id"
        case sequence
        case issuedAtUnixMilliseconds = "issued_at_unix_ms"
        case leaseMilliseconds = "lease_ms"
        case arm, source
        case positionsRadians = "positions_rad"
        case durationSeconds = "duration_s"
        case deadManHeld = "dead_man_held"
    }
}

struct ROBArmAuthorityIntentEnvelope: Codable, Equatable, ROBArmControlEnvelope {
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
    let operation: ROBArmAuthorityOperation

    init(
        messageID: UUID = UUID(),
        senderID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        arm: ROBArmSide,
        operation: ROBArmAuthorityOperation
    ) {
        protocolName = ROBArmControlProtocol.name
        schemaVersion = ROBArmControlProtocol.schemaVersion
        type = "authority_intent"
        self.messageID = messageID
        self.senderID = senderID
        self.sessionID = sessionID
        self.sequence = sequence
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.leaseMilliseconds = leaseMilliseconds
        self.arm = arm
        self.operation = operation
    }

    var validationError: String? {
        guard protocolName == ROBArmControlProtocol.name,
              schemaVersion == ROBArmControlProtocol.schemaVersion,
              type == "authority_intent",
              sequence > 0,
              issuedAtUnixMilliseconds > 0 else { return "invalid authority envelope" }
        switch operation {
        case .acquire:
            guard (60_000 ... 600_000).contains(leaseMilliseconds) else {
                return "authority duration must be 1 through 10 minutes"
            }
        case .release:
            guard (50 ... 1_500).contains(leaseMilliseconds) else {
                return "authority release lease is invalid"
            }
        }
        return nil
    }

    func freshnessValidationError(nowUnixMilliseconds: Int64) -> String? {
        guard abs(nowUnixMilliseconds - issuedAtUnixMilliseconds) <= 5_000 else {
            return "authority timestamp is outside the allowed clock window"
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
        case arm, operation
    }
}

struct ROBArmAuthorityStateEnvelope: Codable, Equatable, ROBArmControlEnvelope {
    let protocolName: String
    let schemaVersion: Int
    let type: String
    let messageID: UUID
    let requestMessageID: UUID
    let recipientID: UUID
    let sessionID: UUID
    let arm: ROBArmSide
    let state: ROBArmAuthorityState
    let authorityID: UUID?
    let expiresAtUnixMilliseconds: Int64
    let detail: String
    let baselinePositionsRadians: [Double]
    let baselineSequence: UInt64
    let modes: [Int]

    init(
        messageID: UUID = UUID(),
        requestMessageID: UUID,
        recipientID: UUID,
        sessionID: UUID,
        arm: ROBArmSide,
        state: ROBArmAuthorityState,
        authorityID: UUID?,
        expiresAtUnixMilliseconds: Int64,
        detail: String,
        baselinePositionsRadians: [Double],
        baselineSequence: UInt64,
        modes: [Int]
    ) {
        protocolName = ROBArmControlProtocol.name
        schemaVersion = ROBArmControlProtocol.schemaVersion
        type = "authority_state"
        self.messageID = messageID
        self.requestMessageID = requestMessageID
        self.recipientID = recipientID
        self.sessionID = sessionID
        self.arm = arm
        self.state = state
        self.authorityID = authorityID
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.detail = String(detail.prefix(256))
        self.baselinePositionsRadians = baselinePositionsRadians
        self.baselineSequence = baselineSequence
        self.modes = modes
    }

    var validationError: String? {
        guard protocolName == ROBArmControlProtocol.name,
              schemaVersion == ROBArmControlProtocol.schemaVersion,
              type == "authority_state",
              !detail.isEmpty,
              detail.count <= 256,
              baselinePositionsRadians.isEmpty
                || ROBArmControlProtocol.containsTargetPositions(baselinePositionsRadians),
              modes.isEmpty || (modes.count == ROBArmControlProtocol.jointCount
                && modes.allSatisfy({ (0 ... 4).contains($0) })) else {
            return "invalid authority state"
        }
        if state == .granted {
            guard authorityID != nil,
                  expiresAtUnixMilliseconds > 0,
                  baselineSequence > 0,
                  baselinePositionsRadians.count == ROBArmControlProtocol.jointCount,
                  modes.count == ROBArmControlProtocol.jointCount else {
                return "granted authority is incomplete"
            }
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
        case arm, state
        case authorityID = "authority_id"
        case expiresAtUnixMilliseconds = "expires_at_unix_ms"
        case detail
        case baselinePositionsRadians = "baseline_positions_rad"
        case baselineSequence = "baseline_sequence"
        case modes
    }
}

struct ROBArmHoldIntentEnvelope: Codable, Equatable, ROBArmControlEnvelope {
    let protocolName: String
    let schemaVersion: Int
    let type: String
    let messageID: UUID
    let senderID: UUID
    let sessionID: UUID
    let authorityID: UUID?
    let sequence: UInt64
    let issuedAtUnixMilliseconds: Int64
    let leaseMilliseconds: UInt32
    let arm: ROBArmSide
    let reason: String

    init(
        messageID: UUID = UUID(),
        senderID: UUID,
        sessionID: UUID,
        authorityID: UUID?,
        sequence: UInt64,
        issuedAtUnixMilliseconds: Int64,
        leaseMilliseconds: UInt32,
        arm: ROBArmSide,
        reason: String
    ) {
        protocolName = ROBArmControlProtocol.name
        schemaVersion = ROBArmControlProtocol.schemaVersion
        type = "hold_intent"
        self.messageID = messageID
        self.senderID = senderID
        self.sessionID = sessionID
        self.authorityID = authorityID
        self.sequence = sequence
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.leaseMilliseconds = leaseMilliseconds
        self.arm = arm
        self.reason = String(reason.prefix(128))
    }

    var validationError: String? {
        guard protocolName == ROBArmControlProtocol.name,
              schemaVersion == ROBArmControlProtocol.schemaVersion,
              type == "hold_intent",
              sequence > 0,
              issuedAtUnixMilliseconds > 0,
              (50 ... 1_500).contains(leaseMilliseconds),
              !reason.isEmpty,
              reason.count <= 128 else { return "invalid hold intent" }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case schemaVersion = "schema_version"
        case type
        case messageID = "message_id"
        case senderID = "sender_id"
        case sessionID = "session_id"
        case authorityID = "authority_id"
        case sequence
        case issuedAtUnixMilliseconds = "issued_at_unix_ms"
        case leaseMilliseconds = "lease_ms"
        case arm, reason
    }
}

struct ROBArmTargetDispositionEnvelope: Codable, Equatable, ROBArmControlEnvelope {
    let protocolName: String
    let schemaVersion: Int
    let type: String
    let messageID: UUID
    let targetMessageID: UUID
    let recipientID: UUID
    let sessionID: UUID
    let arm: ROBArmSide
    let receivedAtUnixMilliseconds: Int64
    let disposition: ROBArmTargetDispositionKind
    let executionEligible: Bool
    let terminal: Bool
    let detail: String
    let measuredPositionsRadians: [Double]?
    let maximumErrorRadians: Double?

    init(
        messageID: UUID = UUID(),
        targetMessageID: UUID,
        recipientID: UUID,
        sessionID: UUID,
        arm: ROBArmSide,
        receivedAtUnixMilliseconds: Int64,
        disposition: ROBArmTargetDispositionKind,
        executionEligible: Bool,
        terminal: Bool,
        detail: String,
        measuredPositionsRadians: [Double]? = nil,
        maximumErrorRadians: Double? = nil
    ) {
        protocolName = ROBArmControlProtocol.name
        schemaVersion = ROBArmControlProtocol.schemaVersion
        type = "target_disposition"
        self.messageID = messageID
        self.targetMessageID = targetMessageID
        self.recipientID = recipientID
        self.sessionID = sessionID
        self.arm = arm
        self.receivedAtUnixMilliseconds = receivedAtUnixMilliseconds
        self.disposition = disposition
        self.executionEligible = executionEligible
        self.terminal = terminal
        self.detail = String(detail.prefix(256))
        self.measuredPositionsRadians = measuredPositionsRadians
        self.maximumErrorRadians = maximumErrorRadians
    }

    var validationError: String? {
        guard protocolName == ROBArmControlProtocol.name,
              schemaVersion == ROBArmControlProtocol.schemaVersion,
              type == "target_disposition",
              receivedAtUnixMilliseconds > 0,
              !detail.isEmpty,
              detail.count <= 256 else { return "invalid target disposition" }
        let eligibleDispositions: Set<ROBArmTargetDispositionKind> = [
            .acceptedForExecution, .executing, .completedMeasured,
        ]
        guard executionEligible == eligibleDispositions.contains(disposition) else {
            return "execution eligibility did not match the disposition"
        }
        let terminalDispositions: Set<ROBArmTargetDispositionKind> = [
            .completedMeasured, .cancelledHeld, .leaseExpiredHeld,
            .holdConfirmed, .holdUnconfirmed, .failed,
            .rejectedAuthorityDisabled, .rejectedExpired,
            .rejectedIdentityMismatch, .rejectedSessionInactive,
            .rejectedStaleSequence, .rejectedTelemetryStale,
            .rejectedPositionModeRequired, .rejectedStepLimit,
            .rejectedSpeedLimit, .rejectedArmBusy, .rejectedInvalid,
        ]
        guard terminal == terminalDispositions.contains(disposition) else {
            return "terminal flag did not match the disposition"
        }
        if let measuredPositionsRadians,
           !ROBArmControlProtocol.containsTargetPositions(measuredPositionsRadians) {
            return "invalid measured disposition vector"
        }
        if let maximumErrorRadians,
           (!maximumErrorRadians.isFinite || maximumErrorRadians < 0 || maximumErrorRadians > 20) {
            return "invalid maximum disposition error"
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case schemaVersion = "schema_version"
        case type
        case messageID = "message_id"
        case targetMessageID = "target_message_id"
        case recipientID = "recipient_id"
        case sessionID = "session_id"
        case arm
        case receivedAtUnixMilliseconds = "received_at_unix_ms"
        case disposition
        case executionEligible = "execution_eligible"
        case terminal
        case detail
        case measuredPositionsRadians = "measured_positions_rad"
        case maximumErrorRadians = "max_error_rad"
    }
}

enum ROBArmControlDecodedMessage: Equatable {
    case measuredState(ROBArmMeasuredState)
    case targetIntent(ROBArmTargetIntentEnvelope)
    case authorityIntent(ROBArmAuthorityIntentEnvelope)
    case authorityState(ROBArmAuthorityStateEnvelope)
    case holdIntent(ROBArmHoldIntentEnvelope)
    case targetDisposition(ROBArmTargetDispositionEnvelope)
}

enum ROBArmControlWireError: Error, Equatable {
    case oversized
    case malformed
    case unknownType
    case unexpectedFields
    case invalid(String)
}

enum ROBArmControlWireCodec {
    /// Matches the authenticated AutoNet v2/legacy frame ceiling. Routing may
    /// inspect a frame larger than the arm protocol's 8 KiB decode limit so a
    /// claimed oversized arm message cannot fall through to another parser.
    private static let maximumRoutingInspectionBytes = 4 * 1_024 * 1_024
    private static let rawProtocolKey = Array("\"protocol\"".utf8)
    private static let rawProtocolValues = [
        Array("\"rob-arm-control/1\"".utf8),
        Array("\"rob-arm-control/2\"".utf8),
    ]
    private static let measuredKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "arm", "sequence",
        "sampled_at_unix_ms", "sample_age_ms", "positions_rad", "velocities_rad_s",
        "currents", "statuses", "modes",
    ]
    private static let targetKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "authority_id", "sequence", "issued_at_unix_ms", "lease_ms", "arm", "source",
        "positions_rad", "duration_s", "dead_man_held",
    ]
    private static let authorityIntentKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "sequence", "issued_at_unix_ms", "lease_ms", "arm", "operation",
    ]
    private static let authorityStateKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "request_message_id",
        "recipient_id", "session_id", "arm", "state", "authority_id", "expires_at_unix_ms",
        "detail", "baseline_positions_rad", "baseline_sequence", "modes",
    ]
    private static let holdKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "sender_id", "session_id",
        "authority_id", "sequence", "issued_at_unix_ms", "lease_ms", "arm", "reason",
    ]
    private static let dispositionKeys: Set<String> = [
        "protocol", "schema_version", "type", "message_id", "target_message_id",
        "recipient_id", "session_id", "arm", "received_at_unix_ms", "disposition",
        "execution_eligible", "terminal", "detail", "measured_positions_rad", "max_error_rad",
    ]

    /// Classifies data before the historical keyed-archive parser. Valid JSON
    /// is decoded so whitespace, member order, and JSON string escapes cannot
    /// hide the protocol marker. For truncated/malformed JSON, a small lexical
    /// fallback recognizes the canonical protocol member anywhere in the
    /// transport-bounded frame.
    static func claimsProtocolForRouting(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumRoutingInspectionBytes else { return false }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            guard let name = dictionary["protocol"] as? String else { return false }
            return name == ROBArmControlProtocol.name || name == "rob-arm-control/1"
        }
        return containsRawProtocolMember(Array(data))
    }

    /// Returns nil for unrelated application data and throws for a malformed
    /// message that claims this protocol marker.
    static func decode(
        _ data: Data,
        nowUnixMilliseconds: Int64 = currentUnixMilliseconds(),
        requireFreshTarget: Bool = true
    ) throws
        -> ROBArmControlDecodedMessage?
    {
        guard !data.isEmpty else { return nil }
        guard data.count <= ROBArmControlProtocol.maximumMessageBytes else {
            throw ROBArmControlWireError.oversized
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        guard let protocolName = dictionary["protocol"] as? String,
              protocolName == ROBArmControlProtocol.name else { return nil }
        guard let type = dictionary["type"] as? String else {
            throw ROBArmControlWireError.malformed
        }

        let decoder = JSONDecoder()
        switch type {
        case "measured_state":
            guard Set(dictionary.keys).isSubset(of: measuredKeys) else {
                throw ROBArmControlWireError.unexpectedFields
            }
            let message = try decode(ROBArmMeasuredState.self, from: data, decoder: decoder)
            if let error = message.validationError { throw ROBArmControlWireError.invalid(error) }
            return .measuredState(message)

        case "target_intent":
            guard Set(dictionary.keys).isSubset(of: targetKeys) else {
                throw ROBArmControlWireError.unexpectedFields
            }
            let message = try decode(ROBArmTargetIntentEnvelope.self, from: data, decoder: decoder)
            if let error = message.boundsValidationError
                ?? (requireFreshTarget
                    ? message.freshnessValidationError(nowUnixMilliseconds: nowUnixMilliseconds)
                    : nil)
            {
                throw ROBArmControlWireError.invalid(error)
            }
            return .targetIntent(message)

        case "authority_intent":
            guard Set(dictionary.keys).isSubset(of: authorityIntentKeys) else {
                throw ROBArmControlWireError.unexpectedFields
            }
            let message = try decode(
                ROBArmAuthorityIntentEnvelope.self,
                from: data,
                decoder: decoder
            )
            if let error = message.validationError
                ?? message.freshnessValidationError(nowUnixMilliseconds: nowUnixMilliseconds) {
                throw ROBArmControlWireError.invalid(error)
            }
            return .authorityIntent(message)

        case "authority_state":
            guard Set(dictionary.keys).isSubset(of: authorityStateKeys) else {
                throw ROBArmControlWireError.unexpectedFields
            }
            let message = try decode(
                ROBArmAuthorityStateEnvelope.self,
                from: data,
                decoder: decoder
            )
            if let error = message.validationError { throw ROBArmControlWireError.invalid(error) }
            return .authorityState(message)

        case "hold_intent":
            guard Set(dictionary.keys).isSubset(of: holdKeys) else {
                throw ROBArmControlWireError.unexpectedFields
            }
            let message = try decode(
                ROBArmHoldIntentEnvelope.self,
                from: data,
                decoder: decoder
            )
            if let error = message.validationError { throw ROBArmControlWireError.invalid(error) }
            return .holdIntent(message)

        case "target_disposition":
            guard Set(dictionary.keys).isSubset(of: dispositionKeys) else {
                throw ROBArmControlWireError.unexpectedFields
            }
            let message = try decode(
                ROBArmTargetDispositionEnvelope.self,
                from: data,
                decoder: decoder
            )
            if let error = message.validationError { throw ROBArmControlWireError.invalid(error) }
            return .targetDisposition(message)

        default:
            throw ROBArmControlWireError.unknownType
        }
    }

    static func encode(_ message: ROBArmMeasuredState) throws -> Data {
        guard message.validationError == nil else {
            throw ROBArmControlWireError.invalid(message.validationError ?? "invalid measured state")
        }
        return try encodeBounded(message)
    }

    static func encode(
        _ message: ROBArmTargetIntentEnvelope,
        nowUnixMilliseconds: Int64 = currentUnixMilliseconds()
    ) throws -> Data {
        guard message.validationError(nowUnixMilliseconds: nowUnixMilliseconds) == nil else {
            throw ROBArmControlWireError.invalid(
                message.validationError(nowUnixMilliseconds: nowUnixMilliseconds)
                    ?? "invalid target intent"
            )
        }
        return try encodeBounded(message)
    }

    static func encode(_ message: ROBArmAuthorityIntentEnvelope) throws -> Data {
        guard message.validationError == nil else {
            throw ROBArmControlWireError.invalid(message.validationError ?? "invalid authority intent")
        }
        return try encodeBounded(message)
    }

    static func encode(_ message: ROBArmAuthorityStateEnvelope) throws -> Data {
        guard message.validationError == nil else {
            throw ROBArmControlWireError.invalid(message.validationError ?? "invalid authority state")
        }
        return try encodeBounded(message)
    }

    static func encode(_ message: ROBArmHoldIntentEnvelope) throws -> Data {
        guard message.validationError == nil else {
            throw ROBArmControlWireError.invalid(message.validationError ?? "invalid hold intent")
        }
        return try encodeBounded(message)
    }

    static func encode(_ message: ROBArmTargetDispositionEnvelope) throws -> Data {
        guard message.validationError == nil else {
            throw ROBArmControlWireError.invalid(message.validationError ?? "invalid disposition")
        }
        return try encodeBounded(message)
    }

    static func currentUnixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder
    ) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw ROBArmControlWireError.malformed }
    }

    private static func encodeBounded<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(message) }
        catch { throw ROBArmControlWireError.malformed }
        guard data.count <= ROBArmControlProtocol.maximumMessageBytes else {
            throw ROBArmControlWireError.oversized
        }
        return data
    }

    private static func containsRawProtocolMember(_ bytes: [UInt8]) -> Bool {
        let shortestValueCount = rawProtocolValues.map(\.count).min() ?? 0
        guard bytes.count >= rawProtocolKey.count + shortestValueCount + 1 else {
            return false
        }
        var searchIndex = 0
        while searchIndex + rawProtocolKey.count <= bytes.count {
            guard bytes[searchIndex ..< searchIndex + rawProtocolKey.count]
                    .elementsEqual(rawProtocolKey) else {
                searchIndex += 1
                continue
            }
            var cursor = searchIndex + rawProtocolKey.count
            skipJSONWhitespace(in: bytes, cursor: &cursor)
            guard cursor < bytes.count, bytes[cursor] == 0x3A else {
                searchIndex += 1
                continue
            }
            cursor += 1
            skipJSONWhitespace(in: bytes, cursor: &cursor)
            if rawProtocolValues.contains(where: { value in
                cursor + value.count <= bytes.count
                    && bytes[cursor ..< cursor + value.count].elementsEqual(value)
            }) {
                return true
            }
            searchIndex += 1
        }
        return false
    }

    private static func skipJSONWhitespace(in bytes: [UInt8], cursor: inout Int) {
        while cursor < bytes.count,
              bytes[cursor] == 0x20 || bytes[cursor] == 0x09
                || bytes[cursor] == 0x0A || bytes[cursor] == 0x0D {
            cursor += 1
        }
    }
}

struct ROBArmTargetGateDecision: Equatable {
    let disposition: ROBArmTargetDispositionKind
    let detail: String
    let advancesSequence: Bool
    /// Admission is still not completion. The bridge must obtain a positive
    /// gateway acknowledgement and measured settling before reporting success.
    let passedExecutionPreflight: Bool
}

struct ROBArmTargetExecutionContext: Equatable {
    static let maximumTelemetryAgeMilliseconds = 250.0
    static let requiredPositionMode = 2
    static let maximumUpdateDeltaRadians = 0.10
    static let maximumAverageSpeedRadiansPerSecond = 0.20

    let authenticatedSessionIsCurrent: Bool
    let measuredPositionsRadians: [Double]?
    let effectiveTelemetryAgeMilliseconds: Double?
    let modes: [Int]
    let armHasInFlightTarget: Bool
}

enum ROBArmTargetGateEvaluator {
    static func evaluate(
        _ target: ROBArmTargetIntentEnvelope,
        authenticatedControllerID: UUID,
        authenticatedSessionID: UUID,
        lastAcceptedSequence: UInt64,
        authorityEnabled: Bool,
        executionContext: ROBArmTargetExecutionContext,
        nowUnixMilliseconds: Int64
    ) -> ROBArmTargetGateDecision {
        if target.boundsValidationError != nil {
            return ROBArmTargetGateDecision(
                disposition: .rejectedInvalid,
                detail: "Target exceeded the calibrated B1 per-joint, duration, or lease bounds.",
                advancesSequence: false,
                passedExecutionPreflight: false
            )
        }
        if target.senderID != authenticatedControllerID
            || target.sessionID != authenticatedSessionID
        {
            return ROBArmTargetGateDecision(
                disposition: .rejectedIdentityMismatch,
                detail: "Target identity or control session did not match the authenticated connection.",
                advancesSequence: false,
                passedExecutionPreflight: false
            )
        }
        if target.freshnessValidationError(nowUnixMilliseconds: nowUnixMilliseconds) != nil {
            return ROBArmTargetGateDecision(
                disposition: .rejectedExpired,
                detail: "Target lease expired or its timestamp was outside the allowed clock window.",
                advancesSequence: false,
                passedExecutionPreflight: false
            )
        }
        if target.sequence <= lastAcceptedSequence {
            return ROBArmTargetGateDecision(
                disposition: .rejectedStaleSequence,
                detail: "Target sequence was stale or replayed.",
                advancesSequence: false,
                passedExecutionPreflight: false
            )
        }
        if !authorityEnabled {
            return ROBArmTargetGateDecision(
                disposition: .rejectedAuthorityDisabled,
                detail: "Cerebro's local, time-limited controller arm authority is disabled.",
                advancesSequence: true,
                passedExecutionPreflight: false
            )
        }
        if !executionContext.authenticatedSessionIsCurrent {
            return ROBArmTargetGateDecision(
                disposition: .rejectedSessionInactive,
                detail: "The authenticated ROBControl session is no longer current.",
                advancesSequence: true,
                passedExecutionPreflight: false
            )
        }
        guard let measured = executionContext.measuredPositionsRadians,
              measured.count == ROBArmControlProtocol.jointCount,
              measured.allSatisfy(\.isFinite),
              let telemetryAge = executionContext.effectiveTelemetryAgeMilliseconds,
              telemetryAge.isFinite,
              (0 ... ROBArmTargetExecutionContext.maximumTelemetryAgeMilliseconds)
                .contains(telemetryAge) else {
            return ROBArmTargetGateDecision(
                disposition: .rejectedTelemetryStale,
                detail: "Fresh seven-joint measured telemetry (250 ms or newer) is required.",
                advancesSequence: true,
                passedExecutionPreflight: false
            )
        }
        guard executionContext.modes.count == ROBArmControlProtocol.jointCount,
              executionContext.modes.allSatisfy({
                  $0 == ROBArmTargetExecutionContext.requiredPositionMode
              }) else {
            return ROBArmTargetGateDecision(
                disposition: .rejectedPositionModeRequired,
                detail: "All seven joints must be verified in Amber position mode.",
                advancesSequence: true,
                passedExecutionPreflight: false
            )
        }
        if executionContext.armHasInFlightTarget {
            return ROBArmTargetGateDecision(
                disposition: .rejectedArmBusy,
                detail: "The arm already has an in-flight controller target.",
                advancesSequence: true,
                passedExecutionPreflight: false
            )
        }
        let deltas = zip(measured, target.positionsRadians).map { abs($0 - $1) }
        guard deltas.allSatisfy({
            $0 / target.durationSeconds
                <= ROBArmTargetExecutionContext.maximumAverageSpeedRadiansPerSecond
        }) else {
            return ROBArmTargetGateDecision(
                disposition: .rejectedSpeedLimit,
                detail: "A joint exceeded the 0.20-radian-per-second average speed limit.",
                advancesSequence: true,
                passedExecutionPreflight: false
            )
        }
        guard deltas.allSatisfy({
            $0 <= ROBArmTargetExecutionContext.maximumUpdateDeltaRadians
        }) else {
            return ROBArmTargetGateDecision(
                disposition: .rejectedStepLimit,
                detail: "A joint exceeded the 0.10-radian controller update limit.",
                advancesSequence: true,
                passedExecutionPreflight: false
            )
        }
        return ROBArmTargetGateDecision(
            disposition: .acceptedForExecution,
            detail: "Target passed controller preflight and is entering the leased Amber executor.",
            advancesSequence: true,
            passedExecutionPreflight: true
        )
    }
}
