import Foundation

/// Local manual tread demand, in the base firmware's signed 0...255 units.
/// This is output shaping, not measured speed or traction control.
@objcMembers final class ROBTreadMotionRamp: NSObject {
    static let accelerationDefaultsKey = "ROBLocalTreadAccelerationMode"
    static let settingsChanged = Notification.Name("ROBLocalTreadAccelerationDidChange")
    static let modeTitles = ["Gentle", "Medium", "Aggressive"]
    static var selectedMode: Int {
        get { min(2, max(0, UserDefaults.standard.integer(forKey: accelerationDefaultsKey))) }
        set {
            UserDefaults.standard.set(min(2, max(0, newValue)), forKey: accelerationDefaultsKey)
            NotificationCenter.default.post(name: settingsChanged, object: nil)
        }
    }
    static func fullScaleSeconds(mode: Int) -> Double {
        [2.4, 1.2, 0.6][min(2, max(0, mode))]
    }

    private var left = 0.0
    private var right = 0.0
    private var lastUpdate: Double?
    var leftCommand: Int { Int(left.rounded()) }
    var rightCommand: Int { Int(right.rounded()) }
    var isStopped: Bool { left == 0 && right == 0 }

    func reset() { left = 0; right = 0; lastUpdate = nil }

    /// A delayed controller tick stops the demand instead of catching up with
    /// a large jump. Direction reversal always emits zero before reversing.
    @objc(advanceToLeft:right:mode:now:)
    func advance(toLeft targetLeft: Int, right targetRight: Int, mode: Int, now: Double) -> Bool {
        guard now.isFinite else { reset(); return false }
        guard let previous = lastUpdate else { lastUpdate = now; return true }
        let elapsed = now - previous
        guard (0...0.25).contains(elapsed) else { reset(); return false }
        lastUpdate = now
        let step = 255 / Self.fullScaleSeconds(mode: mode) * min(elapsed, 0.06)
        func next(_ current: Double, _ requested: Int) -> Double {
            let target = Double(min(255, max(-255, requested)))
            let endpoint = current * target < 0 ? 0 : target
            let delta = endpoint - current
            return abs(delta) <= step ? endpoint : current + (delta > 0 ? step : -step)
        }
        left = next(left, targetLeft); right = next(right, targetRight)
        return true
    }
}
