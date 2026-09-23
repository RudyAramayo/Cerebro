import AppKit

final class ROBShowMotionCoordinator {
    static let shared = ROBShowMotionCoordinator()
    static let greetingSummary = "Fixture combined greeting"
    var isRunning = false
}

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
final class ROBAmberGestureExecutor {
    static let shared = ROBAmberGestureExecutor()
    var isExecuting = false
}
final class ROBAmberGatewayTunnel {
    static let shared = ROBAmberGatewayTunnel()
    var failureDetail: String?
    func connect(host: String? = nil) {}
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
    func sendRoutineWaypoint(arm: String, index: Int, duration: Double, expectedSessionGeneration: UInt64) -> UInt64 {
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
    func healthSnapshot() -> NSDictionary { ["fixture": true] }
    var demonstrationSample: ROBArmDemonstrationSample?
    func setActive(_ active: Bool, teaching: Bool = false) {}
    func observe(target: String, grippers: Bool = true, progress: (@MainActor (String) -> Void)? = nil) async throws -> ROBArmRoutineObservation {
        ROBArmRoutineObservation(pathVisible: !blocked, pathClear: !blocked, hanging: true, armsInFront: !blocked,
            leftJawEmpty: !objectInRight, rightJawEmpty: !objectInRight,
            leftObjectBetweenJaws: false, rightObjectBetweenJaws: objectInRight,
            leftJawOpen: true, rightJawOpen: true, leftJawClosedOnObject: false, rightJawClosedOnObject: objectInRight,
            handsClear: handsClear, confidence: 0.99)
    }
}

@main struct ArmRoutineFixtures {
    @MainActor static func run(_ command: String, target: String = "fixture object") async -> NSDictionary {
        await withCheckedContinuation { continuation in
            ROBArmRoutineCoordinator.shared.performCommand(command, target: target) { continuation.resume(returning: $0) }
        }
    }
    static func testRenditions() {
        let now = 1_000_000.0
        func sample(_ n: Int, _ lift: Double, x: Double = 0.5) -> ROBArmDemonstrationSample {
            .init(sequence: UInt64(n + 1), capturedAt: now + Double(n) * 200,
                  elevation: lift, bodyCenterX: x, bodyCenterY: 0.5, torsoHeight: 0.3)
        }
        var builder = ROBArmDemonstrationBuilder()
        for n in 0...25 {
            let lift = n < 8 ? 0.0 : n < 16 ? 1.0 : 0.5
            precondition(builder.append(sample(n, lift), now: now + Double(n) * 200 + 50))
        }
        let clip = builder.rendition(name: "Slow demonstration")!
        precondition(clip.isValid && clip.levels == [4, 6, 5])
        precondition(clip.waypoints == [5, 4, 5, 6, 5, 6])
        precondition(clip.waypoints.count <= 8 && clip.nominalMotionSeconds <= 32)
        var invalid = ROBArmDemonstrationBuilder()
        precondition(!invalid.append(sample(0, .nan), now: now))
        precondition(!invalid.append(sample(0, 0), now: now + 701))
        precondition(!invalid.append(sample(0, 0), now: now - 1))
        precondition(invalid.append(sample(0, 0), now: now))
        precondition(!invalid.append(sample(0, 1), now: now)) // repeated pixels
        precondition(!invalid.append(sample(1, 1, x: 0.9), now: now + 200)) // body discontinuity
        precondition(!invalid.append(sample(5, 1), now: now + 1000)) // missing tracking interval
        precondition(invalid.rendition(name: "incomplete") == nil)
        let suite = "arm-rendition-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ROBArmImitationStore(defaults: defaults)
        precondition(store.save(clip) && store.find("last") == clip && store.find(clip.id) == clip)
        precondition(store.find("unknown") == nil)
        let corrupt = ROBArmRendition(id: clip.id, name: "tampered", corridor: "unreviewed",
                                     levels: [0, 99], createdAt: Date())
        precondition(!store.save(corrupt))
        defaults.set(try! JSONEncoder().encode([corrupt]), forKey: "ROBArmFrontCorridorRenditionsV1")
        precondition(store.summaries().isEmpty && store.find("last") == nil)
        let zero = Array(repeating: 0.0, count: 7)
        precondition(ROBArmRoutinePlan.duration(from: [], to: zero) == nil)
        precondition(ROBArmRoutinePlan.duration(from: zero, to: [.nan, 0, 0, 0, 0, 0, 0]) == nil)
        var total = 0.0
        for n in 1...6 {
            let a = ROBArmRoutinePlan.rightWaypoints[n-1], b = ROBArmRoutinePlan.rightWaypoints[n]
            let time = ROBArmRoutinePlan.duration(from: a, to: b)!
            precondition(time >= 3.17 && time <= 4.01)
            total += time
        }
        precondition(total < 21 && total > 20)
        print("Renditions: stable bounded lift mapping, discontinuity/staleness rejection, stored-clip validation and timing passed")
    }
    @MainActor static func test() async {
        testRenditions()
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
        precondition(ROBArmRoutineCoordinator.commandForText("Rob, wave at Sam") == "wave")
        precondition(ROBArmRoutineCoordinator.commandForText("copy my pose") == "teach")
        precondition(ROBArmRoutineCoordinator.commandForText("replay that movement") == "replay")
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

        g.ready = false
        ROBAmberGatewayTunnel.shared.failureDetail = "SSH login rejected for fixture robot"
        let connectionStarted = ProcessInfo.processInfo.systemUptime
        let disconnected = await run("grab")
        precondition(disconnected["status"] as? String == "blocked")
        precondition(disconnected["detail"] as? String == "SSH login rejected for fixture robot")
        precondition(ProcessInfo.processInfo.systemUptime - connectionStarted < 1,
                     "SSH failure waited through the generic 12-second timeout")
        precondition(!g.commands.contains { $0.hasPrefix("position_mode") || $0.hasPrefix("calibrate") || $0.hasPrefix("waypoint") || $0.hasPrefix("gripper_") })
        ROBAmberGatewayTunnel.shared.failureDetail = nil
        g.ready = true; g.commands = []
        print("Gateway failure: exact SSH error returned promptly with no activation or gripper motion")

        g.feedbackReadyAt = ProcessInfo.processInfo.systemUptime + 0.3
        let inactive = await run("relax")
        precondition(inactive["status"] as? String == "completed")
        precondition(!g.commands.contains { $0.hasPrefix("position_mode") || $0.hasPrefix("calibrate") })
        g.q["left"]![4] = 0.5; g.commands = []
        let unknown = await run("prepare")
        precondition(unknown["status"] as? String == "blocked" && !g.commands.contains { $0.hasPrefix("waypoint") || $0.hasPrefix("position_mode") })
        g.q["left"] = zero; v.blocked = true; g.commands = []
        let occluded = await run("startup")
        precondition(occluded["status"] as? String == "blocked")
        precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 12,
                     "Explicit controller supervision did not allow the taught route in poor visibility")
        precondition(!g.commands.contains { $0.hasPrefix("calibrate") || $0.hasPrefix("gripper_") },
                     "Poor jaw visibility allowed a gripper operation")
        precondition(!ROBControllerArmApproval.shared.authorizesSupervisedArmRoute(), "Supervision survived completion")
        // A core may have entered active mode before a prior acknowledgement
        // failed. A whole active arm must still verify position mode to move.
        v.blocked = false; g.q = ["left": zero, "right": zero]; g.mode = ["left": 1, "right": 0]; g.commands = []
        let startup = await run("startup")
        precondition(startup["status"] as? String == "completed", startup.description)
        precondition(g.commands.filter { $0.hasPrefix("calibrate:") }.count == 2)
        precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 12)
        precondition(g.commands.firstIndex(of: "calibrate:left")! > g.commands.lastIndex(of: "waypoint_6:right")!)
        precondition(g.mode.values.allSatisfy { $0 == 2 })
        print("Startup: both arms reached front before either gripper calibration")

        g.commands = []; v.blocked = true
        let wave = await run("wave")
        precondition(wave["status"] as? String == "completed" && wave["measured"] as? Bool == true)
        precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 8)
        precondition(!g.commands.contains { $0.hasPrefix("calibrate") }, "Greeting repeated gripper calibration")
        precondition(!g.commands.contains { $0.hasPrefix("gripper_") }, "Supervised gesture unexpectedly moved a jaw")
        v.blocked = false
        precondition(g.q.allSatisfy { ROBArmRoutinePlan.near($0.value, ROBArmRoutinePlan.target(index: 6, physicalLeft: $0.key == "right")!) })
        print("Greeting: locally timed paired motion returned to the measured front pose")
        // Camera-only capture must produce a reusable clip without emitting a
        // motor command. The production collector and builder run unchanged.
        let key = "ROBArmFrontCorridorRenditionsV1"
        let previousRecordings = UserDefaults.standard.data(forKey: key)
        defer {
            if let previousRecordings { UserDefaults.standard.set(previousRecordings, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        var poseSequence: UInt64 = 100
        let bodyFrames = Timer(timeInterval: 0.2, repeats: true) { _ in
            poseSequence += 1
            v.demonstrationSample = .init(sequence: poseSequence,
                capturedAt: Date().timeIntervalSince1970 * 1000, elevation: 0.5,
                bodyCenterX: 0.5, bodyCenterY: 0.5, torsoHeight: 0.3)
        }
        RunLoop.main.add(bodyFrames, forMode: .common)
        g.commands = []
        let taught = await run("teach")
        bodyFrames.invalidate(); v.demonstrationSample = nil
        precondition(taught["status"] as? String == "recorded" && g.commands.isEmpty, taught.description)
        precondition(!r.ownsPhysicalMotion)
        let replay = await run("replay", target: taught["clip_id"] as! String)
        precondition(replay["status"] as? String == "completed" && replay["measured"] as? Bool == true)
        precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 4)
        if let previousRecordings { UserDefaults.standard.set(previousRecordings, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        print("Teaching: no motor commands; saved bounded clip replayed with measured arrival")
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

        g.commands = []
        let missing = await run("replay")
        precondition(missing["status"] as? String == "blocked" && g.commands.isEmpty)
        g.stale = true
        let stale = await run("startup")
        precondition(stale["status"] as? String == "blocked" && !g.commands.contains { $0.hasPrefix("position_mode") })
        print("Arm routine fixtures passed (no hardware access)")
        exit(0)
    }
    static func main() { Task { @MainActor in await test() }; RunLoop.main.run() }
}
