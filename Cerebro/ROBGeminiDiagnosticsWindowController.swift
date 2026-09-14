//
//  ROBGeminiDiagnosticsWindowController.swift
//  Cerebro
//
//  Provider preferences, runtime controls and redacted live AI diagnostics.
//

import AppKit
import AVFoundation
import Foundation

private final class ROBFlippedGeminiSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@objc public protocol ROBGeminiRuntimeControlDelegate: AnyObject {
    func reloadRealtimeConfiguration()
    func setGeminiConnectionEnabled(_ enabled: Bool)
    func setGeminiMicrophoneStreamingEnabled(_ enabled: Bool)
    func setGeminiCameraStreamingEnabled(_ enabled: Bool)
}

@available(macOS 10.15, *)
@objcMembers public final class ROBGeminiSettingsViewController: NSViewController {
    private enum Row: CaseIterable {
        case configured
        case connectionRequested
        case connection
        case model
        case audioStreaming
        case videoStreaming
        case inputMode
        case responseModality
        case googleSearch
        case newsSearch
        case appleMusic
        case robotActionTool
        case videoFramesEncoded
        case videoFramesSent
        case lastVideoSend
        case lastServerEvent
        case lastServerEventTime
        case lastRequestFailure
        case serverInputTranscription
        case rawTurnTimeouts
        case localFallback

        var title: String {
            switch self {
            case .configured: return "Launch configuration loaded"
            case .connectionRequested: return "Connection requested"
            case .connection: return "Connection state"
            case .model: return "Model"
            case .audioStreaming: return "Microphone streaming requested"
            case .videoStreaming: return "Camera composite streaming requested"
            case .inputMode: return "Active input path"
            case .responseModality: return "Response modality"
            case .googleSearch: return "Google Search enabled"
            case .newsSearch: return "Read-only news search enabled"
            case .appleMusic: return "Apple Music tool enabled"
            case .robotActionTool: return "Robot action tool exposed"
            case .videoFramesEncoded: return "Video frames encoded"
            case .videoFramesSent: return "Video frames sent"
            case .lastVideoSend: return "Last video send"
            case .lastServerEvent: return "Last server event"
            case .lastServerEventTime: return "Last server event time"
            case .lastRequestFailure: return "Last request failure"
            case .serverInputTranscription: return "Server input transcription"
            case .rawTurnTimeouts: return "Raw turn timeouts"
            case .localFallback: return "On-device fallback"
            }
        }
    }

    public weak var controlDelegate: ROBGeminiRuntimeControlDelegate?
    private weak var robAI: ROBAI?
    private var connectionToggle: NSButton!
    private var microphoneToggle: NSButton!
    private var cameraToggle: NSButton!
    private var apiKeyField: NSSecureTextField!
    private let modePopup = NSPopUpButton()
    private let driverPopup = NSPopUpButton()
    private let credentialProviderPopup = NSPopUpButton()
    private let modelField = NSTextField()
    private let linesPopup = NSPopUpButton()
    private let geminiCharacterField = NSTextField()
    private let openAICharacterField = NSTextField()
    private let geminiVoicePopup = NSPopUpButton()
    private let openAIVoicePopup = NSPopUpButton()
    private let personalityStatus = NSTextField(wrappingLabelWithString: "")
    private var banterButton: NSButton!
    private var credentialStatusLabel: NSTextField!
    private var valueLabels: [Row: NSTextField] = [:]
    private var refreshTimer: Timer?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    public init(robAI: ROBAI) {
        self.robAI = robAI
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopRefreshTimer()
    }

    public override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 580))
        view = content
        configureContentView(in: content)
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        refreshSettings()
        startRefreshTimer()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        stopRefreshTimer()
    }

    public func refreshSettings() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshSettings() }
            return
        }
        loadViewIfNeeded()
        refresh()
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func configureContentView(in contentView: NSView) {
        let heading = NSTextField(labelWithString: "AI Personalities")
        heading.font = .boldSystemFont(ofSize: 17)

        let explanation = wrappingLabel(
            "Choose one live AI or two fictional robot characters. In Dual Personality, the driver receives wake-gated microphone audio and both providers receive enabled camera images. The characters exchange text and take turns speaking. Each API uses its own account and billing. Local motion checks remain in charge."
        )
        explanation.textColor = .secondaryLabelColor
        explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let credentialHeading = NSTextField(labelWithString: "Provider API key")
        credentialHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        credentialProviderPopup.addItems(withTitles: ROBRealtimeProvider.allCases.map(\.displayName))
        credentialProviderPopup.target = self
        credentialProviderPopup.action = #selector(credentialProviderChanged(_:))
        apiKeyField = NSSecureTextField(string: "")
        apiKeyField.placeholderString = "Paste API key"
        apiKeyField.setAccessibilityLabel("Selected provider API key")
        let saveKeyButton = NSButton(title: "Save in Keychain", target: self, action: #selector(saveAPIKey(_:)))
        let removeKeyButton = NSButton(title: "Remove Key", target: self, action: #selector(removeAPIKey(_:)))
        let credentialButtons = NSStackView(views: [saveKeyButton, removeKeyButton])
        credentialButtons.orientation = .horizontal
        credentialButtons.spacing = 8
        credentialStatusLabel = wrappingLabel("")
        credentialStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        credentialStatusLabel.textColor = .secondaryLabelColor
        let credentialControls = NSStackView(views: [
            credentialHeading,
            credentialProviderPopup,
            apiKeyField,
            credentialButtons,
            credentialStatusLabel
        ])
        credentialControls.orientation = .vertical
        credentialControls.alignment = .leading
        credentialControls.spacing = 6

        connectionToggle = NSButton(
            checkboxWithTitle: "Connect selected AI providers",
            target: self,
            action: #selector(connectionToggleChanged(_:))
        )
        microphoneToggle = NSButton(
            checkboxWithTitle: "Send microphone audio to the driver",
            target: self,
            action: #selector(microphoneToggleChanged(_:))
        )
        cameraToggle = NSButton(
            checkboxWithTitle: "Send sampled camera images to selected providers",
            target: self,
            action: #selector(cameraToggleChanged(_:))
        )
        connectionToggle.setAccessibilityHelp(
            "Opens or closes the selected provider sessions."
        )
        microphoneToggle.setAccessibilityHelp(
            "Controls whether Cerebro sends wake-gated microphone audio to the selected driver."
        )
        cameraToggle.setAccessibilityHelp(
            "Controls AI camera sampling without changing controller video subscriptions."
        )

        let microphoneHelp = wrappingLabel(
            "When off, ROB keeps Apple local speech recognition and submits recognized text while the selected driver is connected."
        )
        microphoneHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        microphoneHelp.textColor = .secondaryLabelColor
        microphoneHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cameraHelp = wrappingLabel(
            "This privacy master controls the labeled main + Insta360 composite shared with the selected providers. Choose camera sources in Settings → Perception. Local perception and paired ROBController/Vision Pro video subscriptions have separate controls."
        )
        cameraHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cameraHelp.textColor = .secondaryLabelColor
        cameraHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [
            connectionToggle,
            microphoneToggle,
            microphoneHelp,
            cameraToggle,
            cameraHelp
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 5
        controls.setCustomSpacing(10, after: connectionToggle)
        controls.setCustomSpacing(10, after: microphoneHelp)

        let gridRows: [[NSView]] = Row.allCases.map { row in
            let nameLabel = NSTextField(labelWithString: row.title)
            nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            nameLabel.textColor = .secondaryLabelColor
            nameLabel.alignment = .right

            let valueLabel = NSTextField(labelWithString: "-")
            valueLabel.setAccessibilityLabel(row.title)
            valueLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            valueLabel.isSelectable = true
            valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            if row == .lastServerEvent {
                valueLabel.maximumNumberOfLines = 3
                valueLabel.lineBreakMode = .byWordWrapping
            } else {
                valueLabel.lineBreakMode = .byTruncatingMiddle
                valueLabel.usesSingleLineMode = true
            }
            valueLabels[row] = valueLabel
            return [nameLabel, valueLabel]
        }

        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 7
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 255
        grid.column(at: 1).xPlacement = .fill

        let separator = NSBox()
        separator.boxType = .separator

        let note = wrappingLabel(
            "Counters reset when providers are reloaded. In Dual Personality they aggregate both sessions; server-event details currently cover Gemini. A sent frame completed the local WebSocket send, not a visual-understanding acknowledgement. Local fallbacks have no motion tools. Diagnostics never retain credentials, media, transcript text, tool arguments, or raw server messages."
        )
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let personalityControls = makePersonalityControls()
        let stack = NSStackView(views: [heading, explanation, personalityControls, credentialControls, controls, separator, grid, note])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: explanation)
        stack.setCustomSpacing(14, after: controls)
        stack.setCustomSpacing(14, after: grid)
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let documentView = ROBFlippedGeminiSettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            personalityControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            credentialControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            apiKeyField.widthAnchor.constraint(equalTo: credentialControls.widthAnchor),
            credentialStatusLabel.widthAnchor.constraint(equalTo: credentialControls.widthAnchor),
            microphoneHelp.widthAnchor.constraint(equalTo: controls.widthAnchor),
            cameraHelp.widthAnchor.constraint(equalTo: controls.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        refresh()
    }

    private var credentialProvider: ROBRealtimeProvider {
        credentialProviderPopup.indexOfSelectedItem == 1 ? .openAI : .gemini
    }
    @objc private func credentialProviderChanged(_ sender: Any?) {
        apiKeyField.stringValue = ""
        apiKeyField.setAccessibilityLabel("\(credentialProvider.displayName) API key")
        credentialStatusLabel.stringValue = ""
        refresh()
    }
    private func makePersonalityControls() -> NSStackView {
        let settings = ROBRealtimePreferences(defaults: .standard)
        modePopup.addItems(withTitles: ROBRealtimeMode.allCases.map(\.title))
        modePopup.selectItem(at: ROBRealtimeMode.allCases.firstIndex(of: settings.mode) ?? 0)
        driverPopup.addItems(withTitles: ROBRealtimeProvider.allCases.map(\.displayName))
        driverPopup.selectItem(at: settings.dualDriver == .openAI ? 1 : 0)
        modelField.stringValue = settings.openAIModel
        linesPopup.addItems(withTitles: (2...6).map(String.init))
        linesPopup.selectItem(withTitle: String(settings.maximumDialogueLines))
        geminiCharacterField.stringValue = settings.geminiCharacter
        openAICharacterField.stringValue = settings.openAICharacter
        for (popup, provider) in [(geminiVoicePopup, ROBRealtimeProvider.gemini), (openAIVoicePopup, .openAI)] {
            popup.addItem(withTitle: "ROB voice (character pitch)")
            popup.lastItem?.representedObject = ""
            for voice in AVSpeechSynthesisVoice.speechVoices().sorted(by: { $0.name < $1.name }) {
                popup.addItem(withTitle: "\(voice.name) — \(voice.language)")
                popup.lastItem?.representedObject = voice.identifier
            }
            let selected = UserDefaults.standard.string(forKey: ROBRealtimePreferences.prefix + "voice." + provider.rawValue) ?? ""
            if let item = popup.itemArray.first(where: { $0.representedObject as? String == selected }) { popup.select(item) }
        }
        func row(_ title: String, _ input: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let row = NSStackView(views: [label, input]); row.orientation = .horizontal; row.spacing = 10
            input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return row
        }
        let apply = NSButton(title: "Apply & Switch Driver", target: self, action: #selector(applyPersonalities(_:)))
        banterButton = NSButton(title: "Start Banter", target: self, action: #selector(startBanter(_:)))
        let stop = NSButton(title: "Stop Banter", target: self, action: #selector(stopBanter(_:)))
        let buttons = NSStackView(views: [apply, banterButton, stop])
        let help = wrappingLabel("Applying ends the current show, stops motion and reconnects the selected providers. The driver alone can propose user-requested actions. Peer replies are dialogue only. Banter waits for speech completion and stops at the selected line limit.")
        help.textColor = .secondaryLabelColor
        let views: [NSView] = [row("Mode", modePopup), row("Driver in Dual mode", driverPopup),
            row("OpenAI model", modelField), row("Lines per exchange", linesPopup),
            row("Gemini character", geminiCharacterField), row("OpenAI character", openAICharacterField),
            row("Gemini voice", geminiVoicePopup), row("OpenAI voice", openAIVoicePopup), buttons, help, personalityStatus]
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    @objc private func applyPersonalities(_ sender: Any?) {
        guard ROBRealtimePreferences.validModel(modelField.stringValue) else {
            credentialStatusLabel.stringValue = "Enter a Realtime model ID such as gpt-realtime-2.1."
            return
        }
        var settings = ROBRealtimePreferences()
        settings.mode = ROBRealtimeMode.allCases[max(0, modePopup.indexOfSelectedItem)]
        settings.dualDriver = driverPopup.indexOfSelectedItem == 1 ? .openAI : .gemini
        settings.openAIModel = modelField.stringValue
        settings.maximumDialogueLines = Int(linesPopup.titleOfSelectedItem ?? "3") ?? 3
        settings.geminiCharacter = String(geminiCharacterField.stringValue.prefix(500))
        settings.openAICharacter = String(openAICharacterField.stringValue.prefix(500))
        settings.save(to: .standard)
        for (popup, provider) in [(geminiVoicePopup, ROBRealtimeProvider.gemini), (openAIVoicePopup, .openAI)] {
            UserDefaults.standard.set(popup.selectedItem?.representedObject as? String ?? "",
                forKey: ROBRealtimePreferences.prefix + "voice." + provider.rawValue)
        }
        controlDelegate?.reloadRealtimeConfiguration()
        refresh()
    }
    @objc private func startBanter(_ sender: Any?) { robAI?.startDualDialogue() }
    @objc private func stopBanter(_ sender: Any?) {
        guard let robAI else { return }
        robAI.cancelDualDialogue()
        // The interruption delegate stops the current utterance as well.
        robAI.delegate?.robAIWasInterrupted?(robAI)
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func connectionToggleChanged(_ sender: NSButton) {
        controlDelegate?.setGeminiConnectionEnabled(sender.state == .on)
        refresh()
    }

    @objc private func microphoneToggleChanged(_ sender: NSButton) {
        controlDelegate?.setGeminiMicrophoneStreamingEnabled(sender.state == .on)
        refresh()
    }

    @objc private func cameraToggleChanged(_ sender: NSButton) {
        controlDelegate?.setGeminiCameraStreamingEnabled(sender.state == .on)
        refresh()
    }

    @objc private func saveAPIKey(_ sender: Any?) {
        do {
            try ROBProviderCredentialStore.saveAPIKey(apiKeyField.stringValue, for: credentialProvider)
            apiKeyField.stringValue = ""
            credentialStatusLabel.textColor = .systemGreen
            credentialStatusLabel.stringValue = "Key saved in this Mac's Keychain. Choose a mode and Apply to load it."
        } catch {
            credentialStatusLabel.textColor = .systemRed
            credentialStatusLabel.stringValue = error.localizedDescription
        }
        refresh()
    }

    @objc private func removeAPIKey(_ sender: Any?) {
        do {
            try ROBProviderCredentialStore.removeAPIKey(for: credentialProvider)
            apiKeyField.stringValue = ""
            credentialStatusLabel.textColor = .secondaryLabelColor
            credentialStatusLabel.stringValue = "Personal key removed; provider sessions reloaded. An environment key remains independent."
            controlDelegate?.reloadRealtimeConfiguration()
        } catch {
            credentialStatusLabel.textColor = .systemRed
            credentialStatusLabel.stringValue = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        personalityStatus.stringValue = robAI?.realtimeModeDescription ?? "AI is unavailable"
        banterButton?.isEnabled = robAI?.dualPersonalityEnabled == true && robAI?.isLiveSessionReady == true
        if credentialStatusLabel?.stringValue.isEmpty == true {
            credentialStatusLabel.stringValue = ROBProviderCredentialStore.apiKey(for: credentialProvider) == nil
                ? "No personal key for this provider is installed."
                : "This provider has a personal key in Keychain."
        }
        guard let snapshot = robAI?.diagnosticsSnapshot() else {
            valueLabels[.configured]?.stringValue = "false"
            valueLabels[.connection]?.stringValue = "unavailable"
            valueLabels[.inputMode]?.stringValue = GeminiRoboticsDiagnosticsInputMode.disabled.displayName
            connectionToggle?.state = .off
            microphoneToggle?.state = .off
            cameraToggle?.state = .off
            connectionToggle?.isEnabled = false
            microphoneToggle?.isEnabled = false
            cameraToggle?.isEnabled = false
            return
        }

        let controlsAreAvailable = snapshot.isConfigured && controlDelegate != nil
        connectionToggle.state = snapshot.isConnectionEnabled ? .on : .off
        microphoneToggle.state = snapshot.streamsAudio ? .on : .off
        cameraToggle.state = snapshot.streamsVideo ? .on : .off
        connectionToggle.isEnabled = controlsAreAvailable
        microphoneToggle.isEnabled = controlsAreAvailable
        cameraToggle.isEnabled = controlsAreAvailable
        connectionToggle.toolTip = snapshot.isConfigured
            ? "Close or open the selected provider sessions"
            : "Save a key for the selected driver and Apply before connecting"
        microphoneToggle.toolTip = snapshot.isConfigured
            ? "Enable or disable raw microphone streaming to the driver"
            : "Save a key for the selected driver and Apply before changing microphone streaming"
        cameraToggle.toolTip = snapshot.isConfigured
            ? "Enable or disable camera images sent to the selected providers"
            : "Save a key for the selected driver and Apply before changing camera streaming"

        valueLabels[.configured]?.stringValue = booleanString(snapshot.isConfigured)
        valueLabels[.connectionRequested]?.stringValue = booleanString(snapshot.isConnectionEnabled)
        valueLabels[.connection]?.stringValue = snapshot.connectionState
        valueLabels[.model]?.stringValue = snapshot.model ?? "-"
        valueLabels[.audioStreaming]?.stringValue = runtimeSettingDescription(
            requested: snapshot.streamsAudio,
            applied: snapshot.isAudioStreamingApplied
        )
        valueLabels[.videoStreaming]?.stringValue = runtimeSettingDescription(
            requested: snapshot.streamsVideo,
            applied: snapshot.isVideoStreamingApplied
        )
        valueLabels[.inputMode]?.stringValue = snapshot.inputMode.displayName
        valueLabels[.responseModality]?.stringValue = snapshot.responseModality ?? "-"
        valueLabels[.googleSearch]?.stringValue = booleanString(snapshot.enablesGoogleSearch)
        valueLabels[.newsSearch]?.stringValue = booleanString(snapshot.enablesNewsSearch)
        valueLabels[.appleMusic]?.stringValue = booleanString(snapshot.enablesAppleMusic)
        valueLabels[.robotActionTool]?.stringValue = booleanString(snapshot.exposesRobotActionTool)
        valueLabels[.videoFramesEncoded]?.stringValue = String(snapshot.videoFramesEncoded)
        valueLabels[.videoFramesSent]?.stringValue = String(snapshot.videoFramesSent)
        valueLabels[.lastVideoSend]?.stringValue = dateDescription(snapshot.lastVideoSendDate)
        let lastServerEvent = snapshot.lastServerEvent ?? "None received"
        valueLabels[.lastServerEvent]?.stringValue = lastServerEvent
        valueLabels[.lastServerEvent]?.toolTip = lastServerEvent
        valueLabels[.lastServerEventTime]?.stringValue = dateDescription(snapshot.lastServerEventDate)
        let failureCategory = snapshot.lastRequestFailureCategory ?? "None"
        valueLabels[.lastRequestFailure]?.stringValue = snapshot.lastRequestFailureDate == nil
            ? failureCategory
            : "\(failureCategory) • \(dateDescription(snapshot.lastRequestFailureDate))"
        let inputCharacterCount = snapshot.lastServerInputTranscriptionCharacterCount
            .map { "\($0) chars" } ?? "none"
        valueLabels[.serverInputTranscription]?.stringValue = snapshot.lastServerInputTranscriptionDate == nil
            ? "0 events • \(inputCharacterCount)"
            : "\(snapshot.serverInputTranscriptionEventCount) events • \(inputCharacterCount) • \(dateDescription(snapshot.lastServerInputTranscriptionDate))"
        let rawTimeoutKind = snapshot.lastRawTurnTimeoutKind ?? "none"
        valueLabels[.rawTurnTimeouts]?.stringValue = snapshot.lastRawTurnTimeoutDate == nil
            ? "0 • \(rawTimeoutKind)"
            : "\(snapshot.rawTurnTimeoutCount) • \(rawTimeoutKind) • \(dateDescription(snapshot.lastRawTurnTimeoutDate))"
        let localProvider = snapshot.lastLocalFallbackProvider ?? "None"
        valueLabels[.localFallback]?.stringValue = snapshot.lastLocalFallbackDate == nil
            ? "0 • \(localProvider)"
            : "\(snapshot.localFallbackCount) • \(localProvider) • \(dateDescription(snapshot.lastLocalFallbackDate))"
    }

    private func booleanString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func runtimeSettingDescription(requested: Bool, applied: Bool) -> String {
        guard requested else { return "false" }
        return applied ? "true (effective)" : "true (waiting)"
    }

    private func dateDescription(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let elapsed = max(0, Date().timeIntervalSince(date))
        let age: String
        if elapsed < 1 {
            age = "just now"
        } else if elapsed < 60 {
            age = String(format: "%.0f s ago", elapsed)
        } else if elapsed < 3_600 {
            age = String(format: "%.0f min ago", elapsed / 60)
        } else {
            age = String(format: "%.1f h ago", elapsed / 3_600)
        }
        return "\(dateFormatter.string(from: date)) (\(age))"
    }
}
