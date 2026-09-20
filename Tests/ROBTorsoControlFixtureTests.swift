import Foundation

@main struct ROBTorsoControlFixtureTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "TorsoFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func sample(_ heading: Double, _ time: Double, _ sequence: UInt64, sigma: Double = 0.1,
                       stream: String = "camera") -> ROBTorsoMotionPolicy.Observation {
        .init(heading: heading, capturedAt: time, uncertainty: sigma, stream: stream, sequence: sequence)
    }
    static func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(condition(), "Asynchronous Tic fixture timed out")
    }
    static func main() throws {
        try expect(ROBTorsoMotionPolicy.wrap(361) == 1 && ROBTorsoMotionPolicy.wrap(-361) == -1, "Circular heading wrap failed")
        var p = ROBTorsoMotionPolicy()
        try expect(!p.arm(at: 10), "Missing camera observation armed")
        p.observe(sample(179, 10, 1), now: 10)
        try expect(p.arm(at: 10), "Fresh camera reference should not require homing")
        p.requestHeading(-179)
        try expect(p.targetHeading == 181 && p.tick(at: 10.05) > 0, "179 to -179 should take the short positive turn")
        p.observe(sample(-179.5, 10.1, 2), now: 10.1)
        try expect(abs((p.unwrappedHeading ?? 0) - 180.5) < 1e-8, "Camera wrap lost continuity")
        p.observe(sample(-100, 10.15, 3), now: 10.15)
        try expect(!p.armed && p.observation?.heading == -100 && p.velocity == 0, "Unexpected camera correction must update pose and stop motion")
        try expect(p.arm(at: 10.15), "Corrected camera pose should support explicit re-arm")
        p.observe(sample(-99, 10.2, 4, stream: "reconnected"), now: 10.2)
        try expect(!p.armed, "Camera source changes must drop authority")

        p = ROBTorsoMotionPolicy()
        p.observe(sample(0, 20, 1), now: 20); _ = p.arm(at: 20); p.requestHeading(45)
        var physical = 0.0, previousVelocity = 0.0, peak = 0.0
        var nearSpeed = Double.infinity
        for i in 1...700 {
            let now = 20 + Double(i) * 0.05
            physical += previousVelocity * 0.05
            p.observe(sample(physical, now, UInt64(i + 1)), now: now)
            let velocity = p.tick(at: now)
            try expect(abs(velocity - previousVelocity) <= p.acceleration * 0.05 + 1e-8, "Acceleration jumped")
            try expect(physical <= 45.1, "Taper overshot the heading")
            peak = max(peak, velocity)
            if 45 - physical < 3 { nearSpeed = min(nearSpeed, abs(velocity)) }
            previousVelocity = velocity
        }
        try expect(abs(45 - physical) <= 0.85 && p.mode == .hold && abs(p.velocity) < 1e-8, "Heading did not settle inside the visual tolerance")
        try expect(peak > 7 && nearSpeed < 1, "Heading should travel briskly and taper near arrival")
        p.requestRate(1)
        let finalTime = 55.0
        _ = p.tick(at: finalTime + 0.05)
        p.requestRate(-1)
        let reversed = p.tick(at: finalTime + 0.1)
        try expect(reversed >= 0, "A direction reversal must first reach zero")
        _ = p.tick(at: finalTime + 1)
        try expect(!p.armed && p.velocity == 0, "Stale vision did not inhibit motion")

        p = ROBTorsoMotionPolicy(); p.observe(sample(0, 60, 1), now: 60); _ = p.arm(at: 60); p.requestRate(1)
        for i in 1...70 {
            let now = 60 + Double(i) * 0.05
            p.observe(sample(0, now, UInt64(i + 1)), now: now)
            _ = p.tick(at: now)
        }
        try expect(!p.armed && p.status.contains("not visually observed"), "A camera-confirmed stall was not reported")
        for rate in [0.1, 1.0] {
            p = ROBTorsoMotionPolicy(); p.observe(sample(0, 80, 1), now: 80); _ = p.arm(at: 80); p.requestRate(rate)
            for i in 1...200 {
                let now = 80 + Double(i) * 0.05
                p.observe(sample(0, now, UInt64(i + 1)), now: now); _ = p.tick(at: now)
            }
            try expect(!p.armed, "A slow unobserved turn kept moving indefinitely")
        }
        p = ROBTorsoMotionPolicy(); p.observe(sample(0, 90, 1), now: 90); _ = p.arm(at: 90); p.requestRate(1)
        physical = 0
        for i in 1...60 {
            let now = 90 + Double(i) * 0.05
            physical -= p.velocity * 0.05
            p.observe(sample(physical, now, UInt64(i + 1)), now: now); _ = p.tick(at: now)
        }
        try expect(!p.armed && p.status.contains("opposite turn"), "Opposite physical motion was not stopped")
        p = ROBTorsoMotionPolicy(); p.observe(sample(0, 70, 1), now: 70); _ = p.arm(at: 70)
        try expect(!p.observe(sample(0, 70.1, 1), now: 70.1), "Replayed sequence accepted")
        try expect(p.observation?.capturedAt == 70, "Replay refreshed camera age")
        p.observe(sample(0, 70.1, 2, sigma: 8), now: 70.1)
        try expect(!p.armed, "Ambiguous yaw retained authority")

        let profile = ROBTicVelocityTransport.Profile()
        try expect(profile.velocityUnits(360.0 / 36800) == 10000, "Tic velocity units are not pulses per 10,000 seconds")
        try expect(profile.accelerationUnits == 81778, "Acceleration conversion is incorrect")
        try expect(profile.velocityUnits(.nan) == nil, "Non-finite velocity accepted")
        try ROBTicVelocityTransport.checkStatus(FakeTic.status(ready: true), starting: false)
        // Position uncertain is valid for camera-referenced velocity operation.
        try ROBTicVelocityTransport.checkStatus(FakeTic.status(ready: false), starting: true)
        var rejected = false
        do { try ROBTicVelocityTransport.checkStatus(FakeTic.status(ready: true, fault: true), starting: false) }
        catch { rejected = true }
        try expect(rejected, "Driver fault was accepted")

        let fake = FakeTic()
        let transport = ROBTicVelocityTransport(execute: fake.execute)
        var ready = false, detail = ""
        transport.onState = { ready = $0; detail = $1 }
        transport.arm(profile: profile)
        try wait { ready }
        for _ in 0..<3 {
            transport.velocity(0, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        try expect(fake.calls.filter { $0 == ["--velocity", "0"] }.count >= 2, "Steady holding demand stopped feeding the watchdog")
        try expect(fake.calls.filter { $0.contains("--exit-safe-start") }.count == 1, "Safe start was cleared repeatedly")
        fake.fault = true
        transport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        transport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { !ready && detail.contains("fault") }
        transport.velocity(2, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try expect(fake.calls.filter { $0.contains("--exit-safe-start") }.count == 1, "Fault auto-resumed motion")
        try expect(!fake.calls.contains(where: { $0.contains("--home") || $0.contains("--halt-and-set-position") || $0.contains("--reset") || $0.contains("-p") }), "Velocity path emitted a home/reset/position command")

        let blocking = FakeTic(); let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let pending = ROBTicVelocityTransport { args in
            if args.first == "--get-settings" { entered.signal(); _ = gate.wait(timeout: .now() + 2) }
            return try blocking.execute(args)
        }
        pending.arm(profile: profile)
        try expect(entered.wait(timeout: .now() + 1) == .success, "Preflight did not start")
        pending.stop(); gate.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try expect(!blocking.calls.contains(where: { $0.contains("--energize") }), "Cancelled preflight still energized")
        print("Torso fixtures passed: circular goals, camera rebase, smooth settling/reversal, stale/replayed/ambiguous evidence, observed stall, units, watchdog, fault latch, cancelled arm, no home or position commands")
    }
}

private final class FakeTic {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var isReady = false
    private var hasFault = false
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var fault: Bool {
        get { lock.lock(); defer { lock.unlock() }; return hasFault }
        set { lock.lock(); hasFault = newValue; lock.unlock() }
    }
    func execute(_ args: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        recorded.append(args)
        if args.first == "--get-settings" {
            try "product: 36v4\ncontrol_mode: serial\nstep_mode: 1\nsoft_error_response: decel_to_hold\ndisable_safe_start: false\ncommand_timeout: 1000\n"
                .write(toFile: args[1], atomically: true, encoding: .utf8)
        }
        if args.contains("--energize") { isReady = true }
        if args.contains("--enter-safe-start") { isReady = false }
        if args == ["--status"] { return Self.status(ready: isReady, fault: hasFault) }
        return ""
    }
    static func status(ready: Bool, fault: Bool = false) -> String {
        """
        Name:                         Tic 36v4 High-Power Stepper Motor Controller
        VIN voltage:                  23.559 V
        Homing active:                No
        Step mode:                    Full step
        Operation state:              \(ready && !fault ? "Normal" : "Soft error")
        Energized:                    \(ready ? "Yes" : "No")
        Position uncertain:           Yes
        Errors currently stopping the motor:
        \(fault ? "  - Motor driver error" : ready ? "  None" : "  - Command timeout\n  - Safe start violation")

        Errors that occurred since last check:
          None
        """
    }
}
