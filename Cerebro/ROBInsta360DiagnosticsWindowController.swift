import AppKit
import Foundation
import UniformTypeIdentifiers

@objcMembers public final class ROBInsta360DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    private let service = ROBInsta360CameraService.shared
    private let imageView = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let metricsLabel = NSTextField(labelWithString: "")
    private let restartButton = NSButton(title: "Apply Preview Settings", target: nil, action: nil)
    private let stabilizationToggle = NSButton(checkboxWithTitle: "Gyro stabilization", target: nil, action: nil)
    private let modelProgress = NSProgressIndicator()
    private let modelStatusLabel = NSTextField(labelWithString: "MLX model: preparing…")
    private let mainCameraDetectionToggle = NSButton(checkboxWithTitle: "Analyze main live-feed camera", target: nil, action: nil)
    private let insta360DetectionToggle = NSButton(checkboxWithTitle: "Analyze Insta360 preview", target: nil, action: nil)
    private let showInferenceToggle = NSButton(checkboxWithTitle: "Show MLX inference output", target: nil, action: nil)
    private let inferenceOutput = NSTextView()
    private let inferenceScroll = NSScrollView()
    private let detectionOverlay = ROBDetectionOverlayView()
    private let mainPoseToggle = NSButton(checkboxWithTitle: "Main pose", target: nil, action: nil)
    private let instaPoseToggle = NSButton(checkboxWithTitle: "360° pose overlay", target: nil, action: nil)
    private let mainObjectsToggle = NSButton(checkboxWithTitle: "Main object labels", target: nil, action: nil)
    private let instaObjectsToggle = NSButton(checkboxWithTitle: "360° object labels", target: nil, action: nil)
    private let addModelButton = NSButton(title: "Add Core ML Model…", target: nil, action: nil)
    private let analysisGeometryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mainFPSPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let instaFPSPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let processingRates: [Double] = [0, 0.25, 0.5, 1, 2, 5, 10]

    public init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Insta360 Stream Diagnostics"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        configure(window)
        NotificationCenter.default.addObserver(self, selector: #selector(serviceChanged(_:)),
                                               name: .robInsta360CameraServiceDidChange, object: service)
        NotificationCenter.default.addObserver(self, selector: #selector(mlxChanged(_:)),
                                               name: .robMLXRuntimeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(detectorOutputChanged(_:)),
                                               name: .robDetectorOutputDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(detectorSettingNotification(_:)),
                                               name: .robDetectorSettingsDidChange, object: nil)
        refresh()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        service.setDiagnosticsPreviewVisible(true)
        window?.makeKeyAndOrderFront(sender)
        refresh()
    }

    public func windowWillClose(_ notification: Notification) {
        service.setDiagnosticsPreviewVisible(false)
    }

    private func configure(_ window: NSWindow) {
        let content = NSView()
        window.contentView = content
        stateLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        urlLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        metricsLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        modelProgress.minValue = 0
        modelProgress.maxValue = 1
        modelProgress.isIndeterminate = true
        modelProgress.style = .bar
        modelStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modelStatusLabel.textColor = .secondaryLabelColor
        let modelRow = NSStackView(views: [modelStatusLabel, modelProgress])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8
        mainCameraDetectionToggle.target = self
        mainCameraDetectionToggle.action = #selector(detectionSettingChanged(_:))
        insta360DetectionToggle.target = self
        insta360DetectionToggle.action = #selector(detectionSettingChanged(_:))
        showInferenceToggle.target = self
        showInferenceToggle.action = #selector(detectionSettingChanged(_:))
        let detectionRow = NSStackView(views: [mainCameraDetectionToggle, insta360DetectionToggle, showInferenceToggle])
        detectionRow.orientation = .horizontal
        detectionRow.spacing = 16
        inferenceOutput.isEditable = false
        inferenceOutput.isSelectable = true
        inferenceOutput.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        inferenceOutput.backgroundColor = .textBackgroundColor
        inferenceOutput.string = "Waiting for the first MLX vision inference…"
        inferenceScroll.documentView = inferenceOutput
        inferenceScroll.hasVerticalScroller = true
        inferenceScroll.borderType = .bezelBorder
        restartButton.target = self
        restartButton.action = #selector(restart(_:))
        stabilizationToggle.target = self
        stabilizationToggle.action = #selector(stabilizationChanged(_:))
        // Diagnostic/show mode favors using every available pixel. A 360°
        // equirectangular feed is intentionally wide, and this keeps the
        // preview attached to every window edge while the operator resizes it.
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        detectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(detectionOverlay)
        NSLayoutConstraint.activate([
            detectionOverlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            detectionOverlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            detectionOverlay.topAnchor.constraint(equalTo: imageView.topAnchor),
            detectionOverlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
        ])
        for toggle in [mainPoseToggle, instaPoseToggle, mainObjectsToggle, instaObjectsToggle] {
            toggle.target = self; toggle.action = #selector(detectorSettingChanged(_:))
        }
        addModelButton.target = self; addModelButton.action = #selector(addCoreMLModel(_:))
        analysisGeometryPopup.addItems(withTitles: ["Full stitched panorama", "Six detector sectors"])
        analysisGeometryPopup.target = self
        analysisGeometryPopup.action = #selector(analysisGeometryChanged(_:))
        analysisGeometryPopup.toolTip = "Six sectors are derived locally from the stitched stream; this is not six native Pro II sensor streams."
        let geometryLabel = NSTextField(labelWithString: "360° analysis:")
        let geometryNote = NSTextField(labelWithString: "Network: one stitched RTMP feed")
        geometryNote.textColor = .secondaryLabelColor
        let geometryRow = NSStackView(views: [geometryLabel, analysisGeometryPopup, geometryNote])
        geometryRow.orientation = .horizontal; geometryRow.spacing = 8
        for popup in [mainFPSPopup, instaFPSPopup] {
            popup.addItems(withTitles: ["Off", "0.25 FPS", "0.5 FPS", "1 FPS", "2 FPS", "5 FPS", "10 FPS"])
            popup.target = self; popup.action = #selector(processingFPSChanged(_:))
        }
        let rateNote = NSTextField(labelWithString: "Ceiling; slow MLX requests never overlap")
        rateNote.textColor = .secondaryLabelColor
        let rateRow = NSStackView(views: [NSTextField(labelWithString: "Main analysis:"), mainFPSPopup,
                                          NSTextField(labelWithString: "Insta360 analysis:"), instaFPSPopup, rateNote])
        rateRow.orientation = .horizontal; rateRow.spacing = 8
        let detectorRow = NSStackView(views: [mainPoseToggle, instaPoseToggle, mainObjectsToggle, instaObjectsToggle, addModelButton])
        detectorRow.orientation = .horizontal; detectorRow.spacing = 12
        let previewStatus = NSStackView(views: [stateLabel, urlLabel])
        previewStatus.orientation = .vertical
        previewStatus.alignment = .leading
        previewStatus.spacing = 3
        let statusFooter = NSStackView(views: [previewStatus, NSView(), stabilizationToggle, restartButton])
        statusFooter.orientation = .horizontal
        statusFooter.alignment = .centerY
        statusFooter.spacing = 12

        let analysisOptions = NSStackView(views: [detectionRow, rateRow, geometryRow, detectorRow])
        analysisOptions.translatesAutoresizingMaskIntoConstraints = false
        analysisOptions.orientation = .vertical
        analysisOptions.alignment = .leading
        analysisOptions.spacing = 8
        let analysisBox = NSBox()
        analysisBox.title = "Analysis Options"
        analysisBox.boxType = .primary
        analysisBox.contentView = analysisOptions

        let mlxOptions = NSStackView(views: [modelRow, inferenceScroll])
        mlxOptions.translatesAutoresizingMaskIntoConstraints = false
        mlxOptions.orientation = .vertical
        mlxOptions.alignment = .leading
        mlxOptions.spacing = 8
        let mlxBox = NSBox()
        mlxBox.title = "MLX Status and Output"
        mlxBox.boxType = .primary
        mlxBox.contentView = mlxOptions

        // The video is intentionally first and touches the top content margin.
        // Status and configuration no longer reduce its upper viewing area.
        let stack = NSStackView(views: [imageView, metricsLabel, analysisBox, mlxBox, statusFooter])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            statusFooter.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewStatus.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            analysisBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            mlxBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelProgress.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            detectionRow.widthAnchor.constraint(equalTo: analysisOptions.widthAnchor),
            rateRow.widthAnchor.constraint(equalTo: analysisOptions.widthAnchor),
            geometryRow.widthAnchor.constraint(equalTo: analysisOptions.widthAnchor),
            detectorRow.widthAnchor.constraint(equalTo: analysisOptions.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: mlxOptions.widthAnchor),
            inferenceScroll.widthAnchor.constraint(equalTo: mlxOptions.widthAnchor),
            inferenceScroll.heightAnchor.constraint(equalToConstant: 82)
        ])
    }

    @objc private func restart(_ sender: Any?) { service.restart() }
    @objc private func stabilizationChanged(_ sender: NSButton) {
        service.gyroStabilizationEnabled = sender.state == .on
    }
    @objc private func serviceChanged(_ notification: Notification) { refresh() }
    @objc private func mlxChanged(_ notification: Notification) { refreshMLX() }
    @objc private func detectionSettingChanged(_ sender: NSButton) {
        let runtime = ROBMLXRuntime.shared
        runtime.mainCameraDetectionEnabled = mainCameraDetectionToggle.state == .on
        runtime.insta360DetectionEnabled = insta360DetectionToggle.state == .on
        runtime.showInferenceOutput = showInferenceToggle.state == .on
        service.refreshDecoderDemand()
        refreshMLX()
    }
    @objc private func detectorSettingChanged(_ sender: NSButton) {
        let registry = ROBDynamicDetectorRegistry.shared
        if sender === mainPoseToggle {
            registry.setEnabled(sender.state == .on, detector: "body-pose", source: .mainCamera)
        } else if sender === instaPoseToggle {
            registry.setEnabled(sender.state == .on, detector: "body-pose", source: .insta360)
        } else if sender === mainObjectsToggle {
            registry.setEnabled(sender.state == .on, detector: "generic-objects", source: .mainCamera)
        } else if sender === instaObjectsToggle {
            registry.setEnabled(sender.state == .on, detector: "generic-objects", source: .insta360)
        }
        service.refreshDecoderDemand()
    }
    @objc private func analysisGeometryChanged(_ sender: NSPopUpButton) {
        ROBDynamicDetectorRegistry.shared.insta360AnalysisGeometry =
            sender.indexOfSelectedItem == 1 ? .sixSectors : .stitchedPanorama
        detectionOverlay.output = nil
    }
    @objc private func processingFPSChanged(_ sender: NSPopUpButton) {
        guard processingRates.indices.contains(sender.indexOfSelectedItem) else { return }
        let source: ROBDetectorSource = sender === mainFPSPopup ? .mainCamera : .insta360
        ROBDynamicDetectorRegistry.shared.setProcessingFramesPerSecond(
            processingRates[sender.indexOfSelectedItem], for: source)
        if source == .insta360 { service.refreshDecoderDemand() }
        if processingRates[sender.indexOfSelectedItem] == 0, source == .insta360 {
            detectionOverlay.output = nil
        }
    }
    @objc private func detectorOutputChanged(_ notification: Notification) {
        guard let output = notification.userInfo?["output"] as? ROBDetectorOutput,
              output.source == .insta360 else { return }
        detectionOverlay.output = output
    }
    @objc private func detectorSettingNotification(_ notification: Notification) {
        guard let source = notification.userInfo?["source"] as? ROBDetectorSource,
              source == .insta360,
              notification.userInfo?["enabled"] as? Bool == false else { return }
        detectionOverlay.output = nil
    }
    @objc private func addCoreMLModel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "mlmodel")!, .init(filenameExtension: "mlmodelc")!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ROBDynamicDetectorRegistry.shared.registerCoreMLModel(at: url) }
        catch { presentError(error) }
    }

    private func refresh() {
        stateLabel.stringValue = service.lastError.map { "\(service.state) — \($0)" } ?? service.state
        stabilizationToggle.state = service.gyroStabilizationEnabled ? .on : .off
        restartButton.isEnabled = service.previewSettingsPending
        restartButton.title = service.previewSettingsPending ? "Apply Preview Settings" : "Preview Settings Applied"
        urlLabel.stringValue = service.streamURL
        metricsLabel.stringValue = String(format: "Frames %llu   Decoded %@   FPS %.1f",
            service.framesReceived,
            ByteCountFormatter.string(fromByteCount: Int64(service.decodedBytes), countStyle: .file),
            service.framesPerSecond)
        let perception = ROBInsta360PerceptionService.shared
        if !perception.lastLabels.isEmpty {
            metricsLabel.stringValue += "   Items: " + perception.lastLabels.joined(separator: ", ")
        }
        if let frame = service.latestFrame { imageView.image = frame }
        refreshMLX()
    }

    private func refreshMLX() {
        Task {
            let diagnostics = await ROBMLXEngine.shared.diagnostics()
            await MainActor.run {
                let progress = diagnostics.downloadProgress
                self.modelProgress.isIndeterminate = progress == nil
                if progress == nil {
                    self.modelProgress.startAnimation(nil)
                } else {
                    self.modelProgress.stopAnimation(nil)
                    self.modelProgress.doubleValue = progress ?? 0
                }
                let percent = progress.map { " \(Int($0 * 100))%" } ?? ""
                self.modelStatusLabel.stringValue = "MLX model: " + (diagnostics.downloadDetail ?? diagnostics.state) + percent
                self.modelProgress.isHidden = progress == 1 && diagnostics.state == "ready"
                let runtime = ROBMLXRuntime.shared
                self.mainCameraDetectionToggle.state = runtime.mainCameraDetectionEnabled ? .on : .off
                self.insta360DetectionToggle.state = runtime.insta360DetectionEnabled ? .on : .off
                self.showInferenceToggle.state = runtime.showInferenceOutput ? .on : .off
                let registry = ROBDynamicDetectorRegistry.shared
                self.mainFPSPopup.selectItem(at: self.rateIndex(registry.processingFramesPerSecond(for: .mainCamera)))
                self.instaFPSPopup.selectItem(at: self.rateIndex(registry.processingFramesPerSecond(for: .insta360)))
                self.analysisGeometryPopup.selectItem(at: registry.insta360AnalysisGeometry.rawValue)
                self.mainPoseToggle.state = registry.enabled("body-pose", source: .mainCamera) ? .on : .off
                self.instaPoseToggle.state = registry.enabled("body-pose", source: .insta360) ? .on : .off
                self.mainObjectsToggle.state = registry.enabled("generic-objects", source: .mainCamera) ? .on : .off
                self.instaObjectsToggle.state = registry.enabled("generic-objects", source: .insta360) ? .on : .off
                self.inferenceScroll.isHidden = !runtime.showInferenceOutput
                if let output = diagnostics.lastVisionObservation, !output.isEmpty {
                    self.inferenceOutput.string = "Source: \(diagnostics.lastVisionSource ?? "unknown")\n\(output)"
                } else if let error = diagnostics.lastError, !error.isEmpty {
                    self.inferenceOutput.string = "MLX error: \(error)" +
                        (diagnostics.lastVisionRawFailure.map { "\nSanitized model response: \($0)" } ?? "")
                } else {
                    self.inferenceOutput.string = "Waiting for the first MLX vision inference…"
                }
            }
        }
    }

    private func rateIndex(_ fps: Double) -> Int {
        processingRates.enumerated().min(by: { abs($0.element - fps) < abs($1.element - fps) })?.offset ?? 0
    }
}
