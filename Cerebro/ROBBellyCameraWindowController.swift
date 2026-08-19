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
        
        let manager = CameraManager(containerView: containerView, role: .belly)
        manager.delegate = self
        self.bellyCameraManager = manager
        
        manager.setPreviewVisible(false)
        reconcileCameraSession()
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
        guard let depth = frameSet.alignedDepth else { return }
        let hologramFrame = ROBDepthCloudFrame(depth: depth, rgbSampleBuffer: frameSet.rgbSampleBuffer, isBelly: true)
        NotificationCenter.default.post(
            name: .ROBDepthCloudFrame,
            object: hologramFrame
        )
    }
}
