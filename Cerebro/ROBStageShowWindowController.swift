//
//  ROBStageShowWindowController.swift
//  Cerebro
//
//  Rehearsal UI for strict stage-show documents. Motion cues are only named
//  requests; the coordinator's delegate decides whether a supervised executor
//  exists and fails safely when it does not.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@objcMembers public final class ROBStageShowWindowController: NSWindowController, NSWindowDelegate {
    private let stageShowCoordinator: ROBStageShowCoordinator
    private let editor = NSTextView()
    private let logView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Load or validate a show to begin.")
    private let localEnabledButton = NSButton(
        checkboxWithTitle: "Use local stage director",
        target: nil,
        action: nil
    )
    private let localProviderPopup = NSPopUpButton()
    private let localEndpointField = NSTextField()
    private let localModelField = NSTextField()
    private let localTimeoutField = NSTextField()
    private let localStatusLabel = NSTextField(labelWithString: "Local director disabled.")
    private let mlxVisionButton = NSButton(checkboxWithTitle: "Sample camera with MLX VLM (≥5 s)", target: nil, action: nil)
    private let mlxMemoryField = NSTextField()
    private let mlxTelemetryLabel = NSTextField(labelWithString: "MLX is idle; models load on first test.")
    private var stateObserver: NSObjectProtocol?
    private var localRefreshTimer: Timer?
    private var localTemperature = ROBLocalImprovisationConfiguration.defaultTemperature

    @objc(initWithStageShowCoordinator:)
    public init(stageShowCoordinator: ROBStageShowCoordinator) {
        self.stageShowCoordinator = stageShowCoordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stage Show"
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        loadLocalProviderSettings()
        loadBundledSample(nil)
        observeCoordinator()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
        startLocalRefreshTimer()
    }

    public func windowWillClose(_ notification: Notification) {
        if stageShowCoordinator.isRunning {
            stageShowCoordinator.cancel(reason: "Stage Show window closed")
        }
        localRefreshTimer?.invalidate()
        localRefreshTimer = nil
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let safetyLabel = NSTextField(wrappingLabelWithString:
            "Shows may contain speech, waits, checkpoints, optional Gemini turns, and named gestures. " +
            "The optional local director produces dialogue only and cannot authorize motion. " +
            "Shows cannot contain servo values, joint angles, SSH commands, hosts, or ports. Dry Run emits no speech, model request, or hardware request."
        )
        safetyLabel.font = .systemFont(ofSize: 12)
        safetyLabel.textColor = .secondaryLabelColor

        let openButton = makeButton("Open…", action: #selector(openShow(_:)))
        let sampleButton = makeButton("Load Sample", action: #selector(loadBundledSample(_:)))
        let validateButton = makeButton("Validate", action: #selector(validateShow(_:)))
        let dryRunButton = makeButton("Dry Run", action: #selector(startDryRun(_:)))
        let offlineButton = makeButton("Run Offline", action: #selector(startSpeechOnly(_:)))
        let localButton = makeButton("Run Local", action: #selector(startLocalOnly(_:)))
        let adaptiveButton = makeButton("Run Adaptive", action: #selector(startAdaptive(_:)))
        let continueButton = makeButton("Continue", action: #selector(continueShow(_:)))
        let stopButton = makeButton("Stop", action: #selector(stopShow(_:)))
        stopButton.contentTintColor = .systemRed

        let buttonStack = NSStackView(views: [
            openButton, sampleButton, validateButton, dryRunButton,
            offlineButton, localButton, adaptiveButton, continueButton, stopButton
        ])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        localProviderPopup.addItems(withTitles: ROBLocalImprovisationProviderKind.allCases.map(\.displayName))
        localProviderPopup.target = self
        localProviderPopup.action = #selector(localProviderSelectionChanged(_:))
        localProviderPopup.toolTip = "Choose the loopback llama.cpp server or private in-process MLX Swift inference."

        localEndpointField.placeholderString = "http://127.0.0.1:8080"
        localEndpointField.toolTip = "Loopback llama.cpp server root, /v1, or /v1/chat/completions"
        localModelField.placeholderString = "cerebro-local"
        localModelField.toolTip = "llama.cpp model name or --alias"
        localTimeoutField.placeholderString = "3"
        localTimeoutField.alignment = .right
        localTimeoutField.toolTip = "Maximum local inference seconds; adaptive cues may allocate a smaller sub-deadline"
        for field in [localEndpointField, localModelField, localTimeoutField] {
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }

        let endpointLabel = NSTextField(labelWithString: "Endpoint")
        let modelLabel = NSTextField(labelWithString: "Model")
        let timeoutLabel = NSTextField(labelWithString: "Timeout")
        for label in [endpointLabel, modelLabel, timeoutLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        let saveLocalButton = makeButton("Save Local", action: #selector(saveLocalProvider(_:)))
        let testLocalButton = makeButton("Test Local", action: #selector(testLocalProvider(_:)))
        let localControlsRow = NSStackView(views: [
            localEnabledButton, localProviderPopup,
            endpointLabel, localEndpointField,
            modelLabel, localModelField,
            timeoutLabel, localTimeoutField,
            saveLocalButton, testLocalButton
        ])
        localControlsRow.orientation = .horizontal
        localControlsRow.alignment = .centerY
        localControlsRow.spacing = 7
        localEndpointField.widthAnchor.constraint(equalToConstant: 215).isActive = true
        localModelField.widthAnchor.constraint(equalToConstant: 125).isActive = true
        localTimeoutField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        localStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        localStatusLabel.textColor = .secondaryLabelColor
        localStatusLabel.lineBreakMode = .byTruncatingMiddle
        localStatusLabel.usesSingleLineMode = true
        let localStack = NSStackView(views: [localControlsRow, localStatusLabel])
        localStack.orientation = .vertical
        localStack.alignment = .leading
        localStack.spacing = 5

        mlxVisionButton.target = self
        mlxVisionButton.action = #selector(mlxVisionChanged(_:))
        mlxVisionButton.toolTip = "Examines selected frames on a low-frequency worker. It never runs in the real-time motor-control loop."
        mlxMemoryField.placeholderString = "Local semantic memory text or retrieval query"
        mlxMemoryField.font = .systemFont(ofSize: 11)
        mlxMemoryField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let rememberButton = makeButton("Remember", action: #selector(rememberWithMLX(_:)))
        let retrieveButton = makeButton("Retrieve", action: #selector(retrieveWithMLX(_:)))
        let mlxRow = NSStackView(views: [mlxVisionButton, mlxMemoryField, rememberButton, retrieveButton])
        mlxRow.orientation = .horizontal
        mlxRow.alignment = .centerY
        mlxRow.spacing = 8
        mlxTelemetryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        mlxTelemetryLabel.textColor = .secondaryLabelColor
        mlxTelemetryLabel.lineBreakMode = .byTruncatingMiddle
        mlxTelemetryLabel.usesSingleLineMode = true
        let mlxStack = NSStackView(views: [mlxRow, mlxTelemetryLabel])
        mlxStack.orientation = .vertical
        mlxStack.alignment = .leading
        mlxStack.spacing = 5

        editor.isRichText = false
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.borderType = .bezelBorder
        editorScroll.documentView = editor

        logView.isEditable = false
        logView.frame = NSRect(x: 0, y: 0, width: 900, height: 130)
        logView.isSelectable = true
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.textContainerInset = NSSize(width: 8, height: 6)
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.borderType = .bezelBorder
        logScroll.documentView = logView

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail

        for view in [safetyLabel, buttonStack, localStack, mlxStack, editorScroll, statusLabel, logScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            safetyLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            safetyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            safetyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: safetyLabel.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            localStack.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 10),
            localStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            localStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            mlxStack.topAnchor.constraint(equalTo: localStack.bottomAnchor, constant: 8),
            mlxStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            mlxStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            editorScroll.topAnchor.constraint(equalTo: mlxStack.bottomAnchor, constant: 10),
            editorScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            editorScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            editorScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: logScroll.topAnchor, constant: -8),

            logScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            logScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            logScroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            logScroll.heightAnchor.constraint(equalToConstant: 130)
        ])
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func observeCoordinator() {
        stateObserver = NotificationCenter.default.addObserver(
            forName: .ROBStageShowStateDidChange,
            object: stageShowCoordinator,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let state = notification.userInfo?["state"] as? String ?? self.stageShowCoordinator.state
            let detail = notification.userInfo?["detail"] as? String ?? self.stageShowCoordinator.detail
            self.statusLabel.stringValue = "\(state): \(detail)"
            self.appendLog("[\(state)] \(detail)")
            self.refreshLocalStatus()
        }
    }

    @objc private func openShow(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            editor.string = try String(contentsOf: url, encoding: .utf8)
            statusLabel.stringValue = "Loaded \(url.lastPathComponent); select Validate before running."
            appendLog("Loaded \(url.path)")
        } catch {
            report(error)
        }
    }

    @objc private func loadBundledSample(_ sender: Any?) {
        do {
            if let url = Bundle.main.url(forResource: "MakerFaireOpening", withExtension: "robshow.json") {
                editor.string = try String(contentsOf: url, encoding: .utf8)
            } else {
                let data = try ROBStageShowCodec.encode(ROBStageShowSamples.makerFaireOpening)
                editor.string = String(decoding: data, as: UTF8.self)
            }
            statusLabel.stringValue = "Loaded the Maker Faire sample."
        } catch {
            report(error)
        }
    }

    @objc private func validateShow(_ sender: Any?) {
        do {
            let show = try decodedEditorShow()
            try stageShowCoordinator.load(show)
            statusLabel.stringValue = "Valid: \(show.title), \(show.cues.count) cues."
        } catch {
            report(error)
        }
    }

    @objc private func startDryRun(_ sender: Any?) {
        start(mode: .dryRun)
    }

    @objc private func startSpeechOnly(_ sender: Any?) {
        start(mode: .speechOnly)
    }

    @objc private func startLocalOnly(_ sender: Any?) {
        start(mode: .localOnly)
    }

    @objc private func startAdaptive(_ sender: Any?) {
        start(mode: .adaptive)
    }

    @objc private func continueShow(_ sender: Any?) {
        stageShowCoordinator.continueAfterCheckpoint()
    }

    @objc private func stopShow(_ sender: Any?) {
        stageShowCoordinator.cancel(reason: "Stopped by the stage operator")
    }

    @objc private func localProviderSelectionChanged(_ sender: Any?) {
        if localProviderPopup.indexOfSelectedItem == 1,
           localModelField.stringValue == ROBLocalImprovisationConfiguration.defaultModel {
            localModelField.stringValue = ROBMLXEngine.defaultLLMModel
        }
        updateLocalFieldAvailability()
    }

    @objc private func mlxVisionChanged(_ sender: NSButton) {
        ROBMLXRuntime.shared.setVisionEnabled(sender.state == .on)
        appendLog(sender.state == .on
            ? "[mlx] low-frequency VLM sampling enabled; camera frames remain outside motor control"
            : "[mlx] VLM sampling disabled")
    }

    @objc private func rememberWithMLX(_ sender: Any?) {
        let text = mlxMemoryField.stringValue
        Task { @MainActor [weak self] in
            do {
                try await ROBMLXEngine.shared.remember(text)
                self?.appendLog("[mlx memory] stored locally")
            } catch { self?.report(error) }
        }
    }

    @objc private func retrieveWithMLX(_ sender: Any?) {
        let query = mlxMemoryField.stringValue
        Task { @MainActor [weak self] in
            do {
                let matches = try await ROBMLXEngine.shared.retrieve(query)
                let result = matches.map { String(format: "%.3f %@", $0.similarity, $0.text) }.joined(separator: " | ")
                self?.appendLog("[mlx retrieval] \(result.isEmpty ? "no memories" : result)")
            } catch { self?.report(error) }
        }
    }

    @objc private func saveLocalProvider(_ sender: Any?) {
        do {
            let configuration = try localConfigurationFromFields()
            try stageShowCoordinator.applyLocalImprovisationConfiguration(configuration)
            ROBLocalImprovisationSettings.save(configuration)
            localStatusLabel.stringValue = configuration.isEnabled
                ? "Saved \(configuration.providerKind.displayName). Test it before a performance."
                : "Local director disabled."
            refreshLocalStatus()
        } catch {
            report(error)
        }
    }

    @objc private func testLocalProvider(_ sender: Any?) {
        do {
            let configuration = try localConfigurationFromFields()
            guard configuration.isEnabled else {
                throw ROBLocalImprovisationError.invalidConfiguration(
                    "Enable the local stage director before testing it."
                )
            }
            try stageShowCoordinator.applyLocalImprovisationConfiguration(configuration)
            ROBLocalImprovisationSettings.save(configuration)
            localStatusLabel.stringValue = "Testing local provider…"
            stageShowCoordinator.preflightLocalImprovisationProvider { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let detail):
                    self.localStatusLabel.stringValue = "Local provider ready: \(detail)"
                    self.appendLog("[local] health and schema preflight passed")
                case .failure(let error):
                    self.localStatusLabel.stringValue = "Local provider unavailable: \(error.localizedDescription)"
                    self.appendLog("[local] preflight failed: \(error.localizedDescription)")
                }
                self.refreshLocalStatus()
            }
        } catch {
            report(error)
        }
    }

    private func start(mode: ROBStageShowRunMode) {
        do {
            let show = try decodedEditorShow()
            try stageShowCoordinator.load(show)
            stageShowCoordinator.start(mode: mode)
        } catch {
            report(error)
        }
    }

    private func decodedEditorShow() throws -> ROBStageShow {
        guard let data = editor.string.data(using: .utf8) else {
            throw ROBStageShowError.invalidDocument("The editor text is not UTF-8.")
        }
        return try ROBStageShowCodec.decode(data)
    }

    private func loadLocalProviderSettings() {
        do {
            let configuration = try ROBLocalImprovisationSettings.load()
            localEnabledButton.state = configuration.isEnabled ? .on : .off
            if let index = ROBLocalImprovisationProviderKind.allCases.firstIndex(of: configuration.providerKind) {
                localProviderPopup.selectItem(at: index)
            }
            localEndpointField.stringValue = configuration.endpointURL.absoluteString
            localModelField.stringValue = configuration.model
            localTimeoutField.stringValue = String(format: "%.1f", configuration.timeout)
            localTemperature = configuration.temperature
            try stageShowCoordinator.applyLocalImprovisationConfiguration(configuration)
        } catch {
            localEnabledButton.state = .off
            localEndpointField.stringValue = ROBLocalImprovisationConfiguration.defaultEndpoint.absoluteString
            localModelField.stringValue = ROBLocalImprovisationConfiguration.defaultModel
            localTimeoutField.stringValue = String(format: "%.1f", ROBLocalImprovisationConfiguration.defaultTimeout)
            localTemperature = ROBLocalImprovisationConfiguration.defaultTemperature
            localStatusLabel.stringValue = "Local settings invalid: \(error.localizedDescription)"
        }
        updateLocalFieldAvailability()
        refreshLocalStatus()
    }

    private func localConfigurationFromFields() throws -> ROBLocalImprovisationConfiguration {
        guard localProviderPopup.indexOfSelectedItem >= 0,
              localProviderPopup.indexOfSelectedItem < ROBLocalImprovisationProviderKind.allCases.count else {
            throw ROBLocalImprovisationError.invalidConfiguration("Select a local provider.")
        }
        let provider = ROBLocalImprovisationProviderKind.allCases[localProviderPopup.indexOfSelectedItem]
        guard let endpoint = URL(string: localEndpointField.stringValue) else {
            throw ROBLocalImprovisationError.invalidConfiguration("The local endpoint is not a valid URL.")
        }
        guard let timeout = Double(localTimeoutField.stringValue) else {
            throw ROBLocalImprovisationError.invalidConfiguration("The local timeout must be a number.")
        }
        return try ROBLocalImprovisationConfiguration(
            isEnabled: localEnabledButton.state == .on,
            providerKind: provider,
            endpointURL: endpoint,
            model: localModelField.stringValue,
            timeout: timeout,
            temperature: localTemperature
        )
    }

    private func updateLocalFieldAvailability() {
        let isLlama = localProviderPopup.indexOfSelectedItem == 0
        localEndpointField.isEnabled = isLlama
        localEndpointField.toolTip = isLlama
            ? "Loopback llama.cpp server root, /v1, or /v1/chat/completions"
            : "Not used by MLX; inference stays in this Cerebro process."
        localModelField.isEnabled = true
        localTimeoutField.isEnabled = true
    }

    private func startLocalRefreshTimer() {
        localRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshLocalStatus()
        }
        localRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshLocalStatus() {
        Task { @MainActor [weak self] in
            let mlx = await ROBMLXEngine.shared.diagnostics()
            guard let self else { return }
            func mib(_ bytes: Int) -> String { String(format: "%.0f MiB", Double(bytes) / 1_048_576) }
            var parts = ["MLX \(mlx.state)", "active \(mib(mlx.activeMemoryBytes))", "peak \(mib(mlx.peakMemoryBytes))"]
            if let latency = mlx.generationLatency { parts.append(String(format: "generation %.2f s", latency)) }
            if let rate = mlx.tokensPerSecond { parts.append(String(format: "%.1f tok/s", rate)) }
            parts.append("VLM frames \(mlx.visionFrameCount)")
            parts.append("memories \(mlx.semanticMemoryCount)")
            self.mlxTelemetryLabel.stringValue = parts.joined(separator: "  •  ")
            self.mlxTelemetryLabel.toolTip = [mlx.llmModel, mlx.vlmModel, mlx.embeddingModel, mlx.lastVisionObservation, mlx.lastError]
                .compactMap { $0 }.joined(separator: "\n")
        }
        guard let snapshot = stageShowCoordinator.localImprovisationDiagnosticsSnapshot() else {
            if localEnabledButton.state != .on {
                localStatusLabel.stringValue = "Local director disabled. Adaptive mode will use Gemini plus the authored fallback."
            }
            return
        }
        var fields = [
            snapshot.providerName,
            snapshot.state,
            "requests \(snapshot.requestCount)",
            "successes \(snapshot.successCount)",
            "fallbacks \(snapshot.fallbackCount)"
        ]
        if let latency = snapshot.lastLatency {
            fields.append(String(format: "last %.2f s", latency))
        }
        if let error = snapshot.lastErrorCategory {
            fields.append("error \(error)")
        }
        localStatusLabel.stringValue = fields.joined(separator: "  •  ")
        localStatusLabel.toolTip = [snapshot.redactedEndpoint, snapshot.model]
            .compactMap { $0 }
            .joined(separator: "  •  ")
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        statusLabel.stringValue = "Invalid: \(message)"
        appendLog("[invalid] \(message)")
        NSSound.beep()
    }

    private func appendLog(_ line: String) {
        let prefix = logView.string.isEmpty ? "" : "\n"
        logView.string += prefix + line
        logView.scrollToEndOfDocument(nil)
    }
}
