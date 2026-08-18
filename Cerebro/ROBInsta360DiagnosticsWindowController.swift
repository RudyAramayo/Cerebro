import AppKit
import Foundation

/// Draws against the same horizontally stretched equirectangular bounds used
/// by the diagnostics image. Neutral degree ticks are always visible; the
/// robot-relative pair appears only for an effective, projection-matched
/// calibration. FRONT/REAR do not depend on unverified left/right handedness.
private final class ROBInsta360OrientationGuideView: NSView {
    private var calibratedForwardDegrees: Double?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func update(calibratedForwardDegrees: Double?) {
        let normalized = calibratedForwardDegrees.map(Self.normalizedDegrees)
        guard normalized != self.calibratedForwardDegrees else { return }
        self.calibratedForwardDegrees = normalized
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 1, bounds.height > 1 else { return }

        let rulerHeight: CGFloat = 28
        NSColor.black.withAlphaComponent(0.64).setFill()
        NSBezierPath(rect: NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: rulerHeight
        )).fill()

        // Both seams are labeled so the operator can confirm the full mapping
        // from 0° through 360°, including wraparound.
        let rulerTicks: [(Double, String)] = [
            (0, "0°"), (90, "90°"), (180, "180°"),
            (270, "270°"), (360, "360°")
        ]
        for (degrees, label) in rulerTicks {
            let x = xPosition(forDegrees: degrees)
            NSColor.white.withAlphaComponent(0.82).setStroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x, y: 0))
            tick.line(to: NSPoint(x: x, y: rulerHeight))
            tick.lineWidth = degrees == 0 || degrees == 360 ? 2 : 1
            tick.stroke()
            drawLabel(
                label,
                centeredAtX: x,
                top: 5,
                foreground: .white,
                background: .clear,
                font: .monospacedSystemFont(ofSize: 11, weight: .semibold)
            )
        }

        guard let forward = calibratedForwardDegrees else {
            drawLabel(
                "ORIENTATION UNCALIBRATED",
                centeredAtX: bounds.midX,
                top: rulerHeight + 8,
                foreground: .white,
                background: NSColor.systemRed.withAlphaComponent(0.82),
                font: .boldSystemFont(ofSize: 11)
            )
            return
        }

        drawDirectionMarker(
            label: "FRONT",
            degrees: forward,
            color: .systemGreen,
            labelTop: rulerHeight + 8
        )
        drawDirectionMarker(
            label: "REAR",
            degrees: Self.normalizedDegrees(forward + 180),
            color: .systemOrange,
            labelTop: rulerHeight + 34
        )
    }

    private func drawDirectionMarker(
        label: String,
        degrees: Double,
        color: NSColor,
        labelTop: CGFloat
    ) {
        let x = xPosition(forDegrees: degrees)
        color.withAlphaComponent(0.92).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: 0))
        line.line(to: NSPoint(x: x, y: bounds.maxY))
        line.lineWidth = 3
        line.stroke()
        drawLabel(
            String(format: "%@ %.0f°", label, degrees),
            centeredAtX: x,
            top: labelTop,
            foreground: .black,
            background: color.withAlphaComponent(0.92),
            font: .boldSystemFont(ofSize: 12)
        )
    }

    private func drawLabel(
        _ value: String,
        centeredAtX x: CGFloat,
        top: CGFloat,
        foreground: NSColor,
        background: NSColor,
        font: NSFont
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground
        ]
        let text = value as NSString
        let textSize = text.size(withAttributes: attributes)
        let hasBackground = background != .clear
        let horizontalPadding: CGFloat = hasBackground ? 6 : 2
        let verticalPadding: CGFloat = hasBackground ? 3 : 0
        let width = textSize.width + horizontalPadding * 2
        let height = textSize.height + verticalPadding * 2
        let originX = min(
            max(x - width / 2, bounds.minX + 2),
            max(bounds.minX + 2, bounds.maxX - width - 2)
        )
        let rect = NSRect(x: originX, y: top, width: width, height: height)
        if hasBackground {
            background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        text.draw(
            at: NSPoint(x: rect.minX + horizontalPadding, y: rect.minY + verticalPadding),
            withAttributes: attributes
        )
    }

    private func xPosition(forDegrees degrees: Double) -> CGFloat {
        let clamped = min(max(degrees, 0), 360)
        let x = bounds.minX + bounds.width * CGFloat(clamped / 360)
        return min(max(x, bounds.minX + 0.5), bounds.maxX - 0.5)
    }

    private static func normalizedDegrees(_ value: Double) -> Double {
        guard value.isFinite else { return 180 }
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped >= 0 ? wrapped : wrapped + 360
    }
}

@objcMembers public final class ROBInsta360DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    private let service = ROBInsta360CameraService.shared
    private let imageView = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let metricsLabel = NSTextField(labelWithString: "")
    private let processingSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton(title: "Open Processing Settings…", target: nil, action: nil)
    private let modelProgress = NSProgressIndicator()
    private let modelStatusLabel = NSTextField(labelWithString: "MLX model: preparing…")
    private let inferenceOutput = NSTextView()
    private let inferenceScroll = NSScrollView()
    private let detectionOverlay = ROBDetectionOverlayView()
    private let orientationGuide = ROBInsta360OrientationGuideView()

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
        NotificationCenter.default.addObserver(self, selector: #selector(geminiVideoSettingsChanged(_:)),
                                               name: .robGeminiVideoSourceSettingsDidChange, object: nil)
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
        inferenceOutput.isEditable = false
        inferenceOutput.isSelectable = true
        inferenceOutput.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        inferenceOutput.backgroundColor = .textBackgroundColor
        inferenceOutput.string = "Waiting for the first MLX vision inference…"
        inferenceScroll.documentView = inferenceOutput
        inferenceScroll.hasVerticalScroller = true
        inferenceScroll.borderType = .bezelBorder
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openProcessingSettings(_:))
        openSettingsButton.bezelStyle = .rounded
        processingSummaryLabel.textColor = .secondaryLabelColor
        processingSummaryLabel.maximumNumberOfLines = 0
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
        orientationGuide.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(orientationGuide)
        NSLayoutConstraint.activate([
            detectionOverlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            detectionOverlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            detectionOverlay.topAnchor.constraint(equalTo: imageView.topAnchor),
            detectionOverlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            orientationGuide.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            orientationGuide.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            orientationGuide.topAnchor.constraint(equalTo: imageView.topAnchor),
            orientationGuide.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
        ])
        let previewStatus = NSStackView(views: [stateLabel, urlLabel])
        previewStatus.orientation = .vertical
        previewStatus.alignment = .leading
        previewStatus.spacing = 3
        let statusFooter = NSStackView(views: [previewStatus, NSView(), openSettingsButton])
        statusFooter.orientation = .horizontal
        statusFooter.alignment = .centerY
        statusFooter.spacing = 12

        let analysisHeading = NSTextField(labelWithString: "Automatic Processing")
        analysisHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let mlxHeading = NSTextField(labelWithString: "MLX Status and Output")
        mlxHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let options = NSStackView(views: [analysisHeading, processingSummaryLabel,
                                          NSGridView(), mlxHeading,
                                          modelRow, inferenceScroll])
        options.translatesAutoresizingMaskIntoConstraints = false
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 8
        options.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let optionsScroll = NSScrollView()
        optionsScroll.documentView = options
        optionsScroll.hasVerticalScroller = true
        optionsScroll.hasHorizontalScroller = false
        optionsScroll.autohidesScrollers = true
        optionsScroll.borderType = .bezelBorder

        // The video is intentionally first and touches the top content margin.
        // Status and configuration no longer reduce its upper viewing area.
        let stack = NSStackView(views: [imageView, metricsLabel, optionsScroll, statusFooter])
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
            optionsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            optionsScroll.heightAnchor.constraint(equalToConstant: 225),
            options.widthAnchor.constraint(equalTo: optionsScroll.contentView.widthAnchor),
            modelProgress.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            processingSummaryLabel.widthAnchor.constraint(equalTo: options.widthAnchor, constant: -20),
            modelRow.widthAnchor.constraint(equalTo: options.widthAnchor, constant: -20),
            inferenceScroll.widthAnchor.constraint(equalTo: options.widthAnchor, constant: -20),
            inferenceScroll.heightAnchor.constraint(equalToConstant: 82)
        ])
    }

    @objc private func serviceChanged(_ notification: Notification) { refresh() }
    @objc private func mlxChanged(_ notification: Notification) { refreshMLX() }
    @objc private func geminiVideoSettingsChanged(_ notification: Notification) { refresh() }
    @objc private func detectorOutputChanged(_ notification: Notification) {
        guard let output = notification.userInfo?["output"] as? ROBDetectorOutput,
              output.source == .insta360 else { return }
        detectionOverlay.output = output
    }
    @objc private func detectorSettingNotification(_ notification: Notification) {
        guard let source = notification.userInfo?["source"] as? ROBDetectorSource,
              source == .insta360 else { return }
        let detectorWasDisabled = notification.userInfo?["enabled"] as? Bool == false
        let geometryChanged = notification.userInfo?["geometryChanged"] as? Bool == true
        let analysisStopped = ROBDynamicDetectorRegistry.shared
            .processingFramesPerSecond(for: .insta360) == 0
        if detectorWasDisabled || geometryChanged || analysisStopped {
            detectionOverlay.output = nil
        }
        refreshMLX()
    }
    @objc private func openProcessingSettings(_ sender: Any?) {
        let delegate = NSApp.delegate as AnyObject?
        let selector = NSSelectorFromString("showInsta360Settings:")
        if delegate?.responds(to: selector) == true {
            _ = delegate?.perform(selector, with: sender)
        }
    }

    private func refresh() {
        stateLabel.stringValue = service.lastError.map { "\(service.state) — \($0)" } ?? service.state
        urlLabel.stringValue = service.streamURL
        metricsLabel.stringValue = String(format: "Frames %llu   Decoded %@   FPS %.1f",
            service.framesReceived,
            ByteCountFormatter.string(fromByteCount: Int64(service.decodedBytes), countStyle: .file),
            service.framesPerSecond)
        let perception = ROBInsta360PerceptionService.shared
        if !perception.lastLabels.isEmpty {
            metricsLabel.stringValue += "   Items: " + perception.lastLabels.joined(separator: ", ")
        }
        let geminiVideoSettings = ROBGeminiVideoSourceSettings.shared
        let projectionIdentity = service.calibrationProjectionIdentity
        let insta360OrientationCalibrated = geminiVideoSettings
            .isInsta360OrientationCalibrationValid(
                forProjectionIdentity: projectionIdentity
            )
        let forward = geminiVideoSettings.insta360ForwardMarkerDegrees
        orientationGuide.update(
            calibratedForwardDegrees: insta360OrientationCalibrated ? forward : nil
        )
        if insta360OrientationCalibrated {
            let rear = GeminiRoboticsRuntimeSettings.normalizedDegrees(forward + 180)
            metricsLabel.stringValue += String(
                format: "   ROB guide: FRONT %.0f° / REAR %.0f°", forward, rear
            )
        } else {
            metricsLabel.stringValue += "   ROB guide: Uncalibrated"
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
                let registry = ROBDynamicDetectorRegistry.shared
                let geometry = registry.insta360AnalysisGeometry == .sixSectors
                    ? "six 60° sectors"
                    : "stitched panorama"
                self.processingSummaryLabel.stringValue = String(
                    format: "Insta360: %@ at %.2f FPS; MLX %@; human detection %@; object detection %@; gyro stabilization %@.%@",
                    geometry,
                    registry.processingFramesPerSecond(for: .insta360),
                    runtime.insta360DetectionEnabled ? "on" : "off",
                    registry.enabled("body-pose", source: .insta360) ? "on" : "off",
                    registry.enabled("generic-objects", source: .insta360) ? "on" : "off",
                    self.service.gyroStabilizationEnabled ? "on" : "off",
                    self.service.previewSettingsPending ? " Preview changes are waiting to be applied" : ""
                )
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
