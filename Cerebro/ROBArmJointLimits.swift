import Foundation

/// Raw J1...J7 limits enforced at the authenticated Amber transport boundary.
/// These are vendor coordinates. A URDF/reference conversion may narrow them
/// for a planner, but must never widen the gateway's accepted interval.
enum ROBArmJointLimits {
    static let radians: [ClosedRange<Double>] = [
        -2.4435 ... 2.4435,
        -2.3213 ... 2.3213,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -2.2863 ... 2.2863,
        -3.05 ... 3.05,
    ]
}

/// Host feedback admission uses a bounded commissioning budget only while the
/// DEBUG app's existing Development Mode is enabled. Packet ages remain real.
enum ROBArmFeedbackTiming {
    static var debugEnabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "ROBDevelopmentMode")
        #else
        return false
        #endif
    }
    static var maximumAgeMilliseconds: Double { debugEnabled ? 500 : 250 }
    static var stationaryMaximumAgeMilliseconds: Double { debugEnabled ? 500 : 350 }
}
