import Foundation

/// The operator decides on the controller; Cerebro owns execution and its
/// measured result. No desktop alert, persisted grant, or per-waypoint prompt.
@objcMembers final class ROBControllerArmApproval: NSObject {
    static let shared = ROBControllerArmApproval()
    static let supervisedRouteNotice = "Supervised taught route: by approving, confirm both arms are physically hanging at zero for a new session, the route is clear and grippers are empty for a greeting. Watch the arms even if camera visibility is poor; keep Stop + hold ready. Gripper calibration and closing still require a camera check."
    static let supervisedGreetingName = "Supervised greet: confirm hanging/clear route/empty jaws; watch despite poor view; neck scan, arms front, wave"
    private(set) var status = "Arm operations require approval on Vision Pro or iPhone"
    var isPending: Bool { pending != nil }
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
    }
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
              p.arguments["gesture"] as? String == name, let peer = p.peer else { return false }
        return peerIsFresh(peer) && now().timeIntervalSince(p.started!) < 120
    }

    /// Only an active approval whose on-controller wording explicitly covers
    /// operator-supervised travel may replace the semantic route inspection.
    /// Never persist or infer this scope from a model's request or a preference.
    func authorizesSupervisedArmRoute() -> Bool {
        guard let p = pending, let started = p.started, let peer = p.peer,
              peerIsFresh(peer), (0..<120).contains(now().timeIntervalSince(started)) else { return false }
        return (p.action == "arm_operation" && p.summary.hasSuffix(Self.supervisedRouteNotice))
            || (p.action == "play_gesture" && p.summary == Self.supervisedGreetingName)
    }

    private func request(action: String, arguments: NSDictionary, summary: String,
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
            created: now(), execute: execute, cancel: cancel, completion: completion)
        update("Waiting for Vision Pro or iPhone to approve: \(summary)")
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    /// Called only after AutoNet has authenticated an operator device/session.
    @nonobjc func receive(_ message: ROBRobotActionMessage, device: UUID, session: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard sessionIsActive(device, session), message.validationError == nil else { return false }
        if message.kind == .controllerHello {
            if message.acceptsActions {
                peers[device] = Peer(device: device, session: session, sender: message.senderID, seen: now(),
                                     capabilities: Set(message.capabilities))
                if let p = pending, p.peer?.device == device, !message.capabilities.contains(p.action) {
                    cancel(reason: "The controller stopped accepting this motion operation.")
                }
            } else {
                peers.removeValue(forKey: device)
                if pending?.peer?.device == device, pending?.peer?.session == session {
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
            pending?.started = now() // Commit once before any execution callback.
            update("Controller approved: \(p.summary)")
            publish(.executing, detail: status, result: [:])
            p.execute { [weak self] result in
                guard let self else { return }
                precondition(Thread.isMainThread)
                guard self.pending?.id == p.id else { return }
                let outcome = result["status"] as? String ?? "failed"
                let succeeded = ["completed", "accepted_unverified", "ready_for_object", "grip_attempted"].contains(outcome)
                self.finish(result, state: succeeded ? .completed : .failed)
            }
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
        guard let p = pending else { return }
        // Clear before callbacks, so cancellation/replayed accepts cannot restart.
        finish(["status": "cancelled", "detail": reason], state: .cancelled, cancelExecution: p.started != nil)
    }

    @nonobjc func tick() {
        precondition(Thread.isMainThread)
        guard let p = pending else { return }
        if let peer = p.peer {
            guard peerIsFresh(peer) else {
                cancel(reason: "The approving controller disconnected; arm hold requested."); return
            }
            if let started = p.started {
                if now().timeIntervalSince(started) > 120 {
                    cancel(reason: "The approved arm operation timed out; hold requested.")
                }
            } else if p.request.map(isExpired) == true {
                finish(["status": "expired", "detail": "No controller approval arrived before the deadline."], state: .expired)
            }
            return
        }
        guard now().timeIntervalSince(p.created) < 30 else {
            finish(["status": "blocked", "detail": "Connect Vision Pro or iPhone and enable Action Approvals. No arm operation was started."], state: .expired)
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
        pending = nil; timer?.invalidate(); timer = nil
        if cancelExecution { p.cancel() }
        update(result["detail"] as? String ?? "Arm operation ended")
        p.completion(result)
    }
}
