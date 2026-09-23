// No hardware authority in isolated gateway protocol fixtures.
final class ROBArmRoutineCoordinator {
    static let shared = ROBArmRoutineCoordinator()
    let isRunning = false
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
