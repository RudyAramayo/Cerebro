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
        window?.makeKeyAndOrderFront(sender)
        refresh()
    }

    private func configure(_ window: NSWindow) {
        let content = NSView()
        window.contentView = content
        let heading = NSTextField(labelWithString: "Background camera service")
        heading.font = .boldSystemFont(ofSize: 17)
        let help = NSTextField(wrappingLabelWithString: "Cerebro owns the Pro 2 and receives this stream without the Insta360 Pro app. This window only observes the already-running background service; closing it does not interrupt robot vision.")
        help.textColor = .secondaryLabelColor
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
        let detectorRow = NSStackView(views: [mainPoseToggle, instaPoseToggle, mainObjectsToggle, instaObjectsToggle, addModelButton])
        detectorRow.orientation = .horizontal; detectorRow.spacing = 12
        let status = NSStackView(views: [stateLabel, NSView(), stabilizationToggle, restartButton])
        status.orientation = .horizontal
        let stack = NSStackView(views: [heading, help, status, urlLabel, imageView, metricsLabel, modelRow, detectionRow, geometryRow, detectorRow, inferenceScroll])
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
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            urlLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            modelRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelProgress.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            detectionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            geometryRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detectorRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inferenceScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inferenceScroll.heightAnchor.constraint(equalToConstant: 100)
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
    }
    @objc private func analysisGeometryChanged(_ sender: NSPopUpButton) {
        ROBDynamicDetectorRegistry.shared.insta360AnalysisGeometry =
            sender.indexOfSelectedItem == 1 ? .sixSectors : .stitchedPanorama
        detectionOverlay.output = nil
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
}
