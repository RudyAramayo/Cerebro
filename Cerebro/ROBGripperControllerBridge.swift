import Foundation

/// Routes authenticated Vision Pro gripper edges into the session-local Amber
/// calibration gate. Calibration itself intentionally remains a local Cerebro
/// operation because it moves the fingers and Amber provides no completion or
/// force feedback.
final class ROBGripperControllerBridge {
    private struct SequenceKey: Hashable {
        let controllerID: UUID
        let sessionID: UUID
    }

    private struct PendingCommand {
        let request: ROBGripperCommandIntentEnvelope
        let controllerID: UUID
        let sessionID: UUID
    }

    private weak var server: AutoNetServer?
    private var gripperObserver: NSObjectProtocol?
    private var commandObserver: NSObjectProtocol?
    private var gatewayObserver: NSObjectProtocol?
    private var authorityObserver: NSObjectProtocol?
    private var lastInboundSequence: [SequenceKey: UInt64] = [:]
    private var stateSequence: [ROBArmSide: UInt64] = [:]
    private var pendingByCommandID: [UInt64: PendingCommand] = [:]
    private var pendingArm: [ROBArmSide: UInt64] = [:]

    init(server: AutoNetServer) {
        self.server = server
    }

    deinit { stop() }

    func start() {
        guard gripperObserver == nil else { return }
        let center = NotificationCenter.default
        gripperObserver = center.addObserver(
            forName: .ROBAmberGatewayGripperDidUpdate,
            object: ROBAmberGatewayClient.shared,
            queue: .main
        ) { [weak self] notification in
            self?.gripperDidUpdate(notification)
        }
        commandObserver = center.addObserver(
            forName: .ROBAmberGatewayCommandDidComplete,
            object: ROBAmberGatewayClient.shared,
            queue: .main
        ) { [weak self] notification in
            self?.gatewayCommandCompleted(notification)
        }
        gatewayObserver = center.addObserver(
            forName: .ROBAmberGatewayStateDidChange,
            object: ROBAmberGatewayClient.shared,
            queue: .main
        ) { [weak self] notification in
            self?.gatewayStateChanged(notification)
        }
        authorityObserver = center.addObserver(
            forName: .ROBAmberDebugAuthorityDidChange,
            object: ROBAmberDebugAuthority.shared,
            queue: .main
        ) { [weak self] _ in
            guard ROBAmberDebugAuthority.shared.authorizesController() else {
                self?.publishBothStates()
                return
            }
        }
        if ROBAmberGatewayClient.shared.isReady() { queryBothStates() }
        publishBothStates()
    }

    func stop() {
        let center = NotificationCenter.default
        if let gripperObserver { center.removeObserver(gripperObserver) }
        if let commandObserver { center.removeObserver(commandObserver) }
        if let gatewayObserver { center.removeObserver(gatewayObserver) }
        if let authorityObserver { center.removeObserver(authorityObserver) }
        gripperObserver = nil
        commandObserver = nil
        gatewayObserver = nil
        authorityObserver = nil
        lastInboundSequence.removeAll()
        stateSequence.removeAll()
        pendingByCommandID.removeAll()
        pendingArm.removeAll()
    }

    func claimsGripperControlProtocol(_ data: Data) -> Bool {
        ROBGripperControlWireCodec.claimsProtocolForRouting(data)
    }

    /// Gripper state is not periodic telemetry. Send the current per-arm
    /// calibration snapshot as soon as an authenticated Vision operator is
    /// ready so reconnecting after local calibration does not require another
    /// physical or query action merely to populate the UI.
    func operatorSessionDidBecomeReady(controllerID: UUID, sessionID: UUID) {
        for arm in ROBArmSide.allCases {
            publishState(
                for: arm,
                recipientID: controllerID,
                sessionID: sessionID
            )
        }
    }

    /// Claimed malformed frames are consumed and cannot fall through to the
    /// historical keyed-archive parser.
    func consumeInbound(
        _ data: Data,
        authenticatedControllerID: UUID,
        authenticatedSessionID: UUID
    ) -> Bool {
        let decoded: ROBGripperControlDecodedMessage?
        do {
            decoded = try ROBGripperControlWireCodec.decode(
                data,
                requireFreshIntent: false
            )
        } catch {
            guard claimsGripperControlProtocol(data) else { return false }
            NSLog("Rejected malformed Vision Pro gripper-control message: %@", String(describing: error))
            return true
        }
        guard let decoded else { return false }
        switch decoded {
        case .commandIntent(let intent):
            consume(
                intent,
                authenticatedControllerID: authenticatedControllerID,
                authenticatedSessionID: authenticatedSessionID
            )
        case .state, .commandDisposition:
            NSLog("Ignored controller-originated gripper state/disposition")
        }
        return true
    }

    private func consume(
        _ intent: ROBGripperCommandIntentEnvelope,
        authenticatedControllerID: UUID,
        authenticatedSessionID: UUID
    ) {
        let key = SequenceKey(
            controllerID: authenticatedControllerID,
            sessionID: authenticatedSessionID
        )
        let now = ROBGripperControlWireCodec.currentUnixMilliseconds()
        let snapshot = gatewaySnapshot(for: intent.arm)

        guard intent.senderID == authenticatedControllerID,
              intent.sessionID == authenticatedSessionID else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedIdentityMismatch,
                detail: "Gripper identity did not match the authenticated ROBControl session.",
                snapshot: snapshot
            )
            return
        }
        guard intent.boundsValidationError == nil else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedInvalid,
                detail: "Gripper action, lease, or conservative 2–20 intensity was invalid.",
                snapshot: snapshot
            )
            return
        }
        guard intent.sequence > (lastInboundSequence[key] ?? 0) else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedStaleSequence,
                detail: "Gripper command sequence was stale or replayed.",
                snapshot: snapshot
            )
            return
        }
        guard intent.freshnessValidationError(nowUnixMilliseconds: now) == nil else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedExpired,
                detail: "Gripper command lease expired or its clock was invalid.",
                snapshot: snapshot
            )
            return
        }
        lastInboundSequence[key] = intent.sequence

        guard intent.deadManHeld else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedDeadMan,
                detail: "Both Vision controller grip buttons must be held.",
                snapshot: snapshot
            )
            return
        }
        guard ROBControlLiveSessionRegistry.isActiveOperator(
            controllerID: authenticatedControllerID,
            sessionID: authenticatedSessionID
        ) else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedSessionInactive,
                detail: "The authenticated ROBControl session is no longer active.",
                snapshot: snapshot
            )
            return
        }
        guard ROBAmberDebugAuthority.shared.authorizesController() else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedAuthorityDisabled,
                detail: "Cerebro's local, time-limited controller authority is disabled.",
                snapshot: snapshot
            )
            return
        }
        guard ROBAmberGatewayClient.shared.isReady() else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .gatewayRejected,
                detail: "The authenticated Amber gateway is not ready.",
                snapshot: snapshot
            )
            return
        }
        guard snapshot.calibrationState == .commandAcceptedUnverified else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedCalibrationRequired,
                detail: "Calibrate this gripper locally in Cerebro after the current power-up.",
                snapshot: snapshot
            )
            return
        }
        guard pendingArm[intent.arm] == nil, !snapshot.commandInFlight else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedBusy,
                detail: "A gripper command is already awaiting Amber acknowledgement.",
                snapshot: snapshot
            )
            return
        }
        // Close the authority-revocation race immediately before the only
        // hardware-reachable call in this bridge.
        guard ROBAmberDebugAuthority.shared.authorizesController() else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .rejectedAuthorityDisabled,
                detail: "Controller authority was revoked before dispatch.",
                snapshot: snapshot
            )
            return
        }

        let commandID = ROBAmberGatewayClient.shared.controlGripper(
            forArm: intent.arm.rawValue,
            action: intent.action.rawValue,
            force: intent.force
        )
        guard commandID != 0 else {
            sendDisposition(
                for: intent,
                recipientID: authenticatedControllerID,
                sessionID: authenticatedSessionID,
                disposition: .gatewayRejected,
                detail: "Cerebro could not queue the gripper command to Amber.",
                snapshot: gatewaySnapshot(for: intent.arm)
            )
            return
        }
        pendingByCommandID[commandID] = PendingCommand(
            request: intent,
            controllerID: authenticatedControllerID,
            sessionID: authenticatedSessionID
        )
        pendingArm[intent.arm] = commandID
    }

    private func gatewayCommandCompleted(_ notification: Notification) {
        guard let info = notification.userInfo,
              info["operation"] as? String == "gripper_control",
              let commandID = (info["commandID"] as? NSNumber)?.uint64Value
                ?? info["commandID"] as? UInt64,
              let pending = pendingByCommandID.removeValue(forKey: commandID) else { return }
        pendingArm.removeValue(forKey: pending.request.arm)
        let accepted = (info["accepted"] as? NSNumber)?.boolValue
            ?? info["accepted"] as? Bool ?? false
        let rawError = info["error"] as? String ?? ""
        let detail = accepted
            ? "Amber acknowledged core dispatch. Physical position, applied force, and completion remain unverified."
            : (rawError.isEmpty ? "Amber rejected the gripper command." : rawError)
        sendDisposition(
            for: pending.request,
            recipientID: pending.controllerID,
            sessionID: pending.sessionID,
            disposition: accepted ? .dispatchAcknowledgedUnverified : .gatewayRejected,
            detail: detail,
            snapshot: gatewaySnapshot(for: pending.request.arm)
        )
        publishState(for: pending.request.arm)
    }

    private func gatewayStateChanged(_ notification: Notification) {
        let raw = (notification.userInfo?["state"] as? NSNumber)?.intValue
            ?? notification.userInfo?["state"] as? Int
        if raw == ROBAmberGatewayState.ready.rawValue {
            queryBothStates()
        } else {
            failPendingCommands(detail: "The Amber gateway session ended before acknowledgement.")
            publishBothStates()
        }
    }

    private func gripperDidUpdate(_ notification: Notification) {
        if let snapshot = notification.userInfo?["snapshot"] as? NSDictionary,
           let armName = snapshot["arm"] as? String,
           let arm = ROBArmSide(rawValue: armName) {
            publishState(for: arm, snapshot: snapshot)
            return
        }
        publishBothStates()
    }

    private func queryBothStates() {
        for arm in ROBArmSide.allCases {
            _ = ROBAmberGatewayClient.shared.queryGripperState(forArm: arm.rawValue)
        }
    }

    private func failPendingCommands(detail: String) {
        let pending = pendingByCommandID.values
        pendingByCommandID.removeAll()
        pendingArm.removeAll()
        for command in pending {
            sendDisposition(
                for: command.request,
                recipientID: command.controllerID,
                sessionID: command.sessionID,
                disposition: .gatewayRejected,
                detail: detail,
                snapshot: gatewaySnapshot(for: command.request.arm)
            )
        }
    }

    private func publishBothStates() {
        for arm in ROBArmSide.allCases { publishState(for: arm) }
    }

    private func publishState(
        for arm: ROBArmSide,
        snapshot: NSDictionary? = nil,
        recipientID: UUID? = nil,
        sessionID: UUID? = nil
    ) {
        let state = snapshot.map { parsedSnapshot($0, arm: arm) } ?? gatewaySnapshot(for: arm)
        let sequence = (stateSequence[arm] ?? 0) &+ 1
        stateSequence[arm] = max(sequence, 1)
        let message = ROBGripperStateEnvelope(
            arm: arm,
            sequence: max(sequence, 1),
            sampledAtUnixMilliseconds: ROBGripperControlWireCodec.currentUnixMilliseconds(),
            calibrationState: state.calibrationState,
            calibrationVerified: false,
            feedbackAvailable: false,
            commandInFlight: state.commandInFlight,
            lastAction: state.lastAction,
            lastForce: state.lastForce,
            detail: state.detail
        )
        guard let data = try? ROBGripperControlWireCodec.encode(message) else { return }
        _ = server?.sendGripperControlMessage(
            data,
            to: recipientID,
            sessionID: sessionID
        )
    }

    private func sendDisposition(
        for request: ROBGripperCommandIntentEnvelope,
        recipientID: UUID,
        sessionID: UUID,
        disposition: ROBGripperDispositionKind,
        detail: String,
        snapshot: ParsedSnapshot
    ) {
        let message = ROBGripperCommandDispositionEnvelope(
            requestMessageID: request.messageID,
            recipientID: recipientID,
            sessionID: sessionID,
            arm: request.arm,
            receivedAtUnixMilliseconds: ROBGripperControlWireCodec.currentUnixMilliseconds(),
            disposition: disposition,
            detail: String(detail.prefix(256)),
            calibrationState: snapshot.calibrationState,
            action: disposition == .dispatchAcknowledgedUnverified ? request.action : nil,
            force: disposition == .dispatchAcknowledgedUnverified ? request.force : nil
        )
        guard let data = try? ROBGripperControlWireCodec.encode(message) else { return }
        _ = server?.sendGripperControlMessage(
            data,
            to: recipientID,
            sessionID: sessionID
        )
    }

    private struct ParsedSnapshot {
        let calibrationState: ROBGripperCalibrationState
        let commandInFlight: Bool
        let lastAction: ROBGripperAction?
        let lastForce: Int?
        let detail: String
    }

    private func gatewaySnapshot(for arm: ROBArmSide) -> ParsedSnapshot {
        parsedSnapshot(
            ROBAmberGatewayClient.shared.gripperSnapshot(forArm: arm.rawValue),
            arm: arm
        )
    }

    private func parsedSnapshot(_ value: NSDictionary, arm: ROBArmSide) -> ParsedSnapshot {
        let calibrationRaw = value["calibrationState"] as? String
            ?? value["calibration_state"] as? String
            ?? ROBGripperCalibrationState.required.rawValue
        let calibration = ROBGripperCalibrationState(rawValue: calibrationRaw) ?? .required
        let inFlight = (value["commandInFlight"] as? NSNumber)?.boolValue
            ?? value["commandInFlight"] as? Bool
            ?? (value["command_in_flight"] as? NSNumber)?.boolValue
            ?? value["command_in_flight"] as? Bool
            ?? false
        let actionRaw = value["lastAction"] as? String
            ?? value["last_action"] as? String
            ?? value["action"] as? String
        let force = (value["lastForce"] as? NSNumber)?.intValue
            ?? value["lastForce"] as? Int
            ?? (value["last_force"] as? NSNumber)?.intValue
            ?? value["last_force"] as? Int
            ?? (value["force"] as? NSNumber)?.intValue
            ?? value["force"] as? Int
        let defaultDetail = calibration == .required
            ? "Calibration is required for the current Amber gateway session."
            : "Amber accepted calibration dispatch; physical calibration remains unverified."
        let detail = (value["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultDetail
        return ParsedSnapshot(
            calibrationState: calibration,
            commandInFlight: inFlight,
            lastAction: actionRaw.flatMap(ROBGripperAction.init(rawValue:)),
            lastForce: force.flatMap { (1 ... 300).contains($0) ? $0 : nil },
            detail: String(detail.prefix(256))
        )
    }
}
