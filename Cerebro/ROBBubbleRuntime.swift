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
    private(set) var pan = 4000
    private(set) var tilt = 8000
    private(set) var targetDescription = "Select a pixel in the depth camera. Calibration is unconfirmed."
    private var timer: Timer?
    private var owner: UUID?
    private var ownerController: UUID?
    private var observers: [NSObjectProtocol] = []
    private var lastOutputs: [Int: Int] = [:]
    private let watchdog = ROBBubbleRelayWatchdog()
    private var lastPublish = 0.0
    private var outputSequence: UInt64 = 0
    private var stowGeneration = 0
    private var stowingUntil = 0.0
    private var localPreviewActive = false
    private var lastDetail = "Dry run • relay wiring and shoulder calibration need verification"
    private var aimUsesCalibration = false
    private let imageQueue = DispatchQueue(label: "com.orbitusrobotics.bubbles.camera", qos: .utility)
    private let imageLock = NSLock()
    private var imageBusy = false
    private var lastImageAdmission = 0.0
    private var imageDemand = false
    private let context: CIContext
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

    @nonobjc init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
        super.init()
        if let data = UserDefaults.standard.data(forKey: "ROBBubbleCalibration.v1"),
           let saved = try? JSONDecoder().decode(ROBBubbleCalibration.self, from: data), saved.valid {
            calibration = saved
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
        let now = ProcessInfo.processInfo.systemUptime
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
            if isOwner(message) { safety.heartbeat(at: now) }
        case .stop:
            stop(reason: "Operator stopped bubbles") // Any authenticated operator can stop.
        case .stow:
            stop(reason: "Tucking laser down, then rotating to the startup side")
            stow()
        case .releaseMount: releaseMount()
        case .authorize:
            guard owner == nil || isOwner(message) else { sendStatus(to: message.sessionID); return }
            guard now >= stowingUntil else {
                lastDetail = "Wait for the tuck-and-turn sequence to finish"
                sendStatus(to: message.sessionID); return
            }
            if watchdog.didTrip { stop(reason: "Relay watchdog stopped outputs"); watchdog.reset() }
            if liveOutputs && (!calibration.wiringConfirmed || serialBox?.bubbleHardwareReady != true) {
                lastDetail = "Verify relay wiring and connect the Maestro before authorization"
            } else {
                safety.authorize(at: now)
                if safety.armed { owner = message.sessionID; ownerController = message.controllerID }
                lastDetail = safety.detail
            }
        default:
            guard isOwner(message), safety.armed else {
                sendStatus(to: message.sessionID); return
            }
            safety.tick(at: now)
            guard safety.armed else { applyOutputs(); return }
            switch command.operation {
            case .aim: aim(command)
            case .manual:
                if let pan = command.pan, let tilt = command.tilt {
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
    func stop(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        safety.stop(at: ProcessInfo.processInfo.systemUptime)
        owner = nil; ownerController = nil; stowGeneration += 1
        stowingUntil = 0
        lastDetail = reason; applyOutputs()
    }
    func stow() {
        stop(reason: "Startup tuck: Tilt 8000, then Pan 4000")
        stowingUntil = ProcessInfo.processInfo.systemUptime + 1.5
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
        guard safety.armed else { lastDetail = "Authorize from ROBController before moving the mount"; return }
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
        if !tiltReleased || !panReleased { lastDetail = "Pulse release could not be verified: connect Maestro and retry" }
    }
    func legacyMotorControl(fan: Bool, on: Bool) {
        localCommand(.init(fan ? (on ? .spinOn : .spinOff) : (on ? .blowerOn : .blowerOff)))
    }
    private func applyAim(pan: Int, tilt: Int, calibrated: Bool) {
        guard (4000 ... 8000).contains(pan), (4000 ... 8000).contains(tilt) else { return }
        stowGeneration += 1
        self.pan = pan; self.tilt = tilt; aimUsesCalibration = calibrated
        write(channel: calibration.panChannel, value: pan)
        write(channel: calibration.tiltChannel, value: tilt)
        lastDetail = liveOutputs ? "Mount targets commanded; position is not encoder verified" : "Dry-run aim; no servo output"
    }
    private func aim(_ command: ROBBubbleCommand) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let id = command.frameID, let frame = frames.first(where: { $0.id == id }),
              now - frame.capturedAt <= 2, let u = command.u, let v = command.v,
              let depth = frame.depth, let intrinsics = frame.intrinsics,
              intrinsics.isValid(forWidth: depth.width, height: depth.height) else {
            lastDetail = "Target rejected: fresh aligned depth and camera intrinsics are required"; return
        }
        // Calibration is valid only at its measured neck pose. The preview geometry
        // model is not a measured transform and must never silently stand in for it.
        if liveOutputs && (!calibration.geometryConfirmed || frame.neck != calibration.neckReference
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
        let now = ProcessInfo.processInfo.systemUptime
        if watchdog.didTrip {
            stop(reason: "Relay watchdog expired; outputs stopped independently of the UI")
        }
        let wasArmed = safety.armed
        safety.tick(at: now)
        if wasArmed && !safety.armed { lastDetail = safety.detail; owner = nil; ownerController = nil }
        if liveOutputs && safety.armed && (serialBox?.bubbleHardwareReady != true
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
        if !safety.armed { owner = nil; ownerController = nil }
        if liveOutputs, let deadline = safety.shutdownDeadline(at: ProcessInfo.processInfo.systemUptime) {
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
        guard liveOutputs, lastOutputs[channel] != value else { return }
        let energizingRelay = (channel == 8 && value != calibration.spinOff)
            || (channel == 9 && value != calibration.blowerOff)
        let succeeded = energizingRelay
            ? watchdog.performIfUntripped { serialBox?.applyBubbleTarget(value, channel: channel) == true }
            : serialBox?.applyBubbleTarget(value, channel: channel) == true
        guard succeeded else {
            safety.stop(at: ProcessInfo.processInfo.systemUptime)
            owner = nil; ownerController = nil
            lastDetail = "Maestro write failed; outputs are unverified and authorization was removed"
            lastOutputs.removeAll()
            return
        }
        lastOutputs[channel] = value
    }
    @nonobjc func snapshot(includeFrame: Bool = false) -> ROBBubbleStatus {
        let now = ProcessInfo.processInfo.systemUptime
        let frame = includeFrame ? frames.last.flatMap { now - $0.capturedAt <= 2 ? $0 : nil } : nil
        return ROBBubbleStatus(detail: lastDetail, armed: safety.armed, dryRun: !liveOutputs,
            spin: safety.spin, blower: safety.blower, spinReady: safety.ready(at: now), mode: safety.mode,
            remainingSeconds: safety.remaining(), cooldownSeconds: safety.cooldownRemaining(at: now),
            pan: pan, tilt: tilt, targetDescription: targetDescription, frameID: frame?.id, jpeg: frame?.jpeg)
    }
    private func sendStatus(to session: UUID, includeFrame: Bool = false) {
        guard let viewer = viewers[session] else { return }
        outputSequence &+= 1
        var state = snapshot(includeFrame: includeFrame)
        if owner != nil && owner != session { state.armed = false; state.detail = "Another controller owns bubble authorization" }
        let message = ROBBubbleMessage(controllerID: viewer.controller, sessionID: session,
            sequence: outputSequence, command: .init(.status), status: state)
        if let data = try? ROBBubbleProtocol.encode(message) { publish?(data, viewer.controller, session) }
    }
    func setLocalPreview(_ active: Bool) { localPreviewActive = active; updateDemand() }
    private func updateDemand() {
        let now = ProcessInfo.processInfo.systemUptime
        let active = localPreviewActive || viewers.values.contains { now - $0.seen < 2 }
        imageLock.lock(); imageDemand = active; imageLock.unlock()
        cameraDemand?(active)
    }
    @nonobjc func offer(_ frameSet: CameraFrameSet) {
        let now = ProcessInfo.processInfo.systemUptime
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
        liveOutputs = false; calibration = next; frames.removeAll(); lastOutputs.removeAll()
        UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: "ROBBubbleCalibration.v1")
    }
    @nonobjc func calibrationJSON() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(calibration)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func captureNeckReference() { calibration.neckReference = currentNeck }
    @nonobjc func setLiveOutputs(_ enabled: Bool) {
        stop(reason: "Output mode changed; reauthorization required")
        guard !enabled || (calibration.valid && calibration.wiringConfirmed && serialBox?.bubbleHardwareReady == true) else {
            lastDetail = "Connect Maestro and confirm measured relay ON/OFF values first"; return
        }
        liveOutputs = enabled; lastOutputs.removeAll()
        if enabled { safety.forceCooldown(at: ProcessInfo.processInfo.systemUptime); lastDetail = safety.detail }
        applyOutputs()
    }

    @nonobjc func localCommand(_ command: ROBBubbleCommand) {
        switch command.operation {
        case .stop: stop(reason: "Stopped from Cerebro")
        case .stow: stow()
        case .releaseMount: releaseMount()
        case .preview, .heartbeat, .authorize, .status: break
        default:
            safety.tick(at: ProcessInfo.processInfo.systemUptime)
            guard safety.armed else { lastDetail = "Authorize from ROBController first"; return }
            if command.operation == .aim { aim(command) }
            else if command.operation == .manual, let pan = command.pan, let tilt = command.tilt {
                applyAim(pan: pan, tilt: tilt, calibrated: false)
            } else { safety.command(command.operation, at: ProcessInfo.processInfo.systemUptime); lastDetail = safety.detail }
            applyOutputs()
        }
    }

    func maestroReconnected() {
        lastOutputs.removeAll()
        stop(reason: "Maestro reconnected; reauthorization required")
        stowingUntil = ProcessInfo.processInfo.systemUptime + 1.5
        // The operator confirmed these OFF/rest outputs. Apply them even when
        // new commands are in dry run, so restart never retains a live relay.
        _ = serialBox?.applyBubbleTarget(calibration.blowerOff, channel: calibration.blowerChannel)
        _ = serialBox?.applyBubbleTarget(calibration.spinOff, channel: calibration.spinChannel)
        _ = serialBox?.applyBubbleTarget(calibration.stowTilt, channel: calibration.tiltChannel)
        let generation = stowGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.stowGeneration == generation else { return }
            _ = self.serialBox?.applyBubbleTarget(self.calibration.stowPan, channel: self.calibration.panChannel)
        }
        if liveOutputs { safety.forceCooldown(at: ProcessInfo.processInfo.systemUptime) }
    }
}
