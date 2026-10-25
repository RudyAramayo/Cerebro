import AppKit
import simd

// Hardware-free workspace-gate fixtures do not fabricate pixel evidence.
// Pure verifier fixtures separately exercise actual RGB-D tracking. Any legacy
// travel-positive case reaching this adapter must stop instead of inventing it.
enum ROBRecyclingVisualInspection {
    enum TargetMoved:Error {case displacement(Double)}
    static var fixedContext=false
    @_optimize(none)
    @MainActor static func fixedHeadContextIsCurrent(model:ROBGhostRobotModel,map:ROBWorkspaceCollisionSnapshot)->Bool {fixedContext}
    struct Context {}
    @_optimize(none)
    @MainActor static func begin(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,gatewayArm:String,check:() throws ->Void) async throws ->Context {
        throw ROBArmRoutineError.blocked("No synthetic visual baseline has been supplied to this fixture.")
    }
    @_optimize(none)
    @MainActor static func beginVisualCalibrationTrial(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,
        map:ROBWorkspaceCollisionSnapshot,trial:ROBWorkspaceVisualCalibrationTrial,gatewayArm:String,
        check:() throws ->Void) async throws ->Context {
        try check()
        throw ROBArmRoutineError.blocked("No synthetic unmeasured visual baseline has been supplied to this fixture.")
    }
    @_optimize(none)
    @MainActor static func verifyAfterLift(context:Context,model:ROBGhostRobotModel,gatewayArm:String,check:() throws ->Void) async throws ->ROBVisualGraspVerifier.Evidence {
        throw ROBArmRoutineError.blocked("No synthetic visual motion evidence has been supplied to this fixture.")
    }
}

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
    func isReserved(_ arm:ROBArmSide,owner:UUID)->Bool {owners[arm]==owner}
}
final class ROBAmberGestureExecutor {
    static let shared = ROBAmberGestureExecutor()
    var isExecuting = false
}
final class ROBGripperStartupCalibration {
    static let shared = ROBGripperStartupCalibration()
    var setupCalls = 0
    func stop(reason: String) {}
    func calibrationReady(forArm arm: String) -> Bool { ROBAmberGatewayClient.shared.calibrated.contains(arm) }
    @MainActor func ensureReady(whileParkedBy owner: UUID) async throws {
        let gateway = ROBAmberGatewayClient.shared
        precondition(gateway.mode.values.allSatisfy { $0 == 0 })
        precondition(gateway.q.values.allSatisfy { ROBArmRoutinePlan.near($0,Array(repeating:0,count:7)) })
        precondition(ROBAmberArmMotionArbiter.shared.owners.values.allSatisfy { $0 == owner })
        setupCalls += 1
        gateway.calibrated = ["left","right"]
        gateway.calibrationReadyAt = 0; gateway.emptyJawInitialized = true
    }
}
final class ROBAmberGatewayTunnel {
    static let shared = ROBAmberGatewayTunnel()
    var failureDetail: String?
    var connections = 0
    func connect(host: String? = nil) { connections += 1 }
}
final class ROBAmberGatewayTelemetry {
    let arm = "right"
    var currents: [NSNumber] = Array(repeating: NSNumber(value: 0.2), count: 7)
    let sequence: UInt64
    let positionsRadians: [NSNumber]
    let statuses: [NSNumber]
    let effectiveSampleAgeMilliseconds: Double
    let sampleAgeAtReceiptMilliseconds: Double
    let effectiveGripperFeedbackAgeMilliseconds = 1.0
    init(sequence: UInt64, positions: [Double], stale: Bool, status: Int, queuedMilliseconds: Double = 0) {
        self.sequence = sequence; positionsRadians = positions.map(NSNumber.init(value:))
        statuses = Array(repeating: NSNumber(value: status), count: 7)
        sampleAgeAtReceiptMilliseconds = stale ? 1000 : 1
        effectiveSampleAgeMilliseconds = sampleAgeAtReceiptMilliseconds + queuedMilliseconds
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
    var calibrationReadyAt = 0.0
    var jawsOpened = false
    var emptyJawInitialized = false
    var afterEmptyInitialization: (() -> Void)?
    var expectedGripperIntensity = 10
    var expectedOpeningIntensity: Int?
    var gripperIntensities: [Int] = []
    var activeLeases: Set<String> = []
    var rejectHold = false
    var confirmHold = true
    var rejectRelease = false
    var afterRelease: (() -> Void)?
    var afterGrip: (() -> Void)?
    var afterStateQuery: (() -> Void)?
    var sequence: UInt64 = 1, nextID: UInt64 = 1
    var freezeSequenceForArms: Set<String> = [] { didSet { frozenSequences = [:] } }
    private var frozenSequences: [String:UInt64] = [:]
    var onTelemetry: ((String) -> Void)?
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
        onTelemetry?(arm)
        let deliveredSequence: UInt64
        if freezeSequenceForArms.contains(arm) {
            if frozenSequences[arm] == nil { frozenSequences[arm] = sequence }
            deliveredSequence = frozenSequences[arm]!
        } else { deliveredSequence = sequence }
        let status = ProcessInfo.processInfo.systemUptime < (modeFeedbackReadyAt[arm] ?? 0) ? 1 : mode[arm]!
        let sample = ROBAmberGatewayTelemetry(sequence: deliveredSequence, positions: q[arm]!, stale: stale, status: status)
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
    var beforeGhostAdmission: (() -> Void)?
    func sendApprovedLeftGestureStep(proposalID: UUID, index: Int, duration: Double, expectedSessionGeneration: UInt64) -> UInt64 {
        beforeGhostAdmission?()
        guard let target = ROBLeftArmTrial.shared.approvedGestureTarget(id: proposalID, index: index,
            seconds: duration, generation: expectedSessionGeneration) else { return 0 }
        precondition(ROBLeftArmTrial.shared.approvedGestureTarget(id: UUID(), index: index, seconds: duration,
            generation: expectedSessionGeneration) == nil)
        precondition(ROBLeftArmTrial.shared.approvedGestureTarget(id: proposalID, index: index + 1, seconds: duration,
            generation: expectedSessionGeneration) == nil)
        let selected=ROBLeftArmTrial.shared.executionGatewayArm
        q[selected] = target
        activeLeases.insert(selected)
        let id = ack("ghost_step_\(index)", selected); onGhostStep?(); return id
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
        calibrationReadyAt = ProcessInfo.processInfo.systemUptime + 8
        emptyJawInitialized = false
        jawsOpened = false
        return ack("calibrate", arm)
    }
    func controlGripper(forArm arm: String, action: String, force: Int) -> UInt64 {
        if assertStationaryGripperApproval {
            precondition(!ROBLeftArmTrial.shared.authorizesTaughtWaypoint(arm: arm,
                expectedSessionGeneration: generation), "Stationary gripper approval authorized arm travel")
        }
        let initializing = ROBLeftArmTrial.shared.status.hasPrefix("Initializing empty left jaws")
        precondition(force == (initializing ? 2 : action == "release" ? expectedOpeningIntensity ?? expectedGripperIntensity : expectedGripperIntensity))
        gripperIntensities.append(force)
        // Firmware may accept an opening while calibration still owns the
        // motor, without physically executing it. Reproduce the live miss.
        if action == "release" { jawsOpened = emptyJawInitialized && ProcessInfo.processInfo.systemUptime >= calibrationReadyAt }
        else {
            jawsOpened = false
            if initializing && ProcessInfo.processInfo.systemUptime >= calibrationReadyAt { emptyJawInitialized = true }
        }
        precondition(calibrated.contains(arm), "Uncalibrated jaw command")
        let id = ack("gripper_\(action)", arm, accepted: action != "release" || !rejectRelease)
        if action == "release" { afterRelease?() }
        if initializing { afterEmptyInitialization?() }
        else if action == "hold" { afterGrip?() }
        return id
    }
}

enum ROBNeckRGBPoseDisplay {
    static var projectionIdentity:String? = nil
    static func estimatedCameraProjectionIdentity(model:ROBGhostRobotModel)->String? {projectionIdentity}
}

final class ROBFixedHeadCalibrationWindowController {
    static let shared=ROBFixedHeadCalibrationWindowController()
    var readNeck:(()->NSDictionary)? = { ["known":true,"stationary":true,"pan":6015,"pan_degrees":0.0,"lower":6011,"upper":6160,"ready_at":0.0] }
}

struct ROBWorkspaceCanSelection {
    let object:ROBWorkspaceLocatedObject?
    let preview:ROBCanGrabPreview?
    let diagnostics:[[String:Any]]
}

final class ROBWorkspaceSearch {
    static let shared = ROBWorkspaceSearch()
    var announce: ((String) -> Void)?
    var lastReport: NSDictionary = ["detail": "Fixture search only"]
    private var collisionSnapshotValue: ROBWorkspaceCollisionSnapshot?
    var collisionScanCalls = 0
    var failCollisionScan = false
    var syntheticDistantPlane = false
    var estimatedContext = false
    var nearestSelectionCalls=0
    var prepareView:((Double,Int)->Bool)? = {_,_ in true}
    var viewReady:((Double,Int)->Bool)? = {_,_ in true}
    @MainActor func nearestReachableCan(model:ROBGhostRobotModel,baseline:[String:Double],map:ROBWorkspaceCollisionSnapshot,
        calibrationFile:URL?=nil,nowMilliseconds:Double=Date().timeIntervalSince1970*1000) async ->ROBWorkspaceCanSelection {
        nearestSelectionCalls += 1
        return .init(object:objects[.can],preview:nil,diagnostics:[["fixture":true,"path_admitted":false]])
    }
    func estimatedContextIsCurrent(model:ROBGhostRobotModel,map:ROBWorkspaceCollisionSnapshot)->Bool {estimatedContext}
    func estimatedCameraProjectionIsCurrent(model:ROBGhostRobotModel,map:ROBWorkspaceCollisionSnapshot)->Bool {
        map.estimatedCameraProjectionIdentity==ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)
    }
    @MainActor func captureEstimatedOrRegisteredCurrentScene(model:ROBGhostRobotModel,generation:UInt64,
        check:() throws->Void,progress:(String)->Void) async throws->ROBWorkspaceCollisionSnapshot {
        try await captureRegisteredCurrentScene(model:model,generation:generation,check:check,progress:progress)
    }
    var onCollisionScan: (() -> Void)?
    var collisionSnapshot: ROBWorkspaceCollisionSnapshot? {
        guard let value = collisionSnapshotValue,
              value.cameraGeneration == ROBArmRoutineVision.shared.cameraGeneration,
              value.sessionGeneration == ROBAmberGatewayClient.shared.generation,
              (0...60_000).contains(Date().timeIntervalSince1970 * 1000 - value.oldestCapturedAtMilliseconds) else { return nil }
        return value
    }
    @MainActor func captureRegisteredCurrentScene(model:ROBGhostRobotModel,generation:UInt64,
        check:() throws->Void,progress:(String)->Void) async throws->ROBWorkspaceCollisionSnapshot {
        try await scanCollisionScene(model:model,generation:generation,check:check,progress:progress)
    }
    func clearCollisionScene() { collisionSnapshotValue = nil }
    @MainActor func scanCollisionScene(model: ROBGhostRobotModel, generation: UInt64,
        check: () throws -> Void, progress: (String) -> Void) async throws -> ROBWorkspaceCollisionSnapshot {
        collisionScanCalls += 1; collisionSnapshotValue = nil
        try check(); onCollisionScan?()
        if failCollisionScan { throw ROBArmRoutineError.blocked("Fixture RGB-D scene unavailable") }
        let now = Date().timeIntervalSince1970 * 1000
        let camera = ROBArmRoutineVision.shared.cameraGeneration
        var map = ROBWorkspaceDepthMap(modelID: model.modelID, geometryID: model.geometryID,
            mappingID: model.selectedMappingID, sessionGeneration: generation,
            cameraGeneration: camera, nowMilliseconds: now - 200,
            estimatedCameraProjectionIdentity:ROBNeckRGBPoseDisplay.projectionIdentity)
        var transform = ROBWorkspaceView(panDegrees: 0, upperTarget: 6306).cameraFrame(model: model)!
        // Explicit synthetic scene for the estimated-runtime fixture only:
        // distant occupied returns leave the arm's local volume UNKNOWN. This
        // never creates registration evidence or bypasses the real mapper.
        if syntheticDistantPlane { transform = matrix_identity_double4x4; transform.columns.3 = SIMD4(1.3,1.3,0,1) }
        for (sequence, age) in [(UInt64(1), 100.0), (UInt64(2), 50.0)] {
            try map.append(width: 24, height: 24, fx: 24, fy: 24, cx: 12, cy: 12,
                depth: { _, _ in 900 }, cameraToRobot: transform, capturedAtMilliseconds: now-age,
                sequence: sequence, cameraGeneration: camera, nowMilliseconds: now,
                recordedPanDegrees: 0, recordedUpperTarget: 6306,recordedLowerTarget:6011,
                estimatedCameraProjectionIdentity:ROBNeckRGBPoseDisplay.projectionIdentity)
        }
        let snapshot = map.snapshot(nowMilliseconds: now)!
        precondition(snapshot.observedFrameCount == 2 && snapshot.occupiedVoxelCount > 0 && snapshot.freeVoxelCount > 0)
        precondition(snapshot.registrationID == nil && snapshot.registrationUncertaintyMeters == nil,
            "Synthetic RGB-D must never manufacture measured camera-to-arm registration")
        try check()
        collisionSnapshotValue = snapshot
        lastReport = ["status": "depth_scene_captured", "detail": snapshot.registrationDetail,
            "collision_map_frames": snapshot.observedFrameCount, "arm_motion_sent": false]
        return snapshot
    }

    var fail = false
    var requiredDepth = true
    var requestedTargets: [ROBWorkspaceTarget] = []
    var objects: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]
    var onInspect: (() -> Void)?
    var afterInspect: (() -> Void)?
    @MainActor func run(targets: [ROBWorkspaceTarget], model: ROBGhostRobotModel, requireDepth: Bool = true, check: () throws -> Void, progress: (String) -> Void) async throws -> [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] {
        requiredDepth = requireDepth
        requestedTargets = targets
        onInspect?()
        if fail { throw ROBArmRoutineError.blocked("Fixture observation unavailable") }
        if requireDepth {
            _ = try await scanCollisionScene(model: model, generation: ROBAmberGatewayClient.shared.generation,
                check: check, progress: progress)
        }
        try check(); afterInspect?(); return objects
    }
}

final class ROBArmRoutineVision {
    static let shared = ROBArmRoutineVision()
    var fresh = true, handsClear = true, blocked = false, objectInRight = false
    var cameraGeneration = UUID()
    var observationCount = 0
    var activationHistory: [Bool] = []
    var runtimeIdentity=String(repeating:"a",count:64)
    var clearsFramesOnSetActive=false,frameAvailable=true
    struct RuntimeCalibration {let identity:String}
    struct Intrinsics {let runtimeCalibration:RuntimeCalibration?}
    struct Frame {let cameraGeneration:UUID;let intrinsics:Intrinsics?}
    func snapshot()->[String:Frame] {frameAvailable ? ["face":.init(cameraGeneration:cameraGeneration,intrinsics:.init(runtimeCalibration:.init(identity:runtimeIdentity)))] : [:]}
    var readinessDescription: String { "Simulated camera unavailable" }
    func healthSnapshot() -> NSDictionary { ["fixture": true] }
    func setActive(_ active: Bool, teaching: Bool = false) {
        activationHistory.append(active)
        if clearsFramesOnSetActive {frameAvailable=false}
    }
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
    @_optimize(none)
    @MainActor static func run(_ proposal: ROBLeftGestureProposal, model: ROBGhostRobotModel) async -> NSDictionary {
        await withCheckedContinuation { continuation in
            ROBLeftArmTrial.shared.perform(proposal: proposal, model: model) { continuation.resume(returning: $0) }
        }
    }
    @_optimize(none)
    @MainActor static func run(_ command: String, target: String = "") async -> NSDictionary {
        await withCheckedContinuation { continuation in
            ROBLeftArmTrial.shared.perform(command, target: target) { continuation.resume(returning: $0) }
        }
    }
    @_optimize(none)
    @MainActor static func estimatedCalibrationTests(model: ROBGhostRobotModel, folder: URL) async throws {
        let trial = ROBLeftArmTrial.shared, gateway = ROBAmberGatewayClient.shared
        let search = ROBWorkspaceSearch.shared, vision = ROBArmRoutineVision.shared
        let broker = ROBControllerArmApproval.shared
        let device = UUID(), session = UUID()
        let hello = ROBRobotActionMessage.controllerHello(senderID:"estimated-fixture",acceptsActions:true,capabilities:["arm_operation"])
        _ = broker.receive(hello,device:device,session:session)
        var decision: Bool? = true, requests = 0
        var pendingHook: (() -> Void)?
        broker.send = { message, targetDevice, targetSession in
            if message.kind == .actionRequest {
                requests += 1
                precondition(message.arguments["operation"] as? String == "manual")
                precondition(message.arguments["arm"] as? String == "left")
                precondition((message.arguments["summary"] as? String)?.contains("UNVERIFIED") == true)
                if let decision {
                    DispatchQueue.main.async {
                        _ = broker.receive(.actionStatus(callID:message.callID!,state:decision ? .accepted : .rejected,
                            detail:"Isolated estimated-step decision",result:[:],senderID:message.recipientID!,recipientID:message.senderID),
                            device:targetDevice,session:targetSession)
                    }
                } else { DispatchQueue.main.async { pendingHook?() } }
            }
            return true
        }
        func physicalCommands() -> [String] {
            gateway.commands.filter { !$0.hasPrefix("mode_query:") && !$0.hasPrefix("priority_hold:") }
        }
        func reset() {
            trial.cancel(reason:"Isolated estimated fixture reset")
            broker.cancel(reason:"Isolated estimated fixture reset")
            gateway.ready = true; gateway.stale = false; gateway.rejectHold = false; gateway.confirmHold = true
            gateway.rejectRenewal = false; gateway.q = ["left":Array(repeating:0,count:7),"right":Array(repeating:0,count:7)]
            gateway.mode = ["left":0,"right":0]; gateway.commands = []; gateway.activeLeases = []
            gateway.beforeGhostAdmission = nil; gateway.onGhostStep = nil; gateway.onTelemetry = nil
            search.syntheticDistantPlane = true; search.failCollisionScan = false; search.clearCollisionScene()
            vision.fresh = true; vision.activationHistory = []
            ROBArmRoutineCoordinator.shared.prepareView = { true }
            decision = true; pendingHook = nil
        }
        func preview() async -> NSDictionary {
            await withCheckedContinuation { continuation in trial.prepareEstimatedCalibration { continuation.resume(returning:$0) } }
        }
        func execute() async -> NSDictionary {
            await withCheckedContinuation { continuation in trial.performEstimatedCalibration { continuation.resume(returning:$0) } }
        }
        reset()
        let absent = await execute()
        precondition(absent["status"] as? String == "blocked" && gateway.commands.isEmpty && requests == 0)
        let prepared = await preview()
        precondition(prepared["status"] as? String == "accepted_unverified",prepared.description)
        precondition(gateway.commands.isEmpty && requests == 0 && vision.activationHistory == [true])
        let path = trial.collisionReviewProposal!
        precondition(path.kind == "estimated_calibration" && path.steps.count == 1 && path.steps[0].jawAction == nil)
        precondition(path.workspaceCollisionPlan == nil && path.validForReplay(model:model))
        let previewRecording = URL(fileURLWithPath:prepared["current_recording"] as! String).deletingPathExtension()
        let proof = try JSONDecoder().decode(ROBEstimatedArmCalibrationPlan.self,
            from:Data(contentsOf:previewRecording.appendingPathExtension("estimated-calibration.json")))
        precondition(path.id == proof.id && path.baseline == proof.baseline && path.steps == proof.steps)
        let generic = await run(path,model:model)
        precondition(generic["status"] as? String == "blocked" && requests == 0 && gateway.commands.isEmpty)
        precondition((generic["detail"] as? String)?.contains("generic gesture lane") == true)
        // The failed generic lane does not grant or consume the dedicated path.
        let accepted = await execute()
        precondition(accepted["status"] as? String == "completed",accepted.description)
        precondition(accepted["estimated_calibration_unverified"] as? Bool == true)
        precondition(requests == 1 && gateway.commands.filter { $0 == "ghost_step_0:right" }.count == 1)
        precondition(gateway.commands.allSatisfy { ["mode_query:right","position_mode:right","ghost_step_0:right","renew_lease:right","priority_hold:right"].contains($0) })
        precondition(gateway.q["right"] == proof.target && gateway.mode["right"] == 2 && gateway.activeLeases.isEmpty)
        precondition(vision.activationHistory == [true,false],"Preview capture restarted before the one-step approval/execution")
        precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty && !broker.isPending)
        let physicalRecording = URL(fileURLWithPath:accepted["current_recording"] as! String).deletingPathExtension()
        let performedProof = try JSONDecoder().decode(ROBEstimatedArmCalibrationPlan.self,
            from:Data(contentsOf:physicalRecording.appendingPathExtension("estimated-calibration.json")))
        precondition(performedProof == proof)
        gateway.commands = []
        let replay = await execute()
        precondition(replay["status"] as? String == "blocked" && gateway.commands.isEmpty && requests == 1)
        let chained = await preview()
        precondition(chained["status"] as? String == "blocked" && gateway.commands.isEmpty)
        print("Estimated step: real production proof/mapper, separate runtime approval, exactly one 4-second approved SDK step, tight measured endpoint and confirmed hold; same camera kept live; real-ID proposal/proof JSON; generic lane, consumed replay and blind chaining rejected")

        for scenario in ["decline","pending_stop","map_change","camera_change","session_change","start_drift","dispatch_drift","stop_during_step"] {
            reset()
            let prepared = await preview()
            precondition(prepared["status"] as? String == "accepted_unverified",prepared.description)
            let beforeRequests = requests
            switch scenario {
            case "decline": decision = false
            case "pending_stop": decision = nil; pendingHook = { trial.cancel(reason:"Explicit Stop while waiting for approval") }
            case "map_change": search.clearCollisionScene()
            case "camera_change": vision.cameraGeneration = UUID()
            case "session_change": gateway.generation += 1
            case "start_drift": gateway.q["right"]![0] = 0.002
            case "dispatch_drift": gateway.beforeGhostAdmission = { gateway.q["right"]![0] = 0.002 }
            case "stop_during_step": gateway.onGhostStep = { trial.cancel(reason:"Explicit Stop during estimated step") }
            default: break
            }
            let result = await execute()
            precondition(["rejected","cancelled","blocked"].contains(result["status"] as? String ?? ""),"\(scenario): \(result)")
            let steps = gateway.commands.filter { $0.hasPrefix("ghost_step_") }
            precondition(steps.count == (scenario == "stop_during_step" ? 1 : 0),"\(scenario): \(gateway.commands)")
            precondition(!gateway.commands.contains(where:{ $0.hasPrefix("gripper_") || $0.hasPrefix("calibrate:") || $0.hasPrefix("deactivate:") || $0.hasPrefix("waypoint_") }))
            if ["decline","pending_stop","map_change","camera_change","session_change","start_drift"].contains(scenario) {
                precondition(physicalCommands().isEmpty,"\(scenario): \(gateway.commands)")
            }
            if ["map_change","camera_change","session_change","start_drift"].contains(scenario) { precondition(requests == beforeRequests) }
            precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty && !broker.isPending)
            gateway.commands = []
            let retry = await execute()
            precondition(retry["status"] as? String == "blocked" && gateway.commands.isEmpty)
        }
        reset(); search.syntheticDistantPlane = false
        print("Estimated runtime rejection: decline, Stop before approval/during motion, lost/replaced map, camera/session change, >2mm start/dispatch drift and missing/consumed proof never admit another step or any jaw/encoder/deactivation command")
    }

    @_optimize(none)
    @MainActor static func delayedTelemetryTests() async throws {
        let g = ROBAmberGatewayClient.shared
        for scenario in ["delivery", "source", "live_loss", "malformed", "current_jump"] {
            g.q["right"] = ROBLeftArmInteractionPlan.target(index:ROBLeftArmInteractionPlan.frontIndex)!; g.mode["right"] = 2
            g.calibrated = ["right"]
            g.stale = false; g.commands = []; g.activeLeases = []
            ROBArmRoutineVision.shared.fresh = true
            UserDefaults.standard.set(scenario == "current_jump" ? 0.5 : 0, forKey: ROBLeftArmTrial.currentLimitKey)
            g.afterStateQuery = {
                g.afterStateQuery = nil
                let initial = g.sequence
                if scenario == "current_jump" {
                    let fresh = ROBAmberGatewayTelemetry(sequence: initial + 1, positions: g.q["right"]!, stale: false, status: 2)
                    NotificationCenter.default.post(name: .ROBAmberGatewayTelemetryDidUpdate, object: g, userInfo: ["telemetry": fresh])
                }
                let queued = ROBAmberGatewayTelemetry(sequence: initial + 2, positions: g.q["right"]!,
                    stale: scenario == "source", status: 2, queuedMilliseconds: 700)
                if scenario == "malformed" { queued.currents[3] = NSNumber(value: Double.nan) }
                if scenario == "current_jump" { queued.currents = Array(repeating: NSNumber(value: 5), count: 7) }
                g.sequence = initial + 3 // a strictly newer cache exists while the UI drains its older notification
                g.stale = scenario == "live_loss"
                NotificationCenter.default.post(name: .ROBAmberGatewayTelemetryDidUpdate, object: g,
                    userInfo: ["telemetry": queued])
            }
            let result = await run("left_grip")
            g.afterStateQuery = nil; g.stale = false
            if scenario == "delivery" {
                precondition(result["status"] as? String == "accepted_unverified", result.description)
                precondition(result["delayed_telemetry_samples"] as? Int == 1)
                precondition((result["max_delayed_telemetry_age_ms"] as? Double ?? 0) >= 700)
                let csv = try String(contentsOfFile: result["current_recording"] as! String)
                precondition(csv.contains(",701.0,"), "Queued history must retain its actual delivery age")
            } else {
                precondition(result["status"] as? String == "blocked", "\(scenario): \(result)")
                precondition(g.commands.contains("priority_hold:right"), "A genuine feedback/current fault did not request hold")
            }
            precondition(g.commands.allSatisfy { ["mode_query:right", "priority_hold:right", "gripper_state:right", "gripper_hold:right"].contains($0) },
                "A stationary recording check activated, moved or deactivated an arm")
            precondition(g.q["right"] == ROBLeftArmInteractionPlan.target(index:ROBLeftArmInteractionPlan.frontIndex)!)
            precondition(!ROBControllerArmApproval.shared.authorizesLeftArmTrial("invented"),
                "Recovered feedback restored an old motion grant")
        }
        UserDefaults.standard.set(0, forKey: ROBLeftArmTrial.currentLimitKey)
        print("Delayed telemetry: 700 ms queued history retained only with newer live feedback; stale source, true feedback loss, malformed currents and historical current jumps still stop; stationary jaws only after valid live feedback; no travel or grant recovery")
    }
    @_optimize(none)
    @MainActor static func tests() async throws {
        let dispatchID = UUID(), dispatchMap = String(repeating:"a",count:64)
        let reviewed = ROBReviewedArmDispatchStart(proposalID:dispatchID,index:3,generation:42,mapFingerprint:dispatchMap,
            positions:Array(repeating:0,count:7),sequence:100,reviewCompletedAtUptime:10)
        func admits(_ positions:[Double] = Array(repeating:0,count:7), id:UUID = dispatchID, index:Int = 3,
                    generation:UInt64 = 42, map:String = dispatchMap, sequence:UInt64 = 101, now:Double = 10.1) -> Bool {
            reviewed.matches(proposalID:id,index:index,generation:generation,mapFingerprint:map,
                positions:positions,sequence:sequence,nowUptime:now)
        }
        precondition(admits() && admits(Array(repeating:0.0001,count:7)))
        var singleDrift = Array(repeating:0.0,count:7); singleDrift[0] = 0.0012
        precondition(admits(singleDrift))
        singleDrift[0] = 0.0014
        precondition(!admits(singleDrift),"A >2mm bounded point drift was admitted")
        precondition(!admits(Array(repeating:0.0003,count:7)),"Small simultaneous joint drifts escaped the aggregate swept bound")
        precondition(!admits([0.001,-0.001,0,0,0,0,0]),"Opposing joint drift signs cancelled each other")
        precondition(!admits(id:UUID()) && !admits(index:4) && !admits(generation:43) && !admits(map:String(repeating:"b",count:64)))
        precondition(!admits(sequence:99) && !admits(now:10.251) && !admits(now:9.999) && !admits(now:Double.nan))
        precondition(!admits([Double.nan,0,0,0,0,0,0]) && !admits([0,0]))
        print("Reviewed-start admission: fresh matching proposal/step/session/map accepted; aggregate >2mm point drift, reordered feedback, expired/future time and mismatched identities blocked; no hardware or approval bypass")
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
        trial.canReachCalibrationFile = folder.appendingPathComponent("isolated-can-calibration.json")
        trial.recyclingTestParametersFile = folder.appendingPathComponent("isolated-recycling-parameters.json")
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
        if CommandLine.arguments.last == "local-receipt" {
            var requests=0,prompts=0
            broker.send={message,_,_ in if message.kind == .actionRequest {requests += 1};return true}
            broker.announceApproval={_ in prompts += 1}
            broker.localRecyclingApprovalAuditDirectory=folder.appendingPathComponent("local-audit")
            ROBNeckRGBPoseDisplay.projectionIdentity=String(repeating:"b",count:64)
            ROBArmRoutineVision.shared.clearsFramesOnSetActive=true
            ROBArmRoutineVision.shared.frameAvailable=true
            g.ready=true;g.stale=false;g.mode=["left":1,"right":1];g.calibrated=["left","right"];g.commands=[]
            ROBWorkspaceSearch.shared.objects=[:]
            func local() async ->NSDictionary {
                await withCheckedContinuation { continuation in
                    trial.performUsingLocalRecyclingReceipt("right_recycle_cans",target:"4"){continuation.resume(returning:$0)}
                }
            }
            var result:NSDictionary?
            Task { @MainActor in result=await local() }
            let pendingEnd=ProcessInfo.processInfo.systemUptime+2
            while broker.pendingLocalRecyclingApprovalScope == nil && ProcessInfo.processInfo.systemUptime<pendingEnd {
                try await Task.sleep(nanoseconds:10_000_000)
            }
            precondition(broker.pendingLocalRecyclingApprovalScope?["command"] as? String == "right_recycle_cans")
            precondition(requests==0 && prompts==0 && g.commands.isEmpty && !trial.isRunning)
            precondition(!broker.receiveSpokenAuthorization("yes proceed"),"Voice cannot impersonate a local imported receipt")
            var receipt=broker.localRecyclingReceiptTemplate as! [String:Any]
            receipt["sourceMessage"]="Synthetic fixture: exactly four cans under one local session instruction."
            receipt["sourceMessageSHA256"]=ROBGhostRobotModel.hash(Data((receipt["sourceMessage"] as! String).utf8))
            receipt["additionalUserInstruction"]="Synthetic fixture: permit best-estimate visual calibration for this exact job."
            receipt["additionalUserInstructionSHA256"]=ROBGhostRobotModel.hash(Data((receipt["additionalUserInstruction"] as! String).utf8))
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let url=folder.appendingPathComponent("synthetic-local-receipt.json")
            try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys).write(to:url)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            try broker.importLocalRecyclingSessionApproval(fromReceiptURL:url)
            let end=ProcessInfo.processInfo.systemUptime+12
            while result == nil && ProcessInfo.processInfo.systemUptime<end {try await Task.sleep(nanoseconds:10_000_000)}
            guard let first=result else {fatalError("Local receipt fixture did not finish")}
            precondition(first["status"] as? String=="not_found",first.description)
            precondition(first["arm_motion_sent"] as? Bool==false && first["reach_sent"] as? Bool==false && first["jaw_command_sent"] as? Bool==false)
            precondition(first["perception_only_rejection"] as? Bool==true && broker.localRecyclingApprovalState?["state"] as? String=="available",first.description)
            precondition(ROBWorkspaceSearch.shared.nearestSelectionCalls==1)
            precondition(!g.commands.contains{$0.hasPrefix("ghost_step") || $0.hasPrefix("waypoint") || $0.hasPrefix("gripper") || $0.hasPrefix("calibrate")})
            let second=await local()
            precondition(second["status"] as? String=="not_found" && requests==0 && prompts==0,second.description)
            precondition(ROBWorkspaceSearch.shared.nearestSelectionCalls==2 && broker.localRecyclingApprovalState?["state"] as? String=="available")
            // An unsafe failure with no trajectory must still revoke, rather
            // than exploiting the perception-only retry exception.
            ROBWorkspaceSearch.shared.afterInspect={g.stale=true}
            let lost=await local()
            precondition(lost["status"] as? String=="blocked" && lost["perception_only_rejection"] as? Bool==false,lost.description)
            precondition(broker.localRecyclingApprovalState == nil && !trial.isRunning)
            ROBWorkspaceSearch.shared.afterInspect=nil;g.stale=false
            ROBNeckRGBPoseDisplay.projectionIdentity=nil
            broker.cancel(reason:"Synthetic local fixture complete")
            print("Local receipt runtime: dedicated exact4 prepare sends no voice/controller request; private URL import authorizes exact job; fresh no-travel/no-jaw perception may retry without another approval, feedback loss revokes; nearest selection used, no fake registration or arm trajectory")
            return
        }
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
        if ["right-estimated","right-estimated-bundle"].contains(CommandLine.arguments.last ?? "") {
            let estimatedBundle = CommandLine.arguments.last == "right-estimated-bundle"
            ROBRecyclingVisualInspection.fixedContext = !estimatedBundle
            ROBWorkspaceSearch.shared.estimatedContext = estimatedBundle
            defer {ROBRecyclingVisualInspection.fixedContext=false;ROBWorkspaceSearch.shared.estimatedContext=false}
            g.ready=true;g.stale=false;g.commands=[];g.mode=["left":1,"right":1]
            g.q=["left":Array(repeating:0,count:7),"right":Array(repeating:0,count:7)]
            ROBWorkspaceSearch.shared.syntheticDistantPlane=true
            ROBWorkspaceSearch.shared.clearCollisionScene()
            ROBArmRoutineCoordinator.shared.prepareView={true};ROBArmRoutineCoordinator.shared.viewIsStationary={true}
            var sides:[String]=[]
            broker.send = { message,_,_ in
                if message.kind == .actionRequest {
                    sides.append(message.arguments["arm"] as! String)
                    precondition(message.arguments["arm"] as? String=="right")
                    precondition((message.arguments["summary"] as? String)?.contains("physical RIGHT-arm") == true)
                    DispatchQueue.main.async {
                        _ = broker.receive(.actionStatus(callID:message.callID!,state:.accepted,
                            detail:"Isolated right nudge decision",result:[:],senderID:"fixture-controller",recipientID:message.senderID),
                            device:device,session:session)
                    }
                }
                return true
            }
            let noProof=await run("right_estimated_trial")
            precondition(noProof["status"] as? String=="blocked" && sides.isEmpty && g.commands.isEmpty)
            let preview=await run("right_estimated_preview")
            precondition(preview["status"] as? String=="accepted_unverified",preview.description)
            precondition(sides.isEmpty && g.commands.isEmpty,"Passive preview actuated or asked for authority")
            let proof=trial.collisionReviewProposal!
            precondition(proof.baseline==Array(repeating:0,count:7) && proof.steps.count==1)
            precondition(proof.steps[0].positions==[-0.03,-0.03,0,0,0,0,0] && proof.steps[0].jawAction==nil)
            let result=await run("right_estimated_trial")
            precondition(result["status"] as? String=="completed",result.description)
            precondition(sides==["right"] && g.commands.filter{$0=="ghost_step_0:left"}.count==1)
            precondition(g.q["left"]==[-0.03,-0.03,0,0,0,0,0] && g.q["right"]==Array(repeating:0,count:7))
            precondition(g.mode==["left":2,"right":1] && g.activeLeases.isEmpty)
            precondition(!g.commands.contains{$0.hasPrefix("calibrate") || $0.hasPrefix("gripper") || $0.hasPrefix("deactivate") || $0.hasPrefix("waypoint")})
            let csv=try String(contentsOfFile:result["current_recording"] as! String,encoding:.utf8)
            precondition(csv.contains(",right,left,"))
            g.commands=[]
            let replay=await run("right_estimated_trial")
            precondition(replay["status"] as? String=="blocked" && g.commands.isEmpty && sides.count==1)
            print("Right estimated runtime: passive active-mode preview, one explicit physical-right approval, one 4s immutable two-joint outward retreat on gateway left, other arm unchanged, no jaw/return/replay; actual pixel/depth acquisition is separately covered, never fabricated here.")
            return
        }
        if ["right-scope","right-three-scope","right-four-scope"].contains(CommandLine.arguments.last ?? "") {
            var requestArms:[String]=[]
            var requestSummaries:[String]=[]
            broker.send = { message,_,_ in
                if message.kind == .actionRequest {
                    requestArms.append(message.arguments["arm"] as! String)
                    requestSummaries.append(message.arguments["summary"] as! String)
                    DispatchQueue.main.async {
                        _ = broker.receive(.actionStatus(callID:message.callID!,state:.accepted,
                            detail:"Isolated scope decision",result:[:],senderID:"fixture-controller",recipientID:message.senderID),
                            device:device,session:session)
                    }
                }
                return true
            }
            _ = await withCheckedContinuation { continuation in broker.beginArmSession {continuation.resume(returning:$0)} }
            precondition(broker.armSessionActive && requestArms == ["left"])
            g.commands=[];g.ready=true;g.stale=false;g.mode=["left":1,"right":1];g.calibrated=["left","right"]
            ROBArmRoutineCoordinator.shared.prepareView={true}; ROBArmRoutineCoordinator.shared.viewIsStationary={true}
            ROBWorkspaceSearch.shared.clearCollisionScene()
            let three = CommandLine.arguments.last == "right-three-scope"
            let four = CommandLine.arguments.last == "right-four-scope"
            if four {
                let originalSide = trial.physicalSide
                for target in ["", "0", "9", "-1", "4.5", "all", "999999999999999999999999999999"] {
                    let rejected = await run("right_recycle_cans", target:target)
                    precondition(rejected["status"] as? String == "rejected", rejected.description)
                    precondition(requestArms == ["left"] && g.commands.isEmpty,
                                 "Invalid batch count requested approval or dispatched a command")
                    precondition(trial.physicalSide == originalSide,
                                 "Invalid batch count changed the selected physical arm")
                }
            }
            let count = four ? 4 : three ? 3 : 1
            let result=await run(four ? "right_recycle_cans" : three ? "right_recycle_three_cans" : "right_recycle_can",
                                 target:four ? " 4\n" : "")
            if count > 1 {
                precondition(result["batch_requested"] as? Int == count && result["batch_completed"] as? Int == 0)
                precondition((result["batch_results"] as? [[String:Any]])?.count == 1,
                             "An unconfirmed first grasp must stop the complete batch")
                precondition(requestSummaries.last?.contains("One approval covers all \(count) complete transfers.") == true,
                             "The approved scope omitted the frozen batch count")
            }
            precondition(requestArms == ["left","both"],"A left-only rehearsal grant was incorrectly reused for the right task")
            precondition(trial.physicalSide=="right" && trial.executionGatewayArm=="left")
            precondition(!broker.authorizesRightArmTrial("invented"))
            precondition(g.mode==["left":2,"right":2],"Both active arms were not held before neck scanning")
            precondition(g.commands.contains("position_mode:left") && g.commands.contains("position_mode:right"))
            precondition(!g.commands.contains {$0.hasPrefix("waypoint_") || $0.hasPrefix("ghost_step_") || $0.hasPrefix("gripper_") || $0.hasPrefix("calibrate:")})
            precondition(g.q.values.allSatisfy {$0==Array(repeating:0.0,count:7)})
            precondition(result["arm_motion_sent"] as? Bool==false && ["not_reachable","not_localized","not_found","needs_help"].contains(result["status"] as? String ?? ""),result.description)
            precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty && !broker.isPending)
            broker.cancel(reason:"Isolated right-scope fixture finished")
            print("Right task scope (\(count) cans): one complete-task approval includes the frozen count; invalid count cannot request authority or change arms; an unconfirmed first item stops the batch; active arms hold without parking or jaw motion and an unregistered map still blocks travel.")
            return
        }
        if CommandLine.arguments.last == "estimated-calibration" {
            let model = try ROBGhostRobotModel(directory:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
            try await estimatedCalibrationTests(model:model,folder:folder)
            return
        }
        // Neck-only observations do not request arm authority, connect a
        // gateway, or issue a hold even when their camera inspection fails.
        g.ready = false
        ROBWorkspaceSearch.shared.onInspect = {
            let stale = ROBAmberGatewayTelemetry(sequence: 1, positions: g.q["right"]!, stale: true, status: 0)
            NotificationCenter.default.post(name: .ROBAmberGatewayTelemetryDidUpdate, object: g, userInfo: ["telemetry": stale])
        }
        for command in ["left_search_workspace", "left_check_hanging"] {
            let searched = await run(command)
            precondition(searched["status"] as? String == "accepted_unverified", searched.description)
            precondition(approvals == 0 && g.commands.isEmpty)
            precondition(!ROBWorkspaceSearch.shared.requiredDepth, "A visual search must not wait for bucket release geometry")
            precondition(ROBWorkspaceSearch.shared.requestedTargets == (command == "left_check_hanging" ? [] : ROBWorkspaceTarget.allCases))
        }
        for (command,target,expected) in [
            ("left_search_workspace","can",[ROBWorkspaceTarget.can]),
            ("left_search_workspace"," Can \n",[ROBWorkspaceTarget.can]),
            ("right_search_workspace","can",[ROBWorkspaceTarget.can]),
            ("left_search_workspace","",ROBWorkspaceTarget.allCases),
            ("left_search_workspace","can and bucket",ROBWorkspaceTarget.allCases),
            ("left_search_workspace","unrecognized",ROBWorkspaceTarget.allCases)] {
            let searched = await run(command,target:target)
            precondition(searched["status"] as? String == "accepted_unverified",searched.description)
            precondition(ROBWorkspaceSearch.shared.requestedTargets == expected,
                "Only an explicit can search may skip waiting for the bucket")
            precondition(!ROBWorkspaceSearch.shared.requiredDepth && approvals == 0 && g.commands.isEmpty)
            precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        }
        ROBWorkspaceSearch.shared.fail = true
        let failedSearch = await run("left_search_workspace",target:"can")
        precondition(failedSearch["status"] as? String == "blocked")
        precondition(approvals == 0 && g.commands.isEmpty && ROBAmberGatewayTunnel.shared.connections == 0)
        ROBWorkspaceSearch.shared.fail = false; ROBWorkspaceSearch.shared.onInspect = nil; g.ready = true
        print("Neck-only search and hanging checks: no arm approval, gateway connection, motor or hold commands, including failure")
        if CommandLine.arguments.last == "can-only-search" {
            print("Can-only neck search: recognized can target exits without bucket work; empty/unknown defaults retain both targets; left/right neck lanes and failed search preserve ownership/no-actuation guards")
            return
        }
        let legacyExecutor = CommandLine.arguments.contains("legacy-executor")
        if !legacyExecutor && CommandLine.arguments.last != "telemetry" {
            let search = ROBWorkspaceSearch.shared
            let front = plan.target(index: plan.frontIndex)!, zero = Array(repeating: 0.0, count: 7)
            let model = try ROBGhostRobotModel(directory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
            let legacyURL = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("docs/calibration/evidence/2026-10-22-recycling/first-confirmed-recycle.proposal.json")
            let legacyCarry = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:Data(contentsOf:legacyURL))
            precondition(legacyCarry.validForReplay(model:model),"Historical route must remain viewable without replaying a taught entry")
            precondition(legacyCarry.workspaceCollisionPlan?.payload == nil && legacyCarry.steps.contains(where:{ $0.jawAction == .grip }))
            g.commands = []; let beforeLegacyApproval = approvals, beforeLegacyScan = search.collisionScanCalls
            let missingPayload = await run(legacyCarry,model:model)
            precondition(missingPayload["status"] as? String == "blocked",missingPayload.description)
            precondition((missingPayload["detail"] as? String)?.contains("Measure the carried object") == true,missingPayload.description)
            precondition(approvals == beforeLegacyApproval && search.collisionScanCalls == beforeLegacyScan && g.commands.isEmpty,
                "A legacy carry without measured payload requested authority or attempted capture/actuation")
            print("Imported carrying proposal: archive remains structurally replayable for preview, but missing measured payload rejects before approval, scene capture or actuator commands")
            let hand = model.toolPosition(model.positions(vendorLeft: front))!
            let now = Date().timeIntervalSince1970 * 1000, view = ROBWorkspaceView(panDegrees: 0, upperTarget: 6306)
            search.objects = [
                .can: .init(target: .can, position: [hand.x,hand.y,hand.z], confidence: 0.9, capturedAt: now, sequence: 10, view: view),
                .orangeBucket: .init(target: .orangeBucket, position: [hand.x,hand.y+0.08,hand.z-0.10], confidence: 0.9,
                    capturedAt: now, sequence: 11, view: view, openingRadius: 0.14)]
            func noActuation(_ detail: String) {
                precondition(g.commands.allSatisfy { $0.hasPrefix("mode_query:") || $0.hasPrefix("priority_hold:") },
                    "\(detail): map admission sent arm mode/travel/gripper commands: \(g.commands)")
                precondition(g.activeLeases.isEmpty && ROBAmberArmMotionArbiter.shared.owners.isEmpty,
                    "\(detail): map admission retained an actuator reservation or lease")
            }
            // Use the real production depth-map builder, including two fresh
            // RGB-D frames. Its provisional transform MUST stay unregistered.
            g.commands = []; g.q["right"] = front; g.mode["right"] = 2
            let scanApprovals = approvals, scansBefore = search.collisionScanCalls
            let neckScan = await run("left_scan_clearance")
            precondition(neckScan["status"] as? String == "accepted_unverified", neckScan.description)
            precondition(neckScan["arm_motion_sent"] as? Bool == false && approvals == scanApprovals && g.commands.isEmpty)
            precondition(search.collisionScanCalls == scansBefore + 1 && search.collisionSnapshot != nil)
            precondition(g.q["right"] == front && g.mode["right"] == 2)
            precondition(trial.collisionReviewProposal == nil && trial.collisionReviewStatus["registration_verified"] as? Bool != true)
            noActuation("Neck-only depth scan")
            search.failCollisionScan = true; g.commands = []
            let unavailable = await run("left_scan_clearance")
            precondition(unavailable["status"] as? String == "blocked", unavailable.description)
            precondition(approvals == scanApprovals && g.commands.isEmpty && search.collisionSnapshot == nil)
            search.failCollisionScan = false
            print("Workspace scan: two advancing RGB-D frames produce a provisional map; scan/failure need no arm approval, activation, jaw or travel commands")

            // Fresh timestamps and unchanged position mode do not substitute
            // for distinct feedback from EACH arm. The other arm continues
            // advancing in both cases, so a shared packet counter cannot pass.
            for frozenArm in ["left","right"] {
                g.commands = []; g.freezeSequenceForArms = [frozenArm]
                g.q = ["left":zero,"right":front]; g.mode = ["left":0,"right":2]
                search.clearCollisionScene()
                let before = search.collisionScanCalls
                let result = await run("left_scan_clearance")
                g.freezeSequenceForArms = []
                precondition(result["status"] as? String == "blocked",result.description)
                precondition((result["detail"] as? String)?.contains("settle with advancing feedback") == true,result.description)
                precondition(search.collisionScanCalls == before && g.commands.isEmpty,
                    "Frozen \(frozenArm) feedback allowed a scene frame or actuator command")
                precondition(g.q["left"] == zero && g.q["right"] == front && g.mode == ["left":0,"right":2])
                precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
            }
            g.commands = []; g.q = ["left":zero,"right":front]; g.mode = ["left":0,"right":2]
            search.clearCollisionScene()
            let beforeDrift = search.collisionScanCalls
            g.onTelemetry = { side in if side == "left" { g.q[side]![0] += 0.0003 } }
            let moving = await run("left_scan_clearance")
            g.onTelemetry = nil
            precondition(moving["status"] as? String == "blocked",moving.description)
            precondition((moving["detail"] as? String)?.contains("still moving") == true,moving.description)
            precondition(search.collisionScanCalls == beforeDrift && g.commands.isEmpty,
                "A gradually moving arm entered static mapping or dispatched actuation")
            precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
            g.q = ["left":zero,"right":front]
            print("Held-scene settling: frozen left OR right sequence and gradual arm drift reject before the first depth capture, with no actuator commands; unchanged mode alone never proves a static scene")

            // A held arm is intentional here: recycling previously parked it
            // before looking at the table. No parking may precede map admission.
            for (command, start, mode) in [("left_recycle_can",front,2), ("left_prepare",zero,0),
                                           ("left_wave",zero,0), ("left_object_cycle",zero,0),
                                           ("left_relax",front,2)] {
                g.commands = []; g.q["right"] = start; g.mode["right"] = mode; g.activeLeases = []
                search.clearCollisionScene()
                let before = approvals, beforeScan = search.collisionScanCalls
                let beforeSetup = ROBGripperStartupCalibration.shared.setupCalls
                let result = await run(command)
                precondition(["blocked", "not_localized", "not_reachable"].contains(result["status"] as? String ?? ""), "\(command): \(result)")
                precondition((result["detail"] as? String)?.lowercased().contains("registration") == true,
                    "The real provisional map must explain its calibration requirement: \(result)")
                precondition(search.collisionScanCalls == beforeScan + 1)
                precondition(approvals == before + (command == "left_relax" ? 0 : 1))
                precondition(g.q["right"] == start && g.mode["right"] == mode,
                    "\(command) changed the arm before unregistered-map rejection")
                precondition(ROBGripperStartupCalibration.shared.setupCalls == beforeSetup,
                    "Recycling initialized jaws before scene registration was admitted")
                precondition(trial.collisionReviewProposal == nil && !broker.isPending)
                noActuation(command)
            }
            print("Workspace gate: recycle/present/wave/handoff/empty return reject unregistered RGB-D before parking, mode changes, waypoints or gripper work; held pose and torque stay unchanged")

            // Declining the complete task cannot even start a neck depth scan.
            g.commands = []; approve = false
            let scansBeforeDecline = search.collisionScanCalls
            let declined = await run("left_prepare")
            precondition(declined["status"] as? String == "rejected", declined.description)
            precondition(g.commands.isEmpty && search.collisionScanCalls == scansBeforeDecline)
            approve = true
            // A session is an authorization, never a calibration certificate.
            let beforeSession = approvals
            let grant: NSDictionary = await withCheckedContinuation { continuation in
                broker.beginArmSession { continuation.resume(returning: $0) }
            }
            precondition(grant["status"] as? String == "completed" && broker.armSessionActive && approvals == beforeSession + 1)
            g.commands = []; search.clearCollisionScene()
            let underSession = await run("left_recycle_can")
            precondition(["blocked", "not_localized", "not_reachable"].contains(underSession["status"] as? String ?? ""), underSession.description)
            precondition((underSession["detail"] as? String)?.lowercased().contains("registration") == true)
            precondition(approvals == beforeSession + 1 && broker.armSessionActive,
                "A perception-only rejection must stay inside the bounded grant while never admitting motion")
            noActuation("Session cannot replace registration")
            broker.cancel(reason: "Fixture ended the bounded session")
            precondition(!broker.armSessionActive)
            // Already inactive hanging is a genuine no-op, rather than an
            // excuse to certify the hanging model or replay a return route.
            g.commands = []; g.q["right"] = zero; g.mode["right"] = 0
            let beforeNoop = approvals, scansBeforeNoop = search.collisionScanCalls
            let inactive = await run("left_relax")
            precondition(inactive["status"] as? String == "completed", inactive.description)
            precondition(approvals == beforeNoop && search.collisionScanCalls == scansBeforeNoop)
            noActuation("Already inactive hanging no-op")
            print("Authorization boundaries: decline starts no scan; a bounded session survives a no-motion perception rejection but cannot bypass registration; explicit Stop ends it; inactive hanging remains a no-op")
            try await delayedTelemetryTests()
            print("Legacy travel-positive cases remain behind explicit legacy-executor. They are not admitted by the current unregistered scene or hanging model/tread geometry; no fixture registration or clearance bypass was added.")
            return
        }
        if legacyExecutor {
            print("LEGACY EXECUTOR CASES: historical travel-positive assumptions are not admitted by the current registered-scene/hanging-clearance requirements; failures here are not a certified physical route.")
        }
        if CommandLine.arguments.last == "recorded-recovery" {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let original = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("docs/calibration/evidence/2026-10-22-recycling/recall-gravity-live-missed-grasp.proposal.json")
            let old = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:Data(contentsOf:original))
            let saved = folder.appendingPathComponent("left_recycle_can-recorded-fixture.proposal.json")
            try old.encoded().write(to:saved)
            var csv = "elapsed_s,sequence,robot_arm,gateway_arm,joint,position_rad,current_raw,current_delta_raw,feedback_age_ms,phase\n"
            for index in 0...29 { for joint in 0..<7 {
                csv += "\(index),\(index+1),left,right,\(joint+1),\(old.steps[index].positions[joint]),0.2,0,1,gesture step \(index)\n"
            } }
            try csv.write(to:folder.appendingPathComponent("left_recycle_can-recorded-fixture.csv"),atomically:true,encoding:.utf8)
            g.generation += 1; g.q["right"] = old.steps[29].positions; g.mode["right"] = 2; g.commands = []
            let recovery = await run("left_prepare")
            precondition(recovery["status"] as? String == "accepted_unverified",recovery.description)
            precondition(approvals == 1 && g.q["right"]! == plan.target(index:plan.frontIndex)!)
            precondition(g.commands.filter { $0.hasPrefix("ghost_step_") }.count == 25)
            precondition(!g.commands.contains("deactivate:right") && g.commands.filter { $0 == "gripper_hold:right" }.count == 1)
            precondition(g.gripperIntensities == [2,10] && g.activeLeases.isEmpty)
            g.commands = []; g.q["right"] = [Double](repeating:2.8,count:7)
            let outside = await run("left_prepare")
            precondition(outside["status"] as? String == "blocked" && !g.commands.contains { $0.hasPrefix("ghost_step") || $0.hasPrefix("gripper_") },outside.description)
            print("Recorded empty recovery: NEW real-protocol fixture approval after a new gateway generation, exact 25-step executed reverse to front, open at 10, no close/deactivate; off-path baseline rejected")
            return
        }
        if CommandLine.arguments.last == "parked-search" {
            let prepared = await run("left_prepare")
            precondition(prepared["status"] as? String == "accepted_unverified" && g.jawsOpened,prepared.description)
            let search = ROBWorkspaceSearch.shared
            search.objects = [:]; g.commands = []
            search.onInspect = {
                precondition(g.mode["right"] == 0 && ROBArmRoutinePlan.near(g.q["right"]!,Array(repeating:0,count:7)))
                precondition(g.commands.contains("deactivate:right") && g.activeLeases.isEmpty)
                g.stale = true // A neck-only parked search has no arm actuator to authorize.
            }
            search.afterInspect = { g.stale = false }
            let noObjects = await run("left_recycle_can")
            precondition(noObjects["status"] as? String == "not_found" && noObjects["arm_motion_sent"] as? Bool == true && noObjects["reach_sent"] as? Bool == false,noObjects.description)
            precondition(!g.commands.contains { $0.hasPrefix("gripper_") || $0.hasPrefix("ghost_step_") })
            search.afterInspect = nil
            for changed in [false,true] {
                g.commands = []
                search.onInspect = { if changed { g.q["right"]![0] = 0.5 } else { g.stale = true } }
                let failed = await run("left_recycle_can")
                precondition(failed["status"] as? String == "blocked",failed.description)
                precondition(!g.commands.contains { $0.hasPrefix("position_mode") || $0.hasPrefix("waypoint_") || $0.hasPrefix("gripper_") || $0.hasPrefix("ghost_step_") })
                g.stale = false; g.q["right"] = Array(repeating:0,count:7)
            }
            search.onInspect = nil
            print("Parked search: registered EMPTY return/deactivation before looking; delayed inactive feedback cannot authorize travel; fresh readmission and unchanged hanging baseline required, no jaw commands")
            return
        }
        if CommandLine.arguments.last == "recycling" {
            let model = try ROBGhostRobotModel(directory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
            let front = model.toolPosition(model.positions(vendorLeft: plan.target(index: plan.frontIndex)!))!
            let now = Date().timeIntervalSince1970 * 1000, view = ROBWorkspaceView(panDegrees: 0, upperTarget: 6306)
            ROBWorkspaceSearch.shared.objects = [
                .can: .init(target: .can, position: [front.x,front.y,front.z], confidence: 0.8, capturedAt: now, sequence: 10, view: view),
                .orangeBucket: .init(target: .orangeBucket, position: [front.x,front.y+0.08,front.z-0.10], confidence: 0.8,
                    capturedAt: now, sequence: 11, view: view, openingRadius: 0.14)]
            g.expectedGripperIntensity = 2
            g.expectedOpeningIntensity = 10
            let outcome = await run("left_recycle_can")
            precondition(outcome["motion_completed"] as? Bool == true, outcome.description)
            precondition(outcome["placement_verified"] as? Bool == false, "Command acknowledgements falsely verified placement")
            precondition(outcome["gripper_opening_intensity"] as? Int == 10 && g.gripperIntensities == [10,2,10], "Reuse startup setup; open before reaching and release at fixed10, grip gently at2")
            precondition(approvals == 1 && ROBWorkspaceSearch.shared.requiredDepth)
            precondition(g.commands.filter { $0 == "gripper_release:right" || $0 == "gripper_hold:right" } == ["gripper_release:right","gripper_hold:right","gripper_release:right"])
            precondition(ROBGripperStartupCalibration.shared.setupCalls == 1 && !g.commands.contains("calibrate:right"), "Recycling repeated calibration instead of reusing stationary setup")
            precondition(g.commands.allSatisfy { $0.hasSuffix(":right") } && !g.commands.contains("deactivate:right"))
            precondition(g.activeLeases.isEmpty && ROBAmberArmMotionArbiter.shared.owners.isEmpty)
            print("Horizontal recycling executor: one grant, stationary startup setup reused without inline calibration/prime, fresh grounded targets, frozen faster path, open/release10 and grip2, measured hold, no right-arm motion or automatic torque-off")
            return
        }
        if CommandLine.arguments.last == "telemetry" { try await delayedTelemetryTests(); return }
        let alreadyHanging = await run("left_relax")
        precondition(alreadyHanging["status"] as? String == "completed", alreadyHanging.description)
        precondition(approvals == 0 && g.commands == ["mode_query:right"])
        g.commands = []
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
        g.mode["right"] = 1 // operator's green/active mode; the next approved prepare restores position mode itself
        let prepare = await run("left_prepare")
        precondition(prepare["status"] as? String == "accepted_unverified", prepare.description)
        precondition(g.commands.firstIndex(of: "position_mode:right")! < g.commands.firstIndex(where: { $0.hasPrefix("waypoint_") })!,
            "Active-mode recovery did not restore position control before movement")
        precondition(!g.commands.contains("deactivate:right"), "Preparation required a manual-style torque-off/on cycle")
        precondition(g.commands.filter { $0.hasPrefix("calibrate") } == ["calibrate:right"])
        precondition(g.commands.contains("gripper_release:right"))
        precondition(g.jawsOpened, "Opening requires calibration to settle and an EMPTY-jaw initialization close")
        precondition(g.commands.filter { $0.hasPrefix("gripper_") && !$0.hasPrefix("gripper_state") } == ["gripper_hold:right","gripper_release:right"])
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
        precondition(g.gripperIntensities == [2,2,2,2])
        precondition(g.commands.filter { $0.hasPrefix("gripper_") && !$0.hasPrefix("gripper_state") } ==
            ["gripper_hold:right", "gripper_release:right", "gripper_hold:right", "gripper_release:right"])
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
        let approvalsBeforeReturn = approvals
        let relax = await run("left_relax")
        precondition(relax["status"] as? String == "completed", relax.description)
        precondition(approvals == approvalsBeforeReturn, "Empty-arm return requested another approval")
        precondition(g.mode["right"] == 0 && g.q["left"]! == rightBefore)
        precondition(g.commands.firstIndex(of: "deactivate:right")! > g.commands.lastIndex(of: "waypoint_0:right")!)
        precondition(ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        print("Left return: no approval or unnecessary activation at hanging; reverse taught route, measured hanging before torque-off, right arm unchanged")
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
        precondition(approvals == 19)

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
        precondition(g.gripperIntensities == [2, 2, 2, 2])
        precondition(g.commands.filter { $0.hasPrefix("gripper_") && $0 != "gripper_state:right" } ==
            ["gripper_hold:right", "gripper_release:right", "gripper_hold:right", "gripper_release:right"])
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
            let expected = failedStage == "object_placed" ? 2 : failedStage == "receiver_supporting" ? 3 : 4
            precondition(g.gripperIntensities == Array(repeating: 2, count: expected))
            precondition(g.commands.filter { $0.hasPrefix("waypoint") }.count == 5)
            precondition(!g.commands.contains("deactivate:right") && g.mode["right"] == 2)
            precondition(trial.interactionStage.isEmpty && ROBAmberArmMotionArbiter.shared.owners.isEmpty)
        }
        g.expectedGripperIntensity = 10; g.stale = false
        precondition(approvals == beforeCycle + 7)
        print("Object-cycle waits: stale feedback, replaced session, expired approval and Stop prevent subsequent close/release/lower, retain torque and invalidate readiness")
        // Help must precede all reaching/gripping, even if the bucket has
        // visual identity only. It must not activate or move either arm.
        g.q["right"] = Array(repeating: 0, count: 7); g.mode["right"] = 0
        g.commands = []; g.activeLeases = []
        let search = ROBWorkspaceSearch.shared
        let now = Date().timeIntervalSince1970 * 1000
        search.objects = [.can: .init(target: .can, position: [10,0,1], confidence: 0.9,
            capturedAt: now, sequence: 111, view: view)]
        search.lastReport = ["status": "visually_found", "visually_confirmed": ["can", "orangeBucket"]]
        var requests: [String] = []
        search.announce = { requests.append($0) }
        let beforeHelp = approvals
        let assistance = await run("left_recycle_can")
        precondition(assistance["status"] as? String == "needs_help", assistance.description)
        precondition(assistance["arm_motion_sent"] as? Bool == false && approvals == beforeHelp + 1)
        precondition(requests == ["Please bring the can closer."] && search.requiredDepth)
        precondition(g.commands == ["mode_query:right", "mode_query:right"], "Help request issued arm/gripper commands")
        g.commands = []; requests = []
        search.objects = [.can: .init(target: .can, position: [hand.x,hand.y,hand.z], confidence: 0.9,
            capturedAt: Date().timeIntervalSince1970 * 1000, sequence: 112, view: view)]
        let missingRim = await run("left_recycle_can")
        precondition(missingRim["status"] as? String == "not_localized", missingRim.description)
        precondition(requests == ["I see the bucket, but I can't measure its opening yet."])
        precondition(g.commands == ["mode_query:right", "mode_query:right"], "Visual bucket detection admitted reaching without release geometry")
        search.objects = [:]; search.announce = nil
        print("Recycling assistance: one short request before motion for a distant can, even without bucket depth; reachable can never substitutes for missing release geometry")
        try await delayedTelemetryTests()
    }
    @_optimize(none)
    static func main() async throws { setbuf(stdout, nil); try await tests(); print("Left-arm trial fixtures passed; no hardware transport exists in this executable") }
}
