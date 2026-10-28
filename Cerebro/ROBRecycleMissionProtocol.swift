import Foundation

/// Shared by Cerebro and ROBController. A mission Start is the operator's
/// bounded task authorization; it is never an actuator command or arm receipt.
struct ROBRecycleMissionMessage: Codable, Equatable {
    static let prefix = Data("ROBRecycleMission.v1\n".utf8)
    enum Kind: String, Codable { case start, stop, status, query, confirmEmpty }
    enum Phase: String, Codable {
        case idle, acquiringMap, searching, navigating, recycling, paused, stopped, finished
    }
    struct Configuration: Codable, Equatable {
        var destination = "orange_bucket"
        var radiusMeters = 5.0
        var maximumCans = 8
        var durationSeconds = 1800
        var maximumTreadDemand = 0.40
        var valid: Bool {
            destination == "orange_bucket" && radiusMeters.isFinite && (1...10).contains(radiusMeters)
                && (1...8).contains(maximumCans) && (60...3600).contains(durationSeconds)
                && maximumTreadDemand.isFinite && (0.30...0.50).contains(maximumTreadDemand)
        }
    }
    var version = 1
    var kind: Kind
    var missionID: UUID
    var sequence: UInt64
    var sentAtMilliseconds: Double
    var configuration: Configuration
    var phase: Phase = .idle
    var detail = ""
    var verifiedTransfers = 0
    var searchedStops = 0
    var possiblePayloadHeld = false
    var active = false

    var valid: Bool {
        version == 1 && sequence > 0 && sentAtMilliseconds.isFinite && sentAtMilliseconds > 0
            && configuration.valid && detail.count <= 2048 && (0...8).contains(verifiedTransfers)
            && (0...256).contains(searchedStops)
    }
    func encoded() -> Data? {
        guard valid, let json = try? JSONEncoder().encode(self), json.count <= 8192 else { return nil }
        return Self.prefix + json
    }
    static func claims(_ data: Data) -> Bool { data.starts(with: Data("ROBRecycleMission.".utf8)) }
    static func decode(_ data: Data) -> Self? {
        guard data.count <= 8192 + prefix.count, data.starts(with: prefix),
              let value = try? JSONDecoder().decode(Self.self, from: data.dropFirst(prefix.count)), value.valid else { return nil }
        return value
    }
    static var now: Double { Date().timeIntervalSince1970 * 1000 }
}

/// Only verified placement plus independently observed empty jaws can advance
/// the mission. Legacy 'accepted_unverified' and batch path counts cannot.
enum ROBRecycleMissionOutcome: Equatable {
    case verifiedTransfer, emptyPerceptionMiss, hold(possiblePayload: Bool)
    static func classify(_ result: NSDictionary) -> Self {
        if result["placement_verified"] as? Bool == true,
           result["empty_verified"] as? Bool == true,result["transfer_completed"] as? Bool == true,
           result["possible_payload_held"] as? Bool != true,result["requires_intervention"] as? Bool != true {
            return .verifiedTransfer
        }
        let possible=(result["possible_payload_held"] as? Bool ?? false) ||
            (result["grasp_attempted"] as? Bool ?? false) || result["jaw_command_sent"] as? Bool != false
        if result["arm_motion_sent"] as? Bool == false,result["jaw_command_sent"] as? Bool == false,
           !possible,["not_reachable","no_reachable_can","not_found","needs_help"].contains(result["status"] as? String ?? "") {
            return .emptyPerceptionMiss
        }
        return .hold(possiblePayload:possible || result["motion_completed"] as? Bool == true)
    }
}
