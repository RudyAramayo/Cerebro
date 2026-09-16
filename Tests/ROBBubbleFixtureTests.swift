import Foundation

@main struct BubbleTests {
    static func main() throws {
        func close(_ actual: Double, _ expected: Double, _ message: String) {
            precondition(abs(actual - expected) < 0.000_001, "\(message): \(actual) != \(expected)")
        }

        // Ten minutes of fan-only operation must leave the bubble budget intact.
        var fanOnly = ROBBubbleSafety()
        fanOnly.authorize(at: 0)
        fanOnly.command(.spinOn, at: 0)
        for second in 1...600 { fanOnly.heartbeat(at: Double(second)) }
        precondition(fanOnly.armed && fanOnly.spin && !fanOnly.blower)
        close(fanOnly.remaining(), ROBBubbleSafety.workBudget, "Fan-only time is free")
        close(fanOnly.cooldownRemaining(at: 600), 0, "The fan starts no bubble cooldown")
        fanOnly.command(.spinOff, at: 600)
        fanOnly.heartbeat(at: 601)
        close(fanOnly.used, 0, "The fan's own relay release tail is not bubble work")
        fanOnly.command(.spinOn, at: 601)
        fanOnly.command(.blowerOn, at: 601.49)
        close(fanOnly.used, 0, "A rejected blower start consumes no work time")
        fanOnly.command(.blowerOn, at: 601.5)
        close(fanOnly.used, 0, "Countdown begins at blower ON, after the spin lead")
        fanOnly.heartbeat(at: 602)
        close(fanOnly.used, 0.5, "Only blower runtime counts")
        fanOnly.command(.blowerOff, at: 602)
        fanOnly.heartbeat(at: 603)
        close(fanOnly.used, 1, "The blower release tail counts while the fan stays on")
        precondition(fanOnly.spin && !fanOnly.blower)

        // A nearly spent bubble budget must not shorten the fan's watchdog lease.
        var partial = ROBBubbleSafety()
        partial.authorize(at: 0)
        partial.command(.spinOn, at: 0)
        partial.command(.blowerOn, at: 0.5)
        for step in 2...237 { partial.heartbeat(at: Double(step) / 2) }
        partial.command(.blowerOff, at: 118.5)
        partial.heartbeat(at: 119)
        close(partial.used, 118.5, "Blower work plus its release tail")
        close(partial.shutdownDeadline(at: 119)!, 121, "Fan-only watchdog uses the lease, not remaining bubble time")
        for step in 239...357 {
            let time = Double(step) / 2
            partial.heartbeat(at: time)
            if step == 240 { partial.command(.spinOff, at: time) }
            if step == 241 { partial.command(.spinOn, at: time) }
        }
        close(partial.used, 118.5, "Fan toggles neither consume nor reset bubble work early")
        partial.heartbeat(at: 179)
        precondition(partial.spin && partial.armed)
        close(partial.used, 0, "Sixty seconds with the blower off cools it even with the fan on")

        // STOP must not bypass cooldown if the physical release tail uses the
        // last part of the work budget after authorization has been removed.
        var tail = ROBBubbleSafety()
        tail.authorize(at: 0)
        tail.command(.spinOn, at: 0)
        tail.command(.blowerOn, at: 0.5)
        for step in 2...238 { tail.heartbeat(at: Double(step) / 2) }
        tail.stop(at: 119.5)
        tail.tick(at: 120.1)
        close(tail.used, 119.5, "Release accounting survives disarming")
        close(tail.cooldownRemaining(at: 120.1), 59.9, "Release tail exhaustion starts the required cooldown")
        tail.authorize(at: 140)
        precondition(!tail.armed)
        tail.authorize(at: 180)
        precondition(tail.armed && tail.used == 0)

        var safety = ROBBubbleSafety()
        safety.command(.spinOn, at: 0)
        precondition(!safety.spin, "Unarmed motor request must fail")
        safety.authorize(at: 0)
        safety.command(.blowerOn, at: 0)
        precondition(!safety.blower, "Blower requires spin")
        safety.command(.spinOn, at: 0)
        safety.command(.blowerOn, at: 0.49)
        precondition(!safety.blower)
        safety.command(.blowerOn, at: 0.5)
        precondition(safety.blower)
        safety.command(.spinOff, at: 0.6)
        precondition(!safety.blower && !safety.spin)
        safety.stop(at: 1)
        let previous = safety.used
        safety.authorize(at: 1.1)
        precondition(safety.used >= previous, "Rearming cannot reset heat budget")
        safety.command(.continuous, at: 1.1)
        safety.tick(at: 3.2)
        precondition(!safety.armed && !safety.spin && !safety.blower, "Lease timeout must stop both motors")

        safety = ROBBubbleSafety()
        safety.authorize(at: 0)
        safety.command(.continuous, at: 0)
        for step in 1...1200 {
            let t = Double(step) / 10
            safety.heartbeat(at: t)
            safety.tick(at: t)
        }
        precondition(!safety.armed && !safety.spin && !safety.blower)
        precondition(safety.cooldownRemaining(at: 120) > 59)
        safety.authorize(at: 140)
        precondition(!safety.armed, "Cooldown cannot be bypassed by reauthorization")
        safety.authorize(at: 181)
        precondition(safety.armed && safety.used == 0)

        safety = ROBBubbleSafety()
        safety.authorize(at: 0)
        safety.command(.pulse, at: 0)
        safety.heartbeat(at: 0.5); safety.tick(at: 0.5)
        precondition(safety.blower)
        for step in 6...35 { safety.heartbeat(at: Double(step) / 10) }
        precondition(!safety.blower && !safety.spin)
        for step in 36...85 { safety.heartbeat(at: Double(step) / 10) }
        precondition(safety.spin && !safety.blower)
        safety.heartbeat(at: 9); safety.tick(at: 9)
        precondition(safety.blower)
        close(safety.used, 3.5, "A pulse counts 3 s of bubbles and the 0.5 s blower tail, excluding spin lead")
        safety.forceCooldown(at: 10)
        safety.authorize(at: 10.5)
        precondition(!safety.armed)

        var calibration = ROBBubbleCalibration()
        precondition(calibration.valid && calibration.spinChannel == 8 && calibration.blowerChannel == 9)
        precondition(calibration.wiringConfirmed && calibration.spinOn == 8000 && calibration.blowerOn == 8000)
        let center = calibration.solve(u: 0.5, v: 0.5, width: 641, height: 481,
            depthMeters: 2, fx: 500, fy: 500, cx: 320, cy: 240)!
        precondition(center.pan == 6000 && center.tilt == 6000)
        calibration.mountX = 0.3
        let parallax = calibration.solve(u: 0.5, v: 0.5, width: 641, height: 481,
            depthMeters: 2, fx: 500, fy: 500, cx: 320, cy: 240)!
        precondition(parallax.pan < 6000, "Right shoulder must aim left at camera center")
        let near = calibration.solve(u: 0.5, v: 0.5, width: 641, height: 481,
            depthMeters: 0.5, fx: 500, fy: 500, cx: 320, cy: 240)!
        precondition(near.pan < parallax.pan, "The nearer the person, the larger the parallax correction")
        precondition(calibration.solve(u: .nan, v: 0.5, width: 641, height: 481,
            depthMeters: 2, fx: 500, fy: 500, cx: 320, cy: 240) == nil)
        calibration.yawDegrees = 180
        precondition(calibration.solve(u: 0.5, v: 0.5, width: 641, height: 481,
            depthMeters: 2, fx: 500, fy: 500, cx: 320, cy: 240) == nil)
        calibration = ROBBubbleCalibration(); calibration.spinChannel = 5
        precondition(!calibration.valid, "Old elbow-pan must not become a bubble relay")

        let message = ROBBubbleMessage(controllerID: UUID(), sessionID: UUID(), sequence: 1,
            sentAt: 100, command: .init(.aim, frameID: UUID(), u: 0.25, v: 0.75))
        let roundTrip = try ROBBubbleProtocol.decode(ROBBubbleProtocol.encode(message))
        precondition(roundTrip == message)
        precondition(!ROBBubbleProtocol.isFresh(message, now: 103))
        let invalid = ROBBubbleMessage(controllerID: UUID(), sessionID: UUID(), sequence: 1,
            command: .init(.manual, pan: 0, tilt: 8000))
        do { _ = try ROBBubbleProtocol.encode(invalid); fatalError("Invalid pan accepted") } catch { }
        let release = ROBBubbleMessage(controllerID: UUID(), sessionID: UUID(), sequence: 2, command: .init(.releaseMount))
        _ = try ROBBubbleProtocol.encode(release)
        for operation in [ROBBubbleOperation.authorizeMount, .authorizeMotors] {
            let command = ROBBubbleMessage(controllerID: UUID(), sessionID: UUID(), sequence: 1, command: .init(operation))
            let decoded = try ROBBubbleProtocol.decode(ROBBubbleProtocol.encode(command))
            precondition(decoded == command)
        }
        if CommandLine.arguments.count > 1 {
            let estimate = try ROBBubbleModelEstimate(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            precondition(abs(estimate.right - 0.208) < 0.001)
            precondition(abs(estimate.below - 0.181) < 0.001)
            precondition(abs(estimate.forward + 0.044) < 0.001, "Use unscaled model coordinates, not the 1.2x presentation scale")
        }
        print("Bubble fixtures passed: fan-only budget isolation, blower countdown and tails, watchdog leases, cooldown, interlocks, projection, protocol")
    }
}
