import AppKit
import AVFoundation
import Vision
import simd

/// Capture provenance is independent of whether a perception consumer is on.
/// Restarting an inspection must not erase a completed scene preview, while a
/// real stream/source/calibration restart must invalidate its coordinate frame.
struct ROBVisionCaptureIdentity {
    enum Update { case unchanged, changed, reordered }
    private(set) var generation = UUID()
    private var signature: String?
    private var sequence: UInt64 = 0
    private var timestampNanoseconds: UInt64 = 0
    private var capturedAtMilliseconds: Double?

    mutating func observe(streamID: String?, source: String, width: Int?, height: Int?,
        intrinsics: [Double]?, sequence: UInt64, timestampNanoseconds: UInt64,
        capturedAtMilliseconds: Double?) -> Update {
        let nextSignature = "\(streamID ?? "unknown")|\(source)|\(width ?? 0)x\(height ?? 0)|"
            + (intrinsics?.map { String($0.bitPattern) }.joined(separator:",") ?? "no-intrinsics")
        // The initial UUID already identifies this first stream. Enrolling
        // its first metadata must not cancel an inspection waiting for startup.
        let changedIdentity = signature != nil && signature != nextSignature
        let previousCapture = self.capturedAtMilliseconds
        let olderCapture = capturedAtMilliseconds.flatMap { value in previousCapture.map { value <= $0 } } ?? false
        if !changedIdentity, sequence <= self.sequence,
           timestampNanoseconds <= self.timestampNanoseconds, olderCapture { return .reordered }
        let restarted = !changedIdentity && (sequence < self.sequence
            || timestampNanoseconds < self.timestampNanoseconds
            || (capturedAtMilliseconds.flatMap { value in previousCapture.map { value < $0 } } ?? false))
        if changedIdentity || restarted { generation = UUID() }
        signature = nextSignature; self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.capturedAtMilliseconds = capturedAtMilliseconds.flatMap { $0.isFinite ? $0 : nil }
        return changedIdentity || restarted ? .changed : .unchanged
    }
}

/// A scene has no camera identity until its first real settled RGB-D sample.
/// Startup may replace an idle stream; established scenes never re-enroll.
struct ROBWorkspaceCaptureAnchor {
    private(set) var cameraGeneration: UUID?
    func permitsCurrent(_ current:UUID) -> Bool { cameraGeneration.map { $0 == current } ?? true }
    mutating func accept(frameGeneration:UUID,currentGeneration:UUID) -> Bool {
        guard frameGeneration == currentGeneration, permitsCurrent(currentGeneration) else { return false }
        cameraGeneration = currentGeneration
        return true
    }
}

/// Only startup inspection invalidation is recoverable. An accepted scene or
/// an actual Stop/cancel closes this window permanently for the current run.
struct ROBWorkspaceObservationWarmup {
    private var deadline:Double?
    mutating func permitsRetry(acceptedObservation:Bool,anchoredMap:Bool,taskCancelled:Bool,nowUptime:Double) -> Bool {
        guard !acceptedObservation, !anchoredMap, !taskCancelled, nowUptime.isFinite else { return false }
        if deadline == nil { deadline = nowUptime+8 }
        return nowUptime < deadline!
    }
}

/// Preserve the detector's exact source frame when enrolling collision depth.
/// Inference completion never changes a capture timestamp or enrolls old pixels.
struct ROBWorkspaceFrameEnrollment {
    enum Decision { case fresh, alreadyEnrolled, invalid }
    private(set) var sequence: UInt64 = 0
    private(set) var capturedAtMilliseconds: Double?
    func decision(sequence candidate:UInt64,capturedAtMilliseconds captured:Double,nowMilliseconds now:Double)->Decision {
        guard candidate>0,captured.isFinite,now.isFinite,(0...700).contains(now-captured) else {return .invalid}
        if candidate==sequence,capturedAtMilliseconds==captured {return .alreadyEnrolled}
        guard candidate>sequence,capturedAtMilliseconds.map({captured>$0}) ?? true else {return .invalid}
        return .fresh
    }
    mutating func record(sequence:UInt64,capturedAtMilliseconds:Double) {
        self.sequence=sequence;self.capturedAtMilliseconds=capturedAtMilliseconds
    }
}

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
    private var captureIdentity = ROBVisionCaptureIdentity()
    private var busy: Set<String> = []
    private var lastOffer: [String: TimeInterval] = [:]
    private var inputNotes: [String: String] = [:]
    private var lastIncomingCapture: Double?
    private var lastIncomingSequence: UInt64 = 0
    private var processingMilliseconds: Double = 0
    private var frames: [String: Frame] = [:]
    private var lastInspection: [String: Any] = [:]
    private let collisionRegistrationProbe = ROBMarkerlessVisionService()
    private var collisionProbeActive = false
    private var collisionProbeObservation: [String: Any] = [:]

    var cameraGeneration: UUID { lock.lock(); defer { lock.unlock() }; return captureIdentity.generation }

    /// A user-applied head-depth correction changes every projected coordinate.
    /// Drop in-flight inference and enroll fresh frames in a new generation.
    func depthAlignmentDidChange() {
        lock.lock(); defer { lock.unlock() }
        captureIdentity = ROBVisionCaptureIdentity()
        epoch = UUID(); frames = [:]; busy = []; lastOffer = [:]
        lastInspection = [:]; inputNotes = [:]
        lastIncomingCapture = nil; lastIncomingSequence = 0; processingMilliseconds = 0
    }

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
        var cameraGeneration: UUID = UUID()
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
        let identityUpdate = captureIdentity.observe(streamID:frame.captureStreamID,source:frame.source.rawValue,
            width:frame.alignedDepth?.width,height:frame.alignedDepth?.height,
            intrinsics:frame.intrinsics.map { [$0.fx,$0.fy,$0.cx,$0.cy] },sequence:frame.sequence,
            timestampNanoseconds:frame.timestampNanoseconds,capturedAtMilliseconds:frame.capturedAtMilliseconds)
        if identityUpdate == .reordered { lock.unlock(); return }
        if identityUpdate == .changed {
            // Capture identity changes also cancel any pending analysis answer.
            epoch = UUID(); frames = [:]; busy = []; lastOffer = [:]
        }
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
        let captureGeneration = captureIdentity.generation
        let probeActive = collisionProbeActive
        let needsBody = teaching && key == "face"
        busy.insert(key); lastOffer[key] = now
        lock.unlock()
        if probeActive {
            collisionRegistrationProbe.offer(frame, role: role, streamID: "collision-\(captureGeneration.uuidString)")
        }
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
                                     pointing: pointing, nearestPerson: nearestPerson, cameraGeneration: captureGeneration)
        }
    }

    func snapshot() -> [String: Frame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    /// Lightweight offline grasp evidence. Does not run a detector, move the
    /// head or arms, restore a grant, or manufacture the projected tool pose.
    /// The executor supplies the tool projection from synchronized MEASURED
    /// feedback and holds the exact registered head view throughout the test.
    func visualGraspSample(fixedViewIdentity:String,targetIdentity:String,
        measuredToolCenter:ROBVisualGraspVerifier.Point,measuredToolDepthMeters:Double,
        toolFeedbackCapturedAtMilliseconds:Double,afterSequence:UInt64 = 0) throws -> ROBVisualGraspVerifier.Sample? {
        guard let frame=snapshot()["face"],frame.sequence>afterSequence,isFresh(frame) else { return nil }
        return try makeVisualGraspSample(frame:frame,fixedViewIdentity:fixedViewIdentity,targetIdentity:targetIdentity,
            measuredToolCenter:measuredToolCenter,measuredToolDepthMeters:measuredToolDepthMeters,
            toolFeedbackCapturedAtMilliseconds:toolFeedbackCapturedAtMilliseconds)
    }

    func makeVisualGraspSample(frame:Frame,fixedViewIdentity:String,targetIdentity:String,
        measuredToolCenter:ROBVisualGraspVerifier.Point,measuredToolDepthMeters:Double,
        toolFeedbackCapturedAtMilliseconds:Double,allowReferenceImage:Bool=false) throws -> ROBVisualGraspVerifier.Sample {
        let referenceAge=Date().timeIntervalSince1970*1000-frame.capturedAt
        guard isFresh(frame) || (allowReferenceImage && (0...30_000).contains(referenceAge) && frame.depthCoverage>=0.25),let depth=frame.depth,
              depth.width>0,depth.height>0,
              let image=context.createCGImage(frame.image,from:frame.image.extent),
              image.width==depth.width,image.height==depth.height else {
            throw ROBVisualGraspVerifier.Unavailable.evidence("Grasp inspection requires a fresh pixel-aligned RGB-D frame.")
        }
        let width=min(320,image.width),height=max(1,Int((Double(image.height)*Double(width)/Double(image.width)).rounded()))
        var gray=[UInt8](repeating:0,count:width*height)
        let rendered=gray.withUnsafeMutableBytes { raw -> Bool in
            guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            // CGImage and the aligned depth raster both use top-left image
            // coordinates. No camera/world visualization correction is applied
            // to raw optical Z; motion differences are checked in this frame.
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard rendered else { throw ROBVisualGraspVerifier.Unavailable.evidence("Could not read the grasp inspection pixels.") }
        var depths=[Float](repeating:0,count:width*height)
        for y in 0..<height { for x in 0..<width {
            let dx=min(depth.width-1,Int((Double(x)+0.5)*Double(depth.width)/Double(width)))
            let dy=min(depth.height-1,Int((Double(y)+0.5)*Double(depth.height)/Double(height)))
            if let mm=depth.distanceMillimeters(x:dx,y:dy),mm>0 { depths[y*width+x]=Float(mm)/1000 }
        } }
        return .init(sequence:frame.sequence,capturedAtMilliseconds:frame.capturedAt,synchronizedRGBDepth:true,
            cameraGeneration:frame.cameraGeneration,fixedViewIdentity:fixedViewIdentity,targetIdentity:targetIdentity,
            width:width,height:height,gray:gray,depthMeters:depths,measuredToolCenter:measuredToolCenter,
            measuredToolDepthMeters:measuredToolDepthMeters,toolFeedbackCapturedAtMilliseconds:toolFeedbackCapturedAtMilliseconds,
            handsClear:frame.handsClear)
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

    /// Depth-only settled capture: no LLM/object inference and no arm command.
    func settledDepthFrame() async throws -> Frame {
        try await settledInspectionFrame(epoch: inspectionEpoch(), requireStaticScene: true)
    }

    @MainActor func beginCollisionRegistrationProbe() {
        collisionRegistrationProbe.onObservation = { [weak self] observation in
            guard let self else { return }
            self.lock.lock(); self.collisionProbeObservation = observation; self.lock.unlock()
        }
        collisionRegistrationProbe.onFailure = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.collisionProbeObservation = ["status": "unavailable", "detail": "Existing markerless registration runtime is unavailable"]
            self.lock.unlock()
        }
        let started = collisionRegistrationProbe.start() != nil
        lock.lock(); collisionProbeActive = started
        collisionProbeObservation = ["status": started ? "waiting" : "unavailable",
            "detail": started ? "Fitting visible base and torso with the existing markerless registrar" : "Existing markerless registration runtime is unavailable"]
        lock.unlock()
    }

    @MainActor func endCollisionRegistrationProbe() {
        lock.lock(); collisionProbeActive = false; lock.unlock()
        collisionRegistrationProbe.stop()
    }

    func collisionRegistrationDiagnostics() -> NSDictionary {
        lock.lock(); defer { lock.unlock() }
        return collisionProbeObservation as NSDictionary
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
    func observeWorkspace(objectDetection: Bool = true,
        onCaptured: @MainActor (Frame) async throws -> Void = { _ in }) async throws -> (ROBWorkspaceObservation, Frame) {
        if objectDetection {
            try await ROBWorkspaceObjectDetector.shared.warmUp()
            try Task.checkCancellation()
            let token = try inspectionEpoch()
            let frame = try await settledInspectionFrame(epoch: token, requireStaticScene: false)
            try await onCaptured(frame)
            try Task.checkCancellation()
            guard frame.cameraGeneration == cameraGeneration else { throw CancellationError() }
            guard let cg = context.createCGImage(frame.image, from: frame.image.extent),
                  let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                throw ROBWorkspaceDetectorError.failure("Local detector could not read the camera image.")
            }
            let inputURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cerebro/WorkspaceDetector/latest-input.jpg")
            try? jpeg.write(to: inputURL, options: .atomic)
            let result = try await ROBWorkspaceObjectDetector.shared.detect(jpeg: jpeg)
            if result.candidates.contains(where: { $0.target == "orangeBucket" && $0.score >= 0.35 }) {
                let directory = inputURL.deletingLastPathComponent()
                try? jpeg.write(to: directory.appendingPathComponent("last-bucket-input.jpg"), options: .atomic)
                if let depth = frame.depth, let k = frame.intrinsics {
                    try? depth.millimetersLittleEndian.write(to: directory.appendingPathComponent("last-bucket-depth.u16"), options: .atomic)
                    let metadata: [String: Any] = ["width": depth.width, "height": depth.height,
                        "fx": k.fx, "fy": k.fy, "cx": k.cx, "cy": k.cy, "captured_at_ms": frame.capturedAt,
                        "sequence": NSNumber(value: frame.sequence), "boxes": result.candidates.filter { $0.target == "orangeBucket" }.map(\.box)]
                    try? JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("last-bucket-depth.json"), options: .atomic)
                }
            }
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
            func detections(_ target: String) -> [ROBWorkspaceDetection] {
                let candidates = result.candidates.filter { $0.target == target && $0.score >= 0.35 }
                    .sorted { $0.score > $1.score }
                return candidates.map { candidate in
                    let center = [(candidate.box[0] + candidate.box[2]) / 2, (candidate.box[1] + candidate.box[3]) / 2]
                    // A bucket box alone never establishes its opening/rim.
                    return .init(visible:true,confidence:candidate.score,box:candidate.box,
                        aim:target == "can" ? center : [],depthPoint:target == "can" ? center : [],confidenceThreshold:0.35)
                }
            }
            let cans = ROBWorkspaceSearchSchedule.distinctCans(detections("can"))
            let absent = ROBWorkspaceDetection(visible:false,confidence:0,box:[],aim:[],depthPoint:[])
            recordInspection(["assessment": "workspace_object_detector", "provider": result.provider,
                "model": result.model, "device": result.device, "inference_ms": result.inference_ms,
                "input_sequence": NSNumber(value: frame.sequence), "input_captured_at_ms": frame.capturedAt,
                "latest_input_file": inputURL.path, "candidates": result.candidates.map {
                    ["target": $0.target, "query": $0.query, "score": $0.score, "box": $0.box] as [String: Any]
                }])
            return (.init(can:cans.first ?? absent,orangeBucket:detections("orangeBucket").first ?? absent,
                leftArmHanging:false,rightArmHanging:false,hangingConfidence:0,cans:cans), frame)
        }
        var diagnostics: [[String: Any]] = []
        for attempt in 0...1 {
            var inspectedToken:UUID?
            let result = try await ROBMLXEngine.shared.observeWorkspaceSearch(formatRetry: attempt > 0) {
                try Task.checkCancellation()
                let token = try self.inspectionEpoch()
                inspectedToken = token
                let frame = try await self.settledInspectionFrame(epoch: token, requireStaticScene: false)
                try await onCaptured(frame)
                try Task.checkCancellation()
                guard frame.cameraGeneration == self.cameraGeneration else { throw CancellationError() }
                guard let cg = self.context.createCGImage(frame.image, from: frame.image.extent),
                      let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                    throw ROBArmRoutineError.blocked("Local search could not read the camera image.")
                }
                return (jpeg: jpeg, evidence: frame)
            }
            try Task.checkCancellation()
            guard let token = inspectedToken, let current = try inspectionFrame(epoch: token), isFresh(current),
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
    private var collisionSnapshotValue: ROBWorkspaceCollisionSnapshot?
    @nonobjc private var collisionSnapshotModel:ROBGhostRobotModel?
    @nonobjc func estimatedCameraProjectionIsCurrent(model:ROBGhostRobotModel,map:ROBWorkspaceCollisionSnapshot)->Bool {
        // Measured profiles and the separate frozen raw/corrected RIGHT
        // context keep their own existing transform/provenance admission.
        if map.registrationID != nil || (map.estimatedCameraProjectionIdentity==nil && !map.observations.isEmpty &&
            map.observations.allSatisfy({$0.estimatedDepthHypothesisID != nil})) {return true}
        let current=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)
        return map.estimatedCameraProjectionIdentity==current &&
            (!ROBNeckRGBPoseDisplay.photoHardwareOpticalOriginRequested || current != nil)
    }
    @nonobjc private func requireEstimatedProjectionIdentity(_ expected:String?,model:ROBGhostRobotModel)throws {
        guard ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==expected,
              !ROBNeckRGBPoseDisplay.photoHardwareOpticalOriginRequested || expected != nil else {
            throw ROBWorkspaceDepthMapError.acquisition("The estimated physical camera projection changed or is invalid; capture a new scene.")
        }
    }
    /// A view label is never substituted for accepted raw commands. The
    /// opt-in photo origin is usable only for a real, stationary source hold.
    @MainActor @nonobjc private func unregisteredCameraProjection(frame:ROBArmRoutineVision.Frame,view:ROBWorkspaceView,
        model:ROBGhostRobotModel)throws->(matrix:simd_double4x4,identity:String?,lowerTarget:Int?) {
        let identity=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)
        try requireEstimatedProjectionIdentity(identity,model:model)
        guard identity != nil else {
            guard let legacy=view.cameraFrame(model:model) else{throw ROBWorkspaceDepthMapError.invalidFrame}
            return (legacy,nil,nil)
        }
        let controller=ROBFixedHeadCalibrationWindowController.shared
        guard frame.intrinsics?.rgbOutputUndistorted==true else {
            throw ROBWorkspaceDepthMapError.acquisition("The estimated photo-origin projection requires the actual undistorted RGB source contract.")
        }
        let scope=try controller.scope(model:model,frame:frame)
        try scope.validate()
        let neck=controller.readNeck?() ?? [:],now=ProcessInfo.processInfo.systemUptime
        let captureUptime=now-(Date().timeIntervalSince1970*1000-frame.capturedAt)/1000
        guard neck["known"]as?Bool==true,neck["stationary"]as?Bool==true,
              neck["pan"]as?Int==scope.panTarget,neck["lower"]as?Int==scope.lowerTarget,neck["upper"]as?Int==scope.upperTarget,
              let pan=neck["pan_degrees"]as?Double,pan.isFinite,abs(pan-view.panDegrees)<=0.05,
              scope.upperTarget==view.upperTarget,
              let ready=neck["ready_at"]as?Double,ready.isFinite,ready<=now,captureUptime>=ready,
              let matrix=ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:scope.panTarget,
                lowerTarget:scope.lowerTarget,upperTarget:scope.upperTarget) else {
            throw ROBWorkspaceDepthMapError.acquisition("The source frame does not match the stationary raw neck hold for the estimated photo-origin projection.")
        }
        try requireEstimatedProjectionIdentity(identity,model:model)
        return (matrix,identity,scope.lowerTarget)
    }
    @MainActor @nonobjc func registeredCameraContext(frame: ROBArmRoutineVision.Frame, model: ROBGhostRobotModel)
        -> (registration: ROBFixedHeadRegistration, scope: ROBFixedHeadRegistrationScope)? {
        guard let scope = try? ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame),
              let registration = ROBFixedHeadRegistrationStore.shared.resolve(scope:scope) else { return nil }
        return (registration,scope)
    }
    @MainActor @nonobjc private func registeredCurrentView(model: ROBGhostRobotModel) -> ROBWorkspaceView? {
        guard let frame = ROBArmRoutineVision.shared.snapshot()["face"],
              (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
              let context = registeredCameraContext(frame:frame,model:model),
              let neck = ROBFixedHeadCalibrationWindowController.shared.readNeck?(),
              let pan = neck["pan_degrees"] as? Double else { return nil }
        return ROBWorkspaceView(panDegrees:pan,upperTarget:context.scope.upperTarget)
    }
    /// Display-only history survives a camera restart or expiry. Motion
    /// admission must exclusively use the fresh collisionSnapshot below.
    @nonobjc var collisionPreviewSnapshot: ROBWorkspaceCollisionSnapshot? { collisionSnapshotValue }
    @nonobjc var collisionSnapshot: ROBWorkspaceCollisionSnapshot? {
        guard let value = collisionSnapshotValue,
              value.cameraGeneration == ROBArmRoutineVision.shared.cameraGeneration,
              (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == value.sessionGeneration,
              (0...60_000).contains(Date().timeIntervalSince1970 * 1000 - value.oldestCapturedAtMilliseconds) else { return nil }
        guard let model=collisionSnapshotModel,estimatedCameraProjectionIsCurrent(model:model,map:value) else{return nil}
        return value
    }

    @MainActor @nonobjc func depthAlignmentDidChange() {
        collisionSnapshotValue = nil
        collisionSnapshotModel = nil
        locatedObjects = [:]
        lastReport = ["status":"depth_alignment_changed", "detail":"Head depth alignment changed; capture a fresh scene."]
    }

    /// Passive acquisition for a reviewed commissioning test. There are no
    /// prepareView callbacks here: the head and both arms must stay unchanged.
    /// The caller owns and checks the live stationary arm observation.
    @MainActor @nonobjc func captureRegisteredCurrentScene(model: ROBGhostRobotModel, generation: UInt64,
        check: () throws -> Void, progress: (String) -> Void) async throws -> ROBWorkspaceCollisionSnapshot {
        collisionSnapshotValue = nil
        collisionSnapshotModel = model
        let vision = ROBArmRoutineVision.shared
        var map: ROBWorkspaceDepthMap?, context: (registration: ROBFixedHeadRegistration, scope: ROBFixedHeadRegistrationScope)?
        var previous: UInt64 = 0, frames = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while frames < 3 {
            try check(); try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ROBWorkspaceDepthMapError.acquisition("Passive fixed-head capture did not receive three advancing frames.")
            }
            let frame = try await vision.settledDepthFrame()
            try check()
            guard frame.sequence > previous else { continue }
            guard let measured = registeredCameraContext(frame:frame,model:model),
                  measured.scope.gatewaySessionGeneration == generation,
                  let depth = frame.depth, let k = frame.intrinsics,
                  k.isValid(forWidth:depth.width,height:depth.height) else {
                throw ROBWorkspaceDepthMapError.acquisition("Measure and validate this exact fixed camera/body pose before passive arm-trial mapping.")
            }
            if let context {
                guard measured.scope == context.scope, measured.registration.id == context.registration.id else {
                    throw ROBWorkspaceDepthMapError.acquisition("Fixed-view registration changed during passive capture.")
                }
            } else { context = measured }
            let inputMap = map ?? ROBWorkspaceDepthMap(modelID:model.modelID,geometryID:model.geometryID,
                mappingID:model.selectedMappingID,sessionGeneration:generation,cameraGeneration:frame.cameraGeneration)
            let selfBounds = measuredSelfBounds(model:model)
            map = try await Task.detached(priority:.userInitiated) {
                var next = inputMap
                try next.append(width:depth.width,height:depth.height,fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,
                    depth:{depth.distanceMillimeters(x:$0,y:$1)},cameraToRobot:measured.registration.cameraToRobot,
                    capturedAtMilliseconds:frame.capturedAt,sequence:frame.sequence,cameraGeneration:frame.cameraGeneration,
                    measuredSelfBounds:selfBounds,cameraRegistrationVerified:false,
                    recordedUpperTarget:measured.scope.upperTarget,registration:measured.registration,registrationScope:measured.scope)
                return next
            }.value
            try check()
            previous = frame.sequence; frames += 1
            progress("Passive fixed-head scene: \(frames)/3 frames; arms and head unchanged.")
        }
        try check()
        guard let snapshot = map?.snapshot(), let expected = context,
              let frame = vision.snapshot()["face"],
              registeredCameraContext(frame:frame,model:model)?.scope == expected.scope else {
            throw ROBWorkspaceDepthMapError.invalidFrame
        }
        collisionSnapshotValue = snapshot
        lastReport = ["status":"passive_fixed_head_scene_captured","registration_verified":true,
            "scene_id":snapshot.sceneID.uuidString,"depth_frames":snapshot.observedFrameCount,
            "detail":"Measured current head view; no neck or arm command was sent."]
        return snapshot
    }

    /// Only the dedicated current-scene probe chooses the explicit estimate.
    /// An invalid selected estimate never falls back to measured registration.
    @MainActor @nonobjc func captureEstimatedOrRegisteredCurrentScene(model: ROBGhostRobotModel, generation: UInt64,
        check: () throws -> Void, progress: (String) -> Void) async throws -> ROBWorkspaceCollisionSnapshot {
        let controller = ROBFixedHeadCalibrationWindowController.shared
        guard let selected = controller.selectedEstimatedContext else {
            return try await captureRegisteredCurrentScene(model:model,generation:generation,check:check,progress:progress)
        }
        collisionSnapshotValue = nil
        lastReport = ["status":"waiting_for_estimated_fixed_head_scene", "registration_verified":false,
            "grasp_authorized":false, "estimated_capture":selected.metadata]
        do {
            try check(); try Task.checkCancellation()
            let frame = try await ROBArmRoutineVision.shared.settledDepthFrame()
            try check(); try Task.checkCancellation()
            let context = try controller.currentEstimatedContext(model:model,frame:frame)
            guard context.depthHypothesisID == selected.depthHypothesisID,
                  context.bodyMotionIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity else {
                throw ROBWorkspaceDepthMapError.acquisition("The selected EMPTY RIGHT estimate changed while waiting for fresh pixels.")
            }
            return try await captureEstimatedCurrentScene(model:model,generation:generation,context:context,check:check,progress:progress)
        } catch {
            collisionSnapshotValue = nil
            lastReport = ["status":"estimated_fixed_head_capture_failed", "registration_verified":false,
                "grasp_authorized":false, "detail":error.localizedDescription]
            throw error
        }
    }

    /// This proves only that the EMPTY RIGHT estimate still describes the
    /// preview/map; it does not create measured registration or grasp authority.
    @MainActor @nonobjc func estimatedContextIsCurrent(model: ROBGhostRobotModel,
        map: ROBWorkspaceCollisionSnapshot) -> Bool {
        guard let frame = ROBArmRoutineVision.shared.snapshot()["face"],
              (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
              let context = try? ROBFixedHeadCalibrationWindowController.shared.currentEstimatedContext(model:model,frame:frame),
              let scope = try? ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame),
              context.matches(currentScope:scope,model:model),
              context.depthHypothesisID.count == 64, context.depthHypothesisID.allSatisfy(\.isHexDigit),
              let depth = frame.depth, let k = frame.intrinsics,
              depth.width == context.width, depth.height == context.height,
              k.isValid(forWidth:depth.width,height:depth.height), [k.fx,k.fy,k.cx,k.cy] == context.intrinsics,
              k.cameraServiceSourceSHA256 == context.cameraServiceSourceSHA256,
              k.rgbOutputUndistorted == context.rgbOutputUndistorted, context.rgbOutputUndistorted,
              frame.cameraGeneration == context.scope.cameraGeneration,
              ROBArmRoutineVision.shared.cameraGeneration == context.scope.cameraGeneration,
              map.modelID == model.modelID, map.geometryID == model.geometryID, map.mappingID == model.selectedMappingID,
              map.cameraGeneration == context.scope.cameraGeneration, map.sessionGeneration == context.scope.gatewaySessionGeneration,
              map.registrationID == nil, map.estimatedCameraProjectionIdentity == nil,
              map.observedFrameCount == 3, map.observations.count == 3,
              (0...60_000).contains(Date().timeIntervalSince1970*1000-map.oldestCapturedAtMilliseconds),
              let readyAt = ROBFixedHeadCalibrationWindowController.shared.readNeck?()["ready_at"] as? Double,
              readyAt.isFinite,
              ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970*1000-map.oldestCapturedAtMilliseconds)/1000 >= readyAt,
              map.bodyMotionIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity,
              context.bodyMotionIdentity == map.bodyMotionIdentity else { return false }
        let matrix = (0..<4).flatMap { column in (0..<4).map { context.cameraToModel[column][$0] } }
        return map.observations.allSatisfy {
            $0.registrationID == nil && $0.estimatedCameraProjectionIdentity == nil && $0.estimatedDepthHypothesisID == context.depthHypothesisID &&
            $0.fixedHeadScope == context.scope && !$0.measuredSelfMaskApplied && $0.cameraToRobotColumnMajor == matrix
        }
    }

    /// Passive, unregistered raw/corrected union for the EMPTY RIGHT probe only.
    /// This never changes a head/arm hold or enters the registered grasp lane.
    @MainActor @nonobjc func captureEstimatedCurrentScene(model: ROBGhostRobotModel, generation: UInt64,
        context: ROBEstimatedFixedHeadCapture.Context, check: () throws -> Void,
        progress: (String) -> Void) async throws -> ROBWorkspaceCollisionSnapshot {
        collisionSnapshotValue = nil
        collisionSnapshotModel = model
        lastReport = ["status":"capturing_estimated_fixed_head_scene", "registration_verified":false,
            "grasp_authorized":false, "estimated_capture":context.metadata]
        do {
            let vision = ROBArmRoutineVision.shared
            let controller = ROBFixedHeadCalibrationWindowController.shared
            let bodyIdentity = ROBFixedHeadBodyMotionIdentity.currentIdentity
            let startedAt = Date().timeIntervalSince1970 * 1000
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            guard context.bodyMotionIdentity == bodyIdentity,
                  context.scope.gatewaySessionGeneration == generation, generation > 0,
                  context.depthHypothesisID.count == 64,
                  context.depthHypothesisID.allSatisfy(\.isHexDigit),
                  let readyAt = controller.readNeck?()["ready_at"] as? Double, readyAt.isFinite else {
                throw ROBWorkspaceDepthMapError.acquisition("The EMPTY RIGHT estimate no longer matches this held body/session context.")
            }
            func validate(_ frame: ROBArmRoutineVision.Frame) throws -> ROBFixedHeadRegistrationScope {
                try check(); try Task.checkCancellation()
                guard ROBFixedHeadBodyMotionIdentity.currentIdentity == bodyIdentity,
                      context.bodyMotionIdentity == bodyIdentity,
                      vision.cameraGeneration == context.scope.cameraGeneration,
                      frame.cameraGeneration == context.scope.cameraGeneration,
                      (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
                      controller.readNeck?()["ready_at"] as? Double == readyAt,
                      let depth = frame.depth, let k = frame.intrinsics,
                      depth.width == context.width, depth.height == context.height,
                      k.isValid(forWidth:depth.width,height:depth.height),
                      k.cameraServiceSourceSHA256 == context.cameraServiceSourceSHA256,
                      k.rgbOutputUndistorted == context.rgbOutputUndistorted, context.rgbOutputUndistorted,
                      [k.fx,k.fy,k.cx,k.cy] == context.intrinsics else {
                    throw ROBWorkspaceDepthMapError.acquisition("The estimated capture lost its exact held head/body or native RGB-D geometry.")
                }
                let scope = try controller.scope(model:model,frame:frame)
                guard scope.gatewaySessionGeneration == generation,
                      context.matches(currentScope:scope,model:model) else {
                    throw ROBWorkspaceDepthMapError.acquisition("The estimated camera/model/mapping/gateway scope changed; capture a new probe context.")
                }
                return scope
            }
            guard let initial = vision.snapshot()["face"] else { throw ROBWorkspaceDepthMapError.invalidFrame }
            _ = try validate(initial)
            var map = ROBWorkspaceDepthMap(modelID:model.modelID,geometryID:model.geometryID,
                mappingID:model.selectedMappingID,sessionGeneration:generation,cameraGeneration:context.scope.cameraGeneration)
            var previousSequence: UInt64 = 0, previousCapture = 0.0, frames = 0
            while frames < 3 {
                try check(); try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline,
                      map.bodyMotionIdentity == bodyIdentity,
                      map.bodyMotionIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity,
                      let current = vision.snapshot()["face"] else {
                    throw ROBWorkspaceDepthMapError.acquisition("Estimated capture expired or its stationary body context changed.")
                }
                _ = try validate(current)
                let frame = try await vision.settledDepthFrame()
                let scope = try validate(frame)
                if frames == 0, frame.capturedAt < startedAt {
                    // A retained fresh preview is not a post-start observation.
                    // Keep the same context and wait; never freshen its stamp.
                    try await Task.sleep(nanoseconds:50_000_000)
                    continue
                }
                guard frame.sequence >= previousSequence, frame.capturedAt >= previousCapture else {
                    throw ROBWorkspaceDepthMapError.acquisition("Estimated depth frames became old or reordered during the held capture.")
                }
                guard frame.sequence != previousSequence, frame.capturedAt != previousCapture else {
                    try await Task.sleep(nanoseconds:50_000_000)
                    continue
                }
                guard let depth = frame.depth, let k = frame.intrinsics else { throw ROBWorkspaceDepthMapError.invalidFrame }
                let inputMap = map
                map = try await Task.detached(priority:.userInitiated) {
                    var next = inputMap
                    try next.append(width:depth.width,height:depth.height,fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,
                        depth:{depth.distanceMillimeters(x:$0,y:$1)},cameraToRobot:context.cameraToModel,
                        capturedAtMilliseconds:frame.capturedAt,sequence:frame.sequence,cameraGeneration:frame.cameraGeneration,
                        measuredSelfBounds:[],cameraRegistrationVerified:false,
                        recordedPanDegrees:Double(scope.panTarget-6000)*0.03,
                        recordedUpperTarget:scope.upperTarget,recordedLowerTarget:scope.lowerTarget,
                        registration:nil,registrationScope:scope,
                        alternateEstimatedDepth:{ x,y in
                            context.correctedMillimeters(raw:depth.distanceMillimeters(x:x,y:y) ?? 0)
                        },estimatedDepthHypothesisID:context.depthHypothesisID)
                    return next
                }.value
                try check(); try Task.checkCancellation()
                guard map.bodyMotionIdentity == bodyIdentity,
                      map.bodyMotionIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity,
                      let current = vision.snapshot()["face"] else { throw ROBWorkspaceDepthMapError.invalidFrame }
                _ = try validate(current)
                previousSequence = frame.sequence; previousCapture = frame.capturedAt; frames += 1
                progress("Estimated EMPTY RIGHT scene: \(frames)/3 frames; raw and corrected returns retained.")
            }
            try check(); try Task.checkCancellation()
            guard map.bodyMotionIdentity == bodyIdentity,
                  map.bodyMotionIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity,
                  let current = vision.snapshot()["face"] else { throw ROBWorkspaceDepthMapError.invalidFrame }
            _ = try validate(current)
            guard let snapshot = map.snapshot(), snapshot.observedFrameCount == 3,
                  snapshot.registrationID == nil,
                  snapshot.bodyMotionIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity,
                  snapshot.observations.allSatisfy({$0.estimatedDepthHypothesisID == context.depthHypothesisID &&
                      $0.fixedHeadScope == context.scope && !$0.measuredSelfMaskApplied}) else {
                throw ROBWorkspaceDepthMapError.invalidFrame
            }
            collisionSnapshotValue = snapshot
            lastReport = ["status":"estimated_fixed_head_scene_captured", "registration_verified":false,
                "grasp_authorized":false, "physical_arm":"right", "scene_id":snapshot.sceneID.uuidString,
                "depth_frames":snapshot.observedFrameCount, "estimated_capture":context.metadata,
                "detail":"Unregistered EMPTY RIGHT probe; all raw and bounded corrected returns retained, no robot self mask or motion command."]
            return snapshot
        } catch {
            collisionSnapshotValue = nil
            lastReport = ["status":"estimated_fixed_head_capture_failed", "registration_verified":false,
                "grasp_authorized":false, "estimated_capture":context.metadata, "detail":error.localizedDescription]
            throw error
        }
    }

    /// Start every scene from current pixels while the arms remain held. A
    /// previous route, object location or map never authorizes parking first.
    @MainActor @nonobjc func scanCollisionScene(model: ROBGhostRobotModel, generation: UInt64,
        check: () throws -> Void, progress: (String) -> Void) async throws -> ROBWorkspaceCollisionSnapshot {
        collisionSnapshotValue = nil
        collisionSnapshotModel = model
        // A measured view is retained exactly, including its lower-neck target.
        // Legacy sweep preparation would command lower 6011 and invalidate it.
        if registeredCurrentView(model:model) != nil {
            return try await captureRegisteredCurrentScene(model:model,generation:generation,check:check,progress:progress)
        }
        let estimatedProjectionIdentity=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)
        try requireEstimatedProjectionIdentity(estimatedProjectionIdentity,model:model)
        let vision = ROBArmRoutineVision.shared
        var captureAnchor = ROBWorkspaceCaptureAnchor()
        var map:ROBWorkspaceDepthMap?
        let requestedViews = [-45.0,-15,15,45].map { ROBWorkspaceView(panDegrees:$0,upperTarget:5650) }
            + [30.0,0,-30].map { ROBWorkspaceView(panDegrees:$0,upperTarget:6306) }
        var views = requestedViews.map { ROBWorkspaceView(panDegrees:boundedPan?($0.panDegrees) ?? $0.panDegrees,upperTarget:$0.upperTarget) }
            .reduce(into:[ROBWorkspaceView]()) { if !$0.contains($1) { $0.append($1) } }
        // A local fixed-pose proof cannot be stretched across an unmeasured sweep.
        if let fixed = registeredCurrentView(model:model) { views = [fixed] }
        let scanStarted = Date().timeIntervalSince1970*1000
        var scanPhase = "initializing", currentView:ROBWorkspaceView?, failureDetail:String?
        var framesProjected = 0, frameSequence:UInt64 = 0, frameCapturedAt:Double?
        var lastPrepareAccepted = false, lastViewReady = false, completed = false
        func acquisitionFailure(_ reason:String) -> ROBWorkspaceDepthMapError {
            let view = currentView.map { String(format:"pan %+.1f, upper %d",$0.panDegrees,$0.upperTarget) } ?? "no selected view"
            let text = "\(scanPhase), \(view): \(reason)"
            failureDetail = text
            return .acquisition(text)
        }
        vision.beginCollisionRegistrationProbe()
        defer {
            if !completed {
                let failureReport:[String:Any] = ["status":"collision_scan_failed","detail":failureDetail ?? "Scan interrupted during \(scanPhase)",
                    "phase":scanPhase,"pan":currentView?.panDegrees ?? 0,"upper":currentView?.upperTarget ?? 0,
                    "frames_projected":framesProjected,"sequence":NSNumber(value:frameSequence),
                    "frame_age_ms":frameCapturedAt.map { Date().timeIntervalSince1970*1000-$0 } ?? -1,
                    "elapsed_ms":Date().timeIntervalSince1970*1000-scanStarted,
                    "prepare_accepted":lastPrepareAccepted,"view_ready":lastViewReady,
                    "expected_camera_generation":captureAnchor.cameraGeneration?.uuidString ?? "waiting_for_first_settled_frame","actual_camera_generation":vision.cameraGeneration.uuidString,
                    "expected_gateway_generation":NSNumber(value:generation),"gateway":ROBAmberGatewayClient.shared.connectionSnapshot(),
                    "camera_health":vision.healthSnapshot(),"markerless_registration_probe":vision.collisionRegistrationDiagnostics()]
                lastReport = failureReport as NSDictionary
            }
            vision.endCollisionRegistrationProbe(); finishView?()
        }
        for (index,view) in views.enumerated() {
            currentView = view; scanPhase = "checking scene identity"
            try check()
            try requireEstimatedProjectionIdentity(estimatedProjectionIdentity,model:model)
            guard captureAnchor.permitsCurrent(vision.cameraGeneration) else {
                throw acquisitionFailure("capture generation changed after the first projected frame (actual \(vision.cameraGeneration))")
            }
            guard (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == generation else {
                throw acquisitionFailure("authenticated Amber session changed before the view")
            }
            if canUseView?(view.panDegrees,view.upperTarget) == false { continue }
            progress("Scanning held-arm clearance: view \(index + 1) of \(views.count)")
            scanPhase = "settling neck view"
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            var settledSince: TimeInterval?
            while true {
                try check()
                lastPrepareAccepted = prepareView?(view.panDegrees,view.upperTarget) == true
                lastViewReady = viewReady?(view.panDegrees,view.upperTarget) == true
                if lastPrepareAccepted && lastViewReady {
                    settledSince = settledSince ?? ProcessInfo.processInfo.systemUptime
                    if ProcessInfo.processInfo.systemUptime - settledSince! >= 1.5 { break }
                } else { settledSince = nil }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw acquisitionFailure("neck did not maintain its 1.5 s settled interval within 8 s (prepareAccepted=\(lastPrepareAccepted), viewReady=\(lastViewReady), settledFor=\(settledSince.map { ProcessInfo.processInfo.systemUptime-$0 } ?? 0) s)")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            for _ in 0..<2 {
                scanPhase = "waiting for fresh settled RGB-D"
                let startupDeadline = ProcessInfo.processInfo.systemUptime+8
                var acceptedFrame:ROBArmRoutineVision.Frame?
                while acceptedFrame == nil {
                    try check(); try Task.checkCancellation()
                    let beforeCapture = vision.cameraGeneration
                    do {
                        let candidate = try await vision.settledDepthFrame()
                        if captureAnchor.accept(frameGeneration:candidate.cameraGeneration,currentGeneration:vision.cameraGeneration) {
                            acceptedFrame = candidate
                        } else if map != nil {
                            throw acquisitionFailure("capture generation changed after the first projected frame")
                        }
                    } catch {
                        try Task.checkCancellation(); try check()
                        guard captureAnchor.cameraGeneration == nil,
                              error is CancellationError || vision.cameraGeneration != beforeCapture else { throw acquisitionFailure(error.localizedDescription) }
                    }
                    guard acceptedFrame != nil || ProcessInfo.processInfo.systemUptime < startupDeadline else {
                        throw acquisitionFailure("camera startup did not provide one stable settled RGB-D generation within 8 s")
                    }
                }
                let frame = acceptedFrame!
                frameSequence = frame.sequence; frameCapturedAt = frame.capturedAt
                try check()
                guard captureAnchor.permitsCurrent(vision.cameraGeneration) else {
                    throw acquisitionFailure("captured frame belongs to a camera generation that changed before projection")
                }
                guard viewReady?(view.panDegrees,view.upperTarget) == true else { throw acquisitionFailure("neck left its settled view before projection") }
                try requireEstimatedProjectionIdentity(estimatedProjectionIdentity,model:model)
                let measured = registeredCameraContext(frame:frame,model:model)
                let estimated=measured == nil ? try unregisteredCameraProjection(frame:frame,view:view,model:model):nil
                let transform=measured?.registration.cameraToRobot ?? estimated!.matrix
                guard let depth = frame.depth else { throw acquisitionFailure("settled frame has no aligned depth") }
                guard let k = frame.intrinsics else { throw acquisitionFailure("settled frame has no camera intrinsics") }
                guard k.isValid(forWidth:depth.width,height:depth.height) else { throw acquisitionFailure("intrinsics are invalid for aligned depth \(depth.width)x\(depth.height)") }
                // Preserve actual measured arm FK for self geometry. An
                // unregistered camera never erases overlapping obstacles.
                let selfBounds = measuredSelfBounds(model:model)
                let currentMap = map ?? ROBWorkspaceDepthMap(modelID:model.modelID,geometryID:model.geometryID,
                    mappingID:model.selectedMappingID,sessionGeneration:generation,cameraGeneration:frame.cameraGeneration,
                    estimatedCameraProjectionIdentity:estimatedProjectionIdentity)
                let captured = frame.capturedAt, sequence = frame.sequence, cameraEpoch = frame.cameraGeneration
                scanPhase = "projecting depth frame \(sequence)"
                do {
                    map = try await Task.detached(priority:.userInitiated) {
                        var next = currentMap
                        try next.append(width:depth.width,height:depth.height,fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,
                            depth:{depth.distanceMillimeters(x:$0,y:$1)},cameraToRobot:transform,
                            capturedAtMilliseconds:captured,sequence:sequence,cameraGeneration:cameraEpoch,
                            measuredSelfBounds:selfBounds,cameraRegistrationVerified:false,
                            recordedPanDegrees:view.panDegrees,recordedUpperTarget:view.upperTarget,
                            recordedLowerTarget:measured?.scope.lowerTarget ?? estimated?.lowerTarget,
                            registration:measured?.registration,registrationScope:measured?.scope,
                            estimatedCameraProjectionIdentity:estimated?.identity)
                        return next
                    }.value
                } catch { throw acquisitionFailure(error.localizedDescription) }
                framesProjected += 1
                try check()
                try requireEstimatedProjectionIdentity(estimatedProjectionIdentity,model:model)
                guard viewReady?(view.panDegrees,view.upperTarget) == true else { throw acquisitionFailure("neck left its settled view while the depth frame was projected") }
            }
        }
        try check()
        scanPhase = "freezing scene snapshot"
        guard let finishedMap = map else { throw acquisitionFailure("no fresh settled depth frame enrolled a scene camera") }
        let frozen = await Task.detached(priority:.userInitiated) { finishedMap.snapshot() }.value
        try requireEstimatedProjectionIdentity(estimatedProjectionIdentity,model:model)
        guard captureAnchor.permitsCurrent(vision.cameraGeneration) else { throw acquisitionFailure("capture generation changed before the completed scene snapshot") }
        guard let snapshot = frozen else { throw acquisitionFailure("only \(framesProjected) fresh depth frames were projected; at least two are required") }
        collisionSnapshotValue = snapshot
        lastReport = ["status":"collision_scene_captured", "detail":snapshot.registrationDetail,
            "scene_id":snapshot.sceneID.uuidString,"depth_frames":snapshot.observedFrameCount,
            "occupied_voxels":snapshot.occupiedVoxelCount,"free_voxels":snapshot.freeVoxelCount,
            "registration_verified":snapshot.registrationID != nil,"markerless_registration_probe":vision.collisionRegistrationDiagnostics()]
        completed = true
        return snapshot
    }

    @MainActor @nonobjc private func measuredSelfBounds(model: ROBGhostRobotModel) -> [(low:SIMD3<Double>,high:SIMD3<Double>)] {
        let gateway = ROBAmberGatewayClient.shared
        let reference = ROBAmberArmReferenceStore.shared
        guard let left = gateway.telemetry(forArm:"right"), let right = gateway.telemetry(forArm:"left"),
              left.effectiveSampleAgeMilliseconds <= 250, right.effectiveSampleAgeMilliseconds <= 250,
              reference.readiness(forArm:"right").isReady, reference.readiness(forArm:"left").isReady,
              let rightModel = reference.modelPositions(fromVendor:right.positionsRadians.map(\.doubleValue),forArm:"left") else { return [] }
        var positions = model.positions(vendorLeft:left.positionsRadians.map(\.doubleValue))
        for (index,value) in rightModel.enumerated() { positions["right_joint\(index+1)"] = value }
        return Array(model.worldCollisionBounds(positions:positions).values)
    }

    /// Small value-only diagnostics can cross the worker boundary without
    /// retaining images, capture buffers or untyped report dictionaries.
    private struct BucketGeometryDiagnostics: Sendable {
        var reason = "detection_unusable"
        var box: [Double] = []
        var confidence: Double?
        var depthWidth = 0, depthHeight = 0
        var rgbWidth = 0, rgbHeight = 0
        var intrinsicsValid: Bool?
        var floorSampleCount = 0, floorMissingDepthCount = 0, floorOutOfRangeCount = 0
        var floorPointCount = 0, floorFinitePointCount = 0
        var floorCorrectionDegrees: Double?, floorSupportFraction: Double?
        var sceneSampleCount = 0, sceneMissingDepthCount = 0, sceneOutOfRangeCount = 0
        var scenePointCount = 0, rgbSampleCount = 0, orangePointCount = 0, rimTopBandPointCount = 0
        var rimRadiusMeters: Double?
        var report: [String: Any] {
            var value: [String: Any] = ["schema_version": 1,
                "status": reason == "grounded" ? "grounded" : "not_grounded", "reason": reason,
                "detection_box": box, "depth_width": depthWidth, "depth_height": depthHeight,
                "rgb_width": rgbWidth, "rgb_height": rgbHeight,
                "floor_sample_count": floorSampleCount, "floor_missing_depth_count": floorMissingDepthCount,
                "floor_out_of_range_count": floorOutOfRangeCount, "floor_point_count": floorPointCount,
                "floor_finite_point_count": floorFinitePointCount,
                "scene_sample_count": sceneSampleCount, "scene_missing_depth_count": sceneMissingDepthCount,
                "scene_out_of_range_count": sceneOutOfRangeCount, "scene_point_count": scenePointCount,
                "rgb_sample_count": rgbSampleCount, "orange_point_count": orangePointCount,
                "rim_top_band_point_count": rimTopBandPointCount]
            if let confidence, confidence.isFinite { value["detection_confidence"] = confidence }
            if let intrinsicsValid { value["intrinsics_valid"] = intrinsicsValid }
            if let floorCorrectionDegrees, floorCorrectionDegrees.isFinite { value["floor_camera_correction_degrees"] = floorCorrectionDegrees }
            if let floorSupportFraction, floorSupportFraction.isFinite { value["floor_support_fraction"] = floorSupportFraction }
            if let rimRadiusMeters, rimRadiusMeters.isFinite { value["rim_radius_m"] = rimRadiusMeters }
            return value
        }
    }

    @nonobjc private func bucketLocation(_ detection: ROBWorkspaceDetection, frame: ROBArmRoutineVision.Frame,
                                         view: ROBWorkspaceView, model: ROBGhostRobotModel, cameraToRobot:simd_double4x4? = nil, registrationID:String? = nil)
        -> (object: ROBWorkspaceLocatedObject?, diagnostics: BucketGeometryDiagnostics) {
        var diagnostics = BucketGeometryDiagnostics()
        diagnostics.confidence = detection.confidence
        if detection.box.allSatisfy(\.isFinite) { diagnostics.box = detection.box }
        guard detection.visuallyUsable else { return (nil, diagnostics) }
        guard detection.box[0] > 0.005, detection.box[2] < 0.995,
              detection.box[1] > 0.015, detection.box[3] < 0.985 else {
            diagnostics.reason = "clipped_box"; return (nil, diagnostics)
        }
        guard let depth = frame.depth else { diagnostics.reason = "missing_depth"; return (nil, diagnostics) }
        diagnostics.depthWidth = depth.width; diagnostics.depthHeight = depth.height
        guard let k = frame.intrinsics else { diagnostics.reason = "missing_intrinsics"; return (nil, diagnostics) }
        diagnostics.intrinsicsValid = k.isValid(forWidth: depth.width, height: depth.height)
        guard let transform = cameraToRobot ?? view.cameraFrame(model: model) else {
            diagnostics.reason = "camera_transform_unavailable"; return (nil, diagnostics)
        }
        guard let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(frame.image, from: frame.image.extent) else {
            diagnostics.reason = "rgb_unavailable"; return (nil, diagnostics)
        }
        diagnostics.rgbWidth = cg.width; diagnostics.rgbHeight = cg.height
        let pixels = NSBitmapImageRep(cgImage: cg)
        var floorPoints: [SIMD3<Double>] = []
        for y in stride(from: 0, to: depth.height, by: 6) { for x in stride(from: 0, to: depth.width, by: 6) {
            diagnostics.floorSampleCount += 1
            guard let mm = depth.distanceMillimeters(x: x,y: y) else { diagnostics.floorMissingDepthCount += 1; continue }
            guard (200...3000).contains(mm) else { diagnostics.floorOutOfRangeCount += 1; continue }
            let z = Double(mm)/1000, p = transform * SIMD4((Double(x)-k.cx)*z/k.fx,(Double(y)-k.cy)*z/k.fy,z,1)
            floorPoints.append(SIMD3(p.x,p.y,p.z))
        } }
        diagnostics.floorPointCount = floorPoints.count
        diagnostics.floorFinitePointCount = floorPoints.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }.count
        let floor = ROBWorkspaceFloorAlignment.fit(points: floorPoints,cameraFrame: transform)
        guard cameraToRobot != nil || floor != nil else {
            diagnostics.reason = "floor_fit_failed"; return (nil, diagnostics)
        }
        diagnostics.floorCorrectionDegrees = floor?.correctionDegrees; diagnostics.floorSupportFraction = floor?.supportFraction
        var orange: [SIMD3<Double>] = [], scene: [SIMD3<Double>] = []
        let left = Int(detection.box[0] * Double(cg.width-1)), right = Int(detection.box[2] * Double(cg.width-1))
        let top = Int(detection.box[1] * Double(cg.height-1)), bottom = Int(detection.box[3] * Double(cg.height-1))
        for y in stride(from: top, through: bottom, by: 2) { for x in stride(from: left, through: right, by: 2) {
            diagnostics.sceneSampleCount += 1
            let u = Double(x)/Double(cg.width-1) * Double(depth.width-1), v = Double(y)/Double(cg.height-1) * Double(depth.height-1)
            guard let mm = depth.distanceMillimeters(x: Int(u), y: Int(v)) else { diagnostics.sceneMissingDepthCount += 1; continue }
            guard (150...3000).contains(mm) else { diagnostics.sceneOutOfRangeCount += 1; continue }
            let measuredFrame = cameraToRobot ?? floor!.cameraFrame
            let z = Double(mm)/1000, p = measuredFrame * SIMD4((u-k.cx)*z/k.fx, (v-k.cy)*z/k.fy, z, 1)
            let point = SIMD3(p.x,p.y,p.z); scene.append(point)
            if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                diagnostics.rgbSampleCount += 1
                if color.redComponent >= 0.20, color.redComponent > color.greenComponent * 2,
                   color.redComponent > color.blueComponent * 2 { orange.append(point) }
            }
        } }
        diagnostics.scenePointCount = scene.count; diagnostics.orangePointCount = orange.count
        let finiteOrange = orange.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        if !finiteOrange.isEmpty {
            let heights = finiteOrange.map(\.z).sorted(), topHeight = heights[heights.count * 98 / 100]
            diagnostics.rimTopBandPointCount = finiteOrange.filter { abs($0.z-topHeight) <= 0.018 }.count
        }
        guard let rim = ROBWorkspaceBucketRim.fit(orange: orange, scene: scene) else {
            diagnostics.reason = "rim_fit_failed"; return (nil, diagnostics)
        }
        diagnostics.reason = "grounded"; diagnostics.rimRadiusMeters = rim.radius
        return (.init(target: .orangeBucket, position: [rim.center.x,rim.center.y,rim.center.z], confidence: detection.confidence,
            capturedAt: frame.capturedAt, sequence: frame.sequence, view: view, openingRadius: rim.radius,
            floorCorrectionDegrees: cameraToRobot == nil ? floor?.correctionDegrees : 0,registrationID:registrationID), diagnostics)
    }

    @MainActor @nonobjc func run(targets: [ROBWorkspaceTarget], model: ROBGhostRobotModel, requireDepth: Bool = true,
        check: () throws -> Void, progress: (String) -> Void) async throws -> [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] {
        let vision = ROBArmRoutineVision.shared
        locatedObjects = [:]
        collisionSnapshotValue = nil
        collisionSnapshotModel = model
        var sceneCaptureAnchor = ROBWorkspaceCaptureAnchor()
        let sceneGatewayGeneration = (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        let collectCollisionDepth = sceneGatewayGeneration > 0
        var collisionMap:ROBWorkspaceDepthMap?
        var collisionEnrollment = ROBWorkspaceFrameEnrollment()
        if collectCollisionDepth { vision.beginCollisionRegistrationProbe() }
        var found: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]
        var locationConfirmation = ROBWorkspaceLocationConfirmation()
        var visuallyFound = Set<ROBWorkspaceTarget>()
        var speech = ROBWorkspaceSearchSpeech()
        var announcements: [[String: Any]] = []
        var evidence: [[String: Any]] = []
        var leftHanging = false, rightHanging = false
        var validObservations = 0
        var observationCaptureAnchor = ROBWorkspaceCaptureAnchor()
        var observationWarmup = ROBWorkspaceObservationWarmup()
        var nearest: (view: ROBWorkspaceView, distance: Double)?
        var livePointing: (hint: ROBWorkspacePointingHint, view: ROBWorkspaceView, capturedAt: Double)?
        var followedLivePointing = false
        var recall = ROBWorkspaceRecall.load(model: model)
        let fixedRegisteredView = registeredCurrentView(model:model)
        let fixedContext = fixedRegisteredView.flatMap { _ in
            vision.snapshot()["face"].flatMap { registeredCameraContext(frame:$0,model:model) }
        }
        let estimatedProjectionIdentity=fixedContext == nil ? ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model):nil
        func requireSceneProjectionIdentity()throws {
            if fixedContext == nil {try requireEstimatedProjectionIdentity(estimatedProjectionIdentity,model:model)}
        }
        try requireSceneProjectionIdentity()
        func isViewReady(_ view: ROBWorkspaceView) -> Bool {
            guard let fixedContext else { return viewReady?(view.panDegrees,view.upperTarget) == true }
            guard view == fixedRegisteredView, let frame = vision.snapshot()["face"],
                  (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
                  let current = registeredCameraContext(frame:frame,model:model) else { return false }
            return current.scope == fixedContext.scope && current.registration.id == fixedContext.registration.id
        }
        let tabletopCanBaseHeight: Double?
        if targets.contains(.can), fixedRegisteredView == nil { tabletopCanBaseHeight = try ROBLeftCanReachCalibration.loadTabletopCanBaseHeight(model:model) }
        else { tabletopCanBaseHeight = nil }
        var selectedCanMeasurement: ROBWorkspaceLocatedObject?
        var schedule = ROBWorkspaceSearchSchedule(targets:targets,recall:recall,
            boundedPan:boundedPan ?? { max(-45,min(45,$0)) })
        let recalledViews = schedule.recallViews
        var bestRecallQuality: [ROBWorkspaceTarget: Double] = [:]
        var recenterViews: [(target: ROBWorkspaceTarget, view: ROBWorkspaceView)] = []
        var recenteredViews: [ROBWorkspaceView] = []
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
                "camera_arm_mapping": collisionSnapshotValue?.registrationID == nil
                    ? "provisional URDF/neck command prior, not measured hand-eye calibration"
                    : "measured fixed-head optical-to-robot registration; scoped local volume",
                "left_hanging_observed": leftHanging, "right_hanging_observed": rightHanging,
                "visually_confirmed": visuallyFound.map(\.rawValue).sorted(), "decoded_observations": validObservations,
                "announcements": announcements,
                "settle_seconds_per_view": 1.5,
                "depth_required": requireDepth,
                "recall_views": recalledViews.map { ["pan": $0.panDegrees, "upper": $0.upperTarget] },
                "historical_positions_used_for_motion": false,
                "collision_map_frames": collisionSnapshotValue?.observedFrameCount ?? 0,
                "collision_registration_verified": collisionSnapshotValue?.registrationID != nil,
                "markerless_registration_probe": vision.collisionRegistrationDiagnostics(),
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
            if collectCollisionDepth { vision.endCollisionRegistrationProbe() }
        }
        func accumulateCollisionDepth(_ view: ROBWorkspaceView, capturedFrame:ROBArmRoutineVision.Frame? = nil) async throws {
            guard collectCollisionDepth else { return }
            try check()
            try requireSceneProjectionIdentity()
            guard isViewReady(view) else {
                throw ROBWorkspaceDepthMapError.acquisition("Neck left the requested settled view before source-frame projection")
            }
            guard sceneCaptureAnchor.permitsCurrent(vision.cameraGeneration),
                  (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == sceneGatewayGeneration else {
                throw ROBWorkspaceDepthMapError.invalidFrame
            }
            // The capture callback runs before inference. Enroll exactly the
            // RGB-D frame whose pixels the detector will inspect while its
            // original capture age still passes projection, never a newer
            // substitute after inference or an old frame with a fresh timestamp.
            guard let frame = capturedFrame ?? vision.snapshot()["face"] else { return }
            switch collisionEnrollment.decision(sequence:frame.sequence,capturedAtMilliseconds:frame.capturedAt,
                nowMilliseconds:Date().timeIntervalSince1970*1000) {
            case .alreadyEnrolled: return
            case .invalid: throw ROBWorkspaceDepthMapError.acquisition("Detector source frame is stale, reordered or has a changed capture time")
            case .fresh: break
            }
            guard let depth = frame.depth, let k = frame.intrinsics,
                  k.isValid(forWidth:depth.width,height:depth.height) else { return }
            let measured = registeredCameraContext(frame:frame,model:model)
            if let fixedContext {
                guard measured?.scope == fixedContext.scope, measured?.registration.id == fixedContext.registration.id else {
                    throw ROBWorkspaceDepthMapError.acquisition("Fixed camera registration changed before source-frame projection")
                }
            }
            let estimated=measured == nil ? try unregisteredCameraProjection(frame:frame,view:view,model:model):nil
            let transform=measured?.registration.cameraToRobot ?? estimated!.matrix
            guard sceneCaptureAnchor.accept(frameGeneration:frame.cameraGeneration,currentGeneration:vision.cameraGeneration) else {
                if collisionMap == nil { return }
                throw ROBWorkspaceDepthMapError.acquisition("Capture generation changed after the first object-search depth frame")
            }
            var currentMap = collisionMap ?? ROBWorkspaceDepthMap(modelID:model.modelID,geometryID:model.geometryID,
                mappingID:model.selectedMappingID,sessionGeneration:sceneGatewayGeneration,cameraGeneration:frame.cameraGeneration,
                estimatedCameraProjectionIdentity:estimatedProjectionIdentity)
            if Date().timeIntervalSince1970*1000-currentMap.createdAtMilliseconds > 55_000 {
                currentMap = ROBWorkspaceDepthMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                    sessionGeneration:sceneGatewayGeneration,cameraGeneration:frame.cameraGeneration,
                    estimatedCameraProjectionIdentity:estimatedProjectionIdentity)
            }
            let selfBounds = measuredSelfBounds(model:model)
            let captured = frame.capturedAt, sequence = frame.sequence, cameraEpoch = frame.cameraGeneration
            let inputMap = currentMap
            collisionMap = try await Task.detached(priority:.userInitiated) {
                var next = inputMap
                try next.append(width:depth.width,height:depth.height,fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,
                    depth:{depth.distanceMillimeters(x:$0,y:$1)},cameraToRobot:transform,
                    capturedAtMilliseconds:captured,sequence:sequence,cameraGeneration:cameraEpoch,
                    measuredSelfBounds:selfBounds,cameraRegistrationVerified:false,
                    recordedPanDegrees:view.panDegrees,recordedUpperTarget:view.upperTarget,
                    recordedLowerTarget:measured?.scope.lowerTarget ?? estimated?.lowerTarget,
                    registration:measured?.registration,registrationScope:measured?.scope,
                    estimatedCameraProjectionIdentity:estimated?.identity)
                return next
            }.value
            collisionEnrollment.record(sequence:sequence,capturedAtMilliseconds:captured)
            try check()
            try requireSceneProjectionIdentity()
            guard isViewReady(view) else { throw ROBWorkspaceDepthMapError.invalidFrame }
        }
        func moveView(_ view: ROBWorkspaceView) async throws -> Bool {
            try requireSceneProjectionIdentity()
            if canUseView?(view.panDegrees, view.upperTarget) == false {
                evidence.append(["pan": view.panDegrees, "upper": view.upperTarget, "status": "outside_current_neck_envelope"])
                return false
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            var settledSince: TimeInterval?
            progress(String(format: "Local search: camera pan %+.0f°, tilt target %d", view.panDegrees, view.upperTarget))
            while ProcessInfo.processInfo.systemUptime < deadline {
                try check()
                let prepared = fixedContext != nil ? true : prepareView?(view.panDegrees,view.upperTarget) == true
                if prepared && isViewReady(view) {
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
            schedule.record(view)
            var priorVisual: [ROBWorkspaceTarget: (detection: ROBWorkspaceDetection, sequence: UInt64)] = [:]
            var priorHanging: ROBWorkspaceObservation?
            var priorPointing: ROBWorkspacePointingHint?
            var retryVisibleDepth = false
            for attempt in 0..<4 {
                if attempt >= 2 && (!requireDepth || !retryVisibleDepth) { break }
                retryVisibleDepth = false
                try check()
                guard isViewReady(view) else {
                    throw ROBArmRoutineError.blocked("Search camera moved during inspection.")
                }
                var acceptedWorkspace:(ROBWorkspaceObservation,ROBArmRoutineVision.Frame)?
                while acceptedWorkspace == nil {
                    try check(); try Task.checkCancellation()
                    guard observationCaptureAnchor.permitsCurrent(vision.cameraGeneration) else { throw CancellationError() }
                    guard isViewReady(view) else {
                        throw ROBArmRoutineError.blocked("Search camera moved during startup inspection.")
                    }
                    do {
                        let candidate = try await vision.observeWorkspace(objectDetection: !targets.isEmpty) { sourceFrame in
                            try await accumulateCollisionDepth(view,capturedFrame:sourceFrame)
                        }
                        guard observationCaptureAnchor.accept(frameGeneration:candidate.1.cameraGeneration,
                            currentGeneration:vision.cameraGeneration) else { throw CancellationError() }
                        acceptedWorkspace = candidate
                    }
                    catch is CancellationError {
                        try Task.checkCancellation(); try check()
                        guard observationWarmup.permitsRetry(acceptedObservation:validObservations > 0,
                            anchoredMap:sceneCaptureAnchor.cameraGeneration != nil || observationCaptureAnchor.cameraGeneration != nil,
                            taskCancelled:Task.isCancelled,
                            nowUptime:ProcessInfo.processInfo.systemUptime) else { throw CancellationError() }
                        progress("Waiting for camera startup.")
                        try await Task.sleep(nanoseconds:100_000_000)
                    }
                }
                let (observation,frame) = acceptedWorkspace!
                validObservations += 1
                try check()
                guard isViewReady(view) else {
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
                // A confirmed object does not need repeated geometry work in
                // every view while the camera searches for the other object.
                // The final age check below still requests fresh measurements.
                let measuredCamera = registeredCameraContext(frame:frame,model:model)
                try requireSceneProjectionIdentity()
                let estimatedCamera=measuredCamera == nil ? try unregisteredCameraProjection(frame:frame,view:view,model:model):nil
                // Passing nil retains the legacy per-object floor handling
                // when the photo-origin option is disabled.
                let cameraTransform=measuredCamera?.registration.cameraToRobot ??
                    (estimatedCamera?.identity != nil ? estimatedCamera?.matrix:nil)
                for target in targets where found[target] == nil {
                    var detection = observation[target]
                    var measurement: ROBWorkspaceLocatedObject?
                    if target == .can, let depth = frame.depth, let k = frame.intrinsics {
                        var candidates: [(detection: ROBWorkspaceDetection, object: ROBWorkspaceLocatedObject)] = []
                        var rejected = 0
                        for candidate in observation.cans ?? [observation.can] {
                            guard let sections = ROBWorkspaceCanSections.measure(detection:candidate,width:depth.width,height:depth.height,
                                fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,depth:{ depth.distanceMillimeters(x:$0,y:$1) },view:view,model:model,
                                cameraToRobot:cameraTransform),
                                  tabletopCanBaseHeight.map({ abs(sections.bottom[2]-$0) <= 0.15 }) ?? true else { rejected += 1; continue }
                            let object = ROBWorkspaceLocatedObject(target:.can,position:sections.middle,confidence:candidate.confidence,
                                capturedAt:frame.capturedAt,sequence:frame.sequence,view:view,sections:sections,registrationID:measuredCamera?.registration.id)
                            guard (try? ROBLeftCanReachCalibration.load(model:model,can:object)) != nil else { rejected += 1; continue }
                            candidates.append((candidate,object))
                        }
                        // Keep the same currently observed instance across
                        // frames; a remembered point only ranks fresh objects.
                        let selected: (detection: ROBWorkspaceDetection, object: ROBWorkspaceLocatedObject)?
                        if let prior = selectedCanMeasurement,
                           let nearest = candidates.min(by:{ simd_distance($0.object.point,prior.point) < simd_distance($1.object.point,prior.point) }),
                           simd_distance(nearest.object.point,prior.point) <= 0.05 {
                            selected = nearest
                        } else { selected = candidates.max(by:{ $0.object.confidence < $1.object.confidence }) }
                        if let selected {
                            detection = selected.detection; measurement = selected.object
                            selectedCanMeasurement = selected.object
                        }
                        entry["visible_table_cans"] = candidates.map { candidate -> [String: Any] in
                            let object = candidate.object, sections = object.sections!
                            return ["box":candidate.detection.box,"confidence":object.confidence,"position":object.position,
                                "top":sections.top,"middle":sections.middle,"base":sections.bottom,
                                "height_m":sections.heightMeters,"diameter_m":sections.diameterMeters,
                                "calibrated_middle_height_m":(tabletopCanBaseHeight ?? sections.bottom[2])+sections.heightMeters/2,
                                "selected":selected.map({ $0.detection.box == candidate.detection.box }) ?? false]
                        }
                        entry["rejected_can_instances"] = rejected
                        if let tabletopCanBaseHeight { entry["tabletop_can_base_height_m"] = tabletopCanBaseHeight }
                    }
                    if detection.visuallyUsable, let previous = priorVisual[target], previous.sequence != frame.sequence,
                       hypot(detection.center[0] - previous.detection.center[0], detection.center[1] - previous.detection.center[1]) <= 0.08 {
                        if target != .can || tabletopCanBaseHeight == nil || measurement != nil { visuallyFound.insert(target) }
                        if found[target] == nil {
                            let centered = ROBWorkspaceRecall.Sighting(target: target, view: view, box: detection.box,
                                confidence: detection.confidence, capturedAt: frame.capturedAt).centeredView
                            if abs(centered.panDegrees - view.panDegrees) > 5 || abs(centered.upperTarget - view.upperTarget) > 180 {
                                recenterViews.append((target,centered))
                            }
                        }
                    }
                    if detection.visuallyUsable { priorVisual[target] = (detection, frame.sequence) }
                    else { priorVisual.removeValue(forKey: target) }
                    if target == .orangeBucket {
                        let bucket = await Task.detached(priority: .userInitiated) {
                            self.bucketLocation(detection, frame: frame, view: view, model: model,
                                cameraToRobot:cameraTransform,registrationID:measuredCamera?.registration.id)
                        }.value
                        measurement = bucket.object
                        entry["bucket_geometry"] = bucket.diagnostics.report
                        try check()
                        try requireSceneProjectionIdentity()
                        guard isViewReady(view) else{throw ROBWorkspaceDepthMapError.invalidFrame}
                    }
                    else if measurement == nil, tabletopCanBaseHeight == nil, let depth = frame.depth, let k = frame.intrinsics {
                        measurement = ROBWorkspaceGrounding.locate(target: target, detection: detection,
                            width: depth.width, height: depth.height, fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy,
                            depth: { depth.distanceMillimeters(x: $0, y: $1) }, view: view, model: model,
                            capturedAt: frame.capturedAt, sequence: frame.sequence,
                            cameraToRobot:cameraTransform,registrationID:measuredCamera?.registration.id)
                    }
                    guard let located = measurement else {
                        if detection.visuallyUsable, found[target] == nil { retryVisibleDepth = true }
                        entry[target.rawValue] = "not_grounded"; continue
                    }
                    if let registration = measuredCamera?.registration,
                       !registration.validRobotVolume.contains(located.point) {
                        entry[target.rawValue] = "outside_fixed_head_registration_volume"; continue
                    }
                    var geometry: [String: Any] = ["position": located.position, "confidence": located.confidence]
                    if let radius = located.openingRadius { geometry["opening_radius_m"] = radius }
                    if let correction = located.floorCorrectionDegrees { geometry["floor_camera_correction_degrees"] = correction }
                    entry[target.rawValue] = geometry
                    if let confirmed = locationConfirmation.observe(located) {
                        found[target] = confirmed
                        // The first fresh confirmed measurement replaces any
                        // historical hint, even after an object was moved. Keep
                        // the best confirmed view seen during this search.
                        let quality = ROBWorkspaceSearchSchedule.recallQuality(detection.box)
                        if bestRecallQuality[target].map({ quality > $0 }) ?? true {
                            bestRecallQuality[target] = quality
                            recall.remember(target:target,detection:detection,view:view,capturedAt:frame.capturedAt)
                            do { try recall.save() } catch { entry["recall_save_error"] = error.localizedDescription }
                        }
                    }
                    else {
                        found.removeValue(forKey:target)
                        retryVisibleDepth = true
                    }
                }
                evidence.append(entry)
                if !targets.isEmpty && targetsConfirmed() { break }
                if targets.isEmpty && leftHanging && rightHanging { break }
            }
            if let message = speech.confirmed(visuallyFound, targets: targets) {
                announce?(message)
                announcements.append(["message": message, "at": ISO8601DateFormatter().string(from: Date()),
                    "visually_confirmed": visuallyFound.map(\.rawValue).sorted()])
                progress(message)
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
        if !recalledViews.isEmpty { announce?("Checking where I last saw them.") }
        var viewIndex = 0
        var fixedViewPending = fixedRegisteredView
        while let view = fixedRegisteredView != nil ? fixedViewPending : schedule.next(confirmed:requireDepth ? Set(found.keys) : visuallyFound) {
            fixedViewPending = nil
            viewIndex += 1
            progress("Searching view \(viewIndex) of up to \(schedule.plannedViewCount)")
            try await inspectWithRetry(view)
            // A partial object at the image edge warrants looking directly
            // at it before continuing the raster, especially a bucket rim.
            while fixedRegisteredView == nil, !targetsConfirmed(), !recenterViews.isEmpty, recenteredViews.count < 4 {
                let candidate = recenterViews.removeFirst(), centered = candidate.view
                guard found[candidate.target] == nil, !schedule.hasAttempted(centered),
                      !recenteredViews.contains(where: { abs($0.panDegrees - centered.panDegrees) < 5 && abs($0.upperTarget - centered.upperTarget) < 150 }) else { continue }
                recenteredViews.append(centered)
                try await inspectWithRetry(centered)
                persist("searching", "Centered a remembered or partially visible object; taking new measurements")
            }
            if fixedRegisteredView == nil, !targets.isEmpty, !followedLivePointing, let pointing = livePointing,
               Date().timeIntervalSince1970 * 1000 - pointing.capturedAt < 15_000,
               targets.contains(where: { !visuallyFound.contains($0) }) {
                followedLivePointing = true
                announce?("Following your pointing direction.")
                try await followPointing(pointing.hint, from: pointing.view)
            }
            persist("searching", "Completed search view \(viewIndex); confirmed targets skip their remaining attention hints")
            if targets.isEmpty ? leftHanging && rightHanging : targetsConfirmed() { break }
        }
        if fixedRegisteredView == nil, validObservations > 0, !targets.isEmpty, targets.contains(where: { !visuallyFound.contains($0) }) {
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
                    guard isViewReady(humanView) else {
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
                locationConfirmation.invalidate(target)
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
        if let collisionMap {
            let frozen = await Task.detached(priority:.userInitiated) { collisionMap.snapshot() }.value
            try check()
            try requireSceneProjectionIdentity()
            guard sceneCaptureAnchor.permitsCurrent(vision.cameraGeneration) else { throw ROBWorkspaceDepthMapError.invalidFrame }
            collisionSnapshotValue = frozen
        }
        try requireSceneProjectionIdentity()
        finished = true
        locatedObjects = found
        persist(status, message)
        return found
    }
}
