import AppKit
import SwiftUI

// This executable contains no serial, network, or real camera implementation.
struct CameraDepthFrame {
    func distanceMillimeters(x: Int, y: Int) -> UInt16? { 1500 }
}
final class ROBBubbleRuntime {
    static let shared = ROBBubbleRuntime()
    struct LaserFrame {
        let id: UUID
        let capturedDate: Date
        let png: Data
        let width: Int
        let height: Int
        let pan: Int
        let tilt: Int
        let panChannel: Int
        let tiltChannel: Int
        let neck: [Int]
        let intrinsics: [Double]?
        let depth: CameraDepthFrame?
    }
    var frame: LaserFrame?
    var active = false
    func setLaserCaptureActive(_ active: Bool) { self.active = active }
    func laserCalibrationFrame() -> LaserFrame? { active ? frame : nil }
}
final class ROBPythonRuntime {
    static let shared = ROBPythonRuntime()
    func newTask(withArguments arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments
        return process
    }
}

@main struct BubbleLaserFixtureTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rob-laser-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ROBBubbleLaserCalibrationModel(archiveRoot: root)
        let runtime = ROBBubbleRuntime.shared
        func frame(_ name: String, neck: [Int] = [6000, 6010, 5990]) throws -> ROBBubbleRuntime.LaserFrame {
            ROBBubbleRuntime.LaserFrame(id: UUID(), capturedDate: Date(),
                png: try Data(contentsOf: Bundle.main.url(forResource: name, withExtension: "png")!),
                width: 640, height: 480, pan: 5836, tilt: 5191, panChannel: 7, tiltChannel: 6,
                neck: neck, intrinsics: [550, 550, 320, 240], depth: CameraDepthFrame())
        }
        runtime.frame = try frame("laser-off")
        model.setActive(true)
        model.captureReference()
        precondition(model.reference?.id == runtime.frame?.id)
        for point in [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100),
                      CGPoint(x: 500, y: 350), CGPoint(x: 100, y: 350)] { model.mark(point) }
        runtime.frame = try frame("laser-on", neck: [6100, 6010, 5990])
        model.detect()
        precondition(!model.busy && model.message.contains("head pose"), "A changed neck must require a new reference")
        runtime.frame = try frame("laser-on")
        model.detect()
        let deadline = Date().addingTimeInterval(20)
        while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(!model.busy && model.result?.laser.status == "found", model.message)
        precondition(model.result?.board.corners?.count == 54)
        precondition(model.recordProblem != nil, "A point needs the settled confirmation")
        model.settled = true
        precondition(model.recordProblem == nil, model.recordProblem ?? "")
        let result = model.result!
        precondition(result.recordingProblem(grid: model.grid, target: 0, settled: true) != nil, "A distant target must fail")
        precondition(result.recordingProblem(grid: ROBBubbleLaserGrid(columns: 8), target: model.target, settled: true) != nil)
        if CommandLine.arguments.contains("--show") {
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 790),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ROB Laser Calibration QA — synthetic mat, no hardware"
            window.contentView = NSHostingView(rootView: ROBBubbleLaserCalibrationView(model: model))
            window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
            app.run()
        } else {
            let firstTarget = model.targetStep
            model.record()
            precondition(model.sampleCount == 1 && model.targetStep == firstTarget + 1)
            let folders = try FileManager.default.contentsOfDirectory(at: model.sessionURL, includingPropertiesForKeys: nil)
            precondition(folders.count == 1 && !folders[0].lastPathComponent.hasPrefix(".pending"))
            let sample = folders[0]
            let files = try FileManager.default.contentsOfDirectory(atPath: sample.path)
            precondition(files.count == 6)
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: sample.appendingPathComponent("observation.json"))) as! [String: Any]
            precondition(metadata["pan"] as? Int == 5836 && metadata["tilt"] as? Int == 5191)
            precondition(metadata["neck"] as? [Int] == [6000, 6010, 5990])
            precondition(metadata["laserDepthMM"] as? Int == 1500 && metadata["operatorConfirmedSettled"] as? Bool == true)
            let json = try Data(contentsOf: sample.appendingPathComponent("analysis.json"))
            let base = try JSONSerialization.jsonObject(with: json) as! [String: Any]
            for mode in ["ambiguous", "not_found", "reference_changed", "no_background"] {
                var modified = base
                var laser = base["laser"] as! [String: Any]
                if mode == "no_background" { laser["usedBackground"] = false } else { laser["status"] = mode }
                modified["laser"] = laser
                let rejected = try JSONDecoder().decode(ROBBubbleLaserResult.self, from: JSONSerialization.data(withJSONObject: modified))
                precondition(rejected.recordingProblem(grid: model.grid, target: model.grid.targets[0], settled: true) != nil)
            }
            model.targetStep = firstTarget; model.settled = true
            precondition(model.recordProblem?.contains("already saved") == true)
            model.record(); precondition(model.sampleCount == 1, "A frame must never be recorded twice")
            model.newPose()
            precondition(model.sampleCount == 1 && model.reference == nil && model.markedCorners.isEmpty)
            precondition(FileManager.default.fileExists(atPath: sample.path), "A new pose preserves earlier observations")
            model.setActive(false)
            precondition(!runtime.active)
            print("Laser capture fixtures passed: OpenCV process, pose checks, confirmation, ambiguity, target error, archival images and metadata, duplicate rejection, multi-pose preservation")
        }
    }
}
