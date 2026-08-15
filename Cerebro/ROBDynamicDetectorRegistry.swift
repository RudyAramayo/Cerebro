import AppKit
import AVFoundation
import CoreML
import Foundation
import Vision

extension Notification.Name {
    static let robDetectorOutputDidChange = Notification.Name("ROBDetectorOutputDidChange")
}

public enum ROBDetectorSource: String, CaseIterable, Sendable { case mainCamera, insta360 }
public struct ROBOverlayPoint: Sendable { public let x, y: Double; public let label: String; public let confidence: Double }
public struct ROBOverlayLine: Sendable { public let x1, y1, x2, y2: Double }
public struct ROBDetectorOutput: Sendable {
    public let source: ROBDetectorSource
    public let capturedAt: Date
    public let points: [ROBOverlayPoint]
    public let lines: [ROBOverlayLine]
}

/// Runtime-selectable detector registry. Disabled detectors produce no request,
/// notification, or callback. Custom Core ML object detectors can be added
/// without changing the capture services.
@objcMembers public final class ROBDynamicDetectorRegistry: NSObject {
    public static let shared = ROBDynamicDetectorRegistry()
    private let queue = DispatchQueue(label: "com.orbitusrobotics.cerebro.detectors", qos: .utility)
    private var lastRun: [ROBDetectorSource: TimeInterval] = [:]
    private var customModels: [(name: String, model: VNCoreMLModel)] = []

    public func enabled(_ detector: String, source: ROBDetectorSource) -> Bool {
        let key = "ROBDetector.\(detector).\(source.rawValue)"
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    public func setEnabled(_ enabled: Bool, detector: String, source: ROBDetectorSource) {
        UserDefaults.standard.set(enabled, forKey: "ROBDetector.\(detector).\(source.rawValue)")
    }

    public func registerCoreMLModel(at url: URL) throws {
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let model = try MLModel(contentsOf: compiled)
        let visionModel = try VNCoreMLModel(for: model)
        queue.sync { customModels.append((url.deletingPathExtension().lastPathComponent, visionModel)) }
    }

    public func offer(_ image: NSImage, source: ROBDetectorSource, capturedAt: Date = Date()) {
        guard let cgImage = Self.cgImage(image) else { return }
        offer(cgImage, source: source, capturedAt: capturedAt)
    }

    public func offer(_ sampleBuffer: CMSampleBuffer, source: ROBDetectorSource, capturedAt: Date = Date()) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let context = CIContext()
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return }
        offer(cg, source: source, capturedAt: capturedAt)
    }

    private func offer(_ image: CGImage, source: ROBDetectorSource, capturedAt: Date) {
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - (self.lastRun[source] ?? 0) >= 0.5 else { return }
            self.lastRun[source] = now
            let poseOn = self.enabled("body-pose", source: source)
            let objectsOn = self.enabled("generic-objects", source: source)
            let models = self.customModels
            guard poseOn || objectsOn || !models.isEmpty else { return }
            var points: [ROBOverlayPoint] = []
            var lines: [ROBOverlayLine] = []
            var requests: [VNRequest] = []

            if poseOn {
                requests.append(VNDetectHumanBodyPoseRequest { request, _ in
                    for observation in (request.results as? [VNHumanBodyPoseObservation]) ?? [] {
                        guard let recognized = try? observation.recognizedPoints(.all) else { continue }
                        for (name, point) in recognized where point.confidence >= 0.2 {
                            points.append(ROBOverlayPoint(x: point.location.x, y: point.location.y,
                                label: name.rawValue.rawValue, confidence: Double(point.confidence)))
                        }
                        for (a, b) in BodyJoints.links {
                            if let p1 = recognized[a], let p2 = recognized[b], p1.confidence >= 0.2, p2.confidence >= 0.2 {
                                lines.append(ROBOverlayLine(x1: p1.location.x, y1: p1.location.y, x2: p2.location.x, y2: p2.location.y))
                            }
                        }
                    }
                })
            }
            if objectsOn {
                let classify = VNClassifyImageRequest()
                let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
                requests += [classify, saliency]
                // Results are joined after the handler completes below.
            }
            for entry in models {
                requests.append(VNCoreMLRequest(model: entry.model) { request, _ in
                    for object in (request.results as? [VNRecognizedObjectObservation]) ?? [] {
                        guard let label = object.labels.first else { continue }
                        points.append(ROBOverlayPoint(x: object.boundingBox.midX, y: object.boundingBox.midY,
                            label: label.identifier, confidence: Double(label.confidence)))
                    }
                })
            }
            do {
                try VNImageRequestHandler(cgImage: image).perform(requests)
                if objectsOn,
                   let classify = requests.compactMap({ $0 as? VNClassifyImageRequest }).first,
                   let saliency = requests.compactMap({ $0 as? VNGenerateObjectnessBasedSaliencyImageRequest }).first {
                    let labels = (classify.results ?? []).filter { $0.confidence >= 0.15 }.prefix(6)
                    let regions = saliency.results?.first?.salientObjects ?? []
                    for (index, label) in labels.enumerated() {
                        let center = index < regions.count
                            ? CGPoint(x: regions[index].boundingBox.midX, y: regions[index].boundingBox.midY)
                            : CGPoint(x: 0.08 + Double(index) * 0.14, y: 0.94)
                        points.append(ROBOverlayPoint(x: center.x, y: center.y,
                            label: "candidate: \(label.identifier)", confidence: Double(label.confidence)))
                    }
                }
                let output = ROBDetectorOutput(source: source, capturedAt: capturedAt, points: points, lines: lines)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .robDetectorOutputDidChange, object: self,
                        userInfo: ["output": output])
                }
            } catch { NSLog("Dynamic detector request failed: %@", String(describing: error)) }
        }
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

final class ROBDetectionOverlayView: NSView {
    var output: ROBDetectorOutput? { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let output, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setStrokeColor(NSColor.systemGreen.cgColor); context.setLineWidth(2)
        for line in output.lines {
            context.move(to: CGPoint(x: line.x1 * bounds.width, y: line.y1 * bounds.height))
            context.addLine(to: CGPoint(x: line.x2 * bounds.width, y: line.y2 * bounds.height)); context.strokePath()
        }
        for point in output.points {
            let p = CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            let text = "\(point.label) \(Int(point.confidence * 100))%" as NSString
            text.draw(at: CGPoint(x: p.x + 6, y: p.y + 5), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.65)
            ])
        }
    }
}
