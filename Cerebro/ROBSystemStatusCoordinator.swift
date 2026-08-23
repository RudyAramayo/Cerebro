//
//  ROBSystemStatusCoordinator.swift
//  Cerebro
//
//  Side-effect-free aggregation of already-cached runtime diagnostics.
//

import AppKit
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
@objcMembers final class ROBSystemStatusCoordinator: NSObject {
    private weak var robAI: ROBAI?
    private weak var cameraViewController: CameraViewController?
    private weak var autoNetServer: AutoNetServer?
    private weak var stageShowCoordinator: ROBStageShowCoordinator?

    private var latestMLXDiagnostics: ROBMLXDiagnosticsSnapshot?
    private var mlxRefreshInFlight = false

    private lazy var statusWindowController = ROBSystemStatusWindowController(
        snapshotProvider: { [weak self] in
            self?.snapshot() ?? ROBSystemStatusSnapshot(services: [], controllers: [])
        }
    )

    @objc(initWithRobAI:cameraViewController:autoNetServer:stageShowCoordinator:)
    init(
        robAI: ROBAI?,
        cameraViewController: CameraViewController?,
        autoNetServer: AutoNetServer?,
        stageShowCoordinator: ROBStageShowCoordinator?
    ) {
        self.robAI = robAI
        self.cameraViewController = cameraViewController
        self.autoNetServer = autoNetServer
        self.stageShowCoordinator = stageShowCoordinator
        super.init()
        refreshMLXCache()
    }

    @objc(showWindow:)
    func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        statusWindowController.showWindow(sender)
    }

    @objc(refreshNow:)
    func refreshNow(_ sender: Any?) {
        statusWindowController.refreshNow(sender)
    }

    private func snapshot() -> ROBSystemStatusSnapshot {
        refreshMLXCache()
        let now = Date()
        let camera = cameraViewController?.serviceStatusSnapshot()
        let control = autoNetServer?.statusSnapshot()
        let media = camera?.videoServer

        let services: [ROBSystemServiceCardSnapshot] = [
            geminiCard(now: now),
            appleFoundationModelsCard(),
            mlxCard(),
            localStageModelCard(),
            messagesBridgeCard(now: now),
            mainCameraCard(camera, now: now),
            insta360Card(now: now),
            mediaCard(media, startupError: camera?.videoServerStartupError),
            controllerListenerCard(control),
        ]

        let controllers = control?.connections.map { connection in
            controllerCard(connection, media: media)
        } ?? []
        return ROBSystemStatusSnapshot(
            capturedAt: now,
            services: services,
            controllers: controllers
        )
    }

    private func geminiCard(now: Date) -> ROBSystemServiceCardSnapshot {
        guard let robAI else {
            return ROBSystemServiceCardSnapshot(
                id: "gemini-live",
                displayName: "Gemini Live",
                category: .languageModels,
                state: .unavailable,
                detail: "The Gemini runtime owner has not been created."
            )
        }
        let snapshot = robAI.diagnosticsSnapshot()
        let sourceSettings = ROBGeminiVideoSourceSettings.shared
        let selectedVideoSources = [
            sourceSettings.mainCameraEnabled ? "Main" : nil,
            sourceSettings.insta360Enabled ? "Insta360" : nil,
        ].compactMap { $0 }.joined(separator: " + ")
        let normalized = snapshot.connectionState.lowercased()
        let state: ROBSystemServiceState
        let detail: String
        if !snapshot.isConfigured {
            state = .unavailable
            detail = "No Gemini Live configuration is available."
        } else if !snapshot.isConnectionEnabled {
            state = .disabled
            detail = "Gemini Live is disabled in runtime settings."
        } else if normalized == "ready" {
            state = .healthy
            detail = "Live session ready; \(snapshot.inputMode.displayName)."
        } else if normalized.contains("connect") || normalized.contains("setup") || normalized.contains("start") {
            state = .working
            detail = "Live session \(snapshot.connectionState)."
        } else if normalized.contains("fail") || normalized.contains("error") {
            state = .degraded
            detail = "Live session \(snapshot.connectionState); local fallback remains separate."
        } else {
            state = .unknown
            detail = "Live session state: \(snapshot.connectionState)."
        }

        let eventDate = [snapshot.lastServerEventDate, snapshot.lastRequestFailureDate]
            .compactMap { $0 }
            .max()
        return ROBSystemServiceCardSnapshot(
            id: "gemini-live",
            displayName: "Gemini Live",
            category: .languageModels,
            state: state,
            detail: detail,
            age: eventDate.map { max(0, now.timeIntervalSince($0)) },
            metrics: [
                .init(label: "Model", value: snapshot.model ?? "Not configured"),
                .init(label: "Google Search", value: snapshot.enablesGoogleSearch ? "Enabled" : "Disabled"),
                .init(label: "News tool", value: snapshot.enablesNewsSearch ? "Enabled" : "Disabled"),
                .init(label: "Apple Music tool", value: snapshot.enablesAppleMusic ? "Enabled" : "Disabled"),
                .init(label: "Audio / video", value: "\(snapshot.isAudioStreamingApplied ? "on" : "off") / \(snapshot.isVideoStreamingApplied ? "on" : "off")"),
                .init(label: "Video sources", value: selectedVideoSources.isEmpty ? "None" : selectedVideoSources),
                .init(label: "On-device fallbacks", value: "\(snapshot.localFallbackCount)"),
            ]
        )
    }

    private func appleFoundationModelsCard() -> ROBSystemServiceCardSnapshot {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            if case .available = availability {
                return ROBSystemServiceCardSnapshot(
                    id: "apple-foundation-models",
                    displayName: "Apple Foundation Models",
                    category: .languageModels,
                    state: .healthy,
                    detail: "Available for private on-device conversational fallback."
                )
            }
            return ROBSystemServiceCardSnapshot(
                id: "apple-foundation-models",
                displayName: "Apple Foundation Models",
                category: .languageModels,
                state: .unavailable,
                detail: "On-device model availability: \(String(describing: availability))."
            )
        }
        #endif
        return ROBSystemServiceCardSnapshot(
            id: "apple-foundation-models",
            displayName: "Apple Foundation Models",
            category: .languageModels,
            state: .unavailable,
            detail: "This macOS build does not expose Foundation Models."
        )
    }

    private func mlxCard() -> ROBSystemServiceCardSnapshot {
        guard let diagnostics = latestMLXDiagnostics else {
            return ROBSystemServiceCardSnapshot(
                id: "mlx-local-models",
                displayName: "MLX Local Models",
                category: .languageModels,
                state: .working,
                detail: "Reading cached MLX diagnostics…"
            )
        }
        let state = semanticState(for: diagnostics.state, idleIsHealthy: false)
        let detail: String
        if let error = diagnostics.lastError, !error.isEmpty {
            detail = "\(diagnostics.state): \(bounded(error))"
        } else if let download = diagnostics.downloadDetail, !download.isEmpty {
            detail = download
        } else {
            detail = "Local LLM/VLM runtime \(diagnostics.state)."
        }
        return ROBSystemServiceCardSnapshot(
            id: "mlx-local-models",
            displayName: "MLX Local Models",
            category: .languageModels,
            state: state,
            detail: detail,
            metrics: [
                .init(label: "LLM", value: diagnostics.llmModel),
                .init(label: "VLM", value: diagnostics.vlmModel),
                .init(label: "Vision frames", value: "\(diagnostics.visionFrameCount)"),
                .init(label: "Active memory", value: bytes(diagnostics.activeMemoryBytes)),
                .init(label: "Peak memory", value: bytes(diagnostics.peakMemoryBytes)),
            ]
        )
    }

    private func localStageModelCard() -> ROBSystemServiceCardSnapshot {
        let configuration = try? ROBLocalImprovisationSettings.load()
        guard configuration?.isEnabled == true else {
            return ROBSystemServiceCardSnapshot(
                id: "stage-local-llm",
                displayName: "Stage Local LLM",
                category: .languageModels,
                state: .disabled,
                detail: "Local stage improvisation is disabled."
            )
        }
        guard let diagnostics = stageShowCoordinator?.localImprovisationDiagnosticsSnapshot() else {
            return ROBSystemServiceCardSnapshot(
                id: "stage-local-llm",
                displayName: "Stage Local LLM",
                category: .languageModels,
                state: .unknown,
                detail: "Configured, but no provider snapshot is currently available."
            )
        }
        return ROBSystemServiceCardSnapshot(
            id: "stage-local-llm",
            displayName: "Stage Local LLM",
            category: .languageModels,
            state: semanticState(for: diagnostics.state, idleIsHealthy: true),
            detail: "\(diagnostics.providerName): \(diagnostics.state).",
            metrics: [
                .init(label: "Model", value: diagnostics.model ?? "Not reported"),
                .init(label: "Requests", value: "\(diagnostics.requestCount)"),
                .init(label: "Successes", value: "\(diagnostics.successCount)"),
                .init(label: "Fallbacks", value: "\(diagnostics.fallbackCount)"),
            ]
        )
    }

    private func messagesBridgeCard(now: Date) -> ROBSystemServiceCardSnapshot {
        // This accessor returns the bridge's in-memory status only. The
        // Services panel must never poll Messages, connect AI, or request a
        // privacy permission merely because it is visible.
        let snapshot = ROBMessagesBridge.shared.statusSnapshot()
        let normalized = snapshot.state.lowercased()
        let state: ROBSystemServiceState
        let detail: String
        if !snapshot.enabled || normalized == "disabled" || normalized == "stopped" {
            state = .disabled
            detail = "Text-only Messages replies are disabled."
        } else if normalized == "listening" {
            state = .healthy
            detail = "Listening for approved one-to-one Messages conversations."
        } else if normalized == "processing" || normalized == "starting" {
            state = .working
            detail = normalized == "starting"
                ? "Checking cached configuration and local inbox access."
                : "Generating isolated text replies for approved Messages chats."
        } else if normalized.contains("configuration required") ||
                    normalized.contains("full disk access") ||
                    normalized.contains("automation permission") ||
                    normalized.contains("ai unavailable") ||
                    normalized.contains("transcript archive") {
            state = .unavailable
            if normalized.contains("full disk access") {
                detail = "Full Disk Access is required to read the local Messages inbox."
            } else if normalized.contains("automation permission") {
                detail = "Automation permission is required to return replies through Messages."
            } else if normalized.contains("ai unavailable") {
                detail = "The isolated text-only Messages AI session is unavailable."
            } else if normalized.contains("transcript archive") {
                detail = "The encrypted Messages transcript is unavailable; no unarchived reply was sent."
            } else {
                detail = "A receiving account and at least one approved sender are required."
            }
        } else if normalized.contains("rate limited") || normalized.contains("error") {
            state = .degraded
            if normalized.contains("rate limited") {
                detail = "Inbound Messages are temporarily rate limited to prevent reply loops."
            } else if let deliveryError = snapshot.lastDeliveryError {
                detail = "Messages reply delivery failed: \(bounded(deliveryError))"
            } else {
                detail = "The Messages bridge reported an error; check its settings and macOS permissions."
            }
        } else {
            state = .unknown
            detail = "Cached bridge state: \(bounded(snapshot.state))."
        }
        let eventDate = [snapshot.lastInboundAt, snapshot.lastReplyAt]
            .compactMap { $0 }
            .max()
        let authorization = snapshot.allowAllSenders
            ? "Public: all remote senders"
            : "Restricted: \(snapshot.allowedSenderCount) authorized remote sender\(snapshot.allowedSenderCount == 1 ? "" : "s")"
        let providerLabel = snapshot.activeAIProvider == nil
            ? "Last AI provider"
            : "Active AI provider"
        let provider = snapshot.activeAIProvider
            ?? snapshot.lastAIProvider
            ?? "None"
        let lastAIError = snapshot.lastAIError.map { bounded($0) } ?? "None"
        let lastDeliveryError = snapshot.lastDeliveryError.map { bounded($0) } ?? "None"
        let lastTranscriptError = snapshot.lastTranscriptError.map { bounded($0) } ?? "None"
        let transcriptMode = snapshot.archivesTranscripts
            ? "Encrypted, \(snapshot.archivedTransactionCount) transaction\(snapshot.archivedTransactionCount == 1 ? "" : "s")"
            : "Disabled"
        let imageMode = !snapshot.allowsImages
            ? "Disabled"
            : (snapshot.allowsGeminiImages
                ? "Gemini, then Swift MLX → Apple FM"
                : "Local Swift MLX → Apple FM")
        return ROBSystemServiceCardSnapshot(
            id: "messages-ai-bridge",
            displayName: "Messages AI Bridge",
            category: .connectivity,
            state: state,
            // Provider status and bounded AI errors are diagnostic metadata.
            // Never expose inbound or reply message text in this card.
            detail: detail,
            age: eventDate.map { max(0, now.timeIntervalSince($0)) },
            metrics: [
                .init(label: "Authorization", value: authorization),
                .init(label: providerLabel, value: bounded(provider)),
                .init(label: "Last AI error", value: lastAIError),
                .init(label: "Last delivery error", value: lastDeliveryError),
                .init(label: "Transcript archive", value: transcriptMode),
                .init(label: "Last transcript error", value: lastTranscriptError),
                .init(label: "Images", value: imageMode),
                .init(label: "Pending replies", value: "\(snapshot.pendingReplyCount)"),
                .init(label: "AI chats", value: "\(snapshot.activeAIChatCount)"),
                .init(label: "Output", value: "Messages only"),
            ]
        )
    }

    private func mainCameraCard(
        _ camera: ROBCameraServiceStatusSnapshot?,
        now: Date
    ) -> ROBSystemServiceCardSnapshot {
        guard let camera else {
            return ROBSystemServiceCardSnapshot(
                id: "main-camera",
                displayName: "Main Camera Feed",
                category: .perception,
                state: .unavailable,
                detail: "The camera controller has not been created."
            )
        }
        let consumers = [
            camera.visibleConsumer ? "preview" : nil,
            camera.automaticProcessingConsumer ? "perception" : nil,
            camera.geminiConsumer ? "Gemini" : nil,
            camera.remoteMediaConsumer ? "controller media" : nil,
        ].compactMap { $0 }
        let state: ROBSystemServiceState
        switch camera.state {
        case CameraSourceState.streamingRGB.rawValue, CameraSourceState.streamingRGBD.rawValue:
            let frameAge = camera.lastFrameAt.map { now.timeIntervalSince($0) } ?? .infinity
            state = frameAge <= 5 ? .healthy : .degraded
        case CameraSourceState.connecting.rawValue, CameraSourceState.reconnecting.rawValue:
            state = .working
        case CameraSourceState.stopped.rawValue:
            state = camera.sessionRequested ? .degraded : .idle
        case CameraSourceState.unavailable.rawValue:
            state = .unavailable
        default:
            state = .unknown
        }
        let detail = camera.detail.flatMap(nonempty)
            ?? (consumers.isEmpty ? "Demand-driven capture is idle." : "Consumers: \(consumers.joined(separator: ", ")).")
        return ROBSystemServiceCardSnapshot(
            id: "main-camera",
            displayName: "Main Camera Feed",
            category: .perception,
            state: state,
            detail: detail,
            age: camera.lastFrameAt.map { max(0, now.timeIntervalSince($0)) },
            metrics: [
                .init(label: "State", value: camera.state),
                .init(label: "Frames", value: "\(camera.framesReceived)"),
                .init(label: "Consumers", value: consumers.isEmpty ? "None" : consumers.joined(separator: ", ")),
            ]
        )
    }

    private func insta360Card(now: Date) -> ROBSystemServiceCardSnapshot {
        let service = ROBInsta360CameraService.shared
        let status = service.statusSnapshot()
        let registry = ROBDynamicDetectorRegistry.shared
        let geminiVideoSettings = ROBGeminiVideoSourceSettings.shared
        let lower = status.state.lowercased()
        let state: ROBSystemServiceState
        if !status.desiredRunning {
            state = .disabled
        } else if status.lastError != nil {
            state = .degraded
        } else if lower.contains("suspended") {
            state = .idle
        } else if status.decoderActive {
            if let lastFrameAt = status.lastFrameAt {
                state = now.timeIntervalSince(lastFrameAt) <= 5 ? .healthy : .degraded
            } else {
                state = .working
            }
        } else if lower.contains("stream") || lower.contains("receiv") || lower.contains("running") {
            state = .working
        } else if lower.contains("connect") || lower.contains("start") || lower.contains("retry") || lower.contains("restart") {
            state = .working
        } else if lower == "stopped" {
            state = .unavailable
        } else {
            state = .unknown
        }
        let scene = ROBSceneSnapshotStore.shared.snapshot()
        let people = scene.people.filter { $0.id.hasPrefix("insta360-") }.count
        let needsFrames = registry.requiresFrames(for: .insta360)
            || (registry.processingFramesPerSecond(for: .insta360) > 0
                && ROBMLXRuntime.shared.insta360DetectionEnabled)
        let geometry = registry.insta360AnalysisGeometry == .sixSectors
            ? "Six sectors"
            : "Stitched panorama"
        let orientation = geminiVideoSettings.insta360OrientationCalibrated
            ? String(
                format: "Forward at %.0f°",
                geminiVideoSettings.insta360ForwardMarkerDegrees
            )
            : "Uncalibrated"
        return ROBSystemServiceCardSnapshot(
            id: "insta360",
            displayName: "Insta360 360° Feed",
            category: .perception,
            state: state,
            detail: status.lastError.map(bounded) ?? status.state,
            age: status.lastFrameAt.map { max(0, now.timeIntervalSince($0)) },
            metrics: [
                .init(label: "Frames", value: "\(status.framesReceived)"),
                .init(label: "Decode rate", value: String(format: "%.1f FPS", status.framesPerSecond)),
                .init(label: "Analysis", value: status.analysisNeedsFrames && needsFrames ? geometry : "Disabled"),
                .init(label: "Gemini composite", value: status.geminiVideoDemandActive ? "Active" : "Inactive"),
                .init(
                    label: "Local Network",
                    value: status.localNetworkPermissionDenied
                        ? "Permission denied"
                        : "No denial detected"
                ),
                .init(label: "Robot-relative orientation", value: orientation),
                .init(label: "Fresh people", value: "\(people)"),
            ]
        )
    }

    private func mediaCard(
        _ media: ROBVideoServerStatusSnapshot?,
        startupError: String?
    ) -> ROBSystemServiceCardSnapshot {
        guard let media else {
            return ROBSystemServiceCardSnapshot(
                id: "controller-media",
                displayName: "Vision Pro / Controller Media",
                category: .connectivity,
                state: .unavailable,
                detail: startupError.map(bounded) ?? "The optional media listener is unavailable."
            )
        }
        let state: ROBSystemServiceState
        if !media.subscriptions.isEmpty {
            state = .working
        } else if media.listenerState == "ready" {
            state = .idle
        } else {
            state = semanticState(for: media.listenerState, idleIsHealthy: false)
        }
        let detail = media.subscriptions.isEmpty
            ? (media.detail ?? "Ready; no authenticated media subscription.")
            : "Streaming to \(media.subscriptions.count) authenticated controller session\(media.subscriptions.count == 1 ? "" : "s")."
        return ROBSystemServiceCardSnapshot(
            id: "controller-media",
            displayName: "Vision Pro / Controller Media",
            category: .connectivity,
            state: state,
            detail: detail,
            metrics: [
                .init(label: "Connections", value: "\(media.connectionCount)"),
                .init(label: "Active streams", value: "\(media.subscriptions.count)"),
                .init(label: "Camera", value: media.cameraAvailability),
            ]
        )
    }

    private func controllerListenerCard(
        _ control: ROBControlServerStatusSnapshot?
    ) -> ROBSystemServiceCardSnapshot {
        guard let control else {
            return ROBSystemServiceCardSnapshot(
                id: "robcontroller-listener",
                displayName: "ROBController Listener",
                category: .connectivity,
                state: .unavailable,
                detail: "The controller listener has not been created."
            )
        }
        let state: ROBSystemServiceState
        if control.isPaused {
            state = .disabled
        } else if control.listenerState == "ready" {
            state = control.connections.isEmpty ? .idle : .healthy
        } else {
            state = semanticState(for: control.listenerState, idleIsHealthy: false)
        }
        return ROBSystemServiceCardSnapshot(
            id: "robcontroller-listener",
            displayName: "ROBController Listener",
            category: .connectivity,
            state: state,
            detail: control.isPaused
                ? "Controller message delivery is paused."
                : (control.detail ?? "\(control.listenerState); \(control.connections.count) live transport connection\(control.connections.count == 1 ? "" : "s")."),
            metrics: [
                .init(label: "Listener", value: control.listenerState),
                .init(label: "Connections", value: "\(control.connections.count)"),
            ]
        )
    }

    private func controllerCard(
        _ connection: ROBControlConnectionStatusSnapshot,
        media: ROBVideoServerStatusSnapshot?
    ) -> ROBControllerSessionCardSnapshot {
        let exactMedia = media?.subscriptions.first {
            $0.controllerID == connection.deviceID && $0.sessionID == connection.sessionID
        }
        let network = connection.network
        var metrics: [ROBSystemStatusMetric] = [
            .init(
                label: "RX",
                value: "\(networkRate(network.receivedBytesPerSecond)) · \(messageRate(network.receivedMessagesPerSecond))"
            ),
            .init(
                label: "TX",
                value: "\(networkRate(network.sentBytesPerSecond)) · \(messageRate(network.sentMessagesPerSecond))"
            ),
            .init(
                label: "Round trip",
                value: networkRoundTrip(connection)
            ),
            .init(
                label: "Traffic total",
                value: "RX \(byteCount(network.totalReceivedBytes)) · TX \(byteCount(network.totalSentBytes))"
            ),
            .init(
                label: "Probe replies",
                value: "\(network.probeReplies)/\(network.probesSent) · \(network.consecutiveProbeMisses) consecutive misses"
            ),
        ]
        if connection.usesLegacyTransport {
            metrics.append(.init(label: "Security", value: "Legacy plaintext compatibility"))
        } else {
            metrics.append(.init(label: "Security", value: "QUIC/TLS"))
        }
        if let exactMedia {
            metrics.append(.init(label: "Media", value: exactMedia.profile))
        }
        let roleName = connection.role == "operatorController"
            ? "Operator Controller"
            : connection.role == "lidarPublisher" ? "Lidar Publisher" : "Controller Connection"
        let probeDegraded = network.probeSupported && network.consecutiveProbeMisses >= 2
        let detail: String
        if probeDegraded {
            detail = "Network test is missing replies; live RX/TX counters remain active."
        } else if exactMedia != nil {
            detail = "Control and media sessions are both active."
        } else if network.probeSupported {
            detail = "Authenticated transport is active with a live echo and throughput test."
        } else {
            detail = "Authenticated transport state: \(connection.state); negotiating network test support."
        }
        return ROBControllerSessionCardSnapshot(
            stableID: connection.stableID,
            displayName: connection.deviceName ?? roleName,
            state: probeDegraded ? .degraded : (connection.state == "ready" ? .healthy : .working),
            detail: detail,
            role: connection.role,
            deviceIdentifier: shortID(connection.deviceID),
            sessionIdentifier: shortID(connection.sessionID),
            age: network.lastReceiveAge,
            metrics: metrics
        )
    }

    private func networkRoundTrip(_ connection: ROBControlConnectionStatusSnapshot) -> String {
        let network = connection.network
        if let milliseconds = network.roundTripMilliseconds {
            return String(format: "%.1f ms", milliseconds)
        }
        if connection.usesLegacyTransport {
            return "Unavailable on legacy transport"
        }
        return network.probeSupported ? "Waiting for echo" : "Negotiating"
    }

    private func networkRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "Unknown" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(bytesPerSecond.rounded()),
            countStyle: .file
        ) + "/s"
    }

    private func messageRate(_ messagesPerSecond: Double) -> String {
        guard messagesPerSecond.isFinite, messagesPerSecond >= 0 else { return "Unknown" }
        return String(format: "%.1f msg/s", messagesPerSecond)
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .file
        )
    }

    private func refreshMLXCache() {
        guard !mlxRefreshInFlight else { return }
        mlxRefreshInFlight = true
        Task { [weak self] in
            let diagnostics = await ROBMLXEngine.shared.diagnostics()
            guard let self else { return }
            self.latestMLXDiagnostics = diagnostics
            self.mlxRefreshInFlight = false
        }
    }

    private func semanticState(
        for rawState: String,
        idleIsHealthy: Bool
    ) -> ROBSystemServiceState {
        let state = rawState.lowercased()
        if state.contains("unavailable") { return .unavailable }
        if state.contains("ready") || state.contains("healthy") || state.contains("available") {
            return .healthy
        }
        if state.contains("load") || state.contains("start") || state.contains("connect") || state.contains("work") {
            return .working
        }
        if state.contains("disable") || state.contains("stopped") { return .disabled }
        if state.contains("idle") { return idleIsHealthy ? .healthy : .idle }
        if state.contains("fail") || state.contains("error") { return .degraded }
        return .unknown
    }

    private func shortID(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.count > 12 ? String(value.prefix(8)) + "…" : value
    }

    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bounded(_ value: String) -> String {
        let singleLine = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return singleLine.count > 240 ? String(singleLine.prefix(240)) + "…" : singleLine
    }

    private func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .memory)
    }
}
