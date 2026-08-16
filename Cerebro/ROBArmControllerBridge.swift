import Foundation

extension Notification.Name {
    static let ROBArmControllerTargetIntentDidUpdate = Notification.Name(
        "ROBArmControllerTargetIntentDidUpdate"
    )
}

/// Cross-executor ownership for each physical Amber arm. Vision targets and
/// named Gemini gestures must never send independent trajectories to the same
/// arm at the same time.
final class ROBAmberArmMotionArbiter {
    static let shared = ROBAmberArmMotionArbiter()

    private let lock = NSLock()
    private var owners: [ROBArmSide: UUID] = [:]

    func reserve(_ arm: ROBArmSide, owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owners[arm] == nil || owners[arm] == owner else { return false }
        owners[arm] = owner
        return true
    }

    func release(_ arm: ROBArmSide, owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if owners[arm] == owner { owners.removeValue(forKey: arm) }
    }

    func isReserved(_ arm: ROBArmSide) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return owners[arm] != nil
    }
}

/// Bridges authenticated ROBControl v2 application data to the leased Amber
/// executor. All mutation is serialized on the main thread. The Ubuntu gateway
/// owns the final monotonic lease watchdog, so a Cerebro crash cannot leave a
/// Vision trajectory without a bounded hold backstop.
final class ROBArmControllerBridge {
    private struct SequenceKey: Hashable {
        let controllerID: UUID
        let sessionID: UUID
    }

    private struct LatestTelemetrySample {
        let sequence: UInt64
        let positionsRadians: [Double]
        let velocitiesRadiansPerSecond: [Double]
        let gatewaySampleAgeMilliseconds: Double
        let receivedAtUptime: TimeInterval

        var effectiveAgeMilliseconds: Double {
            gatewaySampleAgeMilliseconds
                + max(0, ProcessInfo.processInfo.systemUptime - receivedAtUptime) * 1_000
        }
    }

    private struct AuthorityGrant {
        let id: UUID
        let controllerID: UUID
        let sessionID: UUID
        let arm: ROBArmSide
        let expiresAtUptime: TimeInterval
        let expiresAtUnixMilliseconds: Int64
    }

    private final class ActiveRun {
        let ownerID = UUID()
        let target: ROBArmTargetIntentEnvelope
        let controllerID: UUID
        let sessionID: UUID
        let commandID: UInt64
        let startedAtUptime: TimeInterval
        let leaseDeadlineUptime: TimeInterval
        var gatewayAcknowledged = false
        var lastEvaluatedTelemetrySequence: UInt64 = 0
        var consecutiveSettledSamples = 0
        var largestObservedError = 0.0
        var holdCommandID: UInt64?

        init(
            target: ROBArmTargetIntentEnvelope,
            controllerID: UUID,
            sessionID: UUID,
            commandID: UInt64,
            startedAtUptime: TimeInterval
        ) {
            self.target = target
            self.controllerID = controllerID
            self.sessionID = sessionID
            self.commandID = commandID
            self.startedAtUptime = startedAtUptime
            leaseDeadlineUptime = startedAtUptime
                + Double(target.leaseMilliseconds) / 1_000
        }
    }

    private struct PendingHold {
        let arm: ROBArmSide
        let requestMessageID: UUID
        let recipientID: UUID
        let sessionID: UUID
        let dispositionOnSuccess: ROBArmTargetDispositionKind
        let detail: String
        let runOwnerID: UUID?
    }

    private static let settledPositionToleranceRadians = 0.04
    private static let settledVelocityToleranceRadiansPerSecond = 0.10
    private static let requiredSettledSamples = 3

    private weak var server: AutoNetServer?
    private var telemetryObserver: NSObjectProtocol?
    private var commandObserver: NSObjectProtocol?
    private var gatewayStateObserver: NSObjectProtocol?
    private var monitor: Timer?
    private var lastInboundSequence: [SequenceKey: UInt64] = [:]
    private var lastTelemetrySequence: [ROBArmSide: UInt64] = [:]
    private var lastTelemetryBroadcastUptime: [ROBArmSide: TimeInterval] = [:]
    private var latestTelemetry: [ROBArmSide: LatestTelemetrySample] = [:]
    private var grants: [ROBArmSide: AuthorityGrant] = [:]
    private var runs: [ROBArmSide: ActiveRun] = [:]
    private var pendingHolds: [UInt64: PendingHold] = [:]

    init(server: AutoNetServer) {
        self.server = server
    }

    deinit {
        stop()
    }

    func start() {
        guard telemetryObserver == nil else { return }
        let center = NotificationCenter.default
        telemetryObserver = center.addObserver(
            forName: .ROBAmberGatewayTelemetryDidUpdate,
            object: ROBAmberGatewayClient.shared,
            queue: .main
        ) { [weak self] notification in
            guard let telemetry = notification.userInfo?["telemetry"]
                    as? ROBAmberGatewayTelemetry else { return }
            self?.publish(telemetry)
        }
        commandObserver = center.addObserver(
            forName: .ROBAmberGatewayCommandDidComplete,
            object: ROBAmberGatewayClient.shared,
            queue: .main
        ) { [weak self] notification in
            self?.gatewayCommandCompleted(notification)
        }
        gatewayStateObserver = center.addObserver(
            forName: .ROBAmberGatewayStateDidChange,
            object: ROBAmberGatewayClient.shared,
            queue: .main
        ) { [weak self] notification in
            self?.gatewayStateChanged(notification)
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.monitorSafetyState()
        }
        monitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        for arm in Array(runs.keys) {
            _ = ROBAmberGatewayClient.shared.priorityHold(forArm: arm.rawValue)
        }
        let center = NotificationCenter.default
        if let telemetryObserver { center.removeObserver(telemetryObserver) }
        if let commandObserver { center.removeObserver(commandObserver) }
        if let gatewayStateObserver { center.removeObserver(gatewayStateObserver) }
        telemetryObserver = nil
        commandObserver = nil
        gatewayStateObserver = nil
        monitor?.invalidate()
        monitor = nil
        for (arm, run) in Array(runs) {
            ROBAmberArmMotionArbiter.shared.release(arm, owner: run.ownerID)
        }
        lastInboundSequence.removeAll()
        lastTelemetrySequence.removeAll()
        lastTelemetryBroadcastUptime.removeAll()
        latestTelemetry.removeAll()
        grants.removeAll()
        runs.removeAll()
        pendingHolds.removeAll()
    }

    func claimsArmControlProtocol(_ data: Data) -> Bool {
        ROBArmControlWireCodec.claimsProtocolForRouting(data)
    }

    /// Claimed but malformed arm messages are consumed and never reach the
    /// historical keyed-archive command parser.
    func consumeInbound(
        _ data: Data,
        authenticatedControllerID: UUID,
        authenticatedSessionID: UUID
    ) -> Bool {
        let decoded: ROBArmControlDecodedMessage?
        do {
            decoded = try ROBArmControlWireCodec.decode(data, requireFreshTarget: false)
        } catch {
            guard ROBArmControlWireCodec.claimsProtocolForRouting(data) else { return false }
            NSLog("Rejected malformed Vision Pro arm-control message: %@", String(describing: error))
            return true
        }
        guard let decoded else { return false }
        switch decoded {
        case .authorityIntent(let intent):
            consumeAuthority(
                intent,
                authenticatedControllerID: authenticatedControllerID,
                authenticatedSessionID: authenticatedSessionID
            )
        case .targetIntent(let target):
            consumeTarget(
                target,
                authenticatedControllerID: authenticatedControllerID,
                authenticatedSessionID: authenticatedSessionID
            )
        case .holdIntent(let hold):
            consumeHold(
                hold,
                authenticatedControllerID: authenticatedControllerID,
                authenticatedSessionID: authenticatedSessionID
            )
        case .measuredState, .authorityState, .targetDisposition:
            NSLog("Ignored controller-originated %@ message", String(describing: decoded))
        }
        return true
    }

    private func consumeAuthority(
        _ intent: ROBArmAuthorityIntentEnvelope,
        authenticatedControllerID: UUID,
        authenticatedSessionID: UUID
    ) {
        let now = ROBArmControlWireCodec.currentUnixMilliseconds()
        let key = SequenceKey(
            controllerID: authenticatedControllerID,
            sessionID: authenticatedSessionID
        )
        guard intent.senderID == authenticatedControllerID,
              intent.sessionID == authenticatedSessionID else {
            sendAuthorityState(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                state: .rejected,
                grant: nil,
                detail: "Authority identity did not match the authenticated session."
            )
            return
        }
        guard intent.sequence > (lastInboundSequence[key] ?? 0),
              intent.validationError == nil,
              intent.freshnessValidationError(nowUnixMilliseconds: now) == nil,
              ROBControlLiveSessionRegistry.isActiveOperator(
                controllerID: authenticatedControllerID,
                sessionID: authenticatedSessionID
              ) else {
            sendAuthorityState(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                state: .rejected,
                grant: nil,
                detail: "Authority request was stale, replayed, malformed, or inactive."
            )
            return
        }
        lastInboundSequence[key] = intent.sequence

        if intent.operation == .release {
            let grant = grants[intent.arm]
            if grant?.controllerID == authenticatedControllerID,
               grant?.sessionID == authenticatedSessionID {
                grants.removeValue(forKey: intent.arm)
            }
            let holdCommandID = requestPriorityHold(
                arm: intent.arm,
                requestMessageID: intent.messageID,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                successDisposition: .holdConfirmed,
                detail: "Vision arm authority was released and a measured-position hold was requested."
            )
            if holdCommandID == 0 {
                sendDisposition(
                    targetMessageID: intent.messageID,
                    recipientID: authenticatedControllerID,
                    sessionID: authenticatedSessionID,
                    arm: intent.arm,
                    disposition: .holdUnconfirmed,
                    detail: "Authority was released, but the Amber gateway could not accept a priority hold."
                )
            }
            sendAuthorityState(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                state: .released,
                grant: nil,
                detail: "Vision arm authority released."
            )
            return
        }

        guard ROBAmberGatewayClient.shared.isReady(),
              let telemetry = latestTelemetry[intent.arm],
              telemetry.effectiveAgeMilliseconds <= 250,
              telemetry.positionsRadians.count == ROBArmControlProtocol.jointCount else {
            sendAuthorityState(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                state: .rejected,
                grant: nil,
                detail: "The Amber gateway and fresh measured pose are required before arming."
            )
            return
        }
        let modes = gatewayModes(for: intent.arm)
        guard modes.count == ROBArmControlProtocol.jointCount,
              modes.allSatisfy({ $0 == 2 }) else {
            sendAuthorityState(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                state: .rejected,
                grant: nil,
                detail: "Prepare the selected arm in verified position mode first."
            )
            return
        }

        // Never grant a replacement while an earlier authority, trajectory,
        // or named-gesture owner is still present. An asynchronous hold from a
        // replacement request could otherwise arrive after a new trajectory
        // and stop the new motion. The operator must release and receive the
        // hold acknowledgement before acquiring again.
        guard grants[intent.arm] == nil,
              runs[intent.arm] == nil,
              !ROBAmberArmMotionArbiter.shared.isReserved(intent.arm) else {
            sendAuthorityState(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                state: .rejected,
                grant: nil,
                detail: "This arm already has supervised authority or active motion. Release it and wait for the measured hold first."
            )
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let grant = AuthorityGrant(
            id: UUID(),
            controllerID: authenticatedControllerID,
            sessionID: authenticatedSessionID,
            arm: intent.arm,
            expiresAtUptime: uptime + Double(intent.leaseMilliseconds) / 1_000,
            expiresAtUnixMilliseconds: now + Int64(intent.leaseMilliseconds)
        )
        grants[intent.arm] = grant
        sendAuthorityState(
            for: intent,
            recipientID: authenticatedControllerID,
            sessionID: authenticatedSessionID,
            state: .granted,
            grant: grant,
            detail: "Vision arm control is armed for this authenticated session."
        )
    }

    private func consumeTarget(
        _ target: ROBArmTargetIntentEnvelope,
        authenticatedControllerID: UUID,
        authenticatedSessionID: UUID
    ) {
        let now = ROBArmControlWireCodec.currentUnixMilliseconds()
        let uptime = ProcessInfo.processInfo.systemUptime
        let key = SequenceKey(
            controllerID: authenticatedControllerID,
            sessionID: authenticatedSessionID
        )
        let telemetry = latestTelemetry[target.arm]
        let grant = grants[target.arm]
        let grantIsValid = grant?.id == target.authorityID
            && grant?.controllerID == authenticatedControllerID
            && grant?.sessionID == authenticatedSessionID
            && (grant?.expiresAtUptime ?? 0) > uptime
        let executionContext = ROBArmTargetExecutionContext(
            authenticatedSessionIsCurrent: ROBControlLiveSessionRegistry.isActiveOperator(
                controllerID: authenticatedControllerID,
                sessionID: authenticatedSessionID
            ),
            measuredPositionsRadians: telemetry?.positionsRadians,
            effectiveTelemetryAgeMilliseconds: telemetry?.effectiveAgeMilliseconds,
            modes: gatewayModes(for: target.arm),
            armHasInFlightTarget: runs[target.arm] != nil
                || ROBAmberArmMotionArbiter.shared.isReserved(target.arm)
        )
        var decision = ROBArmTargetGateEvaluator.evaluate(
            target,
            authenticatedControllerID: authenticatedControllerID,
            authenticatedSessionID: authenticatedSessionID,
            lastAcceptedSequence: lastInboundSequence[key] ?? 0,
            authorityEnabled: grantIsValid,
            executionContext: executionContext,
            nowUnixMilliseconds: now
        )
        if decision.passedExecutionPreflight, target.leaseMilliseconds < 700 {
            decision = ROBArmTargetGateDecision(
                disposition: .rejectedInvalid,
                detail: "Execution requires a 700–1500 ms gateway lease.",
                advancesSequence: true,
                passedExecutionPreflight: false
            )
        }
        if decision.advancesSequence { lastInboundSequence[key] = target.sequence }

        guard decision.passedExecutionPreflight,
              ROBAmberArmMotionArbiter.shared.reserve(target.arm, owner: target.messageID) else {
            sendDisposition(
                targetMessageID: target.messageID,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                arm: target.arm,
                disposition: decision.passedExecutionPreflight
                    ? .rejectedArmBusy : decision.disposition,
                detail: decision.passedExecutionPreflight
                    ? "Another supervised executor owns this arm." : decision.detail
            )
            postDiagnostic(target: target, decision: decision, executionEligible: false)
            return
        }

        let commandID = ROBAmberGatewayClient.shared.sendLeasedTrajectory(
            arm: target.arm.rawValue,
            positionsRadians: target.positionsRadians.map(NSNumber.init(value:)),
            duration: target.durationSeconds,
            leaseMilliseconds: target.leaseMilliseconds
        )
        guard commandID != 0 else {
            ROBAmberArmMotionArbiter.shared.release(target.arm, owner: target.messageID)
            sendDisposition(
                targetMessageID: target.messageID,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                arm: target.arm,
                disposition: .failed,
                detail: "Cerebro could not transmit the leased trajectory to the Amber gateway."
            )
            return
        }
        let run = ActiveRun(
            target: target,
            controllerID: authenticatedControllerID,
            sessionID: authenticatedSessionID,
            commandID: commandID,
            startedAtUptime: uptime
        )
        // Replace the temporary message-ID reservation with the run's stable
        // owner token before another event-loop turn can admit work.
        ROBAmberArmMotionArbiter.shared.release(target.arm, owner: target.messageID)
        guard ROBAmberArmMotionArbiter.shared.reserve(target.arm, owner: run.ownerID) else {
            _ = ROBAmberGatewayClient.shared.priorityHold(forArm: target.arm.rawValue)
            sendDisposition(
                targetMessageID: target.messageID,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                arm: target.arm,
                disposition: .failed,
                detail: "Arm ownership changed before execution began. A hold was requested."
            )
            return
        }
        runs[target.arm] = run
        sendDisposition(
            targetMessageID: target.messageID,
            recipientID: authenticatedControllerID,
            sessionID: authenticatedSessionID,
            arm: target.arm,
            disposition: .acceptedForExecution,
            executionEligible: true,
            terminal: false,
            detail: decision.detail
        )
        postDiagnostic(target: target, decision: decision, executionEligible: true)
    }

    private func consumeHold(
        _ hold: ROBArmHoldIntentEnvelope,
        authenticatedControllerID: UUID,
        authenticatedSessionID: UUID
    ) {
        let key = SequenceKey(
            controllerID: authenticatedControllerID,
            sessionID: authenticatedSessionID
        )
        guard hold.senderID == authenticatedControllerID,
              hold.sessionID == authenticatedSessionID,
              hold.sequence > (lastInboundSequence[key] ?? 0),
              hold.validationError == nil,
              ROBControlLiveSessionRegistry.isActiveOperator(
                controllerID: authenticatedControllerID,
                sessionID: authenticatedSessionID
              ) else { return }
        lastInboundSequence[key] = hold.sequence
        let commandID = requestPriorityHold(
            arm: hold.arm,
            requestMessageID: hold.messageID,
            recipientID: authenticatedControllerID,
            sessionID: authenticatedSessionID,
            successDisposition: .holdConfirmed,
            detail: "Vision released its arm dead-man: \(hold.reason)"
        )
        if commandID == 0 {
            sendDisposition(
                targetMessageID: hold.messageID,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                arm: hold.arm,
                disposition: .holdUnconfirmed,
                detail: "Cerebro could not transmit the Vision priority hold."
            )
        }
    }

    private func publish(_ telemetry: ROBAmberGatewayTelemetry) {
        guard let arm = ROBArmSide(rawValue: telemetry.arm), telemetry.sequence > 0 else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let positions = telemetry.positionsRadians.map(\.doubleValue)
        let velocities = telemetry.velocitiesRadiansPerSecond.map(\.doubleValue)
        if telemetry.sampleAgeMilliseconds.isFinite,
           telemetry.sampleAgeMilliseconds >= 0,
           positions.count == ROBArmControlProtocol.jointCount,
           velocities.count == ROBArmControlProtocol.jointCount,
           positions.allSatisfy(\.isFinite),
           velocities.allSatisfy(\.isFinite) {
            latestTelemetry[arm] = LatestTelemetrySample(
                sequence: telemetry.sequence,
                positionsRadians: positions,
                velocitiesRadiansPerSecond: velocities,
                gatewaySampleAgeMilliseconds: telemetry.sampleAgeMilliseconds,
                receivedAtUptime: telemetry.receivedAtUptime
            )
        } else {
            latestTelemetry.removeValue(forKey: arm)
        }

        evaluateMeasuredCompletion(for: arm)

        if let previous = lastTelemetryBroadcastUptime[arm], uptime - previous < 0.040 {
            return
        }
        guard lastTelemetrySequence[arm] != telemetry.sequence else { return }
        let age = telemetry.effectiveSampleAgeMilliseconds
        guard age.isFinite, age >= 0 else { return }
        let now = ROBArmControlWireCodec.currentUnixMilliseconds()
        let message = ROBArmMeasuredState(
            arm: arm,
            sequence: telemetry.sequence,
            sampledAtUnixMilliseconds: now - Int64(age.rounded()),
            sampleAgeMilliseconds: age,
            positionsRadians: positions,
            velocitiesRadiansPerSecond: velocities,
            currents: telemetry.currents.map(\.doubleValue),
            statuses: telemetry.statuses.map(\.doubleValue),
            modes: gatewayModes(for: arm)
        )
        guard let data = try? ROBArmControlWireCodec.encode(message) else { return }
        lastTelemetrySequence[arm] = telemetry.sequence
        lastTelemetryBroadcastUptime[arm] = uptime
        _ = server?.sendArmControlMessage(data, to: nil)
    }

    private func evaluateMeasuredCompletion(for arm: ROBArmSide) {
        guard let run = runs[arm], run.gatewayAcknowledged,
              let telemetry = latestTelemetry[arm],
              telemetry.sequence != run.lastEvaluatedTelemetrySequence,
              telemetry.effectiveAgeMilliseconds <= 250 else { return }
        run.lastEvaluatedTelemetrySequence = telemetry.sequence
        let errors = zip(telemetry.positionsRadians, run.target.positionsRadians)
            .map { abs($0 - $1) }
        let maximumError = errors.max() ?? .infinity
        run.largestObservedError = max(run.largestObservedError, maximumError)
        let settled = errors.allSatisfy({ $0 <= Self.settledPositionToleranceRadians })
            && telemetry.velocitiesRadiansPerSecond.allSatisfy({
                abs($0) <= Self.settledVelocityToleranceRadiansPerSecond
            })
        run.consecutiveSettledSamples = settled ? run.consecutiveSettledSamples + 1 : 0
        guard run.consecutiveSettledSamples >= Self.requiredSettledSamples else { return }
        sendDisposition(
            targetMessageID: run.target.messageID,
            recipientID: run.controllerID,
            sessionID: run.sessionID,
            arm: arm,
            disposition: .completedMeasured,
            executionEligible: true,
            terminal: true,
            detail: "Amber reached the requested pose and settled in fresh measured feedback.",
            measuredPositionsRadians: telemetry.positionsRadians,
            maximumErrorRadians: maximumError
        )
        finishRun(arm, expectedOwnerID: run.ownerID)
    }

    private func gatewayCommandCompleted(_ notification: Notification) {
        guard let operation = notification.userInfo?["operation"] as? String else { return }
        let commandID: UInt64
        if let value = notification.userInfo?["commandID"] as? UInt64 {
            commandID = value
        } else {
            commandID = (notification.userInfo?["commandID"] as? NSNumber)?.uint64Value ?? 0
        }
        guard commandID != 0 else { return }
        let accepted = notification.userInfo?["accepted"] as? Bool == true

        if operation == "leased_trajectory",
           let (arm, run) = runs.first(where: { $0.value.commandID == commandID }) {
            guard accepted else {
                requestRunHold(
                    arm: arm,
                    run: run,
                    disposition: .failed,
                    detail: "Amber rejected the leased trajectory: \(notification.userInfo?["error"] as? String ?? "unknown gateway error")"
                )
                return
            }
            run.gatewayAcknowledged = true
            sendDisposition(
                targetMessageID: run.target.messageID,
                recipientID: run.controllerID,
                sessionID: run.sessionID,
                arm: arm,
                disposition: .executing,
                executionEligible: true,
                terminal: false,
                detail: "Amber accepted the leased trajectory; waiting for measured completion."
            )
            return
        }

        guard operation == "priority_hold",
              let pending = pendingHolds.removeValue(forKey: commandID) else { return }
        let positions = (notification.userInfo?["capturedPositionsRadians"] as? [Double])
            ?? latestTelemetry[pending.arm]?.positionsRadians
        let holdConfirmed = notification.userInfo?["holdConfirmed"] as? Bool == true
        if accepted && holdConfirmed {
            sendDisposition(
                targetMessageID: pending.requestMessageID,
                recipientID: pending.recipientID,
                sessionID: pending.sessionID,
                arm: pending.arm,
                disposition: pending.dispositionOnSuccess,
                detail: pending.detail,
                measuredPositionsRadians: positions
            )
        } else {
            sendDisposition(
                targetMessageID: pending.requestMessageID,
                recipientID: pending.recipientID,
                sessionID: pending.sessionID,
                arm: pending.arm,
                disposition: .holdUnconfirmed,
                detail: "Amber could not confirm the priority hold: \(notification.userInfo?["error"] as? String ?? "unknown gateway error")"
            )
        }
        if let ownerID = pending.runOwnerID {
            finishRun(pending.arm, expectedOwnerID: ownerID)
        }
    }

    private func gatewayStateChanged(_ notification: Notification) {
        let rawState = (notification.userInfo?["state"] as? NSNumber)?.intValue
            ?? notification.userInfo?["state"] as? Int
        guard rawState != ROBAmberGatewayState.ready.rawValue else { return }
        let detail = notification.userInfo?["detail"] as? String ?? "Amber gateway unavailable"
        for (arm, run) in Array(runs) {
            sendDisposition(
                targetMessageID: run.target.messageID,
                recipientID: run.controllerID,
                sessionID: run.sessionID,
                arm: arm,
                disposition: .holdUnconfirmed,
                detail: "Gateway session ended before a hold could be confirmed: \(detail)"
            )
            finishRun(arm, expectedOwnerID: run.ownerID)
        }
        grants.removeAll()
        pendingHolds.removeAll()
    }

    private func monitorSafetyState() {
        let uptime = ProcessInfo.processInfo.systemUptime
        for (arm, grant) in Array(grants) {
            let sessionActive = ROBControlLiveSessionRegistry.isActiveOperator(
                controllerID: grant.controllerID,
                sessionID: grant.sessionID
            )
            guard uptime >= grant.expiresAtUptime || !sessionActive else { continue }
            grants.removeValue(forKey: arm)
            if let run = runs[arm] {
                requestRunHold(
                    arm: arm,
                    run: run,
                    disposition: .cancelledHeld,
                    detail: sessionActive
                        ? "Vision arm authority expired; Amber held the measured pose."
                        : "The authenticated Vision session ended; Amber held the measured pose."
                )
            } else {
                _ = ROBAmberGatewayClient.shared.priorityHold(forArm: arm.rawValue)
            }
        }

        for (arm, run) in Array(runs) {
            if uptime >= run.leaseDeadlineUptime {
                requestRunHold(
                    arm: arm,
                    run: run,
                    disposition: .leaseExpiredHeld,
                    detail: "The Vision dead-man lease expired; Amber held the measured pose."
                )
                continue
            }
            guard ROBControlLiveSessionRegistry.isActiveOperator(
                controllerID: run.controllerID,
                sessionID: run.sessionID
            ) else {
                requestRunHold(
                    arm: arm,
                    run: run,
                    disposition: .cancelledHeld,
                    detail: "The authenticated Vision session ended; Amber held the measured pose."
                )
                continue
            }
            guard let telemetry = latestTelemetry[arm],
                  telemetry.effectiveAgeMilliseconds <= 250,
                  gatewayModes(for: arm).allSatisfy({ $0 == 2 }) else {
                requestRunHold(
                    arm: arm,
                    run: run,
                    disposition: .cancelledHeld,
                    detail: "Measured telemetry or verified position mode was lost; Amber hold requested."
                )
                continue
            }
        }
    }

    private func requestRunHold(
        arm: ROBArmSide,
        run: ActiveRun,
        disposition: ROBArmTargetDispositionKind,
        detail: String
    ) {
        guard run.holdCommandID == nil else { return }
        let commandID = requestPriorityHold(
            arm: arm,
            requestMessageID: run.target.messageID,
            recipientID: run.controllerID,
            sessionID: run.sessionID,
            successDisposition: disposition,
            detail: detail,
            runOwnerID: run.ownerID
        )
        run.holdCommandID = commandID == 0 ? nil : commandID
        if commandID == 0 {
            sendDisposition(
                targetMessageID: run.target.messageID,
                recipientID: run.controllerID,
                sessionID: run.sessionID,
                arm: arm,
                disposition: .holdUnconfirmed,
                detail: "Cerebro could not transmit a priority hold to the Amber gateway."
            )
            finishRun(arm, expectedOwnerID: run.ownerID)
        }
    }

    @discardableResult
    private func requestPriorityHold(
        arm: ROBArmSide,
        requestMessageID: UUID,
        recipientID: UUID,
        sessionID: UUID,
        successDisposition: ROBArmTargetDispositionKind,
        detail: String,
        runOwnerID: UUID? = nil
    ) -> UInt64 {
        let commandID = ROBAmberGatewayClient.shared.priorityHold(forArm: arm.rawValue)
        guard commandID != 0 else { return 0 }
        pendingHolds[commandID] = PendingHold(
            arm: arm,
            requestMessageID: requestMessageID,
            recipientID: recipientID,
            sessionID: sessionID,
            dispositionOnSuccess: successDisposition,
            detail: detail,
            runOwnerID: runOwnerID
        )
        return commandID
    }

    private func finishRun(_ arm: ROBArmSide, expectedOwnerID: UUID) {
        guard let run = runs[arm], run.ownerID == expectedOwnerID else { return }
        runs.removeValue(forKey: arm)
        ROBAmberArmMotionArbiter.shared.release(arm, owner: expectedOwnerID)
    }

    private func sendAuthorityState(
        for intent: ROBArmAuthorityIntentEnvelope,
        recipientID: UUID,
        sessionID: UUID,
        state: ROBArmAuthorityState,
        grant: AuthorityGrant?,
        detail: String
    ) {
        let telemetry = latestTelemetry[intent.arm]
        let message = ROBArmAuthorityStateEnvelope(
            requestMessageID: intent.messageID,
            recipientID: recipientID,
            sessionID: sessionID,
            arm: intent.arm,
            state: state,
            authorityID: grant?.id,
            expiresAtUnixMilliseconds: grant?.expiresAtUnixMilliseconds ?? 0,
            detail: detail,
            baselinePositionsRadians: grant == nil ? [] : telemetry?.positionsRadians ?? [],
            baselineSequence: grant == nil ? 0 : telemetry?.sequence ?? 0,
            modes: grant == nil ? [] : gatewayModes(for: intent.arm)
        )
        guard let encoded = try? ROBArmControlWireCodec.encode(message) else { return }
        _ = server?.sendArmControlMessage(
            encoded,
            to: recipientID,
            sessionID: sessionID
        )
    }

    private func sendDisposition(
        targetMessageID: UUID,
        recipientID: UUID,
        sessionID: UUID,
        arm: ROBArmSide,
        disposition: ROBArmTargetDispositionKind,
        executionEligible: Bool = false,
        terminal: Bool = true,
        detail: String,
        measuredPositionsRadians: [Double]? = nil,
        maximumErrorRadians: Double? = nil
    ) {
        let message = ROBArmTargetDispositionEnvelope(
            targetMessageID: targetMessageID,
            recipientID: recipientID,
            sessionID: sessionID,
            arm: arm,
            receivedAtUnixMilliseconds: ROBArmControlWireCodec.currentUnixMilliseconds(),
            disposition: disposition,
            executionEligible: executionEligible,
            terminal: terminal,
            detail: detail,
            measuredPositionsRadians: measuredPositionsRadians,
            maximumErrorRadians: maximumErrorRadians
        )
        guard let encoded = try? ROBArmControlWireCodec.encode(message) else { return }
        _ = server?.sendArmControlMessage(
            encoded,
            to: recipientID,
            sessionID: sessionID
        )
    }

    private func postDiagnostic(
        target: ROBArmTargetIntentEnvelope,
        decision: ROBArmTargetGateDecision,
        executionEligible: Bool
    ) {
        NotificationCenter.default.post(
            name: .ROBArmControllerTargetIntentDidUpdate,
            object: self,
            userInfo: [
                "target": target,
                "disposition": decision.disposition.rawValue,
                "executionEligible": executionEligible,
                "executionPreflightPassed": decision.passedExecutionPreflight,
                "detail": decision.detail,
            ]
        )
        NSLog(
            "Vision Pro %@ arm target %@: %@",
            target.arm.rawValue,
            decision.disposition.rawValue,
            decision.detail
        )
    }

    private func gatewayModes(for arm: ROBArmSide) -> [Int] {
        ROBAmberGatewayClient.shared.modes(forArm: arm.rawValue).map(\.intValue)
    }
}
