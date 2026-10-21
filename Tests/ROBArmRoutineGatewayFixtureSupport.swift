// No hardware authority in isolated gateway protocol fixtures.
final class ROBLeftArmTrial {
    static let shared = ROBLeftArmTrial()
    var approved = false
    var generation: UInt64 = 0
    var ghostID: UUID?
    var ghostIndex = 0
    var ghostSeconds = 3.2
    var ghostTarget = [Double](repeating: 0, count: 7)
    func approvedGestureTarget(id: UUID, index: Int, seconds: Double, generation: UInt64) -> [Double]? {
        guard id == ghostID, index == ghostIndex, abs(seconds - ghostSeconds) < 0.000001,
              authorizesTaughtWaypoint(arm: "right", expectedSessionGeneration: generation) else { return nil }
        return ghostTarget
    }
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
