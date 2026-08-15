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
    private var lastOfferUptime: TimeInterval = 0
    public private(set) var lastObservationDate: Date?
    public private(set) var lastLabels: [String] = []
    public private(set) var lastError: String?

    private override init() { super.init() }

    public func offer(_ image: NSImage, capturedAt: Date) {
        guard ROBMLXRuntime.shared.insta360DetectionEnabled else { return }
        let fps = ROBDynamicDetectorRegistry.shared.processingFramesPerSecond(for: .insta360)
        guard fps > 0 else { return }
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastOfferUptime >= 1 / fps else { return }
            self.lastOfferUptime = now
            guard let cgImage = Self.cgImage(from: image) else { return }
            // Conversion occurs only for an admitted frame and never on AppKit's
            // main thread. MLX retains its own actor/in-flight protection.
            Task { await ROBMLXEngine.shared.offerVisionFrame(
                CIImage(cgImage: cgImage), source: "insta360-preview", minimumInterval: 1 / fps) }

            guard ROBDynamicDetectorRegistry.shared.enabled("generic-objects", source: .insta360),
                  !self.classificationInFlight,
                  now - self.lastClassificationUptime >= 1 / fps else { return }
            self.classificationInFlight = true
            self.lastClassificationUptime = now
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
