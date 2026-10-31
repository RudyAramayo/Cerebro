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

/// Local animation/CLI motion is commissioned separately from incremental
/// remote-controller targets. A faster cap never skips measured settling.
enum ROBArmAnimationTiming {
    static let maximumAverageSpeedRadiansPerSecond = 0.30
}

/// Physical L10 ↔ R11 pose mapping shared by both UI directions and ready
/// planning. This commissioning candidate retains J5's encoder sign and
/// reverses the other six joints. Startup zero offsets remain unverified;
/// the operator-adjusted hold is not proof of this mapping at other poses.
/// Units are preserved; no driver or encoder-zero change is made here.
@objcMembers final class ROBArmPoseMirror: NSObject {
    static func mirroredJointValues(_ values: [NSNumber]) -> [NSNumber]? {
        guard values.count == 7, values.allSatisfy({ $0.doubleValue.isFinite }) else { return nil }
        return values.enumerated().map { index, value in
            NSNumber(value: value.doubleValue * (index == 4 ? 1 : -1))
        }
    }
}

/// Editable position controls show accepted command targets, seeded once
/// from fresh feedback after launch. Telemetry redraws never erase a draft.
@objcMembers final class ROBArmPositionControlState: NSObject {
    static var maximumFeedbackAgeMilliseconds: Double { ROBArmFeedbackTiming.maximumAgeMilliseconds }
    private var displayed = false
    private var lastTarget: [Double]?
    private var draft: [Double]?

    func noteEditedSliderValues(_ values: [NSNumber]) {
        guard values.count == 7, values.allSatisfy({ $0.doubleValue.isFinite }) else { return }
        draft = values.map { $0.doubleValue / 100 }
    }

    func nextSliderValues(targetRadians: [NSNumber], measuredRadians: [NSNumber], feedbackFresh: Bool) -> [NSNumber]? {
        let target = targetRadians.map(\.doubleValue), measured = measuredRadians.map(\.doubleValue)
        let targetValid = target.count == 7 && target.allSatisfy(\.isFinite)
        if let draft {
            guard targetValid, zip(draft, target).allSatisfy({ abs($0-$1) <= 0.000001 }) else { return nil }
            self.draft = nil
        }
        if targetValid {
            guard !displayed || target != lastTarget else { return nil }
            displayed = true; lastTarget = target
            return target.map { NSNumber(value: $0 * 100) }
        }
        guard !displayed, feedbackFresh, measured.count == 7, measured.allSatisfy(\.isFinite) else { return nil }
        displayed = true
        return measured.map { NSNumber(value: $0 * 100) }
    }
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
    static let debugMaximumAgeMilliseconds: Double = 1200
    static var maximumAgeMilliseconds: Double { debugEnabled ? debugMaximumAgeMilliseconds : 250 }
    static var stationaryMaximumAgeMilliseconds: Double { debugEnabled ? debugMaximumAgeMilliseconds : 350 }
}

/// Camera exposure age, independent of current motor-feedback admission.
/// Rudy's debugging budget applies only in a DEBUG build with Development Mode.
/// Preserve original capture times and reserve 150 ms for image analysis.
struct ROBVisionFrameAgeBudget {
    static func limit(normal:Double)->Double {ROBArmFeedbackTiming.debugEnabled ? 1200:normal}
    static var maximumAgeMilliseconds:Double {limit(normal:700)}
    static func acceptsIngress(ageMilliseconds:Double)->Bool {
        (0...(maximumAgeMilliseconds-150)).contains(ageMilliseconds)
    }
    static func acceptsPublication(ageMilliseconds:Double)->Bool {
        (0...maximumAgeMilliseconds).contains(ageMilliseconds)
    }
    static func acceptsAnalysisOpportunity(active:Bool,busy:Bool,elapsedSeconds:Double)->Bool {
        active && !busy && elapsedSeconds >= 0.1
    }
}
