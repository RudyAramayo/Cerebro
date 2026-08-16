import Foundation

private enum FixtureFailure: Error {
    case failed(String)
}

@main
struct ROBSceneProducerFreshnessFixtureTests {
    static func main() throws {
        let atBoundary = ROBSceneProducerFreshness(
            cameraFrameUpdateUptime: 99.75,
            cameraPoseUpdateUptime: 99.50,
            armPoseUpdateUptime: 100.0,
            nowUptime: 100.0
        )
        try expect(atBoundary.cameraFrameAgeMilliseconds == 250, "Camera-frame age changed")
        try expect(atBoundary.cameraPoseAgeMilliseconds == 500, "Camera-pose boundary changed")
        try expect(atBoundary.armPoseAgeMilliseconds == 0, "Arm-pose age changed")
        try expect(atBoundary.allRequiredProducersAreFresh(), "The inclusive 500 ms boundary failed")

        let stale = ROBSceneProducerFreshness(
            cameraFrameUpdateUptime: 99.499,
            cameraPoseUpdateUptime: 100,
            armPoseUpdateUptime: 100,
            nowUptime: 100
        )
        try expect(!stale.allRequiredProducersAreFresh(), "A producer older than 500 ms passed")

        let missing = ROBSceneProducerFreshness(
            cameraFrameUpdateUptime: nil,
            cameraPoseUpdateUptime: 100,
            armPoseUpdateUptime: 100,
            nowUptime: 100
        )
        try expect(missing.cameraFrameAgeMilliseconds.isInfinite, "Missing producer did not fail closed")
        try expect(!missing.allRequiredProducersAreFresh(), "Missing producer passed readiness")

        let futureTimestamp = ROBSceneProducerFreshness(
            cameraFrameUpdateUptime: 101,
            cameraPoseUpdateUptime: 101,
            armPoseUpdateUptime: 101,
            nowUptime: 100
        )
        try expect(
            !futureTimestamp.allRequiredProducersAreFresh()
                && futureTimestamp.cameraFrameAgeMilliseconds.isInfinite,
            "A producer timestamp ahead of the monotonic snapshot passed"
        )

        print("ROB scene-producer freshness fixtures passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FixtureFailure.failed(message) }
    }
}
