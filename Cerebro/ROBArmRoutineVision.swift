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
        capturedAtMilliseconds: Double?, runtimeCalibrationIdentity: String? = nil) -> Update {
        let nextSignature = "\(streamID ?? "unknown")|\(source)|\(width ?? 0)x\(height ?? 0)|"
            + (intrinsics?.map { String($0.bitPattern) }.joined(separator:",") ?? "no-intrinsics")
            + "|runtime:" + (runtimeCalibrationIdentity ?? "legacy")
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
    private var observedJawFullHeightDemand = false
    private var teaching = false
    private var epoch = UUID()
    private var captureIdentity = ROBVisionCaptureIdentity()
    private var runtimeContextEnrolled = false
    private var expectedRuntimeCalibrationIdentity: String?
    private var busy: Set<String> = []
    private var lastOffer: [String: TimeInterval] = [:]
    private var inputNotes: [String: String] = [:]
    private var lastIncomingCapture: Double?
    private var lastIncomingSequence: UInt64 = 0
    private var processingMilliseconds: Double = 0
    private var frames: [String: Frame] = [:]
    private var lastInspection: [String: Any] = [:]
    private var lastSettlingDiagnostics: [String: Any] = [:]
    private let collisionRegistrationProbe = ROBMarkerlessVisionService()
    private var collisionProbeActive = false
    private var collisionProbeObservation: [String: Any] = [:]

    var cameraGeneration: UUID { lock.lock(); defer { lock.unlock() }; return captureIdentity.generation }
    var fullHeightTaskObservationRequested: Bool { lock.lock(); defer { lock.unlock() }; return observedJawFullHeightDemand }

    /// A user-applied head-depth correction changes every projected coordinate.
    /// Drop in-flight inference and enroll fresh frames in a new generation.
    func depthAlignmentDidChange() {
        lock.lock(); defer { lock.unlock() }
        captureIdentity = ROBVisionCaptureIdentity()
        epoch = UUID(); frames = [:]; busy = []; lastOffer = [:]
        lastInspection = [:]; lastSettlingDiagnostics=[:]; inputNotes = [:]
        lastIncomingCapture = nil; lastIncomingSequence = 0; processingMilliseconds = 0
    }

    /// Runs at camera ingress, before a queued delegate can publish old pixels.
    /// Pending inference loses its epoch and old-runtime callbacks are rejected.
    func updateRuntimeCalibrationContext(_ identity: String?) {
        lock.lock(); defer { lock.unlock() }
        if runtimeContextEnrolled && expectedRuntimeCalibrationIdentity != identity {
            captureIdentity = ROBVisionCaptureIdentity()
            epoch = UUID(); frames = [:]; busy = []; lastOffer = [:]
            lastInspection = [:]; lastSettlingDiagnostics=[:]; inputNotes = [:]
            lastIncomingCapture = nil; lastIncomingSequence = 0; processingMilliseconds = 0
        }
        runtimeContextEnrolled = true; expectedRuntimeCalibrationIdentity = identity
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
        if !value {observedJawFullHeightDemand=false}
        lastIncomingCapture = nil; lastIncomingSequence = 0; processingMilliseconds = 0
        lastSettlingDiagnostics=[:]
        if value { lastInspection = [:] }
    }

    /// A standing task may enroll its camera before freezing a fresh job.
    /// Keeping an already-active consumer intact avoids erasing valid frames
    /// or invalidating in-flight inspection merely because Run was requested.
    func ensureActiveForTaskObservation() {
        lock.lock(); defer { lock.unlock() }
        observedJawFullHeightDemand=true
        guard !active else {return}
        active=true;teaching=false;epoch=UUID();frames=[:];busy=[];lastOffer=[:];inputNotes=[:]
        lastIncomingCapture=nil;lastIncomingSequence=0;processingMilliseconds=0;lastInspection=[:];lastSettlingDiagnostics=[:]
    }

    func offer(_ frame: CameraFrameSet, role: CameraRole) {
        // Main face camera owns live clearance. A stale belly stream must not
        // delay it or contribute pixels to a supposedly current observation.
        guard role == .face else { return }
        let key = role.rawValue, now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let runtimeIdentity = frame.intrinsics?.runtimeCalibration?.identity
        guard !runtimeContextEnrolled || runtimeIdentity == expectedRuntimeCalibrationIdentity else {
            lock.unlock(); return
        }
        let identityUpdate = captureIdentity.observe(streamID:frame.captureStreamID,source:frame.source.rawValue,
            width:frame.alignedDepth?.width,height:frame.alignedDepth?.height,
            intrinsics:frame.intrinsics.map { [$0.fx,$0.fy,$0.cx,$0.cy] },sequence:frame.sequence,
            timestampNanoseconds:frame.timestampNanoseconds,capturedAtMilliseconds:frame.capturedAtMilliseconds,
            runtimeCalibrationIdentity:runtimeIdentity)
        if identityUpdate == .reordered { lock.unlock(); return }
        if identityUpdate == .changed {
            // Capture identity changes also cancel any pending analysis answer.
            epoch = UUID(); frames = [:]; busy = []; lastOffer = [:]
            lastSettlingDiagnostics=[:]
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

    /// Observed RGB-D for the jaw tracker. This adapter supplies no projected
    /// tool location: only independently observed edges/motion in these pixels
    /// may become jaw evidence. The caller freezes the actual held head/body
    /// scope and supplies synchronized measured joints, never commanded ones.
    func makeGripperVisualServoFrame(frame: Frame, scopeIdentity: String,
        jointPositions: [Double], jointCapturedAtMilliseconds: Double,
        poseHeldDuringCapture: Bool,
        openingCommandAtMilliseconds: Double? = nil,
        nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000) throws -> ROBGripperVisualServo.Frame {
        guard nowMilliseconds.isFinite, frame.capturedAt.isFinite,
              (0...700).contains(nowMilliseconds-frame.capturedAt), frame.sequence>0,
              frame.cameraGeneration==cameraGeneration, frame.handsClear,
              !scopeIdentity.isEmpty, scopeIdentity.utf8.count<=8192,
              poseHeldDuringCapture, jointPositions.count==7,
              jointPositions.allSatisfy(\.isFinite), jointCapturedAtMilliseconds.isFinite,
              openingCommandAtMilliseconds.map({$0.isFinite && (0...30_000).contains(nowMilliseconds-$0)}) ?? true,
              // Exposure-matched historical feedback is distinct from live
              // dispatch feedback, which the executor checks independently.
              (0...700).contains(nowMilliseconds-jointCapturedAtMilliseconds),
              abs(frame.capturedAt-jointCapturedAtMilliseconds)<=150,
              let depth=frame.depth, let k=frame.intrinsics,
              depth.width>0, depth.height>0,
              k.isValid(forWidth:depth.width,height:depth.height),
              k.rgbOutputUndistorted==true,
              k.depthRGBGeometryCorrespondence?.status=="matched",
              let source=context.createCGImage(frame.image,from:frame.image.extent),
              source.width==depth.width, source.height==depth.height else {
            throw ROBVisualGraspVerifier.Unavailable.evidence("Observed-jaw tracking needs current native aligned RGB-D, a held scope and synchronized measured joint feedback.")
        }
        let width=min(320,source.width)
        let height=max(1,Int((Double(source.height)*Double(width)/Double(source.width)).rounded()))
        var rgba=[UInt8](repeating:0,count:width*height*4)
        let rendered=rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let drawing=CGContext(data:bytes.baseAddress,width:width,height:height,
                bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {return false}
            drawing.interpolationQuality = .high
            // Same top-left raster convention as makeVisualGraspSample.
            drawing.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard rendered else {throw ROBVisualGraspVerifier.Unavailable.evidence("Could not materialize the observed jaw RGB raster.")}
        var rgb=Data(count:width*height*3)
        rgb.withUnsafeMutableBytes { destination in
            let bytes=destination.bindMemory(to:UInt8.self)
            for pixel in 0..<(width*height) {
                bytes[pixel*3]=rgba[pixel*4];bytes[pixel*3+1]=rgba[pixel*4+1];bytes[pixel*3+2]=rgba[pixel*4+2]
            }
        }
        var millimeters=[UInt16](repeating:0,count:width*height)
        for y in 0..<height {for x in 0..<width {
            let dx=min(depth.width-1,Int((Double(x)+0.5)*Double(depth.width)/Double(width)))
            let dy=min(depth.height-1,Int((Double(y)+0.5)*Double(depth.height)/Double(height)))
            if let mm=depth.distanceMillimeters(x:dx,y:dy),mm>0 {millimeters[y*width+x]=mm}
        }}
        let sx=Double(width)/Double(depth.width),sy=Double(height)/Double(depth.height)
        return .init(width:width,height:height,rgb:rgb,depthMillimeters:millimeters,
            fx:k.fx*sx,fy:k.fy*sy,cx:(k.cx+0.5)*sx-0.5,cy:(k.cy+0.5)*sy-0.5,
            sequence:frame.sequence,capturedAtMilliseconds:frame.capturedAt,scopeIdentity:scopeIdentity,
            jointPositions:jointPositions,jointCapturedAtMilliseconds:jointCapturedAtMilliseconds,
            poseHeldDuringCapture:poseHeldDuringCapture,openingCommandAtMilliseconds:openingCommandAtMilliseconds)
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
                "inspection": lastInspection,"settling":lastSettlingDiagnostics]
    }

    private func isFresh(_ frame: Frame) -> Bool {
        (0 ... 700).contains(Date().timeIntervalSince1970 * 1000 - frame.capturedAt)
            && frame.depthCoverage >= 0.25
    }

    /// Nonactuating depth mapping may use a partly populated native depth
    /// raster. Each ray still has to pass the depth mapper's existing local
    /// consistency tests; missing pixels never create free space. Ordinary
    /// inspection, human clearance and motion keep their25% coverage gate.
    private func isDepthMappingEligible(_ frame:Frame)->Bool {
        guard frame.capturedAt.isFinite,(0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
              frame.sequence>0,frame.cameraGeneration==cameraGeneration,
              frame.depthCoverage.isFinite,frame.depthCoverage>0,frame.depthCoverage<=1,
              let depth=frame.depth,depth.width>0,depth.height>0,
              let k=frame.intrinsics,k.isValid(forWidth:depth.width,height:depth.height) else {return false}
        return true
    }

    private func inspectionEpoch() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
        return epoch
    }

    /// Depth-only settled capture: no LLM/object inference and no arm command.
    func settledDepthFrame(deadlineUptime:Double?=nil) async throws -> Frame {
        try await settledInspectionFrame(epoch: inspectionEpoch(), requireStaticScene: true,deadlineUptime:deadlineUptime,depthMappingOnly:true)
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

    private func recordSettlingDiagnostics(_ details:[String:Any],epoch token:UUID) {
        lock.lock();defer{lock.unlock()}
        guard epoch==token else{return}
        lastSettlingDiagnostics=details
    }

    // Preserve the existing veto exactly. This is not a clearance classifier;
    // no brightness compensation, image registration or relaxed threshold can
    // hide an object or viewpoint change from the semantic freshness check.
    static func sceneChangeFraction(_ before: [UInt8], _ after: [UInt8]) -> Double? {
        guard before.count == 64 * 48 * 4, before.count == after.count else { return nil }
        let changed = zip(before, after).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 24 ? 1 : 0) }
        return Double(changed) / Double(before.count)
    }

    /// Diagnostic facts only. Admission still comes exclusively from the
    /// existing isFresh/isDepthMappingEligible call in the settling loop.
    private static func settledFrameDiagnostics(_ frame:Frame?,eligible:Bool,depthMappingOnly:Bool,
        notBefore:Double,nowMilliseconds:Double,currentGeneration:UUID)->(facts:[String:Any],failed:[String]) {
        guard let frame else {return ( ["frame_present":false,"eligible":false], ["no_analyzed_frame"] )}
        func number(_ value:Double)->Any {value.isFinite ? value as Any:NSNull()}
        let age=nowMilliseconds-frame.capturedAt
        let dimensionsValid=frame.depth.map{$0.width>0 && $0.height>0} ?? false
        let intrinsicsValid=frame.depth.flatMap {depth in frame.intrinsics.map{$0.isValid(forWidth:depth.width,height:depth.height)}} ?? false
        var failed:[String]=[]
        if !frame.capturedAt.isFinite {failed.append("nonfinite_capture_time")}
        else {
            if age<0 {failed.append("future_exposure")}
            if age>700 {failed.append("exposure_older_than_700ms")}
            if frame.capturedAt<notBefore {failed.append("captured_before_acquisition")}
        }
        if depthMappingOnly {
            if frame.sequence==0 {failed.append("zero_sequence")}
            if frame.cameraGeneration != currentGeneration {failed.append("camera_generation_mismatch")}
            if !frame.depthCoverage.isFinite || frame.depthCoverage>1 {failed.append("invalid_depth_coverage")}
            else if frame.depthCoverage<=0 {failed.append("no_sparse_depth")}
            if frame.depth==nil {failed.append("missing_depth")}
            else if !dimensionsValid {failed.append("invalid_depth_dimensions")}
            if frame.intrinsics==nil {failed.append("missing_intrinsics")}
            else if !intrinsicsValid {failed.append("invalid_intrinsics")}
        } else if !(frame.depthCoverage>=0.25) {
            failed.append("ordinary_depth_coverage_below_25_percent")
        }
        if !eligible && failed.isEmpty {failed.append("eligibility_rejected_without_classified_condition")}
        let imu=frame.intrinsics?.inertial
        return (["frame_present":true,"eligible":eligible,"sequence":NSNumber(value:frame.sequence),
            "capture_age_ms":number(age),"capture_time_ms":number(frame.capturedAt),
            "captured_after_acquisition":frame.capturedAt>=notBefore,
            "frame_camera_generation":frame.cameraGeneration.uuidString,
            "current_camera_generation":currentGeneration.uuidString,
            "depth_coverage":number(frame.depthCoverage),"depth_present":frame.depth != nil,
            "depth_dimensions_valid":dimensionsValid,"intrinsics_present":frame.intrinsics != nil,
            "intrinsics_valid_for_depth_dimensions":intrinsicsValid,
            "imu_present":imu != nil,"imu_valid":imu?.isValid ?? false,"imu_stationary":imu?.stationary ?? false,
            "imu_window_ms":imu.map{number($0.windowMilliseconds)} ?? NSNull(),
            "imu_sample_count":imu.map{$0.sampleCount as Any} ?? NSNull(),
            "imu_age_ms":imu.map{number($0.ageMilliseconds)} ?? NSNull()],failed)
    }

    private func settledInspectionFrame(epoch token: UUID, requireStaticScene: Bool = true,deadlineUptime:Double?=nil,
        depthMappingOnly:Bool=false,allowStationaryIMUPassiveFrame:Bool=false) async throws -> Frame {
        // Called only when the coordinator has stopped motion and the GPU is
        // ready. A previously captured frame may still depict the neck/arms
        // settling, even though the latest commanded pose is now stationary.
        let notBefore = Date().timeIntervalSince1970 * 1000
        let deadline = min(ProcessInfo.processInfo.systemUptime+3,deadlineUptime ?? .infinity)
        var anchor: Frame?, previous: Frame?
        var distinctSamples = 0
        var pollCount=0,duplicatePolls=0,acceptedDistinctFrames=0,gapResets=0,staticResets=0
        var maximumCaptureGapMilliseconds=0.0
        var conditionPollCounts:[String:Int]=[:],latestFrameFacts:[String:Any]=[:]
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let candidate=try inspectionFrame(epoch:token)
            let eligible=candidate.map{depthMappingOnly ? isDepthMappingEligible($0):isFresh($0)} ?? false
            let diagnostics=Self.settledFrameDiagnostics(candidate,eligible:eligible,depthMappingOnly:depthMappingOnly,
                notBefore:notBefore,nowMilliseconds:Date().timeIntervalSince1970*1000,currentGeneration:cameraGeneration)
            pollCount+=1;latestFrameFacts=diagnostics.facts
            for condition in diagnostics.failed {conditionPollCounts[condition,default:0]+=1}
            if allowStationaryIMUPassiveFrame,depthMappingOnly,!requireStaticScene {
                if let imu=candidate?.intrinsics?.inertial {
                    if !imu.isValid {conditionPollCounts["single_frame_imu_invalid",default:0]+=1}
                    if !imu.stationary {conditionPollCounts["single_frame_imu_not_stationary",default:0]+=1}
                    if imu.windowMilliseconds<300 {conditionPollCounts["single_frame_imu_window_below_300ms",default:0]+=1}
                    if imu.sampleCount<20 {conditionPollCounts["single_frame_imu_samples_below_20",default:0]+=1}
                } else {conditionPollCounts["single_frame_imu_unavailable",default:0]+=1}
            }
            if let frame = candidate,eligible,frame.capturedAt >= notBefore {
                // Object attention sends no arm command and grants no human
                // clearance. Its actual same-exposure stationary IMU window
                // can establish a held view without requiring three costly
                // hand/person analyses less than700ms apart. Mapping/static
                // captures and every ordinary motion inspection retain their
                // existing three-frame path and freshness/clearance gates.
                if allowStationaryIMUPassiveFrame,depthMappingOnly,!requireStaticScene,
                   let imu=frame.intrinsics?.inertial,imu.isValid,imu.stationary,
                   imu.windowMilliseconds>=300,imu.sampleCount>=20 {
                    recordSettlingDiagnostics(["schema_version":1,"status":"accepted",
                        "method":"stationary_imu_single_actual_post_call_frame","depth_mapping_only":true,
                        "static_scene_required":false,"recorded_at_ms":Date().timeIntervalSince1970*1000,
                        "latest_frame":diagnostics.facts,"poll_count":pollCount,"capture_time_refreshed":false,
                        "motion_authority":false,"human_clearance_granted":false],epoch:token)
                    return frame
                }
                if let previous, frame.sequence < previous.sequence || frame.capturedAt < previous.capturedAt {
                    throw ROBArmRoutineError.blocked("The camera stream restarted during inspection.")
                }
                if previous?.sequence != frame.sequence {
                    acceptedDistinctFrames+=1
                    guard let difference = Self.sceneChangeFraction(anchor?.thumbnail ?? frame.thumbnail, frame.thumbnail) else {
                        throw ROBArmRoutineError.blocked("The inspected camera view is unavailable.")
                    }
                    if let previous {
                        let gap=frame.capturedAt-previous.capturedAt
                        maximumCaptureGapMilliseconds=max(maximumCaptureGapMilliseconds,gap)
                        if gap>700 {gapResets+=1}
                    }
                    if requireStaticScene && difference>=0.025 {staticResets+=1}
                    if anchor == nil || (requireStaticScene && difference >= 0.025) ||
                        previous.map({ frame.capturedAt - $0.capturedAt > 700 }) == true {
                        anchor = frame; distinctSamples = 0
                    }
                    distinctSamples += 1
                    previous = frame
                    if let anchor, distinctSamples >= 3, frame.capturedAt - anchor.capturedAt >= 300 {
                        recordSettlingDiagnostics(["schema_version":1,"status":"accepted",
                            "method":"three_distinct_actual_exposures","depth_mapping_only":depthMappingOnly,
                            "static_scene_required":requireStaticScene,"recorded_at_ms":Date().timeIntervalSince1970*1000,
                            "latest_frame":diagnostics.facts,"distinct_samples_since_anchor":distinctSamples,
                            "capture_span_since_anchor_ms":frame.capturedAt-anchor.capturedAt,
                            "capture_gap_resets":gapResets,"static_scene_resets":staticResets,"capture_time_refreshed":false],epoch:token)
                        return frame
                    }
                } else {duplicatePolls+=1}
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let span=anchor.flatMap{a in previous.map{$0.capturedAt-a.capturedAt}} ?? 0
        var diagnostics:[String:Any]=["schema_version":1,"kind":"settled_capture_timeout_diagnostics_only","status":"timeout",
            "depth_mapping_only":depthMappingOnly,"static_scene_required":requireStaticScene,
            "stationary_imu_passive_frame_allowed":allowStationaryIMUPassiveFrame,
            "poll_count":pollCount,"failed_condition_poll_counts":conditionPollCounts,
            "accepted_distinct_frames":acceptedDistinctFrames,"distinct_samples_since_anchor":distinctSamples,
            "capture_span_since_anchor_ms":span.isFinite ? span as Any:NSNull(),"duplicate_polls":duplicatePolls,
            "capture_gap_resets":gapResets,"static_scene_resets":staticResets,
            "maximum_accepted_capture_gap_ms":maximumCaptureGapMilliseconds,
            "latest_frame":latestFrameFacts,"recorded_at_ms":Date().timeIntervalSince1970*1000,"capture_time_refreshed":false]
        let health=healthSnapshot()
        var healthFields:[String:Any]=[:]
        for key in ["active","input_sequence","input_age_ms","analysis_age_ms","analysis_ms","depth_coverage","hands_clear","note"] {
            healthFields[key]=health[key]
        }
        diagnostics["camera_health"]=healthFields
        recordSettlingDiagnostics(diagnostics,epoch:token)
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
    func observeWorkspace(objectDetection: Bool = true,nonactuatingSparseDepth:Bool = false,
        onCaptured: @MainActor (Frame) async throws -> Void = { _ in }) async throws -> (ROBWorkspaceObservation, Frame) {
        if objectDetection {
            try await ROBWorkspaceObjectDetector.shared.warmUp()
            try Task.checkCancellation()
            let token = try inspectionEpoch()
            // Passive search may inspect sparse depth without hiding readable
            // RGB objects. Other callers retain ordinary readiness admission.
            let frame = try await settledInspectionFrame(epoch: token, requireStaticScene: false,
                depthMappingOnly:nonactuatingSparseDepth,allowStationaryIMUPassiveFrame:nonactuatingSparseDepth)
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
                if let current = try inspectionFrame(epoch: token),
                   (nonactuatingSparseDepth ? isDepthMappingEligible(current):isFresh(current)),current.sequence > frame.sequence {
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

/// These candidates belong to one depth scene, not the persisted search recall.
/// A source, body or map replacement cannot inherit an earlier confirmation.
struct ROBWorkspaceCanSceneIdentity: Equatable {
    let sceneID: UUID?
    let cameraGeneration: UUID
    let sessionGeneration: UInt64
    let bodyMotionIdentity: String
    let modelID: String
    let geometryID: String
    let mappingID: String
    let estimatedCameraProjectionIdentity: String?
}

struct ROBWorkspaceCanCandidateSet {
    private struct Track {
        var latest: ROBWorkspaceLocatedObject
        var confirmation = ROBWorkspaceLocationConfirmation()
        var confirmed: ROBWorkspaceLocatedObject?
    }
    private(set) var context: ROBWorkspaceCanSceneIdentity?
    private var tracks: [Track] = []

    static func usable(_ object: ROBWorkspaceLocatedObject, nowMilliseconds: Double) -> Bool {
        object.target == .can && object.position.count == 3 && object.position.allSatisfy(\.isFinite) &&
            object.confidence.isFinite && (0.35...1).contains(object.confidence) && object.sequence > 0 &&
            object.capturedAt.isFinite && nowMilliseconds.isFinite &&
            (0...60_000).contains(nowMilliseconds-object.capturedAt) && object.sections?.valid == true
    }

    mutating func observe(_ objects: [ROBWorkspaceLocatedObject], context: ROBWorkspaceCanSceneIdentity,
                          nowMilliseconds: Double) {
        if self.context != context { tracks = []; self.context = context }
        tracks.removeAll { !Self.usable($0.latest,nowMilliseconds:nowMilliseconds) }
        // Duplicate detector boxes in one exposure cannot confirm each other.
        // A normal can is at least 40 mm wide; 30 mm groups repeated sightings
        // while retaining distinct side-by-side cans.
        var distinct: [ROBWorkspaceLocatedObject] = []
        for object in objects.sorted(by: { $0.confidence > $1.confidence }) where Self.usable(object,nowMilliseconds:nowMilliseconds) {
            if !distinct.contains(where: { simd_distance($0.point,object.point) <= 0.03 }) { distinct.append(object) }
        }
        var matched = Set<Int>()
        for object in distinct {
            let index = tracks.indices.filter { !matched.contains($0) &&
                tracks[$0].latest.registrationID == object.registrationID &&
                simd_distance(tracks[$0].latest.point,object.point) <= 0.05
            }.min { simd_distance(tracks[$0].latest.point,object.point) < simd_distance(tracks[$1].latest.point,object.point) }
            if let index {
                matched.insert(index)
                guard object.sequence > tracks[index].latest.sequence,
                      object.capturedAt > tracks[index].latest.capturedAt else { continue }
                tracks[index].latest = object
                tracks[index].confirmed = tracks[index].confirmation.observe(object)
            } else {
                var track = Track(latest:object)
                _ = track.confirmation.observe(object)
                tracks.append(track); matched.insert(tracks.count-1)
            }
        }
    }

    func confirmed(nowMilliseconds: Double) -> [ROBWorkspaceLocatedObject] {
        tracks.compactMap(\.confirmed).filter { Self.usable($0,nowMilliseconds:nowMilliseconds) }
    }
}

/// A declared geometry prior for the explicitly authorized local trial only.
/// Table depth anchors the base; height, diameter and upright axis are assumed.
/// This constructor grants neither measured registration nor collision clearance.
enum ROBWorkspaceLocalCanShapePrior {
    static func estimate(detection:ROBWorkspaceDetection,allCanDetections:[ROBWorkspaceDetection],
        width:Int,height:Int,fx:Double,fy:Double,cx:Double,cy:Double,
        depth:(Int,Int)->UInt16?,cameraToRobot:simd_double4x4)
        -> (sections:ROBWorkspaceCanSections?,diagnostics:[String:Any]) {
        var report:[String:Any]=["schema_version":1,"kind":"local_trial_known_empty_coke_cylinder",
            "status":"rejected","box":detection.box,"assumed_height_m":0.120,"assumed_diameter_m":0.066,
            "assumed_axis_robot":[0.0,0,1],"registration_verified":false,"measured_can_wall_depth":false,
            "local_plane_is_global_floor_calibration":false,"ring_width_pixels":14]
        func reject(_ stage:String)->(sections:ROBWorkspaceCanSections?,diagnostics:[String:Any]) {
            report["rejection_stage"]=stage;return (nil,report)
        }
        guard detection.usable,width>1,height>1,[fx,fy,cx,cy].allSatisfy(\.isFinite),fx>0,fy>0,
              detection.box.allSatisfy({(0.02...0.98).contains($0)}),
              (0..<4).allSatisfy({column in (0..<4).allSatisfy({cameraToRobot[column][$0].isFinite})}) else {
            return reject("invalid_source_or_clipped_detection")
        }
        let x0=detection.box[0]*Double(width-1),y0=detection.box[1]*Double(height-1)
        let x1=detection.box[2]*Double(width-1),y1=detection.box[3]*Double(height-1)
        let boxWidth=x1-x0,boxHeight=y1-y0
        guard boxWidth>=15,boxHeight>=25 else{return reject("insufficient_rgb_silhouette_pixels")}
        let left=max(0,Int(floor(x0))-14),right=min(width-1,Int(ceil(x1))+14)
        let top=max(0,Int(floor(y0))-14),bottom=min(height-1,Int(ceil(y1))+14)
        let step=max(2,Int(ceil(sqrt(Double((right-left+1)*(bottom-top+1))/2000))))
        func point(_ x:Double,_ y:Double,_ z:Double)->SIMD3<Double> {
            let p=cameraToRobot*SIMD4((x-cx)*z/fx,(y-cy)*z/fy,z,1);return SIMD3(p.x,p.y,p.z)
        }
        var points:[SIMD3<Double>]=[],sampled=0,missing=0
        for y in stride(from:top,through:bottom,by:step) {for x in stride(from:left,through:right,by:step) {
            let insideOwn=Double(x)>=x0 && Double(x)<=x1 && Double(y)>=y0 && Double(y)<=y1
            let insideAnother=allCanDetections.contains { other in
                other.visuallyUsable && other.box.count==4 && other.box != detection.box &&
                (other.box[0]*Double(width-1)...other.box[2]*Double(width-1)).contains(Double(x)) &&
                (other.box[1]*Double(height-1)...other.box[3]*Double(height-1)).contains(Double(y))
            }
            if insideOwn || insideAnother {continue};sampled+=1
            guard let mm=depth(x,y),(150...3000).contains(mm) else {missing+=1;continue}
            let p=point(Double(x),Double(y),Double(mm)/1000)
            guard [p.x,p.y,p.z].allSatisfy(\.isFinite) else{return reject("nonfinite_table_points")}
            points.append(p)
        }}
        report["ring_sample_count"]=sampled;report["ring_valid_point_count"]=points.count;report["ring_missing_count"]=missing
        report["ring_stride_pixels"]=step
        guard points.count>=80 else{return reject("insufficient_local_table_support")}
        var best:[Int]=[]
        for i in 0..<128 {
            let a=points[(i*17)%points.count],b=points[(i*37+points.count/3)%points.count],c=points[(i*61+points.count*2/3)%points.count]
            let cross=simd_cross(b-a,c-a),length=simd_length(cross)
            if length<0.00001 {continue}
            var normal=cross/length;if normal.z<0 {normal = -normal}
            if normal.z<0.85 {continue}
            let offset = -simd_dot(normal,a)
            let inliers=points.indices.filter{abs(simd_dot(normal,points[$0])+offset)<=0.010}
            if inliers.count>best.count {best=inliers}
        }
        let support=Double(best.count)/Double(points.count)
        report["plane_inlier_count"]=best.count;report["plane_support_fraction"]=support
        guard best.count>=80,support>=0.65 else{return reject("no_dominant_local_table_plane")}
        let inliers=best.map{points[$0]},mean=inliers.reduce(SIMD3<Double>.zero,+)/Double(inliers.count)
        var xx=0.0,xy=0.0,yy=0.0,xz=0.0,yz=0.0
        for p in inliers {let d=p-mean;xx+=d.x*d.x;xy+=d.x*d.y;yy+=d.y*d.y;xz+=d.x*d.z;yz+=d.y*d.z}
        let determinant=xx*yy-xy*xy
        guard determinant>0.0000000001 else{return reject("degenerate_local_table_plane")}
        let a=(xz*yy-yz*xy)/determinant,b=(yz*xx-xz*xy)/determinant,c=mean.z-a*mean.x-b*mean.y
        let scale=sqrt(a*a+b*b+1),normal=SIMD3(-a/scale,-b/scale,1/scale),offset = -c/scale
        let errors=inliers.map{abs(simd_dot(normal,$0)+offset)}.sorted()
        let rms=sqrt(errors.reduce(0){$0+$1*$1}/Double(errors.count))
        report["plane_normal_robot"]=[normal.x,normal.y,normal.z];report["plane_offset_m"]=offset
        report["plane_rmse_m"]=rms;report["plane_p95_m"]=errors[errors.count*95/100]
        guard normal.z>=0.85,rms<=0.008,errors[errors.count*95/100]<=0.010 else{return reject("local_table_plane_residual")}
        let camera=SIMD3(cameraToRobot.columns.3.x,cameraToRobot.columns.3.y,cameraToRobot.columns.3.z)
        let u=(x0+x1)/2,v=y1,rotated=cameraToRobot*SIMD4((u-cx)/fx,(v-cy)/fy,1,0)
        let ray=SIMD3(rotated.x,rotated.y,rotated.z),denominator=simd_dot(normal,ray)
        guard abs(denominator)>0.05 else{return reject("base_ray_parallel_to_table")}
        let distance = -(simd_dot(normal,camera)+offset)/denominator
        guard (0.15...3).contains(distance) else{return reject("base_ray_outside_local_range")}
        let surface=camera+ray*distance
        let away=SIMD2(surface.x-camera.x,surface.y-camera.y)
        guard simd_length(away)>0.1 else{return reject("ambiguous_front_surface_to_axis")}
        let shift=simd_normalize(away)*0.033
        var base=surface+SIMD3(shift.x,shift.y,0)
        base.z = -(normal.x*base.x+normal.y*base.y+offset)/normal.z
        guard [base.x,base.y,base.z].allSatisfy(\.isFinite),(0.30...1.40).contains(base.z) else{return reject("base_outside_tabletop_height_range")}
        let inverse=simd_inverse(cameraToRobot)
        var projected:[SIMD2<Double>]=[]
        for z in [0.0,0.120] {for i in 0..<32 {
            let theta=Double(i)*2*Double.pi/32,p=inverse*SIMD4(base.x+0.033*cos(theta),base.y+0.033*sin(theta),base.z+z,1)
            guard p.z>0.1 else{return reject("cylinder_silhouette_behind_camera")}
            projected.append(SIMD2(fx*p.x/p.z+cx,fy*p.y/p.z+cy))
        }}
        let low=projected.reduce(projected[0]){simd_min($0,$1)},high=projected.reduce(projected[0]){simd_max($0,$1)}
        let intersection=max(0,min(high.x,x1)-max(low.x,x0))*max(0,min(high.y,y1)-max(low.y,y0))
        let union=(high.x-low.x)*(high.y-low.y)+boxWidth*boxHeight-intersection
        let iou=union>0 ? intersection/union : 0
        let edgeError=max(max(abs(low.x-x0),abs(low.y-y0)),max(abs(high.x-x1),abs(high.y-y1)))
        let edgeLimit=max(12,0.25*max(boxWidth,boxHeight))
        report["base_ray_pixel"]=[u,v];report["base_front_surface_robot"]=[surface.x,surface.y,surface.z]
        report["assumed_front_surface_to_axis_horizontal_m"]=[shift.x,shift.y,0]
        report["estimated_axis_base_robot"]=[base.x,base.y,base.z]
        report["predicted_silhouette_pixels"]=[low.x,low.y,high.x,high.y]
        report["silhouette_iou"]=iou;report["silhouette_maximum_edge_error_pixels"]=edgeError
        report["silhouette_edge_error_limit_pixels"]=edgeLimit
        guard iou>=0.50,edgeError<=edgeLimit else{return reject("known_cylinder_rgb_silhouette_disagreement")}
        guard let sections=ROBWorkspaceCanSections.localKnownEmptyCokeCylinder(base:base,axis:SIMD3(0,0,1),
            planeRMSEMeters:rms,planePointCount:best.count,planeSupportFraction:support,
            silhouetteIoU:iou,silhouetteMaximumEdgeErrorPixels:edgeError) else{return reject("invalid_known_cylinder_evidence")}
        report["status"]="accepted_estimated_prior";report["rejection_stage"]=NSNull()
        report["estimated_middle_robot"]=sections.middle;report["estimated_top_robot"]=sections.top
        return (sections,report)
    }
}

/// Attention only: current detector boxes can request at most two fresh
/// views. A rejected plane/shape never becomes an accepted can by recentering.
enum ROBWorkspaceCanRecenterPlan {
    /// One current RGB exposure may request attention, never object geometry.
    /// Recenter a clipped silhouette before another full workspace raster.
    static func clippedAttentionViews(sightings:[ROBWorkspaceRecall.Sighting],
        nowMilliseconds:Double,boundedPan:(Double)->Double)->[ROBWorkspaceView] {
        guard nowMilliseconds.isFinite else{return []}
        var result:[ROBWorkspaceView]=[]
        for item in sightings.sorted(by:{$0.confidence>$1.confidence}) where item.target == .can && item.valid &&
            item.confidence>=0.60 && (0...30_000).contains(nowMilliseconds-item.capturedAt) &&
            item.box.contains(where:{$0<0.02 || $0>0.98}) {
            let centered=item.centeredView,pan=boundedPan(centered.panDegrees)
            guard pan.isFinite else{continue}
            let view=ROBWorkspaceView(panDegrees:pan,upperTarget:centered.upperTarget)
            guard abs(view.panDegrees-item.view.panDegrees)>3 || abs(view.upperTarget-item.view.upperTarget)>100 else{continue}
            if !result.contains(where:{abs($0.panDegrees-view.panDegrees)<3 && abs($0.upperTarget-view.upperTarget)<100}) {
                result.append(view)
            }
            if result.count==2 {break}
        }
        return result
    }

    static func views(sightings:[ROBWorkspaceRecall.Sighting],physicalSide:String,
        nowMilliseconds:Double,boundedPan:(Double)->Double)->[ROBWorkspaceView] {
        guard ["left","right"].contains(physicalSide),nowMilliseconds.isFinite else{return []}
        let sign=physicalSide=="right" ? -1.0:1.0
        let current=sightings.filter { $0.target == .can && $0.valid &&
            (0...30_000).contains(nowMilliseconds-$0.capturedAt) &&
            sign*$0.centeredView.panDegrees >= -3 }
        // Lower image centers usually indicate the nearer table row. Prefer
        // that row, then detector confidence; model reach remains independent.
        let ranked=current.sorted {
            let a=($0.box[1]+$0.box[3])/2,b=($1.box[1]+$1.box[3])/2
            return abs(a-b)>0.02 ? a>b:$0.confidence>$1.confidence
        }
        var result:[ROBWorkspaceView]=[]
        for item in ranked {
            let centered=item.centeredView,pan=boundedPan(centered.panDegrees)
            guard pan.isFinite else{continue}
            let view=ROBWorkspaceView(panDegrees:pan,upperTarget:centered.upperTarget)
            if !result.contains(where:{abs($0.panDegrees-view.panDegrees)<3 && abs($0.upperTarget-view.upperTarget)<100}) {
                result.append(view)
            }
            if result.count==2 {break}
        }
        return result
    }
}

struct ROBWorkspaceCanSelection {
    let object: ROBWorkspaceLocatedObject?
    let preview: ROBCanGrabPreview?
    let diagnostics: [[String:Any]]
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
    /// Prediction only; actual capture still verifies the exact accepted raw hold.
    var panTargetForView: ((Double) -> NSNumber?)?
    var finishView: (() -> Void)?
    var announce: ((String) -> Void)?
    private(set) var lastReport: NSDictionary = [:]
    @nonobjc private(set) var locatedObjects: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]
    @nonobjc private var canCandidates = ROBWorkspaceCanCandidateSet()
    @MainActor @nonobjc var locatedCanCandidates: [ROBWorkspaceLocatedObject] {
        guard let context=canCandidates.context,let map=collisionSnapshot,
              context.sceneID==map.sceneID,context.cameraGeneration==ROBArmRoutineVision.shared.cameraGeneration,
              context.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity,
              context.sessionGeneration==map.sessionGeneration else { return [] }
        return canCandidates.confirmed(nowMilliseconds:Date().timeIntervalSince1970*1000)
    }
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
            guard ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:frame.cameraGeneration,
                runtimeCalibrationIdentity:frame.intrinsics?.runtimeCalibration?.identity,
                cameraServiceSourceSHA256:frame.intrinsics?.cameraServiceSourceSHA256) else {throw ROBWorkspaceDepthMapError.invalidFrame}
            guard let legacy=view.cameraFrame(model:model) else{throw ROBWorkspaceDepthMapError.invalidFrame}
            return (legacy,nil,nil)
        }
        let controller=ROBFixedHeadCalibrationWindowController.shared
        guard frame.intrinsics?.rgbOutputUndistorted==true else {
            throw ROBWorkspaceDepthMapError.acquisition("The estimated photo-origin projection requires the actual undistorted RGB source contract.")
        }
        let scope=try controller.scope(model:model,frame:frame)
        try scope.validate()
        guard ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,actualFrame:.init(cameraGeneration:frame.cameraGeneration,
                actualDeviceMXID:frame.intrinsics?.runtimeCalibration?.actualDeviceMXID,
                runtimeCalibrationIdentity:frame.intrinsics?.runtimeCalibration?.identity,
                cameraServiceSourceSHA256:frame.intrinsics?.cameraServiceSourceSHA256,scope:scope,
                inertialJSON:(frame.intrinsics?.inertial).flatMap{try?JSONEncoder().encode($0)})) else {
            throw ROBWorkspaceDepthMapError.acquisition("The requested estimated camera refinement does not cover this actual RGB-D source.")
        }
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
        canCandidates = ROBWorkspaceCanCandidateSet()
        lastReport = ["status":"depth_alignment_changed", "detail":"Head depth alignment changed; capture a fresh scene."]
    }

    /// Pure construction only. Both callers must check their active local-trial
    /// receipt and exact current source before/after using this estimated shape.
    @MainActor @nonobjc func localCanShapePrior(detection:ROBWorkspaceDetection,allCanDetections:[ROBWorkspaceDetection],
        frame:ROBArmRoutineVision.Frame,view:ROBWorkspaceView,model:ROBGhostRobotModel,cameraToRobot:simd_double4x4)
        -> (sections:ROBWorkspaceCanSections?,diagnostics:[String:Any]) {
        guard let depth=frame.depth,let k=frame.intrinsics,k.isValid(forWidth:depth.width,height:depth.height),
              k.rgbOutputUndistorted==true else {
            return (nil,["status":"rejected","rejection_stage":"missing_native_prior_source_geometry"])
        }
        return ROBWorkspaceLocalCanShapePrior.estimate(detection:detection,allCanDetections:allCanDetections,
            width:depth.width,height:depth.height,fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,
            depth:{depth.distanceMillimeters(x:$0,y:$1)},cameraToRobot:cameraToRobot)
    }

    /// Reach ranking only. The caller still plans/admit every connector against
    /// current obstacles and verifies possession; a preview never permits motion.
    @MainActor @nonobjc func nearestReachableCan(model: ROBGhostRobotModel, baseline: [String:Double],
        map: ROBWorkspaceCollisionSnapshot, calibrationFile: URL? = nil,
        nowMilliseconds: Double = Date().timeIntervalSince1970*1000) async -> ROBWorkspaceCanSelection {
        let expected = ROBWorkspaceCanSceneIdentity(sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
            sessionGeneration:map.sessionGeneration,bodyMotionIdentity:map.bodyMotionIdentity,
            modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            estimatedCameraProjectionIdentity:map.estimatedCameraProjectionIdentity)
        func contextIsCurrent() -> Bool {
            canCandidates.context == expected && collisionSnapshot?.sceneID == map.sceneID &&
                map.modelID == model.modelID && map.geometryID == model.geometryID && map.mappingID == model.selectedMappingID &&
                map.cameraGeneration == ROBArmRoutineVision.shared.cameraGeneration &&
                map.bodyMotionIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity &&
                (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == map.sessionGeneration &&
                estimatedCameraProjectionIsCurrent(model:model,map:map)
        }
        return await selectReachableCan(candidates:canCandidates.confirmed(nowMilliseconds:nowMilliseconds),
            model:model,baseline:baseline,map:map,calibrationFile:calibrationFile,nowMilliseconds:nowMilliseconds,
            contextIsCurrent:contextIsCurrent)
    }

    /// Shared reach ranking for the completed scene and its bounded targeted
    /// reobservations. This never creates a collision or motion permission.
    @MainActor private func selectReachableCan(candidates observed:[ROBWorkspaceLocatedObject],
        model:ROBGhostRobotModel,baseline:[String:Double],map:ROBWorkspaceCollisionSnapshot,
        calibrationFile:URL?=nil,nowMilliseconds:Double,contextIsCurrent:()->Bool) async ->ROBWorkspaceCanSelection {
        guard ["left","right"].contains(model.physicalSide),contextIsCurrent(),
              let shoulder=model.frames(baseline)[model.physicalSide+"_two_Link"] else {
            return .init(object:nil,preview:nil,diagnostics:[["status":"scene_context_changed","path_admitted":false]])
        }
        let origin=SIMD3(shoulder.columns.3.x,shoulder.columns.3.y,shoulder.columns.3.z)
        let candidates=observed.filter { object in
            map.observations.contains {
                $0.sequence==object.sequence && $0.capturedAtMilliseconds==object.capturedAt &&
                    $0.registrationID==object.registrationID
            }
        }.sorted {
            let a=simd_distance($0.point,origin),b=simd_distance($1.point,origin)
            return abs(a-b)>0.000001 ? a<b : $0.confidence>$1.confidence
        }
        guard !candidates.isEmpty else {
            return .init(object:nil,preview:nil,diagnostics:[["status":observed.isEmpty
                ? "no_fresh_confirmed_can_with_valid_sections":"no_matching_enrolled_can_source",
                "confirmed_candidate_count":observed.count,"path_admitted":false]])
        }
        var diagnostics: [[String:Any]] = []
        for can in candidates {
            guard !Task.isCancelled,contextIsCurrent() else {
                diagnostics.append(["status":"scene_context_changed","path_admitted":false]); break
            }
            do {
                let projectionIdentity=map.estimatedCameraProjectionIdentity
                let preview = try await Task.detached(priority:.userInitiated) {
                    try ROBCanGrabPreview.make(can:can,model:model,baseline:baseline,side:model.physicalSide,
                        now:nowMilliseconds,reachOffset:ROBLeftCanReachCalibration.load(model:model,can:can,file:calibrationFile,
                            estimatedCameraProjectionIdentity:projectionIdentity))
                }.value
                guard !Task.isCancelled,contextIsCurrent(),
                      ROBWorkspaceCanCandidateSet.usable(can,nowMilliseconds:Date().timeIntervalSince1970*1000) else {
                    diagnostics.append(["status":"scene_context_changed_or_candidate_expired","path_admitted":false]); break
                }
                let reachable=preview.reachesCan && preview.helpRequest == nil
                diagnostics.append(["status":reachable ? "selected_reachable" : "skipped_unreachable",
                    "position":can.position,"captured_at_ms":can.capturedAt,"sequence":NSNumber(value:can.sequence),
                    "physical_arm":model.physicalSide,"shoulder_distance_m":simd_distance(can.point,origin),
                    "grasp_error_m":preview.graspError,"gripper_tilt_degrees":preview.gripperTiltDegrees,"path_admitted":false])
                if reachable { return .init(object:can,preview:preview,diagnostics:diagnostics) }
            } catch {
                diagnostics.append(["status":"skipped_preview_unavailable","position":can.position,
                    "detail":error.localizedDescription,"path_admitted":false])
            }
        }
        return .init(object:nil,preview:nil,diagnostics:diagnostics)
    }

    @nonobjc private static let blockerDepthQueue = DispatchQueue(label: "com.orbitusrobotics.workspace-blocker-depth", qos: .userInitiated)

    /// These value-only workers deliberately use checked continuations rather
    /// than a nested Task.detached.value inside the large capture coroutine.
    /// They can add pixels to a map, never send an actuator command or grant.
    @nonobjc private static func appendBlockerDepth(map:ROBWorkspaceDepthMap,pixels:CameraDepthFrame,
        intrinsics:CameraIntrinsics,matrix:simd_double4x4,capturedAtMilliseconds:Double,sequence:UInt64,
        cameraGeneration:UUID,view:ROBWorkspaceView,projection:String) async throws ->ROBWorkspaceDepthMap {
        let width=pixels.width,height=pixels.height,fx=intrinsics.fx,fy=intrinsics.fy,cx=intrinsics.cx,cy=intrinsics.cy
        let pan=view.panDegrees,upper=view.upperTarget
        return try await withCheckedThrowingContinuation { continuation in
            blockerDepthQueue.async {
                do {
                    var next=map
                    try next.append(width:width,height:height,fx:fx,fy:fy,cx:cx,cy:cy,
                        depth:{pixels.distanceMillimeters(x:$0,y:$1)},cameraToRobot:matrix,
                        capturedAtMilliseconds:capturedAtMilliseconds,sequence:sequence,cameraGeneration:cameraGeneration,
                        measuredSelfBounds:[],cameraRegistrationVerified:false,recordedPanDegrees:pan,
                        recordedUpperTarget:upper,recordedLowerTarget:6011,
                        estimatedCameraProjectionIdentity:projection)
                    continuation.resume(returning:next)
                } catch {continuation.resume(throwing:error)}
            }
        }
    }

    @nonobjc private static func freezeBlockerDepth(map:ROBWorkspaceDepthMap) async ->ROBWorkspaceCollisionSnapshot? {
        await withCheckedContinuation { continuation in
            blockerDepthQueue.async {continuation.resume(returning:map.snapshot())}
        }
    }

    /// Nonactuating mitigation for a specific unknown cell. A new view adds
    /// actual rays to the SAME scene; it never masks robot geometry, erases an
    /// old return or promotes a projected cell into observed free space.
    // Keep the orchestration unoptimized while isolating the observed Swift
    // task-stack failure. Map math runs in the separate optimized workers.
    @_optimize(none)
    @MainActor @nonobjc func captureBlockerCoverage(blocker:ROBWorkspaceUnknownCellBlocker,
        continuing snapshot:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,generation:UInt64,
        attempted:[ROBWorkspaceView],deadlineUptime:Double,recordStage:(String)->Void,check:() throws ->Void,progress:(String)->Void)
        async throws ->(snapshot:ROBWorkspaceCollisionSnapshot,view:ROBWorkspaceView)? {
        let vision=ROBArmRoutineVision.shared,controller=ROBFixedHeadCalibrationWindowController.shared
        try check();try Task.checkCancellation()
        guard snapshot.registrationID==nil,let projection=snapshot.estimatedCameraProjectionIdentity,
              snapshot.visualCalibrationScope != nil,snapshot.state(at:blocker.center) == .unknown else {return nil}
        let deadline=min(deadlineUptime,ProcessInfo.processInfo.systemUptime+12)
        guard deadline.isFinite,ProcessInfo.processInfo.systemUptime<deadline,
              attempted.count<2 else {return nil}
        var anchor=ROBWorkspaceCaptureAnchor()
        guard anchor.accept(frameGeneration:snapshot.cameraGeneration,currentGeneration:vision.cameraGeneration) else {
            throw ROBWorkspaceDepthMapError.invalidFrame
        }
        func requireContext()throws {
            try check();try Task.checkCancellation()
            try requireEstimatedProjectionIdentity(projection,model:model)
            guard anchor.permitsCurrent(vision.cameraGeneration),
                  snapshot.cameraGeneration==vision.cameraGeneration,
                  snapshot.modelID==model.modelID,snapshot.geometryID==model.geometryID,
                  snapshot.mappingID==model.selectedMappingID,snapshot.sessionGeneration==generation,
                  snapshot.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity,
                  (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"]as?NSNumber)?.uint64Value==generation,
                  collisionSnapshotValue?.fingerprint==snapshot.fingerprint,
                  (0...60_000).contains(Date().timeIntervalSince1970*1000-snapshot.oldestCapturedAtMilliseconds) else {
                throw ROBWorkspaceDepthMapError.invalidFrame
            }
            let neck=controller.readNeck?() ?? [:]
            guard neck["known"]as?Bool==true,neck["lower"]as?Int==6011 else {
                throw ROBWorkspaceDepthMapError.acquisition("Targeted coverage requires the unchanged upright lower-neck hold and stationary ROB.")
            }
        }
        try requireContext()
        let initialNeck=controller.readNeck?() ?? [:]
        guard initialNeck["stationary"]as?Bool==true,
              let initialReady=initialNeck["ready_at"]as?Double,initialReady.isFinite,initialReady<=ProcessInfo.processInfo.systemUptime,
              let source=vision.snapshot()["face"],source.cameraGeneration==snapshot.cameraGeneration,
              (0...700).contains(Date().timeIntervalSince1970*1000-source.capturedAt),
              let depth=source.depth,let k=source.intrinsics,k.isValid(forWidth:depth.width,height:depth.height),
              k.rgbOutputUndistorted==true,k.depthRGBGeometryCorrespondence?.status=="matched" else {
            throw ROBWorkspaceDepthMapError.acquisition("Targeted coverage requires the current normalized synchronized face RGB-D source.")
        }
        guard registeredCameraContext(frame:source,model:model)==nil else {return nil}
        let sourceScope=try controller.scope(model:model,frame:source)
        guard sourceScope.gatewaySessionGeneration==generation,sourceScope.cameraGeneration==snapshot.cameraGeneration,
              sourceScope.lowerTarget==6011 else {throw ROBWorkspaceDepthMapError.invalidFrame}
        let width=depth.width,height=depth.height,sourceK=[k.fx,k.fy,k.cx,k.cy],sourceService=k.cameraServiceSourceSHA256
        func blockerDepthDiagnostic(pixels:CameraDepthFrame,intrinsics:CameraIntrinsics,matrix:simd_double4x4)->[String:Any] {
            let half=SIMD3<Double>(repeating:blocker.voxelSizeMeters/2),low=blocker.center-half,high=blocker.center+half
            let inverse=simd_inverse(matrix)
            var projected:[SIMD2<Double>]=[],opticalDepths:[Double]=[]
            for x in [low.x,high.x] {for y in [low.y,high.y] {for z in [low.z,high.z] {
                let q=inverse*SIMD4(x,y,z,1)
                guard q.x.isFinite,q.y.isFinite,q.z.isFinite,q.z>0 else {
                    return ["status":"cell_not_projectable","diagnostic_only":true,"semantic_self_classification":false,"free_space_proof":false]
                }
                projected.append(SIMD2(intrinsics.fx*q.x/q.z+intrinsics.cx,intrinsics.fy*q.y/q.z+intrinsics.cy))
                opticalDepths.append(q.z*1000)
            }}}
            guard projected.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<1e6 && abs($0.y)<1e6}) else {
                return ["status":"cell_projection_invalid","diagnostic_only":true,"free_space_proof":false]
            }
            let x0=max(0,Int(floor(projected.map(\.x).min()!))),x1=min(width-1,Int(ceil(projected.map(\.x).max()!)))
            let y0=max(0,Int(floor(projected.map(\.y).min()!))),y1=min(height-1,Int(ceil(projected.map(\.y).max()!)))
            guard x0<=x1,y0<=y1 else {return ["status":"cell_outside_image","diagnostic_only":true,"free_space_proof":false]}
            let roiWidth=x1-x0+1,roiHeight=y1-y0+1,area=roiWidth*roiHeight
            var step=max(1,Int(ceil(sqrt(Double(area)/4096))))
            while ((roiWidth+step-1)/step)*((roiHeight+step-1)/step)>4096 {step+=1}
            var sampled=0,missing=0,outOfRange=0,eligible=0,values:[Int]=[]
            for y in stride(from:y0,through:y1,by:step) {for x in stride(from:x0,through:x1,by:step) {
                sampled+=1
                guard let raw=pixels.distanceMillimeters(x:x,y:y),raw>0 else {missing+=1;continue}
                guard (100...3000).contains(raw) else {outOfRange+=1;continue}
                values.append(Int(raw))
                guard x>0,y>0,x<width-1,y<height-1 else {continue}
                let neighbors=[(x-1,y),(x+1,y),(x,y-1),(x,y+1)]
                if neighbors.allSatisfy({point in
                    guard let mm=pixels.distanceMillimeters(x:point.0,y:point.1),(100...3000).contains(mm) else {return false}
                    return abs(Int(mm)-Int(raw))<=30
                }) {eligible+=1}
            }}
            values.sort()
            var output:[String:Any]=["status":values.isEmpty ? "no_valid_depth_in_roi":"raw_depth_present",
                "roi_kind":"projected_cell_bounding_rectangle","pixel_bounds":[x0,y0,x1,y1],
                "roi_pixel_area":area,"sample_stride":step,"sampled_pixels":sampled,
                "missing_or_zero_depth_pixels":missing,"out_of_100_3000mm_pixels":outOfRange,
                "valid_depth_pixels":values.count,"locally_consistent_depth_pixels":eligible,
                "predicted_cell_optical_depth_mm":[opticalDepths.min()!,opticalDepths.max()!],
                "diagnostic_only":true,"semantic_self_classification":false,"free_space_proof":false]
            if !values.isEmpty {output["raw_optical_depth_mm_min_median_max"]=[values.first!,values[values.count/2],values.last!]}
            return output
        }
        var candidates:[ROBWorkspaceBlockerCoverageCandidate]=[]
        for upper in [5300,5450,5650,5900] {
            for requested in stride(from:-60.0,through:60.0,by:10) {
                guard let bounded=boundedPan?(requested),bounded.isFinite,abs(bounded)<=60 else {continue}
                let view=ROBWorkspaceView(panDegrees:bounded,upperTarget:upper)
                guard !candidates.contains(where:{$0.view==view}),canUseView?(bounded,upper)==true,
                      let raw=panTargetForView?(bounded)?.intValue,(3000...10000).contains(raw),
                      let matrix=ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:raw,
                        lowerTarget:6011,upperTarget:upper) else {continue}
                candidates.append(.init(view:view,cameraToRobotColumnMajor:(0..<4).flatMap { column in (0..<4).map {matrix[column][$0]} }))
            }
        }
        let selected=ROBWorkspaceBlockerCoveragePlan.nextView(blocker:blocker,candidates:candidates,
            observations:snapshot.observations,attempted:attempted,width:width,height:height,
            fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy)
        var diagnostic:[String:Any]=["blocker_link":blocker.link,
            "blocker_voxel":[blocker.voxel.x,blocker.voxel.y,blocker.voxel.z],"candidate_count":candidates.count,
            "scene_id":snapshot.sceneID.uuidString,"before_map_fingerprint":snapshot.fingerprint,
            "before_state_raw":snapshot.state(at:blocker.center).rawValue,"maximum_views":2,
            "source_rasters_retained":false,"detector_invoked":false,"arm_command_sent":false,
            "free_space_inferred":false,"occupied_returns_preserved":true,"unknown_space_gate_unchanged":true]
        func record(_ status:String,_ detail:String) {
            diagnostic["status"]=status;diagnostic["detail"]=detail
            var report=lastReport as? [String:Any] ?? [:]
            var attempts=report["blocker_coverage_attempts"]as?[[String:Any]] ?? []
            attempts.append(diagnostic);report["blocker_coverage_attempts"]=Array(attempts.suffix(2))
            lastReport=report as NSDictionary
        }
        guard let view=selected,let rawPan=panTargetForView?(view.panDegrees)?.intValue else {
            record("no_new_view","No unused bounded camera view projects the entire blocked cell inside the calibrated image.")
            return nil
        }
        recordStage("candidate_selected")
        diagnostic["pan"]=view.panDegrees;diagnostic["upper"]=view.upperTarget
        diagnostic["predicted_raw_pan"]=rawPan
        progress("Checking the blocked \(blocker.link) region from a new camera view.")
        do {
            recordStage("settle_started")
            var settledSince:Double?
            while true {
                try requireContext()
                guard ProcessInfo.processInfo.systemUptime<deadline else {
                    record("view_unavailable","The new view did not settle within the shared coverage deadline.");return nil
                }
                guard panTargetForView?(view.panDegrees)?.intValue==rawPan,
                      canUseView?(view.panDegrees,view.upperTarget)==true else {throw ROBWorkspaceDepthMapError.invalidFrame}
                if prepareView?(view.panDegrees,view.upperTarget)==true,viewReady?(view.panDegrees,view.upperTarget)==true {
                    settledSince=settledSince ?? ProcessInfo.processInfo.systemUptime
                    if ProcessInfo.processInfo.systemUptime-settledSince!>=1.5 {break}
                } else {settledSince=nil}
                try await Task.sleep(nanoseconds:100_000_000)
            }
            recordStage("settled")
            recordStage("seed_started")
            var map=try ROBWorkspaceDepthMap(continuing:snapshot,modelID:model.modelID,geometryID:model.geometryID,
                mappingID:model.selectedMappingID,sessionGeneration:generation,cameraGeneration:snapshot.cameraGeneration,
                estimatedCameraProjectionIdentity:projection)
            recordStage("seed_complete")
            var heldScope:ROBFixedHeadRegistrationScope?,previous=snapshot.observations.last?.sequence ?? 0
            var previousCapture=snapshot.lastCapturedAtMilliseconds,frames:[[String:Any]]=[],expired=0
            func requireHeldView()throws {
                try requireContext()
                let neck=controller.readNeck?() ?? [:]
                guard viewReady?(view.panDegrees,view.upperTarget)==true,neck["stationary"]as?Bool==true,
                      neck["pan"]as?Int==rawPan,neck["upper"]as?Int==view.upperTarget,
                      let actualPan=neck["pan_degrees"]as?Double,abs(actualPan-view.panDegrees)<=0.05,
                      let ready=neck["ready_at"]as?Double,ready.isFinite,ready<=ProcessInfo.processInfo.systemUptime,
                      panTargetForView?(view.panDegrees)?.intValue==rawPan else {throw ROBWorkspaceDepthMapError.invalidFrame}
            }
            while frames.count<2 {
                try requireHeldView()
                guard ProcessInfo.processInfo.systemUptime<deadline else {throw ROBWorkspaceDepthMapError.acquisition("Targeted coverage expired before two advancing depth exposures.")}
                recordStage("frame_wait")
                let frame=try await vision.settledDepthFrame(deadlineUptime:deadline)
                recordStage("frame_received")
                try requireHeldView()
                guard ProcessInfo.processInfo.systemUptime<deadline,frame.sequence>previous,frame.capturedAt>previousCapture,
                      frame.cameraGeneration==snapshot.cameraGeneration,let pixels=frame.depth,let intrinsics=frame.intrinsics,
                      pixels.width==width,pixels.height==height,intrinsics.isValid(forWidth:width,height:height),
                      [intrinsics.fx,intrinsics.fy,intrinsics.cx,intrinsics.cy]==sourceK,
                      intrinsics.cameraServiceSourceSHA256==sourceService,intrinsics.rgbOutputUndistorted==true,
                      intrinsics.depthRGBGeometryCorrespondence?.status=="matched",
                      registeredCameraContext(frame:frame,model:model)==nil else {throw ROBWorkspaceDepthMapError.invalidFrame}
                let scope=try controller.scope(model:model,frame:frame)
                guard scope.lowerTarget==6011,scope.panTarget==rawPan,scope.upperTarget==view.upperTarget,
                      scope.gatewaySessionGeneration==generation,scope.cameraGeneration==snapshot.cameraGeneration,
                      heldScope.map({$0==scope}) ?? true else {throw ROBWorkspaceDepthMapError.invalidFrame}
                heldScope=scope;previous=frame.sequence;previousCapture=frame.capturedAt
                let projectionContext=try unregisteredCameraProjection(frame:frame,view:view,model:model)
                guard projectionContext.identity==projection,projectionContext.lowerTarget==6011 else {throw ROBWorkspaceDepthMapError.invalidFrame}
                let input=map
                do {
                    recordStage("append_started")
                    map=try await Self.appendBlockerDepth(map:input,pixels:pixels,intrinsics:intrinsics,
                        matrix:projectionContext.matrix,capturedAtMilliseconds:frame.capturedAt,sequence:frame.sequence,
                        cameraGeneration:frame.cameraGeneration,view:view,projection:projection)
                    recordStage("append_complete")
                } catch {
                    try requireHeldView()
                    guard let typed=error as?ROBWorkspaceDepthMapError,case .expiredAtProjection=typed,expired<2,
                          ProcessInfo.processInfo.systemUptime<deadline else {throw error}
                    expired+=1;continue
                }
                try requireHeldView()
                recordStage("roi_started")
                let roi=blockerDepthDiagnostic(pixels:pixels,intrinsics:intrinsics,matrix:projectionContext.matrix)
                recordStage("roi_complete")
                frames.append(["sequence":NSNumber(value:frame.sequence),"captured_at_ms":frame.capturedAt,
                    "pan":view.panDegrees,"raw_pan":scope.panTarget,"lower":scope.lowerTarget,"upper":scope.upperTarget,
                    "blocker_depth_roi":roi])
                diagnostic["frames"]=frames
            }
            let input=map
            recordStage("freeze_started")
            let frozen=await Self.freezeBlockerDepth(map:input)
            recordStage("freeze_complete")
            guard let result=frozen else {
                throw ROBWorkspaceDepthMapError.invalidFrame
            }
            try requireHeldView()
            guard ProcessInfo.processInfo.systemUptime<deadline,result.sceneID==snapshot.sceneID,
                  result.observedFrameCount==snapshot.observedFrameCount+2,!result.isTruncated,
                  result.bodyMotionIdentity==snapshot.bodyMotionIdentity,result.registrationID==nil,
                  result.occupiedVoxelCount>=snapshot.occupiedVoxelCount else {throw ROBWorkspaceDepthMapError.invalidFrame}
            diagnostic["after_map_fingerprint"]=result.fingerprint
            diagnostic["after_state_raw"]=result.state(at:blocker.center).rawValue
            diagnostic["observed_frames"]=result.observedFrameCount
            recordStage("publish")
            collisionSnapshotValue=result;collisionSnapshotModel=model
            record("captured","Two original fresh RGB-D exposures appended; only the ordinary full path review may admit motion.")
            return (result,view)
        } catch {
            record("capture_failed",error.localizedDescription)
            throw error
        }
    }

    /// Passive acquisition for a reviewed commissioning test. There are no
    /// prepareView callbacks here: the head and both arms must stay unchanged.
    /// The caller owns and checks the live stationary arm observation.
    @MainActor @nonobjc func captureRegisteredCurrentScene(model: ROBGhostRobotModel, generation: UInt64,
        check: () throws -> Void, progress: (String) -> Void) async throws -> ROBWorkspaceCollisionSnapshot {
        collisionSnapshotValue = nil
        collisionSnapshotModel = model
        let vision = ROBArmRoutineVision.shared
        let rawCapture=RawScanCapture(model:model,generation:generation)
        defer {rawCapture.closeIfIncomplete()}
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
            await rawCapture.append(frame,sceneID:inputMap.sceneID,scope:measured.scope,transform:measured.registration.cameraToRobot,
                selfBounds:selfBounds,registration:measured.registration,projectionIdentity:nil)
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
        await rawCapture.finish(snapshot)
        lastReport = ["status":"passive_fixed_head_scene_captured","registration_verified":true,
            "scene_id":snapshot.sceneID.uuidString,"depth_frames":snapshot.observedFrameCount,
            "detail":"Measured current head view; no neck or arm command was sent."]
        var archiveReport=lastReport as? [String:Any] ?? [:];archiveReport["raw_archive"]=rawCapture.report
        lastReport=archiveReport as NSDictionary
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

    /// Keep the existing settle interval and deadline for both initial neck
    /// staging and captured views. Readiness remains the native raw-pose gate.
    @MainActor @nonobjc private func settleCollisionScanView(_ view:ROBWorkspaceView,check:()throws->Void,
        status:(ROBWorkspaceView,Bool,Bool)->Void) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+8
        var settledSince:TimeInterval?
        while true {
            try check();try Task.checkCancellation()
            let prepared=prepareView?(view.panDegrees,view.upperTarget)==true
            let ready=viewReady?(view.panDegrees,view.upperTarget)==true
            status(view,prepared,ready)
            if prepared && ready {
                settledSince=settledSince ?? ProcessInfo.processInfo.systemUptime
                if ProcessInfo.processInfo.systemUptime-settledSince!>=1.5 {return}
            } else {settledSince=nil}
            guard ProcessInfo.processInfo.systemUptime<deadline else {
                throw ROBWorkspaceDepthMapError.acquisition("neck did not maintain its 1.5 s settled interval within 8 s (prepareAccepted=\(prepared), viewReady=\(ready), settledFor=\(settledSince.map {ProcessInfo.processInfo.systemUptime-$0} ?? 0) s)")
            }
            try await Task.sleep(nanoseconds:100_000_000)
        }
    }

    /// Preparing the first allowed view can restore lower6011 and its native
    /// pan envelope. Do that BEFORE clamping the full scan, so a restricted
    /// startup envelope does not silently collapse all later upright views.
    @MainActor @nonobjc private func preparedCollisionScanViews(check:()throws->Void,
        status:(ROBWorkspaceView,Bool,Bool)->Void) async throws->[ROBWorkspaceView] {
        let stage=ROBWorkspaceView(panDegrees:boundedPan?(0) ?? 0,upperTarget:5650)
        guard stage.panDegrees.isFinite,canUseView?(stage.panDegrees,stage.upperTarget) != false else {
            throw ROBWorkspaceDepthMapError.acquisition("No native-allowed neck view is available to stage the workspace scan.")
        }
        try await settleCollisionScanView(stage,check:check,status:status)
        try check();try Task.checkCancellation()
        let neck=ROBFixedHeadCalibrationWindowController.shared.readNeck?() ?? [:]
        guard neck["known"]as?Bool==true,neck["stationary"]as?Bool==true,neck["lower"]as?Int==6011 else {
            throw ROBWorkspaceDepthMapError.acquisition("Workspace scan staging did not establish the unchanged upright lower-neck hold.")
        }
        let requested = [-45.0,-15,15,45].map {ROBWorkspaceView(panDegrees:$0,upperTarget:5650)}
            + [30.0,0,-30].map {ROBWorkspaceView(panDegrees:$0,upperTarget:6306)}
        var views:[ROBWorkspaceView]=[]
        for request in requested {
            let pan=boundedPan?(request.panDegrees) ?? request.panDegrees
            guard pan.isFinite else {throw ROBWorkspaceDepthMapError.invalidFrame}
            let view=ROBWorkspaceView(panDegrees:pan,upperTarget:request.upperTarget)
            if canUseView?(pan,view.upperTarget) != false,!views.contains(view) {views.append(view)}
        }
        guard !views.isEmpty else {throw ROBWorkspaceDepthMapError.acquisition("No scan views remain within the freshly settled native neck bounds.")}
        return views
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
        let rawCapture=RawScanCapture(model:model,generation:generation)
        defer {rawCapture.closeIfIncomplete()}
        let scanBodyIdentity=ROBFixedHeadBodyMotionIdentity.currentIdentity
        var captureAnchor = ROBWorkspaceCaptureAnchor()
        var map:ROBWorkspaceDepthMap?
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
                    "camera_health":vision.healthSnapshot(),"markerless_registration_probe":vision.collisionRegistrationDiagnostics(),"raw_archive":rawCapture.report]
                lastReport = failureReport as NSDictionary
            }
            vision.endCollisionRegistrationProbe(); finishView?()
        }
        scanPhase="staging upright neck before selecting scan views"
        let stagingCheck:()throws->Void = {
            try check();try self.requireEstimatedProjectionIdentity(estimatedProjectionIdentity,model:model)
            guard ROBFixedHeadBodyMotionIdentity.currentIdentity==scanBodyIdentity,
                  captureAnchor.permitsCurrent(vision.cameraGeneration),
                  (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"]as?NSNumber)?.uint64Value==generation else {
                throw ROBWorkspaceDepthMapError.invalidFrame
            }
        }
        let settleStatus:(ROBWorkspaceView,Bool,Bool)->Void = {view,prepared,ready in
            currentView=view;lastPrepareAccepted=prepared;lastViewReady=ready
        }
        var views=try await preparedCollisionScanViews(check:stagingCheck,status:settleStatus)
        // A local fixed-pose proof cannot be stretched across an unmeasured sweep.
        if let fixed=registeredCurrentView(model:model) {views=[fixed]}
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
            do {try await settleCollisionScanView(view,check:stagingCheck,status:settleStatus)}
            catch {throw acquisitionFailure(error.localizedDescription)}
            var projectionBudget=ROBWorkspaceProjectionRetryBudget(startedAtUptime:ProcessInfo.processInfo.systemUptime)
            var projectedInView=0,lastAttemptSequence:UInt64=0,lastAttemptCapture=0.0
            var heldScope:ROBFixedHeadRegistrationScope?,heldServiceSHA:String?,heldUndistorted:Bool?
            func validateHeldView()throws {
                try check();try Task.checkCancellation()
                try requireEstimatedProjectionIdentity(estimatedProjectionIdentity,model:model)
                guard captureAnchor.permitsCurrent(vision.cameraGeneration),
                      ROBFixedHeadBodyMotionIdentity.currentIdentity==scanBodyIdentity,
                      (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"]as?NSNumber)?.uint64Value==generation,
                      viewReady?(view.panDegrees,view.upperTarget)==true else {
                    throw acquisitionFailure("held neck/body, source generation or authenticated Amber session changed during projection capture")
                }
                if let heldScope {
                    let neck=ROBFixedHeadCalibrationWindowController.shared.readNeck?() ?? [:]
                    guard neck["known"]as?Bool==true,neck["stationary"]as?Bool==true,
                          neck["pan"]as?Int==heldScope.panTarget,neck["lower"]as?Int==heldScope.lowerTarget,
                          neck["upper"]as?Int==heldScope.upperTarget else {
                        throw acquisitionFailure("the exact raw neck hold changed during projection capture")
                    }
                }
            }
            func projectionDeadlineFailure()->ROBWorkspaceDepthMapError {
                acquisitionFailure(projectionBudget.lastExpiration?.localizedDescription ?? "camera startup did not provide fresh settled RGB-D for this view within 8 s")
            }
            while projectedInView<2 {
                scanPhase = "waiting for fresh settled RGB-D"
                try validateHeldView()
                guard ProcessInfo.processInfo.systemUptime<projectionBudget.deadlineUptime else {throw projectionDeadlineFailure()}
                var acceptedFrame:ROBArmRoutineVision.Frame?
                while acceptedFrame == nil {
                    try validateHeldView()
                    let beforeCapture = vision.cameraGeneration
                    do {
                        let candidate = try await vision.settledDepthFrame(deadlineUptime:projectionBudget.deadlineUptime)
                        if captureAnchor.accept(frameGeneration:candidate.cameraGeneration,currentGeneration:vision.cameraGeneration) {
                            acceptedFrame = candidate
                        } else if map != nil {
                            throw acquisitionFailure("capture generation changed after the first projected frame")
                        }
                    } catch {
                        try Task.checkCancellation(); try check()
                        if ProcessInfo.processInfo.systemUptime>=projectionBudget.deadlineUptime {throw projectionDeadlineFailure()}
                        guard captureAnchor.cameraGeneration == nil,
                              error is CancellationError || vision.cameraGeneration != beforeCapture else { throw acquisitionFailure(error.localizedDescription) }
                    }
                    guard acceptedFrame != nil || ProcessInfo.processInfo.systemUptime < projectionBudget.deadlineUptime else {
                        throw projectionDeadlineFailure()
                    }
                }
                let frame = acceptedFrame!
                frameSequence = frame.sequence; frameCapturedAt = frame.capturedAt
                try validateHeldView()
                guard ProcessInfo.processInfo.systemUptime<projectionBudget.deadlineUptime else {throw projectionDeadlineFailure()}
                guard frame.sequence>lastAttemptSequence,frame.capturedAt>lastAttemptCapture else {
                    throw acquisitionFailure("projection input did not advance beyond the previously attempted source frame")
                }
                lastAttemptSequence=frame.sequence;lastAttemptCapture=frame.capturedAt
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
                let sourceScope=try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame)
                if let heldScope {
                    guard sourceScope==heldScope,k.cameraServiceSourceSHA256==heldServiceSHA,k.rgbOutputUndistorted==heldUndistorted else {
                        throw acquisitionFailure("the exact held pose or native source geometry changed while reacquiring projection pixels")
                    }
                } else {heldScope=sourceScope;heldServiceSHA=k.cameraServiceSourceSHA256;heldUndistorted=k.rgbOutputUndistorted}
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
                } catch {
                    // append rejects age BEFORE mutation. Keep completed map
                    // frames and reacquire actual later pixels, never restamp.
                    try validateHeldView()
                    guard let typed=error as?ROBWorkspaceDepthMapError,case .expiredAtProjection=typed else {
                        throw acquisitionFailure(error.localizedDescription)
                    }
                    if projectionBudget.permitsRetry(after:typed,nowUptime:ProcessInfo.processInfo.systemUptime,
                        contextIsCurrent:true,taskCancelled:Task.isCancelled) {
                        progress("Discarding expired depth frame \(sequence); checking a new settled frame.")
                        continue
                    }
                    throw acquisitionFailure(error.localizedDescription)
                }
                try validateHeldView()
                guard ProcessInfo.processInfo.systemUptime<projectionBudget.deadlineUptime else {throw projectionDeadlineFailure()}
                await rawCapture.append(frame,sceneID:currentMap.sceneID,scope:sourceScope,transform:transform,
                    selfBounds:selfBounds,registration:measured?.registration,projectionIdentity:estimated?.identity)
                projectedInView+=1
                framesProjected += 1
                try validateHeldView()
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
        await rawCapture.finish(snapshot)
        lastReport = ["status":"collision_scene_captured", "detail":snapshot.registrationDetail,
            "scene_id":snapshot.sceneID.uuidString,"depth_frames":snapshot.observedFrameCount,
            "occupied_voxels":snapshot.occupiedVoxelCount,"free_voxels":snapshot.freeVoxelCount,
            "registration_verified":snapshot.registrationID != nil,"markerless_registration_probe":vision.collisionRegistrationDiagnostics()]
        completed = true
        var archiveReport=lastReport as? [String:Any] ?? [:];archiveReport["raw_archive"]=rawCapture.report
        lastReport=archiveReport as NSDictionary
        return snapshot
    }

    /// Diagnostics only. Raw pixels do not classify robot returns or admit
    /// motion. History is observed telemetry, never a planned/FK substitute.
    /// Replay occupied contributors from each saved original sparse (x,y):
    /// z=u16le/1000, optical=((x-cx)*z/fx,(y-cy)*z/fy,z), then saved column-major
    /// cameraToRobot. Apply saved workspace/registered-volume/self-mask rules;
    /// floor(world/0.025) is the source-group ID before27-cell dilation.
    /// Occupancy precedes neighbor consistency: that test affects FREE rays
    /// only. Missing/archive-failed pixels never supply classification or FREE.
    @MainActor private final class RawScanCapture {
        let model:ROBGhostRobotModel,generation:UInt64
        let parentDirectory:URL
        var finished=false
        var writer:ROBWorkspaceRawScanArchive?,failure:String?,records:[ROBWorkspaceRawScanArchive.Record]=[]
        var telemetry:[String:[ROBAmberGatewayTelemetry]]=[:]
        var observer:NSObjectProtocol?
        init(model:ROBGhostRobotModel,generation:UInt64,parentDirectory:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/WorkspaceRawScans",isDirectory:true)) {
            self.model=model;self.generation=generation;self.parentDirectory=parentDirectory
            observer=NotificationCenter.default.addObserver(forName:.ROBAmberGatewayTelemetryDidUpdate,
                object:ROBAmberGatewayClient.shared,queue:.main){[weak self] note in
                guard let sample=note.userInfo?["telemetry"]as?ROBAmberGatewayTelemetry else{return}
                MainActor.assumeIsolated {self?.record(sample)}
            }
            for arm in ["left","right"] {if let sample=ROBAmberGatewayClient.shared.telemetry(forArm:arm){record(sample)}}
        }
        deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
        func record(_ sample:ROBAmberGatewayTelemetry) {
            guard (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"]as?NSNumber)?.uint64Value==generation,
                  sample.sequence>0,sample.sampleAgeAtReceiptMilliseconds.isFinite else{return}
            var values=telemetry[sample.arm] ?? []
            if values.last?.sequence != sample.sequence {values.append(sample);if values.count>240 {values.removeFirst(values.count-240)}}
            telemetry[sample.arm]=values
        }
        func feedback(_ physical:String,frameTime:Double)->ROBWorkspaceRawScanArchive.Availability<ROBWorkspaceRawScanArchive.ArmFeedback> {
            let arm=physical=="left" ? "right":"left",gateway=ROBAmberGatewayClient.shared
            guard let sample=telemetry[arm]?.min(by:{a,b in
                abs(a.receivedAt.timeIntervalSince1970*1000-a.sampleAgeAtReceiptMilliseconds-frameTime)<abs(b.receivedAt.timeIntervalSince1970*1000-b.sampleAgeAtReceiptMilliseconds-frameTime)
            }),sample.positionsRadians.count==7,sample.positionsRadians.allSatisfy({$0.doubleValue.isFinite}),sample.statuses.count==7,
                  sample.effectiveSampleAgeMilliseconds.isFinite,sample.effectiveSampleAgeMilliseconds>=0,
                  sample.effectiveGripperFeedbackAgeMilliseconds.isFinite,sample.effectiveGripperFeedbackAgeMilliseconds>=0,
                  abs(sample.receivedAt.timeIntervalSince1970*1000-sample.sampleAgeAtReceiptMilliseconds-frameTime)<=150,
                  let sourceModel=try?ROBGhostRobotModel(directory:model.directory,physicalSide:physical),gateway.modes(forArm:arm).count==7 else {
                return .unavailable("No actual exposure-nearest physical \(physical) telemetry within150ms in this passive scan history")
            }
            return .available(.init(physicalSide:physical,gatewayArm:arm,telemetrySequence:sample.sequence,
                receivedAtHostMilliseconds:sample.receivedAt.timeIntervalSince1970*1000,effectiveSampleAgeMilliseconds:sample.effectiveSampleAgeMilliseconds,
                effectiveGripperAgeMilliseconds:sample.effectiveGripperFeedbackAgeMilliseconds,positionsRadians:sample.positionsRadians.map(\.doubleValue),
                reportedModes:sample.statuses.map(\.intValue),gatewayModes:gateway.modes(forArm:arm).map(\.intValue),
                exposureOffsetMilliseconds:.available(frameTime-(sample.receivedAt.timeIntervalSince1970*1000-sample.sampleAgeAtReceiptMilliseconds)),
                referenceIdentity:.unavailable("Raw vendor encoder coordinates; native session reference token is not serialized"),
                modelID:sourceModel.modelID,geometryID:sourceModel.geometryID,mappingID:sourceModel.selectedMappingID))
        }
        func append(_ frame:ROBArmRoutineVision.Frame,sceneID:UUID,scope:ROBFixedHeadRegistrationScope,
            transform:simd_double4x4,selfBounds:[(low:SIMD3<Double>,high:SIMD3<Double>)],registration:ROBFixedHeadRegistration?,projectionIdentity:String?) async {
            guard failure==nil else{return}
            do {
                guard let depth=frame.depth,let k=frame.intrinsics,let runtime=k.runtimeCalibration,
                      let image=CIContext(options:[.useSoftwareRenderer:true]).createCGImage(frame.image,from:frame.image.extent),
                      image.width==depth.width,image.height==depth.height else {throw ROBWorkspaceRawScanArchive.ArchiveError.rejected("Passive source RGB/depth raster/runtime is unavailable")}
                if writer==nil {
                    writer=try await .create(parentDirectory:parentDirectory,scene:.init(archiveID:UUID(),workspaceSceneID:sceneID,
                        bodyMotionIdentity:ROBFixedHeadBodyMotionIdentity.currentIdentity,gatewayGeneration:generation,
                        modelID:model.modelID,referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID))
                }
                var rgba=[UInt8](repeating:0,count:depth.width*depth.height*4)
                let rendered=rgba.withUnsafeMutableBytes{bytes->Bool in
                    guard let drawing=CGContext(data:bytes.baseAddress,width:depth.width,height:depth.height,bitsPerComponent:8,
                        bytesPerRow:depth.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
                    drawing.draw(image,in:CGRect(x:0,y:0,width:depth.width,height:depth.height));return true
                }
                guard rendered else {throw ROBWorkspaceRawScanArchive.ArchiveError.rejected("Passive normalized RGB888 copy failed")}
                var rgb=Data(count:depth.width*depth.height*3)
                rgb.withUnsafeMutableBytes{buffer in let out=buffer.bindMemory(to:UInt8.self)
                    for i in 0..<(depth.width*depth.height) {out[i*3]=rgba[i*4];out[i*3+1]=rgba[i*4+1];out[i*3+2]=rgba[i*4+2]}}
                let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                func json(_ object:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)}
                let contracts:[String:Any]=["pixelSource":"retained normalized source raster rendered RGB888 without resizing",
                    "rgbOutputUndistorted":k.rgbOutputUndistorted as Any? ?? NSNull(),"depthRGBGeometryCorrespondence":k.depthRGBGeometryCorrespondence?.status as Any? ?? NSNull(),
                    "cameraServiceSourceSHA256":k.cameraServiceSourceSHA256 as Any? ?? NSNull(),"runtimeCalibrationIdentity":runtime.identity,
                    "sourceSize":k.sourceSize as Any? ?? NSNull(),"sourceIntrinsics":k.sourceIntrinsics as Any? ?? NSNull(),"imageTransform":k.imageTransform as Any? ?? NSNull(),
                    "depthSourceSize":k.depthSourceSize as Any? ?? NSNull(),"depthSourceIntrinsics":k.depthSourceIntrinsics as Any? ?? NSNull(),"depthImageTransform":k.depthImageTransform as Any? ?? NSNull(),
                    "rgbSourceDistortionCoefficients":k.rgbSourceDistortionCoefficients as Any? ?? NSNull(),"depthSourceDistortionCoefficients":k.depthSourceDistortionCoefficients as Any? ?? NSNull(),
                    "gatewayModesObservation":"current native modes at copy time; reportedModes/q are historical telemetry; host association is not exact sensor exposure sync"]
                let sampling:[String:Any]=["mapper":"ROBWorkspaceDepthMap.append_original_normalized_depth_v1","firstPixel":[1,1],
                    "exclusivePixelUpperBound":[depth.width-1,depth.height-1],"stride":max(2,Int(ceil(sqrt(Double(depth.width*depth.height)/12000)))),
                    "acceptedDepthMillimeters":[100,3000],"depthUnits":"u16le_mm","sourceVoxelSizeMeters":0.025,
                    "sourceGroupID":"floor(projectedX/0.025),floor(projectedY/0.025),floor(projectedZ/0.025)","occupiedDilationOffsets":[-1,0,1],
                    "workspaceLowMeters":[-2,-2,-0.3],"workspaceHighMeters":[2,2,2.4],"pixelConvention":"original normalized top-left RGB-D",
                    "registeredValidRobotVolume":try registration.map{try JSONSerialization.jsonObject(with:encoder.encode($0.validRobotVolume))} ?? NSNull(),
                    "measuredSelfMaskApplied":registration != nil && !selfBounds.isEmpty,"measuredSelfMaskMarginMeters":0.01,
                    "measuredSelfBounds":registration == nil ? []:selfBounds.map{["low":[$0.low.x,$0.low.y,$0.low.z],"high":[$0.high.x,$0.high.y,$0.high.z]]},
                    "finalMapLink":"manifest.json sourceMapBinding; all source frames must match before complete","observedSelf":false]
                let input=ROBWorkspaceRawScanArchive.Frame(frameID:UUID(),sequence:frame.sequence,capturedAtHostMilliseconds:frame.capturedAt,
                    rgbCapturedAtHostMilliseconds:.unavailable("Independent RGB exposure host timestamp not exported by retained frame"),
                    depthCapturedAtHostMilliseconds:.unavailable("Independent depth exposure host timestamp not exported by retained frame"),
                    sourceTimestampJSON:.unavailable("Independent device clock timestamps not exported by retained frame"),cameraGeneration:frame.cameraGeneration,
                    width:depth.width,height:depth.height,rgb888:rgb,depthU16LittleEndian:Data(depth.millimetersLittleEndian),
                    infrared:.unavailable("IR not exported by retained frame"),infraredContractJSON:.unavailable("IR not exported by retained frame"),intrinsics:[k.fx,k.fy,k.cx,k.cy],
                    sourceContractsJSON:try json(contracts),runtimeCalibrationJSON:try encoder.encode(runtime),
                    imuJSON:try k.inertial.map{.available(try encoder.encode($0))} ?? .unavailable("No actual IMU packet in retained frame"),
                    actualAppliedNeck:.available(.init(appliedPanTarget:scope.panTarget,appliedLowerTarget:scope.lowerTarget,appliedUpperTarget:scope.upperTarget,
                        observedAtHostMilliseconds:Date().timeIntervalSince1970*1000,stationary:true,source:"native validated source scope; copied while held view remains checked")),
                    physicalLeftFeedback:feedback("left",frameTime:frame.capturedAt),physicalRightFeedback:feedback("right",frameTime:frame.capturedAt),
                    cameraToRobotColumnMajor:(0..<4).flatMap{c in (0..<4).map{r in transform[c][r]}},
                    projectionMethod:registration == nil ? "native_unregisteredCameraProjection_estimate_not_registration":"native_registeredCameraContext",
                    projectionScopeJSON:try json(["fixedHeadScope":try JSONSerialization.jsonObject(with:encoder.encode(scope)),
                        "registrationID":registration?.id as Any? ?? NSNull(),"estimatedCameraProjectionIdentity":projectionIdentity as Any? ?? NSNull()]),returnSamplingContractJSON:try json(sampling))
                records.append(try await writer!.append(input))
            }catch {failure=error.localizedDescription;await writer?.closeIncomplete(reason:error.localizedDescription)}
        }
        func finish(_ snapshot:ROBWorkspaceCollisionSnapshot) async {
            guard failure==nil,let writer else {return}
            do {
                let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                _ = try await writer.finish(sourceMap:.init(workspaceSceneID:snapshot.sceneID,mapFingerprint:snapshot.fingerprint,
                    serializedJSON:try encoder.encode(snapshot),observations:snapshot.observations.map{.init(sequence:$0.sequence,
                        capturedAtHostMilliseconds:$0.capturedAtMilliseconds,cameraGeneration:snapshot.cameraGeneration)}))
                finished=true
            }catch {failure=error.localizedDescription;await writer.closeIncomplete(reason:error.localizedDescription)}
        }
        var report:[String:Any] {[
            "status":finished ? "complete":"incomplete","detail":failure as Any? ?? (finished ? NSNull():"Raw source-map binding is incomplete"),
            "directory":writer?.directory.path as Any? ?? NSNull(),"archived_frames":records.count,"exact_sensor_exposure_timestamps":false,
            "self_classification":false,"motion_authority":false]}
        func closeIfIncomplete() {
            if let writer {Task {await writer.closeIncomplete(reason:"Passive scan ended before final source-map binding; retained map has no complete raw archive")}}
        }
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
        permitsLocalCanShapePrior: () throws -> Bool = {false}, canReachBaseline:[String:Double]? = nil,
        passiveFeedbackCheckpoint:(() async throws->Void)?=nil,
        check: () throws -> Void, progress: (String) -> Void) async throws -> [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] {
        func searchCheckpoint() async throws {
            if let passiveFeedbackCheckpoint {try await passiveFeedbackCheckpoint()}
            try check() // Strict admission remains after the asynchronous pause.
        }
        let vision = ROBArmRoutineVision.shared
        locatedObjects = [:]
        canCandidates = ROBWorkspaceCanCandidateSet()
        collisionSnapshotValue = nil
        collisionSnapshotModel = model
        var sceneCaptureAnchor = ROBWorkspaceCaptureAnchor()
        let sceneGatewayGeneration = (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        let collectCollisionDepth = sceneGatewayGeneration > 0
        var collisionMap:ROBWorkspaceDepthMap?
        var collisionEnrollment = ROBWorkspaceFrameEnrollment()
        if collectCollisionDepth { vision.beginCollisionRegistrationProbe() }
        var found: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]
        var confirmedCanCandidates = ROBWorkspaceCanCandidateSet()
        let sceneBodyIdentity = ROBFixedHeadBodyMotionIdentity.currentIdentity
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
        if targets.contains(.can), fixedRegisteredView == nil {
            tabletopCanBaseHeight = try ROBLeftCanReachCalibration.loadTabletopCanBaseHeight(model:model,
                estimatedCameraProjectionIdentity:estimatedProjectionIdentity)
        }
        else { tabletopCanBaseHeight = nil }
        var selectedCanMeasurement: ROBWorkspaceLocatedObject?
        var currentCanSightings:[ROBWorkspaceRecall.Sighting]=[]
        var reachSelections:[[String:Any]]=[]
        var localReachSelection:ROBWorkspaceCanSelection?
        var localReachSelectionRequired=false
        var schedule = ROBWorkspaceSearchSchedule(targets:targets,recall:recall,
            boundedPan:boundedPan ?? { max(-45,min(45,$0)) })
        let recalledViews = schedule.recallViews
        var bestRecallQuality: [ROBWorkspaceTarget: Double] = [:]
        var recenterViews: [(target: ROBWorkspaceTarget, view: ROBWorkspaceView)] = []
        var recenteredViews: [ROBWorkspaceView] = []
        var clippedCanAttentionViews:[ROBWorkspaceView]=[]
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
                "nearest_reachable_can_selections":reachSelections,
                "nearest_reachable_candidates":localReachSelection?.diagnostics ?? [],
                "confirmed_can_candidates": confirmedCanCandidates.confirmed(nowMilliseconds:Date().timeIntervalSince1970*1000).map { object -> [String:Any] in
                    ["position":object.position,"confidence":object.confidence,"captured_at_ms":object.capturedAt,"sequence":NSNumber(value:object.sequence)]
                },
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
        func accumulateCollisionDepth(_ view: ROBWorkspaceView, capturedFrame:ROBArmRoutineVision.Frame? = nil,
                                      preservingSceneID:UUID? = nil) async throws {
            guard collectCollisionDepth else { return }
            try await searchCheckpoint()
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
            guard preservingSceneID.map({$0==currentMap.sceneID}) ?? true else {throw ROBWorkspaceDepthMapError.invalidFrame}
            if Date().timeIntervalSince1970*1000-currentMap.createdAtMilliseconds > 55_000 {
                guard preservingSceneID==nil else {
                    throw ROBWorkspaceDepthMapError.acquisition("Arm-side depth coverage cannot replace the object scene with a new map.")
                }
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
            try await searchCheckpoint()
            try requireSceneProjectionIdentity()
            guard isViewReady(view) else { throw ROBWorkspaceDepthMapError.invalidFrame }
        }
        func moveView(_ view: ROBWorkspaceView, deadlineUptime:Double? = nil) async throws -> Bool {
            try requireSceneProjectionIdentity()
            if canUseView?(view.panDegrees, view.upperTarget) == false {
                evidence.append(["pan": view.panDegrees, "upper": view.upperTarget, "status": "outside_current_neck_envelope"])
                return false
            }
            let deadline = min(ProcessInfo.processInfo.systemUptime + 12,deadlineUptime ?? .infinity)
            var settledSince: TimeInterval?
            progress(String(format: "Local search: camera pan %+.0f°, tilt target %d", view.panDegrees, view.upperTarget))
            while ProcessInfo.processInfo.systemUptime < deadline {
                try await searchCheckpoint()
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
            var passiveExpiredProjectionRetries=0
            for attempt in 0..<4 {
                if attempt >= 2 && (!requireDepth || !retryVisibleDepth) { break }
                retryVisibleDepth = false
                try await searchCheckpoint()
                guard isViewReady(view) else {
                    throw ROBArmRoutineError.blocked("Search camera moved during inspection.")
                }
                var acceptedWorkspace:(ROBWorkspaceObservation,ROBArmRoutineVision.Frame)?
                while acceptedWorkspace == nil {
                    try await searchCheckpoint(); try Task.checkCancellation()
                    guard observationCaptureAnchor.permitsCurrent(vision.cameraGeneration) else { throw CancellationError() }
                    guard isViewReady(view) else {
                        throw ROBArmRoutineError.blocked("Search camera moved during startup inspection.")
                    }
                    do {
                        let candidate = try await vision.observeWorkspace(objectDetection: !targets.isEmpty,nonactuatingSparseDepth:true) { sourceFrame in
                            try await accumulateCollisionDepth(view,capturedFrame:sourceFrame)
                        }
                        guard observationCaptureAnchor.accept(frameGeneration:candidate.1.cameraGeneration,
                            currentGeneration:vision.cameraGeneration) else { throw CancellationError() }
                        acceptedWorkspace = candidate
                    }
                    catch let error as ROBWorkspaceDepthMapError {
                        guard passiveFeedbackCheckpoint != nil,case .expiredAtProjection=error,passiveExpiredProjectionRetries<2 else {throw error}
                        passiveExpiredProjectionRetries+=1
                        try await searchCheckpoint()
                        evidence.append(["discarded_expired_source_after_passive_checkpoint":true,"capture_time_refreshed":false])
                        continue
                    }
                    catch is CancellationError {
                        try Task.checkCancellation(); try await searchCheckpoint()
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
                try await searchCheckpoint()
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
                        currentCanSightings=(observation.cans ?? [observation.can]).filter(\.visuallyUsable).map {
                            ROBWorkspaceRecall.Sighting(target:.can,view:view,box:$0.box,confidence:$0.confidence,capturedAt:frame.capturedAt)
                        }
                        if targets.contains(.orangeBucket),clippedCanAttentionViews.count<2 {
                            let attention=ROBWorkspaceCanRecenterPlan.clippedAttentionViews(sightings:currentCanSightings,
                                nowMilliseconds:Date().timeIntervalSince1970*1000,
                                boundedPan:boundedPan ?? {max(-45,min(45,$0))})
                            var attentionInsertIndex=0
                            for centered in attention where clippedCanAttentionViews.count<2 &&
                                !schedule.hasAttempted(centered) &&
                                !clippedCanAttentionViews.contains(where:{abs($0.panDegrees-centered.panDegrees)<3 && abs($0.upperTarget-centered.upperTarget)<100}) {
                                clippedCanAttentionViews.append(centered)
                                recenterViews.insert((.can,centered),at:attentionInsertIndex)
                                attentionInsertIndex+=1
                                evidence.append(["clipped_can_attention_only":true,"pan":centered.panDegrees,
                                    "upper":centered.upperTarget,"source_sequence":NSNumber(value:frame.sequence),
                                    "source_captured_at_ms":frame.capturedAt,"maximum_views":2,
                                    "located_object":false,"path_admitted":false])
                            }
                        }
                        var candidates: [(detection: ROBWorkspaceDetection, object: ROBWorkspaceLocatedObject)] = []
                        var sectionDiagnostics: [[String:Any]] = []
                        var sectionSource: [String:Any] = ["sequence":NSNumber(value:frame.sequence),
                            "captured_at_ms":frame.capturedAt,"camera_generation":frame.cameraGeneration.uuidString,
                            "body_motion_identity":collisionMap?.bodyMotionIdentity ?? sceneBodyIdentity,
                            "model_id":model.modelID,"geometry_id":model.geometryID,"mapping_id":model.selectedMappingID,
                            "physical_arm":model.physicalSide,"depth_width":depth.width,"depth_height":depth.height,
                            "runtime_calibration_identity":k.runtimeCalibration?.identity as Any? ?? NSNull(),
                            "camera_service_source_sha256":k.cameraServiceSourceSHA256 as Any? ?? NSNull(),
                            "rgb_output_undistorted_contract":k.rgbOutputUndistorted as Any? ?? NSNull(),
                            "estimated_camera_projection_identity":estimatedCamera?.identity as Any? ?? NSNull(),
                            "registration_id":measuredCamera?.registration.id as Any? ?? NSNull(),
                            "capture_time_refreshed":false,"geometry_thresholds_changed":false]
                        do {
                            let sourceScope=try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame)
                            sectionSource["raw_neck_pan_target"]=sourceScope.panTarget
                            sectionSource["raw_neck_lower_target"]=sourceScope.lowerTarget
                            sectionSource["raw_neck_upper_target"]=sourceScope.upperTarget
                            sectionSource["raw_neck_source"]="stationary held-view scope for this source frame; accepted commands, not measured shaft angles"
                        } catch { sectionSource["source_scope_error"]=error.localizedDescription }
                        entry["can_section_source"]=sectionSource
                        var rejected = 0
                        for candidate in observation.cans ?? [observation.can] {
                            let result=ROBWorkspaceCanSections.measureWithDiagnostics(detection:candidate,width:depth.width,height:depth.height,
                                fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,depth:{ depth.distanceMillimeters(x:$0,y:$1) },view:view,model:model,
                                cameraToRobot:cameraTransform)
                            var diagnostic=result.diagnostics
                            diagnostic["source"]=sectionSource
                            diagnostic["section_measurement_accepted"]=result.sections != nil
                            var acceptedSections=result.sections
                            if acceptedSections==nil,try permitsLocalCanShapePrior(),measuredCamera==nil,
                               let cameraTransform,let projection=estimatedCamera?.identity,
                               let sourceMap=collisionMap,sourceMap.estimatedCameraProjectionIdentity==projection,
                               sourceMap.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity,
                               frame.cameraGeneration==vision.cameraGeneration,
                               collisionEnrollment.sequence==frame.sequence,
                               collisionEnrollment.capturedAtMilliseconds==frame.capturedAt,
                               (0...30_000).contains(Date().timeIntervalSince1970*1000-frame.capturedAt) {
                                let prior=localCanShapePrior(detection:candidate,allCanDetections:observation.cans ?? [observation.can],
                                    frame:frame,view:view,model:model,cameraToRobot:cameraTransform)
                                diagnostic["local_shape_prior"]=prior.diagnostics
                                try await searchCheckpoint();try requireSceneProjectionIdentity()
                                guard try permitsLocalCanShapePrior(),isViewReady(view),
                                      frame.cameraGeneration==vision.cameraGeneration,
                                      sourceMap.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity else {throw CancellationError()}
                                acceptedSections=prior.sections
                            }
                            guard let sections=acceptedSections else {
                                diagnostic["candidate_admission_status"]="section_measurement_rejected"
                                sectionDiagnostics.append(diagnostic);rejected += 1;continue
                            }
                            if sections.shapePriorEvidence != nil {
                                diagnostic["measured_section_rejection_stage"]=diagnostic["rejection_stage"] ?? NSNull()
                                diagnostic["rejection_stage"]=NSNull()
                                diagnostic["status"]="accepted_estimated_prior"
                                diagnostic["candidate_geometry_source"]="local_trial_known_empty_coke_prior_not_measured_bands"
                            }
                            guard tabletopCanBaseHeight.map({abs(sections.bottom[2]-$0)<=0.15}) ?? true else {
                                diagnostic["status"]="rejected";diagnostic["rejection_stage"]="tabletop_base_height_disagreement"
                                diagnostic[sections.shapePriorEvidence==nil ? "measured_base_z_m" : "estimated_base_z_m"]=sections.bottom[2]
                                diagnostic["tabletop_base_z_m"]=tabletopCanBaseHeight!
                                diagnostic["candidate_admission_status"]="rejected_after_section_measurement"
                                sectionDiagnostics.append(diagnostic);rejected += 1;continue
                            }
                            let object = ROBWorkspaceLocatedObject(target:.can,position:sections.middle,confidence:candidate.confidence,
                                capturedAt:frame.capturedAt,sequence:frame.sequence,view:view,sections:sections,registrationID:measuredCamera?.registration.id)
                            if let registration = measuredCamera?.registration,
                               !registration.validRobotVolume.contains(object.point) {
                                diagnostic["status"]="rejected";diagnostic["rejection_stage"]="outside_fixed_head_registration_volume"
                                diagnostic["candidate_admission_status"]="rejected_after_section_measurement"
                                sectionDiagnostics.append(diagnostic);rejected += 1;continue
                            }
                            do {
                                _ = try ROBLeftCanReachCalibration.load(model:model,can:object,
                                    estimatedCameraProjectionIdentity:estimatedCamera?.identity)
                            } catch {
                                diagnostic["status"]="rejected";diagnostic["rejection_stage"]="reach_calibration_configuration_invalid"
                                diagnostic["reason"]=error.localizedDescription
                                diagnostic["candidate_admission_status"]="rejected_after_section_measurement"
                                sectionDiagnostics.append(diagnostic);rejected += 1;continue
                            }
                            diagnostic["candidate_admission_status"]="accepted"
                            sectionDiagnostics.append(diagnostic)
                            candidates.append((candidate,object))
                        }
                        entry["can_section_diagnostics"]=sectionDiagnostics
                        let candidateContext = ROBWorkspaceCanSceneIdentity(sceneID:collisionMap?.sceneID,
                            cameraGeneration:frame.cameraGeneration,sessionGeneration:sceneGatewayGeneration,
                            bodyMotionIdentity:collisionMap?.bodyMotionIdentity ?? sceneBodyIdentity,
                            modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                            estimatedCameraProjectionIdentity:estimatedProjectionIdentity)
                        confirmedCanCandidates.observe(candidates.map(\.object),context:candidateContext,
                            nowMilliseconds:Date().timeIntervalSince1970*1000)
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
                            let heightKey=sections.shapePriorEvidence==nil ? "calibrated_middle_height_m" : "estimated_middle_height_m"
                            return ["box":candidate.detection.box,"confidence":object.confidence,"position":object.position,
                                "top":sections.top,"middle":sections.middle,"base":sections.bottom,
                                "height_m":sections.heightMeters,"diameter_m":sections.diameterMeters,
                                heightKey:(tabletopCanBaseHeight ?? sections.bottom[2])+sections.heightMeters/2,
                                "geometry_source":sections.shapePriorEvidence==nil ? "measured_depth_bands" : "local_trial_assumed_known_cylinder",
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
                        if measurement==nil,try permitsLocalCanShapePrior(),measuredCamera==nil,
                           let cameraTransform,let projection=estimatedCamera?.identity,
                           let sourceMap=collisionMap,sourceMap.estimatedCameraProjectionIdentity==projection,
                           sourceMap.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity,
                           frame.cameraGeneration==vision.cameraGeneration,
                           collisionEnrollment.sequence==frame.sequence,collisionEnrollment.capturedAtMilliseconds==frame.capturedAt,
                           (0...30_000).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
                           let depth=frame.depth,let k=frame.intrinsics,
                           let cg=CIContext(options:[.useSoftwareRenderer:true]).createCGImage(frame.image,from:frame.image.extent) {
                            let bitmap=NSBitmapImageRep(cgImage:cg)
                            if bitmap.pixelsWide==depth.width,bitmap.pixelsHigh==depth.height {
                                let prior=await Task.detached(priority:.userInitiated) {
                                    ROBWorkspaceBucketOpeningPrior.estimate(box:detection.box,width:depth.width,height:depth.height,
                                        fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,cameraToRobot:cameraTransform,
                                        depth:{depth.distanceMillimeters(x:$0,y:$1)},color:{x,y in
                                            guard let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(NSColorSpace.deviceRGB) else{return nil}
                                            return SIMD3(Double(color.redComponent),Double(color.greenComponent),Double(color.blueComponent))
                                        })
                                }.value
                                try await searchCheckpoint();try requireSceneProjectionIdentity()
                                guard try permitsLocalCanShapePrior(),isViewReady(view),
                                      frame.cameraGeneration==vision.cameraGeneration,
                                      sourceMap.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity else {throw CancellationError()}
                                if let prior {
                                    measurement = .init(target:.orangeBucket,position:[prior.center.x,prior.center.y,prior.center.z],
                                        confidence:detection.confidence,capturedAt:frame.capturedAt,sequence:frame.sequence,view:view,
                                        openingRadius:prior.radius,bucketShapePrior:prior.evidence,registrationID:nil)
                                    var priorReport:[String:Any]=["status":"accepted_estimated_prior","registration_verified":false,
                                        "source_sequence":NSNumber(value:frame.sequence),"source_captured_at_ms":frame.capturedAt,
                                        "camera_generation":frame.cameraGeneration.uuidString,
                                        "runtime_calibration_identity":k.runtimeCalibration?.identity as Any? ?? NSNull(),
                                        "camera_service_source_sha256":k.cameraServiceSourceSHA256 as Any? ?? NSNull(),
                                        "body_motion_identity":sourceMap.bodyMotionIdentity,"estimated_camera_projection_identity":projection,
                                        "measured_rim_rejected_reason":bucket.diagnostics.report["reason"] as Any? ?? NSNull()]
                                    if let encoded=try? JSONEncoder().encode(prior.evidence),
                                       let evidence=try? JSONSerialization.jsonObject(with:encoded) {priorReport["evidence"]=evidence}
                                    entry["bucket_shape_prior"]=priorReport
                                } else {entry["bucket_shape_prior"]=["status":"rejected","reason":"rgb_opening_floor_prior_unavailable"]}
                            }
                        }
                        try await searchCheckpoint()
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
                    try await searchCheckpoint()
                    let cameraHealth=vision.healthSnapshot()
                    evidence.append(["pan": view.panDegrees, "upper": view.upperTarget, "attempt": attempt + 1,
                        "error": error.localizedDescription, "local_inference": cameraHealth["inspection"] ?? [:],
                        "camera_health":cameraHealth])
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
                    try await searchCheckpoint()
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
                catch { try await searchCheckpoint(); evidence.append(["refresh_error": error.localizedDescription]) }
            }
        }
        // A visible/confirmed can may belong to the opposite arm. Try only
        // two current selected-side boxes before ending this can-only search.
        // Existing inspect requires two advancing exposures and enrolls their
        // exact RGB-D source frames into the same map before inference.
        if requireDepth,targets == [.can],fixedRegisteredView==nil,let reachBaseline=canReachBaseline,
           try permitsLocalCanShapePrior(),collisionMap != nil {
            guard (1...7).allSatisfy({reachBaseline[model.physicalSide+"_joint\($0)"]?.isFinite==true}) else {
                throw ROBArmRoutineError.blocked("The targeted can search needs the unchanged measured selected-arm baseline.")
            }
            localReachSelectionRequired=true
            let scene=collisionMap!.sceneID,camera=vision.cameraGeneration,body=sceneBodyIdentity
            func requireTargetedContext()throws {
                try check();try Task.checkCancellation();try requireSceneProjectionIdentity()
                guard try permitsLocalCanShapePrior(),collisionMap?.sceneID==scene,
                      sceneCaptureAnchor.permitsCurrent(camera),vision.cameraGeneration==camera,
                      ROBFixedHeadBodyMotionIdentity.currentIdentity==body,
                      (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"]as?NSNumber)?.uint64Value==sceneGatewayGeneration else {
                    throw ROBWorkspaceDepthMapError.invalidFrame
                }
            }
            func rankCurrentCans(_ stage:String) async throws ->ROBWorkspaceCanSelection {
                try await searchCheckpoint();try requireTargetedContext()
                guard let input=collisionMap,
                      let snapshot=await Task.detached(priority:.userInitiated,operation:{input.snapshot()}).value else {
                    throw ROBWorkspaceDepthMapError.invalidFrame
                }
                try await searchCheckpoint();try requireTargetedContext()
                let expected=ROBWorkspaceCanSceneIdentity(sceneID:scene,cameraGeneration:camera,
                    sessionGeneration:sceneGatewayGeneration,bodyMotionIdentity:body,modelID:model.modelID,
                    geometryID:model.geometryID,mappingID:model.selectedMappingID,
                    estimatedCameraProjectionIdentity:estimatedProjectionIdentity)
                let result=await selectReachableCan(candidates:confirmedCanCandidates.confirmed(nowMilliseconds:Date().timeIntervalSince1970*1000),
                    model:model,baseline:reachBaseline,map:snapshot,nowMilliseconds:Date().timeIntervalSince1970*1000,
                    contextIsCurrent:{(try? requireTargetedContext()) != nil && confirmedCanCandidates.context==expected})
                try await searchCheckpoint();try requireTargetedContext()
                reachSelections.append(["stage":stage,"candidates":result.diagnostics,"path_admitted":false])
                return result
            }
            localReachSelection=try await rankCurrentCans("before_targeted_reobservation")
            if localReachSelection?.object==nil {
                let views=ROBWorkspaceCanRecenterPlan.views(sightings:currentCanSightings,physicalSide:model.physicalSide,
                    nowMilliseconds:Date().timeIntervalSince1970*1000,boundedPan:boundedPan ?? {max(-45,min(45,$0))})
                for (index,view) in views.enumerated() {
                    try await searchCheckpoint();try requireTargetedContext()
                    found.removeValue(forKey:.can);locationConfirmation.invalidate(.can)
                    // Force this view's own two-exposure confirmation rather
                    // than ending on the previous opposite-arm discovery.
                    selectedCanMeasurement=nil
                    progress("Checking a nearer \(model.physicalSide)-arm can, view \(index+1) of \(views.count).")
                    try await inspectWithRetry(view)
                    try await searchCheckpoint();try requireTargetedContext()
                    localReachSelection=try await rankCurrentCans("targeted_reobservation_\(index+1)")
                    evidence.append(["targeted_can_reobservation":true,"attempt":index+1,"maximum_views":2,
                        "pan":view.panDegrees,"upper":view.upperTarget,"reachable_confirmed_can":localReachSelection?.object != nil,
                        "shape_thresholds_changed":false,"path_admitted":false])
                    if localReachSelection?.object != nil {found[.can]=localReachSelection!.object;break}
                }
            }
        }
        // The fast object search need not see the selected hanging arm. Add
        // only three bounded depth views for this explicit local trial; detector
        // inference, self masks, occupied returns and free-space gates are unchanged.
        // Use lateral parallax: tilting at one pan kept the hanging forearm
        // behind the same shoulder in the recorded failed entry scans.
        if requireDepth,collectCollisionDepth,fixedRegisteredView==nil,
           found[.can] != nil,(found[.orangeBucket] != nil || targets == [.can]),try permitsLocalCanShapePrior(),
           let originalMap=collisionMap,originalMap.estimatedCameraProjectionIdentity != nil {
            let started=ProcessInfo.processInfo.systemUptime,deadline=started+20
            let sceneID=originalMap.sceneID,camera=vision.cameraGeneration,body=originalMap.bodyMotionIdentity
            let desiredPan=model.physicalSide=="right" ? -55.0 : 55.0
            let alternatePan=model.physicalSide=="right" ? -35.0 : 35.0
            let uprightPan=model.physicalSide=="right" ? -45.0 : 45.0
            let coverageViews=[alternatePan,desiredPan].map {
                ROBWorkspaceView(panDegrees:boundedPan?($0) ?? $0,upperTarget:5650)
            } + [ROBWorkspaceView(panDegrees:boundedPan?(uprightPan) ?? uprightPan,upperTarget:5300)]
            var capturedViews=0
            func requireCoverageContext() throws {
                try check();try Task.checkCancellation();try requireSceneProjectionIdentity()
                guard try permitsLocalCanShapePrior(),collisionMap?.sceneID==sceneID,
                      vision.cameraGeneration==camera,sceneCaptureAnchor.permitsCurrent(camera),
                      body==ROBFixedHeadBodyMotionIdentity.currentIdentity,
                      (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value==sceneGatewayGeneration else {
                    throw ROBWorkspaceDepthMapError.invalidFrame
                }
            }
            progress("Checking \(model.physicalSide)-arm depth coverage.")
            for view in coverageViews {
                try await searchCheckpoint();try requireCoverageContext()
                guard ProcessInfo.processInfo.systemUptime<deadline else {break}
                let pan=view.panDegrees,upper=view.upperTarget
                guard try await moveView(view,deadlineUptime:deadline) else {continue}
                do {
                    let frame=try await vision.settledDepthFrame(deadlineUptime:deadline)
                    try await searchCheckpoint();try requireCoverageContext()
                    guard ProcessInfo.processInfo.systemUptime<deadline else {break}
                    try await accumulateCollisionDepth(view,capturedFrame:frame,preservingSceneID:sceneID)
                    try await searchCheckpoint();try requireCoverageContext()
                    guard collisionEnrollment.sequence==frame.sequence,
                          collisionEnrollment.capturedAtMilliseconds==frame.capturedAt else {throw ROBWorkspaceDepthMapError.invalidFrame}
                    capturedViews+=1
                    evidence.append(["depth_only_arm_coverage":true,"status":"captured","physical_arm":model.physicalSide,
                        "pan":pan,"upper":upper,"scene_id":sceneID.uuidString,"sequence":NSNumber(value:frame.sequence),
                        "captured_at_ms":frame.capturedAt,"detector_invoked":false,"free_space_inferred":false])
                } catch is CancellationError {throw CancellationError()}
                catch {
                    try await searchCheckpoint();try requireCoverageContext()
                    evidence.append(["depth_only_arm_coverage":true,"status":"unavailable","pan":pan,"upper":upper,
                        "detail":error.localizedDescription,"detector_invoked":false,"free_space_inferred":false])
                    if ProcessInfo.processInfo.systemUptime>=deadline {break}
                }
            }
            try await searchCheckpoint();try requireCoverageContext()
            evidence.append(["depth_only_arm_coverage_summary":true,"captured_views":capturedViews,"maximum_views":3,
                "elapsed_seconds":ProcessInfo.processInfo.systemUptime-started,"budget_seconds":20.0,
                "scene_id":sceneID.uuidString,"occupied_returns_preserved":true,"unknown_space_gate_unchanged":true])
        }
        if localReachSelectionRequired {found[.can]=localReachSelection?.object}
        let missing = targets.filter { found[$0] == nil }.map(\.spokenName)
        let unseen = targets.filter { !visuallyFound.contains($0) }.map(\.spokenName)
        let seen = targets.filter { visuallyFound.contains($0) }.map(\.spokenName)
        let noReachableCan=localReachSelectionRequired && localReachSelection?.object==nil
        let status = noReachableCan ? "no_reachable_can" : targets.isEmpty ? (leftHanging && rightHanging ? "observed_hanging" : "hanging_unconfirmed")
            : validObservations == 0 ? "vision_unavailable" : !requireDepth && unseen.isEmpty ? "visually_found"
                : missing.isEmpty ? "found" : unseen.isEmpty ? "depth_unconfirmed" : "not_found"
        let message = noReachableCan ? "I couldn't confirm a can with valid geometry and a reachable grasp for my \(model.physicalSide) arm. I haven't sent a reach." : targets.isEmpty ? (leftHanging && rightHanging ? "I can see both robot arms hanging." : "I couldn't confirm both arms hanging from these views.")
            : validObservations == 0 ? "My local search could not produce a usable camera observation. I cannot yet confirm the can or bucket. I haven't sent a reach."
                : missing.isEmpty || !requireDepth && unseen.isEmpty ? "I found the \(targets.map(\.spokenName).joined(separator: " and "))."
                : unseen.isEmpty ? "I can see the can and orange bucket, but I couldn't confirm their depth positions. I haven't sent a reach."
                    : (seen.isEmpty ? "" : "I can see the \(seen.joined(separator: " and ")). ") +
                        "I still couldn't confirm the \(unseen.joined(separator: " and "))."
        announce?(message); progress(message)
        if let collisionMap {
            let frozen = await Task.detached(priority:.userInitiated) { collisionMap.snapshot() }.value
            try await searchCheckpoint()
            try requireSceneProjectionIdentity()
            guard sceneCaptureAnchor.permitsCurrent(vision.cameraGeneration) else { throw ROBWorkspaceDepthMapError.invalidFrame }
            collisionSnapshotValue = frozen
        }
        try requireSceneProjectionIdentity()
        finished = true
        locatedObjects = found
        canCandidates = confirmedCanCandidates
        persist(status, message)
        return found
    }
}
