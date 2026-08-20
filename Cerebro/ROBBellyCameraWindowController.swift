//
//  ROBBellyCameraWindowController.swift
//  Cerebro
//
//  Dedicated diagnostics window for the robot's Belly Camera.
//

import AppKit
import Foundation
import AVFoundation

@available(macOS 10.15, *)
@objcMembers public final class ROBBellyCameraWindowController: NSWindowController, NSWindowDelegate, CameraManagerDelegate {
    
    private var bellyCameraManager: CameraManagerProtocol?
    private let containerView = NSView()
    private var cameraViewIsVisible = false
    private var cameraSessionIsRequested = false
    private var overlayManager: CameraOverlayManager?
    private var hasSetAspectRatio = false
    private var isCalibrationRequested = false
    private let calibrateButton = NSButton()
    
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        
        window.title = "Belly Camera Diagnostics"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        
        configureContentView(for: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        setDiagnosticsPreviewVisible(true)
    }
    
    public func windowWillClose(_ notification: Notification) {
        setDiagnosticsPreviewVisible(false)
    }
    
    private func configureContentView(for window: NSWindow) {
        let contentView = window.contentView ?? NSView()
        containerView.frame = contentView.bounds
        containerView.autoresizingMask = [.width, .height]
        contentView.addSubview(containerView)
        
        self.overlayManager = CameraOverlayManager(attachingTo: containerView)
        
        let manager = CameraManager(containerView: containerView, role: .belly)
        manager.delegate = self
        self.bellyCameraManager = manager
        
        // Setup Calibrate Button
        calibrateButton.title = "Calibrate Camera (Chessboard)"
        calibrateButton.bezelStyle = .rounded
        calibrateButton.target = self
        calibrateButton.action = #selector(calibrateButtonClicked(_:))
        calibrateButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(calibrateButton, positioned: .above, relativeTo: nil)
        
        NSLayoutConstraint.activate([
            calibrateButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            calibrateButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            calibrateButton.widthAnchor.constraint(equalToConstant: 220),
            calibrateButton.heightAnchor.constraint(equalToConstant: 32)
        ])
        
        manager.setPreviewVisible(false)
        reconcileCameraSession()
    }
    
    @objc private func calibrateButtonClicked(_ sender: NSButton) {
        isCalibrationRequested = true
        sender.isEnabled = false
        sender.title = "Calibrating..."
    }
    
    public func setDiagnosticsPreviewVisible(_ isVisible: Bool) {
        cameraViewIsVisible = isVisible
        bellyCameraManager?.setPreviewVisible(isVisible)
        reconcileCameraSession()
    }
    
    private func reconcileCameraSession() {
        guard let bellyCameraManager else { return }
        let shouldRun = cameraViewIsVisible
        guard shouldRun != cameraSessionIsRequested else { return }
        do {
            if shouldRun {
                try bellyCameraManager.startSession()
            } else {
                try bellyCameraManager.stopSession()
            }
            cameraSessionIsRequested = shouldRun
        } catch {
            print("Belly Camera session error: \(error.localizedDescription)")
        }
    }
    
    public func toggleCamera() {
        guard let bellyCameraManager else { return }
        do {
            try bellyCameraManager.stopSession()
            try bellyCameraManager.startSession()
            cameraSessionIsRequested = true
        } catch {
            print(error.localizedDescription)
        }
    }
    
    public func bindCamera() {
        try? bellyCameraManager?.bindCamera()
    }
    
    public func bindCameraRebootSession() {
        try? bellyCameraManager?.bindCameraRebootSession()
    }
    
    // MARK: - CameraManagerDelegate
    
    func cameraManager(_ manager: CameraManagerProtocol, didOutput frameSet: CameraFrameSet) {
        if isCalibrationRequested {
            isCalibrationRequested = false
            if let depth = frameSet.alignedDepth, let intrinsics = frameSet.intrinsics {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        let rms = try ROBChessboardCalibration.performCalibration(
                            role: .belly,
                            rgbSampleBuffer: frameSet.rgbSampleBuffer,
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
                            alert.informativeText = String(format: "Successfully calibrated the Belly camera!\nSolved RMS Error: %.4f meters", rms)
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
            if let imageBuffer = CMSampleBufferGetImageBuffer(frameSet.rgbSampleBuffer) {
                let width = CGFloat(CVPixelBufferGetWidth(imageBuffer))
                let height = CGFloat(CVPixelBufferGetHeight(imageBuffer))
                if width > 0 && height > 0 {
                    hasSetAspectRatio = true
                    DispatchQueue.main.async { [weak self] in
                        self?.window?.contentAspectRatio = NSSize(width: width, height: height)
                    }
                }
            }
        }
        
        let mainCameraSettings = ROBMainCameraProcessingSettings.shared
        overlayManager?.offer(
            sampleBuffer: frameSet.rgbSampleBuffer,
            depthFrame: frameSet.alignedDepth,
            poseEnabled: mainCameraSettings.bellyPose2DEnabled,
            depthOpacity: mainCameraSettings.bellyDepthOverlayOpacity,
            processingFPS: ROBDynamicDetectorRegistry.shared.processingFramesPerSecond(for: .mainCamera)
        )
        
        guard let depth = frameSet.alignedDepth else { return }
        let hologramFrame = ROBDepthCloudFrame(depth: depth, rgbSampleBuffer: frameSet.rgbSampleBuffer, isBelly: true)
        NotificationCenter.default.post(
            name: .ROBDepthCloudFrame,
            object: hologramFrame
        )
    }
}
