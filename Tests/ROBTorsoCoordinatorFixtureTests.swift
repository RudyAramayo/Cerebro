import Cocoa
import CoreMedia

struct ROBChessPieceDetection {}

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
        center.advance(); center.arm(); center.turnToHeading(45)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try expect(center.commandedVelocity > 0 && fake.calls.isEmpty, "Rehearsal touched motor transport")
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
        center.arm(); try wait { center.isArmed && center.hardwareReady }
        center.setRemoteActive(true, rotation: 0.1)
        try expect(abs(center.targetHeading - (180 / .pi + 18)) < 0.01,
                   "VR heading was not based on the camera angle")
        center.setRemoteActive(false, rotation: 0)
        try expect(center.policy.mode == .hold, "VR release retained motion")
        center.acceptObservation(observation(sequence: 2, camera: "belly", confirmed: false))
        try expect(center.isArmed, "An unavailable alternate camera erased fresh accepted evidence")
        center.acceptObservation(observation(sequence: 2, confirmed: false))
        try expect(!center.isArmed && !center.canArm, "Failed accepted camera retained authority")
        try wait { fake.calls.contains(["--enter-safe-start"]) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try expect(center.status.contains("failed validation"), "Stop acknowledgement hid the visual failure reason")

        center.acceptObservation(observation(sequence: 3, yaw: -1))
        try expect(center.canArm && !center.isArmed, "New camera observation automatically resumed motion")
        center.setLiveCamera(false); center.advance()
        let count = fake.calls.count
        center.arm(); center.setLever(-0.5, held: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        center.releaseLever(); center.closeControls()
        try expect(fake.calls.count == count, "Returning to rehearsal wrote to the motor")
        print("Torso coordinator passed: rehearsal isolation, model/age gates, camera-referenced VR, alternate-camera handling, visual-loss stop, explicit re-arm")
    }
}

private final class FixtureMotor {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func execute(_ args: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        recorded.append(args)
        if args.first == "--get-settings" {
            try "product: 36v4\ncontrol_mode: serial\nstep_mode: 1\nsoft_error_response: decel_to_hold\ndisable_safe_start: false\ncommand_timeout: 1000\n"
                .write(toFile: args[1], atomically: true, encoding: .utf8)
        }
        return """
        Name: Tic 36v4 High-Power Stepper Motor Controller
        VIN voltage: 24 V
        Homing active: No
        Step mode: Full step
        Operation state: Normal
        Energized: Yes
        Position uncertain: Yes
        Errors currently stopping the motor:
          None

        """
    }
}
