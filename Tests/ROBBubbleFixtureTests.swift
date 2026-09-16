import Foundation

@main struct BubbleTests {
    static func main() throws {
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
        precondition(safety.used >= 4, "Relay release tail contributes to heat budget")
        safety.forceCooldown(at: 10)
        safety.authorize(at: 10.5)
        precondition(!safety.armed)

        var calibration = ROBBubbleCalibration()
        precondition(calibration.valid && calibration.spinChannel == 8 && calibration.blowerChannel == 9)
        let center = calibration.solve(u: 0.5, v: 0.5, width: 641, height: 481,
            depthMeters: 2, fx: 500, fy: 500, cx: 320, cy: 240)!
        precondition(center.pan == 6000 && center.tilt == 6000)
        calibration.mountX = 0.3
        let parallax = calibration.solve(u: 0.5, v: 0.5, width: 641, height: 481,
            depthMeters: 2, fx: 500, fy: 500, cx: 320, cy: 240)!
        precondition(parallax.pan < 6000, "Right shoulder must aim left at camera center")
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
        print("Bubble fixtures passed: interlocks, relay delay, lease, cumulative duty, cooldown, projection, protocol")
    }
}
