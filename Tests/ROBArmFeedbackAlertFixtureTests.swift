import Foundation

@main struct ArmFeedbackAlertFixtures {
    static let healthy = ROBArmFeedbackAlertPolicy.Sample(controllerAge: 4, jointAges: Array(repeating: 5, count: 7), gripperAge: 6)
    static let wristMissing = ROBArmFeedbackAlertPolicy.Sample(controllerAge: 4, jointAges: [5, 5, 5, 5, .infinity, 2000, .infinity], gripperAge: .infinity)
    static func main() {
        var policy = ROBArmFeedbackAlertPolicy()
        let good = ["left": healthy, "right": healthy]
        let rightBad = ["left": wristMissing, "right": healthy]
        precondition(policy.update(now: 0, ready: false, samples: [:]).isEmpty)
        precondition(policy.update(now: 1, ready: true, samples: [:]).isEmpty)
        precondition(policy.update(now: 3, ready: true, samples: [:]).isEmpty, "Initial ready packet caused a false alarm")
        precondition(policy.update(now: 4, ready: true, samples: good).isEmpty)
        precondition(policy.update(now: 5, ready: true, samples: rightBad).isEmpty)
        precondition(policy.update(now: 5.8, ready: true, samples: rightBad).isEmpty)
        let fault = policy.update(now: 6.1, ready: true, samples: rightBad)
        precondition(fault.count == 1 && fault[0].isFault)
        precondition(fault[0].text.hasPrefix("Right arm feedback lost:"), "Legacy gateway side leaked into speech")
        precondition(fault[0].text.contains("joints 5, 6, 7 and the gripper not responding"))
        for time in [7.0, 8, 30, 60] { precondition(policy.update(now: time, ready: true, samples: rightBad).isEmpty) }
        precondition(policy.update(now: 61, ready: true, samples: good).isEmpty)
        precondition(policy.update(now: 61.8, ready: true, samples: rightBad).isEmpty, "Flapping retriggered speech")
        precondition(policy.update(now: 62, ready: true, samples: good).isEmpty)
        let restored = policy.update(now: 63.1, ready: true, samples: good)
        precondition(restored.count == 1 && !restored[0].isFault && restored[0].text.hasPrefix("Right arm feedback restored."))
        precondition(policy.update(now: 64, ready: true, samples: rightBad).isEmpty)
        precondition(policy.update(now: 65.1, ready: true, samples: rightBad).count == 1, "A new fault episode was silenced")

        var both = ROBArmFeedbackAlertPolicy()
        _ = both.update(now: 0, ready: true, samples: good)
        _ = both.update(now: 3, ready: true, samples: ["left": wristMissing, "right": wristMissing])
        let pair = both.update(now: 4.1, ready: true, samples: ["left": wristMissing, "right": wristMissing])
        precondition(pair.count == 2 && pair[0].text.hasPrefix("Right") && pair[1].text.hasPrefix("Left"))
        precondition(ROBArmFeedbackAlertPolicy.Sample(controllerAge: 999, jointAges: [], gripperAge: 999).issue == "controller telemetry is missing")
        precondition(ROBArmFeedbackAlertPolicy.Sample(controllerAge: 1, jointAges: [], gripperAge: 1).issue == "joint telemetry is incomplete")
        precondition(ROBArmFeedbackAlertPolicy.Sample(controllerAge: .nan, jointAges: [], gripperAge: 1).issue != nil)
        precondition(ROBArmFeedbackAlertPolicy.Sample(controllerAge: 1, jointAges: [-1, 0, 0, 0, 0, 0, 0], gripperAge: 1).issue == "joint 1 not responding")

        var connection = ROBArmFeedbackAlertPolicy()
        _ = connection.update(now: 0, ready: true, samples: good)
        _ = connection.update(now: 3, ready: true, samples: good)
        precondition(connection.update(now: 4, ready: false, samples: [:]).isEmpty)
        let disconnected = connection.update(now: 5.1, ready: false, samples: [:])
        precondition(disconnected.count == 1 && disconnected[0].text.hasPrefix("Arm gateway connection lost."))
        precondition(connection.update(now: 15, ready: false, samples: [:]).isEmpty)
        _ = connection.update(now: 16, ready: true, samples: good)
        _ = connection.update(now: 19, ready: true, samples: good)
        let reconnected = connection.update(now: 20.1, ready: true, samples: good)
        precondition(reconnected.count == 1 && reconnected[0].text.hasPrefix("Arm gateway feedback restored."))
        precondition(connection.update(now: 21, ready: false, intentionalDisconnect: true, samples: [:]).isEmpty)
        precondition(connection.update(now: 30, ready: false, samples: [:]).isEmpty, "Deliberate disconnect announced a fault")
        print("Arm speech alerts passed: physical side, wrist/gripper loss, frozen controller, startup grace, debounce, recovery, repeated episodes, gateway loss and intentional disconnect (no hardware)")
    }
}
