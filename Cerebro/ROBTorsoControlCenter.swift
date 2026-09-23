import Cocoa

@objcMembers final class ROBTorsoControlCenter: NSObject {
    static let shared = ROBTorsoControlCenter()
    static let changed = Notification.Name("ROBTorsoControlDidChange")
    static let cameraDemandChanged = Notification.Name("ROBTorsoVisionDemandDidChange")

    private(set) var cameraDemandActive = false
    private(set) var usesLiveCamera = false
    private(set) var hardwareReady = false
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
    private var localLeverHeld = false
    private var arming = false
    private let modelID: String?
    private let referenceID: String?

    override convenience init() { self.init(transport: ROBTicVelocityTransport(), vision: ROBMarkerlessVisionService(workerName: "torso_markerless.py")) }

    @nonobjc init(transport: ROBTicVelocityTransport, vision: ROBMarkerlessVisionService,
                 reference: [String: Any]? = nil) {
        self.transport = transport; self.vision = vision
        let path = Bundle.main.url(forResource: "reference", withExtension: "json", subdirectory: "ShadowPlanner")
        let manifest = reference ?? path.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        modelID = manifest?["modelID"] as? String; referenceID = manifest?["referenceID"] as? String
        super.init()
        transport.onState = { [weak self] ready, detail in
            guard let self else { return }
            let unexpectedLoss = !ready && (self.hardwareReady || self.arming)
            self.hardwareReady = ready
            self.hardwareDetail = self.usesLiveCamera ? detail : "Rehearsal — no motor output"
            if ready {
                self.arming = false
                if !self.usesLiveCamera || !self.policy.arm(at: ProcessInfo.processInfo.systemUptime) { self.stop() }
            } else if self.usesLiveCamera && unexpectedLoss {
                self.arming = false; self.policy.invalidate(detail)
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
    var status: String { arming ? "Checking Tic settings and holding a zero-speed target…" : policy.status }
    var maximumSpeed: Double { policy.maximumSpeed }
    var canArm: Bool { !arming && policy.hasFreshObservation(at: ProcessInfo.processInfo.systemUptime) }

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
        stop(); vision.stop(); usesLiveCamera = live
        policy.resetObservation(); remoteBaseline = nil
        cameraDemandActive = live
        hardwareDetail = live ? "Disarmed — camera confirmation required" : "Rehearsal — no motor output"
        visionDetail = live ? "Acquiring torso and base surfaces from RGB-D cameras" : "Simulated observation"
        NotificationCenter.default.post(name: Self.cameraDemandChanged, object: self)
        if live && vision.start() == nil { visionDetail = "Torso vision runtime unavailable; run the shadow-planner setup" }
        startTimer(); publish()
    }

    func reobserve() {
        if usesLiveCamera { setLiveCamera(true) }
        else { stop(); policy.resetObservation(); startTimer() }
    }

    func arm() {
        precondition(Thread.isMainThread)
        guard !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion else {
            stop(); policy.invalidate("Arm routine owns body clearance"); publish(); return
        }
        startTimer()
        let now = ProcessInfo.processInfo.systemUptime
        guard !arming, policy.hasFreshObservation(at: now) else {
            policy.invalidate("Waiting for a fresh, unambiguous camera reference"); publish(); return
        }
        if usesLiveCamera {
            arming = true
            transport.arm(profile: .init(maximumDegreesPerSecond: policy.maximumSpeed,
                                        accelerationDegreesPerSecondSquared: policy.acceleration))
        } else { _ = policy.arm(at: now) }
        publish()
    }

    func stop() {
        precondition(Thread.isMainThread)
        localLeverHeld = false; remoteBaseline = nil; remoteUntil = 0; motionUntil = 0
        policy.invalidate(usesLiveCamera ? "Stopped — re-arm to move" : "Rehearsal stopped")
        stopHardware(); publish()
    }

    private func stopHardware() {
        if hardwareReady || arming { transport.stop() }
        hardwareReady = false; arming = false
    }

    func releaseLever() {
        localLeverHeld = false
        if remoteBaseline == nil { policy.hold() }
    }

    func setLever(_ value: Double, held: Bool) {
        precondition(Thread.isMainThread)
        startTimer()
        guard held else { releaseLever(); return }
        guard remoteBaseline == nil, policy.armed else { return }
        localLeverHeld = true
        policy.requestRate(value); motionUntil = ProcessInfo.processInfo.systemUptime + 60
    }

    func turnToHeading(_ heading: Double) {
        precondition(Thread.isMainThread)
        guard remoteBaseline == nil, policy.armed else { return }
        localLeverHeld = false
        policy.requestHeading(heading); motionUntil = ProcessInfo.processInfo.systemUptime + 60
    }

    func setMaximumSpeed(_ speed: Double) {
        guard speed.isFinite, (1 ... 20).contains(speed) else { return }
        // A profile change requires another explicit arm; the Tic limits and
        // host taper cannot silently disagree during a turn.
        stop(); policy.maximumSpeed = speed; publish()
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
              policy.hasFreshObservation(at: ProcessInfo.processInfo.systemUptime), !localLeverHeld else { return }
        if remoteBaseline == nil { remoteBaseline = policy.unwrappedHeading }
        guard let remoteBaseline else { return }
        remoteUntil = ProcessInfo.processInfo.systemUptime + 0.6
        motionUntil = remoteUntil
        policy.requestHeading(remoteBaseline + min(1, max(-1, rotation)) * 180)
    }

    @objc private func applicationInactive() {
        // Local mouse/keyboard ownership cannot survive app focus loss. An
        // authenticated remote demand has its own continuously renewed lease.
        if remoteBaseline == nil { stop() }
    }

    @objc private func applicationTerminating() { stop() }

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
        let dt = min(0.1, max(0, now - lastTick)); lastTick = now
        if !usesLiveCamera {
            simulatedHeading += policy.velocity * dt
            simulatedSequence &+= 1
            _ = policy.observe(.init(heading: simulatedHeading, capturedAt: now, uncertainty: 0.1,
                                     stream: "explicit-rehearsal", sequence: simulatedSequence), now: now)
        }
        if remoteBaseline != nil && now > remoteUntil { remoteBaseline = nil; policy.hold() }
        if policy.armed && policy.mode != .hold && now > motionUntil { policy.hold() }
        let velocity = policy.tick(at: now)
        if usesLiveCamera {
            if hardwareReady && !policy.armed { stopHardware() }
            else if hardwareReady && now - lastSent >= 0.09 {
                lastSent = now
                // Keep zero-speed hold alive too; unchanged demands must not
                // starve the independent one-second Tic watchdog.
                transport.velocity(velocity, validUntil: min(now + 0.2,
                    (policy.observation?.capturedAt ?? 0) + policy.maximumObservationAge))
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
        _ = policy.observe(.init(heading: yaw * 180 / .pi, capturedAt: now - age,
                                 uncertainty: sigma * 180 / .pi, stream: key, sequence: sequence), now: now)
        visionDetail = String(format: "%@ camera • yaw uncertainty ±%.1f°", camera, sigma * 180 / .pi)
        if !policy.armed && hardwareReady { stopHardware() }
        publish()
    }

    private func publish() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
