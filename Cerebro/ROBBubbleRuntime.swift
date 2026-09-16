import AppKit
import AVFoundation
import CoreImage

/// All mutable actuator and authorization state is confined to the main queue.
@objcMembers final class ROBBubbleRuntime: NSObject {
    static let shared = ROBBubbleRuntime()
    weak var serialBox: ROBSerialBox?
    @nonobjc var cameraDemand: ((Bool) -> Void)?
    @nonobjc var publish: ((Data, UUID, UUID) -> Void)?
    @nonobjc private(set) var calibration = ROBBubbleCalibration()
    @nonobjc private(set) var safety = ROBBubbleSafety()
    private(set) var liveOutputs = false
    private(set) var liveMountOutputs = false
    private(set) var pan = 4000
    private(set) var tilt = 8000
    private(set) var targetDescription = "Select a target in the face-camera RGB image. Depth measures its distance; the camera-to-nozzle offset corrects the aim."
    private var timer: Timer?
    private var owner: UUID?
    private var ownerController: UUID?
    private var ownerLeaseUntil = 0.0
    private var mountAuthorized = false
    private var localMotorControl = false
    private var relayOffEstablished = false
    private var observers: [NSObjectProtocol] = []
    private var lastOutputs: [Int: Int] = [:]
    private let watchdog = ROBBubbleRelayWatchdog()
    private var lastPublish = 0.0
    private var outputSequence: UInt64 = 0
    private var stowGeneration = 0
    private var stowingUntil = 0.0
    private var localPreviewActive = false
    private var lastDetail = "Cerebro controls are ready. Remote controllers must enable Tilt/Pan or authorize bubbles."
    private var aimUsesCalibration = false
    private let imageQueue = DispatchQueue(label: "com.orbitusrobotics.bubbles.camera", qos: .utility)
    private let imageLock = NSLock()
    private var imageBusy = false
    private var lastImageAdmission = 0.0
    private var imageDemand = false
    private let context: CIContext
    private let uptime: () -> Double
    private let defaults: UserDefaults
    private struct Viewer { var controller: UUID; var sequence: UInt64; var seen: Double }
    private var viewers: [UUID: Viewer] = [:]
    private struct Frame {
        let id: UUID
        let capturedAt: Double
        let depth: CameraDepthFrame?
        let intrinsics: CameraIntrinsics?
        let jpeg: Data
        let neck: [Int]
    }
    private var frames: [Frame] = []

    @nonobjc init(context: CIContext = CIContext(options: [.cacheIntermediates: false]),
                 defaults: UserDefaults = .standard,
                 uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.context = context
        self.defaults = defaults
        self.uptime = uptime
        super.init()
        if let data = defaults.data(forKey: "ROBBubbleCalibration.v1"),
           let saved = try? JSONDecoder().decode(ROBBubbleCalibration.self, from: data), saved.valid {
            calibration = saved
        }
        // Upgrade the exact installation the operator has now tested. Do not
        // bless a different saved relay configuration or repeat this migration.
        if !defaults.bool(forKey: "ROBBubble.RelaysVerified20260915") {
            if calibration.spinOn == 8000 && calibration.blowerOn == 8000 {
                calibration.wiringConfirmed = true
                defaults.set(try? JSONEncoder().encode(calibration), forKey: "ROBBubbleCalibration.v1")
            }
            defaults.set(true, forKey: "ROBBubble.RelaysVerified20260915")
        }
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        observers.append(NotificationCenter.default.addObserver(
            forName: .robControlLiveSessionDidEnd, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let session = note.userInfo?[ROBControlLiveSessionNotification.sessionIDKey] as? UUID else { return }
            self.viewers.removeValue(forKey: session)
            if self.owner == session { self.stop(reason: "Authorizing controller disconnected") }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stop(reason: "Cerebro is shutting down") })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stop(reason: "Computer is sleeping") })
    }

    func ownsChannel(_ channel: Int) -> Bool {
        [calibration.panChannel, calibration.tiltChannel, calibration.spinChannel, calibration.blowerChannel].contains(channel)
    }

    @nonobjc func receive(_ message: ROBBubbleMessage) {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = uptime()
        expireRemoteOwner(at: now)
        guard message.command.operation != .status,
              ROBBubbleProtocol.isFresh(message, now: Date().timeIntervalSince1970)
                || message.command.operation == .stop else { return }
        if let old = viewers[message.sessionID], message.sequence <= old.sequence { return }
        guard viewers[message.sessionID] != nil || viewers.count < 16 else { return }
        viewers[message.sessionID] = Viewer(controller: message.controllerID, sequence: message.sequence, seen: now)
        let command = message.command
        switch command.operation {
        case .preview: sendStatus(to: message.sessionID, includeFrame: true)
        case .heartbeat:
            if isOwner(message) { ownerLeaseUntil = now + 2; safety.heartbeat(at: now) }
        case .stop:
            stop(reason: "Operator stopped bubbles") // Any authenticated operator can stop.
        case .stow:
            guard isOwner(message), mountAuthorized else {
                lastDetail = "Enable Tilt/Pan on this controller before stowing"
                sendStatus(to: message.sessionID); return
            }
            stop(reason: "Tucking laser down, then rotating to the startup side")
            stow()
        case .releaseMount: releaseMount()
        case .authorize, .authorizeMount, .authorizeMotors:
            guard !localMotorControl, owner == nil || isOwner(message) else { sendStatus(to: message.sessionID); return }
            guard now >= stowingUntil else {
                lastDetail = "Wait for the tuck-and-turn sequence to finish"
                sendStatus(to: message.sessionID); return
            }
            if watchdog.didTrip { stop(reason: "Relay watchdog stopped outputs"); watchdog.reset() }
            if command.operation == .authorizeMount {
                guard enableMount() else { sendStatus(to: message.sessionID); return }
                mountAuthorized = true
                lastDetail = "Tilt/Pan enabled for this controller; motors require separate authorization"
            } else {
                if command.operation == .authorizeMotors {
                    guard enableMotors() else { sendStatus(to: message.sessionID); return }
                }
                safety.authorize(at: now)
                if command.operation == .authorize && safety.armed { mountAuthorized = true }
                lastDetail = safety.detail
            }
            if mountAuthorized || safety.armed {
                owner = message.sessionID; ownerController = message.controllerID; ownerLeaseUntil = now + 2
            }
        default:
            guard isOwner(message) else {
                sendStatus(to: message.sessionID); return
            }
            safety.tick(at: now)
            switch command.operation {
            case .aim:
                if mountAuthorized { aim(command) }
            case .manual:
                if mountAuthorized, let pan = command.pan, let tilt = command.tilt {
                    applyAim(pan: pan, tilt: tilt, calibrated: false)
                }
            default:
                safety.command(command.operation, at: now); lastDetail = safety.detail
            }
        }
        applyOutputs()
        sendStatus(to: message.sessionID)
        updateDemand()
    }

    private func isOwner(_ message: ROBBubbleMessage) -> Bool {
        owner == message.sessionID && ownerController == message.controllerID
    }
    private func expireRemoteOwner(at now: Double) {
        if owner != nil && now >= ownerLeaseUntil { stop(reason: "Controller heartbeat lost; outputs stopped") }
    }
    func stop(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        safety.stop(at: uptime())
        owner = nil; ownerController = nil; mountAuthorized = false; localMotorControl = false
        aimUsesCalibration = false; stowGeneration += 1
        stowingUntil = 0
        lastDetail = reason; applyOutputs()
    }
    func stow() {
        stop(reason: "Startup tuck: Tilt 8000, then Pan 4000")
        stowingUntil = uptime() + 1.5
        tilt = calibration.stowTilt
        write(channel: calibration.tiltChannel, value: tilt)
        let generation = stowGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.stowGeneration == generation else { return }
            self.pan = self.calibration.stowPan
            self.write(channel: self.calibration.panChannel, value: self.pan)
        }
    }
    func manualPan(_ pan: Int, tilt: Int) {
        // An intentional action at Cerebro is local operator authorization.
        // Remote requests never enter this method; they must own a live lease.
        if owner != nil { stop(reason: "Cerebro took local control") }
        guard enableMount() else { return }
        applyAim(pan: pan, tilt: tilt, calibrated: false)
    }
    func releaseMount() {
        stop(reason: "Tilt/Pan pulses disabled (target 0); servo supply remains powered")
        // Explicit pulse release is an OFF action and remains available even
        // while activation commands are simulated or relay wiring is unconfirmed.
        let tiltReleased = serialBox?.applyBubbleTarget(0, channel: calibration.tiltChannel) == true
        let panReleased = serialBox?.applyBubbleTarget(0, channel: calibration.panChannel) == true
        lastOutputs.removeValue(forKey: calibration.tiltChannel)
        lastOutputs.removeValue(forKey: calibration.panChannel)
        liveMountOutputs = false
        if !tiltReleased || !panReleased { lastDetail = "Pulse release could not be verified: connect Maestro and retry" }
    }
    func legacyMotorControl(fan: Bool, on: Bool) {
        localCommand(.init(fan ? (on ? .spinOn : .spinOff) : (on ? .blowerOn : .blowerOff)))
    }
    private func applyAim(pan: Int, tilt: Int, calibrated: Bool) {
        guard (4000 ... 8000).contains(pan), (4000 ... 8000).contains(tilt) else { return }
        stowGeneration += 1
        self.pan = pan; self.tilt = tilt; aimUsesCalibration = calibrated && liveMountOutputs
        write(channel: calibration.panChannel, value: pan)
        write(channel: calibration.tiltChannel, value: tilt)
        lastDetail = liveMountOutputs ? "Live Tilt/Pan targets commanded" : "Dry-run aim; no servo output"
    }
    private func aim(_ command: ROBBubbleCommand) {
        let now = uptime()
        guard let id = command.frameID, let frame = frames.first(where: { $0.id == id }),
              now - frame.capturedAt <= 2, let u = command.u, let v = command.v,
              let depth = frame.depth, let intrinsics = frame.intrinsics,
              intrinsics.isValid(forWidth: depth.width, height: depth.height) else {
            lastDetail = "Target rejected: fresh aligned depth and camera intrinsics are required"; return
        }
        // Calibration is valid only at its measured neck pose. The preview geometry
        // model is not a measured transform and must never silently stand in for it.
        if liveMountOutputs && (!calibration.geometryConfirmed || frame.neck != calibration.neckReference
                            || currentNeck != calibration.neckReference) {
            lastDetail = "Target rejected: return the camera to its measured calibration pose"; return
        }
        let px = Int((u * Double(depth.width - 1)).rounded())
        let py = Int((v * Double(depth.height - 1)).rounded())
        var values: [Double] = []
        for y in (py - 2)...(py + 2) {
            for x in (px - 2)...(px + 2) {
                if let mm = depth.distanceMillimeters(x: x, y: y), (300 ... 8000).contains(mm) {
                    values.append(Double(mm) / 1000)
                }
            }
        }
        values.sort()
        guard values.count >= 9, values[values.count * 3 / 4] - values[values.count / 4] < 0.15,
              let solution = calibration.solve(u: u, v: v, width: depth.width, height: depth.height,
                  depthMeters: values[values.count / 2], fx: intrinsics.fx, fy: intrinsics.fy,
                  cx: intrinsics.cx, cy: intrinsics.cy) else {
            lastDetail = "Target rejected: depth hole, depth edge, or target outside servo travel"; return
        }
        targetDescription = solution.description + (calibration.geometryConfirmed ? "" : " • UNCALIBRATED simulation")
        applyAim(pan: solution.pan, tilt: solution.tilt, calibrated: true)
    }

    private var currentNeck: [Int] {
        guard let box = serialBox, box.isNeckCommandStateKnown else { return [] }
        return [box.commandedNeckPanTarget, box.commandedLowerNeckTiltTarget, box.commandedUpperNeckTiltTarget]
    }
    private func tick() {
        let now = uptime()
        if watchdog.didTrip {
            stop(reason: "Relay watchdog expired; outputs stopped independently of the UI")
        }
        expireRemoteOwner(at: now)
        let wasArmed = safety.armed
        if localMotorControl { safety.heartbeat(at: now) }
        safety.tick(at: now)
        if wasArmed && !safety.armed { lastDetail = safety.detail; localMotorControl = false }
        if (liveOutputs || liveMountOutputs) && (safety.armed || mountAuthorized || aimUsesCalibration) && (serialBox?.bubbleHardwareReady != true
            || (aimUsesCalibration && currentNeck != calibration.neckReference)) {
            stop(reason: "Hardware disconnected or camera left its calibrated pose")
        }
        applyOutputs()
        // Retain sequence watermarks for this live session; a stale preview cannot
        // erase replay protection. Disconnection removes the corresponding entry.
        if now - lastPublish >= 0.25 {
            lastPublish = now
            for (session, viewer) in viewers where now - viewer.seen < 2 { sendStatus(to: session) }
            NotificationCenter.default.post(name: Notification.Name("ROBBubbleStatusChanged"), object: self)
            updateDemand()
        }
    }
    private func applyOutputs() {
        if !safety.armed { localMotorControl = false }
        if !safety.armed && !mountAuthorized { owner = nil; ownerController = nil }
        if liveOutputs, let deadline = safety.shutdownDeadline(at: uptime()) {
            let box = serialBox
            watchdog.update(deadline: deadline) {
                box?.stopBubbleRelaysForWatchdog()
            }
        }
        // OFF is written before ON when both relays change; blower can never
        // remain commanded on while spin is off.
        write(channel: calibration.blowerChannel, value: safety.blower ? calibration.blowerOn : calibration.blowerOff)
        write(channel: calibration.spinChannel, value: safety.spin ? calibration.spinOn : calibration.spinOff)
        if !safety.spin && !safety.blower,
           lastOutputs[calibration.spinChannel] == calibration.spinOff,
           lastOutputs[calibration.blowerChannel] == calibration.blowerOff {
            watchdog.update(deadline: nil, cutoff: {})
        }
    }
    private func write(channel: Int, value: Int) {
        let mountChannel = channel == calibration.panChannel || channel == calibration.tiltChannel
        guard (mountChannel ? liveMountOutputs : liveOutputs), lastOutputs[channel] != value else { return }
        let energizingRelay = (channel == 8 && value != calibration.spinOff)
            || (channel == 9 && value != calibration.blowerOff)
        let succeeded = energizingRelay
            ? watchdog.performIfUntripped { serialBox?.applyBubbleTarget(value, channel: channel) == true }
            : serialBox?.applyBubbleTarget(value, channel: channel) == true
        guard succeeded else {
            safety.stop(at: uptime())
            owner = nil; ownerController = nil; mountAuthorized = false; localMotorControl = false
            relayOffEstablished = false
            lastDetail = "Maestro write failed; outputs are unverified and authorization was removed"
            lastOutputs.removeAll()
            return
        }
        lastOutputs[channel] = value
    }
    @nonobjc func snapshot(includeFrame: Bool = false) -> ROBBubbleStatus {
        let now = uptime()
        let freshFrame = frames.last.flatMap { now - $0.capturedAt <= 2 ? $0 : nil }
        let frame = includeFrame ? freshFrame : nil
        let depthReady = freshFrame.flatMap { frame in
            frame.depth.map { frame.intrinsics?.isValid(forWidth: $0.width, height: $0.height) == true }
        } ?? false
        return ROBBubbleStatus(detail: lastDetail, armed: safety.armed, dryRun: !liveOutputs && !liveMountOutputs,
            spin: safety.spin, blower: safety.blower, spinReady: safety.ready(at: now), mode: safety.mode,
            remainingSeconds: safety.remaining(), cooldownSeconds: safety.cooldownRemaining(at: now),
            pan: pan, tilt: tilt, targetDescription: targetDescription, frameID: frame?.id, jpeg: frame?.jpeg,
            mountLive: liveMountOutputs, motorsLive: liveOutputs, depthReady: depthReady,
            mountAuthorized: mountAuthorized)
    }
    private func sendStatus(to session: UUID, includeFrame: Bool = false) {
        guard let viewer = viewers[session] else { return }
        outputSequence &+= 1
        var state = snapshot(includeFrame: includeFrame)
        if localMotorControl || (owner != nil && owner != session) {
            state.armed = false; state.mountAuthorized = false
            state.detail = localMotorControl ? "Cerebro is operating the motors locally" : "Another controller owns bubble authorization"
        }
        let message = ROBBubbleMessage(controllerID: viewer.controller, sessionID: session,
            sequence: outputSequence, command: .init(.status), status: state)
        if let data = try? ROBBubbleProtocol.encode(message) { publish?(data, viewer.controller, session) }
    }
    func setLocalPreview(_ active: Bool) { localPreviewActive = active; updateDemand() }
    private func updateDemand() {
        let now = uptime()
        let active = localPreviewActive || viewers.values.contains { now - $0.seen < 2 }
        imageLock.lock(); imageDemand = active; imageLock.unlock()
        cameraDemand?(active)
    }
    @nonobjc func offer(_ frameSet: CameraFrameSet) {
        let now = uptime()
        imageLock.lock()
        guard imageDemand, !imageBusy, now - lastImageAdmission >= 0.4 else { imageLock.unlock(); return }
        imageBusy = true; lastImageAdmission = now; imageLock.unlock()
        // Capture commanded neck pose on the main queue at frame admission.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let neck = self.currentNeck
            self.imageQueue.async {
                defer { self.imageLock.lock(); self.imageBusy = false; self.imageLock.unlock() }
                guard let buffer = CMSampleBufferGetImageBuffer(frameSet.rgbSampleBuffer) else { return }
                let input = CIImage(cvPixelBuffer: buffer)
                let scaled = input.transformed(by: .init(scaleX: min(1, 640 / input.extent.width), y: min(1, 640 / input.extent.width)))
                guard let cg = self.context.createCGImage(scaled, from: scaled.extent),
                      let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.65]),
                      jpeg.count <= 360_000 else { return }
                let aligned = frameSet.alignedDepth.flatMap { depth in
                    depth.width == CVPixelBufferGetWidth(buffer) && depth.height == CVPixelBufferGetHeight(buffer) ? depth : nil
                }
                let frame = Frame(id: UUID(), capturedAt: now, depth: aligned,
                    intrinsics: frameSet.intrinsics, jpeg: jpeg, neck: neck)
                DispatchQueue.main.async {
                    self.frames.append(frame)
                    self.frames = Array(self.frames.suffix(6))
                }
            }
        }
    }

    @nonobjc func saveCalibration(_ data: Data) throws {
        let next = try JSONDecoder().decode(ROBBubbleCalibration.self, from: data)
        guard next.valid else { throw NSError(domain: "Bubble calibration", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid channels, servo values, or geometry"]) }
        stop(reason: "Calibration changed; outputs returned to dry run")
        liveOutputs = false; liveMountOutputs = false
        calibration = next; frames.removeAll(); lastOutputs.removeAll()
        defaults.set(try JSONEncoder().encode(next), forKey: "ROBBubbleCalibration.v1")
    }
    @nonobjc func calibrationJSON() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(calibration)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func captureNeckReference() {
        stop(reason: "New neck reference captured; confirm geometry before camera aiming")
        calibration.geometryConfirmed = false
        calibration.neckReference = currentNeck
    }
    @nonobjc func setLiveMountOutputs(_ enabled: Bool) {
        stop(reason: "Tilt/Pan output mode changed")
        if enabled { _ = enableMount() } else { liveMountOutputs = false }
        lastOutputs.removeValue(forKey: calibration.panChannel)
        lastOutputs.removeValue(forKey: calibration.tiltChannel)
        // Enabling the mode alone never moves the mount. A subsequent
        // authorized manual/aim command (or explicit stow) supplies the target.
    }
    @nonobjc func setLiveOutputs(_ enabled: Bool) {
        stop(reason: "Output mode changed; reauthorization required")
        if enabled { _ = enableMotors() } else { liveOutputs = false }
        applyOutputs()
    }

    private func enableMount() -> Bool {
        guard serialBox?.bubbleHardwareReady == true else {
            lastDetail = "Connect the Maestro before moving Tilt/Pan"; return false
        }
        liveMountOutputs = true
        return true
    }
    private func enableMotors() -> Bool {
        guard calibration.valid, calibration.wiringConfirmed, serialBox?.bubbleHardwareReady == true else {
            lastDetail = "Connect Maestro and confirm relay ON/OFF values before running motors"; return false
        }
        if watchdog.didTrip { stop(reason: "Relay watchdog stopped outputs"); watchdog.reset() }
        if !liveOutputs {
            // A simulated run cannot carry ON state into real hardware.
            safety.stop(at: uptime())
            liveOutputs = true
            lastOutputs.removeValue(forKey: calibration.spinChannel)
            lastOutputs.removeValue(forKey: calibration.blowerChannel)
        }
        if !relayOffEstablished {
            safety.forceCooldown(at: uptime())
            lastDetail = safety.detail
        }
        applyOutputs()
        relayOffEstablished = lastOutputs[calibration.spinChannel] == calibration.spinOff
            && lastOutputs[calibration.blowerChannel] == calibration.blowerOff || relayOffEstablished
        return relayOffEstablished
    }

    @nonobjc func localCommand(_ command: ROBBubbleCommand) {
        switch command.operation {
        case .stop: stop(reason: "Stopped from Cerebro")
        case .stow:
            if enableMount() { stow() }
        case .releaseMount: releaseMount()
        case .preview, .heartbeat, .authorize, .authorizeMount, .authorizeMotors, .status: break
        case .manual:
            if let pan = command.pan, let tilt = command.tilt { manualPan(pan, tilt: tilt) }
        case .aim:
            if owner != nil { stop(reason: "Cerebro took local control") }
            if enableMount() { aim(command) }
        default:
            if owner != nil { stop(reason: "Cerebro took local control") }
            let now = uptime()
            let off = command.operation == .spinOff || command.operation == .blowerOff
            if !off {
                guard now >= stowingUntil, enableMotors() else { return }
                safety.authorize(at: now)
                localMotorControl = safety.armed
            }
            safety.command(command.operation, at: now); lastDetail = safety.detail
            applyOutputs()
        }
    }

    func maestroReconnected() {
        lastOutputs.removeAll()
        stop(reason: "Maestro reconnected; reauthorization required")
        stowingUntil = uptime() + 1.5
        // The operator confirmed these OFF/rest outputs. Apply them even when
        // new commands are in dry run, so restart never retains a live relay.
        let blowerOff = serialBox?.applyBubbleTarget(calibration.blowerOff, channel: calibration.blowerChannel) == true
        let spinOff = serialBox?.applyBubbleTarget(calibration.spinOff, channel: calibration.spinChannel) == true
        relayOffEstablished = blowerOff && spinOff
        _ = serialBox?.applyBubbleTarget(calibration.stowTilt, channel: calibration.tiltChannel)
        let generation = stowGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.stowGeneration == generation else { return }
            _ = self.serialBox?.applyBubbleTarget(self.calibration.stowPan, channel: self.calibration.panChannel)
        }
        // Start the restart cooldown when OFF is actually sent, not when the
        // operator later enables motors. Tilt/Pan remains available throughout.
        safety.forceCooldown(at: uptime())
    }
}
