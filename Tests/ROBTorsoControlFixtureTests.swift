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
        let echo = try ROBTicVelocityTransport.runCommand(executable: "/bin/echo", arguments: ["torso fixture"], operation: "fixture")
        try expect(echo == "torso fixture\n", "Direct child completion lost output")
        for (program, args, timeout, expected) in [
            ("/usr/bin/false", [String](), 0.4, "Tic unavailable"),
            ("/bin/sleep", ["2"], 0.03, "timed out"),
            ("/usr/bin/yes", ["oversized fixture"], 0.4, "Oversized")
        ] {
            let began = ProcessInfo.processInfo.systemUptime
            var detail = ""
            do { _ = try ROBTicVelocityTransport.runCommand(executable: program, arguments: args, operation: "fixture", timeout: timeout) }
            catch { detail = error.localizedDescription }
            try expect(detail.contains(expected), "Child execution did not report \(expected): \(detail)")
            try expect(ProcessInfo.processInfo.systemUptime-began < 1, "A failed child command blocked the USB queue")
        }
        var calibration = ROBTorsoCountCalibration()
        try expect(calibration.heading(count:-8907)==90 && calibration.heading(count:9091)==(-90) && calibration.count(heading:0)==92,
            "Observed quarter-turn counts are not mapped through midpoint 92")
        try expect(calibration.heading(count:92-35996)==360, "Slipring full turns were clamped to calibration points")
        calibration.align(count:1000,observedHeading:-90)
        try expect(abs(calibration.count(heading:-90)-1000)<1e-8, "Software base alignment did not correct the count offset")
        var cable = ROBTorsoMotionPolicy(); cable.debugCableMode = true
        for i in 0...72 { cable.observe(sample(Double(i)*5,Double(i)*0.1+1,UInt64(i+1)),now:Double(i)*0.1+1) }
        try expect(abs(cable.cableTravelDegrees!-360)<1e-6, "Wrapped heading discarded a debug cable revolution")
        _ = cable.arm(at:8.2); cable.requestHeading(90)
        try expect(cable.targetHeading==90 && cable.tick(at:8.25)<0, "Debug destination added twist instead of reversing the accumulated turn")
        try expect(cable.requestUnwind() && cable.targetHeading==0, "Unwind did not return through the original turn")
        cable.debugCableMode = false; cable.requestHeading(90)
        try expect(cable.targetHeading==450, "Untethered operation lost shortest-route/full-turn behavior")
        cable.observe(sample(0,10,99),now:10)
        cable.debugCableMode = true
        try expect(cable.cableTravelDegrees==nil && !cable.requestUnwind(), "Missing turn history fabricated a known cable reference")
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
        try expect(profile.pulsesPerTurn==35996 && ROBTicVelocityTransport.Profile.observedCenterCount==92,
                   "Operator quarter-turn endpoints lost their scale/midpoint")
        try expect(profile.velocityUnits(360.0 / 35996) == -10000 && profile.velocityUnits(-360.0 / 35996)==10000,
                   "ROB left must decrease TIC counts; units are pulses per10,000seconds")
        try expect(profile.accelerationUnits == 79991, "Acceleration must retain a positive magnitude with negative left polarity")
        try expect(profile.velocityUnits(.nan) == nil, "Non-finite velocity accepted")
        try ROBTicVelocityTransport.checkStatus(FakeTic.status(ready: true), starting: false)
        let healthy = FakeTic.status(ready: true)
        try expect(healthy.contains("Errors currently stopping the motor: None"), "Fixture lost real ticcmd healthy formatting")
        try ROBTicVelocityTransport.checkStatus(healthy.replacingOccurrences(of:
            "Errors currently stopping the motor: None", with: "Errors currently stopping the motor:\n  None"), starting: false)
        for malformed in ["Errors currently stopping the motor:", "Errors currently stopping the motor: None\n  - Motor driver error"] {
            var rejected = false
            do { try ROBTicVelocityTransport.checkStatus(healthy.replacingOccurrences(of:
                "Errors currently stopping the motor: None", with: malformed), starting: false) }
            catch { rejected = true }
            try expect(rejected, "Empty or contradictory current error section was accepted")
        }
        // Match the real ticcmd 1.8.3 section layout (no blank separator).
        let compactStatus = FakeTic.status(ready:false).replacingOccurrences(of:"\n\nErrors that occurred",with:"\nErrors that occurred")
        try ROBTicVelocityTransport.checkStatus(compactStatus,starting:true)
        // Position uncertain is valid for camera-referenced velocity operation.
        try ROBTicVelocityTransport.checkStatus(FakeTic.status(ready: false), starting: true)
        var rejected = false
        do { try ROBTicVelocityTransport.checkStatus(FakeTic.status(ready: true, fault: true), starting: false) }
        catch { rejected = true }
        try expect(rejected, "Driver fault was accepted")

        let powered = FakeTic()
        let powerTransport = ROBTicVelocityTransport(execute: powered.execute)
        var powerReady = false
        var powerSample: ROBTicVelocityTransport.PositionSample?
        powerTransport.onState = { value, _ in powerReady = value }
        powerTransport.onPosition = { powerSample = $0 }
        powerTransport.energize(profile: profile)
        try wait { powerReady && powerSample?.energized == true }
        try expect(powered.currentVelocity == 0 && powered.motionDispatchCount == 0,
            "Explicit Energize moved the torso")
        try expect(powerSample?.count == 0 && powerSample?.velocity == 0,
            "Power hold did not publish actual count and speed")
        for _ in 0..<3 {
            powerTransport.velocity(0, validUntil: ProcessInfo.processInfo.systemUptime + 0.2, releaseWhenStopped: false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        try expect(powered.energized && powerReady, "Explicit powered hold released itself at idle")
        powerTransport.stop()
        try wait { !powerReady && powerSample?.energized == false }
        try expect(!powered.releasedWhileMoving, "De-energize skipped measured rest")

        let external = FakeTic()
        _ = try external.execute(["--velocity", "0", "--energize", "--exit-safe-start"])
        let externalTransport = ROBTicVelocityTransport(execute: external.execute)
        externalTransport.stop()
        try wait { !external.energized }
        try expect(external.calls.contains(["--deenergize"]),
            "De-energize ignored a motor owned by the preceding app")

        let fake = FakeTic()
        let transport = ROBTicVelocityTransport(execute: fake.execute)
        var ready = false
        transport.onState = { value, _ in ready = value }
        transport.onMotionDispatch = { fake.recordMotionDispatch() }
        transport.arm(profile: profile)
        try wait { ready }
        try expect(!fake.energized && !fake.calls.contains(where: { $0.contains("--energize") }),
                   "Arming at rest energized the motor")
        try expect(fake.calls.contains(where: { $0.contains("--deenergize") }),
                   "Arming did not verify a released motor")
        for _ in 0..<3 {
            transport.velocity(0, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        try expect(ready && !fake.energized && !fake.calls.contains(where: { $0.contains("--energize") }),
                   "An idle zero demand energized or disarmed the torso")

        try expect(fake.motionDispatchCount==0,"Idle arming/zero invalidated a measured body frame")
        transport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { fake.currentVelocity < 0 }
        try expect(fake.motionDispatchCount==1,"Actual nonzero Tic dispatch did not invalidate the measured body frame")
        let firstWake = fake.calls.firstIndex(where: { $0.contains("--energize") })!
        let firstMotion = fake.calls.firstIndex(where: { FakeTic.velocity($0).map { $0 != 0 } == true })!
        try expect(FakeTic.velocity(fake.calls[firstWake]) == 0 && fake.calls[firstWake].contains("--exit-safe-start"),
                   "Wake did not clear the old target to zero before energizing")
        try expect(firstWake < firstMotion && fake.calls[(firstWake + 1)..<firstMotion].contains(["--status", "--full"]),
                   "Nonzero movement preceded successful energized status verification")
        try expect(fake.calls[firstMotion].contains("--status") && fake.calls[firstMotion].contains("--full"),
                   "Active velocity dispatch did not return feedback in the same command process")
        let releasedBeforeReversal = fake.calls.filter { $0.contains("--deenergize") }.count
        transport.velocity(0, validUntil: ProcessInfo.processInfo.systemUptime + 0.2, releaseWhenStopped: false)
        try wait { fake.targetVelocity == 0 }
        transport.velocity(-1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { fake.currentVelocity > 0 }
        try expect(fake.energized && fake.calls.filter { $0.contains("--deenergize") }.count == releasedBeforeReversal,
                   "A transient reversal zero unnecessarily released motor power")

        fake.decelerationPolls = 3
        let releaseStart = fake.calls.count
        transport.velocity(0, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { !fake.energized }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        try expect(ready && !fake.releasedWhileMoving, "Idle release dropped authority or removed power before measured zero")
        let releaseCalls = Array(fake.calls.dropFirst(releaseStart))
        let powerOff = releaseCalls.firstIndex(where: { $0.contains("--deenergize") })!
        try expect(releaseCalls[..<powerOff].contains(where: { $0.contains("--enter-safe-start") }) &&
                   releaseCalls[..<powerOff].filter { $0.contains("--status") }.count >= 4,
                   "Idle release did not wait for reported deceleration completion")
        try expect(releaseCalls[..<powerOff].contains(where: { $0.contains("--reset-command-timeout") }),
                   "Deceleration polling stopped renewing the independent watchdog")

        transport.velocity(2, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { fake.currentVelocity < 0 }
        try expect(fake.calls.filter { $0.contains("--energize") }.count == 2,
                   "A new turn did not re-energize after an ordinary idle release")
        transport.stop()
        try wait { !ready && !fake.energized }
        let stoppedCount = fake.calls.count
        transport.velocity(2, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try expect(fake.calls.count == stoppedCount && !fake.releasedWhileMoving,
                   "An explicit stop auto-resumed or released the motor while moving")
        try expect(fake.motionDispatchCount==fake.calls.filter({FakeTic.velocity($0).map({$0 != 0}) == true}).count,
                   "Body invalidation did not exactly match admitted nonzero velocity writes")
        try expect(!fake.movedWithoutPower, "A nonzero demand was sent before the motor was energized and ready")
        try expect(!fake.calls.contains(where: { $0.contains("--home") || $0.contains("--halt-and-set-position") || $0.contains("--reset") || $0.contains("-p") }), "Velocity path emitted a home/reset/position command")

        let faulted = FakeTic()
        let faultTransport = ROBTicVelocityTransport(execute: faulted.execute)
        var faultReady = false, faultDetail = ""
        faultTransport.onState = { faultReady = $0; faultDetail = $1 }
        faultTransport.arm(profile: profile); try wait { faultReady }
        faultTransport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { faulted.currentVelocity < 0 }
        faulted.fault = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.28))
        faultTransport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { !faultReady && faultDetail.localizedCaseInsensitiveContains("fault") }
        try wait { !faulted.energized }
        let faultWakeCount = faulted.calls.filter { $0.contains("--energize") }.count
        faultTransport.velocity(2, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(faulted.calls.filter { $0.contains("--energize") }.count == faultWakeCount,
                   "A driver fault automatically resumed motion")

        let stale = FakeTic()
        let staleTransport = ROBTicVelocityTransport(execute: stale.execute)
        var staleReady = false
        staleTransport.onState = { value, _ in staleReady = value }
        staleTransport.arm(profile: profile); try wait { staleReady }
        staleTransport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime - 1)
        try wait { !staleReady }
        try expect(!stale.calls.contains(where: { $0.contains("--energize") }),
                   "An already expired demand energized the motor")

        let slowWake = FakeTic(), wakeGate = DispatchSemaphore(value: 0), wakeEntered = DispatchSemaphore(value: 0)
        let slowTransport = ROBTicVelocityTransport { args in
            let result = try slowWake.execute(args)
            if args.contains("--energize") { wakeEntered.signal(); _ = wakeGate.wait(timeout: .now() + 2) }
            return result
        }
        var slowReady = false
        slowTransport.onState = { value, _ in slowReady = value }
        slowTransport.arm(profile: profile); try wait { slowReady }
        slowTransport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.04)
        try expect(wakeEntered.wait(timeout: .now() + 1) == .success, "Delayed wake did not begin")
        RunLoop.current.run(until: Date().addingTimeInterval(0.06)); wakeGate.signal()
        try wait { !slowReady && !slowWake.energized }
        try expect(!slowWake.calls.contains(where: { FakeTic.velocity($0).map { $0 != 0 } == true }),
                   "A demand that expired during wake still moved the torso")

        let cancelledWake = FakeTic(), cancelGate = DispatchSemaphore(value: 0), cancelEntered = DispatchSemaphore(value: 0)
        let cancelledTransport = ROBTicVelocityTransport { args in
            let result = try cancelledWake.execute(args)
            if args.contains("--energize") { cancelEntered.signal(); _ = cancelGate.wait(timeout: .now() + 2) }
            return result
        }
        var cancelledReady = false
        cancelledTransport.onState = { value, _ in cancelledReady = value }
        cancelledTransport.arm(profile: profile); try wait { cancelledReady }
        cancelledTransport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try expect(cancelEntered.wait(timeout: .now() + 1) == .success, "Cancelled wake did not begin")
        cancelledTransport.stop(); cancelGate.signal()
        try wait { !cancelledReady && !cancelledWake.energized }
        try expect(!cancelledWake.calls.contains(where: { FakeTic.velocity($0).map { $0 != 0 } == true }),
                   "An in-flight wake moved after Stop revoked its generation")

        let failedRelease = FakeTic()
        let releaseTransport = ROBTicVelocityTransport(execute: failedRelease.execute)
        var releaseReady = false, releaseDetail = ""
        releaseTransport.onState = { releaseReady = $0; releaseDetail = $1 }
        releaseTransport.arm(profile: profile); try wait { releaseReady }
        releaseTransport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { failedRelease.currentVelocity < 0 }
        failedRelease.failDeenergize = true
        releaseTransport.velocity(0, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { !releaseReady }
        try expect(failedRelease.energized && !releaseDetail.isEmpty,
                   "A failed power release was reported as a successful idle state")
        let failedWakeCount = failedRelease.calls.filter { $0.contains("--energize") }.count
        releaseTransport.velocity(2, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(failedRelease.calls.filter { $0.contains("--energize") }.count == failedWakeCount,
                   "A failed power release did not latch motion authority off")
        failedRelease.failDeenergize = false
        releaseTransport.stop(); try wait { !failedRelease.energized }

        let shutdownMotor = FakeTic()
        shutdownMotor.decelerationPolls = 3
        let shutdownTransport = ROBTicVelocityTransport(execute: shutdownMotor.execute)
        var shutdownReady = false
        shutdownTransport.onState = { value, _ in shutdownReady = value }
        shutdownTransport.arm(profile: profile); try wait { shutdownReady }
        shutdownTransport.velocity(1, validUntil: ProcessInfo.processInfo.systemUptime + 0.2)
        try wait { shutdownMotor.currentVelocity < 0 }
        try expect(shutdownTransport.stopAndWait(timeout: 1), "Shutdown exited without confirmed motor power off")
        try expect(!shutdownMotor.energized && !shutdownMotor.releasedWhileMoving,
                   "Shutdown must wait for measured rest and power release without main callbacks")

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
        print("Torso fixtures passed: circular goals, camera gates, taper/reversal, observed stall, zero-before-wake, measured-stop power release, idle resume, watchdog, stale wake, fault/release latches, cancelled arm, no home or position commands")
    }
}

private final class FakeTic {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var motionDispatches=0
    var motionDispatchCount:Int {lock.lock();defer {lock.unlock()};return motionDispatches}
    func recordMotionDispatch() {lock.lock();motionDispatches+=1;lock.unlock()}
    private var isEnergized = false
    private var safeStart = true
    private var measuredVelocity: Int32 = 0
    private var requestedVelocity: Int32 = 0
    private var lastReportedVelocity: Int32 = 0
    private var stoppingPolls = 0
    private var configuredDecelerationPolls = 0
    private var prematureRelease = false
    private var unpoweredMovement = false
    private var blockedDeenergize = false
    private var hasFault = false
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    var energized: Bool { lock.lock(); defer { lock.unlock() }; return isEnergized }
    var currentVelocity: Int32 { lock.lock(); defer { lock.unlock() }; return measuredVelocity }
    var targetVelocity: Int32 { lock.lock(); defer { lock.unlock() }; return requestedVelocity }
    var releasedWhileMoving: Bool { lock.lock(); defer { lock.unlock() }; return prematureRelease }
    var movedWithoutPower: Bool { lock.lock(); defer { lock.unlock() }; return unpoweredMovement }
    var decelerationPolls: Int {
        get { lock.lock(); defer { lock.unlock() }; return configuredDecelerationPolls }
        set { lock.lock(); configuredDecelerationPolls = newValue; lock.unlock() }
    }
    var failDeenergize: Bool {
        get { lock.lock(); defer { lock.unlock() }; return blockedDeenergize }
        set { lock.lock(); blockedDeenergize = newValue; lock.unlock() }
    }
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
        if let velocity = Self.velocity(args) {
            requestedVelocity = velocity
            if velocity == 0 {
                if measuredVelocity != 0 { stoppingPolls = configuredDecelerationPolls }
                if stoppingPolls == 0 { measuredVelocity = 0 }
            } else if isEnergized && !safeStart {
                measuredVelocity = velocity; stoppingPolls = 0
            } else { unpoweredMovement = true }
        }
        if args.contains("--energize") { isEnergized = true }
        if args.contains("--exit-safe-start") { safeStart = false }
        if args.contains("--enter-safe-start") {
            safeStart = true; requestedVelocity = 0
            if measuredVelocity != 0 { stoppingPolls = configuredDecelerationPolls }
            if stoppingPolls == 0 { measuredVelocity = 0 }
        }
        if args.contains("--deenergize") {
            if measuredVelocity != 0 || lastReportedVelocity != 0 { prematureRelease = true }
            if blockedDeenergize {
                throw NSError(domain: "FakeTic", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Injected deenergize failure; motor power remains on"])
            }
            isEnergized = false; requestedVelocity = 0; measuredVelocity = 0
        }
        if args.contains("--status") {
            if safeStart || requestedVelocity == 0 {
                if stoppingPolls > 0 { stoppingPolls -= 1 }
                else { measuredVelocity = 0 }
            }
            lastReportedVelocity = measuredVelocity
            return Self.status(ready: isEnergized, fault: hasFault, currentVelocity: measuredVelocity, safeStart: safeStart)
        }
        return ""
    }
    static func velocity(_ args: [String]) -> Int32? {
        guard let index = args.firstIndex(of: "--velocity"), index + 1 < args.count else { return nil }
        return Int32(args[index + 1])
    }
    static func status(ready: Bool, fault: Bool = false, currentVelocity: Int32 = 0,
                       safeStart: Bool? = nil) -> String {
        let safeStart = safeStart ?? !ready
        var errors: [String] = []
        if fault { errors.append("Motor driver error") }
        if !ready { errors.append("Intentionally de-energized") }
        if safeStart { errors.append("Safe start violation") }
        return """
        Name:                         Tic 36v4 High-Power Stepper Motor Controller
        VIN voltage:                  23.559 V
        Homing active:                No
        Step mode:                    Full step
        Operation state:              \(ready && !fault && !safeStart ? "Normal" : "Soft error")
        Energized:                    \(ready ? "Yes" : "No")
        Current velocity:             \(currentVelocity)
        Current position:             0
        Position uncertain:           Yes
        Errors currently stopping the motor:\(errors.isEmpty ? " None" : "\n" + errors.map { "  - " + $0 }.joined(separator: "\n"))
        Errors that occurred since last check: None
        """
    }
}
