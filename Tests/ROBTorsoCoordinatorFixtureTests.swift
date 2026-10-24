import Cocoa
import CoreMedia

struct ROBChessPieceDetection {}
final class ROBArmRoutineCoordinator {
    static let shared = ROBArmRoutineCoordinator()
    var ownsPhysicalMotion = false
}

/// Compiles the real coordinator, views and camera service. The injected Tic
/// executor records calls; it cannot reach USB. --show opens an inert UI fixture.
@main struct ROBTorsoCoordinatorFixtureTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "TorsoCoordinatorFixture", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(condition(), "Coordinator callback timed out")
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
        try wait { fake.currentVelocity > 0 }
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
        try wait { fake.currentVelocity > 0 }
        try expect(fake.calls.filter { $0.contains("--energize") }.count == wakeCount + 1,
                   "The coordinator could not resume after an idle power release")
        center.acceptObservation(observation(sequence: 4, camera: "belly", confirmed: false))
        try expect(center.isArmed, "An unavailable alternate camera erased fresh accepted evidence")
        let stoppedAt = fake.calls.count
        center.acceptObservation(observation(sequence: 4, confirmed: false))
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
        let count = fake.calls.count
        center.arm(); center.setLever(-0.5, held: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        center.releaseLever(); center.closeControls()
        try expect(fake.calls.count == count, "Returning to rehearsal wrote to the motor")
        print("Torso coordinator passed: rehearsal isolation, camera gates, idle arming, camera-referenced VR, target-preserving power updates, idle release/resume, visual-loss power release, explicit re-arm")
    }
}

private final class FixtureMotor {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var isEnergized = false
    private var safeStart = true
    private var measuredVelocity: Int32 = 0
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var energized: Bool { lock.lock(); defer { lock.unlock() }; return isEnergized }
    var currentVelocity: Int32 { lock.lock(); defer { lock.unlock() }; return measuredVelocity }
    func execute(_ args: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        recorded.append(args)
        if args.first == "--get-settings" {
            try "product: 36v4\ncontrol_mode: serial\nstep_mode: 1\nsoft_error_response: decel_to_hold\ndisable_safe_start: false\ncommand_timeout: 1000\n"
                .write(toFile: args[1], atomically: true, encoding: .utf8)
        }
        if let index = args.firstIndex(of: "--velocity"), index + 1 < args.count,
           let velocity = Int32(args[index + 1]), velocity == 0 || (isEnergized && !safeStart) {
            measuredVelocity = velocity
        }
        if args.contains("--energize") { isEnergized = true }
        if args.contains("--exit-safe-start") { safeStart = false }
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
        Position uncertain: Yes
        Errors currently stopping the motor:
        \(errors.isEmpty ? "  None" : errors.map { "  - " + $0 }.joined(separator: "\n"))

        """
    }
}
