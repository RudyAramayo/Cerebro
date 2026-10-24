import AppKit
import simd

/// Ephemeral admission evidence for one already-authorized waypoint. It is
/// never encoded or retained across steps/sessions. Account for start drift
/// inside the swept check's existing 5mm inflation: at most 2.5mm lies between
/// its samples, leaving this conservative 2mm budget without spending the
/// mechanical-clearance or registration margins.
struct ROBReviewedArmDispatchStart {
    let proposalID: UUID
    let index: Int
    let generation: UInt64
    let mapFingerprint: String
    let positions: [Double]
    let sequence: UInt64
    let reviewCompletedAtUptime: Double
    static let maximumStartPointDriftMeters = 0.002
    static let maximumAdmissionDelaySeconds = 0.250
    func matches(proposalID: UUID, index: Int, generation: UInt64, mapFingerprint: String,
                 positions actual: [Double], sequence: UInt64, nowUptime: Double) -> Bool {
        guard self.proposalID == proposalID, self.index == index, self.generation == generation, generation > 0,
              self.mapFingerprint == mapFingerprint, !mapFingerprint.isEmpty,
              self.positions.count == 7, actual.count == 7, (self.positions+actual).allSatisfy(\.isFinite),
              self.sequence > 0, sequence >= self.sequence, nowUptime.isFinite, reviewCompletedAtUptime.isFinite,
              (0...Self.maximumAdmissionDelaySeconds).contains(nowUptime-reviewCompletedAtUptime) else { return false }
        let pointDriftBound = 1.5*zip(self.positions,actual).reduce(0.0) { $0+abs($1.0-$1.1) }
        return pointDriftBound <= Self.maximumStartPointDriftMeters
    }
}

/// Operator-supervised trials with fresh scene evidence and a complete
/// dynamically checked arm sweep. Physical geometry still needs commissioning.
/// Physical sides are explicit: LEFT=R11/gateway right, RIGHT=L10/gateway left.
/// Existing left gesture commands retain their original scope; right recycling
/// has an independent model mapping and one-shot approval.
@objcMembers final class ROBLeftArmTrial: NSObject {
    static let shared = ROBLeftArmTrial()
    static let commands = ["left_wave", "left_prepare", "left_grip", "left_release", "left_relax", "left_object_cycle",
        "left_pick_place", "left_recycle_can", "left_search_workspace", "left_check_hanging", "left_scan_clearance",
        "left_estimated_preview", "left_estimated_calibration",
        "right_estimated_preview", "right_estimated_trial", "right_recycle_can", "right_recycle_two_cans", "right_recycle_three_cans", "left_recycle_two_cans", "right_search_workspace", "right_scan_clearance"]
    private static let neckOnlyCommands = ["left_search_workspace", "left_check_hanging", "left_scan_clearance", "left_estimated_preview"]
    static let currentLimitKey = "ROBLeftArmCurrentJumpLimitRaw"
    private(set) var isRunning = false
    var isNeckOnlyInspection: Bool { isRunning && Self.neckOnlyCommands.contains(activeCommand) }
    var preservesRegisteredHeadView: Bool { isRunning && (activeCommand == "left_recycle_can" || physicalSide == "right" && activeCommand == "left_estimated_calibration") }
    private(set) var status = "Left arm ready for a supervised trial"
    private(set) var lastRecordingPath = ""
    /// Local readiness within the one controller-approved object cycle.
    /// Empty outside a wait; callers must echo the displayed expected stage.
    private(set) var interactionStage = ""
    var statusChanged: ((String) -> Void)?
    @nonobjc var recordingDirectory: URL?
    @nonobjc var canReachCalibrationFile = ROBLeftCanReachCalibration.file
    @nonobjc var recyclingTestParametersFile = ROBRecyclingTestParameters.file
    @nonobjc private(set) var collisionReviewStatus: NSDictionary = ["status":"not_scanned", "detail":"Scan current depth before planning arm travel."]
    @nonobjc private(set) var collisionReviewProposal: ROBLeftGestureProposal?
    @nonobjc private var collisionMap: ROBWorkspaceCollisionSnapshot?
    @nonobjc private var collisionModel: ROBGhostRobotModel?
    private var sceneCapturedForThisTask = false
    private var armTravelDispatched = false
    @nonobjc private var sceneHold: [String:(positions:[Double],modes:[Int])] = [:]
    @nonobjc private var reviewedDispatchStart: ROBReviewedArmDispatchStart?

    private(set) var physicalSide = "left"
    @nonobjc var executionGatewayArm: String { physicalSide == "left" ? "right" : "left" }
    private var arm: String { executionGatewayArm }
    @nonobjc var rightCanReachCalibrationFile = ROBLeftCanReachCalibration.file(forPhysicalSide:"right")
    @nonobjc private var selectedCanReachCalibrationFile: URL {
        physicalSide == "left" ? canReachCalibrationFile : rightCanReachCalibrationFile
    }
    private func selectPhysicalSide(_ side: String) {
        guard physicalSide != side else { return }
        physicalSide = side; referencedGeneration = 0; recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
        collisionMap = nil; collisionModel = nil; collisionReviewProposal = nil
        collisionReviewStatus = ["status":"not_scanned","detail":"Physical arm changed; scan its current scene before planning."]
    }
    private let gateway = ROBAmberGatewayClient.shared
    private let vision = ROBArmRoutineVision.shared
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var ackObserver: NSObjectProtocol?
    private var sampleObserver: NSObjectProtocol?
    private var acks: [UInt64: Bool] = [:]
    private var holdConfirmations: [UInt64: Bool] = [:]
    private var waiting: Set<UInt64> = []
    private var leaseRenewals: [UInt64: Double] = [:]
    private var owner: UUID?
    private var generation: UInt64 = 0
    private var referencedGeneration: UInt64 = 0
    private var deadline = 0.0
    private var summary = ""
    private var failure: String?
    private var cameraReady = false
    private var positionReady = false
    private var allowsArmTravel = false
    private var leased = false
    private var lastRenewal = 0.0
    private var log: FileHandle?
    private var logStarted = 0.0
    private var lastSequence: UInt64 = 0
    private var previousCurrents: [Double]?
    private var currentLimit = 0.0
    private var peakJump = 0.0
    private var sampleCount = 0
    private var delayedSampleCount = 0
    private var maxDelayedSampleAge = 0.0
    private var phase = "preflight"
    private var activeCommand = ""
    private var requestedCanCount = 1
    @nonobjc private var recyclingCan: ROBWorkspaceLocatedObject?
    @nonobjc private var lastVisualGraspEvidence: ROBVisualGraspVerifier.Evidence?
    private var movingTargetReplansRemaining = 1
    private var recyclingGripDispatched = false
    private var inactiveWorkspaceSearch = false
    private var readinessConfirmed = false
    private var jawIntensity = 10
    @nonobjc private var taskJawTarget: [Double]?
    @nonobjc private var proposal: ROBLeftGestureProposal?
    private var proposalStep = -1
    @nonobjc private var sentPath: [[Double]] = []
    @nonobjc private var recoveryPath: [[Double]] = []
    private var recoveryGeneration: UInt64 = 0
    @nonobjc private var offeredRecovery: ROBLeftGestureProposal?

    // These are session-local review evidence, never an actuator grant. The
    // dedicated approval consumes the pending proof exactly once.
    private struct EstimatedPreview {
        let proof: ROBEstimatedArmCalibrationPlan
        let map: ROBWorkspaceCollisionSnapshot
        let model: ROBGhostRobotModel
        let proposal: ROBLeftGestureProposal
        let otherArmHold: (positions: [Double], modes: [Int])
        let geometryValidationFingerprint:String
        let resourceFingerprint:String
    }
    @nonobjc private var pendingEstimated: EstimatedPreview?
    @nonobjc private var activeEstimated: EstimatedPreview?
    private var estimatedPreviewTimer: Timer?
    private var estimatedCameraRetained = false
    private var estimatedApprovalPending = false

    @nonobjc func prepareEstimatedCalibration(completion: @escaping (NSDictionary) -> Void) {
        perform("left_estimated_preview", completion: completion)
    }

    /// Deliberately uses the one-shot manual lane, never a remembered rehearsal
    /// session. The operator confirms EMPTY jaws and visually clear local space.
    @nonobjc func performEstimatedCalibration(completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
                  !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting,
                  !ROBControllerArmApproval.shared.isPending, let pending = pendingEstimated, pending.model.physicalSide==physicalSide else {
                throw ROBArmRoutineError.blocked("Prepare and review a fresh estimated single-step preview first; finish other operations.")
            }
            try validateEstimatedContext(pending, generation: pending.proof.sessionGeneration)
            guard estimatedStartMatches(try measured().positionsRadians.map(\.doubleValue), baseline: pending.proof.baseline) else {
                throw ROBArmRoutineError.blocked("The arm moved from its frozen estimated start; prepare a new preview.")
            }
            let limit = UserDefaults.standard.double(forKey: Self.currentLimitKey)
            guard limit.isFinite, limit >= 0 else { throw ROBArmRoutineError.blocked("Invalid current jump threshold.") }
            let changes = zip(pending.proof.baseline,pending.proof.target).enumerated().map {
                String(format:"J%d %+.4f rad",$0.offset+1,$0.element.1-$0.element.0)
            }.joined(separator:"; ")
            let text = "ONE estimated EMPTY physical \(physicalSide.uppercased())-arm retreat away from the table over 4 seconds: \(changes), modeled vertex travel \(Int(ceil(pending.proof.maximumVertexDisplacementMeters*1000))) mm. Confirm empty jaws and visually clear the complete arm and its surrounding local working space. Camera registration remains UNVERIFIED. This supervised EMPTY retreat may start inside the estimated 150 mm depth margin: recorded existing nearby cells must have at least 100 mm plus jaw allowance of modeled starting separation and move farther from the arm at every checked pose, with strict final improvement. New margin intrusions still block. These are estimated geometry checks, not measured collision protection. No grasp, jaw command, encoder reset, torque-off, return or repeat. Hold at the measured finish and report physical direction. Proof \(pending.proof.id.uuidString); scene \(pending.map.sceneID.uuidString); map SHA256 \(pending.map.fingerprint). Keep Stop + hold ready."
            estimatedApprovalPending = true
            update("Awaiting approval for one estimated empty-arm calibration step")
            ROBControllerArmApproval.shared.request(operation: "manual", arm: physicalSide, summary: text,
                execute: { [weak self] done in
                    guard let self else { return }
                    self.estimatedApprovalPending = false
                    do {
                        guard self.pendingEstimated?.proof == pending.proof else {
                            throw ROBArmRoutineError.blocked("The estimated preview expired or was consumed; no motion sent.")
                        }
                        try self.validateEstimatedContext(pending, generation: pending.proof.sessionGeneration)
                        guard self.estimatedStartMatches(try self.measured().positionsRadians.map(\.doubleValue),baseline:pending.proof.baseline) else {
                            throw ROBArmRoutineError.blocked("The measured arm changed while awaiting approval; no motion sent.")
                        }
                        self.estimatedPreviewTimer?.invalidate(); self.estimatedPreviewTimer = nil
                        self.pendingEstimated = nil
                        self.activeEstimated = pending; self.proposal = pending.proposal
                        self.start("left_estimated_calibration",summary:text,limit:limit,completion:done)
                        if !self.isRunning { self.activeEstimated = nil; self.releaseEstimatedCamera() }
                    } catch {
                        self.invalidateEstimatedPreview(reason:error.localizedDescription)
                        done(["status":"blocked","arm_motion_sent":false,"detail":error.localizedDescription])
                    }
                }, cancel: { [weak self] in self?.abort("Estimated calibration declined or stopped; no further motion authorized.") },
                completion: { [weak self] result in
                    self?.estimatedApprovalPending = false
                    if self?.isRunning != true { self?.invalidateEstimatedPreview(reason:"Estimated calibration approval ended") }
                    completion(result)
                })
        } catch {
            invalidateEstimatedPreview(reason:error.localizedDescription)
            completion(["status":"blocked","arm_motion_sent":false,"detail":error.localizedDescription])
        }
    }

    private func estimatedGeometryFingerprint(proof:ROBEstimatedArmCalibrationPlan,map:ROBWorkspaceCollisionSnapshot,
        model:ROBGhostRobotModel,proposal:ROBLeftGestureProposal) throws ->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var bytes=try encoder.encode(proof)
        bytes.append(Data("|\(proposal.fingerprint)|\(map.fingerprint)|\(model.modelID)|\(model.referenceID)|\(model.geometryID)|\(model.selectedMappingID)|\(model.physicalSide)".utf8))
        return ROBGhostRobotModel.hash(bytes)
    }
    private func estimatedResourceFingerprint(model:ROBGhostRobotModel) throws ->String {
        let paths=["model.urdf","reference.json","surfaces.json"]+Array(Set(model.hulls.values)).sorted()
        var bytes=Data()
        for path in paths {
            bytes.append(Data(path.utf8));bytes.append(0)
            bytes.append(Data(ROBGhostRobotModel.hash(try Data(contentsOf:model.directory.appendingPathComponent(path))).utf8))
        }
        return ROBGhostRobotModel.hash(bytes)
    }

    private func estimatedStartMatches(_ actual: [Double], baseline: [Double]) -> Bool {
        actual.count == 7 && baseline.count == 7 && actual.allSatisfy(\.isFinite) &&
            1.5*zip(actual,baseline).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= ROBReviewedArmDispatchStart.maximumStartPointDriftMeters
    }

    private func estimatedCorridorMatches(_ actual: [Double], proof: ROBEstimatedArmCalibrationPlan) -> Bool {
        guard actual.count == 7, proof.baseline.count == 7, proof.target.count == 7,
              (actual+proof.baseline+proof.target).allSatisfy(\.isFinite) else { return false }
        let delta = zip(proof.baseline,proof.target).map { $1-$0 }
        let squaredLength = delta.reduce(0.0) { $0+$1*$1 }
        guard squaredLength.isFinite, squaredLength > 0 else { return false }
        let projection = zip(zip(actual,proof.baseline),delta).reduce(0.0) { $0+($1.0.0-$1.0.1)*$1.1 } / squaredLength
        let fraction = min(1,max(0,projection))
        let nearest = zip(proof.baseline,delta).map { $0+fraction*$1 }
        return 1.5*zip(actual,nearest).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003
    }

    private func validateEstimatedContext(_ value: EstimatedPreview, generation: UInt64) throws {
        let proof = value.proof, path = value.proposal
        guard Thread.isMainThread else {throw ROBArmRoutineError.blocked("Estimated arm context must be reviewed on the control thread.")}
        if physicalSide == "left", value.map.registrationID == nil {
            guard MainActor.assumeIsolated({
                ROBWorkspaceSearch.shared.estimatedCameraProjectionIsCurrent(model:value.model,map:value.map)
            }) else {
                throw ROBArmRoutineError.blocked("The estimated camera mount changed after the LEFT preview; capture a fresh scene before moving.")
            }
        }
        if physicalSide == "right" {
            guard MainActor.assumeIsolated({
                ROBRecyclingVisualInspection.fixedHeadContextIsCurrent(model:value.model,map:value.map) ||
                ROBWorkspaceSearch.shared.estimatedContextIsCurrent(model:value.model,map:value.map)
            }) else {
                throw ROBArmRoutineError.blocked("The fixed estimated or registered head/body/camera context changed after the RIGHT preview; no probe admitted.")
            }
        }
        guard value.geometryValidationFingerprint == (try estimatedGeometryFingerprint(proof:proof,map:value.map,model:value.model,proposal:path)),
              value.model.physicalSide==physicalSide, gateway.isReady(),
              (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == generation,
              let current = ROBWorkspaceSearch.shared.collisionSnapshot,
              current.sceneID == value.map.sceneID, current.fingerprint == value.map.fingerprint,
              path.kind == "estimated_calibration", path.id == proof.id,
              path.modelID == proof.modelID, path.referenceID == proof.referenceID,
              path.geometryID == proof.geometryID, path.mappingID == proof.mappingID,
              path.sessionGeneration == proof.sessionGeneration, path.baseline == proof.baseline, path.steps == proof.steps,
              path.poses.isEmpty, path.workspaceCollisionPlan == nil, path.workspaceApproachPlan == nil,
              path.recyclingActions == nil, path.recyclingParameters == nil,
              zip(proof.target,ROBArmJointLimits.radians).allSatisfy({ $1.contains($0) }) else {
            throw ROBArmRoutineError.blocked("The single-step estimated proof, scene or arm connection changed; no motion admitted.")
        }
        try proof.validateContext(map:value.map,model:value.model,generation:generation,
            cameraGeneration:vision.cameraGeneration,nowMilliseconds:Date().timeIntervalSince1970*1000)
        if activeCommand == "left_estimated_calibration",
           !estimatedCorridorMatches(try measured().positionsRadians.map(\.doubleValue),proof:proof) {
            throw ROBArmRoutineError.blocked("Measured LEFT joints left the approved estimated retreat corridor; hold requested.")
        }
        let held = value.otherArmHold, otherGatewayArm = arm == "right" ? "left" : "right"
        guard let sample = gateway.telemetry(forArm:otherGatewayArm), sample.effectiveSampleAgeMilliseconds <= 250,
              sample.positionsRadians.count == 7, sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
              gateway.modes(forArm:otherGatewayArm).map(\.intValue) == held.modes,
              sample.statuses.map(\.intValue) == held.modes,
              1.5*zip(sample.positionsRadians.map(\.doubleValue),held.positions).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003 else {
            throw ROBArmRoutineError.blocked("The other arm moved, changed mode or lost fresh feedback; hold the estimated trial.")
        }
    }

    private func releaseEstimatedCamera() {
        if estimatedCameraRetained {
            estimatedCameraRetained = false
            // A different operation may already have acquired camera demand.
            // Relinquish this preview without switching that owner's view off.
            if !ROBArmRoutineCoordinator.shared.isRunning, !ROBShowMotionCoordinator.shared.isRunning,
               !ROBAmberGestureExecutor.shared.isExecuting {
                vision.setActive(false); ROBArmRoutineCoordinator.shared.cameraDemand?(false)
            }
        }
    }

    private func invalidateEstimatedPreview(reason: String, stopCamera: Bool = true) {
        estimatedPreviewTimer?.invalidate(); estimatedPreviewTimer = nil
        pendingEstimated = nil
        if collisionReviewProposal?.kind == "estimated_calibration" { collisionReviewProposal = nil }
        let cancelApproval = estimatedApprovalPending; estimatedApprovalPending = false
        if stopCamera, !isRunning { releaseEstimatedCamera() }
        if cancelApproval { ROBControllerArmApproval.shared.cancel(reason:reason) }
    }

    private func retainEstimatedPreviewCamera() {
        estimatedCameraRetained = true
        estimatedPreviewTimer?.invalidate()
        let timer = Timer(timeInterval:0.25,repeats:true) { [weak self] _ in
            guard let self, let pending = self.pendingEstimated else { return }
            do {
                guard !self.isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
                      !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting else {
                    throw ROBArmRoutineError.blocked("Another operation replaced the estimated preview.")
                }
                try self.validateEstimatedContext(pending,generation:pending.proof.sessionGeneration)
                guard self.estimatedStartMatches(try self.measured().positionsRadians.map(\.doubleValue),baseline:pending.proof.baseline) else {
                    throw ROBArmRoutineError.blocked("The estimated preview start changed; capture a new preview.")
                }
            } catch { self.invalidateEstimatedPreview(reason:error.localizedDescription); self.update(error.localizedDescription) }
        }
        estimatedPreviewTimer = timer; RunLoop.main.add(timer,forMode:.common)
    }

    /// Local review is not actuator permission: execution still starts only
    /// after the authenticated phone/Vision controller accepts this exact hash.
    @nonobjc func perform(proposal: ROBLeftGestureProposal, model: ROBGhostRobotModel,
                          completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard proposal.kind != "estimated_calibration" else {
                throw ROBArmRoutineError.blocked("Estimated calibration cannot execute through the generic gesture lane. Use its fresh single-step approval.")
            }
            if !isRunning { invalidateEstimatedPreview(reason:"Another gesture replaced the estimated preview") }
            guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
                  !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting,
                  !ROBControllerArmApproval.shared.isPending else { throw ROBGhostMotionError.blocked("Finish the active operation first.") }
            guard !proposal.steps.contains(where:{ $0.jawAction == .grip || $0.jawAction == .release }) ||
                  proposal.workspaceCollisionPlan?.payload?.valid == true else {
                throw ROBGhostMotionError.blocked("Measure the carried object and review its complete sweep before requesting a grasp-and-carry motion.")
            }
            if proposal.kind == "recover" {
                guard offeredRecovery == proposal, recoveryGeneration == proposal.sessionGeneration else {
                    throw ROBGhostMotionError.blocked("The recovery path changed; review it again.")
                }
            } else {
                let map = ROBWorkspaceSearch.shared.collisionSnapshot
                try ROBLeftGestureCompiler.validate(proposal,model:model,collisionMap:map,
                    collisionSceneID:map?.sceneID,collisionCameraGeneration:map?.cameraGeneration)
            }
            let limit = UserDefaults.standard.double(forKey: Self.currentLimitKey)
            guard limit.isFinite, limit >= 0 else { throw ROBGhostMotionError.blocked("Invalid current jump threshold.") }
            selectPhysicalSide(model.physicalSide)
            let range = (0..<7).map { index in
                let values = [proposal.baseline[index]] + proposal.steps.map { $0.positions[index] }
                return String(format: "J%d %.2f…%.2f", index + 1, values.min()!, values.max()!)
            }.joined(separator: "; ")
            let current = limit == 0 ? "Record currents only; automatic cutoff is not configured."
                : "Hold on a sample-to-sample current jump above \(limit) raw units; not a calibrated force limit."
            let scope = ["tabletop", "recycling"].contains(proposal.kind)
                ? "Complete a fixed-station can-to-bucket attempt using startup gripper readiness and a fresh full-arm collision review. Open before approach, grip, lift, carry, release above the bucket and retreat held. One approval covers the path. Supervise actual jaw opening and pickup; retention and placement remain unmeasured."
                : "Move only the empty physical LEFT arm; jaws unchanged."
            let text = "Reviewed ghost gesture ‘\(proposal.name)’: \(proposal.steps.count) steps, \(Int(ceil(proposal.seconds))) seconds scheduled, maximum 180 seconds including settling. \(range). Proposal \(proposal.id.uuidString), SHA256 \(proposal.fingerprint). \(scope) Camera centers at upright lower 6011 / upper 6306. Confirm physically hanging at encoder zero for the first movement of this session. Model/encoder mapping uses the recorded upright prior; watch actual arm, tread and cable clearance. This is a supervised trial, not certified collision or force protection. Keep Stop + hold ready; keep the controller open when using controller approval. \(current)"
            update("Awaiting controller approval for reviewed ghost: \(proposal.name)")
            let execute: (@escaping (NSDictionary) -> Void) -> Void = { [weak self] done in
                guard let self else { return }
                self.proposal = proposal
                self.start("left_ghost", summary:text, limit:limit, completion:done)
            }
            let cancelled = { [weak self] in self?.abort("Controller cancelled the ghost gesture; hold requested."); return }
            let finished: (NSDictionary) -> Void = { [weak self] result in self?.update(result["detail"] as? String ?? "Ghost gesture ended"); completion(result) }
            if model.physicalSide == "right" {
                ROBControllerArmApproval.shared.requestRightWorkspaceTask(summary:text,execute:execute,cancel:cancelled,completion:finished)
            } else {
                ROBControllerArmApproval.shared.requestLeftGesture(summary:text,execute:execute,cancel:cancelled,completion:finished)
            }
        } catch { completion(["status": "blocked", "detail": error.localizedDescription]) }
    }

    /// Only the single currently dispatched step of the frozen accepted path
    /// is admitted. No caller supplies raw targets to the gateway.
    @nonobjc func approvedGestureTarget(id: UUID, index: Int, seconds: Double, generation: UInt64) -> [Double]? {
        guard let proposal, proposal.id == id, proposal.sessionGeneration == generation,
              proposalStep == index, proposal.steps.indices.contains(index),
              abs(proposal.steps[index].seconds - seconds) < 0.000001,
              authorizesTaughtWaypoint(arm: arm, expectedSessionGeneration: generation),
              let review = reviewedDispatchStart, let map = collisionMap,
              let sample = try? measured(),
              review.matches(proposalID:id,index:index,generation:generation,mapFingerprint:map.fingerprint,
                positions:sample.positionsRadians.map(\.doubleValue),sequence:sample.sequence,
                nowUptime:ProcessInfo.processInfo.systemUptime) else { return nil }
        reviewedDispatchStart = nil
        return proposal.steps[index].positions
    }

    @nonobjc func recoveryProposal(model: ROBGhostRobotModel) throws -> ROBLeftGestureProposal {
        guard !isRunning, recoveryGeneration > 0,
              (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == recoveryGeneration,
              recoveryPath.count > 1 else { throw ROBGhostMotionError.blocked("No stopped custom path in this gateway session.") }
        let q = try measured().positionsRadians.map(\.doubleValue)
        var segment: Int?
        for index in stride(from: recoveryPath.count - 1, through: 1, by: -1) {
            let a = recoveryPath[index - 1], b = recoveryPath[index]
            let d = zip(a, b).map { $1 - $0 }; let square = d.reduce(0) { $0 + $1 * $1 }
            let t = square > 0 ? max(0, min(1, zip(zip(q, a), d).reduce(0) { $0 + ($1.0.0 - $1.0.1) * $1.1 } / square)) : 0
            if ROBArmRoutinePlan.near(q, zip(a, d).map { $0 + t * $1 }) { segment = index; break }
        }
        guard let segment else { throw ROBGhostMotionError.blocked("Measured arm is outside the interrupted path; no recovery motion proposed.") }
        var previous = q; var steps: [ROBLeftGestureProposal.Step] = []
        for target in recoveryPath.prefix(segment).reversed() {
            let seconds = ROBLeftArmInteractionPlan.duration(from: previous, to: target,
                padding: ROBArmRoutinePlan.tolerance)!
            guard seconds <= 5 else { throw ROBGhostMotionError.blocked("Recovery segment exceeds the motion bound.") }
            steps.append(.init(positions: target, seconds: seconds)); previous = target
        }
        guard steps.reduce(0, { $0 + $1.seconds }) <= 135 else { throw ROBGhostMotionError.blocked("Recovery path exceeds one approval window.") }
        let value = ROBLeftGestureProposal(id: UUID(), name: "Return interrupted gesture", kind: "recover", modelID: model.modelID,
            referenceID: model.referenceID, geometryID: model.geometryID, mappingID: model.selectedMappingID,
            sessionGeneration: recoveryGeneration, baseline: q, poses: [], steps: steps)
        offeredRecovery = value; return value
    }

    override init() {
        super.init()
        ackObserver = NotificationCenter.default.addObserver(forName: .ROBAmberGatewayCommandDidComplete,
            object: gateway, queue: .main) { [weak self] note in
                guard let self, self.isRunning,
                      let id = (note.userInfo?["commandID"] as? NSNumber)?.uint64Value else { return }
                let accepted = note.userInfo?["accepted"] as? Bool == true
                let renewal = self.leaseRenewals.removeValue(forKey: id) != nil
                if self.waiting.contains(id) {
                    self.acks[id] = accepted
                    if note.userInfo?["operation"] as? String == "priority_hold" {
                        self.holdConfirmations[id] = note.userInfo?["holdConfirmed"] as? Bool == true
                    }
                }
                if (renewal || self.waiting.contains(id)) && !accepted {
                    self.abort(note.userInfo?["error"] as? String ?? "Left-arm command rejected; hold requested.")
                }
            }
        sampleObserver = NotificationCenter.default.addObserver(forName: .ROBAmberGatewayTelemetryDidUpdate,
            object: gateway, queue: .main) { [weak self] note in
                guard let self, self.isRunning, self.failure == nil,
                      !Self.neckOnlyCommands.contains(self.activeCommand),
                      !self.inactiveWorkspaceSearch,
                      let sample = note.userInfo?["telemetry"] as? ROBAmberGatewayTelemetry,
                      sample.arm == self.arm else { return }
                do { try self.record(sample) } catch { self.abort(error.localizedDescription) }
            }
    }

    func perform(_ requestedCommand: String, completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        guard Self.commands.contains(requestedCommand) else { completion(["status": "rejected"]); return }
        // Normalize shared task semantics only after preserving physical identity.
        // Busy callers cannot change the side of an already-running operation.
        guard !isRunning else { completion(["status":"busy","detail":"An arm operation is already running."]); return }
        guard !ROBArmRoutineCoordinator.shared.isRunning, !ROBShowMotionCoordinator.shared.isRunning,
              !ROBAmberGestureExecutor.shared.isExecuting,
              !ROBControllerArmApproval.shared.isPending || requestedCommand == "left_relax" else {
            completion(["status":"busy","detail":"Finish the current operation or use Stop + hold."]);return
        }
        selectPhysicalSide(requestedCommand.hasPrefix("right_") ? "right" : "left")
        requestedCanCount = requestedCommand.hasSuffix("_recycle_three_cans") ? 3 : requestedCommand.hasSuffix("_recycle_two_cans") ? 2 : 1
        let canonical = requestedCommand.hasPrefix("right_") ? "left_" + requestedCommand.dropFirst(6) : requestedCommand
        let command = ["left_recycle_two_cans","left_recycle_three_cans"].contains(canonical) ? "left_recycle_can" : canonical == "left_estimated_trial" ? "left_estimated_calibration" : canonical
        if command == "left_estimated_calibration" { performEstimatedCalibration(completion:completion); return }
        if !isRunning { invalidateEstimatedPreview(reason:"Another operation replaced the estimated preview") }
        if command == "left_pick_place" {
            do {
                let model = try workspaceModel()
                guard let saved = ROBTabletopPickPlace.saved(), saved.modelID == model.modelID,
                      saved.referenceID == model.referenceID, saved.geometryID == model.geometryID,
                      let sample = gateway.telemetry(forArm: arm), sample.effectiveSampleAgeMilliseconds <= 250,
                      let session = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value else {
                    throw ROBGhostMotionError.blocked("Save a five-position tabletop task in Ghost gestures and connect fresh arm feedback first.")
                }
                let path = try ROBLeftGestureCompiler.compile(kind: "tabletop", name: saved.name, poses: saved.poses,
                    model: model, baseline: sample.positionsRadians.map(\.doubleValue), generation: session)
                perform(proposal: path, model: model, completion: completion)
            } catch { completion(["status": "blocked", "detail": error.localizedDescription]) }
            return
        }
        // Non-editor operations never inherit an old reviewed proposal.
        if !isRunning { proposal = nil }
        if command == "left_relax", !isRunning,
           !ROBArmRoutineCoordinator.shared.isRunning, !ROBShowMotionCoordinator.shared.isRunning {
            if ROBControllerArmApproval.shared.isPending {
                ROBControllerArmApproval.shared.cancel(reason: "Empty-arm return requested")
            }
        }
        guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
              !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting,
              !ROBControllerArmApproval.shared.isPending else {
            completion(["status": "busy", "detail": "Finish the current operation or use Stop + hold."]); return
        }
        let limit = UserDefaults.standard.double(forKey: Self.currentLimitKey)
        guard limit.isFinite, limit >= 0 else {
            completion(["status": "blocked", "detail": "Current jump limit must be zero or a positive number."]); return
        }
        let action: String
        let intensity = ROBControllerArmApproval.shared.armSessionActive ? 2 : 10
        switch command {
        case "left_estimated_preview": action = "Capture fresh neck-only depth while both arms remain still, then review one estimated EMPTY-left-arm retreat away from the table over 4 seconds. No arm motion or gripper command."
        case "left_scan_clearance": action = "Scan the current workspace with the neck RGB-D camera while both arms remain still. Retain occupied surfaces and observed free space for a full-arm collision review. A provisional camera transform does not authorize movement."
        case "left_search_workspace": action = "Search locally for a Coke can and an orange bucket by panning/tilting the neck camera. Confirm detections in two fresh RGB-D observations using the offline object detector. If missing, ask the nearest visible person to point and search in the estimated pointing direction. Report found/not found. No arm activation, gripper commands or arm travel."
        case "left_check_hanging": action = "Inspect both robot arms by panning/tilting the neck camera using on-device MLX; report whether each is visibly hanging. This observation never resets encoders or activates/moves either arm."
        case "left_recycle_can": action = "One experimental recycling test: hold the current arm pose while the neck camera finds the empty can, bucket opening and workspace depth. Check measured camera/arm registration and the complete arm, open jaws and payload sweep. Dynamically plan the entire approach, middle grasp, carry, gravity release and retreat before moving; no blind parking or taught-route exemption. Reuse stationary startup gripper setup. Open at intensity 10 before approaching, grip at intensity 2, and release above the opening at intensity 10. Deferred empty-jaw setup may happen only after a collision-checked empty return to hanging/inactive. One authorization covers all waypoints. No force escalation, driving, blind retries or torque-off with a payload. Pickup and placement remain unmeasured."
        case "left_wave": action = "Scan current geometry, dynamically connect the empty LEFT arm to the wave targets, check each complete arm sweep, wave and leave raised. Jaws unchanged."
        case "left_prepare": action = "Present the confirmed-EMPTY physical LEFT arm using a fresh full-arm collision-checked connector. Reuse startup gripper readiness; explicit jaw setup is stationary. Confirm no object is held and supervise actual jaw opening. No encoder reset or unreviewed return path."
        case "left_grip": action = "Keep the LEFT arm stationary in front and close its already-calibrated gripper at intensity \(intensity) around the presented OBJECT. Confirm the object is between the open jaws and all fingers are clear. Never grip a person's hand. No reopening, calibration or arm travel."
        case "left_release": action = "Keep the LEFT arm stationary in front and open its already-calibrated gripper to return the object. Confirm the receiver supports the object before approving. No calibration or arm travel."
        case "left_object_cycle": action = "Complete one LEFT object handoff using fresh depth and dynamically checked full-arm connectors. Reuse startup gripper setup, open and wait for Object placed / fingers clear before gripping at intensity 2. Wait for Receiver supporting before release, then Object clear / jaws empty before a checked empty return to hanging and deactivation. Readiness signals continue the same approval. Opening, retention and force remain unmeasured."
        default: action = "Return the empty LEFT arm to hanging through a fresh dynamically calculated full-arm collision-checked route, then deactivate only at measured hanging. Remove any object first. No extra approval is needed for this empty return."
        }
        let notice = " Physical \(physicalSide.uppercased()) arm only. Arm travel requires measured camera/robot registration, fresh observed space and complete arm clearance. Unknown space blocks the path. Confirm the joint reference for the first motion of a session. The other arm stays still. Watch actual clearance; Stop + hold remains available."
        let current = limit == 0 ? " Current recording only; automatic current cutoff is not configured."
            : " Request hold if any joint's current changes by more than \(limit) raw units between samples; this is not a calibrated force limit."
        let travel = ["left_wave", "left_prepare", "left_relax", "left_object_cycle"].contains(command)
        let workspace = ["left_recycle_can", "left_search_workspace", "left_check_hanging", "left_scan_clearance"].contains(command)
        let bothHolds = physicalSide == "right" && command == "left_recycle_can"
            ? " Both arms may enter a measured stationary position hold without travel; only the physical RIGHT arm may execute the planned path. If both are already measured hanging and empty, stationary startup jaw initialization may finish there without raising them. The physical LEFT arm otherwise stays at its measured pose." : ""
        let batch = requestedCanCount > 1 && command == "left_recycle_can"
            ? " \(requestedCanCount) empty cans, sequentially: fresh perception, collision review and visual grasp check for each. A failed or uncertain grasp stops the batch in a hold; no blind next-can retry. One approval covers all \(requestedCanCount) complete transfers." : ""
        let approvedSummary = action + batch + notice + bothHolds + current + (workspace ? " Maximum 600 seconds including search, planning and movement." : travel ? " Maximum 180 seconds including preparation and settling." : "")
        if Self.neckOnlyCommands.contains(command) || command == "left_relax" {
            update(command == "left_relax" ? "Returning the empty left arm to hanging" : "Starting local neck-camera inspection")
            start(command, summary: action, limit: limit, completion: completion)
            return
        }
        update("Awaiting spoken or controller authorization: \(action)")
        let execute: (@escaping (NSDictionary) -> Void) -> Void = { [weak self] done in
            self?.jawIntensity = intensity
            self?.start(command, summary: approvedSummary, limit: limit, completion: done)
        }
        let cancel = { [weak self] in self?.abort("Controller cancelled or disconnected; left-arm hold requested."); return }
        let finished: (NSDictionary) -> Void = { [weak self] result in
            self?.update(result["detail"] as? String ?? "Left-arm operation ended"); completion(result)
        }
        if workspace && physicalSide == "right" {
            ROBControllerArmApproval.shared.requestRightWorkspaceTask(summary: approvedSummary, execute:execute, cancel:cancel, completion:finished)
        } else if workspace {
            ROBControllerArmApproval.shared.requestLeftWorkspaceTask(summary: approvedSummary, execute: execute,
                cancel: cancel, completion: finished)
        } else if travel {
            ROBControllerArmApproval.shared.requestLeftGesture(summary: approvedSummary, execute: execute,
                cancel: cancel, completion: finished)
        } else {
            ROBControllerArmApproval.shared.requestLeftStationary(summary: approvedSummary,
                execute: execute, cancel: cancel, completion: finished)
        }
    }

    func cancel(reason: String) { abort(reason) }

    func depthAlignmentDidChange() {
        precondition(Thread.isMainThread)
        abort("Head depth alignment changed; review a fresh scene.")
        collisionMap = nil; collisionModel = nil; collisionReviewProposal = nil
        collisionReviewStatus = ["status":"not_scanned", "detail":"Head depth alignment changed; capture a fresh scene."]
        recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
    }

    /// Readiness is not fresh motion authority: the original authenticated
    /// controller approval, session and every live guard must remain valid.
    @discardableResult func continueOperation(stage: String) -> Bool {
        precondition(Thread.isMainThread)
        guard isRunning, activeCommand == "left_object_cycle", !readinessConfirmed,
              !interactionStage.isEmpty, interactionStage == stage else { return false }
        do { try verifyFront() }
        catch { abort(error.localizedDescription); return false }
        readinessConfirmed = true; interactionStage = ""
        update("Object-cycle readiness confirmed; continuing the approved operation")
        return true
    }

    /// Gateway admission is scoped to this accepted operation, physical side
    /// and session. Stationary grip/release approvals never permit arm travel.
    @nonobjc func authorizesTaughtWaypoint(arm: String, expectedSessionGeneration: UInt64) -> Bool {
        guard Thread.isMainThread, isRunning, owner != nil, allowsArmTravel,
              cameraReady, positionReady, arm == self.arm, generation > 0,
              generation == expectedSessionGeneration else { return false }
        do { try check(); try checkCollisionContext(); return true } catch { return false }
    }

    private func update(_ message: String) {
        status = message; statusChanged?(message)
        NotificationCenter.default.post(name: Notification.Name("ROBArmRoutineDidChange"), object: self)
    }

    @MainActor private func publishCollisionReview(map: ROBWorkspaceCollisionSnapshot, detail: String,
                                                  blocked: Bool = false) {
        collisionReviewStatus = ["status":blocked ? "blocked" : "captured", "detail":detail,
            "blocked_reason":blocked ? detail : "", "scene_id":map.sceneID.uuidString,
            "map_fingerprint":map.fingerprint, "occupied_voxels":map.occupiedVoxelCount,
            "free_voxels":map.freeVoxelCount, "registration_verified":map.registrationID != nil,
            "observed_frames":map.observedFrameCount]
        update(detail)
    }

    /// No arm travel, including a taught empty return, precedes this scan.
    /// Existing object-search frames may supply the same fresh scene evidence.
    @MainActor private func ensureCollisionScene(model: ROBGhostRobotModel) async throws {
        let prior = inactiveWorkspaceSearch
        try await beginHeldSceneObservation()
        defer { inactiveWorkspaceSearch = prior }
        guard !leased else { throw ROBArmRoutineError.blocked("Hold the arm before scanning its environment.") }
        let now = Date().timeIntervalSince1970*1000
        let map: ROBWorkspaceCollisionSnapshot
        if sceneCapturedForThisTask, let observed = ROBWorkspaceSearch.shared.collisionSnapshot,
           observed.sessionGeneration == generation, observed.cameraGeneration == vision.cameraGeneration,
           observed.modelID == model.modelID, observed.geometryID == model.geometryID,
           (0...ROBWorkspaceCollisionPlan.maximumMapAgeMilliseconds).contains(now-observed.oldestCapturedAtMilliseconds) {
            map = observed
        } else {
            map = try await ROBWorkspaceSearch.shared.scanCollisionScene(model:model,generation:generation,
                check:{ try self.check() },progress:{ self.update($0) })
        }
        collisionMap = map; collisionModel = model; collisionReviewProposal = nil
        sceneCapturedForThisTask = true
        do {
            _ = try ROBWorkspaceCollisionPlan.validateMap(map,model:model,generation:generation,
                sceneID:map.sceneID,cameraGeneration:vision.cameraGeneration,nowMilliseconds:Date().timeIntervalSince1970*1000)
            publishCollisionReview(map:map,detail:"Fresh workspace map ready for complete arm-path collision review.")
        } catch {
            publishCollisionReview(map:map,detail:error.localizedDescription,blocked:true)
            throw error
        }
    }

    @MainActor private func beginHeldSceneObservation(allowActiveForPassiveCapture:Bool = false) async throws {
        guard !leased, leaseRenewals.isEmpty else {
            throw ROBArmRoutineError.blocked("Finish the measured arm hold before moving the neck to scan.")
        }
        var baseline: [String:(positions:[Double],modes:[Int])] = [:]
        var sequences: [String:UInt64] = [:]
        for side in ["left","right"] {
            let modes = gateway.modes(forArm:side).map(\.intValue)
            guard let sample = gateway.telemetry(forArm:side), sample.effectiveSampleAgeMilliseconds <= 250,
                  sample.positionsRadians.count == 7, sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
                  modes.count == 7, ([0,2].contains(modes[0]) || allowActiveForPassiveCapture && modes[0]==1), modes.allSatisfy({ $0 == modes[0] }),
                  sample.statuses.map(\.intValue) == modes else {
                throw ROBArmRoutineError.blocked("Fresh unchanged holding or inactive feedback is required for the neck-only scene scan.")
            }
            baseline[side] = (sample.positionsRadians.map(\.doubleValue),modes)
            sequences[side] = sample.sequence
        }
        sceneHold = baseline; inactiveWorkspaceSearch = true; cameraReady = false; positionReady = false
        // Distinct fresh packets over a measured interval establish that both
        // arms have actually settled before any neck/depth capture begins.
        // Position mode alone is not proof that an earlier move has stopped.
        let started = ProcessInfo.processInfo.systemUptime
        var distinctSamples = ["left":0,"right":0]
        while ProcessInfo.processInfo.systemUptime-started < 0.25 || distinctSamples.values.contains(where: { $0 < 3 }) {
            try check()
            guard ProcessInfo.processInfo.systemUptime-started < 2 else {
                throw ROBArmRoutineError.blocked("Both arms must settle with advancing feedback before scanning workspace geometry.")
            }
            try await Task.sleep(nanoseconds:50_000_000)
            for side in ["left","right"] {
                guard let sample = gateway.telemetry(forArm:side), let held = baseline[side],
                      sample.effectiveSampleAgeMilliseconds <= 250,
                      sample.positionsRadians.count == 7,
                      sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
                      gateway.modes(forArm:side).map(\.intValue) == held.modes,
                      sample.statuses.map(\.intValue) == held.modes,
                      1.5*zip(sample.positionsRadians.map(\.doubleValue),held.positions).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003 else {
                    throw ROBArmRoutineError.blocked("An arm is still moving; no workspace capture or arm command was sent.")
                }
                if sample.sequence > (sequences[side] ?? 0) {
                    sequences[side] = sample.sequence; distinctSamples[side,default:0] += 1
                }
            }
        }
    }

    private func checkCollisionContext() throws {
        if activeCommand == "left_estimated_calibration" {
            guard let active = activeEstimated, proposal == active.proposal,
                  collisionMap?.fingerprint == active.map.fingerprint,
                  collisionMap?.sceneID == active.map.sceneID else {
                throw ROBArmRoutineError.blocked("Missing frozen estimated single-step proof; hold requested.")
            }
            try validateEstimatedContext(active,generation:generation)
            return
        }
        guard let map = collisionMap, let model = collisionModel,
              let current = ROBWorkspaceSearch.shared.collisionSnapshot,
              current.sceneID == map.sceneID, current.fingerprint == map.fingerprint else {
            throw ROBArmRoutineError.blocked("Scan current workspace geometry before arm travel.")
        }
        _ = try ROBWorkspaceCollisionPlan.validateMap(map,model:model,generation:generation,
            sceneID:map.sceneID,cameraGeneration:vision.cameraGeneration,nowMilliseconds:Date().timeIntervalSince1970*1000)
    }

    @MainActor private func workspaceConnector(to goal: [Double], name: String) async throws -> ROBLeftGestureProposal {
        try checkCollisionContext()
        guard let map = collisionMap, let model = collisionModel else {
            throw ROBArmRoutineError.blocked("No current workspace geometry is available.")
        }
        let baseline = try measured().positionsRadians.map(\.doubleValue), session = generation
        let camera = vision.cameraGeneration, now = Date().timeIntervalSince1970*1000
        let result = try await Task.detached(priority:.userInitiated) {
            let path = try ROBWorkspaceCollisionPlan.make(from:baseline,to:goal,map:map,model:model,generation:session,
                sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now)
            return try ROBLeftGestureCompiler.compile(kind:"workspace_collision",name:name,model:model,baseline:baseline,
                generation:session,workspaceCollisionPlan:path,collisionMap:map,collisionSceneID:map.sceneID,
                collisionCameraGeneration:camera,nowMilliseconds:now)
        }.value
        try check(); try checkCollisionContext()
        guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue),baseline,tolerance:0.015) else {
            throw ROBArmRoutineError.blocked("The arm moved while its dynamic route was being calculated.")
        }
        collisionReviewProposal = result
        collisionReviewStatus = ["status":"reviewed","detail":"Complete arm connector checked against current scene geometry.",
            "registration_verified":true,"checked_poses":result.workspaceCollisionPlan?.checkedPoseCount ?? 0,
            "required_clearance_m":ROBWorkspaceCollisionPlan.mechanicalClearanceMeters]
        return result
    }

    private func start(_ command: String, summary: String, limit: Double,
                       completion: @escaping (NSDictionary) -> Void) {
        let id = UUID()
        // Reserve both physical arms so another controller cannot move the
        // other arm into this trial. Only the selected arm receives waypoints;
        // the right-task scope separately covers current-pose holds on both.
        guard ROBAmberArmMotionArbiter.shared.reserve(.left, owner: id) else {
            completion(["status": "blocked", "detail": "Another controller owns the left arm."]); return
        }
        guard ROBAmberArmMotionArbiter.shared.reserve(.right, owner: id) else {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: id)
            completion(["status": "blocked", "detail": "Another controller owns the right arm."]); return
        }
        if command != "left_estimated_calibration" {
            invalidateEstimatedPreview(reason:"Another operation replaced the estimated preview",stopCamera:false)
            activeEstimated = nil
        }
        owner = id; isRunning = true; self.summary = summary; currentLimit = limit
        collisionMap = command == "left_estimated_calibration" ? activeEstimated?.map : nil
        collisionModel = command == "left_estimated_calibration" ? activeEstimated?.model : nil
        sceneCapturedForThisTask = command == "left_estimated_calibration"; reviewedDispatchStart = nil
        armTravelDispatched = false; sceneHold = [:]
        activeCommand = command; recyclingCan=nil; lastVisualGraspEvidence=nil; movingTargetReplansRemaining=1; recyclingGripDispatched=false; inactiveWorkspaceSearch = false; interactionStage = ""; readinessConfirmed = false; taskJawTarget = nil
        lastRecordingPath = ""; sampleCount = 0; peakJump = 0
        failure = nil; generation = 0; cameraReady = false; positionReady = false; leased = false
        allowsArmTravel = ["left_wave", "left_prepare", "left_relax", "left_ghost", "left_object_cycle", "left_recycle_can", "left_estimated_calibration"].contains(command)
        proposalStep = -1; sentPath = []
        waiting = []; acks = [:]; holdConfirmations = [:]; leaseRenewals = [:]; phase = "preflight"
        let workspace = ["left_recycle_can", "left_search_workspace", "left_check_hanging", "left_scan_clearance", "left_estimated_preview"].contains(command)
        deadline = ProcessInfo.processInfo.systemUptime + (workspace ? 590 : allowsArmTravel ? 170 : 115)
        if !estimatedCameraRetained { vision.setActive(true); ROBArmRoutineCoordinator.shared.cameraDemand?(true) }
        if !Self.neckOnlyCommands.contains(command), !gateway.isReady() { ROBAmberGatewayTunnel.shared.connect() }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.monitor() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.beginRecording(command)
                let result = try await self.execute(command)
                self.finish(result, completion: completion)
            } catch {
                self.finish(["status": "blocked", "detail": self.failure ?? error.localizedDescription], completion: completion)
            }
        }
    }

    private func check() throws {
        try Task.checkCancellation()
        if let failure { throw ROBArmRoutineError.blocked(failure) }
        guard Self.neckOnlyCommands.contains(activeCommand) || activeCommand == "left_relax" || (physicalSide == "left" ? ROBControllerArmApproval.shared.authorizesLeftArmTrial(summary) : ROBControllerArmApproval.shared.authorizesRightArmTrial(summary)) else {
            throw ROBArmRoutineError.blocked("Left-arm authorization ended; hold requested.")
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ROBArmRoutineError.blocked("Left-arm trial timed out.") }
        if generation > 0 {
            guard gateway.isReady(), (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == generation else {
                throw ROBArmRoutineError.blocked("Arm gateway session changed.")
            }
            if !inactiveWorkspaceSearch { _ = try measured() }
            else {
                guard !leased, !positionReady, leaseRenewals.isEmpty, sceneHold.count == 2 else {
                    throw ROBArmRoutineError.blocked("The stationary scene-scan hold is unavailable.")
                }
                for (side,baseline) in sceneHold {
                    guard let sample = gateway.telemetry(forArm:side), sample.effectiveSampleAgeMilliseconds <= 250,
                          gateway.modes(forArm:side).map(\.intValue) == baseline.modes,
                          sample.statuses.map(\.intValue) == baseline.modes,
                          sample.positionsRadians.count == 7,
                          sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
                          1.5*zip(sample.positionsRadians.map(\.doubleValue),baseline.positions).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= ROBWorkspaceCollisionPlan.sweptPointTravelMeters else {
                        throw ROBArmRoutineError.blocked("An arm changed pose, mode or feedback freshness during the stationary neck scan.")
                    }
                }
            }
        }
        if activeCommand == "left_estimated_calibration", generation > 0 { try checkCollisionContext() }
        if cameraReady {
            guard vision.fresh, ROBArmRoutineCoordinator.shared.viewIsStationary?() == true else {
                throw ROBArmRoutineError.blocked("Live camera or stationary body view lost; left-arm hold requested.")
            }
        }
        if positionReady {
            let modes = gateway.modes(forArm: arm).map(\.intValue)
            let statuses = gateway.telemetry(forArm: arm)?.statuses.map(\.intValue) ?? []
            guard modes.count == 7, statuses.count == 7, modes.allSatisfy({ $0 == 2 }), statuses.allSatisfy({ $0 == 2 }) else {
                throw ROBArmRoutineError.blocked("Left arm left position mode or reported a motor fault.")
            }
            if !interactionStage.isEmpty,
               ROBLeftArmInteractionPlan.stationaryFrontTarget(try measured().positionsRadians.map(\.doubleValue)) == nil {
                throw ROBArmRoutineError.blocked("Left arm moved from its held front pose while awaiting object readiness.")
            }
            if let target = taskJawTarget,
               !ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue), target) {
                throw ROBArmRoutineError.blocked("Left arm drifted from the task's stationary jaw position; hold requested.")
            }
        }
    }

    private func measured() throws -> ROBAmberGatewayTelemetry {
        let current = gateway.telemetry(forArm: arm)
        guard let sample = current, sample.sequence > 0,
              sample.effectiveSampleAgeMilliseconds <= 250, sample.effectiveGripperFeedbackAgeMilliseconds <= 250,
              sample.positionsRadians.count == 7, sample.currents.count == 7,
              sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }), sample.currents.allSatisfy({ $0.doubleValue.isFinite }) else {
            let detail = current.map {
                String(format: " Motor age %.0f ms, gripper age %.0f ms, sequence %llu.",
                    $0.effectiveSampleAgeMilliseconds, $0.effectiveGripperFeedbackAgeMilliseconds, $0.sequence)
            } ?? " No telemetry sample is available."
            throw ROBArmRoutineError.blocked("Fresh left-arm motor and gripper feedback is required." + detail)
        }
        return sample
    }

    @MainActor private func wait(_ seconds: Double, until condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try check()
            guard ProcessInfo.processInfo.systemUptime < end else { throw ROBArmRoutineError.blocked("Timed out during \(phase).") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check()
    }

    @MainActor private func accepted(requiresConfirmedHold: Bool = false, _ dispatch: () -> UInt64) async throws {
        try check()
        let id = dispatch()
        guard id != 0 else { throw ROBArmRoutineError.blocked("Gateway refused left-arm command during \(phase), before submission.") }
        waiting.insert(id)
        defer { waiting.remove(id); acks.removeValue(forKey: id); holdConfirmations.removeValue(forKey: id) }
        try await wait(3) { self.acks[id] == true }
        if requiresConfirmedHold, holdConfirmations[id] != true {
            throw ROBArmRoutineError.blocked("Left-arm position hold was not confirmed; no gripper command sent.")
        }
    }

    @MainActor private func execute(_ command: String) async throws -> NSDictionary {
        guard command == "left_recycle_can", requestedCanCount > 1 else { return try await executeSingle(command) }
        let count = requestedCanCount
        var results:[[String:Any]]=[]
        for index in 0..<count {
            try check()
            update("Recycling can \(index+1) of \(count); freshly checking this can and the bucket")
            recyclingCan=nil; lastVisualGraspEvidence=nil; movingTargetReplansRemaining=1; recyclingGripDispatched=false; sceneCapturedForThisTask=false;collisionMap=nil;collisionModel=nil;collisionReviewProposal=nil
            let result=try await executeSingle(command)
            results.append(result as! [String:Any])
            guard result["motion_completed"] as? Bool == true,
                  result["grasp_visually_supported"] as? Bool == true else {
                var stopped=result as! [String:Any]
                stopped["batch_requested"]=count;stopped["batch_completed"]=index;stopped["batch_results"]=results
                stopped["detail"]="Recycling test stopped at can \(index+1) of \(count): " + (result["detail"] as? String ?? "Unconfirmed result; held for observation.")
                return stopped as NSDictionary
            }
        }
        return ["status":"accepted_unverified","motion_completed":true,"grasp_visually_supported":true,
            "placement_verified":false,"batch_requested":count,"batch_completed":count,"batch_results":results,
            "physical_arm":physicalSide,"detail":"All \(count) can-transfer paths completed with visual support for each grasp. Gravity releases were commanded over the measured opening; landing inside the bucket remains unmeasured."]
    }

    @MainActor private func executeSingle(_ command: String) async throws -> NSDictionary {
        if command == "left_scan_clearance" || command == "left_estimated_preview" {
            let model = try workspaceModel()
            let current = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
            guard current > 0, gateway.isReady() else { throw ROBArmRoutineError.blocked("Connect Amber before scanning arm-clearance geometry.") }
            generation = current
            let passiveRightProbe = physicalSide == "right" && command == "left_estimated_preview"
            try await beginHeldSceneObservation(allowActiveForPassiveCapture:passiveRightProbe)
            let map:ROBWorkspaceCollisionSnapshot
            if passiveRightProbe {
                map = try await ROBWorkspaceSearch.shared.captureEstimatedOrRegisteredCurrentScene(model:model,generation:current,
                    check:{try self.check()},progress:{self.update($0)})
            } else {
                map = try await ROBWorkspaceSearch.shared.scanCollisionScene(model:model,generation:current,
                    check:{ try self.check() },progress:{ self.update($0) })
            }
            collisionMap = map; collisionReviewProposal = nil
            collisionModel = model; sceneCapturedForThisTask = true
            publishCollisionReview(map:map,detail:map.registrationDetail)
            if command == "left_estimated_preview" {
                let baseline = try measured().positionsRadians.map(\.doubleValue)
                let camera = vision.cameraGeneration, now = Date().timeIntervalSince1970*1000
                let proof = try await Task.detached(priority:.userInitiated) {
                    try ROBEstimatedArmCalibrationPlan.make(from:baseline,map:map,model:model,generation:current,
                        cameraGeneration:camera,nowMilliseconds:now)
                }.value
                try check()
                guard estimatedStartMatches(try measured().positionsRadians.map(\.doubleValue),baseline:baseline),
                      let held = sceneHold[arm == "right" ? "left" : "right"] else {
                    throw ROBArmRoutineError.blocked("The arms changed during estimated calibration review; capture again.")
                }
                let path = ROBLeftGestureProposal(id:proof.id,name:"Estimated EMPTY-arm retreat away from the table",
                    kind:"estimated_calibration",modelID:proof.modelID,referenceID:proof.referenceID,
                    geometryID:proof.geometryID,mappingID:proof.mappingID,sessionGeneration:proof.sessionGeneration,
                    baseline:proof.baseline,poses:[],steps:proof.steps)
                let pending = EstimatedPreview(proof:proof,map:map,model:model,proposal:path,otherArmHold:held,
                    geometryValidationFingerprint:try estimatedGeometryFingerprint(proof:proof,map:map,model:model,proposal:path),
                    resourceFingerprint:try estimatedResourceFingerprint(model:model))
                try validateEstimatedContext(pending,generation:current)
                pendingEstimated = pending; collisionReviewProposal = path
                try writeEstimatedRecording(proof:proof,proposal:path)
                publishCollisionReview(map:map,detail:"Estimated single-step preview ready. Registration UNVERIFIED; visually confirm empty jaws and local clearance before one separate approval.")
                return ["status":"accepted_unverified","arm_motion_sent":false,"measured":false,
                    "estimated_calibration_preview":true,"estimated_proof_id":proof.id.uuidString,
                    "map_fingerprint":map.fingerprint,"unknown_voxels":proof.unknownVoxelCount,
                    "modeled_max_vertex_travel_m":proof.maximumVertexDisplacementMeters,
                    "detail":"One estimated EMPTY-arm retreat away from the table over 4 seconds is ready. No motion sent. Confirm local clearance and approve separately; review expires with the fresh map."]
            }
            return ["status":"accepted_unverified","arm_motion_sent":false,"measured":false,
                    "detail":map.registrationDetail,"workspace_search":ROBWorkspaceSearch.shared.lastReport]
        }
        if command == "left_search_workspace" || command == "left_check_hanging" {
            let model = try workspaceModel()
            _ = try await ROBWorkspaceSearch.shared.run(targets: command == "left_check_hanging" ? [] : ROBWorkspaceTarget.allCases,
                model: model, requireDepth: false, check: { try self.check() }, progress: { self.update($0) })
            return ["status": "accepted_unverified", "measured": false, "arm_motion_sent": false,
                "detail": ROBWorkspaceSearch.shared.lastReport["detail"] ?? "Local workspace search ended.",
                "workspace_search": ROBWorkspaceSearch.shared.lastReport]
        }
        try await wait(12) { self.gateway.isReady() }
        let connectedGeneration = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        guard connectedGeneration > 0 else { throw ROBArmRoutineError.blocked("No authenticated gateway session.") }
        try await accepted { gateway.queryMode(forArm: arm) }
        try await wait(3) { (try? self.measured()) != nil }
        guard gateway.isReady(), (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == connectedGeneration else {
            throw ROBArmRoutineError.blocked("Gateway session changed during left-arm preflight.")
        }
        generation = connectedGeneration
        var q = try measured().positionsRadians.map(\.doubleValue)
        if command == "left_estimated_calibration" { return try await executeEstimatedCalibration() }
        var entryRecovery: ROBLeftGestureProposal?
        if command == "left_relax", ROBArmRoutinePlan.near(q, Array(repeating: 0, count: 7)),
           gateway.modes(forArm: arm).count == 7, gateway.modes(forArm: arm).allSatisfy({ $0.intValue == 0 }),
           try measured().statuses.count == 7, try measured().statuses.allSatisfy({ $0.intValue == 0 }) {
            return ["status": "completed", "measured": true, "detail": "Left arm is already hanging and inactive."]
        }
        if allowsArmTravel, command != "left_recycle_can",
           !(command == "left_prepare" && ROBLeftArmInteractionPlan.stationaryFrontTarget(q) != nil) {
            do { try await ensureCollisionScene(model:workspaceModel()) }
            catch {
                return ["status":"not_localized","arm_motion_sent":false,"reach_sent":false,
                        "detail":error.localizedDescription,"collision_review":collisionReviewStatus]
            }
        }
        if command == "left_prepare", ROBLeftArmInteractionPlan.executionRoute(from:q,hanging:false) == nil {
            guard referencedGeneration == generation else {
                throw ROBArmRoutineError.blocked("The held arm needs a verified joint reference before a new dynamic return can be planned.")
            }
            entryRecovery = try await workspaceConnector(to:ROBLeftArmInteractionPlan.target(index:ROBLeftArmInteractionPlan.frontIndex)!,
                name:"Collision-checked empty return to front")
            proposal = entryRecovery
        }
        if command == "left_recycle_can" {
            let recyclingParameters = try ROBRecyclingTestParameters.load(file: recyclingTestParametersFile)
            // Search while holding the measured pose. Parking is itself a
            // motion and may collide with a newly positioned table.
            if physicalSide == "right" { try await prepareRightRecyclingSceneHolds() }
            q = try measured().positionsRadians.map(\.doubleValue)
            let searchBaseline = q
            try await beginHeldSceneObservation(); phase = "stationary neck-only scene search"
            update("Holding the arms still while searching and mapping the current workspace")
            let model = try workspaceModel()
            let calibrationFile = selectedCanReachCalibrationFile
            let objects = try await ROBWorkspaceSearch.shared.run(targets: ROBWorkspaceTarget.allCases,
                model: model, requireDepth: true, check: { try self.check() }, progress: { self.update($0) })
            sceneCapturedForThisTask = true
            if let map = ROBWorkspaceSearch.shared.collisionSnapshot {
                collisionMap = map; collisionModel = model
                publishCollisionReview(map:map,detail:map.registrationDetail,blocked:map.registrationID == nil)
            }
            try check()
            try await wait(3) { (try? self.measured()) != nil }
            try await accepted { gateway.queryMode(forArm:arm) }
            q = try measured().positionsRadians.map(\.doubleValue)
            guard ROBArmRoutinePlan.near(q,searchBaseline,tolerance:0.015) else {
                throw ROBArmRoutineError.blocked("The arm changed pose during the stationary search.")
            }
            // Ask for a reachable can even when bucket release geometry is
            // still unavailable. This is a model check, never a motion path.
            if let can = objects[.can] {
                let baseline = model.positions(vendorLeft: q)
                let reach = try await Task.detached(priority: .userInitiated) {
                    try ROBCanGrabPreview.make(can: can, model: model, baseline: baseline, side: model.physicalSide,
                        reachOffset:ROBLeftCanReachCalibration.load(model:model,can:can,file:calibrationFile))
                }.value
                try check()
                if let message = reach.helpRequest {
                    ROBWorkspaceSearch.shared.announce?(message)
                    return ["status": "needs_help", "arm_motion_sent": armTravelDispatched, "reach_sent": false, "empty_arm_parked": false, "measured": false,
                        "detail": message + " I'll check its new position before reaching.",
                        "workspace_search": ROBWorkspaceSearch.shared.lastReport]
                }
            }
            guard let can = objects[.can], let bucket = objects[.orangeBucket] else {
                let report = ROBWorkspaceSearch.shared.lastReport
                let visible = report["visually_confirmed"] as? [String] ?? []
                let detail = objects[.orangeBucket] == nil && visible.contains("orangeBucket")
                    ? "I see the bucket, but I can't measure its opening yet."
                    : report["detail"] as? String ?? "Can or orange bucket was not confirmed."
                if visible.contains("orangeBucket") { ROBWorkspaceSearch.shared.announce?(detail) }
                return ["status": ["depth_unconfirmed", "vision_unavailable", "visually_found"].contains(report["status"] as? String ?? "") ? "not_localized" : "not_found", "measured": false, "arm_motion_sent": armTravelDispatched, "reach_sent": false, "empty_arm_parked": false,
                    "detail": detail,
                    "workspace_search": ROBWorkspaceSearch.shared.lastReport]
            }
            recyclingCan=can
            guard [can, bucket].allSatisfy({ Date().timeIntervalSince1970 * 1000 - $0.capturedAt < 60_000 }) else {
                throw ROBGhostMotionError.blocked("Object observations expired during search; no reach was sent.")
            }
            guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue), q, tolerance: 0.015) else {
                throw ROBGhostMotionError.blocked("Arm start position changed during the scan; no reach was sent.")
            }
            do {
                try await ensureCollisionScene(model:model)
                guard collisionMap != nil, let owner else {
                    throw ROBArmRoutineError.blocked("The workspace map or arm ownership changed before planning.")
                }
                if !ROBGripperStartupCalibration.shared.calibrationReady(forArm:arm) {
                    _ = try await parkEmptyArmForSearch(q)
                    try await beginHeldSceneObservation()
                    try await ROBGripperStartupCalibration.shared.ensureReady(whileParkedBy:owner)
                    try check()
                    q = try measured().positionsRadians.map(\.doubleValue)
                    try await ensureCollisionScene(model:model)
                }
                guard let map = collisionMap, let sections = can.sections, sections.valid else {
                    throw ROBArmRoutineError.blocked("Measure the complete can and current environment before planning a payload sweep.")
                }
                guard referencedGeneration == generation || ROBArmRoutinePlan.near(q,Array(repeating:0,count:7)) else {
                    throw ROBArmRoutineError.blocked("The arm joint reference must be verified before a dynamic approach from this held pose.")
                }
                let planningStart = q, session = generation, camera = vision.cameraGeneration
                let front = model.recyclingFrontTarget
                let baseline = model.positions(vendorLeft:front), now = Date().timeIntervalSince1970*1000
                let compiled = try await Task.detached(priority:.userInitiated) {
                    let entry = try ROBWorkspaceCollisionPlan.make(from:planningStart,to:front,map:map,model:model,
                        generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now)
                    let plan = try ROBCanGrabPreview.make(can:can,model:model,baseline:baseline,side:model.physicalSide,bucket:bucket,
                        reachOffset:ROBLeftCanReachCalibration.load(model:model,can:can,file:calibrationFile),
                        bucketYawDegrees:ROBLeftCanReachCalibration.loadBucketYaw(model:model,file:calibrationFile,registrationID:can.registrationID),
                        bucketInwardMeters:ROBLeftCanReachCalibration.loadBucketInward(model:model,file:calibrationFile,registrationID:can.registrationID))
                    let actions = Dictionary(uniqueKeysWithValues:plan.steps.enumerated().compactMap { index,step in
                        step.jawAction.map { (index,$0) }
                    })
                    let raw = try ROBLeftGestureCompiler.compile(kind:"recycling",name:"Recycle with complete arm clearance",
                        poses:plan.steps.map(\.pose),model:model,baseline:planningStart,generation:session,recyclingActions:actions,
                        recyclingParameters:recyclingParameters,workspaceApproachPlan:entry,collisionMap:map,
                        collisionSceneID:map.sceneID,collisionCameraGeneration:camera,nowMilliseconds:now)
                    guard sections.surfaceToAxisOffsetMeters != nil,
                          let grip=raw.steps.firstIndex(where:{$0.jawAction == .grip}),
                          let release=raw.steps.firstIndex(where:{$0.jawAction == .release}),
                          let prepared=raw.steps.firstIndex(where:{$0.jawAction == .prepare}),
                          let tool=model.frames(model.positions(vendorLeft:raw.steps[grip].positions))[model.toolLink] else {
                        throw ROBArmRoutineError.blocked("A fresh measured can axis and frozen jaw stages are required for intentional grasp contact.")
                    }
                    let inverseTool=simd_inverse(tool)
                    func local(_ values:[Double])->SIMD3<Double> {
                        let p=inverseTool*SIMD4(values[0],values[1],values[2],1)
                        return SIMD3(p.x,p.y,p.z)
                    }
                    let top=local(sections.top),bottom=local(sections.bottom),axis=simd_normalize(top-bottom)
                    let radius=sections.diameterMeters/2
                    let radial=SIMD3((0..<3).map { radius*sqrt(max(0,1-axis[$0]*axis[$0])) })
                    let low=simd_min(top,bottom)-radial,high=simd_max(top,bottom)+radial
                    let center=(low+high)/2,half=(high-low)/2+SIMD3<Double>(repeating:0.003)
                    let measurementID="can-frame-\(can.sequence)"
                    let payload=ROBWorkspaceCarriedObject(measurementID:measurementID,
                        centerInToolMeters:[center.x,center.y,center.z],halfExtentsMeters:[half.x,half.y,half.z])
                    let contact=ROBWorkspaceIntentionalContact(measurementID:measurementID,observationSequence:can.sequence,
                        capturedAtMilliseconds:can.capturedAt,sceneID:map.sceneID,cameraGeneration:camera,
                        mapFingerprint:map.fingerprint,modelID:model.modelID,geometryID:model.geometryID,
                        mappingID:model.selectedMappingID,toolLink:model.toolLink,topCenterMeters:sections.top,
                        bottomCenterMeters:sections.bottom,diameterMeters:sections.diameterMeters,
                        firstContactStepIndex:min(grip,prepared+1),gripStepIndex:grip,releaseStepIndex:release,stepCount:raw.steps.count)
                    let review = try ROBWorkspaceCollisionPlan.review(baseline:raw.baseline,steps:raw.steps,map:map,model:model,
                        generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,payload:payload,
                        intentionalContact:contact)
                    return try ROBLeftGestureCompiler.compile(kind:"recycling",name:raw.name,poses:raw.poses,model:model,
                        baseline:planningStart,generation:session,id:raw.id,recyclingActions:actions,
                        recyclingParameters:recyclingParameters,workspaceCollisionPlan:review,workspaceApproachPlan:entry,
                        collisionMap:map,collisionSceneID:map.sceneID,collisionCameraGeneration:camera,nowMilliseconds:now)
                }.value
                try check(); try checkCollisionContext()
                guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue),planningStart,tolerance:0.015),
                      [can,bucket].allSatisfy({ Date().timeIntervalSince1970*1000-$0.capturedAt < 60_000 }) else {
                    throw ROBArmRoutineError.blocked("The arm or objects changed while the complete route was being checked.")
                }
                proposal = compiled; collisionReviewProposal = compiled
                collisionReviewStatus = ["status":"reviewed","registration_verified":true,
                    "checked_poses":compiled.workspaceCollisionPlan?.checkedPoseCount ?? 0,
                    "detail":"Dynamic approach, grasp, payload transfer and retreat checked together before travel."]
            } catch let error as ROBWorkspaceReachError {
                ROBWorkspaceSearch.shared.announce?(error.helpRequest)
                return ["status": "needs_help", "arm_motion_sent": armTravelDispatched, "reach_sent": false, "empty_arm_parked": false, "measured": false,
                    "detail": error.localizedDescription, "workspace_search": ROBWorkspaceSearch.shared.lastReport]
            } catch {
                return ["status": "not_reachable", "arm_motion_sent": armTravelDispatched, "reach_sent": false, "empty_arm_parked": false, "measured": false,
                    "detail": error.localizedDescription, "workspace_search": ROBWorkspaceSearch.shared.lastReport]
            }
            try proposal!.encoded().write(to: URL(fileURLWithPath: lastRecordingPath).deletingPathExtension()
                .appendingPathExtension("proposal.json"), options: .atomic)
            update("Can and orange bucket confirmed. Executing the bounded local plan under the original approval.")
        }
        if let proposal {
            guard proposal.sessionGeneration == generation, ROBArmRoutinePlan.near(q, proposal.baseline, tolerance: 0.015) else {
                throw ROBArmRoutineError.blocked("The gateway session or measured start pose changed; rebuild and review the ghost path.")
            }
            sentPath = [q]
        }
        let stationaryJaw = command == "left_grip" || command == "left_release"
        guard let route = ROBLeftArmInteractionPlan.executionRoute(from: q, hanging: command == "left_relax", waving: command == "left_wave")
            ?? (entryRecovery != nil || proposal?.workspaceCollisionPlan != nil || proposal?.kind == "recover" && referencedGeneration == generation ? [] : nil) else {
            throw ROBArmRoutineError.blocked("Left arm is outside the taught route; no movement sent.")
        }
        if stationaryJaw {
            try verifyFront()
        } else if referencedGeneration != generation {
            guard entryRecovery != nil || ROBArmRoutinePlan.near(q, Array(repeating: 0, count: 7)) else {
                throw ROBArmRoutineError.blocked("First left-arm movement in a new session must start physically hanging at encoder zero.")
            }
            referencedGeneration = generation
        }
        if inactiveWorkspaceSearch {
            try await wait(3) { (try? self.measured()) != nil }
            inactiveWorkspaceSearch = false
            try check()
        }
        try await prepareCameraAndMode(stationaryJaw:stationaryJaw)
        if let entryRecovery {
            try await move(entryRecovery)
            proposal = nil; proposalStep = -1; sentPath = []
            try verifyFront()
        }
        if stationaryJaw {
            try await settleFront()
        } else if let proposal {
            do { try await move(proposal) }
            catch let moved as ROBRecyclingVisualInspection.TargetMoved {
                guard command == "left_recycle_can", !recyclingGripDispatched,movingTargetReplansRemaining>0 else {throw moved}
                movingTargetReplansRemaining-=1
                try await holdTaskPosition(try measured().positionsRadians.map(\.doubleValue))
                self.proposal=nil;proposalStep = -1;taskJawTarget=nil;recyclingCan=nil;lastVisualGraspEvidence=nil
                collisionMap=nil;collisionModel=nil;collisionReviewProposal=nil;sceneCapturedForThisTask=false
                ROBWorkspaceSearch.shared.announce?("The can moved. I am holding and checking its new position.")
                update("Can moved before closing; one bounded fresh search and full replan under the same approval")
                return try await executeSingle(command)
            }
            if ["tabletop", "recycling"].contains(proposal.kind) {
                try await holdTaskPosition(proposal.steps.last!.positions)
                return ["status": "accepted_unverified", "measured": false, "motion_completed": true,
                    "gripper_measured": false, "placement_verified": false,
                    "grasp_visually_supported":lastVisualGraspEvidence?.verdict == .supported,
                    "gripper_intensity": ROBTabletopPickPlace.intensity,
                    "gripper_opening_intensity": proposal.kind == "recycling" ? 10 : 2,
                    "workspace_search": command == "left_recycle_can" ? ROBWorkspaceSearch.shared.lastReport : [:],
                    "physical_arm":physicalSide, "detail": "The \(physicalSide) arm reached all recycling-task positions; closing at intensity 2 and opening at intensity \(proposal.kind == "recycling" ? 10 : 2) were accepted. It is holding at the retreat pose. Object retention, jaw opening and placement in the bucket are unverified; inspect the result."]
            }
            return ["status": "completed", "measured": true, "motion_proposal_id": proposal.id.uuidString,
                "motion_proposal_sha256": proposal.fingerprint,
                "detail": "Ghost gesture ‘\(proposal.name)’ completed; left arm held at its final pose. Jaws unchanged."]
        } else { try await move(route) }
        switch command {
        case "left_relax":
            try await deactivateAtHanging()
            return ["status": "completed", "measured": true, "detail": "Left arm reached hanging and is inactive."]
        case "left_wave":
            try await move([ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.waveRestIndex,
                ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.waveRestIndex],preserveTargets:true)
            return ["status": "completed", "measured": true, "detail": "Left arm waved twice above the shoulder and is holding raised. Gripper unchanged."]
        case "left_object_cycle":
            return try await objectCycleAtFront()
        default:
            try await holdFrontForGripper()
            try await requireGripperCalibration(allowEmptyCalibration: command == "left_prepare")
            try await commandJaw(action: command == "left_grip" ? "hold" : "release", intensity: command == "left_prepare" ? 10 : jawIntensity)
            return ["status": "accepted_unverified", "measured": false, "detail": command == "left_grip"
                ? "Left grip command accepted; arm stays in front. Check object retention before releasing your support."
                : "Left open command accepted; arm stays in front. Check the jaws and object before continuing."]
        }
    }

    @MainActor private func parkEmptyArmForSearch(_ q:[Double]) async throws -> Bool {
        if ROBArmRoutinePlan.near(q,Array(repeating:0,count:7)), gateway.modes(forArm:arm).count == 7, gateway.modes(forArm:arm).allSatisfy({ $0.intValue == 0 }) { return false }
        guard referencedGeneration == generation || ROBArmRoutinePlan.near(q,Array(repeating:0,count:7)) else {
            throw ROBArmRoutineError.blocked("A verified joint reference is needed before calculating an empty-arm return.")
        }
        try checkCollisionContext()
        let connector = try await workspaceConnector(to:Array(repeating:0,count:7),name:"Dynamic empty-arm return for stationary jaw setup")
        let previous = proposal; proposal = connector
        defer { proposal = previous; proposalStep = -1 }
        referencedGeneration = generation
        ROBWorkspaceSearch.shared.announce?("Returning my empty arm along the checked path.")
        inactiveWorkspaceSearch = false
        try await prepareCameraAndMode(stationaryJaw:false)
        try await move(connector)
        try await deactivateAtHanging()
        try await wait(1) { self.leaseRenewals.isEmpty }
        positionReady = false; cameraReady = false
        return true
    }

    @MainActor private func executeEstimatedCalibration() async throws -> NSDictionary {
        guard activeCommand == "left_estimated_calibration", let active = activeEstimated,
              proposal == active.proposal else { throw ROBArmRoutineError.blocked("No frozen estimated proof is active.") }
        try check(); try checkCollisionContext()
        guard estimatedStartMatches(try measured().positionsRadians.map(\.doubleValue),baseline:active.proof.baseline) else {
            throw ROBArmRoutineError.blocked("Estimated calibration start drift exceeded 2 mm; no step sent.")
        }
        // No encoder zero, jaw initialization or arm return is part of this
        // lane. Enter position mode at the existing measured pose only.
        inactiveWorkspaceSearch = false
        try await prepareCameraAndMode(stationaryJaw:false)
        try checkCollisionContext()
        let sample = try measured(), q = sample.positionsRadians.map(\.doubleValue)
        guard estimatedStartMatches(q,baseline:active.proof.baseline) else {
            throw ROBArmRoutineError.blocked("The measured start changed during mode preparation; no calibration step sent.")
        }
        let session = generation, camera = vision.cameraGeneration, now = Date().timeIntervalSince1970*1000
        if physicalSide == "right" {
            // This value was built internally from the complete geometry review
            // and is held immutably in this one pending/active operation. Reuse
            // only identical inputs; imported decoded proofs still use validate().
            guard active.resourceFingerprint == (try estimatedResourceFingerprint(model:active.model)),
                  active.geometryValidationFingerprint == (try estimatedGeometryFingerprint(proof:active.proof,map:active.map,model:active.model,proposal:active.proposal)) else {
                throw ROBArmRoutineError.blocked("The frozen RIGHT geometry, proposal or resources changed; no cached review is reusable.")
            }
            try active.proof.validateContext(map:active.map,model:active.model,generation:session,
                cameraGeneration:camera,nowMilliseconds:now)
        } else {
            try await Task.detached(priority:.userInitiated) {
                try active.proof.validate(map:active.map,model:active.model,generation:session,
                    cameraGeneration:camera,nowMilliseconds:now)
            }.value
        }
        let review = ROBReviewedArmDispatchStart(proposalID:active.proof.id,index:0,generation:session,
            mapFingerprint:active.map.fingerprint,positions:q,sequence:sample.sequence,
            reviewCompletedAtUptime:ProcessInfo.processInfo.systemUptime)
        try check(); try checkCollisionContext()
        let actual = try measured()
        guard estimatedStartMatches(actual.positionsRadians.map(\.doubleValue),baseline:active.proof.baseline),
              review.matches(proposalID:active.proof.id,index:0,generation:session,mapFingerprint:active.map.fingerprint,
                positions:actual.positionsRadians.map(\.doubleValue),sequence:actual.sequence,
                nowUptime:ProcessInfo.processInfo.systemUptime) else {
            throw ROBArmRoutineError.blocked("Actual-start drift invalidated the estimated review; no calibration step sent.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        proposalStep = 0; phase = "estimated single empty-arm retreat"
        update("Performing one slow estimated empty-arm retreat away from the table")
        do {
            reviewedDispatchStart = review
            defer { reviewedDispatchStart = nil }
            // A missing acknowledgement cannot prove that no motion started.
            armTravelDispatched = true
            try await accepted { gateway.sendApprovedLeftGestureStep(proposalID:active.proof.id,index:0,
                duration:active.proof.seconds,expectedSessionGeneration:session) }
        }
        leased = true; lastRenewal = ProcessInfo.processInfo.systemUptime
        var settler = ROBArmRoutineSettler()
        try await wait(active.proof.seconds+3) {
            guard let latest = try? self.measured() else { return false }
            return settler.observe(sequence:latest.sequence,positions:latest.positionsRadians.map(\.doubleValue),
                target:active.proof.target,now:ProcessInfo.processInfo.systemUptime)
                && 1.5*zip(latest.positionsRadians.map(\.doubleValue),active.proof.target).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003
                && ProcessInfo.processInfo.systemUptime-started >= active.proof.seconds
        }
        proposalStep = -1
        try await holdTaskPosition(active.proof.target)
        let end = try measured().positionsRadians.map(\.doubleValue)
        guard 1.5*zip(end,active.proof.target).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003,
              end.contains(where:{ abs($0) > ROBEstimatedArmCalibrationPlan.hangingToleranceRadians+0.002+1e-6 }) else {
            throw ROBArmRoutineError.blocked("The estimated step did not hold its small measured target; observe the arm before any new action.")
        }
        return ["status":"completed","measured":true,"arm_motion_sent":true,"jaw_command_sent":false,
            "estimated_calibration_unverified":true,"estimated_proof_id":active.proof.id.uuidString,
            "map_fingerprint":active.map.fingerprint,"baseline_positions":active.proof.baseline,
            "target_positions":active.proof.target,"measured_positions":end,
            "measured_joint_delta":zip(active.proof.baseline,end).map { $1-$0 },
            "physical_arm":physicalSide,"detail":"One 4-second estimated EMPTY-\(physicalSide)-arm retreat completed and is held. Joint feedback measured; physical calibration remains unverified. No jaw command or automatic return. Report the observed direction and clearance."]
    }

    /// Part of the explicit one-shot RIGHT recycling scope: both physical
    /// arms remain at measured positions. This is not a parking trajectory.
    /// Inactive arms need no extra torque; active arms enter a measured hold.
    @MainActor private func prepareRightRecyclingSceneHolds() async throws {
        guard physicalSide == "right", activeCommand == "left_recycle_can",
              ROBControllerArmApproval.shared.authorizesRightArmTrial(summary), let owner else {
            throw ROBArmRoutineError.blocked("The complete right recycling approval does not cover stationary preparation.")
        }
        var baselines: [String:[Double]] = [:]
        var sequences: [String:UInt64] = [:]
        for side in ["left","right"] {
            guard let sample=gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                  sample.effectiveGripperFeedbackAgeMilliseconds<=250,sample.positionsRadians.count==7,
                  sample.positionsRadians.allSatisfy({$0.doubleValue.isFinite}),
                  sample.statuses.count==7,let first=sample.statuses.first?.intValue,[0,1,2].contains(first),
                  sample.statuses.allSatisfy({$0.intValue==first}),
                  gateway.modes(forArm:side).map(\.intValue)==sample.statuses.map(\.intValue) else {
                throw ROBArmRoutineError.blocked("Both arms need current consistent per-joint feedback before stationary preparation.")
            }
            baselines[side]=sample.positionsRadians.map(\.doubleValue);sequences[side]=sample.sequence
        }
        let heldSince=ProcessInfo.processInfo.systemUptime
        try await wait(2) {
            guard ProcessInfo.processInfo.systemUptime-heldSince>=0.3 else{return false}
            return ["left","right"].allSatisfy { side in
                guard let sample=self.gateway.telemetry(forArm:side),sample.sequence>(sequences[side] ?? 0),
                      sample.effectiveSampleAgeMilliseconds<=250,let q=baselines[side] else{return false}
                return sample.positionsRadians.count==7 && 1.5*zip(sample.positionsRadians.map(\.doubleValue),q).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003
            }
        }
        // Finish a deferred startup only at the already-established hanging
        // zero. A raised arm is never lowered blindly to initialize jaws.
        if !ROBGripperStartupCalibration.shared.calibrationReady(forArm:arm),
           baselines.values.allSatisfy({ROBArmRoutinePlan.near($0,Array(repeating:0,count:7))}) {
            for side in ["left","right"] where gateway.modes(forArm:side).contains(where:{$0.intValue != 0}) {
                guard let sample=gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                      sample.effectiveGripperFeedbackAgeMilliseconds<=250,
                      ROBArmRoutinePlan.near(sample.positionsRadians.map(\.doubleValue),Array(repeating:0,count:7)),
                      gateway.modes(forArm:side).map(\.intValue)==sample.statuses.map(\.intValue) else {
                    throw ROBArmRoutineError.blocked("An arm left its measured hanging state before stationary jaw setup; torque remains unchanged.")
                }
                try await accepted { gateway.deactivateArm(side) }
            }
            try await wait(2) { ["left","right"].allSatisfy { side in
                self.gateway.modes(forArm:side).map(\.intValue)==Array(repeating:0,count:7) &&
                self.gateway.telemetry(forArm:side)?.statuses.map(\.intValue)==Array(repeating:0,count:7)
            } }
            try await ROBGripperStartupCalibration.shared.ensureReady(whileParkedBy:owner)
            try check()
        }
        for side in ["left","right"] {
            if gateway.modes(forArm:side).map(\.intValue)==Array(repeating:1,count:7) {
                guard let sample=gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                      sample.effectiveGripperFeedbackAgeMilliseconds<=250,let q=baselines[side],
                      sample.statuses.map(\.intValue)==Array(repeating:1,count:7),
                      sample.positionsRadians.count==7,
                      1.5*zip(sample.positionsRadians.map(\.doubleValue),q).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {
                    throw ROBArmRoutineError.blocked("An arm changed before entering its measured stationary hold.")
                }
                try await accepted { gateway.enterPositionMode(forArm:side) }
                try await wait(2) {
                    guard let sample=self.gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                          sample.statuses.map(\.intValue)==Array(repeating:2,count:7),let q=baselines[side] else{return false}
                    return self.gateway.modes(forArm:side).map(\.intValue)==Array(repeating:2,count:7) &&
                        1.5*zip(sample.positionsRadians.map(\.doubleValue),q).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003
                }
                try await accepted(requiresConfirmedHold:true) { gateway.priorityHold(forArm:side) }
            }
        }
    }

    @MainActor private func prepareCameraAndMode(stationaryJaw:Bool) async throws {
        phase = "camera preparation"; update("Preparing live view for left-arm trial")
        try await wait(12) { ROBArmRoutineCoordinator.shared.prepareView?() == true }
        try await wait(10) { self.vision.fresh && ROBArmRoutineCoordinator.shared.viewIsStationary?() == true }
        cameraReady = true
        try record(measured())
        if let owner {
            NotificationCenter.default.post(name: Notification.Name("ROBLeftArmTrialViewPrepared"), object: self,
                userInfo: ["executionID": owner])
        }
        if !stationaryJaw {
            let modes = gateway.modes(forArm: arm).map(\.intValue)
            guard modes.count == 7, [0, 1, 2].contains(modes[0]), modes.allSatisfy({ $0 == modes[0] }) else {
                throw ROBArmRoutineError.blocked("Left-arm modes are mixed or unsupported.")
            }
            if modes[0] != 2 { try await accepted { gateway.enterPositionMode(forArm: arm) } }
            let modeSequence = try measured().sequence
            try await wait(2) {
                guard let sample = try? self.measured(), sample.sequence > modeSequence else { return false }
                return sample.statuses.count == 7 && sample.statuses.allSatisfy({ $0.intValue == 2 })
            }
        }
        positionReady = true
    }

    private func workspaceModel() throws -> ROBGhostRobotModel {
        guard let directory = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw ROBGhostMotionError.blocked("Bundled workspace model is unavailable.")
        }
        return try ROBGhostRobotModel(directory: directory, physicalSide: physicalSide)
    }

    @MainActor private func holdTaskPosition(_ target: [Double]) async throws {
        try check()
        taskJawTarget = target
        leased = false
        try await wait(1) { self.leaseRenewals.isEmpty }
        try await accepted(requiresConfirmedHold: true) { gateway.priorityHold(forArm: arm) }
        var settler = ROBArmRoutineSettler()
        try await wait(2) {
            guard let sample = try? self.measured() else { return false }
            return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                target: target, now: ProcessInfo.processInfo.systemUptime)
        }
    }

    @MainActor private func taskJaw(_ action: ROBLeftGestureProposal.JawAction, at target: [Double]) async throws {
        try await holdTaskPosition(target)
        defer { taskJawTarget = nil }
        if proposal?.kind == "recycling" {
            guard ROBGripperStartupCalibration.shared.calibrationReady(forArm: arm) else {
                throw ROBArmRoutineError.blocked("Stationary startup gripper setup is unavailable; no grasp was sent.")
            }
            try await requireGripperCalibration(allowEmptyCalibration: false)
        } else { try await requireGripperCalibration(allowEmptyCalibration: action == .prepare) }
        phase = "tabletop \(action.rawValue)"
        update(action == .grip ? "Local task: gripping empty can at intensity 2" : "Local task: opening gripper at the planned position")
        ROBWorkspaceSearch.shared.announce?(action == .prepare ? "Preparing my \(physicalSide) hand." : action == .grip ? "Grabbing the can." : "Releasing over the bucket.")
        let intensity = action != .grip && proposal?.kind == "recycling" ? 10 : ROBTabletopPickPlace.intensity
        try await accepted { gateway.controlGripper(forArm: arm, action: action == .grip ? "hold" : "release", force:intensity) }
        let settle = proposal?.recyclingParameters?.jawSettleSeconds ?? 1.5
        let end = ProcessInfo.processInfo.systemUptime + settle
        try await wait(settle + 1.5) { ProcessInfo.processInfo.systemUptime >= end }
    }

    @MainActor private func objectCycleAtFront() async throws -> NSDictionary {
        // No travel authority while the object may be present. Only the final
        // explicit empty-jaw readiness restores the bounded reverse route.
        allowsArmTravel = false
        try await holdFrontForGripper()
        try await requireGripperCalibration(allowEmptyCalibration: true)
        try await commandJaw(action: "release", intensity: 2)
        try await awaitReadiness("object_placed", message: "Check the jaws are OPEN. Place the object between them and clear your fingers, then choose Object placed / fingers clear. No closing until you continue.")
        try await holdFrontForGripper()
        try await requireGripperCalibration(allowEmptyCalibration: false)
        try await commandJaw(action: "hold", intensity: 2)
        try await awaitReadiness("receiver_supporting", message: "Grip intensity 2 was accepted, not measured. Check retention before removing support. Support the object in the receiver's hand, then choose Receiver supporting to open. The arm stays stationary.")
        try await holdFrontForGripper()
        try await requireGripperCalibration(allowEmptyCalibration: false)
        try await commandJaw(action: "release", intensity: 2)
        try await awaitReadiness("object_clear", message: "Check the object has released into the receiver's hand and is completely clear of the EMPTY jaws. Choose Object clear / jaws empty to lower the arm.")
        try await settleFront()
        guard let reverse = ROBLeftArmInteractionPlan.executionRoute(from: try measured().positionsRadians.map(\.doubleValue), hanging: true) else {
            throw ROBArmRoutineError.blocked("Left arm left the registered return corridor; no lowering sent.")
        }
        allowsArmTravel = true
        try await move(reverse)
        try await deactivateAtHanging()
        return ["status": "completed", "measured": true, "gripper_measured": false, "gripper_intensity": 2,
            "detail": "Object cycle completed after all three operator readiness signals. Left arm reached hanging and is inactive. Jaw commands were accepted; jaw position, retention and force remain unmeasured."]
    }

    @MainActor private func awaitReadiness(_ stage: String, message: String) async throws {
        try verifyFront()
        interactionStage = stage; readinessConfirmed = false; phase = "waiting \(stage)"
        update(message + " Keep the approving controller open; Stop + hold remains available. Readiness waits are bounded to 45 seconds and the entire operation to 180 seconds.")
        defer { interactionStage = ""; readinessConfirmed = false }
        try await wait(min(45, max(0, deadline - ProcessInfo.processInfo.systemUptime))) { self.readinessConfirmed }
    }

    @MainActor private func holdFrontForGripper() async throws {
        // Settling alone leaves a renewed gateway lease. Drain its replies,
        // then require a confirmed measured-pose hold without removing torque.
        try verifyFront()
        phase = "holding front for gripper"; update("Holding left arm before gripper setup")
        leased = false
        try await wait(1) { self.leaseRenewals.isEmpty }
        try await accepted(requiresConfirmedHold: true) { gateway.priorityHold(forArm: arm) }
        try await settleFront()
    }

    @MainActor private func requireGripperCalibration(allowEmptyCalibration: Bool) async throws {
        try await accepted { gateway.queryGripperState(forArm: arm) }
        let calibrated = gateway.gripperSnapshot(forArm: arm)["calibrationState"] as? String == "command_accepted_unverified"
        if !calibrated {
            guard allowEmptyCalibration else { throw ROBArmRoutineError.blocked("Use Present / open with empty jaws first. Grip/release never recalibrates.") }
            phase = "empty gripper calibration"; update("Calibrating empty left gripper")
            try await accepted { gateway.calibrateGripper(forArm: arm) }
            // The controller acknowledges dispatch before the physical empty
            // calibration finishes. On ROB, opening after two seconds left
            // the jaws closed; a separate later opening succeeded. Keep the
            // measured hold/freshness checks throughout this conservative
            // interval. Elapsed time still does not verify jaw opening.
            update("Waiting for empty gripper calibration before opening")
            let end = ProcessInfo.processInfo.systemUptime + 10
            try await wait(11) { ProcessInfo.processInfo.systemUptime >= end }
        }
        if allowEmptyCalibration {
            // Rob commissioned this stationary EMPTY-jaw close/open cycle:
            // opening alone after calibration left the fingers closed. The
            // caller follows this gentle close with its fixed opening command.
            // Never prime while gripping or releasing a potentially held can.
            phase = "initializing empty jaws"
            update("Initializing empty left jaws: gentle close before opening")
            try await accepted { gateway.controlGripper(forArm: arm, action: "hold", force: 2) }
            let end = ProcessInfo.processInfo.systemUptime + 1.5
            try await wait(3) { ProcessInfo.processInfo.systemUptime >= end }
        }
    }

    @MainActor private func commandJaw(action: String, intensity: Int) async throws {
        try verifyFront()
        phase = action == "hold" ? "grip object" : "release object"
        update(action == "hold" ? "Closing left gripper on the presented object" : "Opening left gripper; support the object")
        try await accepted { gateway.controlGripper(forArm: arm, action: action, force: intensity) }
        let end = ProcessInfo.processInfo.systemUptime + 1.5
        try await wait(3) { ProcessInfo.processInfo.systemUptime >= end }
    }

    @MainActor private func deactivateAtHanging() async throws {
        guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue), Array(repeating: 0, count: 7)) else {
            throw ROBArmRoutineError.blocked("Hanging arrival not measured; torque remains on.")
        }
        positionReady = false; phase = "deactivating"
        try await accepted { gateway.deactivateArm(arm) }
        leased = false
        try await wait(2) { let modes = self.gateway.modes(forArm: self.arm); return modes.count == 7 && modes.allSatisfy({ $0.intValue == 0 }) }
    }

    private func verifyFront() throws {
        try check()
        let modes = gateway.modes(forArm: arm)
        let sample = try measured()
        guard modes.count == 7, modes.allSatisfy({ $0.intValue == 2 }), sample.statuses.count == 7,
              sample.statuses.allSatisfy({ $0.intValue == 2 }),
              ROBLeftArmInteractionPlan.stationaryFrontTarget(sample.positionsRadians.map(\.doubleValue)) != nil else {
            throw ROBArmRoutineError.blocked("Gripper action requires the left arm stationary at the taught front pose in position mode.")
        }
    }

    @MainActor private func settleFront() async throws {
        // Position mode and a single matching read do not prove settling.
        // Recheck distinct fresh samples after changing the arm to a hold.
        try verifyFront()
        var settler = ROBArmRoutineSettler()
        guard let front = ROBLeftArmInteractionPlan.stationaryFrontTarget(try measured().positionsRadians.map(\.doubleValue)) else {
            throw ROBArmRoutineError.blocked("Left arm drifted from the front pose; no jaw command sent.")
        }
        try await wait(2) {
            guard let sample = try? self.measured() else { return false }
            return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                target: front, now: ProcessInfo.processInfo.systemUptime)
        }
    }

    @MainActor private func move(_ route: [Int], preserveTargets: Bool = false) async throws {
        guard let last = route.last else { return }
        // Named routes supply endpoints, not permission to replay their old
        // sweeps through a newly positioned table.
        for index in preserveTargets ? route : [last] {
            guard let target = ROBLeftArmInteractionPlan.target(index:index) else {
                throw ROBArmRoutineError.blocked("The requested arm endpoint is unavailable.")
            }
            let connector = try await workspaceConnector(to:target,name:"Dynamic collision-checked arm connector")
            let previous = proposal; proposal = connector
            do { try await move(connector) }
            catch { proposal = previous; proposalStep = -1; throw error }
            proposal = previous; proposalStep = -1
        }
    }

    @MainActor private func move(_ proposal: ROBLeftGestureProposal) async throws {
        try checkCollisionContext()
        guard let map = collisionMap, let model = collisionModel else {
            throw ROBArmRoutineError.blocked("No fresh scene map is available for the complete arm sweep.")
        }
        let session = generation, camera = vision.cameraGeneration
        let payload = proposal.workspaceCollisionPlan?.payload
        let reviewTime = Date().timeIntervalSince1970*1000
        _ = try await Task.detached(priority:.userInitiated) {
            if let frozen = proposal.workspaceCollisionPlan {
                try frozen.validate(map:map,model:model,generation:session,sceneID:map.sceneID,
                    cameraGeneration:camera,nowMilliseconds:reviewTime)
            }
            return try ROBWorkspaceCollisionPlan.review(baseline:proposal.baseline,steps:proposal.steps,map:map,model:model,
                generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:reviewTime,payload:payload,
                intentionalContact:proposal.workspaceCollisionPlan?.intentionalContact)
        }.value
        var carrying = false
        var visualContext: ROBRecyclingVisualInspection.Context?
        var graspSupported = false
        for (index, step) in proposal.steps.enumerated() {
            // A single already-planned vertical lift may gather evidence. No
            // transfer/release continues on command acceptance alone.
            if proposal.kind == "recycling", carrying, !graspSupported, step.stage != "Verification lift" {
                guard let context=visualContext else {
                    throw ROBArmRoutineError.blocked("No before-close visual grasp baseline; holding the possible payload.")
                }
                let evidence=try await ROBRecyclingVisualInspection.verifyAfterLift(context:context,model:model,gatewayArm:arm,check:{try self.check()})
                lastVisualGraspEvidence=evidence
                try writeVisualGraspEvidence(evidence)
                guard evidence.verdict == .supported else {
                    try await holdTaskPosition(try measured().positionsRadians.map(\.doubleValue))
                    throw ROBArmRoutineError.blocked("Grasp \(evidence.verdict.rawValue): \(evidence.reason) Holding; no carry or automatic reopening.")
                }
                graspSupported=true
                ROBWorkspaceSearch.shared.announce?("I have visual support for the grasp.")
            }
            reviewedDispatchStart = nil
            try check(); try checkCollisionContext()
            let reviewedSample = try measured(), q = reviewedSample.positionsRadians.map(\.doubleValue)
            guard let minimum = ROBLeftArmInteractionPlan.duration(from: q, to: step.positions), step.seconds >= minimum - 0.05 else {
                throw ROBArmRoutineError.blocked("Measured start drift exceeds the reviewed timing; hold requested.")
            }
            let now = Date().timeIntervalSince1970*1000
            _ = try await Task.detached(priority:.userInitiated) {
                try ROBWorkspaceCollisionPlan.review(baseline:q,steps:[step],map:map,model:model,generation:session,
                    sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,payload:payload,
                    intentionalContact:proposal.workspaceCollisionPlan?.intentionalContact,
                    contactStepIndex:proposal.workspaceCollisionPlan?.intentionalContact == nil ? nil : index,
                    carryingAtStart:carrying)
            }.value
            let dispatchReview = ROBReviewedArmDispatchStart(proposalID:proposal.id,index:index,generation:session,
                mapFingerprint:map.fingerprint,positions:q,sequence:reviewedSample.sequence,
                reviewCompletedAtUptime:ProcessInfo.processInfo.systemUptime)
            try check(); try checkCollisionContext()
            let admissionSample = try measured()
            guard dispatchReview.matches(proposalID:proposal.id,index:index,generation:session,mapFingerprint:map.fingerprint,
                positions:admissionSample.positionsRadians.map(\.doubleValue),sequence:admissionSample.sequence,
                nowUptime:ProcessInfo.processInfo.systemUptime) else {
                throw ROBArmRoutineError.blocked("The arm moved while its actual-start sweep was checked. Hold and review the new start before dispatch.")
            }
            proposalStep = index; phase = "gesture step \(index)"; update("\(proposal.name): step \(index + 1)/\(proposal.steps.count)")
            let started = ProcessInfo.processInfo.systemUptime
            sentPath.append(step.positions)
            armTravelDispatched = true
            do {
                reviewedDispatchStart = dispatchReview
                defer { reviewedDispatchStart = nil }
                try await accepted { gateway.sendApprovedLeftGestureStep(proposalID: proposal.id, index: index,
                    duration: step.seconds, expectedSessionGeneration: generation) }
            }
            leased = true; lastRenewal = ProcessInfo.processInfo.systemUptime
            var settler = ROBArmRoutineSettler()
            try await wait(step.seconds + 3) {
                guard let sample = try? self.measured() else { return false }
                return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                    target: step.positions, now: ProcessInfo.processInfo.systemUptime)
                    && ProcessInfo.processInfo.systemUptime - started >= step.seconds
            }
            proposalStep = -1
            if step.jawAction == .grip, proposal.kind == "recycling" {
                guard let can=recyclingCan else { throw ROBArmRoutineError.blocked("The fresh can identity was lost before closing.") }
                try await holdTaskPosition(step.positions)
                visualContext=try await ROBRecyclingVisualInspection.begin(model:model,can:can,gatewayArm:arm,check:{try self.check()})
            }
            if step.jawAction == .grip, proposal.kind == "recycling" { recyclingGripDispatched=true }
            if let action = step.jawAction { try await taskJaw(action, at: step.positions) }
            if step.jawAction == .grip { carrying = true }
            if step.jawAction == .release { carrying = false }
        }
    }

    private func monitor() {
        guard isRunning, failure == nil else { return }
        do {
            try check()
            if leased { try checkCollisionContext() }
            if generation > 0, !inactiveWorkspaceSearch { try record(measured()) }
            let now = ProcessInfo.processInfo.systemUptime
            guard !leaseRenewals.values.contains(where: { now - $0 > 1 }) else { throw ROBArmRoutineError.blocked("Left-arm lease acknowledgement timed out.") }
            if leased, now - lastRenewal >= 0.4 {
                lastRenewal = now
                let id = gateway.renewLease(forArm: arm, leaseMilliseconds: 1500)
                guard id != 0 else { throw ROBArmRoutineError.blocked("Left-arm motion lease refused.") }
                leaseRenewals[id] = now
            }
        } catch { abort(error.localizedDescription) }
    }

    private func writeVisualGraspEvidence(_ evidence: ROBVisualGraspVerifier.Evidence) throws {
        guard !lastRecordingPath.isEmpty else {throw ROBArmRoutineError.blocked("No recording is available for visual grasp evidence.")}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        try encoder.encode(evidence).write(to:URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("grasp-visual.json"),options:.atomic)
    }

    private func writeEstimatedRecording(proof: ROBEstimatedArmCalibrationPlan, proposal: ROBLeftGestureProposal) throws {
        guard !lastRecordingPath.isEmpty else { throw ROBArmRoutineError.blocked("No local calibration recording is open.") }
        let base = URL(fileURLWithPath:lastRecordingPath).deletingPathExtension()
        try proposal.encoded().write(to:base.appendingPathExtension("proposal.json"),options:.atomic)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try encoder.encode(proof).write(to:base.appendingPathExtension("estimated-calibration.json"),options:.atomic)
    }

    private func beginRecording(_ command: String) throws {
        let folder = try recordingDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Cerebro/\(physicalSide == "left" ? "Left" : "Right")ArmTrials")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recordingCommand = physicalSide == "right" && command.hasPrefix("left_") ? "right_" + command.dropFirst(5) : command
        let url = folder.appendingPathComponent("\(recordingCommand)-\(UUID().uuidString).csv")
        try Data("elapsed_s,sequence,robot_arm,gateway_arm,joint,position_rad,current_raw,current_delta_raw,feedback_age_ms,phase\n".utf8).write(to: url, options: .atomic)
        log = try FileHandle(forWritingTo: url); try log?.seekToEnd()
        lastRecordingPath = url.path; logStarted = ProcessInfo.processInfo.systemUptime
        if let proposal { try proposal.encoded().write(to: url.deletingPathExtension().appendingPathExtension("proposal.json"), options: .atomic) }
        if let active = activeEstimated { try writeEstimatedRecording(proof:active.proof,proposal:active.proposal) }
        lastSequence = 0; previousCurrents = nil; peakJump = 0; sampleCount = 0
        delayedSampleCount = 0; maxDelayedSampleAge = 0
    }

    private func record(_ sample: ROBAmberGatewayTelemetry) throws {
        guard log != nil, sample.sequence > lastSequence else { return }
        let deliveredAge = sample.effectiveSampleAgeMilliseconds
        guard sample.sampleAgeAtReceiptMilliseconds <= 250, deliveredAge.isFinite, sample.positionsRadians.count == 7,
              sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
              sample.currents.count == 7, sample.currents.allSatisfy({ $0.doubleValue.isFinite }) else {
            throw ROBArmRoutineError.blocked("Invalid or stale left-arm current recording; hold requested.")
        }
        if deliveredAge > 250 {
            // Notifications carry the packet captured on the gateway queue,
            // not necessarily the latest packet after a busy UI resumes.
            // Retain that historical current sample only if actual live motor
            // AND gripper feedback is fresh and strictly newer. All live
            // admission, session checks and the independent lease stay intact.
            try check()
            let current = try measured()
            guard current.sequence > sample.sequence else {
                throw ROBArmRoutineError.blocked("Left-arm telemetry stopped advancing; hold requested.")
            }
            delayedSampleCount += 1; maxDelayedSampleAge = max(maxDelayedSampleAge, deliveredAge)
        }
        let currents = sample.currents.map(\.doubleValue)
        let changes = zip(currents, previousCurrents ?? currents).map { $0 - $1 }
        let jump = changes.map(abs).max() ?? 0
        peakJump = max(peakJump, jump); previousCurrents = currents; lastSequence = sample.sequence; sampleCount += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - logStarted
        let rows = (0..<7).map { "\(elapsed),\(sample.sequence),\(physicalSide),\(arm),\($0 + 1),\(sample.positionsRadians[$0]),\(currents[$0]),\(changes[$0]),\(deliveredAge),\(phase)\n" }.joined()
        try log?.write(contentsOf: Data(rows.utf8))
        if currentLimit > 0, jump > currentLimit {
            throw ROBArmRoutineError.blocked("Left-arm current jump \(jump) exceeded \(currentLimit) raw units; hold requested. Inspect the recording before retrying.")
        }
    }

    private func abort(_ message: String) {
        invalidateEstimatedPreview(reason:message)
        activeEstimated = nil
        guard isRunning, failure == nil else { return }
        failure = message; task?.cancel(); reviewedDispatchStart = nil
        interactionStage = ""; readinessConfirmed = false
        if !Self.neckOnlyCommands.contains(activeCommand) { _ = gateway.priorityHold(forArm: arm) }
        leased = false
        update(message)
    }

    private func finish(_ result: NSDictionary, completion: @escaping (NSDictionary) -> Void) {
        timer?.invalidate(); timer = nil
        if !Self.neckOnlyCommands.contains(activeCommand), leased || result["status"] as? String == "blocked" { _ = gateway.priorityHold(forArm: arm) }
        leased = false
        if ["tabletop", "recycling", "estimated_calibration"].contains(proposal?.kind ?? "") {
            // A failed close/open may leave a payload. Never offer the old
            // empty-arm reverse/recovery automatically for a recycling task.
            recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
        } else if proposal != nil, result["status"] as? String != "completed", sentPath.count > 1 {
            recoveryPath = sentPath; recoveryGeneration = generation
        } else if result["status"] as? String == "completed" {
            recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
        }
        var output = result as! [String: Any]
        output["physical_arm"]=physicalSide
        if let evidence=lastVisualGraspEvidence {
            output["grasp_visually_supported"]=evidence.verdict == .supported
            if let data=try? JSONEncoder().encode(evidence),let value=try? JSONSerialization.jsonObject(with:data) {output["visual_grasp_evidence"]=value}
        }
        if activeCommand == "left_estimated_calibration" {
            output["arm_motion_sent"] = armTravelDispatched
            output["jaw_command_sent"] = false
            output["estimated_calibration_unverified"] = true
        }
        do { try log?.synchronize(); try log?.close() } catch {
            output["recording_error"] = error.localizedDescription
            output["status"] = "blocked"
            output["detail"] = "Left-arm trial ended, but saving the current recording failed: \(error.localizedDescription)"
        }
        log = nil
        output["current_recording"] = lastRecordingPath
        output["current_samples"] = sampleCount
        output["delayed_telemetry_samples"] = delayedSampleCount
        output["max_delayed_telemetry_age_ms"] = maxDelayedSampleAge
        output["peak_current_jump_raw"] = peakJump
        output["current_jump_limit_raw"] = currentLimit
        if let proposal {
            output["motion_proposal_id"] = proposal.id.uuidString
            output["motion_proposal_sha256"] = proposal.fingerprint
        }
        let keepEstimatedPreview = activeCommand == "left_estimated_preview" &&
            output["status"] as? String == "accepted_unverified" && pendingEstimated != nil
        if !keepEstimatedPreview {
            estimatedCameraRetained = false
            vision.setActive(false); ROBArmRoutineCoordinator.shared.cameraDemand?(false)
            invalidateEstimatedPreview(reason:"Estimated trial ended",stopCamera:false)
        }
        activeEstimated = nil
        if let owner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: owner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: owner)
        }
        owner = nil; isRunning = false; task = nil; proposal = nil; proposalStep = -1; reviewedDispatchStart = nil
        activeCommand = ""; recyclingCan=nil; inactiveWorkspaceSearch = false; interactionStage = ""; readinessConfirmed = false; taskJawTarget = nil
        if keepEstimatedPreview { retainEstimatedPreviewCamera() }
        update(output["detail"] as? String ?? "Left-arm trial ended")
        completion(output as NSDictionary)
    }
}
