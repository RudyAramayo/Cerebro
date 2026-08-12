//
//  ROBStageShowCoordinator.swift
//  Cerebro
//
//  Deterministic stage-show runner. It serializes cues and keeps optional
//  Gemini improvisation behind a timeout plus authored offline fallback.
//

import Foundation

public extension Notification.Name {
    static let ROBStageShowStateDidChange = Notification.Name("ROBStageShowStateDidChange")
}

@objc public enum ROBStageShowRunMode: Int {
    case dryRun
    case speechOnly
    case adaptive
    case localOnly

    var displayName: String {
        switch self {
        case .dryRun: return "Dry run"
        case .speechOnly: return "Speech only"
        case .adaptive: return "Adaptive"
        case .localOnly: return "Local improv"
        }
    }
}

@objc public protocol ROBStageShowCoordinatorDelegate: AnyObject {
    func stageShowCoordinator(_ coordinator: ROBStageShowCoordinator, speak text: String, cueID: String)
    func stageShowCoordinator(
        _ coordinator: ROBStageShowCoordinator,
        requestGeminiTurn prompt: String,
        cueID: String,
        requestID: String,
        timeout: TimeInterval
    )
    func stageShowCoordinator(
        _ coordinator: ROBStageShowCoordinator,
        cancelGeminiTurn requestID: String
    )
    func stageShowCoordinator(
        _ coordinator: ROBStageShowCoordinator,
        requestGesture name: String,
        cueID: String,
        timeout: TimeInterval
    )
    func stageShowCoordinatorDidRequestStop(_ coordinator: ROBStageShowCoordinator)
}

@objcMembers public final class ROBStageShowCoordinator: NSObject {
    public weak var delegate: ROBStageShowCoordinatorDelegate?
    public private(set) var isRunning = false
    public private(set) var state = "idle"
    public private(set) var detail = "Load a show to begin."
    public private(set) var currentCueID: String?
    public private(set) var loadedShowTitle: String?
    @nonobjc public private(set) var localImprovisationConfiguration: ROBLocalImprovisationConfiguration?
    @nonobjc public private(set) var localImprovisationStatus = "Disabled"
    @nonobjc public var localImprovisationProvider: ROBLocalImprovisationProviding?

    private enum Awaiting {
        case none
        case speech
        case localImprovisation
        case gemini
        case gesture(required: Bool)
        case checkpoint
        case timer
    }

    private var show: ROBStageShow?
    private var mode: ROBStageShowRunMode = .dryRun
    private var cueIndex = 0
    private var awaiting: Awaiting = .none
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var pendingGeminiRequestID: String?
    private var pendingLocalRequestID: String?
    private var pendingLocalPlan: ROBLocalImprovisationPlan?
    private var adaptiveDeadlineUptime: TimeInterval?

    /// Reloads the effective UserDefaults/environment configuration. Invalid
    /// settings disable the provider without interrupting app startup.
    public func reloadLocalImprovisationProvider() {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard !isRunning else {
            localImprovisationStatus = "Stop the show before changing the local provider."
            return
        }
        do {
            try applyLocalImprovisationConfiguration(ROBLocalImprovisationSettings.load())
        } catch {
            localImprovisationProvider = nil
            localImprovisationConfiguration = nil
            localImprovisationStatus = "Disabled: \(error.localizedDescription)"
        }
    }

    @nonobjc public func applyLocalImprovisationConfiguration(
        _ configuration: ROBLocalImprovisationConfiguration
    ) throws {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard !isRunning else {
            throw ROBLocalImprovisationError.invalidConfiguration(
                "Stop the current show before changing its local provider."
            )
        }
        localImprovisationConfiguration = configuration
        localImprovisationProvider = ROBLocalImprovisationProviderFactory.makeProvider(
            configuration: configuration
        )
        if configuration.isEnabled {
            localImprovisationStatus = "Configured: \(configuration.providerKind.displayName)"
        } else {
            localImprovisationStatus = "Disabled"
        }
    }

    @nonobjc public func checkLocalImprovisationHealth(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard let provider = localImprovisationProvider else {
            completion(.failure(ROBLocalImprovisationError.serverUnavailable(
                "Enable and save a local improvisation provider first."
            )))
            return
        }
        provider.checkHealth(timeout: 3, completion: completion)
    }

    @nonobjc public func preflightLocalImprovisationProvider(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard !isRunning else {
            completion(.failure(ROBLocalImprovisationError.invalidConfiguration(
                "Stop the current show before testing the local provider."
            )))
            return
        }
        guard let provider = localImprovisationProvider else {
            completion(.failure(ROBLocalImprovisationError.serverUnavailable(
                "Enable and save a local improvisation provider first."
            )))
            return
        }

        provider.checkHealth(timeout: 3) { result in
            let continuePreflight = {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    let requestID = "local-preflight:\(UUID().uuidString)"
                    let request = ROBLocalImprovisationRequest(
                        showTitle: "Cerebro local-provider preflight",
                        cueID: "preflight",
                        sceneGoal: "Choose one concise, family-friendly line welcoming makers to the show.",
                        authoredFallback: "Welcome, makers. My rehearsal systems are ready."
                    )
                    provider.generatePlan(
                        for: request,
                        requestID: requestID,
                        timeout: min(5, provider.maximumRequestSeconds)
                    ) { planResult in
                        let finish = {
                            switch planResult {
                            case .success:
                                completion(.success("Ready; schema-constrained rehearsal plan validated."))
                            case .failure(let error):
                                completion(.failure(error))
                            }
                        }
                        if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
                    }
                }
            }
            if Thread.isMainThread {
                continuePreflight()
            } else {
                DispatchQueue.main.async(execute: continuePreflight)
            }
        }
    }

    @nonobjc public func localImprovisationDiagnosticsSnapshot(
    ) -> ROBLocalImprovisationDiagnosticsSnapshot? {
        localImprovisationProvider?.diagnosticsSnapshot()
    }

    @nonobjc public func load(_ show: ROBStageShow) throws {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard !isRunning else {
            throw ROBStageShowError.invalidDocument("Stop the current show before loading another one.")
        }
        try ROBStageShowCodec.validate(show)
        self.show = show
        loadedShowTitle = show.title
        cueIndex = 0
        currentCueID = nil
        clearGeminiTurn(cancelRequest: true)
        clearLocalImprovisation(cancelRequest: true)
        pendingLocalPlan = nil
        adaptiveDeadlineUptime = nil
        publish(state: "ready", detail: "Validated \(show.cues.count) cues in \(show.title).")
    }

    @objc(loadShowData:error:)
    public func loadShowData(_ data: Data) throws {
        try load(ROBStageShowCodec.decode(data))
    }

    @objc(startWithMode:)
    public func start(mode: ROBStageShowRunMode) {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard let show else {
            publish(state: "failed", detail: "No validated show is loaded.")
            return
        }
        if isRunning {
            cancel(reason: "Replaced by a new run")
        }

        generation &+= 1
        self.mode = mode
        cueIndex = 0
        currentCueID = nil
        clearGeminiTurn(cancelRequest: true)
        clearLocalImprovisation(cancelRequest: true)
        pendingLocalPlan = nil
        adaptiveDeadlineUptime = nil
        awaiting = .none
        isRunning = true
        publish(state: "running", detail: "\(mode.displayName): starting \(show.title).")
        processCurrentCue()
    }

    @objc(cancelWithReason:)
    public func cancel(reason: String) {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard isRunning else { return }
        generation &+= 1
        timer?.invalidate()
        timer = nil
        clearLocalImprovisation(cancelRequest: true)
        awaiting = .none
        clearGeminiTurn(cancelRequest: true)
        pendingLocalPlan = nil
        adaptiveDeadlineUptime = nil
        isRunning = false
        let stoppedCue = currentCueID
        currentCueID = nil
        delegate?.stageShowCoordinatorDidRequestStop(self)
        let suffix = stoppedCue.map { " at cue \($0)" } ?? ""
        publish(state: "cancelled", detail: "\(reason)\(suffix).")
    }

    public func continueAfterCheckpoint() {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard isRunning, case .checkpoint = awaiting else { return }
        advance(detail: "Checkpoint released.")
    }

    public func speechDidFinish() {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard isRunning, case .speech = awaiting else { return }
        advance(detail: "Speech completed.")
    }

    @objc(acceptGeminiResponse:requestID:)
    public func acceptGeminiResponse(_ response: String, requestID: String) -> Bool {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard isRunning,
              case .gemini = awaiting,
              requestID == pendingGeminiRequestID,
              let cue = currentCue else { return false }
        timer?.invalidate()
        timer = nil
        clearGeminiTurn(cancelRequest: true)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            speakAdaptiveFallback(for: cue, reason: "Gemini returned an empty response")
            return true
        }
        awaiting = .speech
        publish(state: "awaiting_speech", detail: "Cue \(cue.id): speaking the adaptive line.")
        scheduleTimeout(seconds: speechTimeout(for: trimmed), label: "speech")
        delegate?.stageShowCoordinator(self, speak: trimmed, cueID: cue.id)
        return true
    }

    @objc(failGeminiTurn:requestID:)
    public func failGeminiTurn(_ failureDetail: String, requestID: String) -> Bool {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard isRunning,
              case .gemini = awaiting,
              requestID == pendingGeminiRequestID,
              let cue = currentCue else { return false }
        timer?.invalidate()
        timer = nil
        clearGeminiTurn(cancelRequest: true)
        speakAdaptiveFallback(for: cue, reason: failureDetail)
        return true
    }

    @objc(completeGestureWithSuccess:detail:)
    public func completeGesture(success: Bool, detail completionDetail: String) -> Bool {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard isRunning, case .gesture(let required) = awaiting, let cue = currentCue else { return false }
        timer?.invalidate()
        timer = nil
        if success {
            advance(detail: completionDetail.isEmpty ? "Gesture completed." : completionDetail)
        } else if required {
            fail("Required gesture \(cue.gesture ?? cue.id) failed: \(completionDetail)")
        } else {
            advance(detail: "Optional gesture skipped: \(completionDetail)")
        }
        return true
    }

    private var currentCue: ROBStageCue? {
        guard let show, cueIndex >= 0, cueIndex < show.cues.count else { return nil }
        return show.cues[cueIndex]
    }

    private func processCurrentCue() {
        guard isRunning, let show else { return }
        guard cueIndex < show.cues.count else {
            finish()
            return
        }
        let cue = show.cues[cueIndex]
        currentCueID = cue.id

        if mode == .dryRun {
            awaiting = .timer
            publish(
                state: "dry_run",
                detail: "Cue \(cueIndex + 1)/\(show.cues.count) \(cue.id): \(cue.kind.rawValue); no speech, model, or hardware call emitted."
            )
            scheduleAdvance(after: 0.04, detail: "Dry-run cue passed.")
            return
        }

        switch cue.kind {
        case .speak:
            guard let text = cue.text else {
                fail("Cue \(cue.id) lost its validated speech text.")
                return
            }
            awaiting = .speech
            publish(state: "awaiting_speech", detail: "Cue \(cue.id): speaking authored dialogue.")
            scheduleTimeout(seconds: speechTimeout(for: text), label: "speech")
            delegate?.stageShowCoordinator(self, speak: text, cueID: cue.id)

        case .wait:
            let seconds = cue.durationSeconds ?? 0
            awaiting = .timer
            publish(state: "waiting", detail: "Cue \(cue.id): waiting \(seconds) seconds.")
            scheduleAdvance(after: seconds, detail: "Timed cue completed.")

        case .playGesture:
            guard let gesture = cue.gesture else {
                fail("Cue \(cue.id) lost its validated gesture name.")
                return
            }
            awaiting = .gesture(required: cue.required)
            let timeout = cue.durationSeconds ?? 1
            publish(state: "awaiting_gesture", detail: "Cue \(cue.id): requesting named gesture \(gesture).")
            scheduleTimeout(seconds: timeout, label: "gesture")
            delegate?.stageShowCoordinator(
                self,
                requestGesture: gesture,
                cueID: cue.id,
                timeout: timeout
            )

        case .geminiTurn, .modelTurn:
            if mode == .speechOnly {
                speakFallback(for: cue, reason: "Speech-only mode")
                return
            }
            beginImprovisation(for: cue)

        case .checkpoint:
            awaiting = .checkpoint
            publish(
                state: "paused",
                detail: "Checkpoint \(cue.id): \(cue.text ?? "Operator confirmation required.")"
            )
        }
    }

    private func speakFallback(for cue: ROBStageCue, reason: String) {
        guard let fallback = cue.fallbackText else {
            fail("Cue \(cue.id) has no offline fallback.")
            return
        }
        awaiting = .speech
        publish(state: "offline_fallback", detail: "Cue \(cue.id): \(reason); speaking the authored fallback.")
        scheduleTimeout(seconds: speechTimeout(for: fallback), label: "fallback speech")
        delegate?.stageShowCoordinator(self, speak: fallback, cueID: cue.id)
    }

    private func speakAdaptiveFallback(for cue: ROBStageCue, reason: String) {
        if let plan = pendingLocalPlan {
            localImprovisationProvider?.noteFallback()
            awaiting = .speech
            publish(
                state: "local_fallback",
                detail: "Cue \(cue.id): \(reason); speaking the validated local line."
            )
            scheduleTimeout(seconds: speechTimeout(for: plan.offlineLine), label: "local fallback speech")
            delegate?.stageShowCoordinator(self, speak: plan.offlineLine, cueID: cue.id)
            return
        }
        speakFallback(for: cue, reason: reason)
    }

    private func beginImprovisation(for cue: ROBStageCue) {
        guard let prompt = cue.text, let authoredFallback = cue.fallbackText, let show else {
            fail("Cue \(cue.id) lost its validated improvisation fields.")
            return
        }

        let totalTimeout = cue.durationSeconds ?? 1
        adaptiveDeadlineUptime = ProcessInfo.processInfo.systemUptime + totalTimeout
        pendingLocalPlan = nil

        guard let provider = localImprovisationProvider else {
            if mode == .localOnly {
                speakFallback(for: cue, reason: "Local improvisation is disabled")
            } else {
                requestGeminiTurn(prompt: prompt, cue: cue, timeout: totalTimeout, localDirected: false)
            }
            return
        }

        let requestID = "local-stage:\(UUID().uuidString)"
        pendingLocalRequestID = requestID
        awaiting = .localImprovisation
        let localBudget: TimeInterval
        if mode == .localOnly {
            localBudget = min(provider.maximumRequestSeconds, totalTimeout)
        } else {
            // Preserve the authored cue deadline: local planning may use only
            // a bounded slice before Gemini gets the remaining time.
            localBudget = min(provider.maximumRequestSeconds, max(0.5, totalTimeout * 0.35))
        }
        publish(
            state: "awaiting_local_improv",
            detail: "Cue \(cue.id): asking \(provider.providerName) for a dialogue-only stage beat."
        )
        scheduleLocalImprovisationFallback(after: localBudget)
        let request = ROBLocalImprovisationRequest(
            showTitle: show.title,
            cueID: cue.id,
            sceneGoal: prompt,
            authoredFallback: authoredFallback
        )
        provider.generatePlan(
            for: request,
            requestID: requestID,
            timeout: localBudget
        ) { [weak self] result in
            guard let self else { return }
            if Thread.isMainThread {
                self.handleLocalImprovisationResult(result, requestID: requestID)
            } else {
                DispatchQueue.main.async {
                    self.handleLocalImprovisationResult(result, requestID: requestID)
                }
            }
        }
    }

    private func handleLocalImprovisationResult(
        _ result: Result<ROBLocalImprovisationPlan, Error>,
        requestID: String
    ) {
        precondition(Thread.isMainThread, "Stage-show state must be serialized on the main thread")
        guard isRunning,
              case .localImprovisation = awaiting,
              pendingLocalRequestID == requestID,
              let cue = currentCue,
              let prompt = cue.text else { return }
        timer?.invalidate()
        timer = nil
        pendingLocalRequestID = nil

        switch result {
        case .success(let plan):
            pendingLocalPlan = plan
            if mode == .localOnly {
                awaiting = .speech
                publish(
                    state: "local_improvisation",
                    detail: "Cue \(cue.id): speaking the validated local improvisation."
                )
                scheduleTimeout(seconds: speechTimeout(for: plan.offlineLine), label: "local speech")
                delegate?.stageShowCoordinator(self, speak: plan.offlineLine, cueID: cue.id)
                return
            }

            let remaining = remainingAdaptiveSeconds()
            guard remaining >= 0.5 else {
                speakAdaptiveFallback(for: cue, reason: "The local director used the cue deadline")
                return
            }
            let handoff = ROBLocalImprovisationPlanCodec.geminiHandoffPrompt(
                plan: plan,
                originalSceneGoal: prompt
            )
            requestGeminiTurn(prompt: handoff, cue: cue, timeout: remaining, localDirected: true)

        case .failure(let error):
            pendingLocalPlan = nil
            if mode == .localOnly {
                speakFallback(for: cue, reason: "Local director failed: \(error.localizedDescription)")
                return
            }
            let remaining = remainingAdaptiveSeconds()
            guard remaining >= 0.5 else {
                speakFallback(for: cue, reason: "Local director exhausted the cue deadline")
                return
            }
            requestGeminiTurn(prompt: prompt, cue: cue, timeout: remaining, localDirected: false)
        }
    }

    private func requestGeminiTurn(
        prompt: String,
        cue: ROBStageCue,
        timeout: TimeInterval,
        localDirected: Bool
    ) {
        let requestID = "stage:\(UUID().uuidString)"
        pendingGeminiRequestID = requestID
        awaiting = .gemini
        let route = localDirected ? "validated local stage direction" : "authored scene goal"
        publish(
            state: "awaiting_gemini",
            detail: "Cue \(cue.id): sending \(route) to Gemini Live."
        )
        scheduleGeminiFallback(after: timeout)
        delegate?.stageShowCoordinator(
            self,
            requestGeminiTurn: prompt,
            cueID: cue.id,
            requestID: requestID,
            timeout: timeout
        )
    }

    private func advance(detail: String) {
        timer?.invalidate()
        timer = nil
        clearLocalImprovisation(cancelRequest: true)
        awaiting = .none
        clearGeminiTurn(cancelRequest: true)
        pendingLocalPlan = nil
        adaptiveDeadlineUptime = nil
        cueIndex += 1
        currentCueID = nil
        publish(state: "running", detail: detail)
        processCurrentCue()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        clearLocalImprovisation(cancelRequest: true)
        awaiting = .none
        clearGeminiTurn(cancelRequest: true)
        pendingLocalPlan = nil
        adaptiveDeadlineUptime = nil
        isRunning = false
        currentCueID = nil
        publish(state: "completed", detail: "Show completed without an outstanding cue.")
    }

    private func fail(_ failureDetail: String) {
        timer?.invalidate()
        timer = nil
        clearLocalImprovisation(cancelRequest: true)
        awaiting = .none
        clearGeminiTurn(cancelRequest: true)
        pendingLocalPlan = nil
        adaptiveDeadlineUptime = nil
        isRunning = false
        delegate?.stageShowCoordinatorDidRequestStop(self)
        publish(state: "failed", detail: failureDetail)
    }

    private func scheduleAdvance(after seconds: TimeInterval, detail: String) {
        let expectedGeneration = generation
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.generation == expectedGeneration, self.isRunning else { return }
            self.advance(detail: detail)
        }
    }

    private func scheduleGeminiFallback(after seconds: TimeInterval) {
        let expectedGeneration = generation
        let totalBudget = currentCue?.durationSeconds ?? seconds
        let localPlanningSeconds = max(0, totalBudget - seconds)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self,
                  self.generation == expectedGeneration,
                  self.isRunning,
                  case .gemini = self.awaiting,
                  let cue = self.currentCue else { return }
            self.clearGeminiTurn(cancelRequest: true)
            let reason: String
            if localPlanningSeconds >= 0.05 {
                reason = String(
                    format: "Gemini did not complete within %.1f seconds (%.1f-second cue budget; %.1f seconds used for local planning)",
                    seconds, totalBudget, localPlanningSeconds
                )
            } else {
                reason = String(
                    format: "Gemini did not complete within %.1f seconds (%.1f-second cue budget)",
                    seconds, totalBudget
                )
            }
            self.speakAdaptiveFallback(for: cue, reason: reason)
        }
    }

    private func scheduleLocalImprovisationFallback(after seconds: TimeInterval) {
        let expectedGeneration = generation
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self,
                  self.generation == expectedGeneration,
                  self.isRunning,
                  case .localImprovisation = self.awaiting,
                  let cue = self.currentCue,
                  let prompt = cue.text else { return }
            self.clearLocalImprovisation(cancelRequest: true)
            if self.mode == .localOnly {
                self.speakFallback(for: cue, reason: "Local director timed out")
                return
            }
            let remaining = self.remainingAdaptiveSeconds()
            guard remaining >= 0.5 else {
                self.speakFallback(for: cue, reason: "Local director exhausted the cue deadline")
                return
            }
            self.requestGeminiTurn(
                prompt: prompt,
                cue: cue,
                timeout: remaining,
                localDirected: false
            )
        }
    }

    private func clearLocalImprovisation(cancelRequest: Bool) {
        if cancelRequest, let requestID = pendingLocalRequestID {
            localImprovisationProvider?.cancel(requestID: requestID)
        }
        pendingLocalRequestID = nil
    }

    private func clearGeminiTurn(cancelRequest: Bool) {
        if cancelRequest, let requestID = pendingGeminiRequestID {
            delegate?.stageShowCoordinator(self, cancelGeminiTurn: requestID)
        }
        pendingGeminiRequestID = nil
    }

    private func remainingAdaptiveSeconds() -> TimeInterval {
        guard let deadline = adaptiveDeadlineUptime else { return 0 }
        return max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }

    private func scheduleTimeout(seconds: TimeInterval, label: String) {
        let expectedGeneration = generation
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.generation == expectedGeneration, self.isRunning else { return }
            if case .gesture(let required) = self.awaiting, !required {
                self.advance(detail: "Optional gesture timed out and was skipped.")
            } else {
                self.fail("Cue \(self.currentCueID ?? "unknown") exceeded its \(label) timeout.")
            }
        }
    }

    private func speechTimeout(for text: String) -> TimeInterval {
        min(180, max(15, Double(text.count) / 7.0 + 10))
    }

    private func publish(state: String, detail: String) {
        self.state = state
        self.detail = detail
        NotificationCenter.default.post(
            name: .ROBStageShowStateDidChange,
            object: self,
            userInfo: ["state": state, "detail": detail, "cue_id": currentCueID ?? ""]
        )
    }
}
