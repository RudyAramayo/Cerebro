import AppKit

/// Operator-supervised trials using the taught approach and a small front-only
/// J3/J5 extension. New extension angles still require physical commissioning.
/// Physical left is Amber R11, gateway `right`; never dispatch to L10 here.
@objcMembers final class ROBLeftArmTrial: NSObject {
    static let shared = ROBLeftArmTrial()
    static let commands = ["left_wave", "left_prepare", "left_grip", "left_release", "left_relax", "left_object_cycle",
        "left_pick_place", "left_recycle_can", "left_search_workspace", "left_check_hanging"]
    static let currentLimitKey = "ROBLeftArmCurrentJumpLimitRaw"
    private(set) var isRunning = false
    private(set) var status = "Left arm ready for a supervised trial"
    private(set) var lastRecordingPath = ""
    /// Local readiness within the one controller-approved object cycle.
    /// Empty outside a wait; callers must echo the displayed expected stage.
    private(set) var interactionStage = ""
    var statusChanged: ((String) -> Void)?
    @nonobjc var recordingDirectory: URL?

    private let arm = "right"
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
    private var phase = "preflight"
    private var activeCommand = ""
    private var readinessConfirmed = false
    private var jawIntensity = 10
    @nonobjc private var taskJawTarget: [Double]?
    @nonobjc private var proposal: ROBLeftGestureProposal?
    private var proposalStep = -1
    @nonobjc private var sentPath: [[Double]] = []
    @nonobjc private var recoveryPath: [[Double]] = []
    private var recoveryGeneration: UInt64 = 0
    @nonobjc private var offeredRecovery: ROBLeftGestureProposal?

    /// Local review is not actuator permission: execution still starts only
    /// after the authenticated phone/Vision controller accepts this exact hash.
    @nonobjc func perform(proposal: ROBLeftGestureProposal, model: ROBGhostRobotModel,
                          completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
                  !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting,
                  !ROBControllerArmApproval.shared.isPending else { throw ROBGhostMotionError.blocked("Finish the active operation first.") }
            if proposal.kind == "recover" {
                guard offeredRecovery == proposal, recoveryGeneration == proposal.sessionGeneration else {
                    throw ROBGhostMotionError.blocked("The recovery path changed; review it again.")
                }
            } else { try ROBLeftGestureCompiler.validate(proposal, model: model) }
            let limit = UserDefaults.standard.double(forKey: Self.currentLimitKey)
            guard limit.isFinite, limit >= 0 else { throw ROBGhostMotionError.blocked("Invalid current jump threshold.") }
            let range = (0..<7).map { index in
                let values = [proposal.baseline[index]] + proposal.steps.map { $0.positions[index] }
                return String(format: "J%d %.2f…%.2f", index + 1, values.min()!, values.max()!)
            }.joined(separator: "; ")
            let current = limit == 0 ? "Record currents only; automatic cutoff is not configured."
                : "Hold on a sample-to-sample current jump above \(limit) raw units; not a calibrated force limit."
            let scope = proposal.kind == "tabletop"
                ? "Complete a fixed-station can-to-bucket attempt: present EMPTY arm, calibrate empty jaws only if needed, open, approach, grip at intensity 2, small lift, carry to bucket release, open and retreat to the final held pose. No per-step Continue or approval. The empty can and bucket must match the taught positions. Jaw opening, retention and placement are unmeasured; supervise the whole attempt."
                : "Move only the empty physical LEFT arm; jaws unchanged."
            let text = "Reviewed ghost gesture ‘\(proposal.name)’: \(proposal.steps.count) steps, \(Int(ceil(proposal.seconds))) seconds scheduled, maximum 180 seconds including settling. \(range). Proposal \(proposal.id.uuidString), SHA256 \(proposal.fingerprint). \(scope) Camera centers at upright lower 6011 / upper 6306. Confirm physically hanging at encoder zero for the first movement of this session. Model/encoder mapping uses the recorded upright prior; watch actual arm, tread and cable clearance. This is a supervised trial, not certified collision or force protection. Keep Stop + hold ready; keep the controller open when using controller approval. \(current)"
            update("Awaiting controller approval for reviewed ghost: \(proposal.name)")
            ROBControllerArmApproval.shared.requestLeftGesture(summary: text,
                execute: { [weak self] done in
                    guard let self else { return }
                    self.proposal = proposal
                    self.start("left_ghost", summary: text, limit: limit, completion: done)
                }, cancel: { [weak self] in self?.abort("Controller cancelled the ghost gesture; hold requested.") },
                completion: { [weak self] result in self?.update(result["detail"] as? String ?? "Ghost gesture ended"); completion(result) })
        } catch { completion(["status": "blocked", "detail": error.localizedDescription]) }
    }

    /// Only the single currently dispatched step of the frozen accepted path
    /// is admitted. No caller supplies raw targets to the gateway.
    @nonobjc func approvedGestureTarget(id: UUID, index: Int, seconds: Double, generation: UInt64) -> [Double]? {
        guard let proposal, proposal.id == id, proposal.sessionGeneration == generation,
              proposalStep == index, proposal.steps.indices.contains(index),
              abs(proposal.steps[index].seconds - seconds) < 0.000001,
              authorizesTaughtWaypoint(arm: arm, expectedSessionGeneration: generation) else { return nil }
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
            referenceID: model.referenceID, geometryID: model.geometryID, mappingID: ROBGhostRobotModel.mappingID,
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
                      let sample = note.userInfo?["telemetry"] as? ROBAmberGatewayTelemetry,
                      sample.arm == self.arm else { return }
                do { try self.record(sample) } catch { self.abort(error.localizedDescription) }
            }
    }

    func perform(_ command: String, completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        guard Self.commands.contains(command) else { completion(["status": "rejected"]); return }
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
        case "left_search_workspace": action = "Search locally for a Coke can and an orange bucket by panning/tilting the neck camera. Confirm detections in two fresh RGB-D observations using on-device MLX. If missing, ask the nearest visible person to point and search in the estimated pointing direction. Report found/not found. No arm activation, gripper commands or arm travel."
        case "left_check_hanging": action = "Inspect both robot arms by panning/tilting the neck camera using on-device MLX; report whether each is visibly hanging. This observation never resets encoders or activates/moves either arm."
        case "left_recycle_can": action = "One experimental recycling task: scan the neck camera locally for an EMPTY Coke can and open orange bucket, confirm each twice with aligned depth, and ask a nearby person to point if needed. Plan with the provisional articulated camera/arm model. If reachable, present the empty LEFT arm, calibrate empty jaws if needed, open, approach the can, close at intensity 2, lift, carry above the bucket rim, open and retreat to a held pose. No per-step permission or Continue. Only this bounded locally computed path may execute. Wrong geometry or a failed grip can cause a miss; supervise the complete attempt. No automatic force escalation, blind retries, driving or torque-off with an object. Retention and placement remain unmeasured."
        case "left_wave": action = "Raise the empty LEFT arm along the initial tread-clearance approach, then coordinate J3/J5 together to -0.60 and J2/J6 together to +1.00/-0.60. Continue to J2 +1.30/J4 -0.60 and raised J5 -1.40. Seven approach segments from hanging plus four wave strokes; watch the newly coordinated front sweeps. Wave J1 -0.90/-1.05 twice with J6 -0.90/-0.60, and leave raised. Jaws unchanged."
        case "left_prepare": action = "Raise the empty LEFT arm in five segments from hanging: retain the initial three tread-clearance moves, then coordinate J3/J5 together to -0.60 and J2/J6 together to +1.00/-0.60. The endpoints are unchanged; the two front sweeps are newly coordinated, model-checked supervised candidates. Watch actual arm/body/tread/cable clearance. Reverse any raised wave section first. Calibrate its EMPTY gripper only if needed, then open it. Keep fingers clear during calibration."
        case "left_grip": action = "Keep the LEFT arm stationary in front and close its already-calibrated gripper at intensity \(intensity) around the presented OBJECT. Confirm the object is between the open jaws and all fingers are clear. Never grip a person's hand. No reopening, calibration or arm travel."
        case "left_release": action = "Keep the LEFT arm stationary in front and open its already-calibrated gripper to return the object. Confirm the receiver supports the object before approving. No calibration or arm travel."
        case "left_object_cycle": action = "Complete one LEFT object handoff: raise the EMPTY arm along the five-segment registered corridor, calibrate its EMPTY jaws only if needed, and open. Pause for the local Object placed / fingers clear signal before closing at vendor intensity 2. Keep the arm stationary while holding; pause for Receiver supporting before opening at intensity 2. Pause for Object clear / jaws empty before reversing the empty arm to hanging and deactivating. These three readiness buttons continue this single approval, not new approvals. Never close on a person's hand. Opening, retention and force are unmeasured; confirm the physical state. No timed automatic close, release or lower."
        default: action = "Return the empty LEFT arm along its registered corridor: reverse the raised section, coordinate the J2/J6 and J3/J5 front sweeps, then reverse the original tread-clearance approach to hanging and deactivate it. Earlier stopped poses use the older corridor when needed. Remove any object first. Watch actual clearance."
        }
        let notice = " Camera centers at the upright neck pose and tilts about 18 degrees below level. New J6/J2/J4 angles are a supervised trial, not a verified collision-free route; watch their direction and tread/cable clearance. Right arm receives no commands. Confirm LEFT arm physically hangs at encoder zero for the first movement of a new session. Watch the live camera and direct view; Stop + hold remains available. Camera object estimates do not veto this supervised trial."
        let current = limit == 0 ? " Current recording only; automatic current cutoff is not configured."
            : " Request hold if any joint's current changes by more than \(limit) raw units between samples; this is not a calibrated force limit."
        let travel = ["left_wave", "left_prepare", "left_relax", "left_object_cycle"].contains(command)
        let workspace = ["left_recycle_can", "left_search_workspace", "left_check_hanging"].contains(command)
        let approvedSummary = action + notice + current + (workspace ? " Maximum 360 seconds including search, planning and movement." : travel ? " Maximum 180 seconds including preparation and settling." : "")
        update("Awaiting spoken or controller authorization: \(action)")
        let execute: (@escaping (NSDictionary) -> Void) -> Void = { [weak self] done in
            self?.jawIntensity = intensity
            self?.start(command, summary: approvedSummary, limit: limit, completion: done)
        }
        let cancel = { [weak self] in self?.abort("Controller cancelled or disconnected; left-arm hold requested."); return }
        let finished: (NSDictionary) -> Void = { [weak self] result in
            self?.update(result["detail"] as? String ?? "Left-arm operation ended"); completion(result)
        }
        if workspace {
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
        do { try check(); return true } catch { return false }
    }

    private func update(_ message: String) {
        status = message; statusChanged?(message)
        NotificationCenter.default.post(name: Notification.Name("ROBArmRoutineDidChange"), object: self)
    }

    private func start(_ command: String, summary: String, limit: Double,
                       completion: @escaping (NSDictionary) -> Void) {
        let id = UUID()
        // Reserve both physical arms so another controller cannot move the
        // other arm into this trial. Only the left arm receives commands.
        guard ROBAmberArmMotionArbiter.shared.reserve(.left, owner: id) else {
            completion(["status": "blocked", "detail": "Another controller owns the left arm."]); return
        }
        guard ROBAmberArmMotionArbiter.shared.reserve(.right, owner: id) else {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: id)
            completion(["status": "blocked", "detail": "Another controller owns the right arm."]); return
        }
        owner = id; isRunning = true; self.summary = summary; currentLimit = limit
        activeCommand = command; interactionStage = ""; readinessConfirmed = false; taskJawTarget = nil
        lastRecordingPath = ""; sampleCount = 0; peakJump = 0
        failure = nil; generation = 0; cameraReady = false; positionReady = false; leased = false
        allowsArmTravel = ["left_wave", "left_prepare", "left_relax", "left_ghost", "left_object_cycle", "left_recycle_can"].contains(command)
        proposalStep = -1; sentPath = []
        waiting = []; acks = [:]; holdConfirmations = [:]; leaseRenewals = [:]; phase = "preflight"
        let workspace = ["left_recycle_can", "left_search_workspace", "left_check_hanging"].contains(command)
        deadline = ProcessInfo.processInfo.systemUptime + (workspace ? 350 : allowsArmTravel ? 170 : 115)
        vision.setActive(true); ROBArmRoutineCoordinator.shared.cameraDemand?(true)
        if !gateway.isReady() { ROBAmberGatewayTunnel.shared.connect() }
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
        guard ROBControllerArmApproval.shared.authorizesLeftArmTrial(summary) else {
            throw ROBArmRoutineError.blocked("Left-arm authorization ended; hold requested.")
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ROBArmRoutineError.blocked("Left-arm trial timed out.") }
        if generation > 0 {
            guard gateway.isReady(), (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == generation else {
                throw ROBArmRoutineError.blocked("Arm gateway session changed.")
            }
            _ = try measured()
        }
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
        guard let sample = gateway.telemetry(forArm: arm), sample.sequence > 0,
              sample.effectiveSampleAgeMilliseconds <= 250, sample.effectiveGripperFeedbackAgeMilliseconds <= 250,
              sample.positionsRadians.count == 7, sample.currents.count == 7,
              sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }), sample.currents.allSatisfy({ $0.doubleValue.isFinite }) else {
            throw ROBArmRoutineError.blocked("Fresh left-arm motor and gripper feedback is required.")
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
        if command == "left_search_workspace" || command == "left_check_hanging" {
            let model = try workspaceModel()
            _ = try await ROBWorkspaceSearch.shared.run(targets: command == "left_check_hanging" ? [] : ROBWorkspaceTarget.allCases,
                model: model, check: { try self.check() }, progress: { self.update($0) })
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
        let q = try measured().positionsRadians.map(\.doubleValue)
        if command == "left_recycle_can" {
            let model = try workspaceModel()
            let objects = try await ROBWorkspaceSearch.shared.run(targets: ROBWorkspaceTarget.allCases,
                model: model, check: { try self.check() }, progress: { self.update($0) })
            guard let can = objects[.can], let bucket = objects[.orangeBucket] else {
                return ["status": ROBWorkspaceSearch.shared.lastReport["status"] as? String == "depth_unconfirmed" ? "not_localized" : "not_found", "measured": false, "arm_motion_sent": false,
                    "detail": ROBWorkspaceSearch.shared.lastReport["detail"] ?? "Can or orange bucket was not confirmed.",
                    "workspace_search": ROBWorkspaceSearch.shared.lastReport]
            }
            guard [can, bucket].allSatisfy({ Date().timeIntervalSince1970 * 1000 - $0.capturedAt < 60_000 }) else {
                throw ROBGhostMotionError.blocked("Object observations expired during search; no arm travel was sent.")
            }
            guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue), q, tolerance: 0.015) else {
                throw ROBGhostMotionError.blocked("Arm start position changed during the scan; no reach was sent.")
            }
            do {
                let task = try ROBWorkspaceGrounding.task(can: can, bucket: bucket, model: model)
                proposal = try ROBLeftGestureCompiler.compile(kind: "tabletop", name: task.name, poses: task.poses,
                    model: model, baseline: q, generation: generation)
                try ROBLeftGestureCompiler.validate(proposal!, model: model)
            } catch {
                return ["status": "not_reachable", "arm_motion_sent": false, "measured": false,
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
            ?? (proposal?.kind == "recover" && referencedGeneration == generation ? [] : nil) else {
            throw ROBArmRoutineError.blocked("Left arm is outside the taught route; no movement sent.")
        }
        if stationaryJaw {
            try verifyFront()
        } else if referencedGeneration != generation {
            guard ROBArmRoutinePlan.near(q, Array(repeating: 0, count: 7)) else {
                throw ROBArmRoutineError.blocked("First left-arm movement in a new session must start physically hanging at encoder zero.")
            }
            referencedGeneration = generation
        }
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
        if stationaryJaw {
            try await settleFront()
        } else if let proposal {
            try await move(proposal)
            if proposal.kind == "tabletop" {
                try await holdTaskPosition(proposal.steps.last!.positions)
                return ["status": "accepted_unverified", "measured": false, "motion_completed": true,
                    "gripper_measured": false, "placement_verified": false, "gripper_intensity": ROBTabletopPickPlace.intensity,
                    "workspace_search": command == "left_recycle_can" ? ROBWorkspaceSearch.shared.lastReport : [:],
                    "detail": "The left arm reached all recycling-task positions; grip and release at intensity 2 were accepted. It is holding at the taught retreat pose. Object retention, jaw opening and placement in the bucket are unverified; inspect the result."]
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
                ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.waveRestIndex])
            return ["status": "completed", "measured": true, "detail": "Left arm waved twice above the shoulder and is holding raised. Gripper unchanged."]
        case "left_object_cycle":
            return try await objectCycleAtFront()
        default:
            try await holdFrontForGripper()
            try await requireGripperCalibration(allowEmptyCalibration: command == "left_prepare")
            try await commandJaw(action: command == "left_grip" ? "hold" : "release", intensity: jawIntensity)
            return ["status": "accepted_unverified", "measured": false, "detail": command == "left_grip"
                ? "Left grip command accepted; arm stays in front. Check object retention before releasing your support."
                : "Left open command accepted; arm stays in front. Check the jaws and object before continuing."]
        }
    }

    private func workspaceModel() throws -> ROBGhostRobotModel {
        guard let directory = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw ROBGhostMotionError.blocked("Bundled workspace model is unavailable.")
        }
        return try ROBGhostRobotModel(directory: directory)
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
        try await requireGripperCalibration(allowEmptyCalibration: action == .prepare)
        phase = "tabletop \(action.rawValue)"
        update(action == .grip ? "Local task: gripping empty can at intensity 2" : "Local task: opening gripper at the planned position")
        try await accepted { gateway.controlGripper(forArm: arm, action: action == .grip ? "hold" : "release",
            force: ROBTabletopPickPlace.intensity) }
        let end = ProcessInfo.processInfo.systemUptime + 1.5
        try await wait(3) { ProcessInfo.processInfo.systemUptime >= end }
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
            let end = ProcessInfo.processInfo.systemUptime + 2
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

    @MainActor private func move(_ route: [Int]) async throws {
        guard let compacted = ROBLeftArmInteractionPlan.compactRoute(
            from: try measured().positionsRadians.map(\.doubleValue), indices: route) else {
            throw ROBArmRoutineError.blocked("Left-arm route changed or crosses a path corner; no movement sent.")
        }
        for index in compacted {
            try check()
            let target = ROBLeftArmInteractionPlan.target(index: index)!
            let duration = ROBLeftArmInteractionPlan.duration(from: try measured().positionsRadians.map(\.doubleValue), to: target)!
            phase = "waypoint \(index)"; update("Left arm: \(phase)")
            let started = ProcessInfo.processInfo.systemUptime
            try await accepted { gateway.sendRoutineWaypoint(arm: arm, index: index, duration: duration, expectedSessionGeneration: generation) }
            leased = true; lastRenewal = ProcessInfo.processInfo.systemUptime
            var settler = ROBArmRoutineSettler()
            try await wait(duration + 3) {
                guard let sample = try? self.measured() else { return false }
                return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                    target: target, now: ProcessInfo.processInfo.systemUptime) && ProcessInfo.processInfo.systemUptime - started >= duration
            }
        }
    }

    @MainActor private func move(_ proposal: ROBLeftGestureProposal) async throws {
        for (index, step) in proposal.steps.enumerated() {
            try check()
            let q = try measured().positionsRadians.map(\.doubleValue)
            guard let minimum = ROBLeftArmInteractionPlan.duration(from: q, to: step.positions), step.seconds >= minimum - 0.05 else {
                throw ROBArmRoutineError.blocked("Measured start drift exceeds the reviewed timing; hold requested.")
            }
            proposalStep = index; phase = "gesture step \(index)"; update("\(proposal.name): step \(index + 1)/\(proposal.steps.count)")
            let started = ProcessInfo.processInfo.systemUptime
            sentPath.append(step.positions)
            try await accepted { gateway.sendApprovedLeftGestureStep(proposalID: proposal.id, index: index,
                duration: step.seconds, expectedSessionGeneration: generation) }
            leased = true; lastRenewal = ProcessInfo.processInfo.systemUptime
            var settler = ROBArmRoutineSettler()
            try await wait(step.seconds + 3) {
                guard let sample = try? self.measured() else { return false }
                return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                    target: step.positions, now: ProcessInfo.processInfo.systemUptime)
                    && ProcessInfo.processInfo.systemUptime - started >= step.seconds
            }
            proposalStep = -1
            if let action = step.jawAction { try await taskJaw(action, at: step.positions) }
        }
    }

    private func monitor() {
        guard isRunning, failure == nil else { return }
        do {
            try check()
            if generation > 0 { try record(measured()) }
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

    private func beginRecording(_ command: String) throws {
        let folder = try recordingDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Cerebro/LeftArmTrials")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(command)-\(UUID().uuidString).csv")
        try Data("elapsed_s,sequence,robot_arm,gateway_arm,joint,position_rad,current_raw,current_delta_raw,feedback_age_ms,phase\n".utf8).write(to: url, options: .atomic)
        log = try FileHandle(forWritingTo: url); try log?.seekToEnd()
        lastRecordingPath = url.path; logStarted = ProcessInfo.processInfo.systemUptime
        if let proposal { try proposal.encoded().write(to: url.deletingPathExtension().appendingPathExtension("proposal.json"), options: .atomic) }
        lastSequence = 0; previousCurrents = nil; peakJump = 0; sampleCount = 0
    }

    private func record(_ sample: ROBAmberGatewayTelemetry) throws {
        guard log != nil, sample.sequence > lastSequence else { return }
        guard sample.effectiveSampleAgeMilliseconds <= 250, sample.positionsRadians.count == 7,
              sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
              sample.currents.count == 7, sample.currents.allSatisfy({ $0.doubleValue.isFinite }) else {
            throw ROBArmRoutineError.blocked("Invalid or stale left-arm current recording; hold requested.")
        }
        let currents = sample.currents.map(\.doubleValue)
        let changes = zip(currents, previousCurrents ?? currents).map { $0 - $1 }
        let jump = changes.map(abs).max() ?? 0
        peakJump = max(peakJump, jump); previousCurrents = currents; lastSequence = sample.sequence; sampleCount += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - logStarted
        let rows = (0..<7).map { "\(elapsed),\(sample.sequence),left,right,\($0 + 1),\(sample.positionsRadians[$0]),\(currents[$0]),\(changes[$0]),\(sample.effectiveSampleAgeMilliseconds),\(phase)\n" }.joined()
        try log?.write(contentsOf: Data(rows.utf8))
        if currentLimit > 0, jump > currentLimit {
            throw ROBArmRoutineError.blocked("Left-arm current jump \(jump) exceeded \(currentLimit) raw units; hold requested. Inspect the recording before retrying.")
        }
    }

    private func abort(_ message: String) {
        guard isRunning, failure == nil else { return }
        failure = message; task?.cancel()
        interactionStage = ""; readinessConfirmed = false
        _ = gateway.priorityHold(forArm: arm); leased = false
        update(message)
    }

    private func finish(_ result: NSDictionary, completion: @escaping (NSDictionary) -> Void) {
        timer?.invalidate(); timer = nil
        if leased || result["status"] as? String == "blocked" { _ = gateway.priorityHold(forArm: arm) }
        leased = false
        if proposal?.kind == "tabletop" {
            // A failed close/open may leave a payload. Never offer the old
            // empty-arm reverse/recovery automatically for a recycling task.
            recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
        } else if proposal != nil, result["status"] as? String != "completed", sentPath.count > 1 {
            recoveryPath = sentPath; recoveryGeneration = generation
        } else if result["status"] as? String == "completed" {
            recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
        }
        var output = result as! [String: Any]
        do { try log?.synchronize(); try log?.close() } catch {
            output["recording_error"] = error.localizedDescription
            output["status"] = "blocked"
            output["detail"] = "Left-arm trial ended, but saving the current recording failed: \(error.localizedDescription)"
        }
        log = nil
        output["current_recording"] = lastRecordingPath
        output["current_samples"] = sampleCount
        output["peak_current_jump_raw"] = peakJump
        output["current_jump_limit_raw"] = currentLimit
        if let proposal {
            output["motion_proposal_id"] = proposal.id.uuidString
            output["motion_proposal_sha256"] = proposal.fingerprint
        }
        vision.setActive(false); ROBArmRoutineCoordinator.shared.cameraDemand?(false)
        if let owner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: owner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: owner)
        }
        owner = nil; isRunning = false; task = nil; proposal = nil; proposalStep = -1
        activeCommand = ""; interactionStage = ""; readinessConfirmed = false; taskJawTarget = nil
        update(output["detail"] as? String ?? "Left-arm trial ended")
        completion(output as NSDictionary)
    }
}
