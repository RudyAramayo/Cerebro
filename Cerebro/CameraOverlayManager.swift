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
            DispatchQueue.main.async {
                self?.poseView.humanHandPose_observations = observations
                self?.poseView.needsDisplay = true
            }
        }
    }()
    
    init(attachingTo parentView: NSView, role: CameraRole = .face, customPoseView: PoseDrawingView? = nil, customDepthOverlayView: NSImageView? = nil) {
        self.poseView = customPoseView ?? PoseDrawingView()
        self.poseView.role = role
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
