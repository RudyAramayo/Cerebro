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
    private var armTransition = 0.0
    private var clipDuration = 0.0
    private var baseline: [String: Double] = [:]
    private var target: [String: Double] = [:]
    private var nextStep = 0.0
    private var stepUntil = 0.0
    private var segmentProgress: [String: ROBAnimationSegmentProgress] = [:]
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
    private var speechOutput: ((String, @escaping (Bool) -> Void) -> Void)?
    private var cancelSpeech: (() -> Void)?
    private var speechID: UUID?
    private let gateway = ROBAmberGatewayClient.shared

    @objc(configureSpeech:cancel:)
    func configureSpeech(_ speak: @escaping (String, @escaping (Bool) -> Void) -> Void, cancel: @escaping () -> Void) {
        speechOutput = speak; cancelSpeech = cancel
    }

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
            try require(sequence.completionGreeting == nil || speechOutput != nil, "Connect the controller speech output before running the greeting.")
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
            // Current deltas belong to this explicit run. A previous run may
            // have ended before manual recovery or a motor power cycle.
            lastCurrents = [:]; lastSequences = [:]
            currentLimit = UserDefaults.standard.double(forKey: ROBLeftArmTrial.currentLimitKey)
            for arm in arms { _ = try measured(arm, requirePosition: false) }
            // The local click supersedes automatic owners once for the whole
            // sequence; it never creates a reusable model/voice approval.
            ROBControllerArmApproval.shared.takeLocalPanelControl()
            self.sequence = sequence; self.serial = serial; owner = UUID(); isRunning = true
            preparing = true; modesRequested = false; deadline = now + 2; lastTick = now
            index = -1; pending = [:]; leasedArms = []; segmentProgress = [:]
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
            if speechID != nil {
                try require(time < deadline, "Greeting timed out; robot holding.")
                return
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
            // The vendor ACK and requested duration do not establish arrival.
            // Observe each arm independently, but keep paired path fractions
            // synchronized: neither arm advances until both have settled.
            var segmentSettled = true
            for arm in arms where segmentProgress[arm] != nil {
                let q = try measured(arm)
                guard let sample = gateway.telemetry(forArm: arm) else { throw ROBAnimationError.invalid("Arm feedback unavailable at segment handoff.") }
                let result = segmentProgress[arm]!.observe(sequence: sample.sequence, positions: q, time: time)
                if let joint = result.reversedJoint {
                    throw ROBAnimationError.invalid("\(arm == "left" ? "Right" : "Left") J\(joint) reversed outside its animation segment; holding both arms.")
                }
                segmentSettled = segmentSettled && result.settled
            }
            let settlingAllowance = clip.pose.values["torso.heading"] == nil ? 8.0 : 60.0
            if !segmentSettled {
                try require(elapsed < clipDuration + settlingAllowance, "Arm segment did not settle; animation stopped without advancing.")
            }
            // The segment clock advances only after the preceding command's
            // actual duration. ACK receipt is not arrival, and wall-clock
            // lateness must never turn into overlapping catch-up commands.
            if elapsed >= nextStep, time >= stepUntil, segmentSettled, nextStep < armTransition, pending.isEmpty {
                let remaining = armTransition-nextStep
                // Amber's minimum leased segment is 0.65 s. Use equal segments
                // so the last one is never shorter than the transport permits.
                // Straight local targets can use longer native trajectories.
                // Keep authored smooth curves sampled and never merge across
                // clip corners, holds, measured-arrival gates or LACT timing.
                // Eight seconds leaves headroom beneath the 10 s transport
                // bound when fresh measured progress extends a segment.
                let count = clip.easing == .linear
                    ? max(1, Int(ceil(armTransition / 8)))
                    : max(1, Int(floor(armTransition / 0.8)))
                let seconds = min(remaining, armTransition / Double(count))
                let end = min(armTransition, nextStep+seconds)
                approved = [:]; approvedDuration = seconds
                for arm in arms {
                    let physical = arm == "left" ? "right" : "left"
                    guard clip.pose.values.keys.contains(where: { $0.hasPrefix("arm.\(physical).") }) else { continue }
                    let q = (1...7).map { j -> Double in
                        let key = "arm.\(physical).j\(j)", start = baseline[key]!
                        return start + ((target[key] ?? start)-start)*clip.easing.fraction(end/armTransition)
                    }
                    approved[arm] = q
                }
                // Telemetry can legitimately trail the last planned point.
                // Keep the same geometric target and rate ceiling; give both
                // arms the duration required from their current feedback,
                // plus one scheduler interval for dispatch/readback skew.
                for (arm, q) in approved {
                    let current = try measured(arm)
                    let required = zip(q, current).map { abs($0-$1) / ROBArmTargetExecutionContext.maximumAverageSpeedRadiansPerSecond }.max() ?? 0
                    approvedDuration = max(approvedDuration, required + 0.05)
                }
                try require(approved.isEmpty || time + approvedDuration <= clipStarted + clipDuration - clip.hold + settlingAllowance,
                    "\(clip.pose.name): arm progress exhausted the clip's settling allowance; holding without skipping targets.")
                // Validate every included arm before sending the first one.
                // The gateway repeats this at dispatch to cover races.
                for arm in arms where approved[arm] != nil {
                    if let reason = gateway.localAnimationStepRejection(arm: arm, expectedSessionGeneration: generation) {
                        throw ROBAnimationError.invalid(reason)
                    }
                }
                for arm in arms where approved[arm] != nil {
                    let current = try measured(arm)
                    let id = gateway.sendLocalAnimationStep(arm: arm, expectedSessionGeneration: generation)
                    try require(id != 0, gateway.animationStepRejection ?? "Animation gateway changed at dispatch; holding.")
                    pending[id] = time; leasedArms.insert(arm)
                    segmentProgress[arm] = ROBAnimationSegmentProgress(start: current, target: approved[arm]!)
                }
                approved = [:]; nextStep = abs(end-armTransition) < 0.000001 ? armTransition : end; stepUntil = now+approvedDuration
            }
            guard nextStep >= armTransition, elapsed >= clipDuration, time >= stepUntil + clip.hold, segmentSettled, pending.isEmpty else { return }
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
                try require(elapsed < clipDuration + (clip.pose.values["torso.heading"] == nil ? 8 : 60), "Clip did not reach its target; animation stopped without advancing.")
            }
        } catch { stop(reason: error.localizedDescription) }
    }
    private func beginNextClip() throws {
        guard let sequence, let serial else { return }
        index += 1
        guard sequence.clips.indices.contains(index) else { finishMotion(sequence); return }
        let clip = sequence.clips[index]
        let requestedArmTransition = sequence.armTransition(for: clip)
        armTransition = requestedArmTransition
        baseline = serial.animationMaestroSnapshot().mapValues(\.doubleValue)
        for arm in arms {
            let q = try measured(arm), physical = arm == "left" ? "right" : "left"
            for j in 1...7 { baseline["arm.\(physical).j\(j)"] = q[j-1] }
            if clip.pose.values.keys.contains(where: { $0.hasPrefix("arm.\(physical).") }) {
                armTransition = max(armTransition, ROBArmRoutinePlan.minimumLeasedTrajectorySeconds)
                let peak = clip.easing == .smooth ? 1.5 : 1.0
                for j in 1...7 {
                    let key = "arm.\(physical).j\(j)"
                    if let target = clip.pose.values[key] {
                        let minimum = abs(target-q[j-1])*peak/ROBArmTargetExecutionContext.maximumAverageSpeedRadiansPerSecond
                        armTransition = max(armTransition, minimum)
                    }
                }
            }
        }
        for key in clip.pose.values.keys where key.hasPrefix("maestro.") {
            try require(baseline[key] != nil, "\(key) has no known active starting target. Set that servo in manual controls before playback.")
        }
        target = baseline.merging(clip.pose.values) { _, new in new }
        clipDuration = max(armTransition, clip.hasOtherTimedTargets ? clip.transition : 0) + clip.hold
        clipStarted = now; nextStep = 0; stepUntil = now; segmentProgress = [:]; torsoStarted = false; settling = 0; lastSettledSequences = [:]
        let speed = clip.hasArmTargets ? String(format: " Arms %.0f%%%@.", sequence.armSpeed*100,
            armTransition > requestedArmTransition + 0.000001 ? " · motor-limited to \(String(format: "%.2f", armTransition)) s" : "") : ""
        publish("Running \(sequence.name) · clip \(index+1)/\(sequence.clips.count): \(clip.pose.name).\(speed) Stop or any local takeover interrupts.")
    }
    private func finishMotion(_ sequence: ROBAnimationSequence) {
        guard let greeting = sequence.completionGreeting, let speechOutput else {
            stop(reason: "Sequence complete; robot holding. Servo/LACT tracks are command estimates."); return
        }
        // Every clip has settled. End the timed outputs before speaking, and
        // keep arm ownership/feedback/hold leases until speech finishes.
        serial?.endAnimationOutputs()
        let id = UUID(), speechOwner = owner
        speechID = id; deadline = now + 30
        let text = greeting.text()
        publish("Motion complete · speaking \(text)")
        speechOutput(text) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.isRunning, self.owner == speechOwner, self.speechID == id else { return }
                self.speechID = nil
                self.stop(reason: finished ? "Sequence and greeting complete; robot holding." : "Greeting interrupted; robot holding.")
            }
        }
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
        let speaking = speechID != nil; speechID = nil
        isRunning = false; timer?.invalidate(); timer = nil; approved = [:]; pending = [:]; segmentProgress = [:]
        if speaking { cancelSpeech?() }
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

/// Feedback-only segment evidence. The hardware has no usable velocity field;
/// derive stability from distinct position samples, never from an ACK. This
/// is not a collision model or proof that interrupted vendor trajectories work.
struct ROBAnimationSegmentProgress {
    let start: [Double]
    let target: [Double]
    private var previous: [Double]?
    private var sequence: UInt64 = 0
    private var stableSince: Double?
    private var stableSamples = 0
    private var furthest: [Double]
    private var settled = false

    init(start: [Double], target: [Double]) {
        self.start = start; self.target = target; self.furthest = start
    }

    mutating func observe(sequence: UInt64, positions: [Double], time: Double) -> (settled: Bool, reversedJoint: Int?) {
        guard sequence > self.sequence else { return (settled, nil) }
        self.sequence = sequence
        guard positions.count == 7, positions.allSatisfy(\.isFinite) else { return (false, nil) }
        // A 0.05 rad retreat from measured progress is a motion fault, not a
        // tiny travel checkpoint. It catches the recorded J6 reversal near
        // +0.34 rad instead of waiting until it passes the whole-run start.
        for j in 0..<7 {
            let direction = target[j] >= start[j] ? 1.0 : -1.0
            let progress = direction * (positions[j] - start[j])
            let peak = direction * (furthest[j] - start[j])
            if progress < peak - 0.05 || direction * (positions[j] - target[j]) > 0.05 {
                return (false, j+1)
            }
            if progress > peak { furthest[j] = positions[j] }
        }
        defer { previous = positions }
        let near = zip(positions, target).allSatisfy { abs($0-$1) <= ROBArmRoutinePlan.tolerance }
        let stable = previous.map { zip(positions, $0).allSatisfy { abs($0-$1) <= 0.004 } } ?? false
        guard near && stable else { stableSince = nil; stableSamples = 0; settled = false; return (false, nil) }
        if stableSince == nil { stableSince = time }
        stableSamples += 1
        settled = stableSamples >= 3 && time - (stableSince ?? time) >= 0.15
        return (settled, nil)
    }
}
