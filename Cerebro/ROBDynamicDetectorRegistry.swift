import AppKit
import AVFoundation
import CoreML
import Foundation
import Vision

public extension Notification.Name {
    static let robInsta360HumanPoseDidUpdate = Notification.Name(
        "ROBInsta360HumanPoseDidUpdate"
    )
    static let robHandWaveDidDetect = Notification.Name(
        "ROBHandWaveDidDetect"
    )
}

extension Notification.Name {
    static let robDetectorOutputDidChange = Notification.Name("ROBDetectorOutputDidChange")
    static let robDetectorSettingsDidChange = Notification.Name("ROBDetectorSettingsDidChange")
}

public enum ROBDetectorSource: String, CaseIterable, Sendable { case mainCamera, insta360 }
public enum ROBInsta360AnalysisGeometry: Int, Sendable { case stitchedPanorama, sixSectors }

/// Optical alignment between the stitched panorama and the forward main
/// camera. The Insta360 is face-relative, but its stitched midpoint sits a few
/// degrees left of the main camera's optical axis on this mounting.
@objcMembers public final class ROBInsta360TrackingCalibration: NSObject {
    public static let forwardCenterX = 0.52

    private override init() {}
}

public struct ROBOverlayPoint: Sendable { public let x, y: Double; public let label: String; public let confidence: Double }
public struct ROBOverlayLine: Sendable { public let x1, y1, x2, y2: Double }
public struct ROBDetectorOutput: Sendable {
    public let source: ROBDetectorSource
    public let capturedAt: Date
    public let points: [ROBOverlayPoint]
    public let lines: [ROBOverlayLine]
}

@objcMembers public final class ROBHandWaveObservation: NSObject {
    public let source: String
    public let targetX: Double
    public let targetY: Double
    public let confidence: Double
    public let capturedAtUptime: TimeInterval

    public init(
        source: String,
        targetX: Double,
        targetY: Double,
        confidence: Double,
        capturedAtUptime: TimeInterval
    ) {
        self.source = source
        self.targetX = targetX
        self.targetY = targetY
        self.confidence = confidence
        self.capturedAtUptime = capturedAtUptime
    }
}

private struct ROBHandWaveCandidate {
    let hand: String
    let targetX: Double
    let targetY: Double
    let relativeWristX: Double
    let confidence: Double
}

private struct ROBHandWaveTrack {
    let id: UUID
    let source: ROBDetectorSource
    let hand: String
    var targetX: Double
    var lastRelativeWristX: Double
    var lastDirection: Int
    var reversals: Int
    var travel: Double
    var motionStartedAtUptime: TimeInterval
    var lastSeenUptime: TimeInterval
    var cooldownUntilUptime: TimeInterval
    var focusUntilUptime: TimeInterval
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
    private var resultGeneration: [ROBDetectorSource: UInt64] = [:]
    private let modelLock = NSLock()
    private var customModels: [(name: String, model: VNCoreMLModel)] = []
    private var handWaveTracks: [ROBHandWaveTrack] = []

    private static let focusOnHandWaveDefaultsKey =
        "ROBDetector.focusOnHandWaveWhenConversationIdle"

    public func processingFramesPerSecond(for source: ROBDetectorSource) -> Double {
        let key = "ROBDetector.processingFPS.\(source.rawValue)"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return source == .mainCamera ? 2 : 1 }
        return max(0, min(30, defaults.double(forKey: key)))
    }

    public func setProcessingFramesPerSecond(_ fps: Double, for source: ROBDetectorSource) {
        let boundedFPS = max(0, min(30, fps))
        UserDefaults.standard.set(boundedFPS, forKey: "ROBDetector.processingFPS.\(source.rawValue)")
        if source == .insta360, boundedFPS == 0 {
            invalidatePendingResults(for: source)
        }
        NotificationCenter.default.post(name: .robDetectorSettingsDidChange, object: self,
            userInfo: ["source": source, "processingFPSChanged": true])
    }

    public var insta360AnalysisGeometry: ROBInsta360AnalysisGeometry {
        get {
            let key = "ROBDetector.insta360AnalysisGeometry"
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: key) != nil else { return .sixSectors }
            return ROBInsta360AnalysisGeometry(rawValue: defaults.integer(forKey: key)) ?? .sixSectors
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "ROBDetector.insta360AnalysisGeometry")
            invalidatePendingResults(for: .insta360)
            NotificationCenter.default.post(name: .robDetectorSettingsDidChange, object: self,
                userInfo: ["source": ROBDetectorSource.insta360, "geometryChanged": true])
        }
    }

    public func enabled(_ detector: String, source: ROBDetectorSource) -> Bool {
        let key = "ROBDetector.\(detector).\(source.rawValue)"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            return detector != "hand-wave"
        }
        return defaults.bool(forKey: key)
    }

    public var focusOnHandWaveWhenConversationIdle: Bool {
        get { UserDefaults.standard.bool(forKey: Self.focusOnHandWaveDefaultsKey) }
        set {
            guard newValue != focusOnHandWaveWhenConversationIdle else { return }
            UserDefaults.standard.set(newValue, forKey: Self.focusOnHandWaveDefaultsKey)
            NotificationCenter.default.post(
                name: .robDetectorSettingsDidChange,
                object: self,
                userInfo: ["focusOnHandWaveChanged": true]
            )
        }
    }

    public func setEnabled(_ enabled: Bool, detector: String, source: ROBDetectorSource) {
        UserDefaults.standard.set(enabled, forKey: "ROBDetector.\(detector).\(source.rawValue)")
        if detector == "hand-wave" {
            invalidatePendingResults(for: source)
            queue.async {
                self.handWaveTracks.removeAll { $0.source == source }
            }
        } else if source == .insta360, detector == "body-pose", !enabled {
            invalidatePendingResults(for: source)
        }
        NotificationCenter.default.post(name: .robDetectorSettingsDidChange, object: self,
            userInfo: ["detector": detector, "source": source, "enabled": enabled])
    }

    public func registerCoreMLModel(at url: URL) throws {
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let model = try MLModel(contentsOf: compiled)
        let visionModel = try VNCoreMLModel(for: model)
        modelLock.lock()
        customModels.append((url.deletingPathExtension().lastPathComponent, visionModel))
        modelLock.unlock()
        NotificationCenter.default.post(name: .robDetectorSettingsDidChange, object: self,
            userInfo: ["customModelsChanged": true])
    }

    /// Whether this registry has a live consumer for frames from `source`.
    /// Keeping this policy here prevents capture services and settings UIs
    /// from drifting apart when detector types are added.
    public func requiresFrames(for source: ROBDetectorSource) -> Bool {
        guard processingFramesPerSecond(for: source) > 0 else { return false }
        let usesBuiltInPose = source == .insta360 && enabled("body-pose", source: source)
        let usesHandWave = enabled("hand-wave", source: source)
        let usesGenericObjects = enabled("generic-objects", source: source)
        modelLock.lock()
        let usesCustomModels = !customModels.isEmpty
        modelLock.unlock()
        return usesBuiltInPose || usesHandWave || usesGenericObjects || usesCustomModels
    }

    /// Drops source-owned people immediately and prevents any Vision request
    /// already in flight from restoring observations after its producer has
    /// stopped or its geometry/detector settings have changed.
    public func invalidatePendingResults(for source: ROBDetectorSource) {
        admissionLock.lock()
        resultGeneration[source, default: 0] &+= 1
        lastAdmission[source] = nil
        if source == .insta360 {
            ROBSceneSnapshotStore.shared.clearPeople(source: source.rawValue)
        }
        admissionLock.unlock()
    }

    public func offer(_ image: NSImage, source: ROBDetectorSource, capturedAt: Date = Date()) {
        guard let generation = reserveFrame(for: source) else { return }
        queue.async {
            guard let cgImage = Self.cgImage(image) else { return }
            self.process(cgImage, source: source, capturedAt: capturedAt, generation: generation)
        }
    }

    public func offer(_ sampleBuffer: CMSampleBuffer, source: ROBDetectorSource, capturedAt: Date = Date()) {
        guard let generation = reserveFrame(for: source) else { return }
        queue.async {
            guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ci = CIImage(cvPixelBuffer: pixel)
            guard let cg = Self.imageContext.createCGImage(ci, from: ci.extent) else { return }
            self.process(cg, source: source, capturedAt: capturedAt, generation: generation)
        }
    }

    /// Reuses the main camera's dedicated low-latency pose request so enabling
    /// wave detection does not run a second body-pose model on the same frame.
    public func offerMainCameraBodyPoses(
        _ observations: [VNHumanBodyPoseObservation]
    ) {
        guard enabled("hand-wave", source: .mainCamera),
              processingFramesPerSecond(for: .mainCamera) > 0 else { return }
        let candidates = observations.compactMap { observation -> [ROBHandWaveCandidate]? in
            guard let tracking = ROBPersonTrackingObservation.make(
                from: observation,
                source: ROBDetectorSource.mainCamera.rawValue
            ), let recognized = try? observation.recognizedPoints(.all) else {
                return nil
            }
            return Self.handWaveCandidates(
                tracking: tracking,
                recognized: recognized,
                xOffset: 0,
                xScale: 1
            )
        }.flatMap { $0 }
        admissionLock.lock()
        let generation = resultGeneration[.mainCamera, default: 0]
        admissionLock.unlock()
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            let waves = self.updateHandWaveTracks(
                with: candidates,
                source: .mainCamera,
                atUptime: now
            )
            guard !waves.isEmpty else { return }
            DispatchQueue.main.async {
                guard self.resultIsCurrent(generation, for: .mainCamera),
                      self.enabled("hand-wave", source: .mainCamera) else { return }
                for wave in waves {
                    NotificationCenter.default.post(
                        name: .robHandWaveDidDetect,
                        object: self,
                        userInfo: ["observation": wave]
                    )
                }
            }
        }
    }

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// Reserves only frames that can actually be analyzed. This intentionally
    /// runs before any NSImage/CIImage conversion on camera callback threads.
    private func reserveFrame(for source: ROBDetectorSource) -> UInt64? {
        guard requiresFrames(for: source) else { return nil }
        let fps = processingFramesPerSecond(for: source)
        let now = ProcessInfo.processInfo.systemUptime
        admissionLock.lock(); defer { admissionLock.unlock() }
        guard now - (lastAdmission[source] ?? 0) >= 1 / fps else { return nil }
        lastAdmission[source] = now
        return resultGeneration[source, default: 0]
    }

    private func resultIsCurrent(_ generation: UInt64, for source: ROBDetectorSource) -> Bool {
        admissionLock.lock(); defer { admissionLock.unlock() }
        return generation == resultGeneration[source, default: 0]
    }

    private func publishInsta360PeopleIfCurrent(
        _ people: [ROBTrackedPerson],
        generation: UInt64
    ) {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard generation == resultGeneration[.insta360, default: 0],
              enabled("body-pose", source: .insta360) else {
            return
        }
        let fps = processingFramesPerSecond(for: .insta360)
        guard fps > 0 else { return }
        ROBSceneSnapshotStore.shared.updatePeople(
            people,
            source: ROBDetectorSource.insta360.rawValue,
            maximumAge: max(3, min(10, 3 / max(fps, 0.01)))
        )
    }

    private func process(
        _ image: CGImage,
        source: ROBDetectorSource,
        capturedAt: Date,
        generation: UInt64
    ) {
        let geometry = source == .insta360 ? insta360AnalysisGeometry : .stitchedPanorama
        // Main-camera pose has a low-latency dedicated Vision path. Running it
        // again here halves throughput and adds no additional result.
        let bodyPoseOn = source == .insta360 && enabled("body-pose", source: source)
        let handWaveOn = source == .insta360 && enabled("hand-wave", source: source)
        let poseRequestOn = bodyPoseOn || handWaveOn
        let objectsOn = enabled("generic-objects", source: source)
        modelLock.lock()
        let models = customModels
        modelLock.unlock()
        guard poseRequestOn || objectsOn || !models.isEmpty else { return }

        var points: [ROBOverlayPoint] = []
        var lines: [ROBOverlayLine] = []
        var detectedPeople: [(bounds: ROBNormalizedRect, confidence: Double)] = []
        var detectedPoses: [ROBPersonTrackingObservation] = []
        var handWaveCandidates: [ROBHandWaveCandidate] = []
        let inputs: [(image: CGImage, xOffset: Double, xScale: Double)]
        if geometry == .sixSectors {
            let width = image.width / 6
            inputs = (0..<6).compactMap { index in
                let x = index * width
                let cropWidth = index == 5 ? image.width - x : width
                return image.cropping(
                    to: CGRect(x: x, y: 0, width: cropWidth, height: image.height)
                ).map {
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

                if poseRequestOn {
                    let humanRectangles = VNDetectHumanRectanglesRequest { request, _ in
                        for observation in (request.results as? [VNHumanObservation]) ?? [] {
                            let bounds = observation.boundingBox
                            detectedPeople.append((
                                bounds: ROBNormalizedRect(
                                    x: input.xOffset + Double(bounds.origin.x) * input.xScale,
                                    y: Double(bounds.origin.y),
                                    width: Double(bounds.width) * input.xScale,
                                    height: Double(bounds.height)
                                ),
                                confidence: Double(observation.confidence)
                            ))
                        }
                    }
                    humanRectangles.revision = VNDetectHumanRectanglesRequestRevision2
                    humanRectangles.upperBodyOnly = false
                    requests.append(humanRectangles)

                    requests.append(VNDetectHumanBodyPoseRequest { request, _ in
                        for observation in (request.results as? [VNHumanBodyPoseObservation]) ?? [] {
                            let tracking = ROBPersonTrackingObservation.make(
                                from: observation,
                                source: source.rawValue,
                                xOffset: input.xOffset,
                                xScale: input.xScale
                            )
                            if bodyPoseOn, let tracking {
                                detectedPoses.append(tracking)
                            }
                            guard let recognized = try? observation.recognizedPoints(.all) else { continue }
                            if handWaveOn, let tracking {
                                handWaveCandidates.append(contentsOf: Self.handWaveCandidates(
                                    tracking: tracking,
                                    recognized: recognized,
                                    xOffset: input.xOffset,
                                    xScale: input.xScale
                                ))
                            }
                            for (name, point) in recognized where point.confidence >= 0.2 {
                                let mapped = mapPoint(point.location)
                                points.append(ROBOverlayPoint(
                                    x: mapped.x,
                                    y: mapped.y,
                                    label: name.rawValue.rawValue,
                                    confidence: Double(point.confidence)
                                ))
                            }
                            for (a, b) in BodyJoints.links {
                                if let p1 = recognized[a], let p2 = recognized[b],
                                   p1.confidence >= 0.2, p2.confidence >= 0.2 {
                                    let m1 = mapPoint(p1.location)
                                    let m2 = mapPoint(p2.location)
                                    lines.append(ROBOverlayLine(
                                        x1: m1.x, y1: m1.y, x2: m2.x, y2: m2.y
                                    ))
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
                            let mapped = mapPoint(CGPoint(
                                x: object.boundingBox.midX,
                                y: object.boundingBox.midY
                            ))
                            points.append(ROBOverlayPoint(
                                x: mapped.x,
                                y: mapped.y,
                                label: label.identifier,
                                confidence: Double(label.confidence)
                            ))
                        }
                    })
                }

                try VNImageRequestHandler(cgImage: input.image).perform(requests)
                if objectsOn,
                   let classify = requests.compactMap({ $0 as? VNClassifyImageRequest }).first,
                   let saliency = requests.compactMap({
                       $0 as? VNGenerateObjectnessBasedSaliencyImageRequest
                   }).first {
                    let labels = (classify.results ?? []).filter { $0.confidence >= 0.15 }.prefix(6)
                    let regions = saliency.results?.first?.salientObjects ?? []
                    for (index, label) in labels.enumerated() {
                        let center = index < regions.count
                            ? CGPoint(
                                x: regions[index].boundingBox.midX,
                                y: regions[index].boundingBox.midY
                            )
                            : CGPoint(x: 0.08 + Double(index) * 0.14, y: 0.94)
                        let mapped = mapPoint(center)
                        points.append(ROBOverlayPoint(
                            x: mapped.x,
                            y: mapped.y,
                            label: "candidate: \(label.identifier)",
                            confidence: Double(label.confidence)
                        ))
                    }
                }
            }

            if handWaveOn {
                let now = ProcessInfo.processInfo.systemUptime
                let waves = updateHandWaveTracks(
                    with: handWaveCandidates,
                    source: source,
                    atUptime: now
                )
                for wave in waves {
                    points.append(ROBOverlayPoint(
                        x: wave.targetX,
                        y: wave.targetY,
                        label: "hand wave",
                        confidence: wave.confidence
                    ))
                }
                if !waves.isEmpty {
                    DispatchQueue.main.async {
                        guard self.resultIsCurrent(generation, for: source),
                              self.enabled("hand-wave", source: source) else { return }
                        for wave in waves {
                            NotificationCenter.default.post(
                                name: .robHandWaveDidDetect,
                                object: self,
                                userInfo: ["observation": wave]
                            )
                        }
                    }
                }
            }

            if source == .insta360, bodyPoseOn {
                detectedPeople.sort {
                    $0.bounds.x == $1.bounds.x
                        ? $0.bounds.y < $1.bounds.y
                        : $0.bounds.x < $1.bounds.x
                }
                let people = detectedPeople.enumerated().map { index, observation in
                    ROBTrackedPerson(
                        id: "person-\(index)",
                        bounds: observation.bounds,
                        distanceMeters: nil,
                        confidence: observation.confidence
                    )
                }
                publishInsta360PeopleIfCurrent(people, generation: generation)
                let currentPoses = detectedPoses
                DispatchQueue.main.async {
                    guard self.resultIsCurrent(generation, for: source) else { return }
                    NotificationCenter.default.post(
                        name: .robInsta360HumanPoseDidUpdate,
                        object: self,
                        userInfo: ["observations": currentPoses]
                    )
                }
            }

            let output = ROBDetectorOutput(
                source: source,
                capturedAt: capturedAt,
                points: points,
                lines: lines
            )
            DispatchQueue.main.async {
                guard self.resultIsCurrent(generation, for: source) else { return }
                NotificationCenter.default.post(
                    name: .robDetectorOutputDidChange,
                    object: self,
                    userInfo: ["output": output]
                )
            }
        } catch {
            NSLog("Dynamic detector request failed: %@", String(describing: error))
        }
    }

    private static func handWaveCandidates(
        tracking: ROBPersonTrackingObservation,
        recognized: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        xOffset: Double,
        xScale: Double
    ) -> [ROBHandWaveCandidate] {
        let joints: [(String, VNHumanBodyPoseObservation.JointName,
                      VNHumanBodyPoseObservation.JointName,
                      VNHumanBodyPoseObservation.JointName)] = [
            ("left", .leftWrist, .leftElbow, .leftShoulder),
            ("right", .rightWrist, .rightElbow, .rightShoulder),
        ]
        let mapPoint: (CGPoint) -> CGPoint = { point in
            CGPoint(x: xOffset + Double(point.x) * xScale, y: point.y)
        }
        let shoulderWidth: Double = {
            guard let left = recognized[.leftShoulder], left.confidence >= 0.25,
                  let right = recognized[.rightShoulder], right.confidence >= 0.25 else {
                return max(0.01, tracking.boundsWidth * 0.4)
            }
            return max(0.01, abs(mapPoint(left.location).x - mapPoint(right.location).x))
        }()
        return joints.compactMap { hand, wristName, elbowName, shoulderName in
            guard let wristPoint = recognized[wristName], wristPoint.confidence >= 0.25,
                  let elbowPoint = recognized[elbowName], elbowPoint.confidence >= 0.25,
                  let shoulderPoint = recognized[shoulderName], shoulderPoint.confidence >= 0.25 else {
                return nil
            }
            let wrist = mapPoint(wristPoint.location)
            let elbow = mapPoint(elbowPoint.location)
            let shoulder = mapPoint(shoulderPoint.location)
            guard wrist.y >= elbow.y - 0.02,
                  wrist.y >= shoulder.y + 0.01 else {
                return nil
            }
            return ROBHandWaveCandidate(
                hand: hand,
                targetX: tracking.headX,
                targetY: tracking.headY,
                relativeWristX: (wrist.x - tracking.headX) / shoulderWidth,
                confidence: Double(min(
                    wristPoint.confidence,
                    min(elbowPoint.confidence, shoulderPoint.confidence)
                ))
            )
        }
    }

    private func updateHandWaveTracks(
        with candidates: [ROBHandWaveCandidate],
        source: ROBDetectorSource,
        atUptime now: TimeInterval
    ) -> [ROBHandWaveObservation] {
        let motionWindow = 3.5
        let sampleGapReset = 1.6
        let minimumStep = 0.08
        let minimumTravel = 0.45
        handWaveTracks.removeAll {
            $0.source == source && now - $0.lastSeenUptime > motionWindow
        }

        var usedTrackIDs = Set<UUID>()
        var detected: [ROBHandWaveObservation] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let match = handWaveTracks.indices
                .filter { index in
                    let track = handWaveTracks[index]
                    return track.source == source
                        && track.hand == candidate.hand
                        && !usedTrackIDs.contains(track.id)
                        && abs(track.targetX - candidate.targetX) <= 0.16
                }
                .min { left, right in
                    abs(handWaveTracks[left].targetX - candidate.targetX)
                        < abs(handWaveTracks[right].targetX - candidate.targetX)
                }

            guard let index = match else {
                let track = ROBHandWaveTrack(
                    id: UUID(),
                    source: source,
                    hand: candidate.hand,
                    targetX: candidate.targetX,
                    lastRelativeWristX: candidate.relativeWristX,
                    lastDirection: 0,
                    reversals: 0,
                    travel: 0,
                    motionStartedAtUptime: now,
                    lastSeenUptime: now,
                    cooldownUntilUptime: 0,
                    focusUntilUptime: 0
                )
                handWaveTracks.append(track)
                usedTrackIDs.insert(track.id)
                continue
            }

            var track = handWaveTracks[index]
            usedTrackIDs.insert(track.id)
            if now - track.lastSeenUptime > sampleGapReset
                || now - track.motionStartedAtUptime > motionWindow {
                track.lastDirection = 0
                track.reversals = 0
                track.travel = 0
                track.motionStartedAtUptime = now
                track.lastRelativeWristX = candidate.relativeWristX
            }
            let delta = candidate.relativeWristX - track.lastRelativeWristX
            if abs(delta) >= minimumStep {
                let direction = delta > 0 ? 1 : -1
                track.travel += abs(delta)
                if track.lastDirection != 0 && direction != track.lastDirection {
                    track.reversals += 1
                }
                track.lastDirection = direction
                track.lastRelativeWristX = candidate.relativeWristX
            }
            track.targetX = candidate.targetX
            track.lastSeenUptime = now

            if now >= track.cooldownUntilUptime,
               track.reversals >= 1,
               track.travel >= minimumTravel {
                track.cooldownUntilUptime = now + 3.0
                track.focusUntilUptime = now + 4.0
                track.lastDirection = 0
                track.reversals = 0
                track.travel = 0
                track.motionStartedAtUptime = now
            }
            if now <= track.focusUntilUptime {
                detected.append(ROBHandWaveObservation(
                    source: source.rawValue,
                    targetX: candidate.targetX,
                    targetY: candidate.targetY,
                    confidence: candidate.confidence,
                    capturedAtUptime: now
                ))
            }
            handWaveTracks[index] = track
        }
        return detected
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
