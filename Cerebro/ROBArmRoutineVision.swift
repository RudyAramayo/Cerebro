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
    private var epoch = UUID()
    private var busy: Set<String> = []
    private var lastOffer: [String: TimeInterval] = [:]
    private var inputNotes: [String: String] = [:]
    private var frames: [String: Frame] = [:]

    struct Frame {
        let image: CIImage
        let capturedAt: Double
        let sequence: UInt64
        let handsClear: Bool
        let depthCoverage: Double
        let thumbnail: [UInt8]
    }

    func setActive(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        active = value; epoch = UUID(); frames = [:]; busy = []; lastOffer = [:]; inputNotes = [:]
    }

    func offer(_ frame: CameraFrameSet, role: CameraRole) {
        let key = role.rawValue, now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard active, !busy.contains(key), now - (lastOffer[key] ?? 0) >= 0.2 else { lock.unlock(); return }
        lastOffer[key] = now
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
        busy.insert(key); lastOffer[key] = now
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let image = CIImage(cvPixelBuffer: pixels)
            let hands = VNDetectHumanHandPoseRequest()
            hands.maximumHandCount = 6
            let people = VNDetectHumanRectanglesRequest()
            people.upperBodyOnly = true
            var clear = false
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixels).perform([hands, people])
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
                                     depthCoverage: Double(valid) / Double(max(1, total)), thumbnail: thumbnail)
        }
    }

    func snapshot() -> [String: Frame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    var fresh: Bool {
        let frames = snapshot(), now = Date().timeIntervalSince1970 * 1000
        return ["face", "belly"].allSatisfy { key in
            guard let f = frames[key] else { return false }
            return (0 ... 700).contains(now - f.capturedAt) && f.depthCoverage >= 0.25
        }
    }

    var handsClear: Bool {
        fresh && snapshot().values.allSatisfy(\.handsClear)
    }

    var readinessDescription: String {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970 * 1000
        return ["face", "belly"].map { key in
            let name = key == "face" ? "Forward camera" : "Belly camera"
            guard let frame = frames[key] else { return "\(name): \(inputNotes[key] ?? "no frames received")" }
            return "\(name): \(Int(now - frame.capturedAt)) ms old, \(Int(frame.depthCoverage * 100))% usable depth"
        }.joined(separator: "; ")
    }

    func observe(target: String) async throws -> ROBArmRoutineObservation {
        // Warm/load before selecting pixels; model initialization must not age
        // the actual inspection frame. The coordinator's deadline still runs.
        try await ROBMLXEngine.shared.ensureVLMReady()
        try Task.checkCancellation()
        guard fresh else { throw ROBArmRoutineError.blocked("Both forward and belly RGB-D cameras must be current.") }
        let frames = snapshot()
        guard let face = frames["face"], let belly = frames["belly"] else {
            throw ROBArmRoutineError.blocked("Camera frames are unavailable.")
        }
        let top = face.image.transformed(by: CGAffineTransform(translationX: 0, y: belly.image.extent.height))
        let composite = top.composited(over: belly.image)
        guard let cg = context.createCGImage(composite, from: composite.extent),
              let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ROBArmRoutineError.blocked("Could not inspect the camera frames.")
        }
        let raw = try await ROBMLXEngine.shared.observeArmWorkspace(jpeg: jpeg, target: String(target.prefix(160)))
        try Task.checkCancellation()
        // A result is not a new frame. Long inference cannot refresh old pixels.
        guard fresh, Date().timeIntervalSince1970 * 1000 - min(face.capturedAt, belly.capturedAt) <= 8_000 else {
            throw ROBArmRoutineError.blocked("Camera inspection timed out; no motion was authorized.")
        }
        let current = snapshot()
        guard current["face"].map({ $0.sequence > face.sequence }) == true,
              current["belly"].map({ $0.sequence > belly.sequence }) == true else {
            throw ROBArmRoutineError.blocked("The camera stream stopped advancing during inspection.")
        }
        // A moving object or changed viewpoint invalidates a delayed semantic
        // observation. This is a veto, never geometric clearance certification.
        for key in ["face", "belly"] {
            guard let before = frames[key]?.thumbnail, let after = current[key]?.thumbnail,
                  before.count == after.count, !before.isEmpty else {
                throw ROBArmRoutineError.blocked("The inspected camera view changed.")
            }
            let changed = zip(before, after).filter { abs(Int($0) - Int($1)) > 24 }.count
            guard Double(changed) / Double(before.count) < 0.025 else {
                throw ROBArmRoutineError.blocked("The scene changed during camera inspection; no new motion was sent.")
            }
        }
        let data = Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard data.count < 4000, let observation = try? JSONDecoder().decode(ROBArmRoutineObservation.self, from: data) else {
            throw ROBArmRoutineError.blocked("Camera inspection was ambiguous; the arms remain held.")
        }
        return observation
    }
}
