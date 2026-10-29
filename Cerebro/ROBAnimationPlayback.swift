import Cocoa

/// A local Run on robot click owns a frozen sequence until completion or Stop.
/// JSON imports and ghost notifications have no route to this executor.
@objc(ROBAnimationPlayback) final class ROBAnimationPlayback: NSObject {
    @objc static let shared = ROBAnimationPlayback()
    static let changed = Notification.Name("ROBAnimationPlaybackChanged")
    @objc private(set) var isRunning = false
    @objc private(set) var status = "Animation playback idle"
    private var sequence: ROBAnimationSequence?
    private weak var serial: ROBSerialBox?
    private var owner: UUID?
    private var generation: UInt64 = 0
    private var arms: [String] = []
    private var reserved: [ROBArmSide] = []
    private var timer: Timer?
    private var deadline = 0.0
    private var lastTick = 0.0
    private var preparing = true
    private var modesRequested = false
    private var index = -1
    private var clipStarted = 0.0
    private var baseline: [String: Double] = [:]
    private var target: [String: Double] = [:]
    private var nextStep = 0.0
    private var stepUntil = 0.0
    private var approved: [String: [Double]] = [:]
    private var approvedDuration = 0.0
    private var pending: [UInt64: Double] = [:]
    private var leasedArms = Set<String>()
    private var lastCurrents: [String: [Double]] = [:]
    private var lastSequences: [String: UInt64] = [:]
    private var currentLimit = 0.0
    private var settling = 0
    private var lastSettledSequences: [String: UInt64] = [:]
    private var torsoStarted = false
    private var usesMaestro = false
    private var usesLACT = false
    private var usesTorso = false
    private let gateway = ROBAmberGatewayClient.shared

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(localTakeover), name: Notification.Name("ROBLocalManualControlRequested"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(commandCompleted(_:)), name: .ROBAmberGatewayCommandDidComplete, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willStop), name: NSApplication.willTerminateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willStop), name: NSWorkspace.willSleepNotification, object: nil)
    }
    private func publish(_ text: String) { status = text; NotificationCenter.default.post(name: Self.changed, object: self) }
    private func require(_ condition: Bool, _ message: String) throws { if !condition { throw ROBAnimationError.invalid(message) } }

    func start(sequence: ROBAnimationSequence, serial: ROBSerialBox) {
        precondition(Thread.isMainThread)
        stop(reason: "Replacing animation")
        do {
            var document = ROBAnimationDocument(); document.sequences = [sequence]; try document.validate()
            try require(!sequence.clips.isEmpty, "This sequence has no clips.")
            try require(sequence.clips.allSatisfy { !$0.pose.needsReview }, "Review imported clip values and Update selected before robot playback.")
            try require(sequence.clips.allSatisfy { !$0.pose.values.isEmpty }, "Remove empty clips before robot playback.")
            let channels = Set(sequence.clips.flatMap { $0.pose.values.keys })
            arms = ["right", "left"].filter { side in channels.contains { $0.hasPrefix("arm.\(side).") } }.map { $0 == "right" ? "left" : "right" }
            usesMaestro = channels.contains { $0.hasPrefix("maestro.") }
            usesLACT = channels.contains("lact.speed"); usesTorso = channels.contains("torso.heading")
            try require(!usesMaestro || serial.animationMaestroReady, "Connect Maestro before playing servo tracks.")
            try require(!usesLACT || serial.animationLACTReady, "Connect the base controller before playing LACT tracks.")
            try require(!usesTorso || ROBTorsoControlCenter.shared.usesHardware, "Select live hardware in Torso Rotation before running a torso track.")
            generation = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
            if !arms.isEmpty { try require(gateway.isReady() && generation > 0, "Connect Amber before playing arm tracks.") }
            for arm in arms { _ = try measured(arm, requirePosition: false) }
            // The local click supersedes automatic owners once for the whole
            // sequence; it never creates a reusable model/voice approval.
            ROBControllerArmApproval.shared.takeLocalPanelControl()
            self.sequence = sequence; self.serial = serial; owner = UUID(); isRunning = true
            currentLimit = UserDefaults.standard.double(forKey: ROBLeftArmTrial.currentLimitKey)
            preparing = true; modesRequested = false; deadline = now + 2; lastTick = now
            index = -1; pending = [:]; leasedArms = []; lastCurrents = [:]; lastSequences = [:]
            publish("Taking local control for \(sequence.name)…")
            let clock = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
            timer = clock; RunLoop.main.add(clock, forMode: .common)
            tick()
        } catch { stop(reason: error.localizedDescription) }
    }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private func measured(_ arm: String, requirePosition: Bool = true) throws -> [Double] {
        try require(gateway.isReady() && (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == generation, "Amber connection changed; animation stopped.")
        guard let sample = gateway.telemetry(forArm: arm) else { throw ROBAnimationError.invalid("Arm feedback unavailable.") }
        try require(sample.effectiveSampleAgeMilliseconds <= ROBArmFeedbackTiming.maximumAgeMilliseconds && sample.effectiveGripperFeedbackAgeMilliseconds <= ROBArmFeedbackTiming.maximumAgeMilliseconds, "Arm/gripper feedback expired; animation holds.")
        let q = sample.positionsRadians.map(\.doubleValue)
        try require(q.count == 7 && q.allSatisfy(\.isFinite), "Invalid arm feedback.")
        if requirePosition {
            try require(sample.statuses.count == 7 && sample.statuses.allSatisfy { $0.intValue == 2 } && gateway.modes(forArm: arm).count == 7 && gateway.modes(forArm: arm).allSatisfy { $0.intValue == 2 }, "Arm left position hold; animation stopped.")
        }
        let currents = sample.currents.map(\.doubleValue)
        try require(currents.count == 7 && currents.allSatisfy(\.isFinite), "Current feedback unavailable.")
        if lastSequences[arm] != sample.sequence {
            if let previous = lastCurrents[arm], currentLimit > 0 {
                try require(zip(currents, previous).allSatisfy { abs($0-$1) <= currentLimit }, "Arm current jump exceeded the configured limit; holding.")
            }
            lastCurrents[arm] = currents; lastSequences[arm] = sample.sequence
        }
        return q
    }
    private func tick() {
        guard isRunning, let owner, let sequence, let serial else { return }
        do {
            let time = now
            try require(time-lastTick <= ROBArmFeedbackTiming.maximumAgeMilliseconds/1000, "Animation scheduler stalled; holding instead of skipping frames.")
            lastTick = time
            for (_, sent) in pending { try require(time-sent <= 1.5, "Animation command acknowledgement timed out.") }
            if preparing {
                try require(time < deadline, "Control handoff or position-mode entry timed out.")
                for arm in arms {
                    guard let side = ROBArmSide(amberGatewayArm: arm) else { throw ROBAnimationError.invalid("Unknown physical arm.") }
                    if !reserved.contains(side) {
                        guard ROBAmberArmMotionArbiter.shared.reserve(side, owner: owner) else { return }
                        reserved.append(side)
                    }
                    _ = try measured(arm, requirePosition: false)
                }
                if !modesRequested {
                    for arm in arms where gateway.modes(forArm: arm).count != 7 || !gateway.modes(forArm: arm).allSatisfy({ $0.intValue == 2 }) {
                        let id = gateway.enterPositionMode(forArm: arm); try require(id != 0, "Could not enter arm position mode."); pending[id] = time
                    }
                    modesRequested = true
                }
                guard pending.isEmpty else { return }
                for arm in arms { _ = try measured(arm) }
                preparing = false; try beginNextClip(); return
            }
            for arm in arms {
                try require(ROBArmSide(amberGatewayArm: arm).map { ROBAmberArmMotionArbiter.shared.isReserved($0, owner: owner) } == true, "Animation lost arm ownership.")
                _ = try measured(arm)
                if leasedArms.contains(arm) { try require(gateway.renewLease(forArm: arm, leaseMilliseconds: 1500) != 0, "Could not renew arm hold watchdog.") }
            }
            guard sequence.clips.indices.contains(index) else { stop(reason: "Sequence complete; robot holding."); return }
            let clip = sequence.clips[index]
            let elapsed = time-clipStarted
            if let heading = clip.pose.values["torso.heading"], !torsoStarted {
                torsoStarted = true
                try require(ROBTorsoControlCenter.shared.startAnimationTurn(to: heading), ROBTorsoControlCenter.shared.status)
            }
            if torsoStarted && elapsed >= 2 {
                try require(ROBTorsoControlCenter.shared.isArmed, ROBTorsoControlCenter.shared.status)
            }
            if usesMaestro {
                let values = clip.pose.values.filter { $0.key.hasPrefix("maestro.") }
                if !values.isEmpty {
                    var demand: [String: NSNumber] = [:]
                    // Neck uses its coupled safety staging at the clip target;
                    // generic servos interpolate in command space.
                    for (id,value) in values {
                        let number = ["maestro.0","maestro.1","maestro.2"].contains(id) ? value : (baseline[id] ?? value) + (value-(baseline[id] ?? value))*clip.easing.fraction(elapsed/clip.transition)
                        demand[id] = NSNumber(value: number)
                    }
                    try require(serial.applyAnimationMaestroValues(demand), "Maestro target was rejected or disconnected.")
                }
            }
            if usesLACT { try require(serial.applyAnimationLACTPercent(elapsed < clip.duration ? clip.pose.values["lact.speed"] ?? 0 : 0), "LACT command failed.") }
            if elapsed >= nextStep, nextStep < clip.transition, pending.isEmpty {
                let remaining = clip.transition-nextStep
                // Amber's minimum leased segment is 0.65 s. Use equal segments
                // so the last one is never shorter than the transport permits.
                let count = max(1, Int(floor(clip.transition / 0.8)))
                let seconds = min(remaining, clip.transition / Double(count))
                let end = min(clip.transition, nextStep+seconds)
                approved = [:]; approvedDuration = seconds
                for arm in arms {
                    let physical = arm == "left" ? "right" : "left"
                    guard clip.pose.values.keys.contains(where: { $0.hasPrefix("arm.\(physical).") }) else { continue }
                    let q = (1...7).map { j -> Double in
                        let key = "arm.\(physical).j\(j)", start = baseline[key]!
                        return start + ((target[key] ?? start)-start)*clip.easing.fraction(end/clip.transition)
                    }
                    approved[arm] = q
                }
                for arm in arms where approved[arm] != nil {
                    let id = gateway.sendLocalAnimationStep(arm: arm, expectedSessionGeneration: generation)
                    try require(id != 0, "Animation target/rate/feedback changed before dispatch; increase transition time if needed.")
                    pending[id] = time; leasedArms.insert(arm)
                }
                approved = [:]; nextStep = abs(end-clip.transition) < 0.000001 ? clip.transition : end; stepUntil = time+seconds
            }
            guard elapsed >= clip.duration, time >= stepUntil, pending.isEmpty else { return }
            var settled = true
            for arm in arms {
                let physical = arm == "left" ? "right" : "left", q = try measured(arm)
                for j in 1...7 where clip.pose.values["arm.\(physical).j\(j)"] != nil {
                    if abs(q[j-1] - target["arm.\(physical).j\(j)"]!) > ROBArmRoutinePlan.tolerance { settled = false }
                }
            }
            if clip.pose.values.keys.contains(where: { ["maestro.0","maestro.1","maestro.2"].contains($0) }) {
                if !serial.animationNeckReady { settled = false }
            }
            if let heading = clip.pose.values["torso.heading"] {
                let torso = ROBTorsoControlCenter.shared
                if !torso.animationTargetReached(heading) { settled = false }
                try require(torso.isArmed || time-clipStarted < 2, torso.status)
            }
            if settled {
                let sequences = Dictionary(uniqueKeysWithValues: arms.compactMap { arm in gateway.telemetry(forArm: arm).map { (arm,$0.sequence) } })
                if arms.isEmpty || sequences.allSatisfy({ lastSettledSequences[$0.key] != $0.value }) { settling += 1; lastSettledSequences = sequences }
                if settling >= 3 { try beginNextClip() }
            } else {
                settling = 0
                try require(elapsed < clip.duration + (clip.pose.values["torso.heading"] == nil ? 8 : 60), "Clip did not reach its target; animation stopped without advancing.")
            }
        } catch { stop(reason: error.localizedDescription) }
    }
    private func beginNextClip() throws {
        guard let sequence, let serial else { return }
        index += 1
        guard sequence.clips.indices.contains(index) else { stop(reason: "Sequence complete; robot holding. Servo/LACT tracks are command estimates."); return }
        let clip = sequence.clips[index]
        baseline = serial.animationMaestroSnapshot().mapValues(\.doubleValue)
        for arm in arms {
            let q = try measured(arm), physical = arm == "left" ? "right" : "left"
            for j in 1...7 { baseline["arm.\(physical).j\(j)"] = q[j-1] }
            if clip.pose.values.keys.contains(where: { $0.hasPrefix("arm.\(physical).") }) {
                try require(clip.transition >= ROBArmRoutinePlan.minimumLeasedTrajectorySeconds, "Arm transitions must be at least \(ROBArmRoutinePlan.minimumLeasedTrajectorySeconds) seconds.")
                let peak = clip.easing == .smooth ? 1.5 : 1.0
                for j in 1...7 {
                    let key = "arm.\(physical).j\(j)"
                    if let target = clip.pose.values[key] {
                        let minimum = abs(target-q[j-1])*peak/ROBArmTargetExecutionContext.maximumAverageSpeedRadiansPerSecond
                        try require(clip.transition >= minimum, "\(clip.pose.name): \(physical) J\(j) needs at least \(String(format: "%.2f", minimum)) seconds with this easing. Edit Transition before running.")
                    }
                }
            }
        }
        for key in clip.pose.values.keys where key.hasPrefix("maestro.") {
            try require(baseline[key] != nil, "\(key) has no known active starting target. Set that servo in manual controls before playback.")
        }
        target = baseline.merging(clip.pose.values) { _, new in new }
        clipStarted = now; nextStep = 0; stepUntil = now; torsoStarted = false; settling = 0; lastSettledSequences = [:]
        publish("Running \(sequence.name) · clip \(index+1)/\(sequence.clips.count): \(clip.pose.name). Stop or any local takeover interrupts.")
    }
    /// Consumed synchronously by the authenticated gateway, never externally
    /// supplied JSON. Fresh dispatch still rechecks modes, bounds and rate.
    func approvedStep(arm: String, generation: UInt64) -> (values: [Double], seconds: Double)? {
        guard isRunning, self.generation == generation, let owner,
              let side = ROBArmSide(amberGatewayArm: arm), ROBAmberArmMotionArbiter.shared.isReserved(side, owner: owner),
              let values = approved[arm] else { return nil }
        return (values, approvedDuration)
    }
    func authorizesTorsoHeading(_ heading: Double) -> Bool {
        isRunning && index >= 0 && sequence?.clips.indices.contains(index) == true && sequence?.clips[index].pose.values["torso.heading"] == heading
    }
    @objc func stop(reason: String) {
        precondition(Thread.isMainThread)
        let active = isRunning
        isRunning = false; timer?.invalidate(); timer = nil; approved = [:]; pending = [:]
        if active {
            for arm in arms { _ = gateway.priorityHold(forArm: arm) }
            if usesTorso { ROBTorsoControlCenter.shared.stop() }
            serial?.endAnimationOutputs()
        }
        if let owner { for side in reserved { ROBAmberArmMotionArbiter.shared.release(side, owner: owner) } }
        reserved = []; owner = nil; sequence = nil; serial = nil
        publish(reason)
    }
    @objc private func localTakeover() { if isRunning { stop(reason: "Local manual control took over the animation.") } }
    @objc private func willStop() { if isRunning { stop(reason: "Animation stopped for sleep/termination.") } }
    @objc private func commandCompleted(_ note: Notification) {
        guard isRunning, let info = note.userInfo, let id = (info["commandID"] as? NSNumber)?.uint64Value, pending.removeValue(forKey: id) != nil else { return }
        if info["accepted"] as? Bool != true { stop(reason: "Animation command rejected: \(info["error"] as? String ?? "unknown gateway error")") }
    }
}
