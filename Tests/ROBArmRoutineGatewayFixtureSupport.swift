// No hardware authority in isolated gateway protocol fixtures.
final class ROBLeftArmTrial {
    static let shared = ROBLeftArmTrial()
    var approved = false
    var generation: UInt64 = 0
    func authorizesTaughtWaypoint(arm: String, expectedSessionGeneration: UInt64) -> Bool {
        approved && arm == "right" && generation > 0 && generation == expectedSessionGeneration
    }
}

final class ROBArmRoutineCoordinator {
    static let shared = ROBArmRoutineCoordinator()
    var isRunning = false
}
enum ROBArmSide {
    case left, right
    init?(amberGatewayArm: String) {
        guard ["left", "right"].contains(amberGatewayArm) else { return nil }
        self = amberGatewayArm == "left" ? .right : .left
    }
}
final class ROBAmberArmMotionArbiter {
    static let shared = ROBAmberArmMotionArbiter()
    func isReserved(_ arm: ROBArmSide) -> Bool { false }
}
