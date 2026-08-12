import Foundation

@objcMembers public final class ROBSaberTransform: NSObject {
    public let x: Double, y: Double, z: Double
    public let roll: Double, pitch: Double, yaw: Double
    public let duration: TimeInterval

    init(_ x: Double, _ y: Double, _ z: Double, _ roll: Double, _ pitch: Double, _ yaw: Double, _ duration: TimeInterval) {
        self.x = x; self.y = y; self.z = z
        self.roll = roll; self.pitch = pitch; self.yaw = yaw; self.duration = duration
        super.init()
    }

    public var isSafe: Bool {
        [x, y, z, roll, pitch, yaw, duration].allSatisfy(\.isFinite)
            && (-0.18 ... 0.18).contains(x)
            && (-0.38 ... -0.18).contains(y)
            && (0.12 ... 0.38).contains(z)
            && abs(roll) <= 1.2 && (-1.8 ... -0.7).contains(pitch) && abs(yaw) <= 1.0
            && (0.65 ... 2.0).contains(duration)
    }
}

/// Process-local consent. It resets whenever the Stage Show window closes or
/// Cerebro starts, and never comes from a show file or model output.
@objcMembers public final class ROBSaberSafetyGate: NSObject {
    public static let shared = ROBSaberSafetyGate()
    public var isArmed = false
}

@objcMembers public final class ROBSaberChoreographyCatalog: NSObject {
    public static let shared = ROBSaberChoreographyCatalog()

    private struct TrainingProfile {
        let duration: TimeInterval
        let combinations: [[ROBSaberTransform]]
    }

    /// Dynamic training gestures deliberately vary timing and direction while
    /// retaining the same Cartesian envelope and actuator-side validation as
    /// authored Stage Show gestures. Difficulty never changes a hardware or
    /// firmware limit.
    public let trainingGestureNames = [
        "saber.training.beginner",
        "saber.training.intermediate",
        "saber.training.advanced",
        "saber.training.expert"
    ]

    public func transforms(forGesture name: String) -> [ROBSaberTransform]? {
        let guardPose = ROBSaberTransform(0.04, -0.29, 0.27, 0, -1.35, 0, 1.4)
        let readyHigh = ROBSaberTransform(0.02, -0.27, 0.34, 0.25, -1.2, -0.25, 1.1)
        let left = ROBSaberTransform(-0.12, -0.30, 0.27, -0.45, -1.3, -0.55, 0.9)
        let right = ROBSaberTransform(0.14, -0.30, 0.25, 0.45, -1.3, 0.55, 0.9)
        let low = ROBSaberTransform(0.05, -0.31, 0.16, 0.2, -1.5, 0.25, 1.0)
        let salute = ROBSaberTransform(0.01, -0.25, 0.32, 0, -0.95, 0, 1.3)
        let catalog: [String: [ROBSaberTransform]] = [
            "saber.guard": [guardPose],
            "saber.salute": [guardPose, salute, guardPose],
            "saber.horizontal-cut": [readyHigh, left, right, guardPose],
            "saber.diagonal-cut": [readyHigh, left, low, guardPose],
            "saber.parry-left": [guardPose, left, guardPose],
            "saber.parry-right": [guardPose, right, guardPose],
            "saber.flourish": [guardPose, readyHigh, left, right, low, guardPose],
            "saber.safe-return": [guardPose]
        ]
        if let profile = trainingProfile(named: name, guardPose: guardPose) {
            guard let attack = profile.combinations.randomElement() else { return nil }
            let transforms = attack.map {
                ROBSaberTransform($0.x, $0.y, $0.z, $0.roll, $0.pitch, $0.yaw, profile.duration)
            } + [guardPose]
            guard transforms.allSatisfy(\.isSafe), transforms.count <= 6 else { return nil }
            return transforms
        }
        guard let transforms = catalog[name], transforms.allSatisfy(\.isSafe), transforms.count <= 6 else { return nil }
        return transforms
    }

    public func requestedTrainingDuration(forGesture name: String) -> TimeInterval {
        trainingProfile(named: name, guardPose: ROBSaberTransform(0.04, -0.29, 0.27, 0, -1.35, 0, 1.4))?.duration ?? 0
    }

    private func trainingProfile(named name: String, guardPose: ROBSaberTransform) -> TrainingProfile? {
        let leftHigh = ROBSaberTransform(-0.12, -0.29, 0.33, -0.40, -1.20, -0.50, 1)
        let rightHigh = ROBSaberTransform(0.13, -0.29, 0.33, 0.40, -1.20, 0.50, 1)
        let leftMid = ROBSaberTransform(-0.14, -0.30, 0.25, -0.45, -1.32, -0.58, 1)
        let rightMid = ROBSaberTransform(0.15, -0.30, 0.25, 0.45, -1.32, 0.58, 1)
        let leftLow = ROBSaberTransform(-0.10, -0.31, 0.17, -0.25, -1.52, -0.38, 1)
        let rightLow = ROBSaberTransform(0.11, -0.31, 0.17, 0.25, -1.52, 0.38, 1)

        switch name {
        case "saber.training.beginner":
            return TrainingProfile(duration: 1.35, combinations: [
                [guardPose, leftMid], [guardPose, rightMid]
            ])
        case "saber.training.intermediate":
            return TrainingProfile(duration: 1.05, combinations: [
                [leftHigh, rightMid], [rightHigh, leftMid], [guardPose, leftLow], [guardPose, rightLow]
            ])
        case "saber.training.advanced":
            return TrainingProfile(duration: 0.82, combinations: [
                [leftHigh, rightMid, leftLow], [rightHigh, leftMid, rightLow],
                [leftLow, rightHigh, leftMid], [rightLow, leftHigh, rightMid]
            ])
        case "saber.training.expert":
            return TrainingProfile(duration: 0.68, combinations: [
                [leftHigh, rightMid, leftLow, rightHigh], [rightHigh, leftMid, rightLow, leftHigh],
                [leftLow, rightHigh, leftMid, rightLow], [rightLow, leftHigh, rightMid, leftLow]
            ])
        default:
            return nil
        }
    }
}
