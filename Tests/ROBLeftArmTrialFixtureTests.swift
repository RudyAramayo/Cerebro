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
    static let ROBAmberGatewayTelemetryDidUpdate = Notification.Name("FixtureTelemetry")
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
    let arm = "right"
    var currents: [NSNumber] = Array(repeating: NSNumber(value: 0.2), count: 7)
    let sequence: UInt64
    let positionsRadians: [NSNumber]
    let statuses: [NSNumber]
    let effectiveSampleAgeMilliseconds: Double
    let effectiveGripperFeedbackAgeMilliseconds = 1.0
    init(sequence: UInt64, positions: [Double], stale: Bool, status: Int) {
        self.sequence = sequence; positionsRadians = positions.map(NSNumber.init(value:))
        statuses = Array(repeating: NSNumber(value: status), count: 7)
        effectiveSampleAgeMilliseconds = stale ? 1000 : 1
    }
}
final class ROBAmberGatewayClient: NSObject {
    static let shared = ROBAmberGatewayClient()
    var generation: UInt64 = 1
    var ready = true, stale = false, rejectRenewal = false
    var current = 0.2
    var assertStationaryGripperApproval = false
    var onWaypoint: (() -> Void)?
    var q = ["left": Array(repeating: 0.0, count: 7), "right": Array(repeating: 0.0, count: 7)]
    var mode = ["left": 0, "right": 0]
    var commands: [String] = []
    var calibrated: Set<String> = []
    var rejectRelease = false
    var afterRelease: (() -> Void)?
    var afterStateQuery: (() -> Void)?
    var sequence: UInt64 = 1, nextID: UInt64 = 1
    var feedbackReadyAt = 0.0
    var modeFeedbackDelay = 0.0
    var modeFeedbackReadyAt: [String: Double] = [:]
    func isReady() -> Bool { ready }
    func manualArmControlReadiness(forUDPPort: Int, expectedSessionGeneration: UInt64) -> NSDictionary {
        ["allowed": ready && !stale && expectedSessionGeneration == generation]
    }
    func connectionSnapshot() -> NSDictionary { ["sessionGeneration": NSNumber(value: generation)] }
    func telemetry(forArm arm: String) -> ROBAmberGatewayTelemetry? {
        guard ProcessInfo.processInfo.systemUptime >= feedbackReadyAt else { return nil }
        sequence += 1
        let status = ProcessInfo.processInfo.systemUptime < (modeFeedbackReadyAt[arm] ?? 0) ? 1 : mode[arm]!
        let sample = ROBAmberGatewayTelemetry(sequence: sequence, positions: q[arm]!, stale: stale, status: status)
        sample.currents = Array(repeating: NSNumber(value: current), count: 7)
        return sample
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
    func enterPositionMode(forArm arm: String) -> UInt64 {
        mode[arm] = 2
        modeFeedbackReadyAt[arm] = ProcessInfo.processInfo.systemUptime + modeFeedbackDelay
        return ack("position_mode", arm)
    }
    func sendRoutineWaypoint(arm: String, index: Int, duration: Double, expectedSessionGeneration: UInt64) -> UInt64 {
        precondition(ROBLeftArmTrial.shared.authorizesTaughtWaypoint(arm: arm,
            expectedSessionGeneration: expectedSessionGeneration), "Gateway admission did not recognize the approved left trial")
        precondition(expectedSessionGeneration == generation && mode[arm] == 2)
        precondition(arm == "right", "Trial dispatched to physical right arm")
        precondition(telemetry(forArm: arm)!.statuses.allSatisfy { $0.intValue == 2 })
        q[arm] = ROBLeftArmInteractionPlan.target(index: index)!
        let id = ack("waypoint_\(index)", arm)
        onWaypoint?()
        return id
    }
    var onGhostStep: (() -> Void)?
    func sendApprovedLeftGestureStep(proposalID: UUID, index: Int, duration: Double, expectedSessionGeneration: UInt64) -> UInt64 {
        guard let target = ROBLeftArmTrial.shared.approvedGestureTarget(id: proposalID, index: index,
            seconds: duration, generation: expectedSessionGeneration) else { return 0 }
        precondition(ROBLeftArmTrial.shared.approvedGestureTarget(id: UUID(), index: index, seconds: duration,
            generation: expectedSessionGeneration) == nil)
        precondition(ROBLeftArmTrial.shared.approvedGestureTarget(id: proposalID, index: index + 1, seconds: duration,
            generation: expectedSessionGeneration) == nil)
        q["right"] = target
        let id = ack("ghost_step_\(index)", "right"); onGhostStep?(); return id
    }
    func priorityHold(forArm arm: String) -> UInt64 { ack("priority_hold", arm) }
    func renewLease(forArm arm: String, leaseMilliseconds: UInt32) -> UInt64 { ack("renew_lease", arm, accepted: !rejectRenewal) }
    func deactivateArm(_ arm: String) -> UInt64 {
        precondition(ROBArmRoutinePlan.near(q[arm]!, Array(repeating: 0, count: 7)), "Torque removed away from hanging")
        mode[arm] = 0; return ack("deactivate", arm)
    }
    func queryGripperState(forArm arm: String) -> UInt64 {
        let id = ack("gripper_state", arm); afterStateQuery?(); return id
    }
    func gripperSnapshot(forArm arm: String) -> NSDictionary {
        ["calibrationState": calibrated.contains(arm) ? "command_accepted_unverified" : "required"]
    }
    func calibrateGripper(forArm arm: String) -> UInt64 {
        precondition(arm == "right" && ROBLeftArmInteractionPlan.stationaryFrontTarget(q[arm]!) != nil)
        calibrated.insert(arm)
        return ack("calibrate", arm)
    }
    func controlGripper(forArm arm: String, action: String, force: Int) -> UInt64 {
        if assertStationaryGripperApproval {
            precondition(!ROBLeftArmTrial.shared.authorizesTaughtWaypoint(arm: arm,
                expectedSessionGeneration: generation), "Stationary gripper approval authorized arm travel")
        }
        precondition(force == 10)
        precondition(calibrated.contains(arm), "Uncalibrated jaw command")
        let id = ack("gripper_\(action)", arm, accepted: action != "release" || !rejectRelease)
        if action == "release" { afterRelease?() }
        return id
    }
}
final class ROBArmRoutineVision {
    static let shared = ROBArmRoutineVision()
    var fresh = true, handsClear = true, blocked = false, objectInRight = false
    var observationCount = 0
    var readinessDescription: String { "Simulated camera unavailable" }
    func healthSnapshot() -> NSDictionary { ["fixture": true] }
    func setActive(_ active: Bool, teaching: Bool = false) {}
    func observe(target: String, grippers: Bool = true, progress: (@MainActor (String) -> Void)? = nil) async throws -> ROBArmRoutineObservation {
        observationCount += 1
        return ROBArmRoutineObservation(pathVisible: !blocked, pathClear: !blocked, hanging: true, armsInFront: !blocked,
            leftJawEmpty: !objectInRight, rightJawEmpty: !objectInRight,
            leftObjectBetweenJaws: false, rightObjectBetweenJaws: objectInRight,
            leftJawOpen: true, rightJawOpen: true, leftJawClosedOnObject: false, rightJawClosedOnObject: objectInRight,
            handsClear: handsClear, confidence: 0.99)
    }
}


enum ROBArmRoutineError: LocalizedError {
    case blocked(String)
    var errorDescription: String? { if case .blocked(let detail) = self { return detail }; return nil }
}
final class ROBArmRoutineCoordinator {
    static let shared = ROBArmRoutineCoordinator()
    var isRunning = false
    var cameraDemand: ((Bool) -> Void)?
    var prepareView: (() -> Bool)? = { true }
    var viewIsStationary: (() -> Bool)? = { true }
}

@main struct LeftArmTrialFixtures {
    @MainActor static func run(_ proposal: ROBLeftGestureProposal, model: ROBGhostRobotModel) async -> NSDictionary {
        await withCheckedContinuation { continuation in
            ROBLeftArmTrial.shared.perform(proposal: proposal, model: model) { continuation.resume(returning: $0) }
        }
    }
    @MainActor static func run(_ command: String) async -> NSDictionary {
        await withCheckedContinuation { continuation in
            ROBLeftArmTrial.shared.perform(command) { continuation.resume(returning: $0) }
        }
    }
    @MainActor static func tests() async throws {
        let plan = ROBLeftArmInteractionPlan.self
        for index in 0...6 {
            precondition(plan.target(index: index)! == ROBArmRoutinePlan.target(index: index, physicalLeft: true)!)
        }
        for index in 7...plan.frontIndex {
            let a = plan.target(index: index - 1)!, b = plan.target(index: index)!
            precondition(a[0] == -1.05 && b[0] == -1.05)
            if index <= 24 { precondition(a[1] == 0.6 && b[1] == 0.6) }
            else { precondition(a[1] >= 0.6 && b[1] <= 1.0) }
            precondition(zip(a, b).filter { abs($0 - $1) > 0.001 }.count == 1)
            precondition(zip(a, b).allSatisfy { abs($0 - $1) <= 0.100001 })
            let middle = zip(a, b).map { ($0 + $1) / 2 }
            let lowering = plan.route(from: middle, hanging: true)!
            precondition(lowering.first == index - 1 && lowering.last == 0)
            precondition(lowering.contains(6), "Extension did not unwind before descending")
        }
        precondition(plan.route(from: plan.target(index: plan.waveIndex)!, hanging: false) == Array(stride(from: plan.waveRestIndex, through: plan.frontIndex, by: -1)))
        var offRoute = plan.target(index: 4)!; offRoute[2] = -0.1
        precondition(plan.route(from: offRoute, hanging: true) == nil, "J3 rotation near the treads was admitted")
        precondition(plan.stationaryFrontTarget(plan.target(index: plan.waveIndex)!) == nil)
        print("Interaction plan: tested approach unchanged, one joint at a time at front, reverse unwinds before descent, off-route poses rejected")
        let trial = ROBLeftArmTrial.shared, g = ROBAmberGatewayClient.shared
        precondition(!trial.authorizesTaughtWaypoint(arm: "right", expectedSessionGeneration: g.generation))
        let broker = ROBControllerArmApproval.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("left-arm-fixture-" + UUID().uuidString)
        trial.recordingDirectory = folder
        let savedLimit = UserDefaults.standard.object(forKey: ROBLeftArmTrial.currentLimitKey)
        defer {
            if let savedLimit { UserDefaults.standard.set(savedLimit, forKey: ROBLeftArmTrial.currentLimitKey) }
            else { UserDefaults.standard.removeObject(forKey: ROBLeftArmTrial.currentLimitKey) }
            try? FileManager.default.removeItem(at: folder)
        }
        UserDefaults.standard.set(0, forKey: ROBLeftArmTrial.currentLimitKey)
        let device = UUID(), session = UUID()
        let hello = ROBRobotActionMessage.controllerHello(senderID: "fixture-controller", acceptsActions: true, capabilities: ["arm_operation"])
        _ = broker.receive(hello, device: device, session: session)
        let heartbeat = Timer(timeInterval: 1, repeats: true) { _ in _ = broker.receive(hello, device: device, session: session) }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate() }
        var approvals = 0
        var approve = true
        broker.send = { message, _, _ in
            if message.kind == .actionRequest {
                approvals += 1
                precondition(g.commands.isEmpty, "Commands sent before controller approval")
                precondition(message.arguments["arm"] as? String == "left")
                DispatchQueue.main.async {
                    _ = broker.receive(.actionStatus(callID: message.callID!, state: approve ? .accepted : .rejected,
                        detail: "Isolated fixture decision", result: [:], senderID: "fixture-controller", recipientID: message.senderID),
                        device: device, session: session)
                }
            }
            return true
        }
        // Rejection is inert, including gripper commands and mode changes.
        approve = false
        let rejected = await run("left_wave")
        precondition(rejected["status"] as? String == "rejected" && g.commands.isEmpty)
        precondition(!broker.authorizesLeftArmTrial("invented"))
        approve = true
        g.q["left"]![6] = 0.5 // unrelated arm is neither read for admission nor moved
        ROBArmRoutineVision.shared.handsClear = false
        ROBArmRoutineVision.shared.blocked = true
        let rightBefore = g.q["left"]!
        let wave = await run("left_wave")
        precondition(wave["status"] as? String == "completed", wave.description)
        precondition(wave["measured"] as? Bool == true)
        precondition(g.commands.allSatisfy { $0.hasSuffix(":right") })
        precondition(g.commands.filter { $0.hasPrefix("waypoint_") }.count == 42)
        precondition(g.commands.filter { $0.hasPrefix("waypoint_") }.suffix(4) == ["waypoint_39:right", "waypoint_38:right", "waypoint_39:right", "waypoint_38:right"])
        precondition(g.q["right"]! == plan.target(index: plan.waveRestIndex)!)
        precondition(!g.commands.contains { $0.hasPrefix("gripper_hold") || $0.hasPrefix("gripper_release") || $0.hasPrefix("calibrate") })
        precondition(g.q["left"]! == rightBefore)
        precondition(ROBArmRoutineVision.shared.observationCount == 0)
        precondition((wave["current_samples"] as? Int ?? 0) > 20)
        let csv = try String(contentsOfFile: wave["current_recording"] as! String, encoding: .utf8)
        precondition(csv.contains("current_raw,current_delta_raw") && csv.contains(",left,right,"))
        precondition(csv.contains("waypoint 6"))
        precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        print("Left wave: one approval, 42 bounded waypoints, above-shoulder endpoint, no right-arm or jaw commands, current CSV saved")
        g.commands = []
        let prepare = await run("left_prepare")
        precondition(prepare["status"] as? String == "accepted_unverified", prepare.description)
        precondition(g.commands.filter { $0.hasPrefix("calibrate") } == ["calibrate:right"])
        precondition(g.commands.contains("gripper_release:right"))
        g.commands = []
        g.assertStationaryGripperApproval = true
        let grip = await run("left_grip")
        precondition(grip["status"] as? String == "accepted_unverified", grip.description)
        precondition(g.commands.contains("gripper_hold:right"))
        precondition(!g.commands.contains { $0.hasPrefix("waypoint") || $0.hasPrefix("calibrate") || $0.hasPrefix("gripper_release") || $0.hasPrefix("position_mode") })
        g.commands = []
        let release = await run("left_release")
        precondition(release["status"] as? String == "accepted_unverified", release.description)
        precondition(g.commands.contains("gripper_release:right"))
        precondition(!g.commands.contains { $0.hasPrefix("waypoint") || $0.hasPrefix("calibrate") || $0.hasPrefix("gripper_hold") })
        // Review and execute a custom gesture through the actual frozen-step
        // admission. Its successful ending returns to the known center pose.
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = try ROBGhostRobotModel(directory: root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
        var pose = model.positions(vendorLeft: g.q["right"]!); pose["left_joint1"] = -0.95
        let frozen = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Fixture ghost", poses: [pose], model: model,
            baseline: g.q["right"]!, generation: g.generation)
        g.commands = []
        let ghost = await run(frozen, model: model)
        precondition(ghost["status"] as? String == "completed", ghost.description)
        precondition(ghost["motion_proposal_sha256"] as? String == frozen.fingerprint)
        precondition(g.q["right"]! == ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!)
        precondition(g.commands.contains { $0.hasPrefix("ghost_step_") })
        precondition(!g.commands.contains { $0.hasPrefix("gripper_") || $0.hasPrefix("calibrate") || $0.hasSuffix(":left") })
        let manifest = URL(fileURLWithPath: ghost["current_recording"] as! String).deletingPathExtension().appendingPathExtension("proposal.json")
        let recordedProposal = try JSONDecoder().decode(ROBLeftGestureProposal.self, from: Data(contentsOf: manifest))
        precondition(recordedProposal == frozen)
        print("Ghost execution: exact approved ID/index/duration, physical-left only, unchanged jaws, measured return and matching recording manifest")
        g.commands = []
        let interrupted = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Interrupted ghost", poses: [pose], model: model,
            baseline: g.q["right"]!, generation: g.generation)
        g.onGhostStep = { trial.cancel(reason: "Fixture ghost stop") }
        let stopped = await run(interrupted, model: model)
        precondition(stopped["status"] as? String == "blocked")
        precondition(g.commands.filter { $0.hasPrefix("ghost_step_") }.count == 1)
        g.onGhostStep = nil; g.commands = []
        let recovery = try trial.recoveryProposal(model: model)
        let recovered = await run(recovery, model: model)
        precondition(recovered["status"] as? String == "completed", recovered.description)
        precondition(g.q["right"]! == ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!)
        print("Ghost interruption: stop holds, later targets cancelled, new controller approval reverses only the remembered path")
        g.commands = []; g.calibrated = []
        let uncalibrated = await run("left_grip")
        precondition(uncalibrated["status"] as? String == "blocked")
        precondition(!g.commands.contains { $0.hasPrefix("gripper_hold") || $0.hasPrefix("gripper_release") || $0.hasPrefix("calibrate") })
        print("Object handoff: empty preparation calibrates once; grip/release never moves an arm, reopens before closing, or recalibrates around an object")
        g.commands = []
        let relax = await run("left_relax")
        precondition(relax["status"] as? String == "completed", relax.description)
        precondition(g.mode["right"] == 0 && g.q["left"]! == rightBefore)
        precondition(g.commands.firstIndex(of: "deactivate:right")! > g.commands.lastIndex(of: "waypoint_0:right")!)
        precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        print("Left return: reverse taught route, measured hanging before torque-off, right arm unchanged")
        // Trip only after real position-mode entry/dispatch. No automatic retry.
        g.commands = []; g.current = 0.2
        UserDefaults.standard.set(0.1, forKey: ROBLeftArmTrial.currentLimitKey)
        g.onWaypoint = { g.current = 2 }
        let currentTrip = await run("left_wave")
        precondition(currentTrip["status"] as? String == "blocked", currentTrip.description)
        precondition((currentTrip["detail"] as? String)?.contains("current jump") == true)
        precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 1)
        precondition(g.commands.contains("priority_hold:right"))
        precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        g.onWaypoint = nil; g.current = 0.2
        print("Current jump: configured cutoff cancels remaining waypoints, requests left hold, retains recording and releases ownership")
        // A stationary command cannot secretly bring a hanging arm forward.
        g.q["right"] = Array(repeating: 0, count: 7); g.mode["right"] = 0; g.commands = []
        let notInFront = await run("left_grip")
        precondition(notInFront["status"] as? String == "blocked")
        precondition(!g.commands.contains { $0.hasPrefix("waypoint") || $0.hasPrefix("position_mode") || $0.hasPrefix("gripper_") })
        // Stale feedback and gateway replacement both stop without torque-off.
        UserDefaults.standard.set(0, forKey: ROBLeftArmTrial.currentLimitKey)
        for fault in ["stale", "session", "camera", "cancel"] {
            g.commands = []; g.stale = false; ROBArmRoutineVision.shared.fresh = true
            g.q["right"] = Array(repeating: 0, count: 7); g.mode["right"] = 0
            g.onWaypoint = {
                switch fault {
                case "stale": g.stale = true
                case "session": g.generation += 1
                case "camera": ROBArmRoutineVision.shared.fresh = false
                default: trial.cancel(reason: "Fixture operator Stop")
                }
            }
            let failed = await run("left_wave")
            precondition(failed["status"] as? String == "blocked", failed.description)
            precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 1)
            precondition(g.commands.contains("priority_hold:right"))
            precondition(!g.commands.contains { $0.hasPrefix("deactivate") })
            precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        }
        print("Stop/faults: stale feedback, replaced session, camera loss and operator cancellation prevent any subsequent waypoint and retain torque")
        precondition(approvals == 16)
    }
    static func main() async throws { setbuf(stdout, nil); try await tests(); print("Left-arm trial fixtures passed; no hardware transport exists in this executable") }
}
