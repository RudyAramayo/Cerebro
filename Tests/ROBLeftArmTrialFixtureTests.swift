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
    var expectedGripperIntensity = 10
    var gripperIntensities: [Int] = []
    var activeLeases: Set<String> = []
    var rejectHold = false
    var confirmHold = true
    var rejectRelease = false
    var afterRelease: (() -> Void)?
    var afterGrip: (() -> Void)?
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
    func ack(_ operation: String, _ arm: String, accepted: Bool = true, holdConfirmed: Bool? = nil) -> UInt64 {
        let id = nextID; nextID += 1
        commands.append("\(operation):\(arm)")
        DispatchQueue.main.async {
            var info: [String: Any] = ["commandID": NSNumber(value: id), "accepted": accepted, "operation": operation]
            if let holdConfirmed { info["holdConfirmed"] = holdConfirmed }
            NotificationCenter.default.post(name: .ROBAmberGatewayCommandDidComplete, object: self,
                userInfo: info)
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
        precondition(ROBLeftArmInteractionPlan.allowsDirectMove(from: q[arm]!, to: index), "Compacted trial cut a corridor corner")
        precondition(telemetry(forArm: arm)!.statuses.allSatisfy { $0.intValue == 2 })
        q[arm] = ROBLeftArmInteractionPlan.target(index: index)!
        activeLeases.insert(arm)
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
        activeLeases.insert("right")
        let id = ack("ghost_step_\(index)", "right"); onGhostStep?(); return id
    }
    func priorityHold(forArm arm: String) -> UInt64 {
        if !rejectHold { activeLeases.remove(arm) }
        return ack("priority_hold", arm, accepted: !rejectHold, holdConfirmed: confirmHold)
    }
    func renewLease(forArm arm: String, leaseMilliseconds: UInt32) -> UInt64 { ack("renew_lease", arm, accepted: !rejectRenewal) }
    func deactivateArm(_ arm: String) -> UInt64 {
        precondition(ROBArmRoutinePlan.near(q[arm]!, Array(repeating: 0, count: 7)), "Torque removed away from hanging")
        activeLeases.remove(arm)
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
        // Match the production gateway: settling does not release a lease,
        // and an attempted calibration invalidates earlier acceptance first.
        calibrated.remove(arm)
        guard !activeLeases.contains(arm) else { return ack("calibrate", arm, accepted: false) }
        calibrated.insert(arm)
        return ack("calibrate", arm)
    }
    func controlGripper(forArm arm: String, action: String, force: Int) -> UInt64 {
        if assertStationaryGripperApproval {
            precondition(!ROBLeftArmTrial.shared.authorizesTaughtWaypoint(arm: arm,
                expectedSessionGeneration: generation), "Stationary gripper approval authorized arm travel")
        }
        precondition(force == expectedGripperIntensity)
        gripperIntensities.append(force)
        precondition(calibrated.contains(arm), "Uncalibrated jaw command")
        let id = ack("gripper_\(action)", arm, accepted: action != "release" || !rejectRelease)
        if action == "release" { afterRelease?() }
        if action == "hold" { afterGrip?() }
        return id
    }
}

final class ROBWorkspaceSearch {
    static let shared = ROBWorkspaceSearch()
    var lastReport: NSDictionary = ["detail": "Fixture search only"]
    @MainActor func run(targets: [ROBWorkspaceTarget], model: ROBGhostRobotModel, check: () throws -> Void, progress: (String) -> Void) async throws -> [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] {
        try check(); return [:]
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
        precondition(!trial.continueOperation(stage: "object_placed"), "Idle readiness admitted an operation")
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
        precondition(g.commands.filter { $0.hasPrefix("waypoint_") }.count == 11)
        precondition(Array(g.commands.filter { $0.hasPrefix("waypoint_") }.prefix(7)) ==
            [1,4,6,18,28,34,42].map { "waypoint_\($0):right" })
        precondition(g.commands.filter { $0.hasPrefix("waypoint_") }.suffix(4) == ["waypoint_43:right", "waypoint_42:right", "waypoint_43:right", "waypoint_42:right"])
        precondition(g.q["right"]! == plan.target(index: plan.waveRestIndex)!)
        precondition(!g.commands.contains { $0.hasPrefix("gripper_hold") || $0.hasPrefix("gripper_release") || $0.hasPrefix("calibrate") })
        precondition(g.q["left"]! == rightBefore)
        precondition(ROBArmRoutineVision.shared.observationCount == 0)
        precondition((wave["current_samples"] as? Int ?? 0) > 20)
        let csv = try String(contentsOfFile: wave["current_recording"] as! String, encoding: .utf8)
        precondition(csv.contains("current_raw,current_delta_raw") && csv.contains(",left,right,"))
        precondition(csv.contains("waypoint 6"))
        precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        print("Left wave: one approval, 11 registered corridor segments instead of 46 stops, no right-arm or jaw commands, current CSV saved")
        g.commands = []
        let prepare = await run("left_prepare")
        precondition(prepare["status"] as? String == "accepted_unverified", prepare.description)
        precondition(g.commands.filter { $0.hasPrefix("calibrate") } == ["calibrate:right"])
        precondition(g.commands.contains("gripper_release:right"))
        let heldForPrepare = g.commands.firstIndex(of: "priority_hold:right")!
        precondition(heldForPrepare > g.commands.lastIndex(of: "waypoint_\(plan.frontIndex):right")!)
        precondition(heldForPrepare < g.commands.firstIndex(of: "calibrate:right")!)
        precondition(!g.activeLeases.contains("right"))
        // A reply may acknowledge the hold request without confirming a
        // measured-pose hold. Neither that nor a refused hold permits jaws.
        for refused in [false, true] {
            g.commands = []; g.calibrated = []
            g.q["right"] = plan.target(index: plan.frontIndex - 1)!
            g.rejectHold = refused; g.confirmHold = false
            let failedHold = await run("left_prepare")
            precondition(failedHold["status"] as? String == "blocked", failedHold.description)
            precondition(g.commands.contains("priority_hold:right"))
            precondition(!g.commands.contains { $0.hasPrefix("gripper_") || $0.hasPrefix("calibrate") })
            precondition(g.mode["right"] == 2, "Failed gripper setup removed torque")
        }
        g.rejectHold = false; g.confirmHold = true
        g.activeLeases = []; g.calibrated = ["right"]
        print("Lease-to-gripper handoff: prepare cancels its settled trajectory lease with a confirmed hold; refused or unconfirmed holds block all jaw commands")
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
        let centerQ = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!
        let hand = model.toolPosition(model.positions(vendorLeft: centerQ))!
        let view = ROBWorkspaceView(panDegrees: 0, upperTarget: 6906)
        let can = ROBWorkspaceLocatedObject(target: .can, position: [hand.x,hand.y,hand.z], confidence: 0.9,
            capturedAt: 1000, sequence: 1, view: view)
        let bucket = ROBWorkspaceLocatedObject(target: .orangeBucket, position: [hand.x,hand.y + 0.08,hand.z - 0.10],
            confidence: 0.9, capturedAt: 1500, sequence: 2, view: view)
        let task = try ROBWorkspaceGrounding.task(can: can, bucket: bucket, model: model)
        let tabletop = try ROBLeftGestureCompiler.compile(kind: "tabletop", name: task.name, poses: task.poses,
            model: model, baseline: centerQ, generation: g.generation)
        g.assertStationaryGripperApproval = false; g.expectedGripperIntensity = 2
        g.commands = []; g.gripperIntensities = []
        let taskApprovalCount = approvals
        let transferred = await run(tabletop, model: model)
        precondition(transferred["status"] as? String == "accepted_unverified", transferred.description)
        precondition(transferred["motion_completed"] as? Bool == true && transferred["placement_verified"] as? Bool == false)
        precondition(approvals == taskApprovalCount + 1 && trial.interactionStage.isEmpty)
        precondition(g.gripperIntensities == [2,2,2])
        precondition(g.commands.filter { $0.hasPrefix("gripper_") && !$0.hasPrefix("gripper_state") } ==
            ["gripper_release:right", "gripper_hold:right", "gripper_release:right"])
        precondition(g.q["right"] == tabletop.steps.last!.positions && g.mode["right"] == 2)
        precondition(!g.commands.contains { $0.hasPrefix("deactivate") || $0.hasSuffix(":left") })
        precondition(g.commands.filter { $0.hasPrefix("ghost_step") }.count == tabletop.steps.count)
        print("Recycling execution: one approval, no Continue, exact frozen path, hold before each jaw, intensity 2, final held retreat and honest unverified placement")
        // A lost motor after closing must not release, retreat or initiate the
        // previous empty-arm recovery. This tests the actual task executor.
        g.commands = []; g.q["right"] = centerQ; g.afterGrip = { g.stale = true }
        let interruptedTask = await run(tabletop, model: model)
        precondition(interruptedTask["status"] as? String == "blocked")
        precondition(g.commands.filter { $0 == "gripper_release:right" }.count == 1)
        precondition(g.commands.contains("priority_hold:right"))
        g.stale = false; g.afterGrip = nil
        do { _ = try trial.recoveryProposal(model: model); preconditionFailure("Offered empty-arm recovery with a possible held can") }
        catch { }
        g.q["right"] = centerQ; g.commands = []; g.expectedGripperIntensity = 10
        print("Recycling interruption: lost feedback after grip cancels release/retreat and never offers an empty-arm return")
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
        precondition(approvals == 20)

        // One authenticated approval covers the complete, bounded interaction.
        // Local readiness cannot be queued early or skip any physical step.
        g.onWaypoint = nil; g.stale = false; ROBArmRoutineVision.shared.fresh = true
        g.q["right"] = Array(repeating: 0, count: 7); g.mode["right"] = 0
        g.activeLeases = []; g.calibrated = []; g.commands = []
        g.expectedGripperIntensity = 2; g.gripperIntensities = []
        var readyStages: [String] = []
        var scheduledStages: Set<String> = []
        let beforeCycle = approvals
        var preparedViews = 0
        let viewObserver = NotificationCenter.default.addObserver(forName: Notification.Name("ROBLeftArmTrialViewPrepared"),
            object: trial, queue: .main) { note in
                preparedViews += 1
                precondition(note.userInfo?["executionID"] is UUID)
                precondition(g.activeLeases.isEmpty, "Prepared-view snapshot was requested during a motion lease")
                precondition(!g.commands.contains { $0.hasPrefix("position_mode") || $0.hasPrefix("waypoint") })
            }
        trial.statusChanged = { _ in
            let stage = trial.interactionStage
            guard !stage.isEmpty, scheduledStages.insert(stage).inserted else { return }
            let count = g.commands.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                precondition(trial.interactionStage == stage && trial.isRunning)
                precondition(g.commands.count == count, "Waiting for readiness dispatched a motor or jaw command")
                precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 5,
                    "Object cycle moved a potentially held object")
                precondition(!g.activeLeases.contains("right"))
                precondition(!trial.authorizesTaughtWaypoint(arm: "right", expectedSessionGeneration: g.generation))
                let wrong = stage == "object_placed" ? "receiver_supporting" : "object_placed"
                precondition(!trial.continueOperation(stage: wrong), "Out-of-order readiness skipped a stage")
                readyStages.append(stage)
                precondition(trial.continueOperation(stage: stage))
                precondition(!trial.continueOperation(stage: stage), "A duplicate readiness signal was accepted")
            }
        }
        let cycle = await run("left_object_cycle")
        trial.statusChanged = nil
        NotificationCenter.default.removeObserver(viewObserver)
        precondition(cycle["status"] as? String == "completed", cycle.description)
        precondition(cycle["gripper_measured"] as? Bool == false)
        precondition(approvals == beforeCycle + 1 && preparedViews == 1)
        precondition(readyStages == ["object_placed", "receiver_supporting", "object_clear"])
        precondition(g.gripperIntensities == [2, 2, 2])
        precondition(g.commands.filter { $0.hasPrefix("gripper_") && $0 != "gripper_state:right" } ==
            ["gripper_release:right", "gripper_hold:right", "gripper_release:right"])
        precondition(g.commands.filter { $0.hasPrefix("calibrate") }.count == 1, "Cycle recalibrated around an object")
        precondition(g.commands.filter { $0.hasPrefix("waypoint") } ==
            [1,4,6,18,28,18,6,4,1,0].map { "waypoint_\($0):right" })
        precondition(g.mode["right"] == 0 && g.q["right"]! == Array(repeating: 0, count: 7))
        precondition(g.q["left"]! == rightBefore && g.commands.allSatisfy { $0.hasSuffix(":right") })
        precondition(trial.interactionStage.isEmpty && !trial.continueOperation(stage: "object_clear"))
        print("Object cycle: one approval, three non-skippable readiness waits, intensity 2, stationary object handoff, five-leg raise/empty return and verified deactivation")

        // Faults at readiness never trigger a surprise jaw action or lower.
        for (failedStage, fault) in [("object_placed", "stale"), ("object_placed", "session"),
                                     ("object_placed", "cancel"), ("receiver_supporting", "cancel"),
                                     ("object_clear", "stale"), ("receiver_supporting", "expired")] {
            g.q["right"] = Array(repeating: 0, count: 7); g.mode["right"] = 0
            g.activeLeases = []; g.commands = []; g.gripperIntensities = []
            g.stale = false; ROBArmRoutineVision.shared.fresh = true
            g.calibrated = ["right"]
            scheduledStages = []
            var commandCountAtFault = 0
            let clock = broker.now
            trial.statusChanged = { _ in
                let stage = trial.interactionStage
                guard !stage.isEmpty, scheduledStages.insert(stage).inserted else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if stage != failedStage {
                        precondition(trial.continueOperation(stage: stage)); return
                    }
                    commandCountAtFault = g.commands.count
                    switch fault {
                    case "stale": g.stale = true
                    case "session": g.generation += 1
                    case "expired": broker.now = { clock().addingTimeInterval(181) }
                    default: trial.cancel(reason: "Fixture Stop while waiting for object readiness")
                    }
                    precondition(!trial.continueOperation(stage: stage), "Faulted readiness resumed an operation")
                }
            }
            let failed = await run("left_object_cycle")
            trial.statusChanged = nil
            while trial.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            broker.now = clock
            precondition(["blocked", "cancelled"].contains(failed["status"] as? String ?? ""), failed.description)
            precondition(commandCountAtFault > 0)
            precondition(g.commands.dropFirst(commandCountAtFault).allSatisfy { $0 == "priority_hold:right" },
                "Faulted object cycle sent a later jaw or lowering command")
            let expected = failedStage == "object_placed" ? 1 : failedStage == "receiver_supporting" ? 2 : 3
            precondition(g.gripperIntensities == Array(repeating: 2, count: expected))
            precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 5)
            precondition(!g.commands.contains("deactivate:right") && g.mode["right"] == 2)
            precondition(trial.interactionStage.isEmpty && ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        }
        g.expectedGripperIntensity = 10; g.stale = false
        precondition(approvals == beforeCycle + 7)
        print("Object-cycle waits: stale feedback, replaced session, expired approval and Stop prevent subsequent close/release/lower, retain torque and invalidate readiness")
    }
    static func main() async throws { setbuf(stdout, nil); try await tests(); print("Left-arm trial fixtures passed; no hardware transport exists in this executable") }
}
