import AppKit

extension Notification.Name {
    static let ROBGripperStartupCalibrationDidChange = Notification.Name("ROBGripperStartupCalibrationDidChange")
}

/// The user's standing startup permission is limited to EMPTY jaws on freshly
/// measured, inactive hanging arms. This does not create or restore arm grants.
/// Amber acknowledges dispatch, so readiness never claims measured jaw travel.
@objcMembers final class ROBGripperStartupCalibration: NSObject {
    static let preferenceKey = "ROBGripperCalibrateOnStartup"
    static let shared = ROBGripperStartupCalibration()
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
            if !newValue {
                DispatchQueue.main.async { shared.stop(reason: "Automatic gripper calibration disabled") }
            }
        }
    }

    private(set) var isRunning = false
    private(set) var status = "Waiting for Amber connection; keep hanging grippers empty"
    private let gateway: ROBAmberGatewayClient
    private var task: Task<Void, Never>?
    private var startupOffered = false
    private var generation: UInt64 = 0
    private var initializedArms = Set<String>()
    private var attemptedGenerations = Set<UInt64>()
    private var commandResults: [UInt64: Bool] = [:]
    private var expectedCommand: UInt64?
    // Stop has no vendor jaw-stop primitive. Retain this conservative settle
    // boundary across cancellation before permitting an explicit retry.
    private var calibrationSettlesAtUptime: TimeInterval = 0
    private var activeOwner: UUID?
    private var arbiterOwner: UUID?
    private var borrowedOwner = false
    private var failure: String?
    private var observers: [NSObjectProtocol] = []
    private var sleepObserver: NSObjectProtocol?
    private let arms = ["left", "right"]

    override convenience init() { self.init(gateway: .shared) }

    @nonobjc init(gateway: ROBAmberGatewayClient) {
        self.gateway = gateway
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .ROBAmberGatewayStateDidChange,
            object: gateway, queue: .main) { [weak self] _ in
                guard let self else { return }
                if !self.gateway.isReady() {
                    self.initializedArms.removeAll()
                    self.stop(reason: "Amber disconnected; no gripper setup will replay on reconnect")
                }
            })
        observers.append(center.addObserver(forName: .ROBAmberGatewayCommandDidComplete,
            object: gateway, queue: .main) { [weak self] note in
                guard let self, let id = (note.userInfo?["commandID"] as? NSNumber)?.uint64Value else { return }
                if id == self.expectedCommand {
                    self.commandResults[id] = note.userInfo?["accepted"] as? Bool == true
                    if self.commandResults[id] != true {
                        if note.userInfo?["operation"] as? String == "gripper_calibrate" {
                            self.calibrationSettlesAtUptime = 0
                        }
                        self.failure = note.userInfo?["error"] as? String ?? "Gripper setup was rejected"
                    }
                } else if note.userInfo?["operation"] as? String == "gripper_calibrate",
                          let arm = note.userInfo?["arm"] as? String {
                    self.initializedArms.remove(arm)
                }
            })
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.initializedArms.removeAll()
                self?.stop(reason: "Sleep cancelled gripper setup; no automatic replay")
            }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        task?.cancel()
    }

    /// Called once after the first authenticated ready event in this process.
    /// A later reconnect invalidates readiness but never repeats jaw motion.
    func gatewayBecameReady() {
        precondition(Thread.isMainThread)
        guard !startupOffered else { return }
        startupOffered = true
        guard Self.enabled else { update("Automatic gripper calibration is disabled"); return }
        start(borrowing: nil)
    }

    func calibrationReady(forArm arm: String) -> Bool {
        precondition(Thread.isMainThread)
        return initializedArms.contains(arm) && gateway.isReady()
            && currentGeneration == generation && generation > 0
            && gateway.gripperSnapshot(forArm: arm)["calibrationState"] as? String == "command_accepted_unverified"
    }

    /// A newly authorized routine can finish deferred setup while its EMPTY
    /// arm is parked. Borrow its existing reservation; never move or raise it.
    @MainActor @nonobjc func ensureReady(whileParkedBy owner: UUID) async throws {
        if arms.allSatisfy({ calibrationReady(forArm: $0) }) { return }
        guard Self.enabled else {
            throw ROBArmRoutineError.blocked("Automatic gripper calibration is disabled. Enable it or run stationary empty-gripper setup in Testing Sandbox.")
        }
        if !isRunning { start(borrowing: owner) }
        while isRunning {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard arms.allSatisfy({ calibrationReady(forArm: $0) }) else {
            throw ROBArmRoutineError.blocked(status)
        }
    }

    /// Explicit sandbox action for users who disabled automatic startup.
    /// The same stationary, inactive, empty-jaw policy remains mandatory.
    @MainActor @nonobjc func prepareStationaryEmptyGrippers() async throws {
        if arms.allSatisfy({ calibrationReady(forArm: $0) }) { return }
        if !isRunning { start(borrowing: nil, manualRetry: true) }
        while isRunning {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard arms.allSatisfy({ calibrationReady(forArm: $0) }) else {
            throw ROBArmRoutineError.blocked(status)
        }
    }

    /// No jaw-stop primitive is supplied by Amber. Stop prevents every
    /// subsequent dispatch; an already accepted vendor calibration may finish.
    func stop(reason: String) {
        precondition(Thread.isMainThread)
        failure = reason
        task?.cancel()
        if isRunning { update(reason + "; no further jaw commands will be sent") }
        else { update(reason) }
    }

    private var currentGeneration: UInt64 {
        (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
    }

    private func start(borrowing owner: UUID?, manualRetry: Bool = false) {
        guard !isRunning, gateway.isReady() else { return }
        let nextGeneration = currentGeneration
        guard nextGeneration > 0, manualRetry || !attemptedGenerations.contains(nextGeneration) else {
            update("Gripper setup already attempted in this connection; inspect the jaws before retrying")
            return
        }
        generation = nextGeneration
        initializedArms.removeAll()
        failure = nil
        isRunning = true
        update("Waiting for stationary, hanging, inactive EMPTY grippers")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finish() }
            do {
                try await self.run(borrowing: owner)
                self.update("Empty gripper setup dispatched; jaws commanded open, completion unmeasured")
            } catch {
                self.initializedArms.removeAll()
                self.update(self.failure ?? error.localizedDescription)
            }
        }
    }

    @MainActor private func run(borrowing owner: UUID?) async throws {
        for arm in arms { _ = gateway.queryMode(forArm: arm) }
        var previous: [String: (sequence: UInt64, positions: [Double])] = [:]
        var stationarySince: TimeInterval?
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while true {
            try check(parked: false)
            if let reason = freshNonParkedReason() {
                throw ROBArmRoutineError.blocked("Startup gripper setup deferred: " + reason)
            }
            if let samples = parkedSamples() {
                let advancing = arms.allSatisfy { arm in
                    guard let old = previous[arm], let sample = samples[arm] else { return false }
                    return sample.sequence > old.sequence
                        && zip(sample.positionsRadians.map(\.doubleValue), old.positions).allSatisfy { abs($0 - $1) <= 0.004 }
                }
                if advancing {
                    if stationarySince == nil { stationarySince = ProcessInfo.processInfo.systemUptime }
                    if ProcessInfo.processInfo.systemUptime - stationarySince! >= 0.5 { break }
                } else { stationarySince = nil }
                previous = samples.mapValues { ($0.sequence, $0.positionsRadians.map(\.doubleValue)) }
            } else { previous.removeAll(); stationarySince = nil }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ROBArmRoutineError.blocked("Startup gripper setup deferred: both EMPTY arms must be hanging, stationary and inactive")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let reservation = owner ?? UUID()
        if owner != nil {
            guard ROBAmberArmMotionArbiter.shared.isReserved(.left, owner: reservation),
                  ROBAmberArmMotionArbiter.shared.isReserved(.right, owner: reservation) else {
                throw ROBArmRoutineError.blocked("The requesting routine no longer owns both arm reservations")
            }
        }
        guard ROBAmberArmMotionArbiter.shared.reserve(.left, owner: reservation) else {
            throw ROBArmRoutineError.blocked("Gripper setup deferred while another operation owns the arms")
        }
        guard ROBAmberArmMotionArbiter.shared.reserve(.right, owner: reservation) else {
            if owner == nil { ROBAmberArmMotionArbiter.shared.release(.left, owner: reservation) }
            throw ROBArmRoutineError.blocked("Gripper setup deferred while another operation owns the arms")
        }
        arbiterOwner = reservation
        borrowedOwner = owner != nil
        guard let gatewayOwner = gateway.beginStartupGripperCalibration(expectedGeneration: generation) else {
            throw ROBArmRoutineError.blocked("Gripper startup admission changed; no calibration sent")
        }
        activeOwner = gatewayOwner
        attemptedGenerations.insert(generation)
        let remainingSettle = calibrationSettlesAtUptime - ProcessInfo.processInfo.systemUptime
        if remainingSettle > 0 {
            update("Waiting for the earlier calibration dispatch to settle before the requested retry")
            try await pause(remainingSettle)
        }
        for arm in arms {
            update("Calibrating empty \(arm == "right" ? "left" : "right") gripper while hanging")
            try await accepted(arm: arm, operation: "gripper_calibrate")
            try await pause(10)
            try await accepted(arm: arm, operation: "initialize_close")
            try await pause(1.5)
            try await accepted(arm: arm, operation: "initialize_open")
            try await pause(1.5)
            initializedArms.insert(arm)
        }
    }

    private func parkedSamples() -> [String: ROBAmberGatewayTelemetry]? {
        var result: [String: ROBAmberGatewayTelemetry] = [:]
        for arm in arms {
            guard let sample = gateway.telemetry(forArm: arm),
                  sample.effectiveSampleAgeMilliseconds <= 250,
                  sample.effectiveGripperFeedbackAgeMilliseconds <= 250,
                  ROBArmRoutinePlan.near(sample.positionsRadians.map(\.doubleValue), Array(repeating: 0, count: 7)),
                  sample.statuses.count == 7, sample.statuses.allSatisfy({ $0.intValue == 0 }),
                  gateway.modes(forArm: arm).count == 7,
                  gateway.modes(forArm: arm).allSatisfy({ $0.intValue == 0 }) else { return nil }
            result[arm] = sample
        }
        return result
    }

    /// A known held/active pose cannot become eligible without a separate arm
    /// operation. Defer immediately so startup never blocks that operation.
    private func freshNonParkedReason() -> String? {
        for arm in arms {
            guard let sample = gateway.telemetry(forArm: arm),
                  sample.effectiveSampleAgeMilliseconds <= 250,
                  sample.effectiveGripperFeedbackAgeMilliseconds <= 250 else { continue }
            if !ROBArmRoutinePlan.near(sample.positionsRadians.map(\.doubleValue), Array(repeating: 0, count: 7)) {
                return "both EMPTY arms must be hanging before stationary setup"
            }
            let modes = gateway.modes(forArm: arm)
            if sample.statuses.count == 7 && sample.statuses.contains(where: { $0.intValue != 0 })
                || modes.count == 7 && modes.contains(where: { $0.intValue != 0 }) {
                return "both EMPTY arms must be inactive before stationary setup"
            }
        }
        return nil
    }

    private func check(parked: Bool = true) throws {
        try Task.checkCancellation()
        if let failure { throw ROBArmRoutineError.blocked(failure) }
        guard gateway.isReady(), currentGeneration == generation, generation > 0 else {
            throw ROBArmRoutineError.blocked("Amber connection changed; gripper setup cancelled")
        }
        guard !parked || parkedSamples() != nil else {
            throw ROBArmRoutineError.blocked("Fresh inactive hanging feedback was lost; gripper setup cancelled")
        }
        if let arbiterOwner {
            guard ROBAmberArmMotionArbiter.shared.isReserved(.left, owner: arbiterOwner),
                  ROBAmberArmMotionArbiter.shared.isReserved(.right, owner: arbiterOwner) else {
                throw ROBArmRoutineError.blocked("Arm ownership changed; gripper setup cancelled")
            }
        }
    }

    @MainActor private func accepted(arm: String, operation: String) async throws {
        try check()
        guard let activeOwner else { throw ROBArmRoutineError.blocked("Gripper startup ownership ended") }
        let id = gateway.sendStartupGripperCommand(forArm: arm, operation: operation,
            owner: activeOwner, expectedGeneration: generation)
        guard id > 0 else { throw ROBArmRoutineError.blocked("Gateway refused stationary gripper setup before dispatch") }
        if operation == "gripper_calibrate" {
            // Include the maximum 3s acknowledgement window plus the existing
            // 10s physical settle if cancellation makes acknowledgement late.
            calibrationSettlesAtUptime = ProcessInfo.processInfo.systemUptime + 13
        }
        expectedCommand = id
        defer { expectedCommand = nil; commandResults.removeValue(forKey: id) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while commandResults[id] != true {
            try check()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ROBArmRoutineError.blocked("Gripper setup acknowledgement timed out; no automatic retry")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check()
    }

    @MainActor private func pause(_ seconds: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try check()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try check()
    }

    private func finish() {
        if let activeOwner { gateway.endStartupGripperCalibration(owner: activeOwner) }
        if let arbiterOwner, !borrowedOwner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: arbiterOwner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: arbiterOwner)
        }
        activeOwner = nil; arbiterOwner = nil; borrowedOwner = false
        expectedCommand = nil; commandResults.removeAll()
        isRunning = false; task = nil
        NotificationCenter.default.post(name: .ROBGripperStartupCalibrationDidChange, object: self)
    }

    private func update(_ detail: String) {
        status = detail
        NotificationCenter.default.post(name: .ROBGripperStartupCalibrationDidChange, object: self)
    }
}
