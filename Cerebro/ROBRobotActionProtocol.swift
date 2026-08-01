//
//  ROBRobotActionProtocol.swift
//  Cerebro / ROBController
//
//  Versioned, backward-compatible action coordination messages carried inside
//  the existing AutoNet keyed-archive envelope.
//

import Foundation

@objc public enum ROBRobotActionMessageKind: Int {
    case controllerHello
    case actionRequest
    case actionStatus
    case actionCancel
}

@objc public enum ROBRobotActionState: Int {
    case none
    case pending
    case accepted
    case executing
    case completed
    case rejected
    case cancelled
    case failed
    case expired
}

@objcMembers
public final class ROBRobotActionMessage: NSObject {
    public static let schemaIdentifier = "com.orbitusrobotics.robot-action"
    public static let currentVersion = 1
    public static let envelopeMarker = "ROBRobotActionProtocol.v1"
    public static let supportedActions = [
        "look_at",
        "play_gesture",
        "request_pick",
        "navigate_relative",
        "stop_motion"
    ]

    public let kind: ROBRobotActionMessageKind
    public let messageID: String
    public let callID: String?
    public let senderID: String
    public let recipientID: String?
    public let sentAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let action: String?
    public let arguments: NSDictionary
    public let state: ROBRobotActionState
    public let detail: String?
    public let result: NSDictionary
    public let acceptsActions: Bool
    public let capabilities: [String]

    public var isExpired: Bool {
        expiresAtMilliseconds > 0 && Self.nowMilliseconds >= expiresAtMilliseconds
    }

    public var isTerminal: Bool {
        switch state {
        case .completed, .rejected, .cancelled, .failed, .expired:
            return true
        default:
            return false
        }
    }

    public var validationError: String? {
        guard !messageID.isEmpty, messageID.count <= 128 else {
            return "message_id is missing or too long"
        }
        guard !senderID.isEmpty, senderID.count <= 128 else {
            return "sender_id is missing or too long"
        }
        if let recipientID, recipientID.isEmpty || recipientID.count > 128 {
            return "recipient_id is empty or too long"
        }
        if let detail, detail.count > 2_048 {
            return "detail exceeds 2048 characters"
        }

        switch kind {
        case .controllerHello:
            return nil

        case .actionRequest:
            guard let callID, !callID.isEmpty, callID.count <= 128 else {
                return "call_id is missing or too long"
            }
            guard let action, Self.supportedActions.contains(action) else {
                return "action is unsupported"
            }
            guard expiresAtMilliseconds > sentAtMilliseconds else {
                return "action request has no valid deadline"
            }
            guard expiresAtMilliseconds - sentAtMilliseconds <= 120_000 else {
                return "action request deadline exceeds 120 seconds"
            }
            return Self.validateArguments(arguments, for: action)

        case .actionStatus:
            guard let callID, !callID.isEmpty, callID.count <= 128 else {
                return "call_id is missing or too long"
            }
            guard state != .none else {
                return "action status is missing state"
            }
            return nil

        case .actionCancel:
            guard let callID, !callID.isEmpty, callID.count <= 128 else {
                return "call_id is missing or too long"
            }
            return nil
        }
    }

    private init(
        kind: ROBRobotActionMessageKind,
        messageID: String = UUID().uuidString,
        callID: String? = nil,
        senderID: String,
        recipientID: String? = nil,
        sentAtMilliseconds: Int64 = ROBRobotActionMessage.nowMilliseconds,
        expiresAtMilliseconds: Int64 = 0,
        action: String? = nil,
        arguments: NSDictionary = [:],
        state: ROBRobotActionState = .none,
        detail: String? = nil,
        result: NSDictionary = [:],
        acceptsActions: Bool = false,
        capabilities: [String] = []
    ) {
        self.kind = kind
        self.messageID = messageID
        self.callID = callID
        self.senderID = senderID
        self.recipientID = recipientID
        self.sentAtMilliseconds = sentAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.action = action
        self.arguments = arguments.copy() as? NSDictionary ?? [:]
        self.state = state
        self.detail = detail
        self.result = result.copy() as? NSDictionary ?? [:]
        self.acceptsActions = acceptsActions
        self.capabilities = Array(capabilities)
        super.init()
    }

    @objc(controllerHelloWithSenderID:acceptsActions:capabilities:)
    public static func controllerHello(
        senderID: String,
        acceptsActions: Bool,
        capabilities: [String]
    ) -> ROBRobotActionMessage {
        ROBRobotActionMessage(
            kind: .controllerHello,
            senderID: senderID,
            acceptsActions: acceptsActions,
            capabilities: capabilities
        )
    }

    @objc(actionRequestWithCallID:action:arguments:senderID:recipientID:expiresAt:)
    public static func actionRequest(
        callID: String,
        action: String,
        arguments: NSDictionary,
        senderID: String,
        recipientID: String?,
        expiresAt: Date
    ) -> ROBRobotActionMessage {
        ROBRobotActionMessage(
            kind: .actionRequest,
            callID: callID,
            senderID: senderID,
            recipientID: recipientID,
            expiresAtMilliseconds: milliseconds(for: expiresAt),
            action: action,
            arguments: arguments,
            state: .pending
        )
    }

    @objc(actionStatusWithCallID:state:detail:result:senderID:recipientID:)
    public static func actionStatus(
        callID: String,
        state: ROBRobotActionState,
        detail: String?,
        result: NSDictionary,
        senderID: String,
        recipientID: String?
    ) -> ROBRobotActionMessage {
        ROBRobotActionMessage(
            kind: .actionStatus,
            callID: callID,
            senderID: senderID,
            recipientID: recipientID,
            state: state,
            detail: detail,
            result: result
        )
    }

    @objc(actionCancelWithCallID:reason:senderID:recipientID:)
    public static func actionCancel(
        callID: String,
        reason: String,
        senderID: String,
        recipientID: String?
    ) -> ROBRobotActionMessage {
        ROBRobotActionMessage(
            kind: .actionCancel,
            callID: callID,
            senderID: senderID,
            recipientID: recipientID,
            state: .cancelled,
            detail: reason
        )
    }

    fileprivate func encodedJSONData() throws -> Data {
        if let validationError {
            throw ROBRobotActionProtocolError.invalidMessage(validationError)
        }

        var object: [String: Any] = [
            "schema": Self.schemaIdentifier,
            "version": Self.currentVersion,
            "message_id": messageID,
            "kind": Self.string(for: kind),
            "sender_id": senderID,
            "sent_at_ms": sentAtMilliseconds
        ]
        if let recipientID, !recipientID.isEmpty {
            object["recipient_id"] = recipientID
        }
        if let callID {
            object["call_id"] = callID
        }
        if expiresAtMilliseconds > 0 {
            object["expires_at_ms"] = expiresAtMilliseconds
        }
        if let action {
            object["action"] = action
            object["arguments"] = arguments
        }
        if state != .none {
            object["state"] = Self.string(for: state)
        }
        if let detail, !detail.isEmpty {
            object["detail"] = detail
        }
        if result.count > 0 {
            object["result"] = result
        }
        if kind == .controllerHello {
            object["accepts_actions"] = acceptsActions
            object["capabilities"] = capabilities
        }

        guard JSONSerialization.isValidJSONObject(object) else {
            throw ROBRobotActionProtocolError.invalidMessage("message contains non-JSON values")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 65_536 else {
            throw ROBRobotActionProtocolError.invalidMessage("payload exceeds 64 KiB")
        }
        return data
    }

    fileprivate static func decodeJSONData(_ data: Data) throws -> ROBRobotActionMessage {
        guard !data.isEmpty, data.count <= 65_536 else {
            throw ROBRobotActionProtocolError.invalidMessage("payload is empty or exceeds 64 KiB")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any],
              object["schema"] as? String == schemaIdentifier,
              (object["version"] as? NSNumber)?.intValue == currentVersion,
              let kindString = object["kind"] as? String,
              let kind = kind(from: kindString),
              let messageID = object["message_id"] as? String,
              let senderID = object["sender_id"] as? String,
              let sentAt = (object["sent_at_ms"] as? NSNumber)?.int64Value else {
            throw ROBRobotActionProtocolError.invalidMessage("required protocol fields are missing")
        }

        let stateString = object["state"] as? String
        let state = stateString.flatMap(state(from:)) ?? .none
        if stateString != nil, state == .none {
            throw ROBRobotActionProtocolError.invalidMessage("state is unsupported")
        }

        let message = ROBRobotActionMessage(
            kind: kind,
            messageID: messageID,
            callID: object["call_id"] as? String,
            senderID: senderID,
            recipientID: object["recipient_id"] as? String,
            sentAtMilliseconds: sentAt,
            expiresAtMilliseconds: (object["expires_at_ms"] as? NSNumber)?.int64Value ?? 0,
            action: object["action"] as? String,
            arguments: object["arguments"] as? NSDictionary ?? [:],
            state: state,
            detail: object["detail"] as? String,
            result: object["result"] as? NSDictionary ?? [:],
            acceptsActions: object["accepts_actions"] as? Bool ?? false,
            capabilities: object["capabilities"] as? [String] ?? []
        )
        if let validationError = message.validationError {
            throw ROBRobotActionProtocolError.invalidMessage(validationError)
        }
        return message
    }

    private static var nowMilliseconds: Int64 {
        milliseconds(for: Date())
    }

    private static func milliseconds(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func validateArguments(_ arguments: NSDictionary, for action: String) -> String? {
        switch action {
        case "look_at", "request_pick":
            guard let targetID = arguments["target_id"] as? String,
                  !targetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  targetID.count <= 256 else {
                return "\(action) requires target_id"
            }

        case "play_gesture":
            guard let gesture = arguments["gesture"] as? String,
                  !gesture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  gesture.count <= 128 else {
                return "play_gesture requires gesture"
            }

        case "navigate_relative":
            guard let distance = finiteDouble(arguments["distance_m"]),
                  (-1.0 ... 1.0).contains(distance) else {
                return "navigate_relative distance_m must be between -1 and 1"
            }
            guard let yaw = finiteDouble(arguments["yaw_rad"]),
                  (-Double.pi ... Double.pi).contains(yaw) else {
                return "navigate_relative yaw_rad must be between -pi and pi"
            }
            guard let speed = finiteDouble(arguments["speed_scale"]),
                  (0.0 ... 0.35).contains(speed) else {
                return "navigate_relative speed_scale must be between 0 and 0.35"
            }

        case "stop_motion":
            break

        default:
            return "action is unsupported"
        }
        return nil
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func string(for kind: ROBRobotActionMessageKind) -> String {
        switch kind {
        case .controllerHello: return "controller_hello"
        case .actionRequest: return "action_request"
        case .actionStatus: return "action_status"
        case .actionCancel: return "action_cancel"
        }
    }

    private static func kind(from string: String) -> ROBRobotActionMessageKind? {
        switch string {
        case "controller_hello": return .controllerHello
        case "action_request": return .actionRequest
        case "action_status": return .actionStatus
        case "action_cancel": return .actionCancel
        default: return nil
        }
    }

    private static func string(for state: ROBRobotActionState) -> String {
        switch state {
        case .none: return "none"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .executing: return "executing"
        case .completed: return "completed"
        case .rejected: return "rejected"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .expired: return "expired"
        }
    }

    private static func state(from string: String) -> ROBRobotActionState? {
        switch string {
        case "pending": return .pending
        case "accepted": return .accepted
        case "executing": return .executing
        case "completed": return .completed
        case "rejected": return .rejected
        case "cancelled": return .cancelled
        case "failed": return .failed
        case "expired": return .expired
        default: return nil
        }
    }
}

@objcMembers
public final class ROBRobotActionWireCodec: NSObject {
    @objc(archiveMessage:legacySender:)
    public static func archive(
        _ message: ROBRobotActionMessage,
        legacySender: String
    ) -> NSData? {
        guard legacySender == message.senderID,
              let payload = try? message.encodedJSONData() else {
            return nil
        }
        let envelope: NSDictionary = [
            "message": ROBRobotActionMessage.envelopeMarker,
            "sender": legacySender,
            "robot_action": payload
        ]
        return try? NSKeyedArchiver.archivedData(
            withRootObject: envelope,
            requiringSecureCoding: false
        ) as NSData
    }

    @objc(decodeEnvelopeData:)
    public static func decodeEnvelopeData(_ data: NSData) -> ROBRobotActionMessage? {
        let allowedClasses: [AnyClass] = [NSDictionary.self, NSString.self, NSData.self]
        guard let envelope = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: allowedClasses,
            from: data as Data
        ) as? NSDictionary,
        envelope["message"] as? String == ROBRobotActionMessage.envelopeMarker,
        let legacySender = envelope["sender"] as? String,
        let payload = envelope["robot_action"] as? Data,
        let message = try? ROBRobotActionMessage.decodeJSONData(payload),
        message.senderID == legacySender else {
            return nil
        }
        return message
    }
}

private enum ROBRobotActionProtocolError: LocalizedError {
    case invalidMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let reason):
            return "Invalid robot action message: \(reason)"
        }
    }
}

// MARK: - Controller-activated autonomy sessions

/// Autonomy is authorized once per bounded session, not once per gesture or
/// planner tick. TLS pairing authenticates the transport; this message binds
/// the operator choice to one robot, profile, area, duration, and sequence.
@objc public enum ROBAutonomySessionMessageKind: Int {
    case start
    case stop
    case status
}

@objc public enum ROBAutonomySessionState: Int {
    case inactive
    case active
    case stopping
    case unavailable
}

@objc public enum ROBAutonomyProfile: Int {
    case expressiveStationary
    case socialRoam
}

@objcMembers
public final class ROBAutonomySessionMessage: NSObject {
    public static let schemaIdentifier = "com.orbitusrobotics.autonomy-session"
    public static let currentVersion = 1
    public static let envelopeMarker = "ROBAutonomySessionProtocol.v1"
    public static let maximumSessionDuration: TimeInterval = 12 * 60 * 60
    public static let supportedBehaviors = [
        "talk",
        "look_at_person",
        "idle_gesture",
        "roam",
        "stop_motion"
    ]

    public let kind: ROBAutonomySessionMessageKind
    public let messageID: String
    public let sessionID: String
    public let sequence: UInt64
    public let senderID: String
    public let recipientID: String?
    public let sentAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let profile: ROBAutonomyProfile
    public let zoneRadiusMeters: Double
    public let maximumSpeedScale: Double
    public let behaviors: [String]
    public let state: ROBAutonomySessionState
    public let detail: String?

    public var isExpired: Bool {
        expiresAtMilliseconds > 0 && Self.nowMilliseconds >= expiresAtMilliseconds
    }

    public var validationError: String? {
        guard !messageID.isEmpty, messageID.count <= 128 else {
            return "message_id is missing or too long"
        }
        guard !sessionID.isEmpty, sessionID.count <= 128 else {
            return "session_id is missing or too long"
        }
        guard sequence > 0 else {
            return "sequence must be positive"
        }
        guard !senderID.isEmpty, senderID.count <= 128 else {
            return "sender_id is missing or too long"
        }
        if let recipientID, recipientID.isEmpty || recipientID.count > 128 {
            return "recipient_id is empty or too long"
        }
        if let detail, detail.count > 2_048 {
            return "detail exceeds 2048 characters"
        }
        guard Set(behaviors).count == behaviors.count,
              behaviors.allSatisfy(Self.supportedBehaviors.contains) else {
            return "behaviors contain duplicates or unsupported values"
        }

        switch kind {
        case .start:
            guard expiresAtMilliseconds > sentAtMilliseconds else {
                return "autonomy session has no valid expiry"
            }
            guard expiresAtMilliseconds - sentAtMilliseconds <= Int64(Self.maximumSessionDuration * 1_000) else {
                return "autonomy session exceeds 12 hours"
            }
            guard zoneRadiusMeters.isFinite, (0.5 ... 50.0).contains(zoneRadiusMeters) else {
                return "zone radius must be between 0.5 and 50 meters"
            }
            guard maximumSpeedScale.isFinite, (0.05 ... 0.35).contains(maximumSpeedScale) else {
                return "maximum speed scale must be between 0.05 and 0.35"
            }
            if profile == .socialRoam, !behaviors.contains("roam") {
                return "social roam requires the roam behavior"
            }
            return nil

        case .stop:
            return nil

        case .status:
            return nil
        }
    }

    private init(
        kind: ROBAutonomySessionMessageKind,
        messageID: String = UUID().uuidString,
        sessionID: String,
        sequence: UInt64,
        senderID: String,
        recipientID: String?,
        sentAtMilliseconds: Int64 = ROBAutonomySessionMessage.nowMilliseconds,
        expiresAtMilliseconds: Int64,
        profile: ROBAutonomyProfile,
        zoneRadiusMeters: Double,
        maximumSpeedScale: Double,
        behaviors: [String],
        state: ROBAutonomySessionState,
        detail: String?
    ) {
        self.kind = kind
        self.messageID = messageID
        self.sessionID = sessionID
        self.sequence = sequence
        self.senderID = senderID
        self.recipientID = recipientID
        self.sentAtMilliseconds = sentAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.profile = profile
        self.zoneRadiusMeters = zoneRadiusMeters
        self.maximumSpeedScale = maximumSpeedScale
        self.behaviors = Array(behaviors)
        self.state = state
        self.detail = detail
        super.init()
    }

    @objc(startWithSessionID:sequence:senderID:recipientID:profile:zoneRadiusMeters:maximumSpeedScale:behaviors:expiresAt:)
    public static func start(
        sessionID: String,
        sequence: UInt64,
        senderID: String,
        recipientID: String?,
        profile: ROBAutonomyProfile,
        zoneRadiusMeters: Double,
        maximumSpeedScale: Double,
        behaviors: [String],
        expiresAt: Date
    ) -> ROBAutonomySessionMessage {
        return ROBAutonomySessionMessage(
            kind: .start,
            sessionID: sessionID,
            sequence: sequence,
            senderID: senderID,
            recipientID: recipientID,
            expiresAtMilliseconds: milliseconds(for: expiresAt),
            profile: profile,
            zoneRadiusMeters: zoneRadiusMeters,
            maximumSpeedScale: maximumSpeedScale,
            behaviors: behaviors,
            state: .active,
            detail: nil
        )
    }

    @objc(stopWithSessionID:sequence:senderID:recipientID:reason:)
    public static func stop(
        sessionID: String,
        sequence: UInt64,
        senderID: String,
        recipientID: String?,
        reason: String
    ) -> ROBAutonomySessionMessage {
        return ROBAutonomySessionMessage(
            kind: .stop,
            sessionID: sessionID,
            sequence: sequence,
            senderID: senderID,
            recipientID: recipientID,
            expiresAtMilliseconds: milliseconds(for: Date(timeIntervalSinceNow: 30)),
            profile: .expressiveStationary,
            zoneRadiusMeters: 0,
            maximumSpeedScale: 0,
            behaviors: [],
            state: .stopping,
            detail: reason
        )
    }

    @objc(statusWithSessionID:sequence:senderID:recipientID:profile:zoneRadiusMeters:maximumSpeedScale:behaviors:state:expiresAt:detail:)
    public static func status(
        sessionID: String,
        sequence: UInt64,
        senderID: String,
        recipientID: String?,
        profile: ROBAutonomyProfile,
        zoneRadiusMeters: Double,
        maximumSpeedScale: Double,
        behaviors: [String],
        state: ROBAutonomySessionState,
        expiresAt: Date?,
        detail: String?
    ) -> ROBAutonomySessionMessage {
        return ROBAutonomySessionMessage(
            kind: .status,
            sessionID: sessionID,
            sequence: sequence,
            senderID: senderID,
            recipientID: recipientID,
            expiresAtMilliseconds: expiresAt.map(milliseconds(for:)) ?? 0,
            profile: profile,
            zoneRadiusMeters: zoneRadiusMeters,
            maximumSpeedScale: maximumSpeedScale,
            behaviors: behaviors,
            state: state,
            detail: detail
        )
    }

    fileprivate func encodedJSONData() throws -> Data {
        if let validationError {
            throw ROBAutonomySessionProtocolError.invalidMessage(validationError)
        }
        var object: [String: Any] = [
            "schema": Self.schemaIdentifier,
            "version": Self.currentVersion,
            "kind": Self.string(for: kind),
            "message_id": messageID,
            "session_id": sessionID,
            "sequence": sequence,
            "sender_id": senderID,
            "sent_at_ms": sentAtMilliseconds,
            "profile": Self.string(for: profile),
            "zone_radius_m": zoneRadiusMeters,
            "maximum_speed_scale": maximumSpeedScale,
            "behaviors": behaviors,
            "state": Self.string(for: state)
        ]
        if let recipientID, !recipientID.isEmpty { object["recipient_id"] = recipientID }
        if expiresAtMilliseconds > 0 { object["expires_at_ms"] = expiresAtMilliseconds }
        if let detail, !detail.isEmpty { object["detail"] = detail }

        guard JSONSerialization.isValidJSONObject(object) else {
            throw ROBAutonomySessionProtocolError.invalidMessage("message contains non-JSON values")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 16_384 else {
            throw ROBAutonomySessionProtocolError.invalidMessage("payload exceeds 16 KiB")
        }
        return data
    }

    fileprivate static func decodeJSONData(_ data: Data) throws -> ROBAutonomySessionMessage {
        guard !data.isEmpty, data.count <= 16_384 else {
            throw ROBAutonomySessionProtocolError.invalidMessage("payload is empty or exceeds 16 KiB")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any],
              object["schema"] as? String == schemaIdentifier,
              (object["version"] as? NSNumber)?.intValue == currentVersion,
              let kindName = object["kind"] as? String,
              let kind = kind(from: kindName),
              let messageID = object["message_id"] as? String,
              let sessionID = object["session_id"] as? String,
              let sequenceNumber = object["sequence"] as? NSNumber,
              sequenceNumber.uint64Value > 0,
              let senderID = object["sender_id"] as? String,
              let sentAt = (object["sent_at_ms"] as? NSNumber)?.int64Value,
              let profileName = object["profile"] as? String,
              let profile = profile(from: profileName),
              let stateName = object["state"] as? String,
              let state = state(from: stateName) else {
            throw ROBAutonomySessionProtocolError.invalidMessage("required protocol fields are missing")
        }

        let message = ROBAutonomySessionMessage(
            kind: kind,
            messageID: messageID,
            sessionID: sessionID,
            sequence: sequenceNumber.uint64Value,
            senderID: senderID,
            recipientID: object["recipient_id"] as? String,
            sentAtMilliseconds: sentAt,
            expiresAtMilliseconds: (object["expires_at_ms"] as? NSNumber)?.int64Value ?? 0,
            profile: profile,
            zoneRadiusMeters: (object["zone_radius_m"] as? NSNumber)?.doubleValue ?? 0,
            maximumSpeedScale: (object["maximum_speed_scale"] as? NSNumber)?.doubleValue ?? 0,
            behaviors: object["behaviors"] as? [String] ?? [],
            state: state,
            detail: object["detail"] as? String
        )
        if let validationError = message.validationError {
            throw ROBAutonomySessionProtocolError.invalidMessage(validationError)
        }
        return message
    }

    private static var nowMilliseconds: Int64 { milliseconds(for: Date()) }

    private static func milliseconds(for date: Date) -> Int64 {
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func string(for kind: ROBAutonomySessionMessageKind) -> String {
        switch kind {
        case .start: return "start"
        case .stop: return "stop"
        case .status: return "status"
        }
    }

    private static func kind(from string: String) -> ROBAutonomySessionMessageKind? {
        switch string {
        case "start": return .start
        case "stop": return .stop
        case "status": return .status
        default: return nil
        }
    }

    private static func string(for profile: ROBAutonomyProfile) -> String {
        switch profile {
        case .expressiveStationary: return "expressive_stationary"
        case .socialRoam: return "social_roam"
        }
    }

    private static func profile(from string: String) -> ROBAutonomyProfile? {
        switch string {
        case "expressive_stationary": return .expressiveStationary
        case "social_roam": return .socialRoam
        default: return nil
        }
    }

    private static func string(for state: ROBAutonomySessionState) -> String {
        switch state {
        case .inactive: return "inactive"
        case .active: return "active"
        case .stopping: return "stopping"
        case .unavailable: return "unavailable"
        }
    }

    private static func state(from string: String) -> ROBAutonomySessionState? {
        switch string {
        case "inactive": return .inactive
        case "active": return .active
        case "stopping": return .stopping
        case "unavailable": return .unavailable
        default: return nil
        }
    }
}

@objcMembers
public final class ROBAutonomySessionWireCodec: NSObject {
    @objc(archiveMessage:legacySender:)
    public static func archive(
        _ message: ROBAutonomySessionMessage,
        legacySender: String
    ) -> NSData? {
        guard legacySender == message.senderID,
              let payload = try? message.encodedJSONData() else {
            return nil
        }
        let envelope: NSDictionary = [
            "message": ROBAutonomySessionMessage.envelopeMarker,
            "sender": legacySender,
            "autonomy_session": payload
        ]
        return try? NSKeyedArchiver.archivedData(
            withRootObject: envelope,
            requiringSecureCoding: false
        ) as NSData
    }

    @objc(decodeEnvelopeData:)
    public static func decodeEnvelopeData(_ data: NSData) -> ROBAutonomySessionMessage? {
        let allowedClasses: [AnyClass] = [NSDictionary.self, NSString.self, NSData.self]
        guard let envelope = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: allowedClasses,
            from: data as Data
        ) as? NSDictionary,
        envelope["message"] as? String == ROBAutonomySessionMessage.envelopeMarker,
        let legacySender = envelope["sender"] as? String,
        let payload = envelope["autonomy_session"] as? Data,
        let message = try? ROBAutonomySessionMessage.decodeJSONData(payload),
        message.senderID == legacySender else {
            return nil
        }
        return message
    }
}

private enum ROBAutonomySessionProtocolError: LocalizedError {
    case invalidMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let reason):
            return "Invalid autonomy session message: \(reason)"
        }
    }
}
