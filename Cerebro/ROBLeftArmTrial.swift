import AppKit

/// Operator-supervised trials using the taught approach and a small front-only
/// J3/J5 extension. New extension angles still require physical commissioning.
/// Physical left is Amber R11, gateway `right`; never dispatch to L10 here.
@objcMembers final class ROBLeftArmTrial: NSObject {
    static let shared = ROBLeftArmTrial()
    static let commands = ["left_wave", "left_prepare", "left_grip", "left_release", "left_relax"]
    static let currentLimitKey = "ROBLeftArmCurrentJumpLimitRaw"
    private(set) var isRunning = false
    private(set) var status = "Left arm ready for a supervised trial"
    private(set) var lastRecordingPath = ""
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

    override init() {
        super.init()
        ackObserver = NotificationCenter.default.addObserver(forName: .ROBAmberGatewayCommandDidComplete,
            object: gateway, queue: .main) { [weak self] note in
                guard let self, self.isRunning,
                      let id = (note.userInfo?["commandID"] as? NSNumber)?.uint64Value else { return }
                let accepted = note.userInfo?["accepted"] as? Bool == true
                let renewal = self.leaseRenewals.removeValue(forKey: id) != nil
                if self.waiting.contains(id) { self.acks[id] = accepted }
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
        switch command {
        case "left_wave": action = "Move the empty LEFT arm along the tested route to front, then try the new front pose: J3 to -0.30 rad, followed by J5 to -0.30 rad, each in 0.10-rad steps. Wave twice with J1 between -0.90 and -1.05 rad; leave it at the new front pose. Jaws unchanged."
        case "left_prepare": action = "Bring the empty LEFT arm along the tested route to front, then try J3 -0.30 rad followed by J5 -0.30 rad in 0.10-rad steps. Calibrate its EMPTY gripper only if needed, then open it. Keep fingers clear during calibration."
        case "left_grip": action = "Keep the LEFT arm stationary in front and close its already-calibrated gripper at intensity 10 around the presented OBJECT. Confirm the object is between the open jaws and all fingers are clear. Never grip a person's hand. No reopening, calibration or arm travel."
        case "left_release": action = "Keep the LEFT arm stationary in front and open its already-calibrated gripper to return the object. Confirm the receiver supports the object before approving. No calibration or arm travel."
        default: action = "Return the empty LEFT arm: undo any new J5 and J3 rotations at the front pose FIRST, then reverse the tested route to hanging and deactivate it. Remove any object first."
        }
        let notice = " Camera faces forward at the existing upright neck pose. New J3/J5 angles are a supervised trial, not a verified collision-free route; watch their direction and tread/cable clearance. Right arm receives no commands. Confirm LEFT arm physically hangs at encoder zero for the first movement of a new session. Watch the live camera and direct view; Stop + hold remains available. Camera object estimates do not veto this supervised trial."
        let current = limit == 0 ? " Current recording only; automatic current cutoff is not configured."
            : " Request hold if any joint's current changes by more than \(limit) raw units between samples; this is not a calibrated force limit."
        let approvedSummary = action + notice + current
        update("Awaiting controller approval: \(action)")
        ROBControllerArmApproval.shared.request(operation: "manual", arm: "left", summary: approvedSummary,
            execute: { [weak self] done in self?.start(command, summary: approvedSummary, limit: limit, completion: done) },
            cancel: { [weak self] in self?.abort("Controller cancelled or disconnected; left-arm hold requested.") },
            completion: { [weak self] result in
                self?.update(result["detail"] as? String ?? "Left-arm operation ended")
                completion(result)
            })
    }

    func cancel(reason: String) { abort(reason) }

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
        lastRecordingPath = ""; sampleCount = 0; peakJump = 0
        failure = nil; generation = 0; cameraReady = false; positionReady = false; leased = false
        allowsArmTravel = ["left_wave", "left_prepare", "left_relax"].contains(command)
        waiting = []; acks = [:]; leaseRenewals = [:]; phase = "preflight"
        deadline = ProcessInfo.processInfo.systemUptime + 90
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
            throw ROBArmRoutineError.blocked("Left-arm controller approval ended; hold requested.")
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

    @MainActor private func accepted(_ dispatch: () -> UInt64) async throws {
        try check()
        let id = dispatch()
        guard id != 0 else { throw ROBArmRoutineError.blocked("Gateway refused left-arm command during \(phase), before submission.") }
        waiting.insert(id)
        try await wait(3) { self.acks[id] == true }
        waiting.remove(id); acks.removeValue(forKey: id)
    }

    @MainActor private func execute(_ command: String) async throws -> NSDictionary {
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
        let stationaryJaw = command == "left_grip" || command == "left_release"
        guard let route = ROBLeftArmInteractionPlan.route(from: q, hanging: command == "left_relax") else {
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
            // Position mode and one matching encoder read do not prove that
            // an earlier trajectory has settled. Require distinct stable reads.
            var settler = ROBArmRoutineSettler()
            guard let front = ROBLeftArmInteractionPlan.stationaryFrontTarget(try measured().positionsRadians.map(\.doubleValue)) else {
                throw ROBArmRoutineError.blocked("Left arm drifted from the front pose; no jaw command sent.")
            }
            try await wait(2) {
                guard let sample = try? self.measured() else { return false }
                return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                    target: front, now: ProcessInfo.processInfo.systemUptime)
            }
        } else { try await move(route) }
        switch command {
        case "left_relax":
            guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue), Array(repeating: 0, count: 7)) else {
                throw ROBArmRoutineError.blocked("Hanging arrival not measured; torque remains on.")
            }
            positionReady = false; phase = "deactivating"
            try await accepted { gateway.deactivateArm(arm) }
            leased = false
            try await wait(2) { let modes = self.gateway.modes(forArm: self.arm); return modes.count == 7 && modes.allSatisfy({ $0.intValue == 0 }) }
            return ["status": "completed", "measured": true, "detail": "Left arm reached hanging and is inactive."]
        case "left_wave":
            try await move([ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.frontIndex,
                ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.frontIndex])
            return ["status": "completed", "measured": true, "detail": "Left arm waved twice and is holding in front. Gripper unchanged."]
        default:
            try verifyFront()
            try await accepted { gateway.queryGripperState(forArm: arm) }
            let calibrated = gateway.gripperSnapshot(forArm: arm)["calibrationState"] as? String == "command_accepted_unverified"
            if !calibrated {
                guard command == "left_prepare" else { throw ROBArmRoutineError.blocked("Use Present / open with empty jaws first. Grip/release never recalibrates.") }
                phase = "empty gripper calibration"; update("Calibrating empty left gripper")
                try await accepted { gateway.calibrateGripper(forArm: arm) }
                let end = ProcessInfo.processInfo.systemUptime + 2
                try await wait(3) { ProcessInfo.processInfo.systemUptime >= end }
            }
            try verifyFront()
            phase = command == "left_grip" ? "grip object" : "release object"
            update(command == "left_grip" ? "Closing left gripper on the presented object" : "Opening left gripper; support the object")
            try await accepted { gateway.controlGripper(forArm: arm, action: command == "left_grip" ? "hold" : "release", force: 10) }
            let end = ProcessInfo.processInfo.systemUptime + 1.5
            try await wait(3) { ProcessInfo.processInfo.systemUptime >= end }
            return ["status": "accepted_unverified", "measured": false, "detail": command == "left_grip"
                ? "Left grip command accepted; arm stays in front. Check object retention before releasing your support."
                : "Left open command accepted; arm stays in front. Check the jaws and object before continuing."]
        }
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

    @MainActor private func move(_ route: [Int]) async throws {
        for index in route {
            try check()
            let target = ROBLeftArmInteractionPlan.target(index: index)!
            let duration = ROBArmRoutinePlan.duration(from: try measured().positionsRadians.map(\.doubleValue), to: target)!
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
        _ = gateway.priorityHold(forArm: arm); leased = false
        update(message)
    }

    private func finish(_ result: NSDictionary, completion: @escaping (NSDictionary) -> Void) {
        timer?.invalidate(); timer = nil
        if leased || result["status"] as? String == "blocked" { _ = gateway.priorityHold(forArm: arm) }
        leased = false
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
        vision.setActive(false); ROBArmRoutineCoordinator.shared.cameraDemand?(false)
        if let owner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: owner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: owner)
        }
        owner = nil; isRunning = false; task = nil
        update(output["detail"] as? String ?? "Left-arm trial ended")
        completion(output as NSDictionary)
    }
}
