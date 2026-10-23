import Foundation

/// The operator decides on the controller; Cerebro owns execution and its
/// measured result. No desktop alert, persisted grant, or per-waypoint prompt.
@objcMembers final class ROBControllerArmApproval: NSObject {
    static let shared = ROBControllerArmApproval()
    static let supervisedRouteNotice = "Supervised taught route: by approving, confirm both arms are physically hanging at zero for a new session, the route is clear and grippers are empty for a greeting. Watch the arms even if camera visibility is poor; keep Stop + hold ready. Gripper calibration and closing still require a camera check."
    static let supervisedGreetingName = "Supervised greet: confirm hanging/clear route/empty jaws; watch despite poor view; neck scan, arms front, wave"
    private(set) var status = "Arm operations need spoken or controller authorization"
    var isPending: Bool { pending != nil }
    var armSessionActive: Bool { armSession.map(sessionIsFresh) ?? false }
    var armSessionDetail: String {
        guard armSessionActive, let session = armSession else { return "No active arm rehearsal session" }
        let end = DateFormatter.localizedString(from: session.expires, dateStyle: .none, timeStyle: .short)
        return "Left-arm session authorized until \(end). Covered routines do not ask again. Stop ends the session."
    }
    var announceApproval: ((String) -> Void)?
    @nonobjc var send: ((ROBRobotActionMessage, UUID, UUID) -> Bool)?
    @nonobjc var sessionIsActive: (UUID, UUID) -> Bool = {
        ROBControlLiveSessionRegistry.isActiveOperator(controllerID: $0, sessionID: $1)
    }
    @nonobjc var now: () -> Date = Date.init

    private struct Peer {
        let device: UUID
        let session: UUID
        let sender: String
        let seen: Date
        let capabilities: Set<String>
    }
    private struct Pending {
        let id: String
        let action: String
        let arguments: NSDictionary
        let summary: String
        let created: Date
        let execute: (@escaping (NSDictionary) -> Void) -> Void
        let cancel: () -> Void
        let completion: (NSDictionary) -> Void
        var peer: Peer?
        var request: ROBRobotActionMessage?
        var started: Date?
        let executionLimit: TimeInterval
        var voiceAuthorized = false
        var armSessionID: String? = nil
        var attentionReminders = 0
    }
    private struct ArmSession {
        let id: String
        let peer: Peer?
        let voiceAuthorized: Bool
        let expires: Date
    }
    private var armSession: ArmSession?
    private var peers: [UUID: Peer] = [:]
    private var pending: Pending?
    private var timer: Timer?
    private let senderID = "Cerebro.arm-operations"
    // Give the operator time to notice the phone banner and review the complete
    // operation. No execution begins until a current controller accepts it.
    private static let operatorApprovalSeconds: TimeInterval = 90

    func request(operation: String, arm: String, summary: String,
                 execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
                 cancel: @escaping () -> Void,
                 completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation": operation, "arm": arm, "summary": summary],
                summary: summary, execute: execute, cancel: cancel, completion: completion)
    }

    /// A reviewed immutable ghost rendition remains bounded to three minutes.
    /// This does not change other arm or gripper approval deadlines.
    @nonobjc func requestLeftGesture(summary: String,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": "left", "summary": summary],
            summary: summary, executionLimit: 180, allowArmSession: true, execute: execute, cancel: cancel, completion: completion)
    }

    /// One bounded task includes local search, pointing assistance, planning,
    /// all arm segments and gripper actions. No nested approval per step.
    @nonobjc func requestLeftWorkspaceTask(summary: String,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": "left", "summary": summary],
            summary: summary, executionLimit: 600, allowArmSession: true, execute: execute, cancel: cancel, completion: completion)
    }
    @nonobjc func requestLeftStationary(summary: String,
        execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
        cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": "left", "summary": summary],
            summary: summary, allowArmSession: true, execute: execute, cancel: cancel, completion: completion)
    }

    func beginArmSession(completion: @escaping (NSDictionary) -> Void) {
        let summary = "Authorize a 15-minute supervised LEFT-arm rehearsal: local search/pointing, preparation of the CONFIRMED-EMPTY arm, empty calibration, a stationary EMPTY-jaw initialization close at intensity 2 followed by opening at fixed intensity 10, bounded reviewed gestures, empty-can recycling with gentle closing at intensity 2 and gravity release at intensity 10, and empty-arm lowering. A held EMPTY arm after a missed recycling attempt may first return through its recorded visited targets to front; an explicit local grasp-clearance calibration may skip low targets only after validating each connecting segment above the calibrated height. No unvisited recovery targets. Confirm no object is held. One authorization covers these complete routines and all waypoints. No driving, right-arm motion, arbitrary raw targets, blind force escalation or torque-off with a payload. The model/hand-eye geometry is provisional; watch clearance and keep Stop available. Stop, sleep/restart, expiry or controller loss ends this session."
        request(action: "arm_operation", arguments: ["operation": "manual", "arm": "left", "summary": summary],
            summary: summary, execute: { [weak self] done in
                guard let self, let p = self.pending else { return }
                self.armSession = ArmSession(id: p.id, peer: p.peer, voiceAuthorized: p.voiceAuthorized,
                    expires: self.now().addingTimeInterval(900))
                done(["status": "completed", "measured": false,
                    "detail": "Left-arm rehearsal authorized for 15 minutes. Complete local routines no longer ask again. Stop ends the session; held objects must be supported before lowering."])
            }, cancel: {}, completion: completion)
    }

    private func sessionIsFresh(_ session: ArmSession) -> Bool {
        session.expires > now() && (session.voiceAuthorized || session.peer.map(peerIsFresh) == true)
    }

    private func authorizationIsLive(_ p: Pending) -> Bool {
        guard let started = p.started, (0..<p.executionLimit).contains(now().timeIntervalSince(started)) else { return false }
        if let id = p.armSessionID {
            return armSession.map { $0.id == id && sessionIsFresh($0) } == true
        }
        return p.voiceAuthorized || p.peer.map(peerIsFresh) == true
    }

    /// Call only from the live local microphone transcript path, after echo
    /// suppression. Camera text, typed chat and model tool calls never enter it.
    func receiveSpokenAuthorization(_ text: String) -> Bool {
        precondition(Thread.isMainThread)
        guard let p = pending, p.started == nil, now().timeIntervalSince(p.created) < Self.operatorApprovalSeconds else { return false }
        guard let accepted = Self.spokenDecision(text) else { return false }
        if !accepted { cancel(reason: "Local spoken rejection; no new motion authorized."); return true }
        pending?.voiceAuthorized = true
        beginAcceptedOperation()
        return true
    }

    /// Endpoint a stable microphone candidate promptly, then wait for its
    /// recognizer FINAL result before granting anything. Continuous dictation
    /// otherwise may not finalize a short "yes" until its minute-long timeout.
    func isSpokenAuthorizationCandidate(_ text: String) -> Bool {
        guard let p = pending, p.started == nil, now().timeIntervalSince(p.created) < Self.operatorApprovalSeconds else { return false }
        return Self.spokenDecision(text) != nil
    }

    private static func spokenDecision(_ text: String) -> Bool? {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "^(?:(?:hey )?(?:rob|robbie|robot)[, ]+)?"
        if value.range(of: prefix + "(?:no|no thanks|cancel|reject|do not proceed|don't proceed)[.!?]*$", options: .regularExpression) != nil {
            return false
        }
        return value.range(of: prefix + "(?:yes(?:[, ]+(?:please|proceed|go ahead|do it|continue))?|(?:ok|okay)(?:[, ]+(?:proceed|go ahead|do it))?|sure|proceed|go ahead|approved|permission granted)[.!?]*$", options: .regularExpression) != nil ? true : nil
    }

    private func beginAcceptedOperation() {
        guard let p = pending, p.started == nil else { return }
        pending?.started = now()
        update("Authorized complete operation: \(p.summary)")
        publish(.executing, detail: status, result: [:])
        p.execute { [weak self] result in
            guard let self, self.pending?.id == p.id else { return }
            precondition(Thread.isMainThread)
            let outcome = result["status"] as? String ?? "failed"
            let succeeded = ["completed", "accepted_unverified", "ready_for_object", "grip_attempted"].contains(outcome)
            let noReach = result["reach_sent"] as? Bool == false
            let safelyParked = noReach && result["empty_arm_parked"] as? Bool == true
            let observationOnly = ["not_found", "not_localized", "not_reachable", "needs_help"].contains(outcome)
                && (result["arm_motion_sent"] as? Bool == false || safelyParked)
            if !succeeded, !observationOnly, p.armSessionID != nil { self.armSession = nil }
            self.finish(result, state: succeeded ? .completed : .failed)
        }
    }

    /// Existing controllers already review named play_gesture requests and
    /// leave their execution/result to Cerebro. Use that same authenticated,
    /// one-shot lane for an immutable, bounded neck rehearsal.
    func requestMotionPath(name: String, execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
                           cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        request(action: "play_gesture", arguments: ["gesture": name], summary: name,
                execute: execute, cancel: cancel, completion: completion)
    }

    func authorizesMotionPath(_ name: String) -> Bool {
        guard let p = pending, p.started != nil, p.action == "play_gesture",
              p.arguments["gesture"] as? String == name else { return false }
        return authorizationIsLive(p)
    }

    /// Exact one-shot scope for the operator-supervised physical-left trial.
    func authorizesLeftArmTrial(_ summary: String) -> Bool {
        guard let p = pending,
              p.action == "arm_operation", p.arguments["operation"] as? String == "manual",
              p.arguments["arm"] as? String == "left", p.summary == summary,
              authorizationIsLive(p) else { return false }
        return true
    }

    /// Only an active approval whose on-controller wording explicitly covers
    /// operator-supervised travel may replace the semantic route inspection.
    /// Never persist or infer this scope from a model's request or a preference.
    func authorizesSupervisedArmRoute() -> Bool {
        guard let p = pending, authorizationIsLive(p) else { return false }
        return (p.action == "arm_operation" && p.summary.hasSuffix(Self.supervisedRouteNotice))
            || (p.action == "play_gesture" && p.summary == Self.supervisedGreetingName)
    }

    private func request(action: String, arguments: NSDictionary, summary: String, executionLimit: TimeInterval = 120,
                         allowArmSession: Bool = false,
                         execute: @escaping (@escaping (NSDictionary) -> Void) -> Void,
                         cancel: @escaping () -> Void, completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        guard pending == nil else {
            completion(["status": "busy", "detail": status]); return
        }
        let probe = ROBRobotActionMessage.actionRequest(callID: UUID().uuidString,
            action: action, arguments: arguments,
            senderID: senderID, recipientID: nil, expiresAt: now().addingTimeInterval(Self.operatorApprovalSeconds))
        guard probe.validationError == nil else {
            completion(["status": "rejected", "detail": "Invalid controller motion approval request."]); return
        }
        pending = Pending(id: probe.callID!, action: action, arguments: arguments.copy() as! NSDictionary, summary: summary,
            created: now(), execute: execute, cancel: cancel, completion: completion, executionLimit: executionLimit)
        if allowArmSession, let session = armSession, sessionIsFresh(session) {
            pending?.peer = session.peer; pending?.voiceAuthorized = session.voiceAuthorized
            pending?.armSessionID = session.id
            startTimer(); beginAcceptedOperation(); return
        }
        update("Awaiting spoken or controller authorization: \(summary)")
        // Rob requested this exact brief spoken prompt. The immutable complete
        // scope remains in the controller request and Settings status.
        announceApproval?("Can I move my arms?")
        startTimer()
        tick()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Called only after AutoNet has authenticated an operator device/session.
    @nonobjc func receive(_ message: ROBRobotActionMessage, device: UUID, session: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard sessionIsActive(device, session), message.validationError == nil else { return false }
        if message.kind == .actionCancel, let grant = armSession, message.callID == grant.id,
           let peer = grant.peer, peer.device == device, peer.session == session,
           message.senderID == peer.sender, message.recipientID == senderID {
            cancel(reason: "Controller ended the arm rehearsal session; hold requested.")
            return true
        }
        if message.kind == .controllerHello {
            if message.acceptsActions {
                peers[device] = Peer(device: device, session: session, sender: message.senderID, seen: now(),
                                     capabilities: Set(message.capabilities))
                if let p = pending, p.peer?.device == device, !message.capabilities.contains(p.action) {
                    cancel(reason: "The controller stopped accepting this motion operation.")
                }
            } else {
                peers.removeValue(forKey: device)
                if armSession?.peer?.device == device, armSession?.voiceAuthorized == false { armSession = nil }
                if pending?.peer?.device == device, pending?.peer?.session == session, pending?.voiceAuthorized != true {
                    self.cancel(reason: "The controller stopped accepting arm operations.")
                }
            }
            tick()
            return false // Existing action workflows also consume hello.
        }
        guard let p = pending, message.callID == p.id else { return false }
        guard let peer = p.peer, peer.device == device, peer.session == session,
              message.senderID == peer.sender, message.recipientID == senderID else { return true }
        if message.kind == .actionCancel {
            cancel(reason: "The controller cancelled the arm operation."); return true
        }
        guard message.kind == .actionStatus else { return true }
        if message.state == .accepted {
            guard p.started == nil else {
                publish(.executing, detail: "This approved operation is already running.", result: [:]); return true
            }
            guard let request = p.request, !isExpired(request),
                  peerIsFresh(peer) else {
                finish(["status": "expired", "detail": "Controller approval expired; no operation was started."], state: .expired)
                return true
            }
            beginAcceptedOperation()
        } else if message.isTerminal {
            // A controller can reject/cancel, but cannot assert hardware success.
            if p.started != nil { cancel(reason: "The controller ended the arm operation; hold requested.") }
            else {
                let terminal: ROBRobotActionState
                let outcome: String
                switch message.state {
                case .expired: terminal = .expired; outcome = "expired"
                case .cancelled: terminal = .cancelled; outcome = "cancelled"
                case .failed: terminal = .failed; outcome = "failed"
                default: terminal = .rejected; outcome = "rejected"
                }
                let controllerDetail = message.detail ?? ""
                let detail = controllerDetail.isEmpty ? "The controller did not approve this motion operation."
                    : "Controller: \(String(controllerDetail.prefix(512)))"
                finish(["status": outcome, "detail": detail], state: terminal)
            }
        }
        return true
    }

    func cancel(reason: String) {
        precondition(Thread.isMainThread)
        armSession = nil
        guard let p = pending else {
            timer?.invalidate(); timer = nil; update(reason); return
        }
        // Clear before callbacks, so cancellation/replayed accepts cannot restart.
        finish(["status": "cancelled", "detail": reason], state: .cancelled, cancelExecution: p.started != nil)
    }

    @nonobjc func tick() {
        precondition(Thread.isMainThread)
        if armSession == nil && pending == nil { timer?.invalidate(); timer = nil; return }
        if let session = armSession, !sessionIsFresh(session) {
            armSession = nil
            if pending?.armSessionID != nil { cancel(reason: "Arm rehearsal session ended; hold requested."); return }
            update("Arm rehearsal authorization expired or its controller disconnected.")
        }
        guard let p = pending else { return }
        if p.started == nil, p.attentionReminders < 2,
           now().timeIntervalSince(p.created) >= (p.attentionReminders == 0 ? 20 : 45),
           now().timeIntervalSince(p.created) < Self.operatorApprovalSeconds {
            pending?.attentionReminders += 1
            // Rob requested an audible attention cue when the first question
            // is missed. Repeat the SAME scope without extending its deadline.
            announceApproval?("Hey! Can I move my arms?")
        }
        if p.started != nil, p.voiceAuthorized || p.armSessionID != nil {
            if !authorizationIsLive(p) { cancel(reason: "Authorized arm operation expired; hold requested.") }
            return
        }
        if let peer = p.peer {
            guard peerIsFresh(peer) else {
                cancel(reason: "The approving controller disconnected; arm hold requested."); return
            }
            if let started = p.started {
                if now().timeIntervalSince(started) > p.executionLimit {
                    cancel(reason: "The approved arm operation timed out; hold requested.")
                }
            } else if p.request.map(isExpired) == true {
                finish(["status": "expired", "detail": "No controller approval arrived before the deadline."], state: .expired)
            }
            return
        }
        guard now().timeIntervalSince(p.created) < Self.operatorApprovalSeconds else {
            finish(["status": "blocked", "detail": "No spoken or controller authorization arrived. No arm operation was started."], state: .expired)
            return
        }
        guard let peer = peers.values.filter({ now().timeIntervalSince($0.seen) < 15 &&
            $0.capabilities.contains(p.action) && sessionIsActive($0.device, $0.session) })
            .sorted(by: { $0.seen > $1.seen }).first else { return }
        let request = ROBRobotActionMessage.actionRequest(callID: p.id, action: p.action,
            arguments: p.arguments,
            senderID: senderID, recipientID: peer.sender, expiresAt: now().addingTimeInterval(Self.operatorApprovalSeconds))
        pending?.peer = peer; pending?.request = request
        guard send?(request, peer.device, peer.session) == true else {
            finish(["status": "blocked", "detail": "Could not deliver the arm approval request to the controller."], state: .failed)
            return
        }
    }

    private func isExpired(_ request: ROBRobotActionMessage) -> Bool {
        now().timeIntervalSince1970 * 1000 >= Double(request.expiresAtMilliseconds)
    }

    private func update(_ detail: String) {
        status = detail
        NotificationCenter.default.post(name: Notification.Name("ROBControllerArmApprovalDidChange"), object: self)
    }
    private func peerIsFresh(_ peer: Peer) -> Bool {
        guard let current = peers[peer.device], current.session == peer.session,
              current.sender == peer.sender,
              pending.map({ current.capabilities.contains($0.action) }) != false else { return false }
        return now().timeIntervalSince(current.seen) < 15 && sessionIsActive(peer.device, peer.session)
    }

    /// UI callers capture the selected arm/force before requesting approval.
    /// Recheck feedback and the gateway generation after the operator decides.
    @nonobjc func requestGatewayCommand(operation: String, arm: String, summary: String,
        command: @escaping () -> UInt64, completion: @escaping (NSDictionary) -> Void) {
        let gateway = ROBAmberGatewayClient.shared
        let gatewayArm = arm == "right" ? "left" : "right"
        let port = arm == "right" ? 26001 : 26002
        let generation = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        var observer: NSObjectProtocol?
        var timeout: DispatchWorkItem?
        var commandID: UInt64 = 0
        func cleanup() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil; timeout?.cancel(); timeout = nil
        }
        request(operation: operation, arm: arm, summary: summary, execute: { done in
            let readiness = gateway.manualArmControlReadiness(forUDPPort: port,
                expectedSessionGeneration: generation)
            guard generation != 0, readiness["allowed"] as? Bool == true else {
                done(["status": "blocked", "detail": readiness["reason"] as? String ?? "Gateway session is unavailable."])
                return
            }
            observer = NotificationCenter.default.addObserver(forName: .ROBAmberGatewayCommandDidComplete,
                object: gateway, queue: .main) { note in
                guard commandID != 0, (note.userInfo?["commandID"] as? NSNumber)?.uint64Value == commandID else { return }
                cleanup()
                let accepted = note.userInfo?["accepted"] as? Bool == true
                let gripper = operation.contains("gripper")
                done(["status": accepted ? (gripper ? "accepted_unverified" : "completed") : "failed",
                      "detail": accepted ? (gripper ? "Amber accepted the gripper command; jaw position, force and mechanical completion remain unverified." : "Amber acknowledged the arm mode command.")
                        : (note.userInfo?["error"] as? String ?? "Amber rejected the command.")])
            }
            commandID = command()
            guard commandID != 0 else {
                cleanup(); done(["status": "blocked", "detail": "Arm interlocks rejected the command before submission."]); return
            }
            let deadline = DispatchWorkItem {
                cleanup(); _ = gateway.priorityHold(forArm: gatewayArm)
                done(["status": "failed", "detail": "Amber acknowledgement timed out; arm hold requested."])
            }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        }, cancel: {
            cleanup(); _ = gateway.priorityHold(forArm: gatewayArm)
        }, completion: completion)
    }
    private func publish(_ state: ROBRobotActionState, detail: String, result: NSDictionary) {
        guard let p = pending, let peer = p.peer else { return }
        let reply = ROBRobotActionMessage.actionStatus(callID: p.id, state: state, detail: detail,
            result: result, senderID: senderID, recipientID: peer.sender)
        _ = send?(reply, peer.device, peer.session)
    }
    private func finish(_ result: NSDictionary, state: ROBRobotActionState, cancelExecution: Bool = false) {
        guard let p = pending else { return }
        publish(state, detail: result["detail"] as? String ?? "Arm operation ended", result: result)
        pending = nil
        if armSessionActive { startTimer() } else { timer?.invalidate(); timer = nil }
        if cancelExecution { p.cancel() }
        update(result["detail"] as? String ?? "Arm operation ended")
        p.completion(result)
    }
}
