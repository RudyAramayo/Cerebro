import Foundation

@main struct ROBTreadMotionRampFixtureTests {
    static func main() {
        for (mode, seconds) in [(0, 2.4), (1, 1.2), (2, 0.6)] {
            let ramp = ROBTreadMotionRamp()
            precondition(ramp.advance(toLeft: 255, right: -255, mode: mode, now: 0))
            precondition(ramp.isStopped, "Press must start from zero")
            var previous = 0
            for tick in 1...Int(seconds / 0.03 + 1) {
                precondition(ramp.advance(toLeft: 255, right: -255, mode: mode, now: Double(tick) * 0.03))
                precondition(ramp.leftCommand >= previous && ramp.rightCommand == -ramp.leftCommand)
                precondition(ramp.leftCommand - previous <= Int(ceil(255 / seconds * 0.03)) + 1)
                if Double(tick) * 0.03 < seconds - 0.01 { precondition(ramp.leftCommand < 255) }
                previous = ramp.leftCommand
            }
            precondition(ramp.leftCommand == 255 && ramp.rightCommand == -255)
        }
        let ramp = ROBTreadMotionRamp()
        var time = 0.0
        func tick(_ target: Int, dt: Double = 0.03) -> Bool {
            time += dt
            return ramp.advance(toLeft: target, right: target, mode: 0, now: time)
        }
        precondition(tick(-102))
        for _ in 0..<5 { precondition(tick(-102)) }
        precondition(abs(ramp.leftCommand) < 20, "Gentle cannot jump to breakaway demand in150ms")
        for _ in 0..<28 { precondition(tick(-102)) }
        precondition(ramp.leftCommand == -102, "40percent demand should be reached in about one second")
        precondition(tick(102) && ramp.leftCommand < 0)
        var sawZero = false
        while ramp.leftCommand <= 0 {
            precondition(tick(102))
            if ramp.leftCommand == 0 { sawZero = true }
        }
        precondition(sawZero, "Reversal must emit zero")
        precondition(tick(0))
        for _ in 0..<40 { precondition(tick(0)) }
        precondition(ramp.isStopped)
        precondition(tick(255))
        precondition(!tick(255, dt: 0.5) && ramp.isStopped, "A stalled host must stop instead of jumping")
        precondition(tick(255) && ramp.isStopped, "A reset must start again from zero")
        precondition(!ramp.advance(toLeft: 255, right: 255, mode: 0, now: .nan) && ramp.isStopped)
        print("Tread ramp fixtures passed: all three timed profiles, slow40percent breakaway ramp, symmetric release, zero-before-reverse, delayed-tick stop and no catch-up jump")
    }
}
