#!/usr/bin/env python3
"""Run the production seed-capture callback across slow detector inference."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STUBS = r'''
import Foundation
enum ROBGhostMotionError: Error { case blocked(String) }
struct ROBFixedHeadRegistrationScope: Codable { let body: String }
struct ROBGhostRobotModel { static func hash(_ bytes: Data) -> String { bytes.base64EncodedString() } }
struct ROBWorkspaceVisualCalibrationTrial {
    let receiptID = "real-test-receipt"
    let usesOperatorClearedCameraCollisionAdvisory = true
}
struct ROBWorkspaceLocatedObject {}
struct ROBWorkspaceCollisionSnapshot {}
struct ROBAmberGatewayTelemetry {
    var sampleAgeAtReceiptMilliseconds = 10.0
    var effectiveSampleAgeMilliseconds = 20.0
    var positionsRadians = Array(repeating: NSNumber(value: 0), count: 7)
}
enum ROBArmFeedbackTiming { static let maximumAgeMilliseconds = 500.0 }
enum ROBGripperVisualServo {
    struct Frame {
        let sequence: UInt64
        let capturedAtMilliseconds: Double
        let scopeIdentity: String
        let jointsCapturedAt: Double
    }
}
@MainActor final class ROBFixedHeadCalibrationWindowController {
    static let shared = ROBFixedHeadCalibrationWindowController()
    var body = "held-body"
    func scope(model: ROBGhostRobotModel, frame: ROBArmRoutineVision.Frame) throws -> ROBFixedHeadRegistrationScope {
        .init(body: body)
    }
}
@MainActor final class ROBArmRoutineVision {
    struct Frame { var sequence: UInt64 = 1; var capturedAt = Date().timeIntervalSince1970 * 1000 - 20; var source = "original-source" }
    static let shared = ROBArmRoutineVision()
    var input = Frame()
    var changeSource = false
    var duringInference: () -> Void = {}
    var captureCalls = 0
    func observeWorkspace(onCaptured: (Frame) async throws -> Void) async throws -> (Int, Frame) {
        let source = input
        try await onCaptured(source)
        duringInference()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        var returned = source
        if changeSource { returned.source = "replacement-source" }
        return (0, returned)
    }
    func makeGripperVisualServoFrame(frame: Frame, scopeIdentity: String, jointPositions: [Double],
        jointCapturedAtMilliseconds: Double, poseHeldDuringCapture: Bool, openingCommandAtMilliseconds: Double?,
        nowMilliseconds: Double, cameraCollisionAdvisoryTrial: ROBWorkspaceVisualCalibrationTrial?) throws -> ROBGripperVisualServo.Frame {
        // Inert pixel adapter enforces the production capture boundary's age
        // contract. The real callback/helper below chooses when it is called.
        guard (0...700).contains(nowMilliseconds - frame.capturedAt),
              abs(jointCapturedAtMilliseconds - frame.capturedAt) <= 150 else { throw ROBGhostMotionError.blocked("stale capture") }
        captureCalls += 1
        return .init(sequence: frame.sequence, capturedAtMilliseconds: frame.capturedAt,
                     scopeIdentity: scopeIdentity, jointsCapturedAt: jointCapturedAtMilliseconds)
    }
}
'''
TESTS = r'''
@main struct Fixtures {
    @MainActor static func main() async throws {
        let vision = ROBArmRoutineVision.shared
        let model = ROBGhostRobotModel(), trial = ROBWorkspaceVisualCalibrationTrial()
        var stopped = false
        func run() async throws -> ROBGripperVisualServo.Frame {
            try await Capture.beginIncrementalVisualServo(model: model, can: .init(), map: .init(), trial: trial,
                gatewayArm: "left", feedbackForFrame: { _ in .init() }, check: {
                    if stopped { throw ROBGhostMotionError.blocked("Stop") }
                })
        }
        vision.input = .init()
        let exposure = vision.input.capturedAt
        let seed = try await run()
        precondition(vision.captureCalls == 1 && seed.capturedAtMilliseconds == exposure)
        precondition(Date().timeIntervalSince1970 * 1000 - seed.capturedAtMilliseconds > 1000)
        precondition(abs(seed.jointsCapturedAt - exposure) < 150, "Inference freshened held feedback")
        vision.input = .init(); vision.input.capturedAt -= 900
        do { _ = try await run(); preconditionFailure("Stale source accepted") } catch {}
        vision.input = .init(); vision.changeSource = true
        do { _ = try await run(); preconditionFailure("Replacement source inherited retained appearance") } catch {}
        vision.changeSource = false; vision.input = .init()
        vision.duringInference = { stopped = true }
        do { _ = try await run(); preconditionFailure("Stop during inference was ignored") } catch {}
        print("Grasp appearance passed: actual production callback captures before1.1s inference, preserves exposure/joint clocks, rejects stale source, source substitution and Stop")
    }
}
'''


def main():
    source = (ROOT / "Cerebro/ROBRecyclingVisualInspection.swift").read_text()
    start = source.index("    private static func incrementalCanViewIdentity")
    end = source.index("        let controller=ROBFixedHeadCalibrationWindowController.shared,scope=", start)
    production = source[start:end]
    guard_start = source.index("        guard let seedPixels=capturedAppearance", end)
    guard_end = source.index("        // The seed retains", guard_start)
    production += "        let scope=try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:reference)\n"
    production += "        let view=try incrementalCanViewIdentity(scope:scope,trial:trial,frame:reference)\n"
    production += source[guard_start:guard_end] + "        _ = observation\n        return seedPixels\n    }\n"
    wrapper = "@MainActor enum Capture {\n typealias ServoContext = ROBGripperVisualServo.Frame\n"
    wrapper += "static func visualFrameContract(_ frame:ROBArmRoutineVision.Frame)throws->String {frame.source}\n"
    with tempfile.TemporaryDirectory(prefix="rob-grasp-seed-") as folder:
        path = Path(folder)
        swift = path / "Capture.swift"
        swift.write_text(STUBS + wrapper + production + "}\n" + TESTS)
        binary = path / "fixture"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)], check=True, timeout=45)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
