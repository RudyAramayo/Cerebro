import AppKit
import CoreImage
import Foundation
import Vision

/// Sampled, advisory perception for the delayed panoramic stream. Results are
/// scene context only and are never connected to Cerebro's control loop.
@objcMembers public final class ROBInsta360PerceptionService: NSObject {
    public static let shared = ROBInsta360PerceptionService()

    private let queue = DispatchQueue(label: "com.orbitusrobotics.cerebro.insta360-perception", qos: .utility)
    private var lastClassificationUptime: TimeInterval = 0
    private var classificationInFlight = false
    public private(set) var lastObservationDate: Date?
    public private(set) var lastLabels: [String] = []
    public private(set) var lastError: String?

    private override init() { super.init() }

    public func offer(_ image: NSImage, capturedAt: Date) {
        // MLX has its own enable switch, actor isolation, and >=5 second gate.
        // Offering a frame never blocks this caller or forces a model download.
        if let ciImage = Self.ciImage(from: image) {
            Task { await ROBMLXEngine.shared.offerVisionFrame(ciImage, minimumInterval: 8) }
        }

        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            guard !self.classificationInFlight, now - self.lastClassificationUptime >= 2 else { return }
            self.classificationInFlight = true
            self.lastClassificationUptime = now
            guard let cgImage = Self.cgImage(from: image) else {
                self.classificationInFlight = false
                return
            }
            let request = VNClassifyImageRequest()
            do {
                try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
                let classifications = (request.results ?? [])
                    .filter { $0.confidence >= 0.15 }
                    .prefix(8)
                let objects = classifications.enumerated().map { index, result in
                    ROBTrackedObject(
                        id: "insta360-classification-\(index)",
                        label: result.identifier,
                        // VNClassifyImageRequest is scene-level, not a detector;
                        // full-frame bounds avoid inventing a location.
                        bounds: ROBNormalizedRect(x: 0, y: 0, width: 1, height: 1),
                        distanceMeters: nil,
                        confidence: Double(result.confidence)
                    )
                }
                ROBSceneSnapshotStore.shared.updateObjects(objects)
                DispatchQueue.main.async {
                    self.lastLabels = objects.map(\.label)
                    self.lastObservationDate = capturedAt
                    self.lastError = nil
                    NotificationCenter.default.post(name: .robInsta360CameraServiceDidChange, object: ROBInsta360CameraService.shared)
                }
            } catch {
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
            }
            self.classificationInFlight = false
        }
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func ciImage(from image: NSImage) -> CIImage? {
        guard let cgImage = cgImage(from: image) else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
