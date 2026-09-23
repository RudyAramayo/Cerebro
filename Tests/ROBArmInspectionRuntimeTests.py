#!/usr/bin/env python3
"""Exercise the production vision inspector with synthetic frames and an inert model.

No robot, camera device, GPU model, controller grant or motor API is used.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
vision = (ROOT / 'Cerebro/ROBArmRoutineVision.swift').read_text()
engine = (ROOT / 'Cerebro/ROBMLXRuntime.swift').read_text()
engine_method = engine[engine.index('    func observeArmWorkspace<Evidence>'):engine.index('    /// Accepts at most one selected frame')]
assert engine_method.index('beginGPUOperation()') < engine_method.index('loadVLM()') < engine_method.index('frameProvider()')
assert 'frame.evidence' in engine_method

support = r'''
import AppKit
import AVFoundation

enum ROBArmRoutineError: LocalizedError {
    case blocked(String)
    var errorDescription: String? { if case .blocked(let value) = self { return value }; return nil }
}
enum CameraRole: String { case face, belly }
enum CameraSource { case depthAIService }
struct FixtureDepth {
    let width = 640, height = 400
    func distanceMillimeters(x: Int, y: Int) -> UInt16? { 1500 }
}
struct CameraFrameSet {
    let capturedAtMilliseconds: Double?
    let sequence: UInt64
    let source = CameraSource.depthAIService
    let alignedDepth: FixtureDepth?
    let rgbSampleBuffer: CMSampleBuffer
}
struct ROBArmDemonstrationSample {
    let sequence: UInt64
    let capturedAt: Double
    let elevation, bodyCenterX, bodyCenterY, torsoHeight: Double
}
@MainActor final class ROBMLXEngine {
    static let shared = ROBMLXEngine()
    var calls = 0
    var gateDelay: UInt64 = 0
    var delay: UInt64 = 240_000_000
    var changed: ((Int) -> Void)?
    var replies: [String] = []
    var sequencesAtGate: [UInt64] = []
    var formatRetries: [Bool] = []
    func observeArmWorkspace<Evidence>(target: String, grippers: Bool = true, formatRetry: Bool = false,
        frameProvider: () async throws -> (jpeg: Data, evidence: Evidence)
    ) async throws -> (raw: String, evidence: Evidence) {
        try await Task.sleep(nanoseconds: gateDelay)
        sequencesAtGate.append(ROBArmRoutineVision.shared.snapshot()["face"]?.sequence ?? 0)
        let frame = try await frameProvider()
        precondition(!frame.jpeg.isEmpty)
        calls += 1
        formatRetries.append(formatRetry)
        changed?(calls)
        try await Task.sleep(nanoseconds: delay)
        return (replies[min(calls - 1, replies.count - 1)], frame.evidence)
    }
}
'''
fixtures = r'''
extension ROBArmRoutineVision {
    func fixtureFrame(sequence: UInt64, value: UInt8, age: Double = 0, coverage: Double = 1, hands: Bool = true) {
        let pixel = CGFloat(value) / 255
        let image = CIImage(color: CIColor(red: pixel, green: pixel, blue: pixel)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
        var thumbnail = [UInt8](repeating: value, count: 64 * 48 * 4)
        for i in stride(from: 3, to: thumbnail.count, by: 4) { thumbnail[i] = 255 }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        frames["face"] = Frame(image: image, capturedAt: Date().timeIntervalSince1970 * 1000 - age,
            sequence: sequence, handsClear: hands, depthCoverage: coverage, thumbnail: thumbnail, demonstration: nil)
    }
}
@MainActor final class Feed {
    var sequence: UInt64 = 0
    var value: UInt8 = 40
    var age = 0.0, coverage = 1.0
    var paused = false, changing = false, hands = true
    var task: Task<Void, Never>?
    func start() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused {
                    self.sequence += 1
                    // Avoid a two-colour alias when a loaded test host skips
                    // every other frame; every adjacent sample still changes.
                    if self.changing { self.value = UInt8((self.sequence % 7) * 40) }
                    ROBArmRoutineVision.shared.fixtureFrame(sequence: self.sequence, value: self.value,
                        age: self.age, coverage: self.coverage, hands: self.hands)
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}
@main struct Tests {
    @MainActor static func reply(clear: Bool, confidence: Double = 0.99) -> String {
        let observation: [String: Any] = ["pathVisible": clear, "pathClear": clear, "hanging": true, "armsInFront": true,
            "leftJawEmpty": true, "rightJawEmpty": true, "leftObjectBetweenJaws": false, "rightObjectBetweenJaws": false,
            "leftJawOpen": true, "rightJawOpen": true, "leftJawClosedOnObject": false, "rightJawClosedOnObject": false,
            "handsClear": true, "confidence": confidence]
        return String(data: try! JSONSerialization.data(withJSONObject: observation), encoding: .utf8)!
    }
    @MainActor static func run(_ name: String, blocked: String? = nil,
        configure: (Feed, ROBMLXEngine) -> Void = { _, _ in }, verify: (ROBArmRoutineObservation?, ROBMLXEngine) -> Void = { _, _ in }) async {
        let vision = ROBArmRoutineVision.shared, engine = ROBMLXEngine.shared
        vision.setActive(true)
        let feed = Feed()
        engine.calls = 0; engine.gateDelay = 0; engine.delay = 240_000_000; engine.changed = nil
        engine.replies = [reply(clear: true)]; engine.sequencesAtGate = []; engine.formatRetries = []
        configure(feed, engine)
        feed.start()
        defer { feed.stop(); vision.setActive(false) }
        do {
            let result = try await vision.observe(target: "fixture")
            precondition(blocked == nil, "Expected blocked: \(name)")
            verify(result, engine)
        } catch {
            guard let blocked else { fatalError("\(name): \(error)") }
            let detail = error.localizedDescription
            precondition(detail.lowercased().contains(blocked.lowercased()), "\(name): unexpected error \(detail)")
            verify(nil, engine)
        }
        print("Arm inspection: \(name) passed")
    }
    @MainActor static func main() async {
        ROBArmObservationCodecFixtures.run()
        await run("GPU wait selects only new settled frames", configure: { _, engine in
            engine.gateDelay = 500_000_000
        }, verify: { result, engine in
            let health = ROBArmRoutineVision.shared.healthSnapshot()["inspection"] as! [String: Any]
            precondition((health["source_sequence"] as! NSNumber).uint64Value > engine.sequencesAtGate[0])
            precondition(result?.permitsMotion == true && engine.calls == 1)
        })
        await run("settling transient does not reuse a pre-settle frame", configure: { feed, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                feed.value = 180
            }
        }, verify: { _, engine in precondition(engine.calls == 1) })
        await run("changed scene requires a new model answer", configure: { feed, engine in
            engine.changed = { call in if call == 1 { feed.value = 180 } }
            engine.replies = [reply(clear: true), reply(clear: false)]
        }, verify: { result, engine in
            precondition(engine.calls == 2 && result?.permitsMotion == false, "An old clear answer authorized a new scene")
        })
        await run("continuous changes cannot retry forever", blocked: "second camera inspection", configure: { feed, engine in
            engine.changed = { _ in feed.value = feed.value == 40 ? 180 : 40 }
        }, verify: { _, engine in precondition(engine.calls == 2) })
        await run("unsettled view never reaches the model", blocked: "did not settle", configure: { feed, _ in
            feed.changing = true
        }, verify: { _, engine in precondition(engine.calls == 0) })
        await run("stale frames cannot settle", blocked: "did not settle", configure: { feed, _ in feed.age = 900 })
        await run("missing depth cannot settle", blocked: "did not settle", configure: { feed, _ in feed.coverage = 0.1 })
        await run("frozen stream cannot validate model output", blocked: "stopped advancing", configure: { feed, engine in
            engine.changed = { _ in feed.paused = true }
        })
        await run("an expired inspection image is rejected", blocked: "timed out", configure: { _, engine in
            engine.delay = 8_100_000_000
        })
        await run("Markdown wrapper preserves all facts without another model call", configure: { _, engine in
            engine.replies = ["```json\n" + reply(clear: true) + "\n```"]
        }, verify: { result, engine in precondition(result?.permitsMotion == true && engine.calls == 1) })
        await run("unreadable answer retries once with a new independent assessment", configure: { _, engine in
            engine.replies = ["not JSON", reply(clear: false)]
        }, verify: { result, engine in
            precondition(result?.permitsMotion == false && engine.calls == 2 && engine.formatRetries == [false, true])
            precondition(engine.sequencesAtGate[1] > engine.sequencesAtGate[0])
        })
        await run("unreadable answers cannot authorize or retry forever", blocked: "automatic retry also failed", configure: { _, engine in
            engine.replies = ["not JSON"]
        }, verify: { _, engine in
            precondition(engine.calls == 2)
            let health = ROBArmRoutineVision.shared.healthSnapshot()["inspection"] as! [String: Any]
            precondition(health["response_error"] as? String == "invalid_json")
            precondition(health["response_sample"] as? String == "not JSON")
        })
        await run("negative assessment is never retried for a favourable answer", configure: { _, engine in
            engine.replies = [reply(clear: false), reply(clear: true)]
        }, verify: { result, engine in precondition(result?.permitsMotion == false && engine.calls == 1) })
        await run("low confidence is never retried for approval", configure: { _, engine in
            engine.replies = [reply(clear: true, confidence: 0.5), reply(clear: true)]
        }, verify: { result, engine in precondition(result?.permitsMotion == false && engine.calls == 1) })
        await run("conflicting keys cannot authorize or retry", blocked: "conflicting", configure: { _, engine in
            engine.replies = [reply(clear: true).replacingOccurrences(of: "{", with: "{\"pathClear\":false,")]
        }, verify: { _, engine in precondition(engine.calls == 1) })
        await run("scene and format failures share a two-attempt limit", blocked: "second camera inspection", configure: { feed, engine in
            engine.replies = ["not JSON", reply(clear: true)]
            engine.changed = { call in if call == 2 { feed.value = 180 } }
        }, verify: { _, engine in precondition(engine.calls == 2) })
        await run("a new camera epoch cannot accept an old answer", blocked: "cancel", configure: { _, engine in
            engine.changed = { _ in ROBArmRoutineVision.shared.setActive(false) }
        })
        await run("hand veto is preserved", configure: { feed, _ in feed.hands = false }, verify: { _, _ in
            precondition(!ROBArmRoutineVision.shared.handsClear)
        })
        precondition(ROBArmRoutineVision.sceneChangeFraction([], []) == nil)
        precondition(ROBArmRoutineVision.sceneChangeFraction([1], [1]) == nil)
        let dark = [UInt8](repeating: 0, count: 64 * 48 * 4)
        precondition(ROBArmRoutineVision.sceneChangeFraction(dark, dark) == 0)
        precondition(ROBArmRoutineVision.sceneChangeFraction(dark, dark.map { $0 + 25 }) == 1)
        print("Arm inspection runtime and GPU ordering checks passed; no hardware access")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='rob-arm-inspection-') as temporary:
    folder = Path(temporary)
    source = folder / 'Inspection.swift'
    source.write_text(support + vision + fixtures)
    executable = folder / 'inspection-fixture'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-module-cache-path', '/private/tmp/cerebro-swift-module-cache',
                    str(ROOT / 'Cerebro/ROBArmRoutinePlan.swift'), str(ROOT / 'Tests/ROBArmObservationCodecFixtureTests.swift'),
                    str(source), '-o', str(executable)], check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=60)
