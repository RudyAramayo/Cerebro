import AppKit
import AVFoundation
import CoreML
import Foundation
import Vision

extension Notification.Name {
    static let robDetectorOutputDidChange = Notification.Name("ROBDetectorOutputDidChange")
    static let robDetectorSettingsDidChange = Notification.Name("ROBDetectorSettingsDidChange")
}

public enum ROBDetectorSource: String, CaseIterable, Sendable { case mainCamera, insta360 }
public enum ROBInsta360AnalysisGeometry: Int, Sendable { case stitchedPanorama, sixSectors }
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
    private let admissionLock = NSLock()
    private var lastAdmission: [ROBDetectorSource: TimeInterval] = [:]
    private var customModels: [(name: String, model: VNCoreMLModel)] = []

    public func processingFramesPerSecond(for source: ROBDetectorSource) -> Double {
        let key = "ROBDetector.processingFPS.\(source.rawValue)"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return source == .mainCamera ? 2 : 1 }
        return max(0, min(30, defaults.double(forKey: key)))
    }

    public func setProcessingFramesPerSecond(_ fps: Double, for source: ROBDetectorSource) {
        UserDefaults.standard.set(max(0, min(30, fps)), forKey: "ROBDetector.processingFPS.\(source.rawValue)")
        NotificationCenter.default.post(name: .robDetectorSettingsDidChange, object: self,
            userInfo: ["source": source, "processingFPSChanged": true])
    }

    public var insta360AnalysisGeometry: ROBInsta360AnalysisGeometry {
        get { ROBInsta360AnalysisGeometry(rawValue: UserDefaults.standard.integer(forKey: "ROBDetector.insta360AnalysisGeometry")) ?? .stitchedPanorama }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "ROBDetector.insta360AnalysisGeometry")
            NotificationCenter.default.post(name: .robDetectorSettingsDidChange, object: self,
                userInfo: ["source": ROBDetectorSource.insta360, "geometryChanged": true])
        }
    }

    public func enabled(_ detector: String, source: ROBDetectorSource) -> Bool {
        let key = "ROBDetector.\(detector).\(source.rawValue)"
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    public func setEnabled(_ enabled: Bool, detector: String, source: ROBDetectorSource) {
        UserDefaults.standard.set(enabled, forKey: "ROBDetector.\(detector).\(source.rawValue)")
        NotificationCenter.default.post(name: .robDetectorSettingsDidChange, object: self,
            userInfo: ["detector": detector, "source": source, "enabled": enabled])
    }

    public func registerCoreMLModel(at url: URL) throws {
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let model = try MLModel(contentsOf: compiled)
        let visionModel = try VNCoreMLModel(for: model)
        queue.sync { customModels.append((url.deletingPathExtension().lastPathComponent, visionModel)) }
    }

    public func offer(_ image: NSImage, source: ROBDetectorSource, capturedAt: Date = Date()) {
        guard reserveFrame(for: source) else { return }
        queue.async {
            guard let cgImage = Self.cgImage(image) else { return }
            self.process(cgImage, source: source, capturedAt: capturedAt)
        }
    }

    public func offer(_ sampleBuffer: CMSampleBuffer, source: ROBDetectorSource, capturedAt: Date = Date()) {
        guard reserveFrame(for: source) else { return }
        queue.async {
            guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ci = CIImage(cvPixelBuffer: pixel)
            guard let cg = Self.imageContext.createCGImage(ci, from: ci.extent) else { return }
            self.process(cg, source: source, capturedAt: capturedAt)
        }
    }

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// Reserves only frames that can actually be analyzed. This intentionally
    /// runs before any NSImage/CIImage conversion on camera callback threads.
    private func reserveFrame(for source: ROBDetectorSource) -> Bool {
        let fps = processingFramesPerSecond(for: source)
        guard fps > 0 else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        admissionLock.lock(); defer { admissionLock.unlock() }
        guard now - (lastAdmission[source] ?? 0) >= 1 / fps else { return false }
        lastAdmission[source] = now
        return true
    }

    private func process(_ image: CGImage, source: ROBDetectorSource, capturedAt: Date) {
            let geometry = source == .insta360 ? self.insta360AnalysisGeometry : .stitchedPanorama
            // Main-camera pose has a low-latency dedicated Vision path. Running
            // it again here halves throughput and adds no additional result.
            let poseOn = source != .mainCamera && self.enabled("body-pose", source: source)
            let objectsOn = self.enabled("generic-objects", source: source)
            let models = self.customModels
            guard poseOn || objectsOn || !models.isEmpty else { return }
            var points: [ROBOverlayPoint] = []
            var lines: [ROBOverlayLine] = []
            let inputs: [(image: CGImage, xOffset: Double, xScale: Double)]
            if geometry == .sixSectors {
                let width = image.width / 6
                inputs = (0..<6).compactMap { index in
                    let x = index * width
                    let cropWidth = index == 5 ? image.width - x : width
                    return image.cropping(to: CGRect(x: x, y: 0, width: cropWidth, height: image.height)).map {
                        ($0, Double(x) / Double(image.width), Double(cropWidth) / Double(image.width))
                    }
                }
            } else {
                inputs = [(image, 0, 1)]
            }

            do {
              for input in inputs {
                var requests: [VNRequest] = []
                let mapPoint: (CGPoint) -> CGPoint = { point in
                    CGPoint(x: input.xOffset + Double(point.x) * input.xScale, y: point.y)
                }

                if poseOn {
                requests.append(VNDetectHumanBodyPoseRequest { request, _ in
                    for observation in (request.results as? [VNHumanBodyPoseObservation]) ?? [] {
                        guard let recognized = try? observation.recognizedPoints(.all) else { continue }
                        for (name, point) in recognized where point.confidence >= 0.2 {
                            let mapped = mapPoint(point.location)
                            points.append(ROBOverlayPoint(x: mapped.x, y: mapped.y,
                                label: name.rawValue.rawValue, confidence: Double(point.confidence)))
                        }
                        for (a, b) in BodyJoints.links {
                            if let p1 = recognized[a], let p2 = recognized[b], p1.confidence >= 0.2, p2.confidence >= 0.2 {
                                let m1 = mapPoint(p1.location), m2 = mapPoint(p2.location)
                                lines.append(ROBOverlayLine(x1: m1.x, y1: m1.y, x2: m2.x, y2: m2.y))
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
                        let mapped = mapPoint(CGPoint(x: object.boundingBox.midX, y: object.boundingBox.midY))
                        points.append(ROBOverlayPoint(x: mapped.x, y: mapped.y,
                            label: label.identifier, confidence: Double(label.confidence)))
                    }
                })
            }
                try VNImageRequestHandler(cgImage: input.image).perform(requests)
                if objectsOn,
                   let classify = requests.compactMap({ $0 as? VNClassifyImageRequest }).first,
                   let saliency = requests.compactMap({ $0 as? VNGenerateObjectnessBasedSaliencyImageRequest }).first {
                    let labels = (classify.results ?? []).filter { $0.confidence >= 0.15 }.prefix(6)
                    let regions = saliency.results?.first?.salientObjects ?? []
                    for (index, label) in labels.enumerated() {
                        let center = index < regions.count
                            ? CGPoint(x: regions[index].boundingBox.midX, y: regions[index].boundingBox.midY)
                            : CGPoint(x: 0.08 + Double(index) * 0.14, y: 0.94)
                        let mapped = mapPoint(center)
                        points.append(ROBOverlayPoint(x: mapped.x, y: mapped.y,
                            label: "candidate: \(label.identifier)", confidence: Double(label.confidence)))
                    }
                }
              }
                let output = ROBDetectorOutput(source: source, capturedAt: capturedAt, points: points, lines: lines)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .robDetectorOutputDidChange, object: self,
                        userInfo: ["output": output])
                }
            } catch { NSLog("Dynamic detector request failed: %@", String(describing: error)) }
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
