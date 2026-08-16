//
//  ROBSceneProducerFreshness.swift
//  Cerebro
//
//  Monotonic freshness math shared by scene-state producers and diagnostics.
//

import Foundation

public struct ROBSceneProducerFreshness: Sendable, Equatable {
    public static let visualCalibrationMaximumAgeMilliseconds = 500.0

    public let cameraFrameAgeMilliseconds: Double
    public let cameraPoseAgeMilliseconds: Double
    public let armPoseAgeMilliseconds: Double

    /// Injectable monotonic time keeps boundary behavior deterministic in
    /// fixture tests. Missing, nonfinite, or otherwise invalid timestamps are
    /// represented as infinity and therefore fail closed.
    public init(
        cameraFrameUpdateUptime: TimeInterval?,
        cameraPoseUpdateUptime: TimeInterval?,
        armPoseUpdateUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) {
        cameraFrameAgeMilliseconds = Self.ageMilliseconds(
            since: cameraFrameUpdateUptime,
            nowUptime: nowUptime
        )
        cameraPoseAgeMilliseconds = Self.ageMilliseconds(
            since: cameraPoseUpdateUptime,
            nowUptime: nowUptime
        )
        armPoseAgeMilliseconds = Self.ageMilliseconds(
            since: armPoseUpdateUptime,
            nowUptime: nowUptime
        )
    }

    public func allRequiredProducersAreFresh(
        maximumAgeMilliseconds: Double = Self.visualCalibrationMaximumAgeMilliseconds
    ) -> Bool {
        guard maximumAgeMilliseconds.isFinite, maximumAgeMilliseconds >= 0 else {
            return false
        }
        return [
            cameraFrameAgeMilliseconds,
            cameraPoseAgeMilliseconds,
            armPoseAgeMilliseconds,
        ].allSatisfy {
            $0.isFinite && $0 >= 0 && $0 <= maximumAgeMilliseconds
        }
    }

    public static func ageMilliseconds(
        since updateUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Double {
        guard let updateUptime,
              updateUptime.isFinite,
              nowUptime.isFinite,
              updateUptime >= 0,
              nowUptime >= 0,
              updateUptime <= nowUptime else { return .infinity }
        return (nowUptime - updateUptime) * 1_000
    }
}
