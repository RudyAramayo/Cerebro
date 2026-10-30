import Cocoa
import CoreMedia

struct ROBChessPieceDetection {}
final class ROBAnimationPlayback {
    static let shared = ROBAnimationPlayback()
    func authorizesTorsoHeading(_ heading: Double) -> Bool { false }
}
final class ROBArmRoutineCoordinator {
    static let shared = ROBArmRoutineCoordinator()
    var ownsPhysicalMotion = false
    var torsoRotationBlockReason: String?
}

/// Compiles the real coordinator, views and camera service. The injected Tic
/// executor records calls; it cannot reach USB. --show opens an inert UI fixture.
@main struct ROBTorsoCoordinatorFixtureTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "TorsoCoordinatorFixture", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(line: UInt = #line, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(condition(), "Coordinator callback timed out at fixture line \(line)")
    }
    static func observation(sequence: UInt64 = 1, yaw: Double = 1, age: Double = 0,
                            camera: String = "face", confirmed: Bool = true) -> [String: Any] {
        ["schemaVersion": 1, "source": "markerless_rgbd", "frame": "base_link", "modelID": "test-model",
         "referenceID": "test-reference", "status": confirmed ? "confirmed" : "unavailable",
         "camera": camera, "streamID": "test-stream", "sequence": sequence,
         "capturedAtMilliseconds": (Date().timeIntervalSince1970 - age) * 1000,
         "torso": ["status": "confirmed", "yawRadians": yaw, "standardDeviationRadians": 0.005,
                   "residualMeters": 0.003]]
    }
    static func main() throws {
        let oldDebug = UserDefaults.standard.object(forKey: "ROBDevelopmentMode")
        let oldSpeed = UserDefaults.standard.object(forKey: ROBTorsoControlCenter.speedLimitKey)
        UserDefaults.standard.set(false, forKey: "ROBDevelopmentMode")
        UserDefaults.standard.removeObject(forKey: ROBTorsoControlCenter.speedLimitKey)
        defer {
            if let oldDebug { UserDefaults.standard.set(oldDebug, forKey: "ROBDevelopmentMode") }
            else { UserDefaults.standard.removeObject(forKey: "ROBDevelopmentMode") }
            if let oldSpeed { UserDefaults.standard.set(oldSpeed, forKey: ROBTorsoControlCenter.speedLimitKey) }
            else { UserDefaults.standard.removeObject(forKey: ROBTorsoControlCenter.speedLimitKey) }
        }
        let fake = FixtureMotor()
        let vision = ROBMarkerlessVisionService(resources: nil)
        let center = ROBTorsoControlCenter(transport: ROBTicVelocityTransport(execute: fake.execute), vision: vision,
            reference: ["modelID": "test-model", "referenceID": "test-reference"])
        if CommandLine.arguments.contains("--show") {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            center.showControls(nil)
            app.activate(ignoringOtherApps: true)
            app.run()
            return
        }
        let originalBodyIdentity=ROBFixedHeadBodyMotionIdentity.currentIdentity
        center.advance(); center.arm(); center.turnToHeading(45)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try expect(center.commandedVelocity > 0 && fake.calls.isEmpty, "Rehearsal touched motor transport")
        try expect(ROBFixedHeadBodyMotionIdentity.currentIdentity==originalBodyIdentity,"Rehearsal invalidated physical registration")
        center.setLiveCamera(true)
        try expect(!center.isArmed && !center.canArm, "Preview observation leaked into live authority")
        center.arm()
        try expect(fake.calls.isEmpty, "Missing camera evidence reached motor preflight")

        var wrong = observation(); wrong["modelID"] = "other-model"
        center.acceptObservation(wrong)
        try expect(!center.canArm, "Mismatched model was accepted")
        center.acceptObservation(observation(age: 2))
        try expect(!center.canArm, "Stale camera frame was accepted")
        center.acceptObservation(observation())
        try expect(center.canArm && abs(center.observedHeading - 180 / .pi) < 0.01,
                   "Camera yaw did not replace the debug reference")
        ROBArmRoutineCoordinator.shared.torsoRotationBlockReason = "Raise the hanging left arm first"
        center.arm()
        try expect(!center.canArm && !center.isArmed && fake.calls.isEmpty,
                   "A hanging arm reached torso motor preflight")
        ROBArmRoutineCoordinator.shared.torsoRotationBlockReason = nil
        ROBArmRoutineCoordinator.shared.ownsPhysicalMotion = true
        center.arm()
        try expect(!center.isArmed && fake.calls.isEmpty, "Torso activated during arm clearance ownership")
        ROBArmRoutineCoordinator.shared.ownsPhysicalMotion = false
        center.acceptObservation(observation(sequence: 2))
        center.arm(); try wait { center.isArmed && center.hardwareReady }
        try expect(!fake.energized && !fake.calls.contains(where: { $0.contains("--energize") }),
                   "Arming the coordinator energized an idle motor")
        try expect(ROBFixedHeadBodyMotionIdentity.currentIdentity==originalBodyIdentity,"Idle arming invalidated physical registration")
        center.setRemoteActive(true, rotation: 0.1)
        let remoteTarget = 180 / Double.pi + 18
        try expect(abs(center.targetHeading - remoteTarget) < 0.01,
                   "VR heading was not based on the camera angle")
        try wait { fake.currentVelocity < 0 }
        try expect(ROBFixedHeadBodyMotionIdentity.currentIdentity != originalBodyIdentity,"Physical torso dispatch retained old camera-to-base registration")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        try expect(center.isArmed && center.policy.mode == .heading && abs(center.targetHeading - remoteTarget) < 0.01,
                   "Motor power acknowledgement reset the active heading request")
        center.setRemoteActive(false, rotation: 0)
        try expect(center.policy.mode == .hold, "VR release retained motion")
        try wait { !fake.energized }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        try expect(center.isArmed && center.hardwareReady && abs(center.targetHeading - remoteTarget) < 0.01,
                   "Ordinary idle power release dropped arming or reset the target")
        let wakeCount = fake.calls.filter { $0.contains("--energize") }.count
        center.acceptObservation(observation(sequence: 3))
        center.turnToHeading(180 / .pi + 5)
        try wait { fake.currentVelocity < 0 }
        try expect(fake.calls.filter { $0.contains("--energize") }.count == wakeCount + 1,
                   "The coordinator could not resume after an idle power release")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try expect(center.isArmed && center.policy.mode == .heading,
                   "Returning to chat cancelled an explicitly started finite turn")
        ROBArmRoutineCoordinator.shared.torsoRotationBlockReason = "Arm clearance lost during turn"
        center.advance()
        try expect(!center.isArmed, "Torso kept turning after an arm left its raised hold")
        try wait { !fake.energized }
        ROBArmRoutineCoordinator.shared.torsoRotationBlockReason = nil
        center.acceptObservation(observation(sequence: 4))
        center.arm(); try wait { center.isArmed && center.hardwareReady }
        center.turnToHeading(180 / .pi + 5)
        try wait { fake.currentVelocity < 0 }
        center.acceptObservation(observation(sequence: 5, camera: "belly", confirmed: false))
        try expect(center.isArmed, "An unavailable alternate camera erased fresh accepted evidence")
        let stoppedAt = fake.calls.count
        center.acceptObservation(observation(sequence: 5, confirmed: false))
        try expect(!center.isArmed && !center.canArm, "Failed accepted camera retained authority")
        try wait { !fake.energized }
        try expect(fake.calls.dropFirst(stoppedAt).contains(where: { $0.contains("--enter-safe-start") }) &&
                   fake.calls.dropFirst(stoppedAt).contains(where: { $0.contains("--deenergize") }),
                   "Visual-loss stop did not stop and release the energized motor")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try expect(center.status.contains("failed validation"), "Stop acknowledgement hid the visual failure reason")

        center.acceptObservation(observation(sequence: 5, yaw: -1))
        try expect(center.canArm && !center.isArmed, "New camera observation automatically resumed motion")
        center.setLiveCamera(false); center.advance()
        // Switching away from hardware finishes an explicit stop, even if the
        // motor was energized by another app. Drain that before rehearsal.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let count = fake.calls.count
        center.arm(); center.setLever(-0.5, held: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        center.releaseLever(); center.closeControls()
        try expect(fake.calls.count == count, "Returning to rehearsal wrote to the motor")
        center.setCountEstimate()
        try wait { center.currentCount == 1000 && center.canArm }
        try expect(!center.usesLiveCamera && center.navigationHeading.isNaN && !fake.energized,
            "Selecting count estimates fabricated measured alignment or energized the motor")
        let beforeReference = fake.calls.count
        center.setSoftwareReference(0)
        try wait { abs(center.observedHeading)<0.001 && center.hasSoftwareBaseReference }
        try expect(center.countReference==1000 && center.navigationHeading==0,
            "Software alignment did not bind the current stationary count to physical base front")
        try expect(!fake.calls.dropFirst(beforeReference).contains(where: {$0.contains("--halt-and-set-position") || $0.contains("--home") || $0.contains("--energize")}),
            "Software reference changed hardware position or moved the torso")
        ROBArmRoutineCoordinator.shared.torsoRotationBlockReason = "Raise both arms"
        center.arm()
        try expect(!center.isArmed, "Count control bypassed both-arm tread clearance")
        try wait { center.canEnergize }
        _ = NSApplication.shared
        let window = ROBTorsoControlWindowController(center: center)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let controls = views(window.window!.contentView!)
        func control<T: NSView>(_ identifier: String, as type: T.Type) throws -> T {
            guard let control = controls.first(where: { $0.accessibilityIdentifier() == identifier }) as? T else {
                throw NSError(domain: "TorsoUIFixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing control \(identifier)"])
            }
            return control
        }
        let slider = try control("ROB.Torso.CalibratedCountRange", as: NSSlider.self)
        let countField = try control("ROB.Torso.TargetCount", as: NSTextField.self)
        let headingField = try control("ROB.Torso.TargetHeading", as: NSTextField.self)
        let turn = try control("ROB.Torso.Turn", as: NSButton.self)
        let energize = try control("ROB.Torso.Energize", as: NSButton.self)
        let deenergize = try control("ROB.Torso.Deenergize", as: NSButton.self)
        let lever = try control("ROB.Torso.Velocity", as: NSSlider.self)
        let powerLabel = try control("ROB.Torso.MotorPower", as: NSTextField.self)
        slider.doubleValue = center.count(forHeading: 45)
        _ = slider.sendAction(slider.action, to: slider.target)
        try expect(slider.isContinuous && abs(headingField.doubleValue-45)<0.01 && abs(countField.doubleValue-slider.doubleValue)<0.51,
            "Dragging the native count slider did not update the destination fields")
        try expect(fake.currentVelocity == 0 && !center.isArmed && !lever.isEnabled,
            "Editing a preview target moved or armed the hanging-arm robot")
        // First AppKit initialization can outlast the feedback budget on a
        // loaded build host. Await a new real fixture sample before clicking.
        try wait { energize.isEnabled && deenergize.isEnabled }
        // Serial preflight takes several USB commands. Its own fresh status
        // must survive an idle poll waiting >500 ms behind zero-speed setup.
        fake.commandDelay = 0.15
        _ = energize.sendAction(energize.action, to: energize.target)
        try wait { center.powerHoldRequested && center.hardwareReady && fake.energized && powerLabel.stringValue.contains("Motor ENERGIZED") }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        try expect(fake.energized && fake.currentVelocity == 0 && !center.isArmed && !lever.isEnabled,
            "Explicit power hold dropped out or bypassed rotation clearance")
        try expect(powerLabel.stringValue.contains("current count 1000"), "Native UI omitted actual controller feedback")
        _ = deenergize.sendAction(deenergize.action, to: deenergize.target)
        try wait { !fake.energized && !center.powerHoldRequested && powerLabel.stringValue.contains("DE-ENERGIZED") }
        fake.commandDelay = 0
        try expect(!center.isArmed, "De-energize left rotation armed")
        ROBArmRoutineCoordinator.shared.torsoRotationBlockReason = nil
        try wait { center.canEnergize }
        center.energize(); try wait { center.hardwareReady && fake.energized }
        fake.commandDelay = 0.15
        center.arm(); try wait { center.isArmed }
        fake.commandDelay = 0
        try expect(fake.energized && center.powerHoldRequested, "Arming rotation discarded an explicit powered hold")
        let trackingDeadline = Date().addingTimeInterval(0.8)
        while Date() < trackingDeadline {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
        }
        try expect(center.isArmed && fake.energized,
                   "Menu/slider tracking starved TIC feedback: \(center.status)")
        let beforePositionTurn = fake.calls.count
        let nativeGoal = String(Int32(center.count(forHeading: 90).rounded()))
        center.turnToHeading(90); try wait { fake.currentVelocity<0 }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try expect(center.isArmed && center.policy.mode == .heading, "Focus loss interrupted a native position turn")
        try wait { center.policy.mode == .hold && fake.currentVelocity == 0 }
        let nativeTurnCalls = Array(fake.calls.dropFirst(beforePositionTurn))
        try expect(nativeTurnCalls.contains(where: { $0.prefix(2) == ["--position", nativeGoal] }),
                   "TIC count heading did not dispatch its target position")
        try expect(!nativeTurnCalls.contains(where: { args in
            guard let i = args.firstIndex(of: "--velocity") else { return false }
            return args[i+1] != "0"
        }), "Mac velocity corrections interfered with TIC position braking")
        try expect(center.isArmed && abs(center.observedHeading-90)<0.02,
                   "Count turn did not arrive: heading=\(center.observedHeading), status=\(center.status), calls=\(nativeTurnCalls)")
        let fineTarget = Int32(center.currentCount) - 5
        countField.stringValue = String(fineTarget)
        _ = countField.sendAction(countField.action, to: countField.target)
        _ = turn.sendAction(turn.action, to: turn.target)
        try wait { center.currentCount == Double(fineTarget) && center.policy.mode == .hold }
        try expect(fake.calls.contains(where: { $0.prefix(2) == ["--position", String(fineTarget)] }),
                   "Native count entry was rounded through the degree display before dispatch")
        center.setLever(0.2, held: true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try expect(!center.isArmed, "Held manual speed input survived focus loss")
        try wait { !fake.energized }
        center.closeControls()
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "ROBDevelopmentMode")
        center.advance()
        try expect(ROBArmFeedbackTiming.maximumAgeMilliseconds == 1200, "Fixture must exercise the enlarged arm-feedback budget")
        try expect(center.policy.maximumControlInterval == 0.5, "Debug UI retained the250ms torso limit")
        center.setLiveCamera(false); center.advance()
        try expect(center.policy.maximumControlInterval == 0.5, "Changing torso source lost the500ms debug budget")
        center.arm(); center.turnToHeading(center.observedHeading + 20)
        try wait { center.isArmed && center.commandedVelocity > 0 }
        try expect(center.policy.mode == .heading, "The arm-feedback budget invalidated a fresh torso turn")
        center.stop()
        UserDefaults.standard.set(false, forKey: "ROBDevelopmentMode"); center.advance()
        try expect(center.policy.maximumControlInterval == 0.25, "Normal torso mode kept the debug allowance")
        center.closeControls()
        #endif
        center.setMaximumPulseRate(3000)
        try expect(abs(center.maximumPulseRate-3000)<1e-8 && !center.isArmed, "Pulse-rate change did not stop and save the limit")
        center.setCountEstimate()
        try expect(abs(center.maximumPulseRate-3000)<1e-8, "Switching to TIC silently reset the speed limit")
        center.closeControls()
        let restored = ROBTorsoControlCenter(transport: ROBTicVelocityTransport(execute: FixtureMotor().execute),
            vision: ROBMarkerlessVisionService(resources: nil))
        try expect(abs(restored.maximumPulseRate-3000)<1e-8, "Relaunch lost the selected pulse ceiling")
        restored.setMaximumPulseRate(3001)
        try expect(abs(restored.maximumPulseRate-3000)<1e-8, "Overspeed setting was accepted")
        restored.closeControls()
        try localTakeover()
        try idleReferenceReacquisition()
        print("Torso coordinator passed: exact TIC targets and five-pulse UI edits, no host position hunting, focus rules, persisted pulse ceiling, rehearsal isolation, camera gates, idle arming, camera-referenced VR, target-preserving power updates, idle release/resume, visual-loss power release, explicit re-arm")
    }

    static func idleReferenceReacquisition() throws {
        let motor = FixtureMotor()
        let transport = ROBTicVelocityTransport(execute: motor.execute)
        let center = ROBTorsoControlCenter(transport: transport, vision: ROBMarkerlessVisionService(resources: nil),
            reference: ["modelID": "test-model", "referenceID": "test-reference"])
        center.setCountEstimate(); try wait { center.canSetSoftwareReference }
        center.closeControls()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func sample(_ uptime: Double) -> ROBTicVelocityTransport.PositionSample {
            .init(count: 1000, velocity: 0, uncertain: true, capturedAt: ProcessInfo.processInfo.systemUptime,
                  energized: false, operationState: "De-energized", serialNumber: "fixture", uptimeSeconds: uptime)
        }
        transport.onPosition?(sample(100))
        center.setSoftwareReference(0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        transport.onPosition?(sample(101))
        let commands = motor.calls.count
        // Deliberately pause this isolated main-thread fixture. No live USB,
        // timers or hardware workers are used for the resulting samples.
        Thread.sleep(forTimeInterval: 0.9)
        transport.onPosition?(sample(102))
        try expect(center.hasSoftwareBaseReference && center.navigationHeading == 0 && !center.isArmed,
            "A stopped unchanged same-boot TIC sample erased the observed software reference")
        try expect(!motor.calls.dropFirst(commands).contains(where: { $0.contains("--position") || $0.contains("--energize") }),
            "Idle reference reacquisition dispatched movement or energized the motor")
        Thread.sleep(forTimeInterval: 0.9)
        transport.onPosition?(sample(0))
        try expect(!center.hasSoftwareBaseReference && !center.isArmed,
            "A rebooted controller retained the previous physical reference")
        center.closeControls()
    }

    static func localTakeover() throws {
        let motor = FixtureMotor()
        let center = ROBTorsoControlCenter(transport: ROBTicVelocityTransport(execute: motor.execute),
            vision: ROBMarkerlessVisionService(resources: nil),
            reference: ["modelID": "test-model", "referenceID": "test-reference"])
        defer { center.closeControls(); ROBArmRoutineCoordinator.shared.ownsPhysicalMotion = false }
        center.setCountEstimate(); try wait { center.canArm }
        try expect(!center.isArmed && center.canUseLocalControls, "Local lever still requires the Arm button")
        center.setLever(0.25, held: true)
        try wait { motor.currentVelocity < 0 }
        try expect(center.isLocalLeverHeld && center.isArmed, "Local drag did not preflight and start directly")
        center.releaseLever(); try wait { !motor.energized && motor.currentVelocity == 0 }

        center.stop(); try wait { center.canArm }
        motor.commandDelay = 0.08
        let before = motor.calls.count
        center.setLever(-0.25, held: true)
        try wait { motor.calls.dropFirst(before).contains(where: { $0.contains("--get-settings") }) }
        center.releaseLever()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        try expect(!center.isArmed && !motor.energized && !motor.calls.dropFirst(before).contains(where: { args in
            if args.contains("--position") { return true }
            guard let i = args.firstIndex(of: "--velocity") else { return false }
            return args[i+1] != "0"
        }), "Released preflight produced a delayed movement")
        motor.commandDelay = 0
        try wait { center.canArm }

        // Main-view takeover synchronously stops the center; owner cleanup can
        // finish later. The new demand must survive only while still held.
        ROBArmRoutineCoordinator.shared.ownsPhysicalMotion = true
        var takeovers = 0
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("ROBLocalManualControlRequested"),
            object: center, queue: .main) { _ in
                takeovers += 1; center.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    ROBArmRoutineCoordinator.shared.ownsPhysicalMotion = false
                }
            }
        center.setLever(-0.25, held: true)
        try expect(motor.currentVelocity == 0, "Manual control moved before ownership handoff")
        try wait { motor.currentVelocity > 0 }
        try expect(takeovers == 1, "Manual drag did not notify automatic owners exactly once")
        NotificationCenter.default.removeObserver(observer)
        center.releaseLever(); try wait { !motor.energized }

        center.setLiveCamera(true); center.acceptObservation(observation())
        center.arm(); try wait { center.isArmed }
        center.setRemoteActive(true, rotation: 0.1); try wait { motor.currentVelocity < 0 }
        center.acceptObservation(observation(sequence: 2))
        center.setLever(-0.25, held: true); try wait { motor.currentVelocity > 0 }
        center.setRemoteActive(true, rotation: 0.1)
        try expect(center.policy.mode == .velocity, "Remote demand stole control during a local drag")
        center.releaseLever()
        center.setRemoteActive(true, rotation: 0.1)
        try expect(center.policy.mode == .hold, "Old remote demand resumed after local release")
        center.stop(); try wait { !motor.energized }
        print("Local torso takeover passed: no Arm prerequisite, release cancels preflight, owner handoff, remote override and no remote replay")
    }
}

private final class FixtureMotor {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var measuredPosition: Int32 = 1000
    private var positionTarget: Int32?
    private var isEnergized = false
    private var safeStart = true
    private var measuredVelocity: Int32 = 0
    private var delay = 0.0
    var commandDelay: Double {
        get { lock.lock(); defer { lock.unlock() }; return delay }
        set { lock.lock(); delay = newValue; lock.unlock() }
    }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var energized: Bool { lock.lock(); defer { lock.unlock() }; return isEnergized }
    var currentVelocity: Int32 { lock.lock(); defer { lock.unlock() }; return measuredVelocity }
    func execute(_ args: [String]) throws -> String {
        let delay = commandDelay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); defer { lock.unlock() }
        recorded.append(args)
        if args.first == "--get-settings" {
            try "product: 36v4\ncontrol_mode: serial\nstep_mode: 1\nsoft_error_response: decel_to_hold\ndisable_safe_start: false\ncommand_timeout: 1000\n"
                .write(toFile: args[1], atomically: true, encoding: .utf8)
        }
        if let index = args.firstIndex(of: "--velocity"), index + 1 < args.count,
           let velocity = Int32(args[index + 1]), velocity == 0 || (isEnergized && !safeStart) {
            measuredVelocity = velocity; positionTarget = nil
        }
        if args.contains("--energize") { isEnergized = true }
        if args.contains("--exit-safe-start") { safeStart = false }
        if let index = args.firstIndex(of: "--position"), isEnergized && !safeStart {
            positionTarget = Int32(args[index+1])
        }
        if args.contains("--status"), let target = positionTarget, isEnergized && !safeStart {
            // Deterministic controller progress within the host's continuity
            // bound. Position control finishes without a host velocity command.
            measuredPosition += min(500, max(-500, target-measuredPosition))
            measuredVelocity = measuredPosition == target ? 0 : (target > measuredPosition ? 1_000_000 : -1_000_000)
        }
        if args.contains("--enter-safe-start") { safeStart = true; measuredVelocity = 0 }
        if args.contains("--deenergize") { isEnergized = false; measuredVelocity = 0 }
        var errors: [String] = []
        if !isEnergized { errors.append("Intentionally de-energized") }
        if safeStart { errors.append("Safe start violation") }
        return """
        Name: Tic 36v4 High-Power Stepper Motor Controller
        VIN voltage: 24 V
        Homing active: No
        Step mode: Full step
        Operation state: \(isEnergized && !safeStart ? "Normal" : "Soft error")
        Energized: \(isEnergized ? "Yes" : "No")
        Current velocity: \(measuredVelocity)
        Current position: \(measuredPosition)
        Position uncertain: Yes
        Errors currently stopping the motor:\(errors.isEmpty ? " None" : "\n" + errors.map { "  - " + $0 }.joined(separator: "\n"))
        Errors that occurred since last check: None

        """
    }
}
