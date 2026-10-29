import Cocoa

@objcMembers final class ROBTorsoControlCenter: NSObject {
    static let shared = ROBTorsoControlCenter()
    static let changed = Notification.Name("ROBTorsoControlDidChange")
    static let cameraDemandChanged = Notification.Name("ROBTorsoVisionDemandDidChange")
    static let speedLimitKey = "ROBTorsoMaximumPulseRate"

    private(set) var cameraDemandActive = false
    private(set) var usesLiveCamera = false
    private(set) var usesCountEstimate = false
    var usesHardware: Bool { usesLiveCamera || usesCountEstimate }
    @nonobjc private var calibration = ROBTorsoCountCalibration()
    @nonobjc private var ticPosition: ROBTicVelocityTransport.PositionSample?
    private var countSequence: UInt64 = 0
    private var lastPositionRead = 0.0
    private var referenceRevision = 0
    private(set) var hasSoftwareBaseReference = false
    /// Software alignment is explicitly operator observed, then propagated by
    /// counts. It is never relabelled as camera-measured or a tread encoder.
    var navigationHeading: Double {
        guard hasFreshFeedback, usesLiveCamera || (usesCountEstimate && hasSoftwareBaseReference) else { return .nan }
        return observedHeading
    }
    var debugCableMode: Bool { policy.debugCableMode }
    var cableTravelDegrees: Double { policy.cableTravelDegrees ?? .nan }
    var canUnwind: Bool { isArmed && debugCableMode && policy.cableReferenceHeading != nil }
    var countReference: Double { calibration.centerCount }
    var currentCount: Double { ticPosition.map { Double($0.count) } ?? .nan }
    var countEstimateDetail: String {
        let reference = String(format: "Software front %.0f counts", calibration.centerCount)
        return reference + " • count estimate, not measured torso alignment"
    }
    @nonobjc func heading(forCount count: Double) -> Double { calibration.heading(count: count) }
    @nonobjc func count(forHeading heading: Double) -> Double { calibration.count(heading: heading) }

    private(set) var hardwareReady = false
    private(set) var powerHoldRequested = false
    private var powerRequestPending = false
    private var lastCommandFailure: String?
    private(set) var hardwareDetail = "Rehearsal — no motor output"
    private(set) var visionDetail = "Simulated observation"
    @nonobjc private(set) var policy = ROBTorsoMotionPolicy()
    @nonobjc private let transport: ROBTicVelocityTransport
    @nonobjc let vision: ROBMarkerlessVisionService
    private var timer: Timer?
    private var windowController: ROBTorsoControlWindowController?
    private var simulatedHeading = 0.0
    private var simulatedSequence: UInt64 = 0
    private var remoteBaseline: Double?
    private var remoteUntil = 0.0
    private var motionUntil = 0.0
    private var lastTick = 0.0
    private var lastSent = 0.0
    private var lastUIPublish = 0.0
    private var uiPublishPending = false
    private var localLeverHeld = false
    private enum LocalDemand { case rate(Double), heading(Double) }
    @nonobjc private var pendingLocalDemand: LocalDemand?
    private var localDemandDeadline = 0.0
    private var localControlOwnsTorso = false
    private var nativePositionTarget: Int32?
    private var arming = false
    private let modelID: String?
    private let referenceID: String?
    @nonobjc private let armClearance: () -> String?

    override convenience init() { self.init(transport: ROBTicVelocityTransport(), vision: ROBMarkerlessVisionService(workerName: "torso_markerless.py")) }

    @nonobjc init(transport: ROBTicVelocityTransport, vision: ROBMarkerlessVisionService,
                 reference: [String: Any]? = nil,
                 armClearance: @escaping () -> String? = { ROBArmRoutineCoordinator.shared.torsoRotationBlockReason }) {
        self.transport = transport; self.vision = vision
        self.armClearance = armClearance
        let path = Bundle.main.url(forResource: "reference", withExtension: "json", subdirectory: "ShadowPlanner")
        let manifest = reference ?? path.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        modelID = manifest?["modelID"] as? String; referenceID = manifest?["referenceID"] as? String
        super.init()
        let savedSpeed = UserDefaults.standard.double(forKey: Self.speedLimitKey) * 360 / ROBTorsoCountCalibration.countsPerTurn
        if savedSpeed.isFinite, ROBTorsoMotionPolicy.speedRange.contains(savedSpeed) {
            policy.maximumSpeed = savedSpeed
        }
        policy.debugCableMode = UserDefaults.standard.bool(forKey: "ROBDevelopmentMode")
        transport.onPosition = { [weak self] sample in self?.acceptCount(sample) }
        transport.onMotionDispatch = { ROBFixedHeadBodyMotionIdentity.invalidate() }
        transport.onState = { [weak self] ready, detail in
            guard let self else { return }
            let unexpectedLoss = !ready && (self.hardwareReady || self.arming || self.powerRequestPending)
            self.hardwareReady = ready
            self.hardwareDetail = self.usesHardware ? detail : "Rehearsal — no motor output"
            if ready { self.powerRequestPending = false }
            if ready && self.arming {
                self.arming = false
                if let reason = self.armClearance() {
                    self.stop(); self.policy.invalidate(reason)
                } else if !self.usesHardware || !self.policy.arm(at: ProcessInfo.processInfo.systemUptime) { self.stop() }
                else { self.advanceLocalDemand() }
            } else if self.usesHardware && unexpectedLoss {
                self.arming = false; self.powerRequestPending = false; self.powerHoldRequested = false
                self.pendingLocalDemand = nil; self.localLeverHeld = false
                self.lastCommandFailure = detail
                self.policy.invalidate(detail)
            }
            self.publish()
        }
        vision.onObservation = { [weak self] object in self?.acceptObservation(object) }
        vision.onFailure = { [weak self] in
            guard let self, self.usesLiveCamera else { return }
            self.visionDetail = "Torso estimator unavailable; restart camera reference"
            self.policy.loseObservation(self.visionDetail); self.stopHardware(); self.publish()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationInactive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationTerminating),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    var observedHeading: Double {
        policy.hasFreshObservation(at: ProcessInfo.processInfo.systemUptime) ? policy.observation?.heading ?? .nan : .nan
    }
    var targetHeading: Double { policy.targetHeading.map(ROBTorsoMotionPolicy.wrap) ?? .nan }
    var commandedVelocity: Double { policy.velocity }
    var isArmed: Bool { policy.armed }
    var status: String {
        let operation = lastCommandFailure.map { "Last command failed: " + $0 } ?? (powerRequestPending ? "Checking TIC and energizing a zero-speed hold…"
            : arming ? "Checking Tic settings and preparing the motor…"
            : pendingLocalDemand != nil ? "Taking manual control…" : policy.status)
        if usesHardware, let reason = armClearance() { return operation + "\n" + reason }
        return operation
    }
    var maximumSpeed: Double { policy.maximumSpeed }
    var maximumPulseRate: Double { policy.maximumSpeed * ROBTorsoCountCalibration.countsPerTurn / 360 }
    private var hasFreshTicFeedback: Bool {
        ticPosition.map { (0...0.5).contains(ProcessInfo.processInfo.systemUptime-$0.capturedAt) } == true
    }
    var motorPowerDetail: String {
        guard usesHardware else { return "Rehearsal — no motor output" }
        guard let sample = ticPosition, hasFreshTicFeedback else { return "Motor power and count: awaiting fresh TIC feedback" }
        return String(format: "Motor %@ • current count %d • controller speed %+.2f°/s • %@",
            sample.energized ? "ENERGIZED" : "DE-ENERGIZED", sample.count,
            -Double(sample.velocity)/10_000*360/ROBTorsoCountCalibration.countsPerTurn, sample.operationState)
    }
    var canEnergize: Bool {
        usesHardware && !arming && !powerRequestPending && !powerHoldRequested && !isArmed &&
            hasFreshTicFeedback && ticPosition?.velocity == 0 && !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion
    }
    var canSetSoftwareReference: Bool {
        usesCountEstimate && hasFreshTicFeedback && ticPosition?.velocity == 0 && !arming && !powerRequestPending
    }
    var compactControlDetail: String {
        let motion = String(format: "Requested %+.2f°/s", commandedVelocity)
        return motorPowerDetail + " • " + motion + "\n" + (usesHardware
            ? (hasFreshTicFeedback ? status : hardwareDetail)
            : "Rehearsal selected — choose TIC count estimate in Torso Rotation for hardware control.")
    }
    private var hasFreshFeedback: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return policy.hasFreshObservation(at: now) && (!usesCountEstimate || hasFreshTicFeedback)
    }
    var canArm: Bool { !arming && !powerRequestPending && hasFreshFeedback && (!usesHardware || armClearance() == nil) }
    var isLocalLeverHeld: Bool { localLeverHeld }
    var canUseLocalControls: Bool {
        localLeverHeld || pendingLocalDemand != nil || isArmed || canArm
            || (hasFreshFeedback && ROBArmRoutineCoordinator.shared.ownsPhysicalMotion)
    }

    func showControls(_ sender: Any?) {
        precondition(Thread.isMainThread)
        if usesLiveCamera && !cameraDemandActive { setLiveCamera(true) }
        startTimer()
        if windowController == nil { windowController = ROBTorsoControlWindowController(center: self) }
        windowController?.showWindow(sender)
        windowController?.window?.makeKeyAndOrderFront(sender)
    }

    func setLiveCamera(_ live: Bool) {
        precondition(Thread.isMainThread)
        stop(); vision.stop(); usesLiveCamera = live; usesCountEstimate = false; ticPosition = nil
        lastPositionRead = 0
        hasSoftwareBaseReference = false
        let speed = policy.maximumSpeed
        policy = ROBTorsoMotionPolicy(); policy.maximumSpeed = speed
        policy.debugCableMode = UserDefaults.standard.bool(forKey: "ROBDevelopmentMode")
        remoteBaseline = nil
        cameraDemandActive = live
        hardwareDetail = live ? "Disarmed — camera confirmation required" : "Rehearsal — no motor output"
        visionDetail = live ? "Acquiring torso and base surfaces from RGB-D cameras" : "Simulated observation"
        NotificationCenter.default.post(name: Self.cameraDemandChanged, object: self)
        if live && vision.start() == nil { visionDetail = "Torso vision runtime unavailable; run the shadow-planner setup" }
        startTimer(); publish()
    }

    func reobserve() {
        if usesCountEstimate { startTimer(); transport.readPosition() }
        else if usesLiveCamera { setLiveCamera(true) }
        else { stop(); policy.resetObservation(); startTimer() }
    }

    /// Native, supervised count control. No hardware index/homing or encoder
    /// is assumed. This source can never satisfy usesLiveCamera in navigation.
    func setCountEstimate() {
        setLiveCamera(false)
        usesCountEstimate = true
        hardwareDetail = "Disarmed — software count control"
        visionDetail = countEstimateDetail
        // Begin a new tracked segment, never claim existing cable twist is zero.
        let speed = policy.maximumSpeed
        policy = ROBTorsoMotionPolicy(); policy.maximumSpeed = speed
        policy.debugCableMode = UserDefaults.standard.bool(forKey: "ROBDevelopmentMode")
        transport.readPosition(); startTimer(); publish()
    }

    /// Operator observation of the physical torso against the tread base.
    /// Only the host offset changes; no Tic reset, homing, or motion is issued.
    func setSoftwareReference(_ observedDegrees: Double) {
        guard observedDegrees.isFinite, (-180...180).contains(observedDegrees) else {
            stop()
            policy.invalidate("Enter a finite observed angle between −180° and 180°"); publish(); return
        }
        guard canSetSoftwareReference, let sample = ticPosition else {
            stop()
            policy.invalidate("Software reference needs fresh TIC feedback at zero speed"); publish(); return
        }
        stop()
        calibration.align(count: Double(sample.count), observedHeading: observedDegrees)
        hasSoftwareBaseReference = true
        referenceRevision += 1
        let speed = policy.maximumSpeed
        policy = ROBTorsoMotionPolicy(); policy.maximumSpeed = speed
        policy.debugCableMode = UserDefaults.standard.bool(forKey: "ROBDevelopmentMode")
        visionDetail = countEstimateDetail + " • operator supplied base reference"
        publish()
    }

    func unwindDebugTurn() {
        guard remoteBaseline == nil, policy.requestUnwind() else { return }
        localLeverHeld = false; motionUntil = ProcessInfo.processInfo.systemUptime + 600
        configureNativePositionTarget()
        publish()
    }

    @nonobjc private func acceptCount(_ sample: ROBTicVelocityTransport.PositionSample) {
        guard usesHardware else { return }
        guard usesCountEstimate else { ticPosition = sample; publish(); return }
        if let previous = ticPosition {
            let gap = sample.capturedAt-previous.capturedAt
            let delta = abs(Double(sample.count)-Double(previous.count))*360/ROBTorsoCountCalibration.countsPerTurn
            if gap > 0.75 || delta > max(8, maximumSpeed*max(0,gap)+4) {
                let preflight = arming || powerRequestPending
                if !preflight && (policy.armed || powerHoldRequested) {
                    lastCommandFailure = String(format: "TIC feedback interrupted (%.0f ms gap, %.2f° count change); stopped", gap*1000, delta)
                }
                hasSoftwareBaseReference = false
                // Preflight owns the USB queue and issues only zero-speed
                // setup. Rebase from its actual status without cancelling the
                // setup because an idle poll waited behind it. No saved base
                // alignment survives that gap, and no turn is dispatched here.
                if !preflight { stop() }
                policy.resetObservation()
            }
        }
        ticPosition = sample; countSequence &+= 1
        let now = ProcessInfo.processInfo.systemUptime
        let wasArmed = policy.armed
        _ = policy.observe(.init(heading: calibration.heading(count: Double(sample.count)),
            capturedAt: sample.capturedAt, uncertainty: 0.05,
            stream: "tic-count-estimate-\(referenceRevision)", sequence: countSequence), now: now)
        visionDetail = String(format: "TIC %d • %@\n%@", sample.count,
            sample.uncertain ? "index/reference unconfirmed" : "controller reference set", countEstimateDetail)
        if (wasArmed && !policy.armed) || (!policy.armed && hardwareReady && !powerHoldRequested) { stopHardware() }
        publish()
    }

    /// Explicit power control can verify the stationary stepper with hanging
    /// arms. It cannot arm rotation or turn a saved target into motion.
    func energize() {
        precondition(Thread.isMainThread)
        guard canEnergize else {
            stop()
            if !usesHardware { policy.invalidate("Choose TIC count estimate or Live camera before energizing") }
            else { policy.invalidate("Energize requires fresh TIC feedback at zero speed and no active motion") }
            publish(); return
        }
        localLeverHeld = false; remoteBaseline = nil; remoteUntil = 0; motionUntil = 0
        lastCommandFailure = nil
        policy.invalidate("Motor hold requested — rotation remains disarmed")
        powerHoldRequested = true; powerRequestPending = true
        transport.energize(profile: .init(maximumDegreesPerSecond: policy.maximumSpeed,
            accelerationDegreesPerSecondSquared: policy.acceleration))
        startTimer(); publish()
    }

    func deenergize() { stop() }

    func arm() {
        precondition(Thread.isMainThread)
        guard !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion else {
            stop(); policy.invalidate("Arm routine owns body clearance"); publish(); return
        }
        if usesHardware, let reason = armClearance() {
            stop(); policy.invalidate(reason); publish(); return
        }
        startTimer()
        let now = ProcessInfo.processInfo.systemUptime
        guard !arming, hasFreshFeedback else {
            policy.invalidate("Waiting for fresh torso feedback from the selected source"); publish(); return
        }
        if usesHardware {
            lastCommandFailure = nil
            arming = true; hardwareReady = false
            transport.arm(profile: .init(maximumDegreesPerSecond: policy.maximumSpeed,
                                        accelerationDegreesPerSecondSquared: policy.acceleration),
                          energizedHold: powerHoldRequested)
        } else { _ = policy.arm(at: now) }
        publish()
    }

    func stop() {
        precondition(Thread.isMainThread)
        nativePositionTarget = nil
        pendingLocalDemand = nil; localDemandDeadline = 0; localControlOwnsTorso = false
        localLeverHeld = false; remoteBaseline = nil; remoteUntil = 0; motionUntil = 0
        policy.invalidate(usesHardware ? "Stopped — hold the slider or choose a destination to move" : "Rehearsal stopped")
        stopHardware(retry: true); publish()
    }

    private func stopHardware(retry: Bool = false) {
        if hardwareReady || arming || powerRequestPending || powerHoldRequested || (retry && usesHardware) { transport.stop() }
        hardwareReady = false; arming = false; powerRequestPending = false; powerHoldRequested = false
    }

    func releaseLever() {
        if case .rate = pendingLocalDemand {
            // A released drag never becomes a delayed move after USB setup.
            stop(); return
        }
        nativePositionTarget = nil
        localLeverHeld = false
        if remoteBaseline == nil { policy.hold() }
        publish()
    }

    func setLever(_ value: Double, held: Bool) {
        precondition(Thread.isMainThread)
        startTimer()
        guard held else { releaseLever(); return }
        guard value.isFinite else { stop(); return }
        let rate = min(1, max(-1, value))
        if !localLeverHeld {
            beginLocalDemand(.rate(rate)); return
        }
        if pendingLocalDemand != nil { pendingLocalDemand = .rate(rate) }
        else if policy.armed { policy.requestRate(rate) }
    }

    /// Native destination button: the click authorizes this bounded turn.
    func takeLocalControlAndTurn(to heading: Double) {
        guard heading.isFinite else { stop(); return }
        beginLocalDemand(.heading(heading))
    }

    @nonobjc private func beginLocalDemand(_ demand: LocalDemand) {
        precondition(Thread.isMainThread)
        // Cancel the previous target before handing off other motion owners.
        // The main controller may synchronously call stop() during this event.
        stop()
        NotificationCenter.default.post(name: Notification.Name("ROBLocalManualControlRequested"), object: self)
        pendingLocalDemand = demand
        localControlOwnsTorso = true
        if case .rate = demand { localLeverHeld = true }
        localDemandDeadline = ProcessInfo.processInfo.systemUptime + 2
        startTimer(); advanceLocalDemand(); publish()
    }

    private func advanceLocalDemand() {
        guard let demand = pendingLocalDemand else { return }
        guard ProcessInfo.processInfo.systemUptime < localDemandDeadline else {
            stop(); policy.invalidate("Manual takeover timed out; try the control again"); return
        }
        if arming { return }
        guard hasFreshFeedback else {
            stop(); policy.invalidate("Waiting for fresh torso feedback from the selected source"); return
        }
        // Cancellation can finish asynchronously. Wait only for that handoff;
        // never loosen telemetry ages or replay a released slider request.
        if ROBArmRoutineCoordinator.shared.ownsPhysicalMotion { return }
        if !policy.armed {
            arm()
            guard policy.armed else {
                if !arming { pendingLocalDemand = nil; localLeverHeld = false }
                return
            }
        }
        pendingLocalDemand = nil
        motionUntil = ProcessInfo.processInfo.systemUptime + 60
        switch demand {
        case .rate(let rate):
            guard localLeverHeld else { stop(); return }
            policy.requestRate(rate)
        case .heading(let heading):
            turnToHeading(heading)
        }
    }

    func turnToHeading(_ heading: Double) {
        precondition(Thread.isMainThread)
        guard remoteBaseline == nil, policy.armed else { return }
        localLeverHeld = false
        policy.requestHeading(heading); motionUntil = ProcessInfo.processInfo.systemUptime + 60
        configureNativePositionTarget()
    }

    private func configureNativePositionTarget() {
        nativePositionTarget = nil
        guard usesCountEstimate, let target = policy.targetHeading else { return }
        let count = calibration.count(heading: target).rounded()
        guard count.isFinite, (Double(Int32.min)...Double(Int32.max)).contains(count) else {
            stop(); policy.invalidate("Target count is outside the TIC position range"); return
        }
        nativePositionTarget = Int32(count)
    }

    func setMaximumSpeed(_ speed: Double) {
        guard speed.isFinite, ROBTorsoMotionPolicy.speedRange.contains(speed) else { return }
        // A profile change requires another explicit arm; the Tic limits and
        // host profile cannot silently disagree during a turn.
        stop(); policy.maximumSpeed = speed
        UserDefaults.standard.set(maximumPulseRate, forKey: Self.speedLimitKey)
        publish()
    }

    func setMaximumPulseRate(_ pulses: Double) {
        guard pulses.isFinite, (100...ROBTorsoMotionPolicy.maximumPulseRate).contains(pulses) else { return }
        setMaximumSpeed(pulses * 360 / ROBTorsoCountCalibration.countsPerTurn)
    }

    /// Existing normalized VR head demand becomes a circular heading offset
    /// from a fresh camera reference, never from the debug slider or Tic count.
    func setRemoteActive(_ active: Bool, rotation: Double) {
        precondition(Thread.isMainThread)
        guard active, rotation.isFinite else {
            if remoteBaseline != nil { remoteBaseline = nil; remoteUntil = 0; policy.hold() }
            return
        }
        guard usesLiveCamera, hardwareReady, policy.armed,
              policy.hasFreshObservation(at: ProcessInfo.processInfo.systemUptime), !localControlOwnsTorso else { return }
        if remoteBaseline == nil { remoteBaseline = policy.unwrappedHeading }
        guard let remoteBaseline else { return }
        remoteUntil = ProcessInfo.processInfo.systemUptime + 0.6
        motionUntil = remoteUntil
        policy.requestHeading(remoteBaseline + min(1, max(-1, rotation)) * 180)
    }

    @objc private func applicationInactive() {
        // A clicked finite destination owns the whole bounded turn. Returning
        // to chat must not silently cancel it. Held manual input still loses
        // ownership on focus loss; remote demand keeps its separate lease.
        guard remoteBaseline == nil else { return }
        if case .heading = pendingLocalDemand { return }
        let finiteTurn = policy.armed && policy.mode == .heading && !localLeverHeld
            && ProcessInfo.processInfo.systemUptime < motionUntil
        if !finiteTurn { stop() }
    }

    @objc private func applicationTerminating() {
        stop()
        if !transport.stopAndWait() {
            NSLog("Torso shutdown: motor power-off could not be confirmed before termination")
        }
    }

    func closeControls() {
        stop(); vision.stop(); cameraDemandActive = false
        timer?.invalidate(); timer = nil
        NotificationCenter.default.post(name: Self.cameraDemandChanged, object: self)
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.advance() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @nonobjc func advance(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Use the operator's shared DEBUG 500 ms budget for the UI control
        // loop too. Original sample ages, TIC freshness and its independent
        // hardware watchdog remain unchanged.
        policy.maximumControlInterval = ROBArmFeedbackTiming.maximumAgeMilliseconds / 1000
        if usesHardware && (policy.armed || arming), let reason = armClearance() {
            stop(); policy.invalidate(reason); publish(); return
        }
        let debug = UserDefaults.standard.bool(forKey: "ROBDevelopmentMode")
        if policy.debugCableMode != debug {
            policy.hold(); policy.debugCableMode = debug
        }
        if usesHardware {
            // Active velocity writes already return full status in the same
            // transaction. Poll separately only when idle or preparing control.
            let needsIdlePoll = !hardwareReady || (policy.mode == .hold && !powerHoldRequested)
            if needsIdlePoll && now-lastPositionRead >= 0.15 { lastPositionRead = now; transport.readPosition() }
            if usesCountEstimate && !arming && !powerRequestPending && (policy.armed || powerHoldRequested), ticPosition.map({ now-$0.capturedAt > 0.5 }) != false {
                let detail = String(format: "TIC feedback expired during control (%.0f ms old); stopped", (now-(ticPosition?.capturedAt ?? now))*1000)
                ROBTicVelocityTransport.trace(detail)
                stop(); lastCommandFailure = detail; policy.invalidate(detail); publish(); return
            }
        }
        let dt = min(0.1, max(0, now - lastTick)); lastTick = now
        if !usesHardware {
            simulatedHeading += policy.velocity * dt
            simulatedSequence &+= 1
            _ = policy.observe(.init(heading: simulatedHeading, capturedAt: now, uncertainty: 0.1,
                                     stream: "explicit-rehearsal", sequence: simulatedSequence), now: now)
        }
        advanceLocalDemand()
        if remoteBaseline != nil && now > remoteUntil { remoteBaseline = nil; policy.hold() }
        if policy.armed && policy.mode != .hold && now > motionUntil { policy.hold() }
        let wasArmed = policy.armed
        if !policy.armed || policy.mode != .heading { nativePositionTarget = nil }
        let directTarget = nativePositionTarget
        let measuredVelocity = directTarget.flatMap { _ in ticPosition.map {
            -Double($0.velocity) / 10_000 * 360 / ROBTorsoCountCalibration.countsPerTurn
        } }
        let arrived = directTarget.map { target in ticPosition?.count == target && ticPosition?.velocity == 0 } ?? false
        let velocity = policy.tick(at: now, measuredPositionVelocity: measuredVelocity, positionReached: arrived)
        if usesHardware {
            if wasArmed && !policy.armed { stopHardware() }
            else if hardwareReady && !policy.armed && !powerHoldRequested { stopHardware() }
            else if hardwareReady && now - lastSent >= 0.09 {
                lastSent = now
                // Only settled hold requests release power; a brief zero at
                // direction reversal retains drive until the turn finishes.
                let feedbackDeadline = powerHoldRequested && !policy.armed
                    ? (ticPosition?.capturedAt ?? 0) + 0.5
                    : (policy.observation?.capturedAt ?? 0) + policy.maximumObservationAge
                if let directTarget, policy.mode == .heading, policy.armed {
                    transport.position(directTarget, validUntil: min(now + policy.maximumControlInterval,
                        (ticPosition?.capturedAt ?? 0) + 0.5, motionUntil))
                } else {
                    nativePositionTarget = nil
                    transport.velocity(velocity, validUntil: min(now + 0.2, feedbackDeadline),
                        releaseWhenStopped: policy.mode == .hold && !powerHoldRequested)
                }
            }
        }
        publish()
    }

    @nonobjc func acceptObservation(_ object: [String: Any]) {
        guard usesLiveCamera else { return }
        let age = (Date().timeIntervalSince1970 * 1000 - (object["capturedAtMilliseconds"] as? Double ?? .nan)) / 1000
        guard object["schemaVersion"] as? Int == 1, object["source"] as? String == "markerless_rgbd",
              object["frame"] as? String == "base_link", let modelID, let referenceID,
              object["modelID"] as? String == modelID, object["referenceID"] as? String == referenceID,
              object["status"] as? String == "confirmed", age.isFinite, (0 ... 0.75).contains(age),
              let torso = object["torso"] as? [String: Any], torso["status"] as? String == "confirmed",
              let yaw = torso["yawRadians"] as? Double, let sigma = torso["standardDeviationRadians"] as? Double,
              let residual = torso["residualMeters"] as? Double, residual.isFinite, (0 ... 0.012).contains(residual),
              let stream = object["streamID"] as? String, let camera = object["camera"] as? String,
              ["face", "belly"].contains(camera), let sequence = object["sequence"] as? UInt64 else {
            // An unobserved alternate camera cannot invalidate a fresh accepted
            // camera. The accepted stream still expires on its original clock.
            let incoming = (object["camera"] as? String).flatMap { camera in
                (object["streamID"] as? String).map { camera + ":" + $0 }
            }
            if incoming == nil || incoming == policy.observation?.stream
                || !policy.hasFreshObservation(at: ProcessInfo.processInfo.systemUptime) {
                visionDetail = object["detail"] as? String ?? "Torso observation failed validation"
                policy.loseObservation(visionDetail); stopHardware()
            }
            publish(); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Keep one valid camera source while fresh to avoid toggling coordinate
        // registrations at every face/belly frame. On loss, a new source rebases.
        let key = camera + ":" + stream
        if let prior = policy.observation, prior.stream != key, policy.hasFreshObservation(at: now) { return }
        let wasArmed = policy.armed
        _ = policy.observe(.init(heading: yaw * 180 / .pi, capturedAt: now - age,
                                 uncertainty: sigma * 180 / .pi, stream: key, sequence: sequence), now: now)
        visionDetail = String(format: "%@ camera • yaw uncertainty ±%.1f°", camera, sigma * 180 / .pi)
        if (wasArmed && !policy.armed) || (!policy.armed && hardwareReady && !powerHoldRequested) { stopHardware() }
        publish()
    }

    private func publish() {
        // Status and power callbacks can arrive together. Keep motor control at
        // 20 Hz, but coalesce AppKit layout work to at most 10 Hz.
        let now = ProcessInfo.processInfo.systemUptime
        let delay = 0.1-(now-lastUIPublish)
        if delay > 0 {
            if !uiPublishPending {
                uiPublishPending = true
                DispatchQueue.main.asyncAfter(deadline: .now()+delay) { [weak self] in
                    self?.uiPublishPending = false; self?.publish()
                }
            }
            return
        }
        lastUIPublish = now
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
