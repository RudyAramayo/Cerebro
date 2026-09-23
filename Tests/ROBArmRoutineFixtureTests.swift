import AppKit

// The production coordinator and planner run unchanged, with no sockets,
// cameras or hardware SDK. Mock commands acknowledge asynchronously so races
// between dispatch, cancellation, telemetry and leases remain exercised.
extension Notification.Name {
    static let ROBAmberGatewayCommandDidComplete = Notification.Name("FixtureAck")
}
enum ROBControlLiveSessionRegistry {
    static func isActiveOperator(controllerID: UUID, sessionID: UUID) -> Bool { true }
}
enum ROBArmSide: Hashable { case left, right }
final class ROBAmberArmMotionArbiter {
    static let shared = ROBAmberArmMotionArbiter()
    var owners: [ROBArmSide: UUID] = [:]
    func reserve(_ arm: ROBArmSide, owner: UUID) -> Bool {
        guard owners[arm] == nil else { return false }; owners[arm] = owner; return true
    }
    func release(_ arm: ROBArmSide, owner: UUID) { if owners[arm] == owner { owners.removeValue(forKey: arm) } }
}
final class ROBAmberGatewayTunnel {
    static let shared = ROBAmberGatewayTunnel()
    func connect(host: String) {}
}
final class ROBAmberGatewayTelemetry {
    let sequence: UInt64
    let positionsRadians: [NSNumber]
    let statuses = Array(repeating: NSNumber(value: 2), count: 7)
    let effectiveSampleAgeMilliseconds: Double
    let effectiveGripperFeedbackAgeMilliseconds = 1.0
    init(sequence: UInt64, positions: [Double], stale: Bool) {
        self.sequence = sequence; positionsRadians = positions.map(NSNumber.init(value:))
        effectiveSampleAgeMilliseconds = stale ? 1000 : 1
    }
}
final class ROBAmberGatewayClient: NSObject {
    static let shared = ROBAmberGatewayClient()
    var generation: UInt64 = 1
    var ready = true, stale = false, rejectRenewal = false
    var q = ["left": Array(repeating: 0.0, count: 7), "right": Array(repeating: 0.0, count: 7)]
    var mode = ["left": 0, "right": 0]
    var commands: [String] = []
    var sequence: UInt64 = 1, nextID: UInt64 = 1
    var feedbackReadyAt = 0.0
    func isReady() -> Bool { ready }
    func manualArmControlReadiness(forUDPPort: Int, expectedSessionGeneration: UInt64) -> NSDictionary {
        ["allowed": ready && !stale && expectedSessionGeneration == generation]
    }
    func connectionSnapshot() -> NSDictionary { ["sessionGeneration": NSNumber(value: generation)] }
    func telemetry(forArm arm: String) -> ROBAmberGatewayTelemetry? {
        guard ProcessInfo.processInfo.systemUptime >= feedbackReadyAt else { return nil }
        sequence += 1
        return ROBAmberGatewayTelemetry(sequence: sequence, positions: q[arm]!, stale: stale)
    }
    func modes(forArm arm: String) -> [NSNumber] { Array(repeating: NSNumber(value: mode[arm]!), count: 7) }
    func ack(_ operation: String, _ arm: String, accepted: Bool = true) -> UInt64 {
        let id = nextID; nextID += 1
        commands.append("\(operation):\(arm)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ROBAmberGatewayCommandDidComplete, object: self,
                userInfo: ["commandID": NSNumber(value: id), "accepted": accepted, "operation": operation])
        }
        return id
    }
    func queryMode(forArm arm: String) -> UInt64 { ack("mode_query", arm) }
    func enterPositionMode(forArm arm: String) -> UInt64 { mode[arm] = 2; return ack("position_mode", arm) }
    func sendRoutineWaypoint(arm: String, index: Int, expectedSessionGeneration: UInt64) -> UInt64 {
        precondition(expectedSessionGeneration == generation && mode[arm] == 2)
        q[arm] = ROBArmRoutinePlan.target(index: index, physicalLeft: arm == "right")!
        return ack("waypoint_\(index)", arm)
    }
    func priorityHold(forArm arm: String) -> UInt64 { ack("priority_hold", arm) }
    func renewLease(forArm arm: String, leaseMilliseconds: UInt32) -> UInt64 { ack("renew_lease", arm, accepted: !rejectRenewal) }
    func deactivateArm(_ arm: String) -> UInt64 {
        precondition(ROBArmRoutinePlan.near(q[arm]!, Array(repeating: 0, count: 7)), "Torque removed away from hanging")
        mode[arm] = 0; return ack("deactivate", arm)
    }
    func calibrateGripper(forArm arm: String) -> UInt64 {
        precondition(q.allSatisfy { ROBArmRoutinePlan.near($0.value, ROBArmRoutinePlan.target(index: 6, physicalLeft: $0.key == "right")!) }, "Calibration before BOTH arms reached front")
        return ack("calibrate", arm)
    }
    func controlGripper(forArm arm: String, action: String, force: Int) -> UInt64 {
        precondition(force == 10)
        return ack("gripper_\(action)", arm)
    }
}
final class ROBArmRoutineVision {
    static let shared = ROBArmRoutineVision()
    var fresh = true, handsClear = true, blocked = false, objectInRight = false
    var readinessDescription: String { "Simulated camera unavailable" }
    func setActive(_ active: Bool) {}
    func observe(target: String) async throws -> ROBArmRoutineObservation {
        ROBArmRoutineObservation(pathVisible: !blocked, pathClear: !blocked, hanging: true, armsInFront: true,
            leftJawEmpty: !objectInRight, rightJawEmpty: !objectInRight,
            leftObjectBetweenJaws: false, rightObjectBetweenJaws: objectInRight,
            leftJawOpen: true, rightJawOpen: true, leftJawClosedOnObject: false, rightJawClosedOnObject: objectInRight,
            handsClear: handsClear, confidence: 0.99)
    }
}

@main struct ArmRoutineFixtures {
    @MainActor static func run(_ command: String) async -> NSDictionary {
        await withCheckedContinuation { continuation in
            ROBArmRoutineCoordinator.shared.performCommand(command, target: "fixture object") { continuation.resume(returning: $0) }
        }
    }
    @MainActor static func test() async {
        let r = ROBArmRoutineCoordinator.shared, g = ROBAmberGatewayClient.shared, v = ROBArmRoutineVision.shared
        let approvals = ROBControllerArmApproval.shared
        let device = UUID(), session = UUID()
        let hello = ROBRobotActionMessage.controllerHello(senderID: "fixture-controller", acceptsActions: true, capabilities: ["arm_operation"])
        _ = approvals.receive(hello, device: device, session: session)
        // Simulated controller heartbeat and explicit one-shot approval. This is
        // fixture-only; production never manufactures the accepted response.
        let heartbeat = Timer(timeInterval: 1, repeats: true) { _ in
            _ = approvals.receive(hello, device: device, session: session)
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        approvals.send = { request, _, _ in
            if request.kind == .actionRequest {
                DispatchQueue.main.async {
                    _ = approvals.receive(.actionStatus(callID: request.callID!, state: .accepted,
                        detail: "Fixture operator approves", result: [:], senderID: "fixture-controller", recipientID: request.senderID),
                        device: device, session: session)
                }
            }
            return true
        }
        r.prepareView = { true }; r.viewIsStationary = { true }
        precondition(ROBArmRoutineCoordinator.commandForText("Rob, relax your arms") == "relax")
        for text in ["don't grab this", "hold on", "explain how to grab this", "do not relax", "I said 'grab this'", "grab the cup but do not move", "grab this if I say yes"] {
            precondition(ROBArmRoutineCoordinator.commandForText(text) == nil, text)
        }
        precondition(ROBArmRoutineCoordinator.commandForText("hold this") == "hold")
        precondition(ROBArmRoutineCoordinator.commandForText("could you please grab that cup") == "grab")
        for left in [false, true] {
            let zero = ROBArmRoutinePlan.target(index: 0, physicalLeft: left)!
            precondition(ROBArmRoutinePlan.route(from: zero, physicalLeft: left, hanging: false) == [1,2,3,4,5,6])
            let mid = ROBArmRoutinePlan.target(index: 5, physicalLeft: left)!.enumerated().map { $0.offset == 0 ? (left ? -0.6 : 0.6) : $0.element }
            precondition(ROBArmRoutinePlan.route(from: mid, physicalLeft: left, hanging: true) == [4,3,2,1,0])
            var bad = zero; bad[5] = 0.7
            precondition(ROBArmRoutinePlan.progress(bad, physicalLeft: left) == nil)
            bad[5] = .nan; precondition(ROBArmRoutinePlan.progress(bad, physicalLeft: left) == nil)
        }
        var settler = ROBArmRoutineSettler()
        let zero = Array(repeating: 0.0, count: 7)
        for i in 0...10 { precondition(!settler.observe(sequence: 1, positions: zero, target: zero, now: Double(i))) }
        precondition(!settler.observe(sequence: 2, positions: zero, target: zero, now: 11))
        precondition(!settler.observe(sequence: 3, positions: zero, target: zero, now: 11.05))
        precondition(settler.observe(sequence: 4, positions: zero, target: zero, now: 11.2))

        g.feedbackReadyAt = ProcessInfo.processInfo.systemUptime + 0.3
        let inactive = await run("relax")
        precondition(inactive["status"] as? String == "completed")
        precondition(!g.commands.contains { $0.hasPrefix("position_mode") || $0.hasPrefix("calibrate") })
        g.q["left"]![4] = 0.5; g.commands = []
        let unknown = await run("prepare")
        precondition(unknown["status"] as? String == "blocked" && !g.commands.contains { $0.hasPrefix("waypoint") || $0.hasPrefix("position_mode") })
        g.q["left"] = zero; v.blocked = true; g.commands = []
        let occluded = await run("startup")
        precondition(occluded["status"] as? String == "blocked" && !g.commands.contains { $0.hasPrefix("position_mode") })
        v.blocked = false; g.commands = []
        let startup = await run("startup")
        precondition(startup["status"] as? String == "completed", startup.description)
        precondition(g.commands.filter { $0.hasPrefix("calibrate:") }.count == 2)
        precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 12)
        precondition(g.commands.firstIndex(of: "calibrate:left")! > g.commands.lastIndex(of: "waypoint_6:right")!)
        precondition(g.mode.values.allSatisfy { $0 == 2 })
        print("Startup: both arms reached front before either gripper calibration")

        g.commands = []; v.objectInRight = true
        let grip = await run("grab")
        precondition(grip["status"] as? String == "grip_attempted", grip.description)
        precondition(g.commands.contains("gripper_hold:left"), "Physical right routed to wrong Amber core")
        precondition(!g.commands.contains { $0.hasPrefix("calibrate") }, "Recalibrated around a presented object")
        v.objectInRight = false; g.commands = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { v.fresh = false }
        let lostCamera = await run("relax")
        precondition(lostCamera["status"] as? String == "blocked")
        precondition(!g.commands.contains { $0.hasPrefix("deactivate") }, "Torque removed after failed return")
        precondition(g.commands.contains("priority_hold:left"))
        v.fresh = true; g.commands = []
        let relax = await run("relax")
        precondition(relax["status"] as? String == "completed", relax.description)
        precondition(g.mode.values.allSatisfy { $0 == 0 })
        precondition(g.commands.firstIndex(of: "deactivate:left")! > g.commands.lastIndex(of: "waypoint_0:right")!)
        precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        print("Relax: failed return held torque; successful return deactivated only at hanging")

        g.commands = []; g.stale = true
        let stale = await run("startup")
        precondition(stale["status"] as? String == "blocked" && !g.commands.contains { $0.hasPrefix("position_mode") })
        print("Arm routine fixtures passed (no hardware access)")
        exit(0)
    }
    static func main() { Task { @MainActor in await test() }; RunLoop.main.run() }
}
