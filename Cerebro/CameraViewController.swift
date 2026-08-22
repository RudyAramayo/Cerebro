//
//  ViewController.swift
//  macOS Camera
//
//  Created by Mihail Șalari. on 4/24/17.
//  Copyright © 2017 Mihail Șalari. All rights reserved.
//

import Cocoa
import Vision
import CoreImage
import SceneKit
import CoreImage.CIFilterBuiltins

extension Notification.Name {
    static let ROBDepthCloudFrame = Notification.Name("ROBDepthCloudFrame")
    static let robMainCameraProcessingSettingsDidChange = Notification.Name(
        "ROBMainCameraProcessingSettingsDidChange"
    )
}

/// Typed ownership for preferences that used to live in the main-camera
/// diagnostics window. The headless capture service and Settings can now share
/// them without making the preview window part of the runtime lifecycle.
@objcMembers public final class ROBMainCameraProcessingSettings: NSObject {
    public static let shared = ROBMainCameraProcessingSettings()

    private static let pose3DEnabledKey = "ROBCameraPose3DEnabled"
    private static let pose3DFPSKey = "ROBCameraPose3DFPS"
    private static let swordTrackerEnabledKey = "ROBCameraSwordTrackerEnabled"
    private static let swordTrackerFPSKey = "ROBCameraSwordTrackerFPS"
    private static let depthOverlayOpacityKey = "ROBCameraDepthOverlayOpacity"
    private static let bellyPose2DEnabledKey = "ROBCameraBellyPose2DEnabled"
    private static let bellyDepthOverlayOpacityKey = "ROBCameraBellyDepthOverlayOpacity"
    private static let bellyDepthOverlayEnabledKey = "ROBCameraBellyDepthOverlayEnabled"
    private static let bellySidewalkOverlayEnabledKey = "ROBCameraBellySidewalkOverlayEnabled"
    private static let bellySidewalkOverlayOpacityKey = "ROBCameraBellySidewalkOverlayOpacity"
    private let defaults = UserDefaults.standard

    public var pose3DEnabled: Bool {
        get { defaults.object(forKey: Self.pose3DEnabledKey) == nil || defaults.bool(forKey: Self.pose3DEnabledKey) }
        set { set(newValue, key: Self.pose3DEnabledKey) }
    }

    public var pose3DFramesPerSecond: Double {
        get {
            defaults.object(forKey: Self.pose3DFPSKey) == nil
                ? 0.5
                : max(0.1, min(2, defaults.double(forKey: Self.pose3DFPSKey)))
        }
        set { set(max(0.1, min(2, newValue)), key: Self.pose3DFPSKey) }
    }

    public var swordTrackerEnabled: Bool {
        get {
            defaults.object(forKey: Self.swordTrackerEnabledKey) == nil
                || defaults.bool(forKey: Self.swordTrackerEnabledKey)
        }
        set { set(newValue, key: Self.swordTrackerEnabledKey) }
    }

    public var swordTrackerFramesPerSecond: Double {
        get {
            defaults.object(forKey: Self.swordTrackerFPSKey) == nil
                ? 30
                : max(5, min(60, defaults.double(forKey: Self.swordTrackerFPSKey)))
        }
        set { set(max(5, min(60, newValue)), key: Self.swordTrackerFPSKey) }
    }

    public var depthOverlayOpacity: Double {
        get {
            defaults.object(forKey: Self.depthOverlayOpacityKey) == nil
                ? 0.45
                : max(0, min(1, defaults.double(forKey: Self.depthOverlayOpacityKey)))
        }
        set { set(max(0, min(1, newValue)), key: Self.depthOverlayOpacityKey) }
    }

    public var bellyPose2DEnabled: Bool {
        get {
            defaults.object(forKey: Self.bellyPose2DEnabledKey) == nil
                || defaults.bool(forKey: Self.bellyPose2DEnabledKey)
        }
        set { set(newValue, key: Self.bellyPose2DEnabledKey) }
    }

    public var bellyDepthOverlayOpacity: Double {
        get {
            defaults.object(forKey: Self.bellyDepthOverlayOpacityKey) == nil
                ? 0.45
                : max(0, min(1, defaults.double(forKey: Self.bellyDepthOverlayOpacityKey)))
        }
        set { set(max(0, min(1, newValue)), key: Self.bellyDepthOverlayOpacityKey) }
    }

    public var bellyDepthOverlayEnabled: Bool {
        get {
            defaults.object(forKey: Self.bellyDepthOverlayEnabledKey) == nil
                || defaults.bool(forKey: Self.bellyDepthOverlayEnabledKey)
        }
        set { set(newValue, key: Self.bellyDepthOverlayEnabledKey) }
    }

    public var bellySidewalkOverlayEnabled: Bool {
        get {
            defaults.object(forKey: Self.bellySidewalkOverlayEnabledKey) == nil
                || defaults.bool(forKey: Self.bellySidewalkOverlayEnabledKey)
        }
        set { set(newValue, key: Self.bellySidewalkOverlayEnabledKey) }
    }

    public var bellySidewalkOverlayOpacity: Double {
        get {
            defaults.object(forKey: Self.bellySidewalkOverlayOpacityKey) == nil
                ? 0.45
                : max(0, min(1, defaults.double(forKey: Self.bellySidewalkOverlayOpacityKey)))
        }
        set { set(max(0, min(1, newValue)), key: Self.bellySidewalkOverlayOpacityKey) }
    }

    private func set(_ value: Bool, key: String) {
        guard defaults.object(forKey: key) == nil || defaults.bool(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        notifyChange()
    }

    private func set(_ value: Double, key: String) {
        guard defaults.object(forKey: key) == nil || defaults.double(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .robMainCameraProcessingSettingsDidChange, object: self)
    }
}

@objcMembers public final class ROBDepthCloudFrame: NSObject {
    public let millimetersLittleEndian: NSData
    public let width: Int
    public let height: Int
    public let rgbPixelBuffer: CVPixelBuffer?
    public let isBelly: Bool

    init(depth: CameraDepthFrame, rgbSampleBuffer: CMSampleBuffer, isBelly: Bool = false) {
        millimetersLittleEndian = depth.millimetersLittleEndian as NSData
        width = depth.width
        height = depth.height
        rgbPixelBuffer = CMSampleBufferGetImageBuffer(rgbSampleBuffer)
        self.isBelly = isBelly
    }
}

final class ROBDepthOverlayRenderer {
    private let queue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.depth-overlay", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var lastRender: CFTimeInterval = 0

    func offer(depth: CameraDepthFrame, completion: @escaping (NSImage) -> Void) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard !busy, now - lastRender >= 0.1 else { lock.unlock(); return }
        busy = true; lastRender = now; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: depth.width, pixelsHigh: depth.height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: depth.width * 4, bitsPerPixel: 32
            )
            if let output = bitmap?.bitmapData {
                depth.millimetersLittleEndian.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for index in 0..<(depth.width * depth.height) {
                        let mm = Int(UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8))
                        let destination = output.advanced(by: index * 4)
                        guard mm >= 150, mm <= 10_000 else {
                            destination[0] = 0; destination[1] = 0; destination[2] = 0; destination[3] = 0
                            continue
                        }
                        let t = max(0, min(1, Float(mm - 300) / 5_700))
                        destination[0] = UInt8(255 * (1 - t))
                        destination[1] = UInt8(255 * (1 - abs(t * 2 - 1)))
                        destination[2] = UInt8(255 * t)
                        destination[3] = 255
                    }
                }
            }
            let image = NSImage(size: NSSize(width: depth.width, height: depth.height))
            if let bitmap { image.addRepresentation(bitmap) }
            DispatchQueue.main.async {
                completion(image)
                self.lock.lock(); self.busy = false; self.lock.unlock()
            }
        }
    }
}

/// Builds one GPU point primitive rather than thousands of SceneKit nodes.
/// Sampling every fourth pixel caps a 640x400 frame at 16,000 points, and the
/// five-Hz gate keeps diagnostics from competing with perception or control.
private final class ROBDepthPointCloudRenderer {
    private let queue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.depth-point-cloud", qos: .utility)
    private let lock = NSLock()
    private var isBuilding = false
    private var lastBuildTime: CFTimeInterval = 0

    func offer(depth: CameraDepthFrame, rgbSampleBuffer: CMSampleBuffer, in view: SCNView) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard !isBuilding, now - lastBuildTime >= 0.2 else { lock.unlock(); return }
        isBuilding = true
        lastBuildTime = now
        lock.unlock()

        let rgbBuffer = CMSampleBufferGetImageBuffer(rgbSampleBuffer)
        queue.async { [weak self, weak view] in
            guard let self else { return }
            let geometry = self.geometry(depth: depth, rgbBuffer: rgbBuffer)
            DispatchQueue.main.async {
                defer {
                    self.lock.lock(); self.isBuilding = false; self.lock.unlock()
                }
                guard let view, let geometry else { return }
                let scene = SCNScene()
                let cloud = SCNNode(geometry: geometry)
                scene.rootNode.addChildNode(cloud)

                let camera = SCNNode()
                camera.camera = SCNCamera()
                camera.camera?.zNear = 0.01
                camera.camera?.zFar = 12
                camera.position = SCNVector3(0, 0, 0)
                scene.rootNode.addChildNode(camera)
                view.scene = scene
                view.pointOfView = camera
            }
        }
    }

    private func geometry(depth: CameraDepthFrame, rgbBuffer: CVPixelBuffer?) -> SCNGeometry? {
        let stride = 4
        let width = depth.width
        let height = depth.height
        guard width > 0, height > 0 else { return nil }
        let fx = Float(width) / (2 * tan(69 * .pi / 360))
        let fy = fx
        let cx = Float(width - 1) / 2
        let cy = Float(height - 1) / 2
        var vertices: [SIMD3<Float>] = []
        var colors: [SIMD4<UInt8>] = []
        vertices.reserveCapacity((width / stride) * (height / stride))
        colors.reserveCapacity(vertices.capacity)

        if let rgbBuffer { CVPixelBufferLockBaseAddress(rgbBuffer, .readOnly) }
        defer { if let rgbBuffer { CVPixelBufferUnlockBaseAddress(rgbBuffer, .readOnly) } }
        let rgbWidth = rgbBuffer.map(CVPixelBufferGetWidth) ?? 0
        let rgbHeight = rgbBuffer.map(CVPixelBufferGetHeight) ?? 0
        let rgbRowBytes = rgbBuffer.map(CVPixelBufferGetBytesPerRow) ?? 0
        let rgbBase = rgbBuffer.flatMap(CVPixelBufferGetBaseAddress)?.assumingMemoryBound(to: UInt8.self)

        depth.millimetersLittleEndian.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in Swift.stride(from: 0, to: height, by: stride) {
                for x in Swift.stride(from: 0, to: width, by: stride) {
                    let offset = (y * width + x) * 2
                    let millimeters = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                    guard millimeters >= 150, millimeters <= 10_000 else { continue }
                    let z = Float(millimeters) / 1000
                    vertices.append(SIMD3((Float(x) - cx) * z / fx, -(Float(y) - cy) * z / fy, -z))
                    if let rgbBase, x < rgbWidth, y < rgbHeight {
                        let pixel = rgbBase.advanced(by: y * rgbRowBytes + x * 4)
                        colors.append(SIMD4(pixel[2], pixel[1], pixel[0], 255))
                    } else {
                        colors.append(SIMD4(80, 210, 255, 255))
                    }
                }
            }
        }
        guard !vertices.isEmpty else { return nil }
        let vertexData = vertices.withUnsafeBytes { Data($0) }
        let colorData = colors.withUnsafeBytes { Data($0) }
        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: vertices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: false, componentsPerVector: 4,
            bytesPerComponent: 1, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<UInt8>>.stride
        )
        var indices = (0..<vertices.count).map(UInt32.init)
        let indexData = indices.withUnsafeMutableBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .point,
            primitiveCount: vertices.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        element.pointSize = 2
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 3
        return SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
    }
}

private struct ROBSwordTrack {
    let grip: CGPoint
    let tip: CGPoint
    let confidence: Double
}

private struct ROBProjectedPose3D {
    let points: [CGPoint]
    let lines: [(CGPoint, CGPoint)]
    let confidence: Double
}

/// A low-latency geometric tracker for elongated training implements. It uses
/// the latest 2D wrist locations to reject unrelated edges, then smooths the
/// blade axis over time. Only one contour request may be in flight.
private final class ROBSwordTracker {
    private let queue = DispatchQueue(label: "com.orbitusrobotics.cerebro.sword-tracker", qos: .userInteractive)
    private let lock = NSLock()
    private var inFlight = false
    private var lastAdmission: CFTimeInterval = 0
    private var previous: ROBSwordTrack?

    func offer(_ sampleBuffer: CMSampleBuffer, wrists: [CGPoint], maximumFPS: Double,
               completion: @escaping (ROBSwordTrack?) -> Void) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard !inFlight, maximumFPS > 0, now - lastAdmission >= 1 / maximumFPS else {
            lock.unlock(); return
        }
        inFlight = true; lastAdmission = now; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.inFlight = false; self.lock.unlock() }
            autoreleasepool {
                let request = VNDetectContoursRequest()
                request.contrastAdjustment = 1.5
                request.detectsDarkOnLight = true
                request.maximumImageDimension = 320
                do {
                    try VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:]).perform([request])
                    let track = request.results?.first.flatMap { self.bestTrack(in: $0, wrists: wrists) }
                    self.previous = track
                    DispatchQueue.main.async { completion(track) }
                } catch {
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        }
    }

    func reset() {
        queue.async { self.previous = nil }
    }

    private func bestTrack(in observation: VNContoursObservation, wrists: [CGPoint]) -> ROBSwordTrack? {
        var best: (track: ROBSwordTrack, score: CGFloat)?
        for contour in Self.flattenedContours(observation.topLevelContours) {
            let points = Self.points(in: contour.normalizedPath)
            guard points.count >= 5, let axis = Self.principalAxis(points) else { continue }
            let length = Self.distance(axis.0, axis.1)
            let bounds = contour.normalizedPath.boundingBox
            let thickness = max(0.002, min(bounds.width, bounds.height))
            let elongation = length / thickness
            guard length >= 0.10, length <= 0.85, elongation >= 4 else { continue }
            let d0 = wrists.map { Self.distance($0, axis.0) }.min() ?? 1
            let d1 = wrists.map { Self.distance($0, axis.1) }.min() ?? 1
            let grip = d0 <= d1 ? axis.0 : axis.1
            let tip = d0 <= d1 ? axis.1 : axis.0
            let wristDistance = min(d0, d1)
            // Wrist pose initializes/reacquires the track. Once locked, the
            // previous grip can carry fast motion between slower body-pose
            // updates without letting unrelated scene edges take over.
            let continuityDistance = previous.map { min(Self.distance($0.grip, axis.0), Self.distance($0.grip, axis.1)) } ?? 1
            let hasBodyAnchor = !wrists.isEmpty
            let canAcquireGeometrically = !hasBodyAnchor && previous == nil && length >= 0.16 && elongation >= 7
            guard wristDistance <= 0.22 || continuityDistance <= 0.14 || canAcquireGeometrically else { continue }
            var score = min(1, (elongation - 3) / 12) * 0.35 + min(1, length / 0.45) * 0.35
            score += max(0, 1 - wristDistance / 0.22) * 0.30
            if let previous {
                let direct = Self.distance(previous.grip, grip) + Self.distance(previous.tip, tip)
                score += max(0, 1 - direct / 0.5) * 0.25
                score += max(0, 1 - continuityDistance / 0.14) * 0.20
            } else if !hasBodyAnchor {
                score = min(score, 0.48)
            }
            let candidate = ROBSwordTrack(grip: grip, tip: tip, confidence: Double(min(0.99, score)))
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        guard var track = best?.track else { return nil }
        if let previous {
            let alpha: CGFloat = 0.62
            track = ROBSwordTrack(
                grip: CGPoint(x: previous.grip.x * (1 - alpha) + track.grip.x * alpha,
                              y: previous.grip.y * (1 - alpha) + track.grip.y * alpha),
                tip: CGPoint(x: previous.tip.x * (1 - alpha) + track.tip.x * alpha,
                             y: previous.tip.y * (1 - alpha) + track.tip.y * alpha),
                confidence: track.confidence)
        }
        return track
    }

    private static func flattenedContours(_ roots: [VNContour]) -> [VNContour] {
        var result: [VNContour] = []
        var pending = roots
        while let contour = pending.popLast() {
            result.append(contour)
            pending.append(contentsOf: contour.childContours)
        }
        return result
    }

    private static func points(in path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            for index in 0..<count { result.append(element.pointee.points[index]) }
        }
        return result
    }

    private static func principalAxis(_ points: [CGPoint]) -> (CGPoint, CGPoint)? {
        let count = CGFloat(points.count)
        let center = CGPoint(x: points.reduce(0) { $0 + $1.x } / count,
                             y: points.reduce(0) { $0 + $1.y } / count)
        var xx: CGFloat = 0, xy: CGFloat = 0, yy: CGFloat = 0
        for point in points {
            let x = point.x - center.x, y = point.y - center.y
            xx += x * x; xy += x * y; yy += y * y
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let projections = points.map { ($0.x - center.x) * direction.x + ($0.y - center.y) * direction.y }
        guard let low = projections.min(), let high = projections.max(), high > low else { return nil }
        return (CGPoint(x: center.x + low * direction.x, y: center.y + low * direction.y),
                CGPoint(x: center.x + high * direction.x, y: center.y + high * direction.y))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

struct ROBCameraServiceStatusSnapshot: Sendable {
    let state: String
    let detail: String?
    let stateChangedAt: Date
    let framesReceived: UInt64
    let lastFrameAt: Date?
    let sessionRequested: Bool
    let visibleConsumer: Bool
    let automaticProcessingConsumer: Bool
    let geminiConsumer: Bool
    let remoteMediaConsumer: Bool
    let videoServer: ROBVideoServerStatusSnapshot?
    let videoServerStartupError: String?
}

final class CameraViewController: NSViewController {
    private var cameraManager: CameraManagerProtocol?
    private let faceContainerView = NSView()
    
    private let faceDepthPointCloudRenderer = ROBDepthPointCloudRenderer()
    
    private var videoServer: ROBVideoServer?
    private var cameraViewIsVisible = false
    private var latestFrameSet: CameraFrameSet?
    private var lastActiveProject = ROBDatasetManager.shared.activeProject
    private var lastMainCameraResolution = ROBMLXRuntime.shared.mainCameraResolution
    private var remoteVideoIsActive = false
    private var geminiVideoIsActive = false
    private var recordingDemandActive = false
    private var cameraSessionIsRequested = false
    private var cameraStatusState = CameraSourceState.stopped
    private var cameraStatusDetail: String?
    private var cameraStatusChangedAt = Date()
    private var cameraFramesReceived: UInt64 = 0
    private var cameraLastFrameAt: Date?
    private var videoServerStartupError: String?
    
    @IBOutlet weak var skeletonView: SCNView!
    @IBOutlet weak var personMaskImageView: NSImageView!
    @IBOutlet weak var personMaskImageView_maskImage: NSImageView!
    @IBOutlet weak var poseView: PoseDrawingView!
    @objc public weak var robMainViewController: ROBMainViewController?
    
    var sceneCreated = false
    let renderer = HumanBodySkeletonRenderer()
    var viewModel: HumanBodyPose3DDetector = HumanBodyPose3DDetector()
    let context = CIContext()
    private let depthOverlayView = NSImageView()
    private var overlayManager: CameraOverlayManager?
    private var hasSetAspectRatio = false
    private var isCalibrationRequested = false
    private let calibrateButton = NSButton()
    private let processingSettings = ROBMainCameraProcessingSettings.shared
    private var latestHumanObservations: [VNHumanObservation] = []
    private var lastSceneSnapshotUpdate: CFTimeInterval = 0
    private var lastVisionProcessingUpdate: CFTimeInterval = 0
    private var last3DPoseProcessingUpdate: CFTimeInterval = 0
    private let visionAnalysisQueue = DispatchQueue(label: "com.orbitusrobotics.cerebro.realtime-pose", qos: .userInitiated)
    private let visionAdmissionLock = NSLock()
    private var visionAnalysisInFlight = false
    private let reversePoseEstimator = ROBReverseCameraPoseEstimator()
    private let swordTracker = ROBSwordTracker()
    private let swordWristLock = NSLock()
    private var swordWristAnchors: [CGPoint] = []
    private lazy var humanBodyPose3DRequest: VNDetectHumanBodyPose3DRequest = {
        VNDetectHumanBodyPose3DRequest { [weak self] request, error in
            guard error == nil, let observation = (request.results as? [VNHumanBodyPose3DObservation])?.first else { return }
            DispatchQueue.main.async { self?.process_humanBodyPose3D_Observation(observation) }
        }
    }()

    private var pose3DEnabled: Bool {
        processingSettings.pose3DEnabled
    }

    private var pose3DFPS: Double {
        processingSettings.pose3DFramesPerSecond
    }

    private var swordTrackerEnabled: Bool {
        processingSettings.swordTrackerEnabled
    }

    private var swordTrackerFPS: Double {
        processingSettings.swordTrackerFramesPerSecond
    }
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        faceContainerView.frame = view.bounds
        faceContainerView.autoresizingMask = [.width, .height]
        view.addSubview(faceContainerView, positioned: .below, relativeTo: nil)
        
        skeletonView.frame = view.bounds
        skeletonView.autoresizingMask = [.width, .height]

        let manager = CameraManager(containerView: faceContainerView, role: .face)
        manager.delegate = self
        manager.recordingFrameHandler = { frameSet in
            ROBRecordingCoordinator.shared.offerCameraFrame(role: .face, frameSet: frameSet)
        }
        cameraManager = manager
        
        setupCalibrateButton()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(perceptionSettingsDidChange(_:)),
            name: .robMainCameraProcessingSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(perceptionSettingsDidChange(_:)),
            name: .robMLXRuntimeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(perceptionSettingsDidChange(_:)),
            name: .robDetectorSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLearnObjectNotification(_:)),
            name: Notification.Name("ROBLearnObjectNotification"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(perceptionSettingsDidChange(_:)),
            name: Notification.Name("ROBHologramMovieRecordingStateDidChange"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingDemandDidChange(_:)),
            name: .robRecordingDemandDidChange,
            object: ROBRecordingCoordinator.shared
        )

        do {
            let videoServer = try ROBVideoServer()
            videoServer.subscriptionActivityDidChange = { [weak self] isActive in
                guard let self else { return }
                self.remoteVideoIsActive = isActive
                self.reconcileCameraSession()
            }
            try videoServer.start()
            self.videoServer = videoServer
            manager.videoSampleHandler = { [weak videoServer] sampleBuffer in
                videoServer?.offer(sampleBuffer)
            }
        } catch {
            // Perception remains available if the optional media service fails.
            videoServerStartupError = error.localizedDescription
            print("ROBVideo startup failed: \(error.localizedDescription)")
        }
        
        setupSceneKitView()
        setupDepthOverlay()
        manager.setPreviewVisible(false)
        applyProcessingSettings()
        applyRecordingDemand()
        reconcileCameraSession()
    }
    
    @IBAction func toggleCamera(_ sender: Any?) {
        guard let cameraManager else { return }
        do {
            print("ToggleCamera")
            try cameraManager.stopSession()
            try cameraManager.startSession()
            cameraSessionIsRequested = true
        } catch {
            print(error.localizedDescription)
        }
    }
    
    @IBAction func bindCamera(_ sender: Any?) {
        guard let cameraManager else { return }
        do {
            try cameraManager.bindCamera()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    @IBAction func bindCameaRebootSession(_ sender: Any?) {
        guard let cameraManager else { return }
        do {
            try cameraManager.bindCameraRebootSession()
        } catch {
            print(error.localizedDescription)
        }
    }

    /// Adds Gemini as an independent camera consumer. Controller/Vision Pro
    /// video demand remains owned by ROBVideoServer and cannot be disabled by
    /// the Gemini runtime switch.
    @objc(setGeminiVideoDemandActive:)
    func setGeminiVideoDemandActive(_ isActive: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setGeminiVideoDemandActive(isActive)
            }
            return
        }
        guard geminiVideoIsActive != isActive else { return }
        geminiVideoIsActive = isActive
        reconcileCameraSession()
    }

    /// Controls only the local diagnostics renderer. Camera capture remains
    /// governed by the independent perception, Gemini, recording, and remote
    /// media consumers.
    @objc(setDiagnosticsPreviewVisible:)
    func setDiagnosticsPreviewVisible(_ isVisible: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setDiagnosticsPreviewVisible(isVisible)
            }
            return
        }
        cameraViewIsVisible = isVisible
        cameraManager?.setPreviewVisible(isVisible)
        reconcileCameraSession()
    }
    
    
    override var representedObject: Any? {
        didSet {
            // Update the view, if already loaded.
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        cameraViewIsVisible = true
        cameraManager?.setPreviewVisible(true)
        reconcileCameraSession()
    }
    
    override func viewDidDisappear() {
        super.viewDidDisappear()
        cameraViewIsVisible = false
        cameraManager?.setPreviewVisible(false)
        reconcileCameraSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        videoServer?.stop()
    }

    @objc private func applicationWillTerminate() {
        videoServer?.stop()
        try? cameraManager?.stopSession()
    }

    private func reconcileCameraSession() {
        guard let cameraManager else { return }
        let shouldRun = cameraViewIsVisible
            || automaticProcessingNeedsFrames
            || remoteVideoIsActive
            || geminiVideoIsActive
            || recordingDemandActive
            || ROBHologramExporter.shared.isMovieRecording
        guard shouldRun != cameraSessionIsRequested else { return }
        do {
            if shouldRun {
                try cameraManager.startSession()
            } else {
                try cameraManager.stopSession()
            }
            cameraSessionIsRequested = shouldRun
        } catch {
            print(error.localizedDescription)
        }
    }

    private var automaticProcessingNeedsFrames: Bool {
        if swordTrackerEnabled { return true }
        let registry = ROBDynamicDetectorRegistry.shared
        guard registry.processingFramesPerSecond(for: .mainCamera) > 0 else { return false }
        return ROBMLXRuntime.shared.mainCameraDetectionEnabled
            || registry.enabled("body-pose", source: .mainCamera)
            || registry.requiresFrames(for: .mainCamera)
            || pose3DEnabled
    }

    @objc private func perceptionSettingsDidChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.perceptionSettingsDidChange(notification)
            }
            return
        }
        applyProcessingSettings()
        
        let currentProject = ROBDatasetManager.shared.activeProject
        let currentResolution = ROBMLXRuntime.shared.mainCameraResolution
        
        if lastActiveProject != currentProject || lastMainCameraResolution != currentResolution {
            lastActiveProject = currentProject
            lastMainCameraResolution = currentResolution
            if cameraSessionIsRequested {
                // Forcibly reboot camera session to hot-swap model blob and load new resolution parameters dynamically
                guard let cameraManager else {
                    cameraSessionIsRequested = false
                    let message = "Camera hot restart failed: camera manager is unavailable."
                    cameraStatusDetail = message
                    cameraStatusChangedAt = Date()
                    print(message)
                    return
                }
                do {
                    try cameraManager.stopSession()
                    cameraSessionIsRequested = false
                    try cameraManager.startSession()
                    cameraSessionIsRequested = true
                } catch {
                    // The flag represents a successfully acknowledged session,
                    // not merely intent. Clearing it allows reconciliation to
                    // retry instead of suppressing recovery after a failed start.
                    cameraSessionIsRequested = false
                    let message = "Camera hot restart failed: \(error.localizedDescription)"
                    cameraStatusDetail = message
                    cameraStatusChangedAt = Date()
                    print(message)
                    reconcileCameraSession()
                }
            }
        } else {
            reconcileCameraSession()
        }
    }

    @objc private func recordingDemandDidChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.recordingDemandDidChange(notification) }
            return
        }
        applyRecordingDemand()
        reconcileCameraSession()
    }

    private func applyRecordingDemand() {
        let demand = ROBRecordingCoordinator.shared.cameraCaptureDemand(for: .face)
        recordingDemandActive = demand.active
        cameraManager?.setCaptureResolutionOverride(demand.resolutionOverride)
    }

    private func applyProcessingSettings() {
        depthOverlayView.alphaValue = processingSettings.depthOverlayOpacity
        let processingEnabled = ROBDynamicDetectorRegistry.shared
            .processingFramesPerSecond(for: .mainCamera) > 0
        if !processingEnabled {
            latestHumanObservations = []
            poseView.bodyPose_observations = []
            poseView.humanHandPose_observations = []
            poseView.dynamicDetectorOutput = nil
        }
        if !pose3DEnabled || !processingEnabled {
            skeletonView.isHidden = true
            skeletonView.scene = nil
            sceneCreated = false
            poseView.projectedPose3D = nil
        }
        if !swordTrackerEnabled {
            swordTracker.reset()
            swordWristLock.lock()
            swordWristAnchors = []
            swordWristLock.unlock()
            poseView.swordTrack = nil
            poseView.swordTrackingStatus = nil
        } else if poseView.swordTrackingStatus == nil {
            poseView.swordTrackingStatus = "Sword: waiting for camera frames"
        }
        poseView.needsDisplay = true
    }

    /// Cached state for the process grid. Reading this snapshot has no camera,
    /// permission, model-loading, or network side effects.
    @nonobjc func serviceStatusSnapshot() -> ROBCameraServiceStatusSnapshot {
        precondition(Thread.isMainThread, "Camera status is owned by the main thread")
        return ROBCameraServiceStatusSnapshot(
            state: cameraStatusState.rawValue,
            detail: cameraStatusDetail,
            stateChangedAt: cameraStatusChangedAt,
            framesReceived: cameraFramesReceived,
            lastFrameAt: cameraLastFrameAt,
            sessionRequested: cameraSessionIsRequested,
            visibleConsumer: cameraViewIsVisible,
            automaticProcessingConsumer: automaticProcessingNeedsFrames,
            geminiConsumer: geminiVideoIsActive,
            remoteMediaConsumer: remoteVideoIsActive,
            videoServer: videoServer?.statusSnapshot(),
            videoServerStartupError: videoServerStartupError
        )
    }

    @objc private func handleLearnObjectNotification(_ notification: Notification) {
        guard let className = notification.userInfo?["className"] as? String else { return }
        
        // Grab the latest index finger tip point and check if it's fresh (e.g. less than 2 seconds old)
        let store = ROBSceneSnapshotStore.shared
        guard let fingerPoint = store.latestIndexFingerPoint,
              let fingerTime = store.latestIndexFingerPointTime,
              ProcessInfo.processInfo.systemUptime - fingerTime <= 2.0 else {
            NSLog("[LearnObject] No fresh index finger pointing detected (must point and speak within 2 seconds).")
            return
        }
        
        // Grab the latest frame set
        guard let latestFrameSet = self.latestFrameSet else { return }
        
        // Convert CMSampleBuffer (rgbSampleBuffer) to NSImage
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(latestFrameSet.rgbSampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        
        // Calculate the relative bounding box for YOLO
        // Note: fingerPoint.x is between 0.0 and 1.0 (relative to width), fingerPoint.y is between 0.0 and 1.0 (relative to height, 0 is bottom)
        let boxWidth: CGFloat = 0.12
        let boxHeight: CGFloat = 0.18
        let xCenter = fingerPoint.x
        let yCenter = 1.0 - fingerPoint.y - 0.09 // Invert y because YOLO/Cocoa coordinate space has origin at top-left, and offset upwards
        
        let boundingBox = CGRect(
            x: xCenter,
            y: max(0.0, min(1.0, yCenter)),
            width: boxWidth,
            height: boxHeight
        )
        
        // Save to active project using ROBDatasetManager
        ROBDatasetManager.shared.saveSample(image: nsImage, boundingBox: boundingBox, className: className)
    }
}

extension CameraViewController: CameraManagerDelegate {
    
    func process_humanBodyPose3D_Observation(_ observation: VNHumanBodyPose3DObservation) {
        guard pose3DEnabled else { return }
        var projected: [VNHumanBodyPose3DObservation.JointName: CGPoint] = [:]
        for joint in observation.availableJointNames {
            guard let point = try? observation.pointInImage(joint) else { continue }
            projected[joint] = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
        var lines: [(CGPoint, CGPoint)] = []
        for joint in observation.availableJointNames {
            guard let parent = observation.parentJointName(joint) else { continue }
            if parent != joint, let childPoint = projected[joint], let parentPoint = projected[parent] {
                lines.append((childPoint, parentPoint))
            }
        }
        poseView.projectedPose3D = ROBProjectedPose3D(
            points: Array(projected.values), lines: lines, confidence: Double(observation.confidence))
        poseView.needsDisplay = true
        // The old SceneKit camera was centered in an unrelated coordinate
        // system. The live overlay uses Vision's calibrated image projection.
        skeletonView.isHidden = true
    }
    
    func updateScene(observation: VNHumanBodyPose3DObservation) {
        guard let myScene = self.skeletonView.scene else {
            return
        }
        let nodeDict = renderer.createSkeletonNodes(observation: observation)
        
        // Clear any previous skeleton from the scene
        myScene.rootNode.childNodes.forEach {
            if $0 != self.renderer.cameraNode {
                $0.removeFromParentNode()
            }
        }
        
        // Add skeleton nodes to the scene.
        let bodyAnchorNode = SCNNode()
        bodyAnchorNode.position = SCNVector3(0, 0, 0)
        myScene.rootNode.addChildNode(bodyAnchorNode)
        for jointName in nodeDict.keys {
            if let jointNode = nodeDict[jointName] {
                bodyAnchorNode.addChildNode(jointNode)
            }
        }
        
        // Give the head more spherical geometry.
        if let topHead = nodeDict[.topHead], let centerHeadNode = nodeDict[.centerHead], let centerShoulderNode = nodeDict[.centerShoulder] {
            let headHight = CGFloat(topHead.position.y - centerShoulderNode.position.y)
            centerHeadNode.geometry = SCNBox(width: 0.2,
                                             height: headHight,
                                             length: 0.2,
                                             chamferRadius: 0.4)
            centerHeadNode.geometry?.firstMaterial?.diffuse.contents = NSColor(ciColor: .red)
            topHead.isHidden = true
        }
        
        let jointOrderArray: [VNHumanBodyPose3DObservation.JointName] = [.leftWrist, .leftElbow, .leftShoulder,
                                                                         .rightWrist, .rightElbow, .rightShoulder,
                                                                         .centerShoulder, .spine, .rightAnkle,
                                                                         .rightKnee, .rightHip, .leftAnkle, .leftKnee, .leftHip]
        for jointName in jointOrderArray {
            connectNodeToParent(joint: jointName,
                                observation: observation,
                                nodeJointDict: nodeDict,
                                viewModel)
        }
    }
    
    func createScene(observation: VNHumanBodyPose3DObservation) -> SCNScene {
        let myScene = SCNScene()
        let nodeDict = renderer.createSkeletonNodes(observation: observation)
        myScene.rootNode.addChildNode(renderer.createCameraNode(observation: observation))
        
        // Add skeleton nodes to the scene.
        let bodyAnchorNode = SCNNode()
        bodyAnchorNode.position = SCNVector3(0, 0, 0)
        myScene.rootNode.addChildNode(bodyAnchorNode)
        for jointName in nodeDict.keys {
            if let jointNode = nodeDict[jointName] {
                bodyAnchorNode.addChildNode(jointNode)
            }
        }
        
        // Give the head more spherical geometry.
        if let topHead = nodeDict[.topHead], let centerHeadNode = nodeDict[.centerHead], let centerShoulderNode = nodeDict[.centerShoulder] {
            let headHight = CGFloat(topHead.position.y - centerShoulderNode.position.y)
            centerHeadNode.geometry = SCNBox(width: 0.2,
                                             height: headHight,
                                             length: 0.2,
                                             chamferRadius: 0.4)
            centerHeadNode.geometry?.firstMaterial?.diffuse.contents = NSColor(ciColor: .red)
            topHead.isHidden = true
        }
        
        let jointOrderArray: [VNHumanBodyPose3DObservation.JointName] = [.leftWrist, .leftElbow, .leftShoulder,
                                                                         .rightWrist, .rightElbow, .rightShoulder,
                                                                         .centerShoulder, .spine, .rightAnkle,
                                                                         .rightKnee, .rightHip, .leftAnkle, .leftKnee, .leftHip]
        for jointName in jointOrderArray {
            connectNodeToParent(joint: jointName,
                                observation: observation,
                                nodeJointDict: nodeDict,
                                viewModel)
        }
        return myScene
    }
    
    func setupSceneKitView() {
        self.skeletonView.isHidden = true
    }

    private func setupDepthOverlay() {
        self.overlayManager = CameraOverlayManager(
            attachingTo: view,
            role: .face,
            customPoseView: poseView,
            customDepthOverlayView: depthOverlayView
        )
        self.overlayManager?.onBodyPoseDetected = { [weak self] observations in
            let wrists = observations.flatMap { observation -> [CGPoint] in
                [VNHumanBodyPoseObservation.JointName.leftWrist,
                 VNHumanBodyPoseObservation.JointName.rightWrist].compactMap { name in
                    guard let point = try? observation.recognizedPoint(name), point.confidence >= 0.25 else { return nil }
                    return point.location
                }
            }
            self?.swordWristLock.lock()
            self?.swordWristAnchors = wrists
            self?.swordWristLock.unlock()
        }
        depthOverlayView.imageScaling = .scaleProportionallyUpOrDown
        depthOverlayView.alphaValue = CGFloat(processingSettings.depthOverlayOpacity)
        depthOverlayView.translatesAutoresizingMaskIntoConstraints = false
        depthOverlayView.isHidden = true
        view.addSubview(depthOverlayView, positioned: .below, relativeTo: poseView)
        NSLayoutConstraint.activate([
            depthOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            depthOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            depthOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
            depthOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupCalibrateButton() {
        calibrateButton.title = "Calibrate Camera (Chessboard)"
        calibrateButton.bezelStyle = .rounded
        calibrateButton.target = self
        calibrateButton.action = #selector(calibrateButtonClicked(_:))
        calibrateButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(calibrateButton, positioned: .above, relativeTo: nil)
        
        NSLayoutConstraint.activate([
            calibrateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            calibrateButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            calibrateButton.widthAnchor.constraint(equalToConstant: 220),
            calibrateButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    
    @objc private func calibrateButtonClicked(_ sender: NSButton) {
        isCalibrationRequested = true
        sender.isEnabled = false
        sender.title = "Calibrating..."
    }
    
    func applySourceOverCompositing(inputImage: CIImage, backgroundImage: CIImage) -> CIImage? {
        // 1. Create a CISourceOverCompositing filter instance.
        let filter = CIFilter.sourceOverCompositing()

        // 2. Set the input images for the filter.
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        filter.setValue(backgroundImage, forKey: kCIInputBackgroundImageKey)

        // 3. Retrieve the output image.
        guard let outputImage = filter.outputImage else {
            print("Failed to get output image from filter.")
            return nil
        }

        return outputImage
    }
    
    func cameraManager(_ manager: CameraManagerProtocol, didOutput frameSet: CameraFrameSet) {
        cameraFramesReceived &+= 1
        cameraLastFrameAt = Date()
        let sampleBuffer = frameSet.rgbSampleBuffer
        self.latestFrameSet = frameSet
        
        if isCalibrationRequested {
            isCalibrationRequested = false
            if let depth = frameSet.alignedDepth, let intrinsics = frameSet.intrinsics {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        let rms = try ROBChessboardCalibration.performCalibration(
                            role: .face,
                            rgbSampleBuffer: sampleBuffer,
                            depth: depth,
                            intrinsics: intrinsics,
                            cols: 9,
                            rows: 6,
                            squareSizeMeters: 0.036909375
                        )
                        DispatchQueue.main.async {
                            self?.calibrateButton.isEnabled = true
                            self?.calibrateButton.title = "Calibrate Camera (Chessboard)"
                            let alert = NSAlert()
                            alert.messageText = "Calibration Succeeded!"
                            alert.informativeText = String(format: "Successfully calibrated the Face camera!\nSolved RMS Error: %.4f meters", rms)
                            alert.runModal()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self?.calibrateButton.isEnabled = true
                            self?.calibrateButton.title = "Calibrate Camera (Chessboard)"
                            let alert = NSAlert()
                            alert.messageText = "Calibration Failed"
                            alert.informativeText = error.localizedDescription
                            alert.runModal()
                        }
                    }
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.calibrateButton.isEnabled = true
                    self?.calibrateButton.title = "Calibrate Camera (Chessboard)"
                    let alert = NSAlert()
                    alert.messageText = "Calibration Failed"
                    alert.informativeText = "Depth frame is currently unavailable."
                    alert.runModal()
                }
            }
        }
        
        if !hasSetAspectRatio {
            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let width = CGFloat(CVPixelBufferGetWidth(imageBuffer))
                let height = CGFloat(CVPixelBufferGetHeight(imageBuffer))
                if width > 0 && height > 0 {
                    hasSetAspectRatio = true
                    DispatchQueue.main.async { [weak self] in
                        self?.view.window?.contentAspectRatio = NSSize(width: width, height: height)
                    }
                }
            }
        }
        
        let sceneUpdateTime = CACurrentMediaTime()
        let shouldUpdateSceneSnapshot = sceneUpdateTime - lastSceneSnapshotUpdate >= 0.2
        if shouldUpdateSceneSnapshot {
            lastSceneSnapshotUpdate = sceneUpdateTime
            ROBSceneSnapshotStore.shared.updateCameraFrame(
                sequence: frameSet.sequence,
                timestampNanoseconds: frameSet.timestampNanoseconds,
                source: frameSet.source.rawValue,
                people: latestHumanObservations,
                depth: frameSet.alignedDepth
            )
            if let pieces = frameSet.chessPieces {
                ROBSceneSnapshotStore.shared.updateChessPieces(pieces)
            }
        }
        
        let poseEnabled = ROBDynamicDetectorRegistry.shared.enabled("body-pose", source: .mainCamera)
        let processingFPS = ROBDynamicDetectorRegistry.shared.processingFramesPerSecond(for: .mainCamera)
        overlayManager?.offer(
            sampleBuffer: sampleBuffer,
            depthFrame: frameSet.alignedDepth,
            poseEnabled: poseEnabled,
            depthOpacity: processingSettings.depthOverlayOpacity,
            processingFPS: processingFPS
        )
        
        if let depth = frameSet.alignedDepth {
            let hologramFrame = ROBDepthCloudFrame(depth: depth, rgbSampleBuffer: sampleBuffer, isBelly: false)
            ROBHologramExporter.shared.capture(hologramFrame)
            if cameraViewIsVisible {
                faceDepthPointCloudRenderer.offer(depth: depth, rgbSampleBuffer: sampleBuffer, in: skeletonView)
            }
            NotificationCenter.default.post(
                name: .ROBDepthCloudFrame,
                object: hologramFrame
            )
            robMainViewController?.didCaptureAlignedDepthData(
                depth.millimetersLittleEndian,
                width: UInt(depth.width),
                height: UInt(depth.height),
                sequence: frameSet.sequence,
                timestampNanoseconds: frameSet.timestampNanoseconds
            )
        } else {
            robMainViewController?.clearAlignedDepthFrame()
        }

        // ROBAI performs its own one-frame-per-second throttle and JPEG
        // encoding on a separate queue, so the capture callback stays cheap.
        robMainViewController?.didCaptureCameraSampleBuffer(sampleBuffer)

        // MLX applies a separate >=3 second sampling gate and performs VLM
        // inference on its actor. This call never enters the motor loop.
        ROBMLXRuntime.shared.offerCameraSampleBuffer(sampleBuffer)
        ROBDynamicDetectorRegistry.shared.offer(sampleBuffer, source: .mainCamera)
        if swordTrackerEnabled {
            swordWristLock.lock(); let wrists = swordWristAnchors; swordWristLock.unlock()
            swordTracker.offer(sampleBuffer, wrists: wrists, maximumFPS: swordTrackerFPS) { [weak self] track in
                self?.poseView.swordTrack = track
                self?.poseView.swordTrackingStatus = track == nil
                    ? (wrists.isEmpty ? "Sword: searching (no wrist lock)" : "Sword: searching near wrist")
                    : "Sword: locked"
                self?.poseView.needsDisplay = true
            }
        }

        // Keep the legacy Vision requests under the same user-selected
        // analysis ceiling as MLX and the dynamic detector registry.
        guard processingFPS > 0 else { return }
        let visionProcessingTime = CACurrentMediaTime()
        guard visionProcessingTime - lastVisionProcessingUpdate >= 1 / processingFPS else { return }
        lastVisionProcessingUpdate = visionProcessingTime

        visionAdmissionLock.lock()
        guard !visionAnalysisInFlight else { visionAdmissionLock.unlock(); return }
        visionAnalysisInFlight = true
        visionAdmissionLock.unlock()

        // Vision can take longer than the requested sampling interval. Never
        // execute it on the camera callback or queue more than one analysis.
        visionAnalysisQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.visionAdmissionLock.lock()
                self.visionAnalysisInFlight = false
                self.visionAdmissionLock.unlock()
            }

        //process samplebuffer here
        let humanRectanglesRequest = VNDetectHumanRectanglesRequest { request, error in
            let observations = (request.results as? [VNHumanObservation]) ?? []
            DispatchQueue.main.async {
                self.latestHumanObservations = observations
                self.poseView.humanRect_observations = observations
                self.poseView.setNeedsDisplay(self.poseView.bounds)
            }
        }
        humanRectanglesRequest.revision = VNDetectHumanRectanglesRequestRevision2
        humanRectanglesRequest.upperBodyOnly = false
        
        let calibrationBarcodeRequest = VNDetectBarcodesRequest { request, error in
            let observations = (request.results as? [VNBarcodeObservation]) ?? []
            self.reversePoseEstimator.process(
                barcodes: observations,
                depth: frameSet.alignedDepth,
                intrinsics: frameSet.intrinsics
            )
        }
        calibrationBarcodeRequest.symbologies = [.qr]
        let trajectoriesRequest = VNDetectTrajectoriesRequest(frameAnalysisSpacing: CMTime(value: 1, timescale: 60), trajectoryLength: 1, completionHandler: { request, error in
            for observation in request.results as! [VNTrajectoryObservation] {
                print("trajectoriesRequest = \(observation)")
            }
        })
        let animalBodyPoseRequest = VNDetectAnimalBodyPoseRequest(completionHandler: { request, error in
            for observation in request.results as! [VNAnimalBodyPoseObservation] {
                print("animalBodyPoseRequest = \(observation)")
            }
        })
        
        let detectFaceRequest = VNDetectFaceRectanglesRequest { request, error in
            if let observations = request.results as? [VNFaceObservation] {
                print("detectFaceRequest = \(observations)")
                self.robMainViewController?.didSeeNewPeople(observations)
            }
        }
        
        let personInstanceRequest = VNGeneratePersonInstanceMaskRequest { request, error in
            for observation in request.results as! [VNInstanceMaskObservation] {
                print("personInstanceRequest = \(observation)")
                
                do {
                    // 4. Get the first person's mask.
                    // The observations are `VNInstanceMaskObservation` objects.
                    let firstPersonMaskObservation = observation as VNInstanceMaskObservation
                    
                    // 5. Generate a `CIImage` mask for the desired instance.
                    // We'll use the `allInstances` property to get a mask for all detected instances.
                    let maskPixelBuffer = try firstPersonMaskObservation.generateMask(forInstances: observation.allInstances)
                    var maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)
                    
                    
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        return
                    }
                    let ciImage = CIImage(cvImageBuffer: imageBuffer)
                    
                    // 6. Scale the mask to match the size of the original image.
                    let scaleX = ciImage.extent.width / maskImage.extent.width
                    let scaleY = ciImage.extent.height / maskImage.extent.height
                    maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                    
                    //------ Working draw mask after transform
                    let rep: NSCIImageRep = NSCIImageRep(ciImage: maskImage) //Render the mask image which looks good...
                    let mask_nsImage: NSImage = NSImage(size: rep.size)
                    mask_nsImage.addRepresentation(rep)

                    DispatchQueue.main.async {
                        self.personMaskImageView_maskImage.image = mask_nsImage
                    }
                    //------
                } catch {
                    print("Failed to perform Vision request: \(error.localizedDescription)")
                    return
                }
            }
        }
        let segmentationRequest = VNGeneratePersonSegmentationRequest { request, error in
            for observation in request.results as! [VNPixelBufferObservation] {
                print("segmentationRequest = \(observation)")
                DispatchQueue.main.async {
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        return
                    }
                    let ciImage = CIImage(cvImageBuffer: imageBuffer)
                    
                    self.processAndDrawMask(observation: observation, on: ciImage)
                }
            }
        }
        
        let imageRequestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
        // Keep the real-time path deliberately narrow. Rectangles, hands,
        // faces, saliency, and semantic models run through lower-rate services.
        var requests: [VNRequest] = []
        if shouldUpdateSceneSnapshot {
            requests.append(calibrationBarcodeRequest)
        }
        let pose3DTime = CACurrentMediaTime()
        if self.pose3DEnabled,
           pose3DTime - self.last3DPoseProcessingUpdate >= 1 / self.pose3DFPS {
            self.last3DPoseProcessingUpdate = pose3DTime
            requests.append(self.humanBodyPose3DRequest)
        }
        try? imageRequestHandler.perform(requests)
        }
    }

    func cameraManager(
        _ manager: CameraManagerProtocol,
        didChange state: CameraSourceState,
        detail: String?
    ) {
        cameraStatusState = state
        cameraStatusDetail = detail
        cameraStatusChangedAt = Date()
        videoServer?.updateCameraState(state)
        ROBSceneSnapshotStore.shared.updateCameraState(state.rawValue)
        if state != .streamingRGBD {
            robMainViewController?.clearAlignedDepthFrame()
        }
        if let detail, !detail.isEmpty {
            print("Camera state \(state.rawValue): \(detail)")
        } else {
            print("Camera state \(state.rawValue)")
        }
    }
    
    func processAndDrawMask(observation: VNPixelBufferObservation, on originalCIImage: CIImage) {
            let maskPixelBuffer = observation.pixelBuffer

            // Create a CIImage from the segmentation mask.
            let maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)

            // The mask is the same size as the observation, not necessarily the original image.
            // Scale the mask to match the original image size.
            let scaleX = originalCIImage.extent.width / maskImage.extent.width
            let scaleY = originalCIImage.extent.height / maskImage.extent.height
            let scaledMaskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            // Create a Core Image filter to blend the mask with the original image.
            let filter = CIFilter(name: "CISourceOverCompositing")
            filter?.setValue(scaledMaskImage, forKey: kCIInputImageKey)
            filter?.setValue(originalCIImage, forKey: kCIInputBackgroundImageKey)
            
            // Get the final output image.
            guard let outputCIImage = filter?.outputImage else {
                print("Error: Could not get output CIImage.")
                return
            }

            // 5. Convert CIImage to NSImage and display it.
            let context = CIContext(options: nil)
            if let cgImageResult = context.createCGImage(outputCIImage, from: outputCIImage.extent) {
                let finalImage = NSImage(cgImage: cgImageResult, size: CGSizeMake(originalCIImage.extent.width, originalCIImage.extent.height))
                self.personMaskImageView.image = finalImage
            }
        }
}


// MARK: - Redraws the skeleton upon model change.
func connectNodeToParent(joint: VNHumanBodyPose3DObservation.JointName, observation: VNHumanBodyPose3DObservation,
                         nodeJointDict: [VNHumanBodyPose3DObservation.JointName: SCNNode], _ viewModel: HumanBodyPose3DDetector) {
    if let parentJointName = observation.parentJointName(joint), let node = nodeJointDict[joint] {
        guard let parentNode = nodeJointDict[parentJointName] else {
            return
        }
        updateLineNode(node: node,
                       joint: joint,
                       fromPoint: node.simdPosition,
                       toPoint: parentNode.simdPosition,
                       detector: viewModel,
                       observation: observation)
    }
}

func updateLineNode(node: SCNNode,
                    joint: VNHumanBodyPose3DObservation.JointName,
                    fromPoint: simd_float3,
                    toPoint: simd_float3,
                    originalCubeWidth: Float = 0.05,
                    detector: HumanBodyPose3DDetector,
                    observation: VNHumanBodyPose3DObservation) {
    // Determine the distance between the child and parent nodes.
    let length = max(simd_length(toPoint - fromPoint), 1E-5)
    
    // The distance between the child and parent nodes serves as the length of the limb node geometry.
    let boxGeometry = SCNBox(width: CGFloat(Float(originalCubeWidth)),
                             height: CGFloat(Float(length)),
                             length: CGFloat(originalCubeWidth),
                             chamferRadius: 0.05)
    node.geometry = boxGeometry
    node.geometry?.firstMaterial?.diffuse.contents = NSColor(ciColor: .red)
    
    // The node is positioned between the child and parent nodes.
    node.simdPosition = (toPoint + fromPoint) / 2
    node.simdEulerAngles = detector.calculateLocalAngleToParent(joint: joint, observation: observation)
}

extension VNHumanBodyPoseObservation {
    func getJointPoints(for size: NSSize) -> [CGPoint] {
        var points: [CGPoint] = []
        let joints = availableJointNames
        
        for jointName in joints {
            if let recognizedPoint = try? recognizedPoint(jointName), recognizedPoint.confidence > 0.1 {
                // Convert normalized point to image coordinates
                let visionPoint = recognizedPoint.location
                var cgPoint = VNImagePointForNormalizedPoint(visionPoint, Int(size.width), Int(size.height))
                
                // Adjust for different coordinate systems (Vision's bottom-left vs AppKit's top-left)
                cgPoint.y = size.height - cgPoint.y
                points.append(cgPoint)
            }
        }
        return points
    }
}

struct BodyJoints {
    static let links: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.neck, .rightShoulder),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.neck, .leftShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.rightShoulder, .rightHip),
        (.leftShoulder, .leftHip),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.rightHip, .leftHip)
    ]
}

class PoseDrawingView: NSView {
    var role: CameraRole = .face
    var humanHandPose_observations: [VNHumanHandPoseObservation] = []
    var humanRect_observations: [VNHumanObservation] = []
    var bodyPose_observations: [VNHumanBodyPoseObservation] = []
    var clearScreenTimer: Timer = Timer()
    var kClearScreenTimeInterval = 1.0
    var dynamicDetectorOutput: ROBDetectorOutput?
    fileprivate var swordTrack: ROBSwordTrack?
    fileprivate var swordTrackingStatus: String?
    fileprivate var projectedPose3D: ROBProjectedPose3D?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeDynamicDetectors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeDynamicDetectors()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func observeDynamicDetectors() {
        NotificationCenter.default.addObserver(self, selector: #selector(dynamicDetectorChanged(_:)),
                                               name: .robDetectorOutputDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dynamicDetectorSettingChanged(_:)),
                                               name: .robDetectorSettingsDidChange, object: nil)
    }

    @objc private func dynamicDetectorChanged(_ notification: Notification) {
        guard let output = notification.userInfo?["output"] as? ROBDetectorOutput,
              output.source == .mainCamera else { return }
        dynamicDetectorOutput = output
        needsDisplay = true
    }

    @objc private func dynamicDetectorSettingChanged(_ notification: Notification) {
        guard let source = notification.userInfo?["source"] as? ROBDetectorSource,
              source == .mainCamera,
              notification.userInfo?["enabled"] as? Bool == false else { return }
        if notification.userInfo?["detector"] as? String == "body-pose" {
            bodyPose_observations = []
            humanHandPose_observations = []
        }
        dynamicDetectorOutput = nil
        needsDisplay = true
    }
    
    @objc func clearScreen() {
        self.humanHandPose_observations = []
        self.humanRect_observations = []
        self.bodyPose_observations = []
        self.swordTrack = nil
        self.setNeedsDisplay(self.bounds)
    }
    
    let fingerJoints: [[VNHumanHandPoseObservation.JointName]] = [
            [.thumbCMC, .thumbMP, .thumbIP, .thumbTip],
            [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
            [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
            [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
            [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
        ]
        
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        clearScreenTimer.invalidate()
        clearScreenTimer = Timer.scheduledTimer(timeInterval: kClearScreenTimeInterval, target: self, selector: #selector(clearScreen), userInfo: nil, repeats: false)
         
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        context.setLineWidth(4.0)
        
        //VNHumanHandPoseObservation
        for observation in humanHandPose_observations {
            guard let recognizedPoints = try? observation.recognizedPoints(.all) else { continue }
            
            let pointMap = recognizedPoints.filter { $0.value.confidence > 0.1 }.mapValues {
                // Convert normalized Vision coordinates to image-sized coordinates
                let cgPoint = VNImagePointForNormalizedPoint($0.location, Int(bounds.width), Int(bounds.height))
                return cgPoint
            }
            
            // Draw the connecting lines
            for finger in fingerJoints {
                let path = CGMutablePath()
                var firstPoint = true
                for jointName in finger {
                    if let point = pointMap[jointName] {
                        if firstPoint {
                            path.move(to: point)
                            firstPoint = false
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                context.addPath(path)
            }
            
            // Draw the points (circles)
            for point in pointMap.values {
                context.addEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            }
            
            context.setStrokeColor(CGColor(red: 1.0, green: 0, blue: 0, alpha: 1.0))
            context.setFillColor(CGColor(red: 1.0, green: 0, blue: 0, alpha: 1.0))
            context.setLineWidth(3.0)
            context.strokePath()
            context.fillPath()
        }
        
        // VNHumanObservation
        for observation in humanRect_observations {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            
            // Set up the drawing attributes.
            context.setStrokeColor(NSColor.red.cgColor)
            context.setLineWidth(2.0)

            let boundingBox = observation.boundingBox
            
            // Convert normalized coordinates to the view's coordinates.
            let rectInViewSpace = CGRect(
                x: boundingBox.origin.x * bounds.width,
                y: boundingBox.origin.y * bounds.height,
                width: boundingBox.size.width * bounds.width,
                height: boundingBox.size.height * bounds.height
            )
            
            // Draw the bounding box.
            context.stroke(rectInViewSpace)
        }
        
        // VNHumanBodyPose 2D
        context.setStrokeColor(NSColor.green.cgColor)
        
        for observation in bodyPose_observations {
            let bodyPoints = observation.getJointPoints(for: bounds.size)
            
            // Draw connections (lines)
            for (joint1Name, joint2Name) in BodyJoints.links {
                if let point1 = try? observation.recognizedPoint(joint1Name),
                   let point2 = try? observation.recognizedPoint(joint2Name),
                   point1.confidence > 0.1, point2.confidence > 0.1 {
                    
                    var cgPoint1 = VNImagePointForNormalizedPoint(point1.location, Int(bounds.width), Int(bounds.height))
                    cgPoint1.y = bounds.height - cgPoint1.y
                    
                    var cgPoint2 = VNImagePointForNormalizedPoint(point2.location, Int(bounds.width), Int(bounds.height))
                    cgPoint2.y = bounds.height - cgPoint2.y
                    
                    let fixed_cgPoint1 = cgPoint1.translateFromCoreImageToUIKitCoordinateSpace(using: bounds.height)
                    let fixed_cgPoint2 = cgPoint2.translateFromCoreImageToUIKitCoordinateSpace(using: bounds.height)
                    
                    context.move(to: fixed_cgPoint1)
                    context.addLine(to: fixed_cgPoint2)
                    context.strokePath()
                }
            }
            
            // Draw joints (circles)
            context.setFillColor(NSColor.red.cgColor)
            for point in bodyPoints {
                let fixed_point = point.translateFromCoreImageToUIKitCoordinateSpace(using: bounds.height)
                let rect = NSRect(x: fixed_point.x - 5, y: fixed_point.y - 5, width: 10, height: 10)
                context.fillEllipse(in: rect)
            }
        }

        if let swordTrack {
            let grip = CGPoint(x: swordTrack.grip.x * bounds.width, y: swordTrack.grip.y * bounds.height)
            let tip = CGPoint(x: swordTrack.tip.x * bounds.width, y: swordTrack.tip.y * bounds.height)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 5, color: NSColor.black.cgColor)
            context.setStrokeColor(NSColor.systemCyan.cgColor)
            context.setLineWidth(7)
            context.setLineCap(.round)
            context.move(to: grip); context.addLine(to: tip); context.strokePath()
            context.setFillColor(NSColor.systemOrange.cgColor)
            context.fillEllipse(in: CGRect(x: grip.x - 7, y: grip.y - 7, width: 14, height: 14))
            context.setFillColor(NSColor.systemCyan.cgColor)
            context.fillEllipse(in: CGRect(x: tip.x - 5, y: tip.y - 5, width: 10, height: 10))
            context.restoreGState()
            ("sword \(Int(swordTrack.confidence * 100))%" as NSString).draw(
                at: CGPoint(x: tip.x + 8, y: tip.y + 8),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                                 .foregroundColor: NSColor.systemCyan,
                                 .backgroundColor: NSColor.black.withAlphaComponent(0.7)])
        }
        if let swordTrackingStatus {
            (swordTrackingStatus as NSString).draw(
                at: CGPoint(x: 18, y: bounds.height - 28),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                                 .foregroundColor: swordTrack == nil ? NSColor.systemYellow : NSColor.systemGreen,
                                 .backgroundColor: NSColor.black.withAlphaComponent(0.72)])
        }
        if let projectedPose3D {
            context.saveGState()
            context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(3)
            for line in projectedPose3D.lines {
                context.move(to: CGPoint(x: line.0.x * bounds.width, y: line.0.y * bounds.height))
                context.addLine(to: CGPoint(x: line.1.x * bounds.width, y: line.1.y * bounds.height))
                context.strokePath()
            }
            context.setFillColor(NSColor.systemBlue.cgColor)
            for point in projectedPose3D.points {
                context.fillEllipse(in: CGRect(x: point.x * bounds.width - 4,
                                               y: point.y * bounds.height - 4,
                                               width: 8, height: 8))
            }
            context.restoreGState()
            ("3D projected \(Int(projectedPose3D.confidence * 100))%" as NSString).draw(
                at: CGPoint(x: 18, y: bounds.height - 48),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                                 .foregroundColor: NSColor.systemBlue,
                                 .backgroundColor: NSColor.black.withAlphaComponent(0.7)])
        }

        if role == .face, let output = dynamicDetectorOutput {
            context.setStrokeColor(NSColor.systemGreen.cgColor)
            context.setLineWidth(2)
            for line in output.lines {
                context.move(to: CGPoint(x: line.x1 * bounds.width, y: line.y1 * bounds.height))
                context.addLine(to: CGPoint(x: line.x2 * bounds.width, y: line.y2 * bounds.height))
                context.strokePath()
            }
            for point in output.points {
                let p = CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
                context.setFillColor(NSColor.systemOrange.cgColor)
                context.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                ("\(point.label) \(Int(point.confidence * 100))%" as NSString).draw(
                    at: CGPoint(x: p.x + 6, y: p.y + 5),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                                     .foregroundColor: NSColor.white,
                                     .backgroundColor: NSColor.black.withAlphaComponent(0.65)])
            }
        }

        // Render Chessboard & Pieces overlays (Face camera only)
        if role == .face {
            let snapshot = ROBSceneSnapshotStore.shared.snapshot()
            let pieces = snapshot.chessPieces
            
            context.saveGState()
            let statusText: String
            let textColor: NSColor
            if !pieces.isEmpty {
                statusText = "CHESSBOARD DETECTED (\(pieces.count) pieces visible)"
                textColor = .systemGreen
                
                // Draw a small orange bounding circle/label for each detected chess piece in the 2D view!
                // Since our YOLO Spatial Chess model gives us 3D coordinates (x, y, z) in meters relative to the camera,
                // we perform a real-time 3D perspective projection to overlay them precisely onto the 2D view!
                for piece in pieces {
                    // Simple perspective projection:
                    // Screen X = centerX + (piece.x / piece.z * scale)
                    // Screen Y = centerY + (piece.y / piece.z * scale)
                    let scale: CGFloat = bounds.width * 0.8
                    let projX = (bounds.width / 2.0) + CGFloat(piece.x / piece.z) * scale
                    let projY = (bounds.height / 2.0) - CGFloat(piece.y / piece.z) * scale
                    
                    if projX >= 0, projX <= bounds.width, projY >= 0, projY <= bounds.height {
                        context.setStrokeColor(NSColor.systemOrange.cgColor)
                        context.setLineWidth(2.0)
                        context.strokeEllipse(in: CGRect(x: projX - 16, y: projY - 16, width: 32, height: 32))
                        
                        let pieceLabel = piece.type.replacingOccurrences(of: "_", with: " ").capitalized as NSString
                        pieceLabel.draw(
                            at: CGPoint(x: projX - 14, y: projY + 20),
                            withAttributes: [
                                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                                .foregroundColor: NSColor.systemOrange,
                                .backgroundColor: NSColor.black.withAlphaComponent(0.65)
                            ]
                        )
                    }
                }
            } else {
                statusText = "NO CHESSBOARD SEEN (Searching...)"
                textColor = .systemOrange
            }
            
            let nsText = "[OAK-D CNN: \(statusText)]" as NSString
            nsText.draw(
                at: CGPoint(x: 15, y: bounds.height - 25),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: textColor,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.7)
                ]
            )
            context.restoreGState()
        }

        // Render sidewalk centerline path overlay (Belly camera only)
        let settings = ROBMainCameraProcessingSettings.shared
        if role == .belly, settings.bellySidewalkOverlayEnabled {
            let snapshot = ROBSceneSnapshotStore.shared.snapshot()
            let confidence = snapshot.sidewalkConfidence
            let deviation = snapshot.sidewalkCenterDeviation

            // Draw a permanent diagnostic status overlay at the top left of the preview
            context.saveGState()
            let statusText: String
            let textColor: NSColor
            if confidence >= 0.5 {
                statusText = "SIDEWALK PATH DETECTED (Dev: \(String(format: "%.2f", deviation)), Conf: \(Int(confidence * 100))%)"
                textColor = .systemGreen
            } else {
                statusText = "NON-SIDEWALK TERRAIN (Searching...)"
                textColor = .systemOrange
            }
            let nsText = "[OAK-D CNN: \(statusText)]" as NSString
            nsText.draw(
                at: CGPoint(x: 15, y: bounds.height - 25),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: textColor.withAlphaComponent(CGFloat(settings.bellySidewalkOverlayOpacity)),
                    .backgroundColor: NSColor.black.withAlphaComponent(0.7 * CGFloat(settings.bellySidewalkOverlayOpacity))
                ]
            )
            context.restoreGState()

            if confidence >= 0.5 {
                let deviation = snapshot.sidewalkCenterDeviation // between -1.0 and 1.0
                let confidence = snapshot.sidewalkConfidence
                
                context.saveGState()
                
                // Map the normalized deviation (-1.0 to 1.0) to x-coordinate in view bounds
                let centerX = bounds.width / 2.0
                let targetX = centerX + CGFloat(deviation) * (bounds.width / 2.0)
                
                // Draw a beautiful vertical guideline / path representing the sidewalk center-line
                context.setStrokeColor(NSColor.systemGreen.withAlphaComponent(CGFloat(settings.bellySidewalkOverlayOpacity)).cgColor)
                context.setLineWidth(12.0)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                
                // Draw a vertical guideline on the bottom 60% of the frame (forward lane prediction)
                context.move(to: CGPoint(x: targetX, y: 0))
                context.addLine(to: CGPoint(x: targetX, y: bounds.height * 0.6))
                context.strokePath()
                
                // Draw a small target/crosshair representing the centered point
                context.setFillColor(NSColor.systemGreen.withAlphaComponent(CGFloat(settings.bellySidewalkOverlayOpacity)).cgColor)
                context.fillEllipse(in: CGRect(x: targetX - 8, y: bounds.height * 0.3 - 8, width: 16, height: 16))
                
                // Draw a nice text label
                let text = "Sidewalk: \(Int(confidence * 100))%" as NSString
                text.draw(
                    at: CGPoint(x: targetX + 12, y: bounds.height * 0.3 - 6),
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: NSColor.systemGreen,
                        .backgroundColor: NSColor.black.withAlphaComponent(0.6 * CGFloat(settings.bellySidewalkOverlayOpacity))
                    ]
                )
                
                context.restoreGState()
            }
        }
    }
}

extension CGPoint {
    func translateFromCoreImageToUIKitCoordinateSpace(using height: CGFloat) -> CGPoint {
        let transform = CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -height);
        
        return self.applying(transform)
    }
}
