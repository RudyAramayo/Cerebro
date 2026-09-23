import AppKit
import AVFoundation
import Vision

/// A separate camera consumer, independent of preview/detector preferences.
/// Inference observes the scene; the fixed local routine owns all actuation.
final class ROBArmRoutineVision {
    static let shared = ROBArmRoutineVision()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "rob.arm-routine.vision", qos: .userInitiated)
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private var active = false
    private var teaching = false
    private var epoch = UUID()
    private var busy: Set<String> = []
    private var lastOffer: [String: TimeInterval] = [:]
    private var inputNotes: [String: String] = [:]
    private var lastIncomingCapture: Double?
    private var lastIncomingSequence: UInt64 = 0
    private var processingMilliseconds: Double = 0
    private var frames: [String: Frame] = [:]
    private var lastInspection: [String: Any] = [:]

    struct Frame {
        let image: CIImage
        let capturedAt: Double
        let sequence: UInt64
        let handsClear: Bool
        let depthCoverage: Double
        let thumbnail: [UInt8]
        let demonstration: ROBArmDemonstrationSample?
    }

    func setActive(_ value: Bool, teaching: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        active = value; self.teaching = teaching; epoch = UUID(); frames = [:]; busy = []; lastOffer = [:]; inputNotes = [:]
        lastIncomingCapture = nil; lastIncomingSequence = 0; processingMilliseconds = 0
        if value { lastInspection = [:] }
    }

    func offer(_ frame: CameraFrameSet, role: CameraRole) {
        // Main face camera owns live clearance. A stale belly stream must not
        // delay it or contribute pixels to a supposedly current observation.
        guard role == .face else { return }
        let key = role.rawValue, now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if active {
            lastIncomingCapture = frame.capturedAtMilliseconds.flatMap { $0.isFinite ? $0 : nil }
            lastIncomingSequence = frame.sequence
        }
        guard active, !busy.contains(key), now - (lastOffer[key] ?? 0) >= 0.2 else { lock.unlock(); return }
        // Only admitted work spends the sampling interval. A stale or invalid
        // input must not suppress the next fresh RGB-D frame for another 200 ms.
        guard frame.source == .depthAIService, let depth = frame.alignedDepth else {
            inputNotes[key] = "synchronized depth is unavailable"; lock.unlock(); return
        }
        guard let captured = frame.capturedAtMilliseconds, captured.isFinite else {
            inputNotes[key] = "capture time is unavailable"; lock.unlock(); return
        }
        let age = Date().timeIntervalSince1970 * 1000 - captured
        guard (0 ... 400).contains(age) else {
            inputNotes[key] = "incoming frame is \(String(format: "%.0f", age)) ms old"; lock.unlock(); return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(frame.rgbSampleBuffer) else {
            inputNotes[key] = "RGB pixels are unavailable"; lock.unlock(); return
        }
        inputNotes[key] = "processing RGB-D frame"
        let token = epoch
        let needsBody = teaching && key == "face"
        busy.insert(key); lastOffer[key] = now
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let image = CIImage(cvPixelBuffer: pixels)
            let hands = VNDetectHumanHandPoseRequest()
            hands.maximumHandCount = 6
            let people = VNDetectHumanRectanglesRequest()
            people.upperBodyOnly = true
            let body = VNDetectHumanBodyPoseRequest()
            var demonstration: ROBArmDemonstrationSample?
            var clear = false
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixels).perform(needsBody ? [hands, people, body] : [hands, people])
                if needsBody, let observations = body.results, observations.count == 1,
                   let points = try? observations[0].recognizedPoints(.all) {
                    let names: [VNHumanBodyPoseObservation.JointName] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftWrist, .rightWrist]
                    if names.allSatisfy({ points[$0].map { $0.confidence >= 0.65 } == true }),
                       let ls = points[.leftShoulder], let rs = points[.rightShoulder],
                       let lh = points[.leftHip], let rh = points[.rightHip],
                       let lw = points[.leftWrist], let rw = points[.rightWrist] {
                        let shoulder = (ls.location.y + rs.location.y) / 2
                        let hip = (lh.location.y + rh.location.y) / 2
                        if shoulder - hip > 0.12, abs(ls.location.x - rs.location.x) > 0.08 {
                            let wrist = (lw.location.y + rw.location.y) / 2
                            demonstration = .init(sequence: frame.sequence, capturedAt: captured,
                                elevation: min(1, max(0, Double((wrist - hip) / (shoulder - hip)))),
                                bodyCenterX: Double((ls.location.x + rs.location.x + lh.location.x + rh.location.x) / 4),
                                bodyCenterY: Double((shoulder + hip) / 2), torsoHeight: Double(shoulder - hip))
                        }
                    }
                }
                // A visible hand is a veto regardless of whether it has depth.
                // Unknown depth must not make fingers safe to close around.
                clear = !(hands.results ?? []).contains { $0.confidence >= 0.3 }
                for person in people.results ?? [] where person.confidence >= 0.4 {
                    let box = person.boundingBox
                    var distances: [UInt16] = []
                    for dx in [0.3, 0.5, 0.7] {
                        for dy in [0.3, 0.5, 0.7] {
                            let x = Int((box.minX + box.width * dx) * Double(depth.width))
                            let y = Int((1 - box.minY - box.height * dy) * Double(depth.height))
                            if let mm = depth.distanceMillimeters(x: x, y: y), mm > 0 { distances.append(mm) }
                        }
                    }
                    if distances.isEmpty || distances.min()! < 1200 { clear = false }
                }
            } catch { clear = false }
            var valid = 0, total = 0
            for y in stride(from: 0, to: depth.height, by: 12) {
                for x in stride(from: 0, to: depth.width, by: 12) {
                    total += 1
                    if let mm = depth.distanceMillimeters(x: x, y: y), (100 ... 6000).contains(mm) { valid += 1 }
                }
            }
            // Materialize a small immutable frame; do not retain recyclable
            // capture buffers while the VLM waits for the shared GPU gate.
            let scale = 640 / image.extent.width
            let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let immutable = self.context.createCGImage(resized, from: resized.extent)
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.epoch == token else { return }
            self.busy.remove(key)
            self.processingMilliseconds = (ProcessInfo.processInfo.systemUptime - now) * 1000
            guard let immutable else { return }
            var thumbnail = [UInt8](repeating: 0, count: 64 * 48 * 4)
            let small = CIImage(cgImage: immutable).transformed(by:
                CGAffineTransform(scaleX: 64 / CGFloat(immutable.width), y: 48 / CGFloat(immutable.height)))
            thumbnail.withUnsafeMutableBytes { bytes in
                self.context.render(small, toBitmap: bytes.baseAddress!, rowBytes: 64 * 4,
                    bounds: CGRect(x: 0, y: 0, width: 64, height: 48), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            self.frames[key] = Frame(image: CIImage(cgImage: immutable), capturedAt: captured,
                                     sequence: frame.sequence, handsClear: clear,
                                     depthCoverage: Double(valid) / Double(max(1, total)), thumbnail: thumbnail,
                                     demonstration: demonstration)
        }
    }

    func snapshot() -> [String: Frame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    var demonstrationSample: ROBArmDemonstrationSample? { snapshot()["face"]?.demonstration }

    var fresh: Bool {
        snapshot()["face"].map(isFresh) ?? false
    }

    var handsClear: Bool {
        guard let frame = snapshot()["face"] else { return false }
        return isFresh(frame) && frame.handsClear
    }

    var readinessDescription: String {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970 * 1000
        return ["face"].map { key in
            let name = key == "face" ? "Forward camera" : "Belly camera"
            guard let frame = frames[key] else { return "\(name): \(inputNotes[key] ?? "no frames received")" }
            return "\(name): \(Int(now - frame.capturedAt)) ms old, \(Int(frame.depthCoverage * 100))% usable depth, analysis \(Int(processingMilliseconds)) ms"
        }.joined(separator: "; ")
    }

    /// Read-only evidence for rehearsal and failure reports. Capture and
    /// analysis ages stay separate; a recent callback never freshens old pixels.
    func healthSnapshot() -> NSDictionary {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970 * 1000
        let frame = frames["face"]
        return ["active": active, "input_sequence": NSNumber(value: lastIncomingSequence),
                "input_age_ms": lastIncomingCapture.map { now - $0 } ?? -1,
                "analysis_age_ms": frame.map { now - $0.capturedAt } ?? -1,
                "analysis_ms": processingMilliseconds, "depth_coverage": frame?.depthCoverage ?? 0,
                "hands_clear": frame?.handsClear ?? false, "note": inputNotes["face"] ?? "No frames received",
                "inspection": lastInspection]
    }

    private func isFresh(_ frame: Frame) -> Bool {
        (0 ... 700).contains(Date().timeIntervalSince1970 * 1000 - frame.capturedAt)
            && frame.depthCoverage >= 0.25
    }

    private func inspectionEpoch() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
        return epoch
    }

    private func inspectionFrame(epoch token: UUID) throws -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard active, epoch == token else { throw CancellationError() }
        return frames["face"]
    }

    private func recordInspection(_ details: [String: Any]) {
        lock.lock(); lastInspection = details; lock.unlock()
    }

    // Preserve the existing veto exactly. This is not a clearance classifier;
    // no brightness compensation, image registration or relaxed threshold can
    // hide an object or viewpoint change from the semantic freshness check.
    static func sceneChangeFraction(_ before: [UInt8], _ after: [UInt8]) -> Double? {
        guard before.count == 64 * 48 * 4, before.count == after.count else { return nil }
        let changed = zip(before, after).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 24 ? 1 : 0) }
        return Double(changed) / Double(before.count)
    }

    private func settledInspectionFrame(epoch token: UUID) async throws -> Frame {
        // Called only when the coordinator has stopped motion and the GPU is
        // ready. A previously captured frame may still depict the neck/arms
        // settling, even though the latest commanded pose is now stationary.
        let notBefore = Date().timeIntervalSince1970 * 1000
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var anchor: Frame?, previous: Frame?
        var distinctSamples = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let frame = try inspectionFrame(epoch: token), isFresh(frame), frame.capturedAt >= notBefore {
                if let previous, frame.sequence < previous.sequence || frame.capturedAt < previous.capturedAt {
                    throw ROBArmRoutineError.blocked("The camera stream restarted during inspection.")
                }
                if previous?.sequence != frame.sequence {
                    guard let difference = Self.sceneChangeFraction(anchor?.thumbnail ?? frame.thumbnail, frame.thumbnail) else {
                        throw ROBArmRoutineError.blocked("The inspected camera view is unavailable.")
                    }
                    if anchor == nil || difference >= 0.025 ||
                        previous.map({ frame.capturedAt - $0.capturedAt > 700 }) == true {
                        anchor = frame; distinctSamples = 0
                    }
                    distinctSamples += 1
                    previous = frame
                    if let anchor, distinctSamples >= 3, frame.capturedAt - anchor.capturedAt >= 300 {
                        return frame
                    }
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ROBArmRoutineError.blocked("The camera view did not settle within 3 seconds. Keep the workspace still and retry; no new motion was sent.")
    }

    func observe(target: String, grippers: Bool = true, progress: (@MainActor (String) -> Void)? = nil) async throws -> ROBArmRoutineObservation {
        let token = try inspectionEpoch()
        // One shared retry budget for a changed scene or unreadable response.
        // Never retry an actual negative/uncertain observation to seek approval.
        var formatRetry = false
        for attempt in 1...2 {
            try Task.checkCancellation()
            await progress?(attempt == 1 ? "Waiting for a steady main-camera view"
                : formatRetry ? "Vision reply was incomplete; checking a fresh view once more"
                : "Scene changed; checking a fresh steady view once more")
            recordInspection(["attempt": attempt, "phase": "waiting_for_model_and_steady_view"])
            let result = try await ROBMLXEngine.shared.observeArmWorkspace(target: String(target.prefix(160)), grippers: grippers, formatRetry: formatRetry) {
                let face = try await self.settledInspectionFrame(epoch: token)
                guard let cg = self.context.createCGImage(face.image, from: face.image.extent),
                      let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                    throw ROBArmRoutineError.blocked("Could not inspect the camera frames.")
                }
                await progress?("Inspecting the current arm workspace (\(attempt)/2)")
                return (jpeg: jpeg, evidence: face)
            }
            try Task.checkCancellation()
            let face = result.evidence
            guard let current = try inspectionFrame(epoch: token), isFresh(current),
                  Date().timeIntervalSince1970 * 1000 - face.capturedAt <= 8_000 else {
                throw ROBArmRoutineError.blocked("Camera inspection timed out; no motion was authorized.")
            }
            guard current.sequence > face.sequence, current.capturedAt > face.capturedAt else {
                throw ROBArmRoutineError.blocked("The camera stream stopped advancing during inspection.")
            }
            guard let changed = Self.sceneChangeFraction(face.thumbnail, current.thumbnail) else {
                throw ROBArmRoutineError.blocked("The inspected camera view changed.")
            }
            let age = Date().timeIntervalSince1970 * 1000 - face.capturedAt
            var diagnostics: [String: Any] = ["attempt": attempt, "phase": changed < 0.025 ? "steady" : "scene_changed",
                "source_sequence": NSNumber(value: face.sequence), "current_sequence": NSNumber(value: current.sequence),
                "source_age_ms": age, "changed_fraction": changed, "limit": 0.025]
            recordInspection(diagnostics)
            NSLog("Arm camera inspection %d: %.1f%% changed, %.0f ms source age", attempt, changed * 100, age)
            guard changed < 0.025 else { continue }
            do {
                let observation = try ROBArmObservationCodec.decode(result.raw)
                diagnostics["phase"] = "decoded"
                diagnostics["assessment"] = grippers ? "grippers" : "arm_route"
                diagnostics["motion_block_reason"] = (grippers ? observation.gripperInspectionBlockReason : observation.motionBlockReason) ?? ""
                diagnostics["confidence"] = observation.confidence
                diagnostics["response_sample"] = ROBArmObservationCodec.diagnosticSample(result.raw)
                recordInspection(diagnostics)
                NSLog("Arm camera assessment: %@", ROBArmObservationCodec.diagnosticSample(result.raw))
                return observation
            } catch let issue as ROBArmObservationCodec.Failure {
                let sample = ROBArmObservationCodec.diagnosticSample(result.raw)
                diagnostics["phase"] = "invalid_model_response"
                diagnostics["response_error"] = issue.code
                diagnostics["response_detail"] = issue.detail
                diagnostics["response_sample"] = sample
                recordInspection(diagnostics)
                NSLog("Arm camera response rejected (%@), attempt %d: %@", issue.code, attempt, sample)
                if attempt == 1, issue.retryable { formatRetry = true; continue }
                throw ROBArmRoutineError.blocked("\(issue.detail)\(attempt == 2 ? " The automatic retry also failed." : "") No further arm movement was requested.")
            }
        }
        throw ROBArmRoutineError.blocked("The scene changed during the second camera inspection; no further arm movement was requested.")
    }
}
