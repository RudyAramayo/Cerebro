//
//  ROBGeminiDiagnosticsWindowController.swift
//  Cerebro
//
//  Runtime controls and redacted diagnostics for Gemini Robotics Live.
//

import AppKit
import Foundation

@objc public protocol ROBGeminiRuntimeControlDelegate: AnyObject {
    func setGeminiConnectionEnabled(_ enabled: Bool)
    func setGeminiMicrophoneStreamingEnabled(_ enabled: Bool)
    func setGeminiCameraStreamingEnabled(_ enabled: Bool)
}

@available(macOS 10.15, *)
@objcMembers public final class ROBGeminiDiagnosticsWindowController: NSWindowController, NSWindowDelegate {
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
            case .videoStreaming: return "Camera streaming requested"
            case .inputMode: return "Active input path"
            case .responseModality: return "Response modality"
            case .googleSearch: return "Google Search enabled"
            case .newsSearch: return "Read-only news search enabled"
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 920),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "AI Provider Control & Diagnostics"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        configureContentView(for: window)
        refresh()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refresh()
        startRefreshTimer()
    }

    public func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func configureContentView(for window: NSWindow) {
        let contentView = NSView(frame: NSRect(
            origin: .zero,
            size: window.contentLayoutRect.size
        ))
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        let heading = NSTextField(labelWithString: "Gemini Robotics runtime")
        heading.font = .boldSystemFont(ofSize: 17)

        let explanation = wrappingLabel(
            "Gemini is Cerebro's preferred live provider for direct microphone audio and sampled camera frames. Ordinary conversation automatically falls back to Apple Foundation Models, then Swift MLX, when Live cannot answer. Install a personal key below; it is stored only in this Mac's Keychain."
        )
        explanation.textColor = .secondaryLabelColor
        explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let credentialHeading = NSTextField(labelWithString: "Gemini Live personal API key")
        credentialHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        apiKeyField = NSSecureTextField(string: "")
        apiKeyField.placeholderString = "Paste API key"
        apiKeyField.setAccessibilityLabel("Gemini Live API key")
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
            apiKeyField,
            credentialButtons,
            credentialStatusLabel
        ])
        credentialControls.orientation = .vertical
        credentialControls.alignment = .leading
        credentialControls.spacing = 6

        connectionToggle = NSButton(
            checkboxWithTitle: "Connect to Gemini",
            target: self,
            action: #selector(connectionToggleChanged(_:))
        )
        microphoneToggle = NSButton(
            checkboxWithTitle: "Send microphone audio to Gemini",
            target: self,
            action: #selector(microphoneToggleChanged(_:))
        )
        cameraToggle = NSButton(
            checkboxWithTitle: "Send sampled camera frames to Gemini",
            target: self,
            action: #selector(cameraToggleChanged(_:))
        )
        connectionToggle.setAccessibilityHelp(
            "Opens or closes Cerebro's Gemini Live connection."
        )
        microphoneToggle.setAccessibilityHelp(
            "Controls whether Cerebro sends raw microphone audio to Gemini."
        )
        cameraToggle.setAccessibilityHelp(
            "Controls Gemini camera sampling without changing controller video subscriptions."
        )

        let microphoneHelp = wrappingLabel(
            "When off, ROB keeps Apple local speech recognition and submits recognized text only while the Gemini connection is on."
        )
        microphoneHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        microphoneHelp.textColor = .secondaryLabelColor
        microphoneHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cameraHelp = wrappingLabel(
            "This switch controls only Gemini's sampled camera input. It does not disable Cerebro perception or paired ROBController/Vision Pro video subscriptions."
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
            "Counters cover the lifetime of this ROBAI instance. A sent frame completed the local WebSocket send; Gemini does not acknowledge individual video frames. Local fallbacks are dialogue-only and never receive motion tools. Diagnostics never retain credentials, media, transcript text, tool arguments, or raw server messages."
        )
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [heading, explanation, credentialControls, controls, separator, grid, note])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: explanation)
        stack.setCustomSpacing(14, after: controls)
        stack.setCustomSpacing(14, after: grid)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            credentialControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            apiKeyField.widthAnchor.constraint(equalTo: credentialControls.widthAnchor),
            credentialStatusLabel.widthAnchor.constraint(equalTo: credentialControls.widthAnchor),
            microphoneHelp.widthAnchor.constraint(equalTo: controls.widthAnchor),
            cameraHelp.widthAnchor.constraint(equalTo: controls.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
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
            try ROBProviderCredentialStore.saveAPIKey(apiKeyField.stringValue, for: .gemini)
            apiKeyField.stringValue = ""
            credentialStatusLabel.textColor = .systemGreen
            credentialStatusLabel.stringValue = robAI?.isConfigured == true
                ? "Key updated securely. Relaunch Cerebro to load the new credential."
                : "Key saved securely. Relaunch Cerebro once to initialize Gemini Live."
        } catch {
            credentialStatusLabel.textColor = .systemRed
            credentialStatusLabel.stringValue = error.localizedDescription
        }
        refresh()
    }

    @objc private func removeAPIKey(_ sender: Any?) {
        do {
            try ROBProviderCredentialStore.removeAPIKey(for: .gemini)
            apiKeyField.stringValue = ""
            credentialStatusLabel.textColor = .secondaryLabelColor
            credentialStatusLabel.stringValue = robAI?.isConfigured == true
                ? "Personal key removed. Relaunch Cerebro to discard the loaded credential; an environment credential remains independent."
                : "Personal key removed. An environment credential, if configured, remains independent."
        } catch {
            credentialStatusLabel.textColor = .systemRed
            credentialStatusLabel.stringValue = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        if credentialStatusLabel?.stringValue.isEmpty == true {
            credentialStatusLabel.stringValue = ROBProviderCredentialStore.apiKey(for: .gemini) == nil
                ? "No personal Gemini key is installed."
                : "A personal Gemini key is installed in Keychain."
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
            ? "Close or open the Gemini Live WebSocket session"
            : "Launch Cerebro with Gemini enabled and a credential before connecting"
        microphoneToggle.toolTip = snapshot.isConfigured
            ? "Enable or disable raw microphone streaming while Gemini is connected"
            : "Launch Cerebro with Gemini enabled and a credential before changing microphone streaming"
        cameraToggle.toolTip = snapshot.isConfigured
            ? "Enable or disable sampled camera input to Gemini"
            : "Launch Cerebro with Gemini enabled and a credential before changing camera streaming"

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
