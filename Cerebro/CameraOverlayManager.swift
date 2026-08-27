//
//  CameraOverlayManager.swift
//  Cerebro
//
//  Shared manager for rendering 2D skeleton pose and depth overlays over a camera preview.
//

import AppKit
import Foundation
import Vision
import AVFoundation

/// A compact, Objective-C-visible head/body observation shared by the main
/// camera and panoramic detector. Joint points are reduced before crossing the
/// controller boundary so the tracking loop never retains Vision requests or
/// camera buffers.
@objcMembers public final class ROBPersonTrackingObservation: NSObject {
    public let source: String
    public let headX: Double
    public let headY: Double
    public let boundsX: Double
    public let boundsY: Double
    public let boundsWidth: Double
    public let boundsHeight: Double
    public let confidence: Double
    public let capturedAtUptime: TimeInterval

    public init(
        source: String,
        headX: Double,
        headY: Double,
        boundsX: Double,
        boundsY: Double,
        boundsWidth: Double,
        boundsHeight: Double,
        confidence: Double,
        capturedAtUptime: TimeInterval
    ) {
        self.source = source
        self.headX = headX
        self.headY = headY
        self.boundsX = boundsX
        self.boundsY = boundsY
        self.boundsWidth = boundsWidth
        self.boundsHeight = boundsHeight
        self.confidence = confidence
        self.capturedAtUptime = capturedAtUptime
    }

    @nonobjc static func make(
        from observation: VNHumanBodyPoseObservation,
        source: String,
        xOffset: Double = 0,
        xScale: Double = 1,
        capturedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> ROBPersonTrackingObservation? {
        guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
        let bodyPoints = recognized.values.filter { $0.confidence >= 0.20 }
        guard bodyPoints.count >= 4 else { return nil }

        let mapped: (CGPoint) -> CGPoint = { point in
            CGPoint(x: xOffset + Double(point.x) * xScale, y: point.y)
        }
        let locations = bodyPoints.map { mapped($0.location) }
        let minX = locations.map(\.x).min() ?? 0
        let maxX = locations.map(\.x).max() ?? 0
        let minY = locations.map(\.y).min() ?? 0
        let maxY = locations.map(\.y).max() ?? 0
        guard maxX > minX, maxY > minY else { return nil }

        let headNames: [VNHumanBodyPoseObservation.JointName] = [
            .nose, .leftEye, .rightEye, .leftEar, .rightEar,
        ]
        let headPoints = headNames.compactMap { name -> VNRecognizedPoint? in
            guard let point = recognized[name], point.confidence >= 0.20 else { return nil }
            return point
        }
        let headLocation: CGPoint
        if !headPoints.isEmpty {
            let mappedHead = headPoints.map { mapped($0.location) }
            headLocation = CGPoint(
                x: mappedHead.map(\.x).reduce(0, +) / Double(mappedHead.count),
                y: mappedHead.map(\.y).reduce(0, +) / Double(mappedHead.count)
            )
        } else {
            let shoulders = [
                recognized[.leftShoulder], recognized[.rightShoulder],
            ].compactMap { point -> VNRecognizedPoint? in
                guard let point, point.confidence >= 0.20 else { return nil }
                return point
            }
            guard !shoulders.isEmpty else { return nil }
            let mappedShoulders = shoulders.map { mapped($0.location) }
            headLocation = CGPoint(
                x: mappedShoulders.map(\.x).reduce(0, +) / Double(mappedShoulders.count),
                y: min(1, mappedShoulders.map(\.y).reduce(0, +) / Double(mappedShoulders.count)
                    + max(0.08, (maxY - minY) * 0.18))
            )
        }

        let confidencePoints = headPoints.isEmpty ? bodyPoints : headPoints
        let confidence = confidencePoints.map { Double($0.confidence) }.reduce(0, +)
            / Double(confidencePoints.count)
        return ROBPersonTrackingObservation(
            source: source,
            headX: min(1, max(0, headLocation.x)),
            headY: min(1, max(0, headLocation.y)),
            boundsX: minX,
            boundsY: minY,
            boundsWidth: maxX - minX,
            boundsHeight: maxY - minY,
            confidence: confidence,
            capturedAtUptime: capturedAtUptime
        )
    }
}

@available(macOS 10.15, *)
@objcMembers final class CameraOverlayManager: NSObject {
    let depthOverlayView: NSImageView
    let poseView: PoseDrawingView
    var onBodyPoseDetected: (([VNHumanBodyPoseObservation]) -> Void)?
    
    private let depthOverlayRenderer = ROBDepthOverlayRenderer()
    private let visionAnalysisQueue = DispatchQueue(label: "com.orbitusrobotics.cerebro.realtime-pose-overlay", qos: .userInitiated)
    private let visionAdmissionLock = NSLock()
    private var visionAnalysisInFlight = false
    private var lastVisionProcessingUpdate: CFTimeInterval = 0
    
    private lazy var humanBodyPoseRequest: VNDetectHumanBodyPoseRequest = {
        VNDetectHumanBodyPoseRequest { [weak self] request, error in
            let observations = (request.results as? [VNHumanBodyPoseObservation]) ?? []
            DispatchQueue.main.async {
                self?.poseView.bodyPose_observations = observations
                self?.poseView.needsDisplay = true
                self?.onBodyPoseDetected?(observations)
            }
        }
    }()
    
    private lazy var humanHandPoseRequest: VNDetectHumanHandPoseRequest = {
        VNDetectHumanHandPoseRequest { [weak self] request, error in
            let observations = (request.results as? [VNHumanHandPoseObservation]) ?? []
            if let firstHand = observations.first,
               let indexTip = try? firstHand.recognizedPoint(.indexTip),
               indexTip.confidence > 0.3 {
                // CoreImage coordinate space has origin at bottom-left, top-right is (1,1).
                let normalizedPoint = CGPoint(x: indexTip.location.x, y: indexTip.location.y)
                ROBSceneSnapshotStore.shared.updateLatestIndexFingerPoint(normalizedPoint)
            }
            DispatchQueue.main.async {
                self?.poseView.humanHandPose_observations = observations
                self?.poseView.needsDisplay = true
            }
        }
    }()
    
    init(attachingTo parentView: NSView, role: CameraRole = .face, customPoseView: PoseDrawingView? = nil, customDepthOverlayView: NSImageView? = nil) {
        let resolvedPoseView = customPoseView ?? PoseDrawingView()
        resolvedPoseView.role = role
        self.poseView = resolvedPoseView
        self.depthOverlayView = customDepthOverlayView ?? NSImageView()
        super.init()
        
        // Setup Depth Overlay View
        if customDepthOverlayView == nil {
            depthOverlayView.imageScaling = .scaleProportionallyUpOrDown
            depthOverlayView.translatesAutoresizingMaskIntoConstraints = false
            depthOverlayView.isHidden = true
            parentView.addSubview(depthOverlayView)
            NSLayoutConstraint.activate([
                depthOverlayView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
                depthOverlayView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
                depthOverlayView.topAnchor.constraint(equalTo: parentView.topAnchor),
                depthOverlayView.bottomAnchor.constraint(equalTo: parentView.bottomAnchor)
            ])
        }
        
        // Setup Pose View
        if customPoseView == nil {
            poseView.translatesAutoresizingMaskIntoConstraints = false
            parentView.addSubview(poseView)
            NSLayoutConstraint.activate([
                poseView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
                poseView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
                poseView.topAnchor.constraint(equalTo: parentView.topAnchor),
                poseView.bottomAnchor.constraint(equalTo: parentView.bottomAnchor)
            ])
        }
    }
    
    func offer(
        sampleBuffer: CMSampleBuffer,
        depthFrame: CameraDepthFrame?,
        poseEnabled: Bool,
        depthOpacity: Double,
        processingFPS: Double
    ) {
        // 1. Process Depth overlay if available
        if let depth = depthFrame {
            depthOverlayRenderer.offer(depth: depth) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.depthOverlayView.alphaValue = CGFloat(depthOpacity)
                    self.depthOverlayView.image = image
                    self.depthOverlayView.isHidden = false
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.depthOverlayView.isHidden = true
            }
        }
        
        // 2. Process 2D human pose if enabled
        guard poseEnabled, processingFPS > 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.poseView.bodyPose_observations = []
                self?.poseView.humanHandPose_observations = []
                self?.poseView.needsDisplay = true
            }
            return
        }
        
        let visionProcessingTime = CACurrentMediaTime()
        guard visionProcessingTime - lastVisionProcessingUpdate >= 1 / processingFPS else { return }
        lastVisionProcessingUpdate = visionProcessingTime
        
        visionAdmissionLock.lock()
        guard !visionAnalysisInFlight else { visionAdmissionLock.unlock(); return }
        visionAnalysisInFlight = true
        visionAdmissionLock.unlock()
        
        visionAnalysisQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.visionAdmissionLock.lock()
                self.visionAnalysisInFlight = false
                self.visionAdmissionLock.unlock()
            }
            
            let imageRequestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
            var requests: [VNRequest] = []
            requests.append(self.humanBodyPoseRequest)
            requests.append(self.humanHandPoseRequest)
            
            try? imageRequestHandler.perform(requests)
        }
    }
}
