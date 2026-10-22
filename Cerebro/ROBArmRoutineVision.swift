import AppKit
import AVFoundation
import Vision
import simd

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
        var depth: CameraDepthFrame? = nil
        var intrinsics: CameraIntrinsics? = nil
        var pointing: ROBWorkspacePointingHint? = nil
        var nearestPerson: (x: Double, y: Double, distance: Double)? = nil
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
            var pointing: ROBWorkspacePointingHint?
            var nearestPerson: (x: Double, y: Double, distance: Double)?
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
                    if !distances.isEmpty {
                        distances.sort(); let distance = Double(distances[distances.count / 2]) / 1000
                        if nearestPerson == nil || distance < nearestPerson!.distance {
                            nearestPerson = (Double(box.midX), Double(1 - box.midY), distance)
                        }
                    }
                }
                // A pointing estimate guides only the next camera view. Require
                // an extended index and folded middle/ring fingers; prefer the
                // nearest measured hand, never infer an object's existence.
                for hand in hands.results ?? [] where hand.confidence >= 0.5 {
                    guard let points = try? hand.recognizedPoints(.all),
                          let wrist = points[.wrist], let tip = points[.indexTip], let base = points[.indexMCP],
                          let middle = points[.middleTip], let ring = points[.ringTip],
                          [wrist, tip, base, middle, ring].allSatisfy({ $0.confidence >= 0.5 }) else { continue }
                    func distance(_ a: VNRecognizedPoint, _ b: VNRecognizedPoint) -> Double {
                        hypot(a.location.x - b.location.x, a.location.y - b.location.y)
                    }
                    guard distance(wrist, tip) > distance(wrist, middle) * 1.25,
                          distance(wrist, tip) > distance(wrist, ring) * 1.25,
                          distance(base, tip) > 0.03,
                          let mm = depth.distanceMillimeters(x: Int(wrist.location.x * Double(depth.width - 1)),
                            y: Int((1 - wrist.location.y) * Double(depth.height - 1))) else { continue }
                    let hint = ROBWorkspacePointingHint(x: tip.location.x, y: 1 - tip.location.y,
                        dx: tip.location.x - base.location.x, dy: base.location.y - tip.location.y,
                        distanceMeters: Double(mm) / 1000)
                    if pointing == nil || hint.distanceMeters < pointing!.distanceMeters { pointing = hint }
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
                                     demonstration: demonstration, depth: depth, intrinsics: frame.intrinsics,
                                     pointing: pointing, nearestPerson: nearestPerson)
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

    private func settledInspectionFrame(epoch token: UUID, requireStaticScene: Bool = true) async throws -> Frame {
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
                    if anchor == nil || (requireStaticScene && difference >= 0.025) ||
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

    /// Acquire the actual pixels after the local model/GPU is ready. The caller
    /// holds a specific settled neck view throughout both inference and depth
    /// projection; a current callback never refreshes the capture timestamp.
    func observeWorkspace(objectDetection: Bool = true) async throws -> (ROBWorkspaceObservation, Frame) {
        let token = try inspectionEpoch()
        if objectDetection {
            try await ROBWorkspaceObjectDetector.shared.warmUp()
            let frame = try await settledInspectionFrame(epoch: token, requireStaticScene: false)
            guard let cg = context.createCGImage(frame.image, from: frame.image.extent),
                  let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                throw ROBWorkspaceDetectorError.failure("Local detector could not read the camera image.")
            }
            let inputURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cerebro/WorkspaceDetector/latest-input.jpg")
            try? jpeg.write(to: inputURL, options: .atomic)
            let result = try await ROBWorkspaceObjectDetector.shared.detect(jpeg: jpeg)
            try Task.checkCancellation()
            let liveDeadline = ProcessInfo.processInfo.systemUptime + 2
            var advancing = false
            while ProcessInfo.processInfo.systemUptime < liveDeadline {
                try Task.checkCancellation()
                if let current = try inspectionFrame(epoch: token), isFresh(current), current.sequence > frame.sequence {
                    advancing = true; break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard advancing, Date().timeIntervalSince1970 * 1000 - frame.capturedAt < 30_000 else {
                throw ROBWorkspaceDetectorError.failure("Local detector lost the advancing live camera.")
            }
            func detection(_ target: String) -> ROBWorkspaceDetection {
                let candidates = result.candidates.filter { $0.target == target && $0.score >= 0.35 }
                    .sorted { $0.score > $1.score }
                guard let best = candidates.first else {
                    return .init(visible: false, confidence: 0, box: [], aim: [], depthPoint: [])
                }
                let center = [(best.box[0] + best.box[2]) / 2, (best.box[1] + best.box[3]) / 2]
                // An object box can locate an upright can wall. A bucket box
                // alone does not establish its opening/rim, so do not invent
                // a release point from the rectangle's center.
                return .init(visible: true, confidence: best.score, box: best.box,
                    aim: target == "can" ? center : [], depthPoint: target == "can" ? center : [], confidenceThreshold: 0.35)
            }
            recordInspection(["assessment": "workspace_object_detector", "provider": result.provider,
                "model": result.model, "device": result.device, "inference_ms": result.inference_ms,
                "input_sequence": NSNumber(value: frame.sequence), "input_captured_at_ms": frame.capturedAt,
                "latest_input_file": inputURL.path, "candidates": result.candidates.map {
                    ["target": $0.target, "query": $0.query, "score": $0.score, "box": $0.box] as [String: Any]
                }])
            return (.init(can: detection("can"), orangeBucket: detection("orangeBucket"),
                leftArmHanging: false, rightArmHanging: false, hangingConfidence: 0), frame)
        }
        var diagnostics: [[String: Any]] = []
        for attempt in 0...1 {
            let result = try await ROBMLXEngine.shared.observeWorkspaceSearch(formatRetry: attempt > 0) {
                let frame = try await self.settledInspectionFrame(epoch: token, requireStaticScene: false)
                guard let cg = self.context.createCGImage(frame.image, from: frame.image.extent),
                      let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                    throw ROBArmRoutineError.blocked("Local search could not read the camera image.")
                }
                return (jpeg: jpeg, evidence: frame)
            }
            try Task.checkCancellation()
            guard let current = try inspectionFrame(epoch: token), isFresh(current),
                  current.sequence > result.evidence.sequence,
                  Date().timeIntervalSince1970 * 1000 - result.evidence.capturedAt < 30_000 else {
                throw ROBArmRoutineError.blocked("Local search lost the advancing live camera.")
            }
            do {
                let observation = try ROBWorkspaceObservation.decode(result.raw)
                diagnostics.append(["attempt": attempt + 1, "status": "decoded", "sequence": NSNumber(value: result.evidence.sequence),
                    "response_sample": ROBArmObservationCodec.diagnosticSample(result.raw)])
                recordInspection(["assessment": "workspace_search", "attempts": diagnostics])
                return (observation, result.evidence)
            } catch {
                diagnostics.append(["attempt": attempt + 1, "status": "invalid", "error": error.localizedDescription,
                    "response_sample": ROBArmObservationCodec.diagnosticSample(result.raw)])
                recordInspection(["assessment": "workspace_search", "attempts": diagnostics])
                guard attempt == 0, (error as? ROBWorkspaceObservationError)?.canRetryFormat == true else { throw error }
            }
        }
        throw ROBArmRoutineError.blocked("Local vision could not produce a readable search observation.")
    }
}

/// Repeatable local search, also callable as a search-only arm operation. Neck
/// requests use the normal serial policy; the owning task reserves the arms,
/// brakes the base and owns its one controller approval throughout the scan.
@objcMembers final class ROBWorkspaceSearch: NSObject {
    static let shared = ROBWorkspaceSearch()
    var prepareView: ((Double, Int) -> Bool)?
    var viewReady: ((Double, Int) -> Bool)?
    var canUseView: ((Double, Int) -> Bool)?
    var boundedPan: ((Double) -> Double)?
    var finishView: (() -> Void)?
    var announce: ((String) -> Void)?
    private(set) var lastReport: NSDictionary = [:]
    @nonobjc private(set) var locatedObjects: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]

    @MainActor @nonobjc func run(targets: [ROBWorkspaceTarget], model: ROBGhostRobotModel, requireDepth: Bool = true,
        check: () throws -> Void, progress: (String) -> Void) async throws -> [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] {
        let vision = ROBArmRoutineVision.shared
        locatedObjects = [:]
        var found: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]
        var visuallyFound = Set<ROBWorkspaceTarget>()
        var evidence: [[String: Any]] = []
        var leftHanging = false, rightHanging = false
        var validObservations = 0
        var nearest: (view: ROBWorkspaceView, distance: Double)?
        var livePointing: (hint: ROBWorkspacePointingHint, view: ROBWorkspaceView, capturedAt: Double)?
        var followedLivePointing = false
        let reportID = UUID().uuidString
        let startedAt = ISO8601DateFormatter().string(from: Date())
        var finished = false
        func targetsConfirmed() -> Bool {
            targets.allSatisfy { requireDepth ? found[$0] != nil : visuallyFound.contains($0) }
        }
        func persist(_ status: String, _ detail: String) {
            var report: [String: Any] = ["schema_version": 1, "status": status, "detail": detail,
                "created_at": ISO8601DateFormatter().string(from: Date()), "search_started_at": startedAt,
                "inference": targets.isEmpty ? "on-device MLX hanging inspection; no cloud session" : "offline OWLv2 object boxes; no cloud or generative detection",
                "camera_arm_mapping": "provisional URDF/neck command prior, not measured hand-eye calibration",
                "left_hanging_observed": leftHanging, "right_hanging_observed": rightHanging,
                "visually_confirmed": visuallyFound.map(\.rawValue).sorted(), "decoded_observations": validObservations,
                "settle_seconds_per_view": 1.5,
                "depth_required": requireDepth,
                "views": evidence, "objects": found.reduce(into: [String: Any]()) {
                    $0[$1.key.rawValue] = ["position": $1.value.position, "captured_at_ms": $1.value.capturedAt]
                }]
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("Cerebro/WorkspaceSearch", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("\(reportID).json")
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
                report["recording"] = file.path
            } catch { report["recording_error"] = error.localizedDescription }
            lastReport = report as NSDictionary
        }
        defer {
            if !finished { persist("interrupted", "Search interrupted; completed observations are retained. Object absence is unconfirmed.") }
            finishView?()
        }
        func moveView(_ view: ROBWorkspaceView) async throws -> Bool {
            if canUseView?(view.panDegrees, view.upperTarget) == false {
                evidence.append(["pan": view.panDegrees, "upper": view.upperTarget, "status": "outside_current_neck_envelope"])
                return false
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            var settledSince: TimeInterval?
            progress(String(format: "Local search: camera pan %+.0f°, tilt target %d", view.panDegrees, view.upperTarget))
            while ProcessInfo.processInfo.systemUptime < deadline {
                try check()
                if prepareView?(view.panDegrees, view.upperTarget) == true,
                   viewReady?(view.panDegrees, view.upperTarget) == true {
                    if settledSince == nil { settledSince = ProcessInfo.processInfo.systemUptime }
                    if ProcessInfo.processInfo.systemUptime - settledSince! >= 1.5 { return true }
                } else { settledSince = nil }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            evidence.append(["pan": view.panDegrees, "upper": view.upperTarget, "status": "view_unavailable"])
            return false
        }
        func inspect(_ view: ROBWorkspaceView) async throws {
            guard try await moveView(view) else { return }
            var prior: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]
            var priorVisual: [ROBWorkspaceTarget: (detection: ROBWorkspaceDetection, sequence: UInt64)] = [:]
            var priorHanging: ROBWorkspaceObservation?
            var priorPointing: ROBWorkspacePointingHint?
            for _ in 0..<2 {
                try check()
                guard viewReady?(view.panDegrees, view.upperTarget) == true else {
                    throw ROBArmRoutineError.blocked("Search camera moved during inspection.")
                }
                let (observation, frame) = try await vision.observeWorkspace(objectDetection: !targets.isEmpty)
                validObservations += 1
                try check()
                guard viewReady?(view.panDegrees, view.upperTarget) == true else {
                    throw ROBArmRoutineError.blocked("Search camera changed before depth projection.")
                }
                if let person = frame.nearestPerson, nearest == nil || person.distance < nearest!.distance {
                    nearest = (view, person.distance)
                }
                if let previous = priorHanging, previous.hangingConfidence >= 0.7, observation.hangingConfidence >= 0.7 {
                    leftHanging = leftHanging || (previous.leftArmHanging && observation.leftArmHanging)
                    rightHanging = rightHanging || (previous.rightArmHanging && observation.rightArmHanging)
                }
                priorHanging = observation
                if let hint = frame.pointing {
                    if let previous = priorPointing, previous.agrees(with: hint) {
                        livePointing = (hint, view, frame.capturedAt)
                    }
                    priorPointing = hint
                } else { priorPointing = nil }
                var entry: [String: Any] = ["pan": view.panDegrees, "upper": view.upperTarget,
                    "sequence": NSNumber(value: frame.sequence), "captured_at_ms": frame.capturedAt,
                    "left_hanging": observation.leftArmHanging, "right_hanging": observation.rightArmHanging,
                    "hanging_confidence": observation.hangingConfidence]
                entry["local_inference"] = vision.healthSnapshot()["inspection"]
                for target in targets {
                    let detection = observation[target]
                    if detection.visuallyUsable, let previous = priorVisual[target], previous.sequence != frame.sequence,
                       hypot(detection.center[0] - previous.detection.center[0], detection.center[1] - previous.detection.center[1]) <= 0.08 {
                        visuallyFound.insert(target)
                    }
                    if detection.visuallyUsable { priorVisual[target] = (detection, frame.sequence) }
                    else { priorVisual.removeValue(forKey: target) }
                    guard let depth = frame.depth, let k = frame.intrinsics,
                          let located = ROBWorkspaceGrounding.locate(target: target, detection: detection,
                            width: depth.width, height: depth.height, fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy,
                            depth: { depth.distanceMillimeters(x: $0, y: $1) }, view: view, model: model,
                            capturedAt: frame.capturedAt, sequence: frame.sequence) else {
                        prior.removeValue(forKey: target); entry[target.rawValue] = "not_grounded"; continue
                    }
                    entry[target.rawValue] = ["position": located.position, "confidence": located.confidence]
                    if let previous = prior[target], previous.agrees(with: located) { found[target] = located }
                    prior[target] = located
                }
                evidence.append(entry)
            }
        }
        func inspectWithRetry(_ view: ROBWorkspaceView) async throws {
            for attempt in 0...1 {
                do { try await inspect(view); return }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try check()
                    evidence.append(["pan": view.panDegrees, "upper": view.upperTarget, "attempt": attempt + 1,
                        "error": error.localizedDescription, "local_inference": vision.healthSnapshot()["inspection"] ?? [:]])
                    let transientCamera = ["camera", "settle", "stream", "view"].contains { error.localizedDescription.lowercased().contains($0) }
                    if !transientCamera || attempt == 1 { return }
                    progress("Camera pause; settling and retrying this view")
                }
            }
        }
        func followPointing(_ hint: ROBWorkspacePointingHint, from humanView: ROBWorkspaceView) async throws {
            let views = hint.searchViews(from: humanView, boundedPan: boundedPan ?? { max(-45, min(45, $0)) })
            evidence.append(["pointing_hint": ["x": hint.x, "y": hint.y, "dx": hint.dx, "dy": hint.dy],
                "guided_views": views.map { ["pan": $0.panDegrees, "upper": $0.upperTarget] }, "pointing_is_object_confirmation": false])
            for (index, view) in views.enumerated() {
                progress("Pointing search view \(index + 1) of \(views.count)")
                try await inspectWithRetry(view)
                persist("searching", "Completed pointing search view \(index + 1) of \(views.count)")
                if targetsConfirmed() { break }
            }
        }
        let sweep = targets.isEmpty ? [ROBWorkspaceView(panDegrees: 0, upperTarget: 5300),
            .init(panDegrees: -35, upperTarget: 5300), .init(panDegrees: 35, upperTarget: 5300)] : ROBWorkspaceView.sweep
        for (index, view) in sweep.enumerated() {
            progress("Searching view \(index + 1) of \(sweep.count)")
            try await inspectWithRetry(view)
            if !targets.isEmpty, !followedLivePointing, let pointing = livePointing,
               Date().timeIntervalSince1970 * 1000 - pointing.capturedAt < 15_000,
               targets.contains(where: { !visuallyFound.contains($0) }) {
                followedLivePointing = true
                announce?("Following your pointing direction.")
                try await followPointing(pointing.hint, from: pointing.view)
            }
            persist("searching", "Completed search view \(index + 1) of \(sweep.count)")
            if targets.isEmpty ? leftHanging && rightHanging : targetsConfirmed() { break }
        }
        if validObservations > 0, !targets.isEmpty, targets.contains(where: { !visuallyFound.contains($0) }) {
            let missing = targets.filter { !visuallyFound.contains($0) }.map(\.spokenName).joined(separator: " and ")
            let humanView = nearest?.view ?? ROBWorkspaceView(panDegrees: 0, upperTarget: 6906)
            if try await moveView(humanView) {
                announce?("Point to the \(missing), please.")
                progress("Waiting for a nearby person's pointing gesture")
                let deadline = ProcessInfo.processInfo.systemUptime + 20
                var prior: ROBWorkspacePointingHint?, priorSequence: UInt64 = 0
                var pointingHint: ROBWorkspacePointingHint?
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try check()
                    guard viewReady?(humanView.panDegrees, humanView.upperTarget) == true else {
                        throw ROBArmRoutineError.blocked("Search view changed while waiting for pointing.")
                    }
                    if let frame = vision.snapshot()["face"], vision.fresh, frame.sequence != priorSequence {
                        priorSequence = frame.sequence
                        if let pointing = frame.pointing {
                            if let previous = prior, previous.agrees(with: pointing) {
                                pointingHint = pointing; break
                            }
                            prior = pointing
                        } else { prior = nil }
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if let pointingHint {
                    try await followPointing(pointingHint, from: humanView)
                }
            }
        }
        // Refresh older discoveries after a long sweep; never send a reach to
        // a remembered cloud or silently treat historical points as current.
        for target in targets {
            if let object = found[target], Date().timeIntervalSince1970 * 1000 - object.capturedAt > 20_000 {
                found.removeValue(forKey: target)
                visuallyFound.remove(target)
                do { try await inspect(object.view) } catch is CancellationError { throw CancellationError() }
                catch { try check(); evidence.append(["refresh_error": error.localizedDescription]) }
            }
        }
        let missing = targets.filter { found[$0] == nil }.map(\.spokenName)
        let unseen = targets.filter { !visuallyFound.contains($0) }.map(\.spokenName)
        let seen = targets.filter { visuallyFound.contains($0) }.map(\.spokenName)
        let status = targets.isEmpty ? (leftHanging && rightHanging ? "observed_hanging" : "hanging_unconfirmed")
            : validObservations == 0 ? "vision_unavailable" : !requireDepth && unseen.isEmpty ? "visually_found"
                : missing.isEmpty ? "found" : unseen.isEmpty ? "depth_unconfirmed" : "not_found"
        let message = targets.isEmpty ? (leftHanging && rightHanging ? "I can see both robot arms hanging." : "I couldn't confirm both arms hanging from these views.")
            : validObservations == 0 ? "My local search could not produce a usable camera observation. I cannot yet confirm the can or bucket. I haven't sent a reach."
                : missing.isEmpty || !requireDepth && unseen.isEmpty ? "I found the \(targets.map(\.spokenName).joined(separator: " and "))."
                : unseen.isEmpty ? "I can see the can and orange bucket, but I couldn't confirm their depth positions. I haven't sent a reach."
                    : (seen.isEmpty ? "" : "I can see the \(seen.joined(separator: " and ")). ") +
                        "I still couldn't confirm the \(unseen.joined(separator: " and "))."
        announce?(message); progress(message)
        finished = true
        locatedObjects = found
        persist(status, message)
        return found
    }
}
