import AppKit
import AVFoundation

// Headless hardware substitutes: these tests cannot open a serial port.
@objcMembers final class ROBSerialBox: NSObject {
    var bubbleHardwareReady = true
    var isNeckCommandStateKnown = true
    var commandedNeckPanTarget = 6000
    var commandedLowerNeckTiltTarget = 6000
    var commandedUpperNeckTiltTarget = 6000
    var writes: [[Int]] = []
    var failedChannels: Set<Int> = []
    func stopBubbleRelaysForWatchdog() { }
    func applyBubbleTarget(_ target: Int, channel: Int) -> Bool {
        writes.append([channel, target]); return bubbleHardwareReady && !failedChannels.contains(channel)
    }
}
extension Notification.Name {
    static let robControlLiveSessionDidEnd = Notification.Name("fixture-session-ended")
}
enum ROBControlLiveSessionNotification { static let sessionIDKey = "session" }
struct CameraDepthFrame {
    let width: Int; let height: Int; let millimetersLittleEndian: Data
    func distanceMillimeters(x: Int, y: Int) -> UInt16? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = 2 * (y * width + x)
        let mm = UInt16(millimetersLittleEndian[offset]) | UInt16(millimetersLittleEndian[offset + 1]) << 8
        return mm == 0 ? nil : mm
    }
}
struct CameraIntrinsics {
    let fx: Double; let fy: Double; let cx: Double; let cy: Double
    func isValid(forWidth: Int, height: Int) -> Bool { fx > 0 && fy > 0 }
}
struct CameraFrameSet {
    let rgbSampleBuffer: CMSampleBuffer
    let alignedDepth: CameraDepthFrame?
    let intrinsics: CameraIntrinsics?
}

@main struct BubbleRuntimeTests {
    static func main() throws {
        let domain = "ROB.BubbleFixtures.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let runtime = ROBBubbleRuntime(context: CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false]), defaults: defaults)
        let box = ROBSerialBox(); runtime.serialBox = box
        let a = UUID(), b = UUID(), sessionA = UUID(), sessionB = UUID()
        func request(_ operation: ROBBubbleOperation, sequence: UInt64, controller: UUID = a, session: UUID = sessionA,
                     frame: UUID? = nil, u: Double? = nil, v: Double? = nil) {
            runtime.receive(.init(controllerID: controller, sessionID: session, sequence: sequence,
                command: .init(operation, frameID: frame, u: u, v: v)))
        }
        request(.spinOn, sequence: 1)
        precondition(!runtime.snapshot().spin)
        request(.authorize, sequence: 2)
        precondition(runtime.snapshot().armed)
        request(.spinOn, sequence: 1, controller: b, session: sessionB)
        precondition(!runtime.snapshot().spin, "A second controller cannot use another session's authorization")
        request(.spinOn, sequence: 3)
        precondition(runtime.snapshot().spin)
        request(.spinOff, sequence: 3)
        precondition(runtime.snapshot().spin, "Duplicate sequences cannot change motor outputs")
        request(.stop, sequence: 2, controller: b, session: sessionB)
        precondition(!runtime.snapshot().armed && !runtime.snapshot().spin)
        request(.authorize, sequence: 4)
        precondition(runtime.snapshot().armed)

        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 20, 20, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescription: format!,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let depth = CameraDepthFrame(width: 20, height: 20, millimetersLittleEndian: Data((0..<400).flatMap { _ in [UInt8(0xd0), 0x07] }))
        runtime.setLocalPreview(true)
        runtime.offer(.init(rgbSampleBuffer: sample!, alignedDepth: depth,
                            intrinsics: .init(fx: 10, fy: 10, cx: 9.5, cy: 9.5)))
        let deadline = Date().addingTimeInterval(1.5)
        while runtime.snapshot(includeFrame: true).frameID == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let frameID = runtime.snapshot(includeFrame: true).frameID else { fatalError("No preview frame") }
        request(.aim, sequence: 5, frame: UUID(), u: 0.5, v: 0.5)
        precondition(runtime.pan == 4000, "Unrecognized frame IDs must fail closed")
        request(.aim, sequence: 6, frame: frameID, u: 0.5, v: 0.5)
        precondition(runtime.pan == 6000 && runtime.tilt == 6000)
        precondition(runtime.snapshot().targetDescription.contains("UNCALIBRATED"))
        precondition(box.writes.isEmpty, "Dry-run aiming and motor commands must never write hardware")
        NotificationCenter.default.post(name: .robControlLiveSessionDidEnd, object: nil,
            userInfo: [ROBControlLiveSessionNotification.sessionIDKey: sessionA])
        precondition(!runtime.snapshot().armed)
        request(.authorize, sequence: 7)
        request(.releaseMount, sequence: 8)
        precondition(!runtime.snapshot().armed && !runtime.snapshot().spin && !runtime.snapshot().blower)
        precondition(box.writes == [[6, 0], [7, 0]], "Explicit OFF must still release servo pulses in dry run")

        var now = ProcessInfo.processInfo.systemUptime
        defaults.set(true, forKey: "ROBPassiveHardwareStartup")
        let passive = ROBBubbleRuntime(context: CIContext(options: [.useSoftwareRenderer: true]), defaults: defaults, uptime: { now })
        let passiveHardware = ROBSerialBox(); passive.serialBox = passiveHardware
        precondition(passive.automaticMountStartupEnabled, "Saved laser startup defaults on independently of passive arms")
        passive.maestroReconnected()
        precondition(passiveHardware.writes == [[9, 4000], [8, 4000], [6, 8000]], "Relays OFF, then tuck tilt before any pan")
        precondition(passive.mountStartupStatus()["startup_in_progress"] as? Bool == true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        precondition(passiveHardware.writes == [[9, 4000], [8, 4000], [6, 8000], [7, 4000]], "Passive arms must not suppress automatic laser positioning")
        precondition(passive.mountStartupStatus()["startup_state"] as? String == "complete")
        precondition(passive.mountStartupStatus()["commanded_pan"] as? Int == 4000)
        precondition(passive.mountStartupStatus()["commanded_tilt"] as? Int == 8000)
        precondition(!passive.snapshot().armed && !passive.liveOutputs && !passive.liveMountOutputs,
                     "Automatic positioning must not authorize later mount or relay operations")
        now += 2
        passive.manualPan(6200, tilt: 5800)
        precondition(passiveHardware.writes.suffix(2) == [[7, 6200], [6, 5800]], "Passive startup blocked explicit controls")

        // Persist non-factory values and exercise the actual runtime without
        // serial ports or the production preferences domain.
        let savedCalibration = defaults.data(forKey: "ROBBubbleCalibration.v1")
        var custom = ROBBubbleCalibration(); custom.stowTilt = 7810; custom.stowPan = 4210
        let customData = try JSONEncoder().encode(custom)
        defaults.set(customData, forKey: "ROBBubbleCalibration.v1")
        func mountFixture() -> (ROBBubbleRuntime, ROBSerialBox) {
            let runtime = ROBBubbleRuntime(context: CIContext(options: [.useSoftwareRenderer: true]), defaults: defaults, uptime: { now })
            let box = ROBSerialBox(); runtime.serialBox = box
            return (runtime, box)
        }
        let (saved, savedBox) = mountFixture()
        saved.maestroReconnected()
        precondition(savedBox.writes == [[9, 4000], [8, 4000], [6, 7810]])
        let (stopped, stoppedBox) = mountFixture()
        stopped.maestroReconnected(); stopped.localCommand(.init(.stop))
        let (released, releasedBox) = mountFixture()
        released.maestroReconnected(); released.releaseMount()
        let (overridden, overriddenBox) = mountFixture()
        overridden.maestroReconnected(); overridden.manualPan(6100, tilt: 5900)
        let (failedTilt, failedTiltBox) = mountFixture()
        failedTiltBox.failedChannels = [6]; failedTilt.maestroReconnected()
        let (failedRelay, failedRelayBox) = mountFixture()
        failedRelayBox.failedChannels = [9]; failedRelay.maestroReconnected()
        let (disconnected, disconnectedBox) = mountFixture()
        disconnected.maestroReconnected(); disconnectedBox.bubbleHardwareReady = false
        let (failedPan, failedPanBox) = mountFixture()
        failedPanBox.failedChannels = [7]; failedPan.maestroReconnected()
        let (reconnected, reconnectedBox) = mountFixture()
        reconnected.maestroReconnected(); reconnected.maestroReconnected()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        precondition(savedBox.writes == [[9, 4000], [8, 4000], [6, 7810], [7, 4210]])
        precondition(saved.pan == 4210 && saved.tilt == 7810, "Published position must use the saved values actually sent")
        precondition(defaults.data(forKey: "ROBBubbleCalibration.v1") == customData, "Startup must never rewrite saved calibration")
        precondition(stoppedBox.writes.allSatisfy { $0[0] != 7 } && stopped.mountStartupStatus()["startup_state"] as? String == "cancelled")
        precondition(releasedBox.writes.suffix(2) == [[6, 0], [7, 0]], "Release must cancel delayed pan")
        precondition(overriddenBox.writes.suffix(2) == [[7, 6100], [6, 5900]], "Manual action must cancel delayed pan")
        precondition(failedTiltBox.writes.allSatisfy { $0[0] != 7 }, "A failed tuck must never be followed by pan")
        precondition(failedRelayBox.writes.allSatisfy { ![6, 7].contains($0[0]) }, "Unverified relay OFF must prevent positioning")
        precondition(disconnectedBox.writes.allSatisfy { $0[0] != 7 }, "Disconnection must prevent delayed pan")
        for failed in [failedTilt, failedRelay, disconnected, failedPan] {
            precondition(failed.mountStartupStatus()["startup_state"] as? String == "failed")
            precondition(failed.mountStartupStatus()["commanded_pan"] is NSNull, "Rejected targets cannot be reported as commanded")
        }
        precondition(reconnectedBox.writes.filter { $0[0] == 7 } == [[7, 4210]], "Reconnect must invalidate the old delayed pan")

        let writesBeforeSetting = savedBox.writes
        saved.automaticMountStartupEnabled = false
        precondition(savedBox.writes == writesBeforeSetting, "Changing the preference must not move hardware")
        let (disabled, disabledBox) = mountFixture()
        precondition(!disabled.automaticMountStartupEnabled, "Explicit opt-out survives runtime recreation")
        disabled.maestroReconnected()
        defaults.set("invalid", forKey: "ROBLaserMountAutomaticStartupEnabled")
        let (invalidSetting, invalidSettingBox) = mountFixture()
        precondition(!invalidSetting.automaticMountStartupEnabled)
        invalidSetting.maestroReconnected()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        for box in [disabledBox, invalidSettingBox] {
            precondition(box.writes == [[9, 4000], [8, 4000]], "Disabled startup still sends relay OFF but never positions servos")
        }
        precondition(disabled.mountStartupStatus()["startup_state"] as? String == "disabled")
        disabled.automaticMountStartupEnabled = true
        let (reenabled, reenabledBox) = mountFixture()
        reenabled.maestroReconnected()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        precondition(reenabledBox.writes.suffix(2) == [[6, 7810], [7, 4210]], "Explicit enable restores the saved sequence")
        defaults.removeObject(forKey: "ROBLaserMountAutomaticStartupEnabled")
        defaults.set(savedCalibration, forKey: "ROBBubbleCalibration.v1")
        defaults.set(false, forKey: "ROBPassiveHardwareStartup")
        let live = ROBBubbleRuntime(context: CIContext(options: [.useSoftwareRenderer: true]), defaults: defaults, uptime: { now })
        let hardware = ROBSerialBox(); live.serialBox = hardware
        live.maestroReconnected()
        now += 2
        var sequence: UInt64 = 0
        func liveRequest(_ operation: ROBBubbleOperation, pan: Int? = nil, tilt: Int? = nil) {
            sequence += 1
            live.receive(.init(controllerID: a, sessionID: sessionA, sequence: sequence,
                command: .init(operation, pan: pan, tilt: tilt)))
        }
        hardware.writes.removeAll()
        liveRequest(.authorizeMount)
        precondition(live.snapshot().mountAuthorized == true && !live.snapshot().armed)
        precondition(live.snapshot().depthReady == false && live.snapshot().cooldownSeconds > 0)
        precondition(hardware.writes.isEmpty, "Enabling mount permission alone must not move anything")
        liveRequest(.manual, pan: 6100, tilt: 5900)
        precondition(hardware.writes == [[7, 6100], [6, 5900]], "Manual motion needs neither depth nor motor cooldown completion")
        liveRequest(.spinOn)
        precondition(!live.snapshot().spin, "Mount authorization does not authorize motors")
        live.receive(.init(controllerID: b, sessionID: sessionB, sequence: 1,
            command: .init(.manual, pan: 7000, tilt: 7000)))
        precondition(live.pan == 6100, "Other sessions cannot borrow mount authorization")
        now += 2.1
        liveRequest(.heartbeat)
        liveRequest(.manual, pan: 7000, tilt: 7000)
        precondition(live.pan == 6100 && live.snapshot().mountAuthorized == false, "Late heartbeat cannot revive a mount lease")

        live.manualPan(6200, tilt: 5800)
        precondition(live.pan == 6200 && hardware.writes.suffix(2) == [[7, 6200], [6, 5800]])
        liveRequest(.manual, pan: 7100, tilt: 7100)
        precondition(live.pan == 6200, "Local movement does not grant remote permission")
        live.localCommand(.init(.spinOn))
        precondition(!live.snapshot().spin, "Local controls still respect the reconnect cooldown")
        now += 61
        live.localCommand(.init(.spinOn))
        precondition(live.snapshot().spin && hardware.writes.contains([8, 8000]), "Cerebro can start the verified fan without a controller")
        precondition(live.snapshot().remainingSeconds == ROBBubbleSafety.workBudget)
        live.localCommand(.init(.blowerOn))
        precondition(!live.snapshot().blower)
        now += 0.51
        live.localCommand(.init(.blowerOn))
        precondition(live.snapshot().blower && hardware.writes.contains([9, 8000]))
        precondition(live.snapshot().remainingSeconds == ROBBubbleSafety.workBudget, "Published countdown stays full until the blower starts")
        for _ in 0..<6 {
            now += 0.5
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
        precondition(live.snapshot().spin && live.snapshot().blower, "Local operation does not need remote heartbeats")
        let usedBeforeStop = live.safety.used
        live.localCommand(.init(.stop))
        precondition(!live.snapshot().spin && !live.snapshot().blower)
        precondition(hardware.writes.suffix(2) == [[9, 4000], [8, 4000]])

        liveRequest(.authorizeMount)
        liveRequest(.authorizeMotors)
        precondition(live.snapshot().armed && live.snapshot().mountAuthorized == true)
        precondition(!live.snapshot().spin && !live.snapshot().blower, "Remote authorization alone never starts motors")
        precondition(live.safety.used >= usedBeforeStop, "Changing authorization must preserve the duty budget")
        liveRequest(.spinOn)
        precondition(live.snapshot().spin)
        now += 2.1
        liveRequest(.heartbeat)
        precondition(!live.snapshot().spin && !live.snapshot().armed && live.snapshot().mountAuthorized == false)
        liveRequest(.releaseMount)
        precondition(hardware.writes.suffix(2) == [[6, 0], [7, 0]] && !live.liveMountOutputs)

        var captureTime = ProcessInfo.processInfo.systemUptime
        let capture = ROBBubbleRuntime(context: CIContext(options: [.useSoftwareRenderer: true]), defaults: defaults,
                                       uptime: { captureTime })
        let captureBox = ROBSerialBox(); capture.serialBox = captureBox
        capture.setLaserCaptureActive(true)
        precondition(captureBox.writes.isEmpty, "Opening calibration must not write any actuator")
        capture.manualPan(5836, tilt: 5191)
        let commandedWrites = captureBox.writes
        func captureImage() {
            captureTime += 0.5
            let previous = capture.snapshot(includeFrame: true).frameID
            capture.offer(.init(rgbSampleBuffer: sample!, alignedDepth: depth,
                                intrinsics: .init(fx: 10, fy: 10, cx: 9.5, cy: 9.5)))
            let deadline = Date().addingTimeInterval(1.5)
            while capture.snapshot(includeFrame: true).frameID == previous && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(capture.snapshot(includeFrame: true).frameID != previous, "A new RGB frame must arrive")
        }
        captureImage()
        let captured = capture.laserCalibrationFrame()!
        precondition(captured.pan == 5836 && captured.tilt == 5191 && captured.neck == [6000, 6000, 6000])
        precondition(captured.panChannel == 7 && captured.tiltChannel == 6)
        precondition(captured.width == 20 && captured.height == 20 && NSImage(data: captured.png) != nil)
        precondition(captureBox.writes == commandedWrites, "Reading images and pose must not command actuators")
        captureBox.commandedNeckPanTarget = 6100
        precondition(capture.laserCalibrationFrame() == nil, "Changed head commands invalidate the current image")
        captureBox.commandedNeckPanTarget = 6000
        capture.manualPan(5840, tilt: 5191)
        precondition(capture.laserCalibrationFrame() == nil, "Changed nozzle commands require a new image")
        captureImage()
        precondition(capture.laserCalibrationFrame() != nil)
        captureTime += 2.1
        precondition(capture.laserCalibrationFrame() == nil, "Stale calibration images are rejected")
        captureBox.isNeckCommandStateKnown = false
        captureImage()
        precondition(capture.laserCalibrationFrame() == nil, "Unknown neck commands cannot become a calibration sample")
        captureBox.isNeckCommandStateKnown = true
        captureImage()
        capture.releaseMount()
        precondition(capture.laserCalibrationFrame() == nil, "Released mount pulses cannot be recorded as a known pose")
        capture.setLaserCaptureActive(false)

        let watchdog = ROBBubbleRelayWatchdog()
        let cutoff = DispatchSemaphore(value: 0)
        watchdog.update(deadline: ProcessInfo.processInfo.systemUptime + 0.05) { cutoff.signal() }
        // Deliberately do not run the main run loop: cutoff must be independent.
        precondition(cutoff.wait(timeout: .now() + 1) == .success)
        precondition(watchdog.didTrip && !watchdog.performIfUntripped { true })
        print("Bubble runtime fixtures passed: local controls, separate remote permissions, camera-free movement, leases, relay delay, cooldown, RGB-D targeting, release, watchdog")
    }
}
