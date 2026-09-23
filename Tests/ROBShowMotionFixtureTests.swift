import AppKit

// Production rehearsal coordinator and approval broker; all hardware, cameras
// and controller decisions below are isolated fakes. No robot transport exists.
enum ROBControlLiveSessionRegistry {
    static func isActiveOperator(controllerID: UUID, sessionID: UUID) -> Bool { true }
}
extension Notification.Name { static let ROBAmberGatewayCommandDidComplete = Notification.Name("FixtureAck") }
enum ROBArmSide: Hashable { case left, right }
final class ROBAmberArmMotionArbiter {
    static let shared = ROBAmberArmMotionArbiter()
    var owners: [ROBArmSide: UUID] = [:]
    func reserve(_ arm: ROBArmSide, owner: UUID) -> Bool {
        guard owners[arm] == nil else { return false }; owners[arm] = owner; return true
    }
    func release(_ arm: ROBArmSide, owner: UUID) { if owners[arm] == owner { owners.removeValue(forKey: arm) } }
}
final class ROBAmberGestureExecutor {
    static let shared = ROBAmberGestureExecutor()
    var isExecuting = false
    func requestPriorityHold() -> NSDictionary { [:] }
}
enum ROBArmRendition { static let revision = "fixture-corridor" }
final class ROBArmRoutineCoordinator {
    static let shared = ROBArmRoutineCoordinator()
    var isRunning = false, greetings = 0
    var greetingResult: NSDictionary = ["status": "completed", "detail": "Fixture measured greeting", "measured": true]
    var onGreeting: (() -> Void)?
    func continueApprovedGreeting(completion: @escaping (NSDictionary) -> Void) {
        precondition(ROBControllerArmApproval.shared.authorizesMotionPath(ROBShowMotionCoordinator.greetingSummary))
        greetings += 1; onGreeting?()
        completion(greetingResult)
    }
    func cancel(reason: String) { isRunning = false }
}
final class ROBAmberGatewayTunnel {
    static let shared = ROBAmberGatewayTunnel()
    var failureDetail: String?
    func connect() {}
}
final class ROBAmberGatewayTelemetry {
    var effectiveSampleAgeMilliseconds = 1.0
    var positionsRadians = Array(repeating: NSNumber(value: 0), count: 7)
}
final class ROBAmberGatewayClient: NSObject {
    static let shared = ROBAmberGatewayClient()
    var sample = ROBAmberGatewayTelemetry()
    func isReady() -> Bool { true }
    func connectionSnapshot() -> NSDictionary { ["sessionGeneration": NSNumber(value: 1)] }
    func telemetry(forArm: String) -> ROBAmberGatewayTelemetry? { sample }
    func modes(forArm: String) -> [NSNumber] { Array(repeating: 0, count: 7) }
    func queryMode(forArm: String) -> UInt64 { 1 }
    func priorityHold(forArm: String) -> UInt64 { 1 }
    func manualArmControlReadiness(forUDPPort: Int, expectedSessionGeneration: UInt64) -> NSDictionary { ["allowed": true] }
}
final class ROBTorsoControlCenter {
    static let shared = ROBTorsoControlCenter()
    var isArmed = false
}
final class ROBArmRoutineVision {
    static let shared = ROBArmRoutineVision()
    var fresh = true, handsClear = true
    var readinessDescription: String { "Fixture camera" }
    func setActive(_ active: Bool) {}
    func healthSnapshot() -> NSDictionary { ["input_age_ms": 30, "analysis_age_ms": 40] }
}

@main struct ShowMotionFixtures {
    @MainActor static func run(_ coordinator: ROBShowMotionCoordinator, _ path: String, rehearsal: Bool = true) async -> NSDictionary {
        await withCheckedContinuation { continuation in
            coordinator.performPath(path, rehearsal: rehearsal) { continuation.resume(returning: $0) }
        }
    }
    @MainActor static func tests() async throws {
        let suite = "show-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let coordinator = ROBShowMotionCoordinator(defaults: defaults, receiptDirectory: directory)
        let broker = ROBControllerArmApproval.shared
        let device = UUID(), session = UUID(), sender = "fixture-controller"
        let hello = ROBRobotActionMessage.controllerHello(senderID: sender, acceptsActions: true, capabilities: ["play_gesture"])
        _ = broker.receive(hello, device: device, session: session)
        let heartbeat = Timer(timeInterval: 1, repeats: true) { _ in _ = broker.receive(hello, device: device, session: session) }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate() }
        var approvalCount = 0
        broker.send = { message, _, _ in
            if message.kind == .actionRequest {
                approvalCount += 1
                precondition(message.action == "play_gesture")
                DispatchQueue.main.async {
                    _ = broker.receive(.actionStatus(callID: message.callID!, state: .accepted, detail: "Fixture operator decision",
                        result: [:], senderID: sender, recipientID: message.senderID), device: device, session: session)
                }
            }
            return true
        }
        var pan = 5781, source = "Torso servo control", commands: [Int] = []
        var uprightValid = true
        coordinator.prepare = { true }
        coordinator.readNeck = { ["known": true, "pan": pan, "lower": 6011, "upper": 6906,
                                  "saved_center": 5781, "saved_left": 7652, "saved_right": 4000,
                                  "saved_upright_valid": uprightValid,
                                  "ready_at": 0.0, "source": source] }
        coordinator.commandNeck = { p, l, u in
            precondition(l == 6011 && u == 6906 && (5448...6114).contains(p))
            commands.append(p); pan = p; return 1
        }
        let untested = await run(coordinator, ROBShowMotionCoordinator.greetingID, rehearsal: false)
        precondition(untested["status"] as? String == "blocked" && commands.isEmpty && approvalCount == 0)
        let invalid = await run(coordinator, "show.unbounded")
        precondition(invalid["status"] as? String == "rejected" && commands.isEmpty)
        uprightValid = false
        let wrongPose = await run(coordinator, ROBShowMotionCoordinator.scanID)
        precondition(wrongPose["status"] as? String == "blocked" && approvalCount == 0)
        uprightValid = true
        let greeting = await run(coordinator, ROBShowMotionCoordinator.greetingID)
        precondition(greeting["status"] as? String == "completed", greeting.description)
        precondition(approvalCount == 1 && commands == [5781, 6114, 5781, 5448, 5781])
        precondition(ROBArmRoutineCoordinator.shared.greetings == 1 && pan == 5781)
        precondition(greeting["neck_measured"] as? Bool == false)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: coordinator.lastReceiptPath))) as! [String: Any]
        precondition(!(receipt["samples"] as! [[String: Any]]).isEmpty)
        precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        print("Rehearsal: one real broker grant covers bounded look + greeting, evidence saved, neck measurement not fabricated")

        // Calibration changes invalidate the model's rehearsal availability.
        defaults.set(12, forKey: "ROBMaestroServoSpeedLimit")
        let stale = await run(coordinator, ROBShowMotionCoordinator.greetingID, rehearsal: false)
        precondition(stale["status"] as? String == "blocked" && approvalCount == 1)
        commands = []
        coordinator.commandNeck = { p, _, _ in
            commands.append(p); pan = p; ROBArmRoutineVision.shared.fresh = false; return 1
        }
        let lost = await run(coordinator, ROBShowMotionCoordinator.scanID)
        precondition(lost["status"] as? String == "blocked" && commands.count == 1)
        precondition(ROBArmRoutineCoordinator.shared.greetings == 1 && ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        ROBArmRoutineVision.shared.fresh = true
        commands = []
        coordinator.commandNeck = { p, _, _ in commands.append(p); pan = p + 20; source = "Manual controller"; return 1 }
        let override = await run(coordinator, ROBShowMotionCoordinator.scanID)
        precondition(override["status"] as? String == "blocked" && commands.count == 1)
        precondition((override["detail"] as? String)?.contains("interrupted") == true)
        commands = []; source = "Torso servo control"
        coordinator.commandNeck = { p, _, _ in
            commands.append(p); pan = p
            DispatchQueue.main.async { coordinator.stop() }
            return 1
        }
        _ = await run(coordinator, ROBShowMotionCoordinator.scanID)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(commands.count == 1 && !coordinator.isRunning && ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        print("Rehearsal: invalid IDs, stale calibration, camera loss and manual override reject or stop before later steps")

        // A later arm-camera veto must not erase the completed neck component.
        defaults.removeObject(forKey: "ROBShowMotionRehearsalReceiptsV1")
        ROBArmRoutineCoordinator.shared.greetingResult = ["status": "blocked", "detail": "Fixture arm view obscured"]
        coordinator.commandNeck = { p, _, _ in commands.append(p); pan = p; return 1 }
        let partial = await run(coordinator, ROBShowMotionCoordinator.greetingID)
        precondition(partial["status"] as? String == "blocked")
        func available(_ id: String) -> Bool {
            let paths = coordinator.capabilitySnapshot()["paths"] as! [[String: Any]]
            return paths.first { $0["id"] as? String == id }?["available_to_model"] as? Bool == true
        }
        precondition(available(ROBShowMotionCoordinator.scanID) && !available(ROBShowMotionCoordinator.greetingID))
        let partialFile = URL(fileURLWithPath: coordinator.lastReceiptPath)
        var priorReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: partialFile)) as! [String: Any]
        priorReceipt.removeValue(forKey: "completed_components")
        try JSONSerialization.data(withJSONObject: priorReceipt).write(to: partialFile)
        defaults.removeObject(forKey: "ROBShowMotionRehearsalReceiptsV1")
        precondition(available(ROBShowMotionCoordinator.scanID) && !available(ROBShowMotionCoordinator.greetingID))
        priorReceipt["result"] = ["status": "blocked", "detail": "Neck did not complete"]
        try JSONSerialization.data(withJSONObject: priorReceipt).write(to: partialFile)
        defaults.removeObject(forKey: "ROBShowMotionRehearsalReceiptsV1")
        precondition(!available(ROBShowMotionCoordinator.scanID))
        print("Rehearsal: completed look survives an arm veto; legacy receipts require the post-neck completion marker")
    }
    static func main() {
        Task { @MainActor in
            do { try await tests(); print("Show rehearsal fixtures passed; no hardware access"); exit(0) }
            catch { fatalError(error.localizedDescription) }
        }
        RunLoop.main.run()
    }
}
