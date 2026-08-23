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
    private var navigationDemandActive = false
    private var recordingDemandActive = false
    private var remoteVideoDemandActive = false
    private var cameraSessionIsRequested = false
    private var overlayManager: CameraOverlayManager?
    private var hasSetAspectRatio = false
    private var isCalibrationRequested = false
    private let calibrateButton = NSButton()
    private let avFoundationCameraLabel = NSTextField(labelWithString: "AVFoundation:")
    private let avFoundationCameraSelector = NSPopUpButton()
    
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        
        window.title = "Belly Camera Diagnostics"
        window.minSize = NSSize(width: 620, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        
        configureContentView(for: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        
        self.overlayManager = CameraOverlayManager(attachingTo: containerView, role: .belly)
        
        let manager = CameraManager(containerView: containerView, role: .belly)
        manager.delegate = self
        manager.recordingFrameHandler = { frameSet in
            ROBRecordingCoordinator.shared.offerCameraFrame(role: .belly, frameSet: frameSet)
        }
        manager.videoSampleHandler = { sampleBuffer in
            if #available(macOS 12.0, *) {
                ROBVideoServerRegistry.shared.offer(
                    cameraID: "belly",
                    sampleBuffer: sampleBuffer
                )
            }
        }
        self.bellyCameraManager = manager
        
        // Keep source selection and calibration in one non-overlapping row.
        calibrateButton.title = "Calibrate Camera (Chessboard)"
        calibrateButton.bezelStyle = .rounded
        calibrateButton.target = self
        calibrateButton.action = #selector(calibrateButtonClicked(_:))
        calibrateButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(calibrateButton, positioned: .above, relativeTo: nil)

        avFoundationCameraLabel.translatesAutoresizingMaskIntoConstraints = false
        avFoundationCameraLabel.toolTip = "Camera used when the Belly RGB-D source is unavailable."
        contentView.addSubview(avFoundationCameraLabel, positioned: .above, relativeTo: nil)

        avFoundationCameraSelector.target = self
        avFoundationCameraSelector.action = #selector(avFoundationCameraSelected(_:))
        avFoundationCameraSelector.translatesAutoresizingMaskIntoConstraints = false
        avFoundationCameraSelector.setAccessibilityLabel("Belly AVFoundation camera")
        contentView.addSubview(avFoundationCameraSelector, positioned: .above, relativeTo: nil)
        reloadAVFoundationCameraSelector()
        
        NSLayoutConstraint.activate([
            calibrateButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            calibrateButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            calibrateButton.widthAnchor.constraint(equalToConstant: 220),
            calibrateButton.heightAnchor.constraint(equalToConstant: 32),
            avFoundationCameraSelector.centerYAnchor.constraint(equalTo: calibrateButton.centerYAnchor),
            avFoundationCameraSelector.trailingAnchor.constraint(
                equalTo: calibrateButton.leadingAnchor,
                constant: -12
            ),
            avFoundationCameraSelector.widthAnchor.constraint(equalToConstant: 220),
            avFoundationCameraLabel.centerYAnchor.constraint(equalTo: calibrateButton.centerYAnchor),
            avFoundationCameraLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            avFoundationCameraLabel.trailingAnchor.constraint(
                equalTo: avFoundationCameraSelector.leadingAnchor,
                constant: -8
            )
        ])
        
        manager.setPreviewVisible(false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingDemandDidChange(_:)),
            name: .robRecordingDemandDidChange,
            object: ROBRecordingCoordinator.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteVideoDemandDidChange(_:)),
            name: .robVideoCameraDemandDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(avFoundationDevicesDidChange(_:)),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(avFoundationDevicesDidChange(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
        applyRecordingDemand()
        reconcileCameraSession()
    }
    
    @objc private func calibrateButtonClicked(_ sender: NSButton) {
        isCalibrationRequested = true
        sender.isEnabled = false
        sender.title = "Calibrating..."
    }

    @objc private func avFoundationCameraSelected(_ sender: NSPopUpButton) {
        bellyCameraManager?.selectAVFoundationCamera(
            uniqueID: sender.selectedItem?.representedObject as? String
        )
        reloadAVFoundationCameraSelector()
    }

    @objc private func avFoundationDevicesDidChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reloadAVFoundationCameraSelector() }
            return
        }
        reloadAVFoundationCameraSelector()
    }

    private func reloadAVFoundationCameraSelector() {
        guard let bellyCameraManager else { return }
        let cameras = bellyCameraManager.availableAVFoundationCameras()
        let selectedID = bellyCameraManager.selectedAVFoundationCameraID

        avFoundationCameraSelector.removeAllItems()
        avFoundationCameraSelector.addItem(withTitle: "Automatic")
        for camera in cameras {
            avFoundationCameraSelector.addItem(withTitle: camera.localizedName)
            avFoundationCameraSelector.lastItem?.representedObject = camera.uniqueID
        }

        if let selectedID {
            if let item = avFoundationCameraSelector.itemArray.first(where: {
                ($0.representedObject as? String) == selectedID
            }) {
                avFoundationCameraSelector.select(item)
            } else {
                avFoundationCameraSelector.addItem(withTitle: "Selected camera unavailable")
                avFoundationCameraSelector.lastItem?.representedObject = selectedID
                avFoundationCameraSelector.select(avFoundationCameraSelector.lastItem)
            }
        } else {
            avFoundationCameraSelector.selectItem(at: 0)
        }

        avFoundationCameraSelector.isEnabled = !cameras.isEmpty || selectedID != nil
        avFoundationCameraSelector.toolTip = "Belly-camera AVFoundation fallback: \(avFoundationCameraSelector.titleOfSelectedItem ?? "Automatic")"
    }
    
    public func setDiagnosticsPreviewVisible(_ isVisible: Bool) {
        cameraViewIsVisible = isVisible
        bellyCameraManager?.setPreviewVisible(isVisible)
        reconcileCameraSession()
    }

    /// Keeps RGB-D perception alive without opening the diagnostics window.
    /// This is enabled at runtime so manually driven terrain can be learned.
    public func setNavigationDemandActive(_ active: Bool) {
        navigationDemandActive = active
        reconcileCameraSession()
    }

    @objc private func recordingDemandDidChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.recordingDemandDidChange(notification) }
            return
        }
        applyRecordingDemand()
        reconcileCameraSession()
    }

    @objc private func remoteVideoDemandDidChange(_ notification: Notification) {
        guard notification.userInfo?[ROBVideoCameraDemandNotification.cameraIDKey]
                as? String == "belly",
              let active = notification.userInfo?[
                ROBVideoCameraDemandNotification.isActiveKey
              ] as? Bool else { return }
        remoteVideoDemandActive = active
        reconcileCameraSession()
    }

    private func applyRecordingDemand() {
        let demand = ROBRecordingCoordinator.shared.cameraCaptureDemand(for: .belly)
        recordingDemandActive = demand.active
        bellyCameraManager?.setCaptureResolutionOverride(demand.resolutionOverride)
    }
    
    private func reconcileCameraSession() {
        guard let bellyCameraManager else { return }
        let shouldRun = cameraViewIsVisible
            || navigationDemandActive
            || recordingDemandActive
            || remoteVideoDemandActive
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
    
    // MARK: - CameraManagerDelegate

    func cameraManager(
        _ manager: CameraManagerProtocol,
        didChange state: CameraSourceState,
        detail: String?
    ) {
        if #available(macOS 12.0, *) {
            ROBVideoServerRegistry.shared.updateCameraState(state, cameraID: "belly")
        }
    }
    
    func cameraManager(_ manager: CameraManagerProtocol, didOutput frameSet: CameraFrameSet) {
        ROBTraversabilityRuntime.shared.offer(frameSet: frameSet)
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

        // Road-navigation telemetry belongs to the belly camera role. The
        // current road model publishes no navigable sidewalk signal, so absent
        // values intentionally clear the shared signal instead of preserving
        // stale data or borrowing telemetry from the face camera.
        ROBSceneSnapshotStore.shared.updateSidewalkDetection(
            deviation: frameSet.sidewalkCenterDeviation ?? 0.0,
            confidence: frameSet.sidewalkConfidence ?? 0.0
        )
        
        let mainCameraSettings = ROBMainCameraProcessingSettings.shared
        overlayManager?.offer(
            sampleBuffer: frameSet.rgbSampleBuffer,
            depthFrame: frameSet.alignedDepth,
            poseEnabled: mainCameraSettings.bellyPose2DEnabled,
            depthOpacity: mainCameraSettings.bellyDepthOverlayEnabled ? mainCameraSettings.bellyDepthOverlayOpacity : 0.0,
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
