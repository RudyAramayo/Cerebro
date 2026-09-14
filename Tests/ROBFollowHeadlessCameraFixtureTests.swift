import AppKit
import AVFoundation
import Foundation

// Isolated test doubles for services linked by the real follow coordinator.
// This fixture never links Cerebro's application delegate or hardware drivers.
struct CameraDepthFrame {
    let width = 0, height = 0
    func distanceMillimeters(x: Int, y: Int) -> UInt16? { nil }
}
struct ROBLidarScanFrame {
    struct Point { let distanceMeters: Double, angleRadians: Double }
    let points: [Point] = []
    static func decode(_ data: Data) throws -> Self { .init() }
}
final class ROBTraversabilityRuntime {
    static let shared = ROBTraversabilityRuntime()
    struct Direction { let geometryConfidence: Double, depthClearanceMeters: Double, headingOffset: Double }
    struct Snapshot { let receivedAtUptime: TimeInterval; let directions: [Direction] }
    func snapshot() -> Snapshot? { nil }
    func setAutonomousMotionActive(_ active: Bool) {}
}
@objc protocol ROBInsta360VideoFrameConsumer: AnyObject {
    func consumeInsta360JPEGFrame(_ data: Data, capturedAt: Date, capturedAtUptime: TimeInterval)
}
final class ROBInsta360CameraService {
    static let shared = ROBInsta360CameraService()
    func setFollowFrameConsumer(_ consumer: ROBInsta360VideoFrameConsumer?) {}
    func setFollowVideoDemandActive(_ active: Bool) {}
}
enum ROBInsta360TrackingCalibration { static let forwardCenterX = 0.52 }
enum ROBControlLiveSessionNotification {
    static let controllerIDKey = "controllerID", sessionIDKey = "sessionID"
}
extension Notification.Name {
    static let robControlLiveSessionDidEnd = Notification.Name("fixture.sessionEnded")
}

private final class CaptureDelegate: NSObject, ROBFollowPersonCoordinatorDelegate {
    var cameraEvents: [Bool] = []
    var messages: [ROBFollowTargetMessage] = []
    var motionRequests = 0
    var wantsCamera: Bool { cameraEvents.last ?? false }
    func followPersonCoordinator(_ coordinator: ROBFollowPersonCoordinator, setMainCameraDemandActive active: Bool) { cameraEvents.append(active) }
    func followPersonCoordinator(_ coordinator: ROBFollowPersonCoordinator, applyLeftTread: Double, rightTread: Double, speedScale: Double) { motionRequests += 1 }
    func followPersonCoordinatorDidRequestBaseStop(_ coordinator: ROBFollowPersonCoordinator) {}
    func followPersonCoordinatorPrepareTrackingPose(_ coordinator: ROBFollowPersonCoordinator) -> Bool { motionRequests += 1; return false }
    func followPersonCoordinator(_ coordinator: ROBFollowPersonCoordinator, applyNeckPan: Float, tilt: Float) { motionRequests += 1 }
    func followPersonCoordinator(_ coordinator: ROBFollowPersonCoordinator, applyTorsoRotation: Float) { motionRequests += 1 }
    func followPersonCoordinatorDidRequestActuatorRelease(_ coordinator: ROBFollowPersonCoordinator) {}
    func followPersonCoordinator(_ coordinator: ROBFollowPersonCoordinator, publishData data: Data, controllerID: UUID, sessionID: UUID) {
        if let message = try? ROBFollowTargetProtocol.decode(data) { messages.append(message) }
    }
}

@main enum ROBFollowHeadlessCameraFixtureTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ detail: String) {
        checks += 1
        guard value() else { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    }
    static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01))) }
    }
    static func awaitState(_ detail: String, timeout: Double = 2, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { pump(0.01) }
        expect(condition(), detail)
    }
    static func main() throws {
        let coordinator = ROBFollowPersonCoordinator(robotID: "fixture")
        let delegate = CaptureDelegate(); coordinator.delegate = delegate
        let controller = UUID(), session = UUID()
        var sequence: UInt64 = 0
        func send(_ kind: ROBFollowTargetKind, _ request: UUID = UUID()) throws {
            sequence += 1
            let message = ROBFollowTargetMessage(kind: kind, requestID: request, controllerID: controller, sessionID: session, sequence: sequence, sentAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000))
            let data = try ROBFollowTargetProtocol.encode(message)
            expect(coordinator.handleWireData(data), "real coordinator claims follow frame")
        }

        try send(.previewRequest)
        awaitState("preview requests capture without a diagnostics window") { delegate.wantsCamera }
        expect(!coordinator.active && delegate.motionRequests == 0, "preview grants no motion authority")
        try send(.stop)
        awaitState("stop releases preview capture") { !delegate.wantsCamera }

        let oldRequest = UUID(), newRequest = UUID()
        try send(.previewRequest, oldRequest)
        awaitState("second preview starts capture") { delegate.wantsCamera }
        pump(2)
        try send(.previewRequest, newRequest)
        pump(8.5)
        expect(delegate.wantsCamera, "old timeout cannot release a newer preview's camera")
        expect(!delegate.messages.contains { $0.requestID == oldRequest && $0.state == .blocked }, "old timeout cannot publish a stale blocker")
        awaitState("missing camera times out and releases capture", timeout: 3) { !delegate.wantsCamera }
        expect(delegate.messages.contains { $0.requestID == newRequest && $0.state == .blocked }, "camera failure reaches the phone as a blocked status")

        try send(.previewRequest)
        awaitState("preview restarts after timeout") { delegate.wantsCamera }
        NotificationCenter.default.post(name: .robControlLiveSessionDidEnd, object: nil, userInfo: [ROBControlLiveSessionNotification.controllerIDKey: controller, ROBControlLiveSessionNotification.sessionIDKey: session])
        awaitState("disconnect releases camera demand") { !delegate.wantsCamera }
        expect(!coordinator.active && delegate.motionRequests == 0, "preview and disconnect never move the robot")
        coordinator.shutdown(); pump(0.05)
        expect(!delegate.wantsCamera, "shutdown leaves capture demand off")
        print("Follow headless camera fixtures passed: \(checks) checks")
    }
}
