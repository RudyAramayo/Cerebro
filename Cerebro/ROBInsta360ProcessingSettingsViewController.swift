import AppKit
import Foundation
import UniformTypeIdentifiers

private final class ROBFlippedPerceptionSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Settings-only controls for automatic camera analysis and the Insta360
/// preview. This controller intentionally does not claim diagnostics preview
/// visibility; opening Settings must not start frame decoding by itself.
@objcMembers public final class ROBInsta360ProcessingSettingsViewController: NSViewController {
    private let service = ROBInsta360CameraService.shared
    private let runtime = ROBMLXRuntime.shared
    private let registry = ROBDynamicDetectorRegistry.shared
    private let geminiVideoSettings = ROBGeminiVideoSourceSettings.shared
    private let mainCameraSettings = ROBMainCameraProcessingSettings.shared

    private let geminiMainCameraToggle = NSButton(
        checkboxWithTitle: "Include main forward camera", target: nil, action: nil)
    private let geminiInsta360Toggle = NSButton(
        checkboxWithTitle: "Include Insta360 panorama", target: nil, action: nil)
    private let geminiInsta360ForwardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let geminiCalibrationHelpLabel = NSTextField(wrappingLabelWithString: "")

    private let mainCameraDetectionToggle = NSButton(
        checkboxWithTitle: "Analyze main live-feed camera", target: nil, action: nil)
    private let insta360DetectionToggle = NSButton(
        checkboxWithTitle: "Analyze Insta360 preview", target: nil, action: nil)
    private let showInferenceToggle = NSButton(
        checkboxWithTitle: "Show MLX inference output", target: nil, action: nil)

    private let mainFPSPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let instaFPSPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let analysisGeometryPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let mainPoseToggle = NSButton(
        checkboxWithTitle: "Main pose", target: nil, action: nil)
    private let instaPoseToggle = NSButton(
        checkboxWithTitle: "360° human detection and pose", target: nil, action: nil)
    private let mainObjectsToggle = NSButton(
        checkboxWithTitle: "Main object labels", target: nil, action: nil)
    private let instaObjectsToggle = NSButton(
        checkboxWithTitle: "360° object labels", target: nil, action: nil)
    private let addModelButton = NSButton(title: "Add Core ML Model…", target: nil, action: nil)

    private let pose3DToggle = NSButton(
        checkboxWithTitle: "Render 3D pose", target: nil, action: nil)
    private let pose3DFPSPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swordTrackerToggle = NSButton(
        checkboxWithTitle: "Track training sword", target: nil, action: nil)
    private let swordTrackerFPSPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let depthOpacitySlider = NSSlider(
        value: 0.45, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let depthOpacityValueLabel = NSTextField(labelWithString: "45%")

    private let stabilizationToggle = NSButton(
        checkboxWithTitle: "Gyro stabilization", target: nil, action: nil)
    private let applyPreviewSettingsButton = NSButton(
        title: "Apply Preview Settings", target: nil, action: nil)
    private let previewStatusLabel = NSTextField(labelWithString: "")
    private let modelStatusLabel = NSTextField(labelWithString: "")

    private let processingRates: [Double] = [0, 0.25, 0.5, 1, 2, 5, 10, 15, 30]
    private let processingRateTitles = [
        "Off", "0.25 FPS", "0.5 FPS", "1 FPS", "2 FPS",
        "5 FPS", "10 FPS", "15 FPS", "30 FPS"
    ]
    private let pose3DRates: [Double] = [0.1, 0.25, 0.5, 1, 2]
    private let pose3DRateTitles = ["0.1 FPS", "0.25 FPS", "0.5 FPS", "1 FPS", "2 FPS"]
    private let swordTrackerRates: [Double] = [5, 10, 15, 30, 60]
    private let swordTrackerRateTitles = ["5 FPS", "10 FPS", "15 FPS", "30 FPS", "60 FPS"]
    private let panoramaForwardMarkerDegrees = Array(stride(from: 0, to: 360, by: 15))
    private var pendingRefresh: DispatchWorkItem?

    public init() {
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robInsta360CameraServiceDidChange,
            object: service)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robMLXRuntimeDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robDetectorSettingsDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robGeminiVideoSourceSettingsDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robMainCameraProcessingSettingsDidChange,
            object: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robInsta360CameraServiceDidChange,
            object: service)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robMLXRuntimeDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robDetectorSettingsDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robGeminiVideoSourceSettingsDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robMainCameraProcessingSettingsDidChange,
            object: nil)
    }

    deinit {
        pendingRefresh?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    public override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 580))
        view = content
        buildInterface(in: content)
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        refreshSettings()
    }

    /// Reloads every control through the production getters so absent defaults
    /// retain their existing opt-in/opt-out semantics.
    public func refreshSettings() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshSettings() }
            return
        }
        loadViewIfNeeded()

        mainCameraDetectionToggle.state = runtime.mainCameraDetectionEnabled ? .on : .off
        insta360DetectionToggle.state = runtime.insta360DetectionEnabled ? .on : .off
        showInferenceToggle.state = runtime.showInferenceOutput ? .on : .off

        mainFPSPopup.selectItem(at: rateIndex(
            registry.processingFramesPerSecond(for: .mainCamera)))
        instaFPSPopup.selectItem(at: rateIndex(
            registry.processingFramesPerSecond(for: .insta360)))
        analysisGeometryPopup.selectItem(at: registry.insta360AnalysisGeometry.rawValue)

        mainPoseToggle.state = registry.enabled(
            "body-pose", source: .mainCamera) ? .on : .off
        instaPoseToggle.state = registry.enabled(
            "body-pose", source: .insta360) ? .on : .off
        mainObjectsToggle.state = registry.enabled(
            "generic-objects", source: .mainCamera) ? .on : .off
        instaObjectsToggle.state = registry.enabled(
            "generic-objects", source: .insta360) ? .on : .off

        pose3DToggle.state = mainCameraSettings.pose3DEnabled ? .on : .off
        pose3DFPSPopup.selectItem(at: nearestRateIndex(
            mainCameraSettings.pose3DFramesPerSecond, in: pose3DRates))
        pose3DFPSPopup.isEnabled = mainCameraSettings.pose3DEnabled
        swordTrackerToggle.state = mainCameraSettings.swordTrackerEnabled ? .on : .off
        swordTrackerFPSPopup.selectItem(at: nearestRateIndex(
            mainCameraSettings.swordTrackerFramesPerSecond, in: swordTrackerRates))
        swordTrackerFPSPopup.isEnabled = mainCameraSettings.swordTrackerEnabled
        depthOpacitySlider.doubleValue = mainCameraSettings.depthOverlayOpacity
        updateDepthOpacityValueLabel()

        geminiMainCameraToggle.state = geminiVideoSettings.mainCameraEnabled ? .on : .off
        geminiInsta360Toggle.state = geminiVideoSettings.insta360Enabled ? .on : .off
        stabilizationToggle.state = service.gyroStabilizationEnabled ? .on : .off
        let projectionIdentity = service.calibrationProjectionIdentity
        let calibrationCanBeSet = geminiVideoSettings.insta360Enabled
            && !service.gyroStabilizationEnabled
            && !service.previewSettingsPending
            && projectionIdentity != nil
        let calibrationIsValid = geminiVideoSettings
            .isInsta360OrientationCalibrationValid(
                forProjectionIdentity: projectionIdentity
            )
        geminiInsta360ForwardPopup.isEnabled = calibrationCanBeSet
        if calibrationIsValid {
            let target = geminiVideoSettings.insta360ForwardMarkerDegrees
            let nearestIndex = panoramaForwardMarkerDegrees.enumerated().min {
                circularDegreeDistance(Double($0.element), target)
                    < circularDegreeDistance(Double($1.element), target)
            }?.offset ?? 12
            geminiInsta360ForwardPopup.selectItem(at: nearestIndex + 1)
        } else {
            geminiInsta360ForwardPopup.selectItem(at: 0)
        }

        let calibrationStatus: String
        if service.gyroStabilizationEnabled {
            calibrationStatus = "Robot-relative FRONT/REAR calibration is unavailable while Gyro stabilization is on: stabilized yaw moves within the panorama. Turn it off and apply the preview setting first."
        } else if service.previewSettingsPending {
            calibrationStatus = "Apply the unstabilized preview setting before choosing ROB forward. Calibration remains unavailable while that camera change is pending."
        } else if projectionIdentity == nil {
            calibrationStatus = "Waiting for the camera to confirm its unstabilized stitched projection. ROB-relative directions remain uncalibrated."
        } else if calibrationIsValid {
            calibrationStatus = "FRONT and REAR are calibrated for this camera host and projection. Verify both markers against the live 0°–360° guide in Insta360 Diagnostics."
        } else {
            calibrationStatus = "Ready to calibrate: use Insta360 Diagnostics to find ROB forward, then choose that 0°–345° position here. Camera host or projection changes clear this calibration."
        }
        geminiCalibrationHelpLabel.stringValue =
            "Gemini receives one labeled composite at no more than 1 FPS. \(calibrationStatus) Until calibrated, Gemini must not infer which region is behind ROB. Imagery leaves this Mac only while Gemini's master camera switch is on."

        applyPreviewSettingsButton.isEnabled = service.previewSettingsPending
        applyPreviewSettingsButton.title = service.previewSettingsPending
            ? "Apply Preview Settings"
            : "Preview Settings Applied"

        if let error = service.lastError, !error.isEmpty {
            previewStatusLabel.stringValue = "\(service.state) — \(error)"
        } else {
            previewStatusLabel.stringValue = service.state
        }
    }

    private func buildInterface(in content: NSView) {
        let heading = NSTextField(labelWithString: "Camera Processing")
        heading.font = .boldSystemFont(ofSize: 20)

        let explanation = wrappingLabel(
            "Choose which live camera frames Cerebro analyzes. Processing settings apply immediately; preview stabilization is applied only when requested below.")
        explanation.textColor = .secondaryLabelColor

        configureControls()

        let geminiBox = NSBox()
        geminiBox.title = "Gemini Live Camera Context"
        geminiBox.contentView = NSView()
        let geminiHelp = geminiCalibrationHelpLabel
        geminiHelp.maximumNumberOfLines = 0
        geminiHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        geminiHelp.textColor = .secondaryLabelColor
        let geminiStack = NSStackView(views: [
            row([geminiMainCameraToggle, geminiInsta360Toggle]),
            row([
                NSTextField(labelWithString: "ROB forward in panorama:"),
                geminiInsta360ForwardPopup,
                secondaryLabel("0° = left seam • 180° = image center")
            ]),
            geminiHelp
        ])
        configureVerticalStack(geminiStack)
        geminiStack.spacing = 6
        geminiBox.contentView?.addSubview(geminiStack)
        if let geminiContent = geminiBox.contentView {
            NSLayoutConstraint.activate([
                geminiStack.leadingAnchor.constraint(equalTo: geminiContent.leadingAnchor, constant: 12),
                geminiStack.trailingAnchor.constraint(equalTo: geminiContent.trailingAnchor, constant: -12),
                geminiStack.topAnchor.constraint(equalTo: geminiContent.topAnchor, constant: 9),
                geminiStack.bottomAnchor.constraint(equalTo: geminiContent.bottomAnchor, constant: -10),
                geminiHelp.widthAnchor.constraint(equalTo: geminiStack.widthAnchor)
            ])
        }

        let analysisBox = NSBox()
        analysisBox.title = "Automatic Analysis"
        analysisBox.contentView = NSView()
        let analysisStack = NSStackView(views: [
            row([mainCameraDetectionToggle, insta360DetectionToggle, showInferenceToggle]),
            row([
                NSTextField(labelWithString: "Main analysis:"), mainFPSPopup,
                NSTextField(labelWithString: "Insta360 analysis:"), instaFPSPopup
            ]),
            row([
                NSTextField(labelWithString: "360° analysis:"), analysisGeometryPopup,
                secondaryLabel("One stitched network feed")
            ]),
            row([
                mainPoseToggle, instaPoseToggle
            ]),
            row([
                mainObjectsToggle, instaObjectsToggle, addModelButton
            ]),
            modelStatusLabel
        ])
        configureVerticalStack(analysisStack)
        analysisBox.contentView?.addSubview(analysisStack)
        if let analysisContent = analysisBox.contentView {
            NSLayoutConstraint.activate([
                analysisStack.leadingAnchor.constraint(equalTo: analysisContent.leadingAnchor, constant: 12),
                analysisStack.trailingAnchor.constraint(equalTo: analysisContent.trailingAnchor, constant: -12),
                analysisStack.topAnchor.constraint(equalTo: analysisContent.topAnchor, constant: 10),
                analysisStack.bottomAnchor.constraint(equalTo: analysisContent.bottomAnchor, constant: -12)
            ])
        }

        let mainCameraBox = NSBox()
        mainCameraBox.title = "Main Camera Processing"
        mainCameraBox.contentView = NSView()
        depthOpacitySlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        depthOpacityValueLabel.alignment = .right
        depthOpacityValueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let mainCameraStack = NSStackView(views: [
            row([
                pose3DToggle,
                NSTextField(labelWithString: "Rate:"), pose3DFPSPopup,
                secondaryLabel("Also limited by Main analysis")
            ]),
            row([
                swordTrackerToggle,
                NSTextField(labelWithString: "Rate:"), swordTrackerFPSPopup
            ]),
            row([
                NSTextField(labelWithString: "Depth overlay opacity:"),
                depthOpacitySlider, depthOpacityValueLabel
            ])
        ])
        configureVerticalStack(mainCameraStack)
        mainCameraBox.contentView?.addSubview(mainCameraStack)
        if let mainCameraContent = mainCameraBox.contentView {
            NSLayoutConstraint.activate([
                mainCameraStack.leadingAnchor.constraint(
                    equalTo: mainCameraContent.leadingAnchor, constant: 12),
                mainCameraStack.trailingAnchor.constraint(
                    equalTo: mainCameraContent.trailingAnchor, constant: -12),
                mainCameraStack.topAnchor.constraint(
                    equalTo: mainCameraContent.topAnchor, constant: 10),
                mainCameraStack.bottomAnchor.constraint(
                    equalTo: mainCameraContent.bottomAnchor, constant: -12)
            ])
        }

        let previewBox = NSBox()
        previewBox.title = "Insta360 Preview"
        previewBox.contentView = NSView()
        previewStatusLabel.textColor = .secondaryLabelColor
        previewStatusLabel.lineBreakMode = .byTruncatingMiddle
        previewStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let previewRow = row([
            stabilizationToggle, applyPreviewSettingsButton, previewStatusLabel
        ])
        previewBox.contentView?.addSubview(previewRow)
        if let previewContent = previewBox.contentView {
            NSLayoutConstraint.activate([
                previewRow.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor, constant: 12),
                previewRow.trailingAnchor.constraint(equalTo: previewContent.trailingAnchor, constant: -12),
                previewRow.topAnchor.constraint(equalTo: previewContent.topAnchor, constant: 12),
                previewRow.bottomAnchor.constraint(equalTo: previewContent.bottomAnchor, constant: -12)
            ])
        }

        let rootStack = NSStackView(views: [
            heading, explanation, geminiBox, analysisBox, mainCameraBox, previewBox
        ])
        configureVerticalStack(rootStack)
        rootStack.spacing = 10

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let documentView = ROBFlippedPerceptionSettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rootStack)
        scrollView.documentView = documentView
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rootStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            rootStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            geminiBox.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            geminiBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 135),
            analysisBox.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            analysisBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 225),
            mainCameraBox.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            mainCameraBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 125),
            previewBox.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            previewBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 65)
        ])

        refreshSettings()
    }

    private func configureControls() {
        geminiMainCameraToggle.target = self
        geminiMainCameraToggle.action = #selector(geminiVideoSourceChanged(_:))
        geminiMainCameraToggle.setAccessibilityIdentifier("ROB.GeminiVideo.MainCamera")
        geminiMainCameraToggle.setAccessibilityHelp(
            "Include fresh main forward-camera pixels in Gemini's labeled composite observation.")
        geminiInsta360Toggle.target = self
        geminiInsta360Toggle.action = #selector(geminiVideoSourceChanged(_:))
        geminiInsta360Toggle.setAccessibilityIdentifier("ROB.GeminiVideo.Insta360")
        geminiInsta360Toggle.setAccessibilityHelp(
            "Keep the Insta360 decoder available headlessly and include its stitched panorama in Gemini's labeled composite observation.")
        geminiInsta360ForwardPopup.addItem(withTitle: "Uncalibrated")
        geminiInsta360ForwardPopup.addItems(withTitles: panoramaForwardMarkerDegrees.map { "\($0)°" })
        geminiInsta360ForwardPopup.target = self
        geminiInsta360ForwardPopup.action = #selector(geminiInsta360ForwardChanged(_:))
        geminiInsta360ForwardPopup.setAccessibilityIdentifier(
            "ROB.GeminiVideo.Insta360ForwardMarker")
        geminiInsta360ForwardPopup.setAccessibilityLabel(
            "ROB forward direction in the Insta360 panorama")
        geminiInsta360ForwardPopup.setAccessibilityHelp(
            "First turn Gyro stabilization off and apply the preview setting. Then choose Uncalibrated, or the horizontal panorama position that faces the same direction as ROB. Zero degrees is the left seam and 180 degrees is the image center.")

        mainCameraDetectionToggle.target = self
        mainCameraDetectionToggle.action = #selector(mlxSettingChanged(_:))
        insta360DetectionToggle.target = self
        insta360DetectionToggle.action = #selector(mlxSettingChanged(_:))
        showInferenceToggle.target = self
        showInferenceToggle.action = #selector(mlxSettingChanged(_:))

        for popup in [mainFPSPopup, instaFPSPopup] {
            popup.addItems(withTitles: processingRateTitles)
            popup.target = self
            popup.action = #selector(processingFPSChanged(_:))
        }
        mainFPSPopup.setAccessibilityLabel("Main camera analysis rate")
        instaFPSPopup.setAccessibilityLabel("Insta360 analysis rate")

        analysisGeometryPopup.addItems(withTitles: [
            "Full stitched panorama", "Six detector sectors"
        ])
        analysisGeometryPopup.target = self
        analysisGeometryPopup.action = #selector(analysisGeometryChanged(_:))
        analysisGeometryPopup.toolTip = "Six sectors are derived locally from the stitched stream; this is not six native Pro II sensor streams."
        analysisGeometryPopup.setAccessibilityLabel("Insta360 analysis geometry")

        for toggle in [mainPoseToggle, instaPoseToggle, mainObjectsToggle, instaObjectsToggle] {
            toggle.target = self
            toggle.action = #selector(detectorSettingChanged(_:))
        }

        pose3DToggle.target = self
        pose3DToggle.action = #selector(mainCameraFeatureChanged(_:))
        pose3DToggle.setAccessibilityIdentifier("ROB.MainCamera.Pose3D.Enabled")
        pose3DToggle.toolTip = "Uses Apple's 3D body-pose model on the serialized main-camera analysis queue."
        pose3DFPSPopup.addItems(withTitles: pose3DRateTitles)
        pose3DFPSPopup.target = self
        pose3DFPSPopup.action = #selector(mainCameraRateChanged(_:))
        pose3DFPSPopup.setAccessibilityIdentifier("ROB.MainCamera.Pose3D.FPS")
        pose3DFPSPopup.setAccessibilityLabel("Main camera 3D pose rate")
        pose3DFPSPopup.toolTip = "Independent conservative ceiling; also limited by the main-camera analysis rate."

        swordTrackerToggle.target = self
        swordTrackerToggle.action = #selector(mainCameraFeatureChanged(_:))
        swordTrackerToggle.setAccessibilityIdentifier("ROB.MainCamera.SwordTracker.Enabled")
        swordTrackerToggle.toolTip = "Tracks elongated high-contrast training implements near detected wrists."
        swordTrackerFPSPopup.addItems(withTitles: swordTrackerRateTitles)
        swordTrackerFPSPopup.target = self
        swordTrackerFPSPopup.action = #selector(mainCameraRateChanged(_:))
        swordTrackerFPSPopup.setAccessibilityIdentifier("ROB.MainCamera.SwordTracker.FPS")
        swordTrackerFPSPopup.setAccessibilityLabel("Main camera training sword tracking rate")
        swordTrackerFPSPopup.toolTip = "Maximum admission rate; actual speed is limited by camera FPS and contour processing time."

        depthOpacitySlider.target = self
        depthOpacitySlider.action = #selector(depthOverlayOpacityChanged(_:))
        depthOpacitySlider.isContinuous = true
        depthOpacitySlider.numberOfTickMarks = 11
        depthOpacitySlider.allowsTickMarkValuesOnly = false
        depthOpacitySlider.setAccessibilityIdentifier("ROB.MainCamera.DepthOverlayOpacity")
        depthOpacitySlider.setAccessibilityLabel("Main camera depth overlay opacity")
        depthOpacityValueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        depthOpacityValueLabel.textColor = .secondaryLabelColor

        addModelButton.target = self
        addModelButton.action = #selector(addCoreMLModel(_:))
        addModelButton.bezelStyle = .rounded
        modelStatusLabel.textColor = .secondaryLabelColor
        modelStatusLabel.stringValue = "Custom Core ML models remain active for this app session."

        stabilizationToggle.target = self
        stabilizationToggle.action = #selector(stabilizationChanged(_:))
        applyPreviewSettingsButton.target = self
        applyPreviewSettingsButton.action = #selector(applyPreviewSettings(_:))
        applyPreviewSettingsButton.bezelStyle = .rounded
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleRefreshIfLoaded() }
            return
        }
        scheduleRefreshIfLoaded()
    }

    /// The camera service publishes frame/metric changes frequently. Coalesce
    /// those notifications so an open Settings window never refreshes its
    /// controls at decoder frame rate.
    private func scheduleRefreshIfLoaded() {
        guard isViewLoaded, pendingRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            self.refreshSettings()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @objc private func mlxSettingChanged(_ sender: NSButton) {
        if sender === mainCameraDetectionToggle {
            runtime.mainCameraDetectionEnabled = sender.state == .on
        } else if sender === insta360DetectionToggle {
            runtime.insta360DetectionEnabled = sender.state == .on
            service.refreshDecoderDemand()
        } else if sender === showInferenceToggle {
            runtime.showInferenceOutput = sender.state == .on
        }
    }

    @objc private func geminiVideoSourceChanged(_ sender: NSButton) {
        if sender === geminiMainCameraToggle {
            geminiVideoSettings.mainCameraEnabled = sender.state == .on
        } else if sender === geminiInsta360Toggle {
            geminiVideoSettings.insta360Enabled = sender.state == .on
            refreshSettings()
        }
    }

    @objc private func geminiInsta360ForwardChanged(_ sender: NSPopUpButton) {
        let markerIndex = sender.indexOfSelectedItem - 1
        guard panoramaForwardMarkerDegrees.indices.contains(markerIndex) else {
            geminiVideoSettings.insta360OrientationCalibrated = false
            return
        }
        guard !service.gyroStabilizationEnabled,
              !service.previewSettingsPending,
              let projectionIdentity = service.calibrationProjectionIdentity else {
            NSSound.beep()
            sender.selectItem(at: 0)
            refreshSettings()
            return
        }
        geminiVideoSettings.insta360ForwardMarkerDegrees = Double(
            panoramaForwardMarkerDegrees[markerIndex]
        )
        geminiVideoSettings.insta360OrientationCalibrated = true
        guard geminiVideoSettings.isInsta360OrientationCalibrationValid(
            forProjectionIdentity: projectionIdentity
        ) else {
            NSSound.beep()
            sender.selectItem(at: 0)
            refreshSettings()
            return
        }
    }

    @objc private func processingFPSChanged(_ sender: NSPopUpButton) {
        guard processingRates.indices.contains(sender.indexOfSelectedItem) else { return }
        let source: ROBDetectorSource = sender === mainFPSPopup ? .mainCamera : .insta360
        registry.setProcessingFramesPerSecond(
            processingRates[sender.indexOfSelectedItem], for: source)
        if source == .insta360 {
            service.refreshDecoderDemand()
        }
    }

    @objc private func analysisGeometryChanged(_ sender: NSPopUpButton) {
        registry.insta360AnalysisGeometry = sender.indexOfSelectedItem == 1
            ? .sixSectors
            : .stitchedPanorama
    }

    @objc private func detectorSettingChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        if sender === mainPoseToggle {
            registry.setEnabled(enabled, detector: "body-pose", source: .mainCamera)
        } else if sender === instaPoseToggle {
            registry.setEnabled(enabled, detector: "body-pose", source: .insta360)
            service.refreshDecoderDemand()
        } else if sender === mainObjectsToggle {
            registry.setEnabled(enabled, detector: "generic-objects", source: .mainCamera)
        } else if sender === instaObjectsToggle {
            registry.setEnabled(enabled, detector: "generic-objects", source: .insta360)
            service.refreshDecoderDemand()
        }
    }

    @objc private func mainCameraFeatureChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        if sender === pose3DToggle {
            mainCameraSettings.pose3DEnabled = enabled
            pose3DFPSPopup.isEnabled = enabled
        } else if sender === swordTrackerToggle {
            mainCameraSettings.swordTrackerEnabled = enabled
            swordTrackerFPSPopup.isEnabled = enabled
        }
    }

    @objc private func mainCameraRateChanged(_ sender: NSPopUpButton) {
        if sender === pose3DFPSPopup,
           pose3DRates.indices.contains(sender.indexOfSelectedItem) {
            mainCameraSettings.pose3DFramesPerSecond =
                pose3DRates[sender.indexOfSelectedItem]
        } else if sender === swordTrackerFPSPopup,
                  swordTrackerRates.indices.contains(sender.indexOfSelectedItem) {
            mainCameraSettings.swordTrackerFramesPerSecond =
                swordTrackerRates[sender.indexOfSelectedItem]
        }
    }

    @objc private func depthOverlayOpacityChanged(_ sender: NSSlider) {
        mainCameraSettings.depthOverlayOpacity = sender.doubleValue
        sender.doubleValue = mainCameraSettings.depthOverlayOpacity
        updateDepthOpacityValueLabel()
    }

    @objc private func stabilizationChanged(_ sender: NSButton) {
        if service.gyroStabilizationEnabled != (sender.state == .on) {
            geminiVideoSettings.invalidateInsta360OrientationCalibration()
        }
        service.gyroStabilizationEnabled = sender.state == .on
        refreshSettings()
    }

    @objc private func applyPreviewSettings(_ sender: Any?) {
        guard service.previewSettingsPending else { return }
        service.restart()
    }

    @objc private func addCoreMLModel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mlmodel")!,
            UTType(filenameExtension: "mlmodelc")!
        ]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Core ML model to use for live camera analysis."

        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.registerCoreMLModel(at: url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            registerCoreMLModel(at: url)
        }
    }

    private func registerCoreMLModel(at url: URL) {
        do {
            try registry.registerCoreMLModel(at: url)
            modelStatusLabel.stringValue = "Added \(url.deletingPathExtension().lastPathComponent) for this app session."
        } catch {
            NSApp.presentError(error)
        }
    }

    private func rateIndex(_ fps: Double) -> Int {
        processingRates.enumerated().min {
            abs($0.element - fps) < abs($1.element - fps)
        }?.offset ?? 0
    }

    private func nearestRateIndex(_ fps: Double, in rates: [Double]) -> Int {
        rates.enumerated().min {
            abs($0.element - fps) < abs($1.element - fps)
        }?.offset ?? 0
    }

    private func updateDepthOpacityValueLabel() {
        depthOpacityValueLabel.stringValue = String(
            format: "%.0f%%", depthOpacitySlider.doubleValue * 100)
    }

    private func circularDegreeDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    private func configureVerticalStack(_ stack: NSStackView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views + [NSView()])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func wrappingLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.maximumNumberOfLines = 0
        return label
    }

    private func secondaryLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.textColor = .secondaryLabelColor
        return label
    }
}
