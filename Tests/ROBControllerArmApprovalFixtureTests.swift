import Foundation
import CryptoKit

// Compile the production broker and wire protocol with these socket-free seams.
enum ROBControlLiveSessionRegistry {
    static func isActiveOperator(controllerID: UUID, sessionID: UUID) -> Bool { false }
}
extension Notification.Name {
    static let ROBAmberGatewayCommandDidComplete = Notification.Name("FixtureArmAck")
}
final class ROBAmberGatewayClient: NSObject {
    static let shared = ROBAmberGatewayClient()
    var generation: UInt64 = 1
    var ready = true
    var holds: [String] = []
    func connectionSnapshot() -> NSDictionary { ["sessionGeneration": NSNumber(value: generation)] }
    func manualArmControlReadiness(forUDPPort: Int, expectedSessionGeneration: UInt64) -> NSDictionary {
        ["allowed": ready && expectedSessionGeneration == generation, "reason": "Feedback/session changed"]
    }
    func priorityHold(forArm arm: String) -> UInt64 { holds.append(arm); return 1 }
}

@main struct ControllerArmApprovalFixtures {
    static let device = UUID(), session = UUID()
    static let sender = "iphone-or-vision"
    static let hello = ROBRobotActionMessage.controllerHello(senderID: sender,
        acceptsActions: true, capabilities: ["arm_operation"])

    static func reply(_ request: ROBRobotActionMessage, _ state: ROBRobotActionState = .accepted,
                      senderID: String = sender, recipientID: String = "Cerebro.arm-operations") -> ROBRobotActionMessage {
        .actionStatus(callID: request.callID!, state: state, detail: "Fixture decision", result: [:],
            senderID: senderID, recipientID: recipientID)
    }

    static func broker() -> ROBControllerArmApproval {
        let b = ROBControllerArmApproval()
        b.standingCanCampaignDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("isolated-standing-campaign-" + UUID().uuidString)
        b.sessionIsActive = { $0 == device && $1 == session }
        return b
    }

    static func main() throws {
        precondition(Thread.isMainThread)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ detail: String) {
            precondition(condition(), detail); checks += 1
        }

        // No controller, unauthenticated hello, or old client can authorize.
        do {
            let b = broker()
            var sent = 0, executed = 0, result: NSDictionary = [:]
            var time = Date(); b.now = { time }
            b.send = { _, _, _ in sent += 1; return true }
            _ = b.receive(hello, device: UUID(), session: UUID())
            b.request(operation: "startup", arm: "both", summary: "Prepare arms and both grippers",
                execute: { _ in executed += 1 }, cancel: {}, completion: { result = $0 })
            check(sent == 0 && executed == 0 && b.isPending, "No authenticated controller must mean no command")
            _ = b.receive(.controllerHello(senderID: sender, acceptsActions: true, capabilities: ["play_gesture"]), device: device, session: session)
            check(sent == 0, "An older controller cannot review an arm operation")
            time.addTimeInterval(91); b.tick()
            check(result["status"] as? String == "blocked" && !b.isPending && executed == 0, "No-controller deadline must fail closed")
        }

        // Approval binds to exact device, session, sender alias and recipient.
        do {
            let b = broker()
            var messages: [ROBRobotActionMessage] = [], executed = 0, stopped = 0
            var done: ((NSDictionary) -> Void)?, terminal: NSDictionary = [:]
            b.send = { message, target, targetSession in
                check(target == device && targetSession == session, "Delivery must target the authenticated session")
                messages.append(message); return true
            }
            _ = b.receive(hello, device: device, session: session)
            b.request(operation: "prepare", arm: "both", summary: "Front and calibrate both empty grippers",
                execute: { executed += 1; done = $0 }, cancel: { stopped += 1 }, completion: { terminal = $0 })
            let request = messages[0]
            check(request.arguments["operation"] as? String == "prepare" && executed == 0, "A request alone must not execute")
            let archive = ROBRobotActionWireCodec.archive(request, legacySender: request.senderID)!
            check(ROBRobotActionWireCodec.decodeEnvelopeData(archive)?.callID == request.callID, "Arm approval wire round trip")
            _ = b.receive(reply(request), device: UUID(), session: session)
            _ = b.receive(reply(request), device: device, session: UUID())
            _ = b.receive(reply(request, senderID: "forged"), device: device, session: session)
            _ = b.receive(reply(request, recipientID: "another-cerebro"), device: device, session: session)
            check(executed == 0, "Wrong identity or destination cannot approve")
            var competing: NSDictionary = [:]
            b.request(operation: "relax", arm: "both", summary: "Competing request", execute: { _ in executed += 100 }, cancel: {}, completion: { competing = $0 })
            check(competing["status"] as? String == "busy", "Only one immutable approval at a time")
            _ = b.receive(reply(request), device: device, session: session)
            _ = b.receive(reply(request), device: device, session: session)
            check(executed == 1 && messages.last?.state == .executing, "Duplicate acceptance must not execute twice")
            done?(["status": "completed", "detail": "Measured front pose"])
            check(terminal["status"] as? String == "completed" && !b.isPending && stopped == 0, "Only executor completion ends a successful operation")
            _ = b.receive(reply(request), device: device, session: session)
            check(executed == 1, "Acceptance replay after completion must not restart")
        }

        // Physical-left trials require the exact accepted manual operation,
        // side and summary. They do not inherit another arm's approval.
        for arm in ["left", "right", "both"] {
            let b = broker()
            var request: ROBRobotActionMessage?, done: ((NSDictionary) -> Void)?
            b.send = { message, _, _ in if message.kind == .actionRequest { request = message }; return true }
            _ = b.receive(hello, device: device, session: session)
            b.request(operation: "manual", arm: arm, summary: "Exact left trial",
                execute: { done = $0 }, cancel: {}, completion: { _ in })
            check(!b.authorizesLeftArmTrial("Exact left trial"), "Pending trial cannot move")
            _ = b.receive(reply(request!), device: device, session: session)
            check(b.authorizesLeftArmTrial("Exact left trial") == (arm == "left"), "Trial scope must bind physical side")
            check(!b.authorizesLeftArmTrial("Different trial"), "Trial scope must bind complete summary")
            done?(["status": "completed"])
            check(!b.authorizesLeftArmTrial("Exact left trial"), "Completed trial cannot authorize another movement")
        }

        // Poor-view travel is covered only by the wording the operator actually
        // approved, never by a pending, old, ordinary or expired approval.
        for supervised in [false, true] {
            let b = broker()
            var request: ROBRobotActionMessage?, done: ((NSDictionary) -> Void)?
            b.send = { message, _, _ in if message.kind == .actionRequest { request = message }; return true }
            _ = b.receive(hello, device: device, session: session)
            let summary = "Prepare both arms. " + (supervised ? ROBControllerArmApproval.supervisedRouteNotice : "Check camera clearance first.")
            b.request(operation: "prepare", arm: "both", summary: summary,
                execute: { done = $0 }, cancel: {}, completion: { _ in })
            check(!b.authorizesSupervisedArmRoute(), "Pending request cannot authorize degraded visibility")
            _ = b.receive(reply(request!), device: device, session: session)
            check(b.authorizesSupervisedArmRoute() == supervised, "Supervision scope must match the reviewed wording")
            done?(["status": "completed"])
            check(!b.authorizesSupervisedArmRoute(), "Supervision must end with the approved operation")
        }

        // A connected operator can review after the old 30-second window,
        // but elapsed time alone never starts or renews an operation.
        do {
            let b = broker()
            var time = Date(), request: ROBRobotActionMessage?, executed = 0
            var done: ((NSDictionary) -> Void)?
            b.now = { time }
            b.send = { message, _, _ in if message.kind == .actionRequest { request = message }; return true }
            _ = b.receive(hello, device: device, session: session)
            b.request(operation: "prepare", arm: "both", summary: "Front and calibrate both empty grippers",
                execute: { executed += 1; done = $0 }, cancel: {}, completion: { _ in })
            let r = request!
            check(abs(Double(r.expiresAtMilliseconds - r.sentAtMilliseconds) - 90_000) < 100,
                "The delivered phone review window must be 90 seconds")
            time.addTimeInterval(60)
            _ = b.receive(hello, device: device, session: session)
            check(b.isPending && executed == 0 && request?.callID == r.callID,
                "Waiting with a fresh controller must retain the same unapproved operation")
            _ = b.receive(reply(r), device: device, session: session)
            check(executed == 1, "A current approval within 90 seconds should execute once")
            done?(["status": "completed"])
        }

        // A frozen ghost rendition has its own bounded three-minute execution
        // lease. The review window and all ordinary requests remain unchanged.
        do {
            let b = broker()
            var time = Date(), request: ROBRobotActionMessage?, held = 0
            b.now = { time }
            b.send = { message, _, _ in if message.kind == .actionRequest { request = message }; return true }
            _ = b.receive(hello, device: device, session: session)
            b.requestLeftGesture(summary: "Reviewed immutable ghost", execute: { _ in }, cancel: { held += 1 }, completion: { _ in })
            _ = b.receive(reply(request!), device: device, session: session)
            time.addTimeInterval(125)
            _ = b.receive(hello, device: device, session: session)
            check(b.authorizesLeftArmTrial("Reviewed immutable ghost"), "Ghost authorization ended before its bounded rendition window")
            time.addTimeInterval(56)
            _ = b.receive(hello, device: device, session: session)
            check(!b.isPending && held == 1, "Ghost execution exceeded three minutes without cancellation/hold")
        }

        // Rejection, expiry, decline, send failure, disconnect and lost opt-in.
        for scenario in ["reject", "expired", "claimed_complete", "disconnect_pending", "disconnect_running", "disabled", "cancel", "send_failed"] {
            let b = broker()
            var time = Date(), connected = true, request: ROBRobotActionMessage?
            var executed = 0, held = 0, completed = 0
            var done: ((NSDictionary) -> Void)?
            b.now = { time }; b.sessionIsActive = { $0 == device && $1 == session && connected }
            b.send = { message, _, _ in
                if message.kind == .actionRequest { request = message }
                return scenario != "send_failed"
            }
            _ = b.receive(hello, device: device, session: session)
            b.request(operation: "relax", arm: "both", summary: "Lower gently and deactivate",
                execute: { executed += 1; done = $0 }, cancel: { held += 1 }, completion: { _ in completed += 1 })
            let r = request!
            switch scenario {
            case "reject": _ = b.receive(reply(r, .rejected), device: device, session: session)
            case "claimed_complete": _ = b.receive(reply(r, .completed), device: device, session: session)
            case "expired":
                time = Date(timeIntervalSince1970: Double(r.expiresAtMilliseconds) / 1000)
                _ = b.receive(hello, device: device, session: session)
                _ = b.receive(reply(r), device: device, session: session)
            case "disconnect_pending": connected = false; b.tick()
            case "disconnect_running", "disabled", "cancel":
                _ = b.receive(reply(r), device: device, session: session)
                if scenario == "disabled" {
                    _ = b.receive(.controllerHello(senderID: sender, acceptsActions: false, capabilities: []), device: device, session: session)
                } else if scenario == "cancel" { b.cancel(reason: "Stop + hold") }
                else { connected = false; b.tick() }
                check(held == 1, "Active operation must request hold on \(scenario)")
                done?(["status": "completed", "detail": "Late callback"])
            default: break
            }
            check(!b.isPending && completed == 1, "\(scenario) must terminate exactly once")
            check(executed == (["disconnect_running", "disabled", "cancel"].contains(scenario) ? 1 : 0), "\(scenario) unexpectedly dispatched hardware")
        }

        // Changing gateway session while the user reviews must invalidate approval.
        do {
            let b = broker(), gateway = ROBAmberGatewayClient.shared
            var request: ROBRobotActionMessage?, commands = 0, result: NSDictionary = [:]
            b.send = { message, _, _ in if message.kind == .actionRequest { request = message }; return true }
            _ = b.receive(hello, device: device, session: session)
            b.requestGatewayCommand(operation: "position", arm: "right", summary: "Position and hold",
                command: { commands += 1; return 12 }, completion: { result = $0 })
            gateway.generation += 1
            _ = b.receive(reply(request!), device: device, session: session)
            check(commands == 0 && result["status"] as? String == "blocked", "Reconnection must invalidate the reviewed command")
        }

        // A controller's expiry detail must not be presented as an operator rejection.
        do {
            let b = broker()
            var request: ROBRobotActionMessage?, result: NSDictionary = [:], executed = false
            b.send = { message, _, _ in if message.kind == .actionRequest { request = message }; return true }
            _ = b.receive(.controllerHello(senderID: sender, acceptsActions: true, capabilities: ["play_gesture"]), device: device, session: session)
            b.requestMotionPath(name: "Bounded neck rehearsal", execute: { _ in executed = true }, cancel: {}, completion: { result = $0 })
            _ = b.receive(reply(request!, .expired), device: device, session: session)
            check(!executed && result["status"] as? String == "expired", "Controller expiry cannot execute or become rejection")
            check(result["detail"] as? String == "Controller: Fixture decision", "Preserve the controller's reason")
        }

        for arguments: NSDictionary in [
            ["operation": "activate", "arm": "both", "summary": "Reviewed operation", "force": 999],
            ["operation": "invented", "arm": "both", "summary": "Reviewed operation"],
            ["operation": "activate", "arm": "unknown", "summary": "Reviewed operation"]
        ] {
            let request = ROBRobotActionMessage.actionRequest(callID: UUID().uuidString, action: "arm_operation",
                arguments: arguments, senderID: "Cerebro", recipientID: sender, expiresAt: Date().addingTimeInterval(30))
            check(request.validationError != nil, "Unreviewable/unknown arm command must be rejected")
        }
        do {
            let b = broker()
            var executed = 0, stopped = 0, spoken = 0
            b.announceApproval = { text in
                spoken += 1
                check(text == "Can I move my arms?", "Use Rob's exact brief spoken authorization prompt")
            }
            b.requestLeftWorkspaceTask(summary: "One complete recycling task", execute: { _ in executed += 1 },
                cancel: { stopped += 1 }, completion: { _ in })
            for text in ["say yes proceed", "if I say yes", "yes but don't move", "not approved", "\"yes proceed\""] {
                check(!b.receiveSpokenAuthorization(text), "Discussion/negation cannot become spoken approval")
            }
            check(executed == 0 && spoken == 1, "Prompt once; wait for local authorization")
            check(b.isSpokenAuthorizationCandidate("yes proceed") && executed == 0,
                "A stable candidate may endpoint dictation but cannot authorize before the final transcript")
            check(b.receiveSpokenAuthorization("ROB, yes, proceed!"), "A clear pending spoken approval must work without a controller")
            check(executed == 1 && b.authorizesLeftArmTrial("One complete recycling task"), "Voice grants only the complete pending scope")
            check(!b.receiveSpokenAuthorization("yes proceed"), "Repeated voice cannot restart an executing operation")
            b.cancel(reason: "Spoken Stop fixture")
            check(stopped == 1 && !b.authorizesLeftArmTrial("One complete recycling task"), "Stop revokes spoken motion authority")
        }
        do {
            let b = broker()
            var clock = Date(), prompts: [String] = [], executions = 0
            b.now = { clock }; b.announceApproval = { prompts.append($0) }
            b.requestLeftWorkspaceTask(summary: "One unchanged complete task", execute: { _ in executions += 1 }, cancel: {}, completion: { _ in })
            clock.addTimeInterval(20); b.tick(); b.tick()
            clock.addTimeInterval(25); b.tick(); b.tick()
            check(prompts == ["Can I move my arms?", "Hey! Can I move my arms?", "Hey! Can I move my arms?"], "Bounded attention reminders repeat one pending operation")
            check(executions == 0 && !b.authorizesLeftArmTrial("One unchanged complete task"), "Reminders cannot grant motion")
            check(b.receiveSpokenAuthorization("yes proceed"), "One final microphone approval accepts the original scope after reminders")
            clock.addTimeInterval(20); b.tick()
            check(prompts.count == 3 && executions == 1, "Executing operations never ask again")
            b.cancel(reason: "Reminder fixture complete")
            let expired = broker(); clock = Date(); expired.now = { clock }
            expired.requestLeftGesture(summary: "Unheard request", execute: { _ in executions += 1 }, cancel: {}, completion: { _ in })
            clock.addTimeInterval(91); expired.tick()
            check(!expired.isPending && executions == 1, "Reminders do not extend the original approval deadline")
        }
        do {
            let b = broker()
            var prompts = 0, executions = 0, result: NSDictionary = [:]
            var time = Date(); b.now = { time }
            b.announceApproval = { _ in prompts += 1 }
            b.beginArmSession { result = $0 }
            check(b.receiveSpokenAuthorization("yes proceed"), "Authorize one rehearsal session by voice")
            check(b.armSessionActive && result["status"] as? String == "completed", "The session must survive its authorization callback")
            b.requestLeftWorkspaceTask(summary: "Search without finding the can", execute: { done in
                done(["status": "not_found", "arm_motion_sent": false])
            }, cancel: {}, completion: { _ in })
            check(b.armSessionActive && prompts == 1, "A missing object must not demand another authorization to retry search")
            b.requestLeftWorkspaceTask(summary: "Empty arm parked; opening depth still missing", execute: { done in
                done(["status":"not_localized","arm_motion_sent":true,"reach_sent":false,"empty_arm_parked":true])
            }, cancel: {}, completion: { _ in })
            check(b.armSessionActive && prompts == 1, "A completed empty-arm park followed by a perception miss must preserve the live session")
            for title in ["Present empty left arm", "Recycle empty can", "Lower empty left arm"] {
                b.requestLeftGesture(summary: title, execute: { done in
                    executions += 1
                    check(b.authorizesLeftArmTrial(title), "Each routine remains scoped to its own exact operation")
                    done(["status": "completed"])
                }, cancel: {}, completion: { _ in })
            }
            check(executions == 3 && prompts == 1 && b.armSessionActive, "Startup, task and lowering share one session authorization")
            time.addTimeInterval(901)
            check(!b.armSessionActive, "Rehearsal expires without a persisted grant")
            b.tick(); time = Date() // reset the wire clock after expiring the fixture grant
            b.requestLeftGesture(summary: "Another task", execute: { _ in executions += 1 }, cancel: {}, completion: { _ in })
            check(executions == 3 && prompts == 2, "Expired session cannot silently authorize another operation")
            check(b.receiveSpokenAuthorization("no"), "Spoken rejection cancels a pending request")
            check(!b.isPending && !b.armSessionActive, "Rejected request leaves no grant")
        }
        do {
            let b = broker()
            b.beginArmSession { _ in }
            check(b.receiveSpokenAuthorization("yes proceed"), "Authorize failure fixture session")
            b.requestLeftWorkspaceTask(summary: "Reached before failure", execute: { done in
                done(["status":"not_localized","arm_motion_sent":true,"reach_sent":true,"empty_arm_parked":true])
            }, cancel: {}, completion: { _ in })
            check(!b.armSessionActive,"A prior parked flag cannot preserve authorization after a failed reach")
        }
        do {
            let b = broker()
            var clock = Date(), stopped = 0
            b.now = { clock }
            b.requestLeftWorkspaceTask(summary: "Deliberate camera search and transfer", execute: { _ in }, cancel: { stopped += 1 }, completion: { _ in })
            check(b.receiveSpokenAuthorization("yes proceed"), "One voice approval covers the deliberate search task")
            clock.addTimeInterval(599)
            check(b.authorizesLeftArmTrial("Deliberate camera search and transfer"), "Camera settling must not exhaust the old short task window")
            clock.addTimeInterval(2); b.tick()
            check(stopped == 1 && !b.authorizesLeftArmTrial("Deliberate camera search and transfer"), "The complete search task remains bounded to ten minutes")
        }

        // A local imported receipt is a distinct lane, never a microphone or
        // controller impersonation. All texts here are synthetic fixture data.
        let localDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("local-recycling-approval-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        func localBroker() -> ROBControllerArmApproval {
            let b = broker()
            b.localRecyclingApprovalAuditDirectory = localDirectory.appendingPathComponent("audit-" + UUID().uuidString)
            return b
        }
        func hash(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        func receipt(_ b: ROBControllerArmApproval, mutate: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
            var value = b.localRecyclingReceiptTemplate! as! [String: Any]
            value["sourceMessage"] = "Synthetic explicit user instruction for this isolated four-can fixture."
            value["sourceMessageSHA256"] = hash(value["sourceMessage"] as! String)
            if (value["scope"] as! [String: Any])["permitsUnmeasuredVisualCalibrationTrial"] as? Bool == true {
                let additional = "Synthetic explicit instruction permitting an unmeasured visual calibration test, with feedback and Stop retained."
                value["additionalUserInstruction"] = additional
                value["additionalUserInstructionSHA256"] = hash(additional)
            }
            mutate(&value)
            let url = localDirectory.appendingPathComponent(UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
        func expectReceiptRejection(_ b: ROBControllerArmApproval, _ url: URL, _ detail: String) {
            do { try b.importLocalRecyclingSessionApproval(fromReceiptURL: url); check(false, detail) }
            catch { check(true, detail) }
        }
        do {
            let b = localBroker()
            var executed = 0, prompts = 0, stopped = 0, context: String? = "context-A"
            var done: ((NSDictionary) -> Void)?
            b.announceApproval = { _ in prompts += 1 }
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 4,
                summary: "Exact four-can job", contextIdentity: { context }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true, execute: { executed += 1; done = $0 },
                cancel: { stopped += 1 }, completion: { _ in })
            check(b.isPending && executed == 0 && prompts == 0, "Preparing a local job neither speaks nor grants")
            check(b.localRecyclingApprovalState == nil, "A prepared template is not an imported approval")
            check(!b.receiveSpokenAuthorization("yes proceed"), "A receipt-only request cannot be granted by microphone text")
            check(!b.authorizesRightArmTrial("Exact four-can job"), "A prepared local job cannot move")
            let url = try receipt(b)
            try b.importLocalRecyclingSessionApproval(fromReceiptURL: url)
            check(executed == 1 && prompts == 0 && b.authorizesRightArmTrial("Exact four-can job"), "Exact local receipt starts once without a spoken prompt")
            check(b.localRecyclingApprovalState?["state"] as? String == "executing" &&
                b.localRecyclingApprovalState?["sourceMessage"] == nil, "Sandbox state reports execution without exposing private source texts")
            check(!b.authorizesLeftArmTrial("Exact four-can job") && !b.authorizesRightArmTrial("Other job"), "Local receipt binds physical arm and immutable summary")
            check(b.authorizesLocalRecyclingVisualCalibrationTrial(summary: "Exact four-can job", arm: "right"), "Explicit visual-trial permission remains separately scoped")
            check(!b.authorizesLocalRecyclingVisualCalibrationTrial(summary: "Exact four-can job", arm: "left"), "Visual-trial permission cannot cross arms")
            check(b.activeLocalRecyclingApprovalEvidence?["registrationVerifiedByApproval"] as? Bool == false, "An approval never certifies registration")
            check(b.activeLocalRecyclingApprovalEvidence?["nominalEmptyCommissioningStepEnabled"] as? Bool == false &&
                !b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary: "Exact four-can job", arm: "right"),
                "An ordinary visual-trial receipt cannot enable the separate nominal commissioning step")
            check(b.activeLocalRecyclingApprovalEvidence?["oneDegreeEmptyCalibrationStepEnabled"] as? Bool == false &&
                !b.authorizesLocalRecyclingOneDegreeEmptyCalibrationStep(summary: "Exact four-can job", arm: "right"),
                "An ordinary visual-trial receipt cannot enable one-degree actuator calibration")
            expectReceiptRejection(b, url, "Executing receipt cannot import twice")
            let files = try FileManager.default.contentsOfDirectory(at: b.localRecyclingApprovalAuditDirectory, includingPropertiesForKeys: nil)
            check(files.count == 1, "A private replay tombstone is written before the first execution")
            context = nil; b.tick()
            check(stopped == 1 && !b.isPending && b.activeLocalRecyclingApprovalEvidence == nil, "Losing context revokes and requests hold")
            check(b.localRecyclingApprovalState == nil, "Revoked context cannot appear as an available local approval")
            done?(["status": "completed"])
            check(executed == 1, "Late completion cannot restore local authority")
        }
        do {
            let b = localBroker(); var executed = 0
            var done: ((NSDictionary) -> Void)?
            let summary = "One slow empty-right-arm outward commissioning step, then hold; zero transfers"
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 4,
                summary: summary, contextIdentity: { "nominal-step-true-context" }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true, nominalEmptyCommissioningStepEnabled: true,
                execute: { executed += 1; done = $0 }, cancel: {}, completion: { _ in })
            check(b.pendingLocalRecyclingApprovalScope?["nominalEmptyCommissioningStepEnabled"] as? Bool == true,
                "The exact one-step flag must be visible in the immutable prepared scope")
            check(!b.receiveSpokenAuthorization("yes proceed") && executed == 0,
                "Speech cannot enable or grant the one-step receipt-only experiment")
            let changed = try receipt(b) { value in
                var scope = value["scope"] as! [String: Any]
                scope["nominalEmptyCommissioningStepEnabled"] = false; value["scope"] = scope
            }
            expectReceiptRejection(b, changed, "An old/default-false receipt cannot grant the new commissioning option")
            let url = try receipt(b)
            try b.importLocalRecyclingSessionApproval(fromReceiptURL: url)
            check(executed == 1 && b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary: summary, arm: "right"),
                "An exact explicit private receipt grants only its dedicated one-step permission")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary: summary, arm: "left") &&
                !b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary: "A recycling grab", arm: "right"),
                "One-step permission cannot cross arms or a changed operation summary")
            check(b.activeLocalRecyclingApprovalEvidence?["nominalEmptyCommissioningStepEnabled"] as? Bool == true &&
                b.activeLocalRecyclingApprovalEvidence?["sourceMessage"] == nil,
                "Active evidence binds the option without exposing the private user text")
            done?(["status": "partial", "transfersCompleted": 0])
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary: summary, arm: "right") &&
                b.localRecyclingApprovalState == nil, "Finishing the one-step experiment cannot retain a reusable motion grant")
        }
        for (receiptOnly, visualTrial) in [(false, true), (true, false)] {
            let b = localBroker(); var executed = 0, rejected = false
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 4,
                summary: "Not a dedicated explicit commissioning scope", contextIdentity: { "context" }, receiptOnly: receiptOnly,
                permitsUnmeasuredVisualCalibrationTrial: visualTrial, nominalEmptyCommissioningStepEnabled: true,
                execute: { _ in executed += 1 }, cancel: {}, completion: { rejected = $0["status"] as? String == "rejected" })
            check(rejected && executed == 0 && !b.isPending,
                "The nominal option requires both the dedicated receipt-only lane and explicit visual trial scope")
        }
        do {
            let b=localBroker();var executed=0;var done:((NSDictionary)->Void)?
            let summary="ONE RIGHT J2 minus0.02rad over4seconds actuator calibration, then hold; contact unverified, ZERO transfers"
            b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,
                summary:summary,contextIdentity:{"one-degree-calibration-context"},receiptOnly:true,
                permitsUnmeasuredVisualCalibrationTrial:true,oneDegreeEmptyCalibrationStepEnabled:true,
                execute:{executed+=1;done=$0},cancel:{},completion:{_ in})
            check(b.pendingLocalRecyclingApprovalScope?["oneDegreeEmptyCalibrationStepEnabled"] as? Bool == true &&
                b.pendingLocalRecyclingApprovalScope?["nominalEmptyCommissioningStepEnabled"] as? Bool == false,
                "One-degree actuator calibration must have its own exact mutually exclusive scope")
            check(!b.receiveSpokenAuthorization("yes proceed") && executed==0,
                "Ordinary microphone input cannot enable or grant actuator calibration")
            let wrong=try receipt(b){value in
                var scope=value["scope"]as![String:Any];scope["oneDegreeEmptyCalibrationStepEnabled"]=false;value["scope"]=scope
            }
            expectReceiptRejection(b,wrong,"A prior ordinary receipt cannot enable the one-degree calibration experiment")
            try b.importLocalRecyclingSessionApproval(fromReceiptURL:receipt(b))
            check(executed==1 && b.authorizesLocalRecyclingOneDegreeEmptyCalibrationStep(summary:summary,arm:"right"),
                "Only the exact private one-degree receipt grants the dedicated calibration permission")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right") &&
                !b.authorizesLocalRecyclingOneDegreeEmptyCalibrationStep(summary:summary,arm:"left") &&
                !b.authorizesLocalRecyclingOneDegreeEmptyCalibrationStep(summary:"Ordinary can grab",arm:"right"),
                "Actuator calibration cannot grant nominal commissioning, another arm or another operation")
            check(b.activeLocalRecyclingApprovalEvidence?["oneDegreeEmptyCalibrationStepEnabled"]as?Bool==true &&
                b.activeLocalRecyclingApprovalEvidence?["sourceMessage"]==nil,
                "Calibration evidence must retain its flag without leaking the private user source")
            done?(["status":"partial_empty_calibration_step_held","batch_completed":0])
            check(!b.authorizesLocalRecyclingOneDegreeEmptyCalibrationStep(summary:summary,arm:"right") &&
                b.localRecyclingApprovalState==nil,"One completed calibration step consumes its grant without chaining")
        }
        for (side,receiptOnly,visual,nominal) in [("left",true,true,false),("right",false,true,false),
            ("right",true,false,false),("right",true,true,true)] {
            let b=localBroker();var executed=0,rejected=false
            b.requestRecyclingWorkspaceTask(command:side+"_recycle_cans",arm:side,canCount:4,
                summary:"Invalid actuator calibration lane",contextIdentity:{"context"},receiptOnly:receiptOnly,
                permitsUnmeasuredVisualCalibrationTrial:visual,nominalEmptyCommissioningStepEnabled:nominal,
                oneDegreeEmptyCalibrationStepEnabled:true,execute:{_ in executed+=1},cancel:{},
                completion:{rejected=$0["status"]as?String=="rejected"})
            check(rejected && executed==0 && !b.isPending,
                "Actuator calibration requires RIGHT, private receipt, explicit visual trial and no nominal flag")
        }
        for change in ["count", "arm", "command", "summary", "context", "treads", "torso", "gestures", "future", "expired", "too_long", "other_session", "source_hash", "missing_source", "extra_key", "additional_hash"] {
            let b = localBroker(); var executed = 0
            b.requestRecyclingWorkspaceTask(command: "left_recycle_cans", arm: "left", canCount: 4,
                summary: "Exact fixture scope", contextIdentity: { "context" }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true, execute: { _ in executed += 1 }, cancel: {}, completion: { _ in })
            let url = try receipt(b) { value in
                var scope = value["scope"] as! [String: Any]
                switch change {
                case "count": scope["canCount"] = 3
                case "arm": scope["arm"] = "right"
                case "command": scope["command"] = "left_wave"
                case "summary": scope["summary"] = "Changed"
                case "context": scope["contextIdentity"] = "other"
                case "treads": scope["treads"] = true
                case "torso": scope["torso"] = true
                case "gestures": scope["manualGestures"] = true
                case "future": value["issuedAtMilliseconds"] = Date().addingTimeInterval(60).timeIntervalSince1970 * 1000
                case "expired": value["expiresAtMilliseconds"] = Date().addingTimeInterval(-1).timeIntervalSince1970 * 1000
                case "too_long": value["expiresAtMilliseconds"] = (value["issuedAtMilliseconds"] as! Double) + 43_200_001
                case "other_session": value["appSessionID"] = UUID().uuidString
                case "source_hash": value["sourceMessageSHA256"] = String(repeating: "0", count: 64)
                case "missing_source": value["sourceMessage"] = ""
                case "extra_key": value["approve_anything"] = true
                case "additional_hash": value["additionalUserInstructionSHA256"] = String(repeating: "0", count: 64)
                default: break
                }
                value["scope"] = scope
            }
            expectReceiptRejection(b, url, "Receipt mutation must reject: " + change)
            check(executed == 0 && b.activeLocalRecyclingApprovalEvidence == nil, "Invalid receipt never grants: " + change)
            b.cancel(reason: "Fixture cleanup")
        }
        do {
            let b = localBroker(); var executed = 0
            b.requestRecyclingWorkspaceTask(command: "left_recycle_cans", arm: "left", canCount: 4,
                summary: "Private import", contextIdentity: { "context" }, receiptOnly: true,
                execute: { _ in executed += 1 }, cancel: {}, completion: { _ in })
            let url = try receipt(b)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            expectReceiptRejection(b, url, "World-readable receipt cannot import")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let link = localDirectory.appendingPathComponent("receipt-link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            expectReceiptRejection(b, link, "Receipt symlink cannot import")
            check(executed == 0, "File safety failure cannot dispatch")
            b.cancel(reason: "Fixture cleanup")
        }
        for outcome in ["perception", "explicit_perception", "explicit_veto", "unclassified_block", "motion_failure", "missing_jaw_proof", "complete", "stop", "timeout"] {
            let b = localBroker(); var clock = Date(), executed = 0, stopped = 0
            var done: ((NSDictionary) -> Void)?
            b.now = { clock }
            func request(_ summary: String = "Retry only same four-can job") {
                b.requestRecyclingWorkspaceTask(command: "left_recycle_cans", arm: "left", canCount: 4,
                    summary: summary, contextIdentity: { "context" }, receiptOnly: true,
                    execute: { executed += 1; done = $0 }, cancel: { stopped += 1 }, completion: { _ in })
            }
            request(); let url = try receipt(b); try b.importLocalRecyclingSessionApproval(fromReceiptURL: url)
            switch outcome {
            case "perception", "explicit_perception":
                done?(["status": outcome == "perception" ? "not_found" : "blocked", "perception_only_rejection": true,
                    "arm_motion_sent": false, "reach_sent": false, "jaw_command_sent": false])
                check(b.localRecyclingApprovalState?["state"] as? String == "available", "Perception-only result reports retained exact-job availability")
                request()
                check(executed == 2 && b.authorizesLeftArmTrial("Retry only same four-can job"), "Explicit perception-only rejection may retry the identical job")
                check(b.localRecyclingApprovalState?["state"] as? String == "executing", "Retained exact job returns to executing")
            case "unclassified_block": done?(["status": "blocked", "arm_motion_sent": false, "reach_sent": false, "jaw_command_sent": false])
            case "explicit_veto": done?(["status": "not_found", "perception_only_rejection": false,
                "arm_motion_sent": false, "reach_sent": false, "jaw_command_sent": false])
            case "motion_failure": done?(["status": "blocked", "arm_motion_sent": true, "reach_sent": true, "jaw_command_sent": false])
            case "missing_jaw_proof": done?(["status": "not_found", "arm_motion_sent": false, "reach_sent": false])
            case "complete": done?(["status": "completed"])
            case "stop": b.cancel(reason: "Stop fixture")
            case "timeout": clock.addTimeInterval(601); b.tick()
            default: break
            }
            if !["perception", "explicit_perception"].contains(outcome) {
                check(b.localRecyclingApprovalState == nil, "Terminal/unsafe result cannot report an available local approval")
                request()
                check(executed == 1 && !b.authorizesLeftArmTrial("Retry only same four-can job"), "Failure/completion/Stop/timeout cannot reuse the local grant: " + outcome)
                expectReceiptRejection(b, url, "Consumed receipt cannot be replayed: " + outcome)
            }
            if ["stop", "timeout"].contains(outcome) { check(stopped == 1, "Stop and task timeout hold once") }
            b.cancel(reason: "Fixture cleanup")
        }
        do {
            let b = localBroker(); var done: ((NSDictionary) -> Void)?, executed = 0
            func request(_ summary: String) {
                b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 4,
                    summary: summary, contextIdentity: { "context" }, receiptOnly: true,
                    execute: { executed += 1; done = $0 }, cancel: {}, completion: { _ in })
            }
            request("Original summary"); let url = try receipt(b); try b.importLocalRecyclingSessionApproval(fromReceiptURL: url)
            done?(["status": "not_found", "arm_motion_sent": false, "reach_sent": false, "jaw_command_sent": false])
            request("Changed summary")
            check(executed == 1 && !b.authorizesRightArmTrial("Changed summary"), "Perception retry cannot change immutable scope")
            expectReceiptRejection(b, url, "Old receipt cannot approve changed scope")
            b.cancel(reason: "Fixture cleanup")
        }
        do {
            let b = localBroker(); var clock = Date(), executed = 0
            b.now = { clock }
            b.requestRecyclingWorkspaceTask(command: "left_recycle_cans", arm: "left", canCount: 4,
                summary: "Wait is not approval", contextIdentity: { "context" }, receiptOnly: true,
                execute: { _ in executed += 1 }, cancel: {}, completion: { _ in })
            clock.addTimeInterval(43_199); b.tick()
            check(b.isPending && executed == 0, "Waiting never grants a prepared local request")
            clock.addTimeInterval(2); b.tick()
            check(!b.isPending && executed == 0, "Unimported request is bounded to twelve hours")
        }
        do {
            let b = localBroker(); var done: ((NSDictionary) -> Void)?, executed = 0
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 4,
                summary: "Crash replay fixture", contextIdentity: { "context" }, receiptOnly: true,
                execute: { executed += 1; done = $0 }, cancel: {}, completion: { _ in })
            let original = try receipt(b)
            try b.importLocalRecyclingSessionApproval(fromReceiptURL: original)
            done?(["status": "completed"])
            let restarted = localBroker()
            restarted.localRecyclingApprovalAuditDirectory = b.localRecyclingApprovalAuditDirectory
            restarted.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 4,
                summary: "Crash replay fixture", contextIdentity: { "context" }, receiptOnly: true,
                execute: { _ in executed += 1 }, cancel: {}, completion: { _ in })
            expectReceiptRejection(restarted, original, "A prior process receipt cannot survive a new app session")
            var edited = try JSONSerialization.jsonObject(with: Data(contentsOf: original)) as! [String: Any]
            edited["appSessionID"] = restarted.localRecyclingApprovalSessionID
            let sameID = localDirectory.appendingPathComponent("same-receipt-id.json")
            try JSONSerialization.data(withJSONObject: edited, options: [.sortedKeys]).write(to: sameID)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sameID.path)
            expectReceiptRejection(restarted, sameID, "Persistent import tombstone rejects a replay even after editing its app-session identifier")
            check(executed == 1, "Crash replay never dispatches")
            restarted.cancel(reason: "Fixture cleanup")
        }
        for (command, arm, count) in [("left_wave", "left", 4), ("left_recycle_cans", "left", 3), ("right_recycle_cans", "both", 4)] {
            let b = localBroker(); var rejected = false
            b.requestRecyclingWorkspaceTask(command: command, arm: arm, canCount: count,
                summary: "Invalid local scope", contextIdentity: { "context" }, receiptOnly: true,
                execute: { _ in check(false, "Invalid local scope executed") }, cancel: {},
                completion: { rejected = $0["status"] as? String == "rejected" })
            check(rejected && !b.isPending, "Local receipts cannot broaden to another count, gesture or unspecified arm")
        }
        func standingFile(_ b: ROBControllerArmApproval, mutate: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
            let source = "Synthetic actual user task: remove these four empty Coke cans into the orange bucket."
            let instruction = "Synthetic actual user instruction: continue this arms-only campaign and recover connections until I intervene."
            var value: [String: Any] = ["schemaVersion": 1, "kind": "local_user_standing_can_campaign_authorization",
                "campaignID": UUID().uuidString, "issuedAtMilliseconds": b.now().timeIntervalSince1970 * 1000,
                "source": "explicit_user_session_instruction", "sourceMessage": source, "sourceMessageSHA256": hash(source),
                "additionalUserInstruction": instruction, "additionalUserInstructionSHA256": hash(instruction),
                "scope": ["canCount": 4, "targetObject": "empty_coke_can", "destination": "orange_bucket", "arms": ["left", "right"],
                    "treads": false, "torso": false, "manualGestures": false, "permitsUnmeasuredVisualCalibrationTrial": true,
                    "automaticConnectionRecovery": true, "validUntil": "four_transfers_or_user_intervention"]]
            mutate(&value)
            let file = localDirectory.appendingPathComponent(UUID().uuidString + "-standing.json")
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-positive")
            let input=try standingFile(b);var executions=0,prompts=0,stops=0,context:String?="fresh-source-A"
            var done:((NSDictionary)->Void)?;b.announceApproval={_ in prompts+=1}
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:input)
            check(b.standingLocalCanCampaignActive && !b.isPending && executions==0,"Standing import is passive, not startup motion")
            func run(_ broker:ROBControllerArmApproval,_ title:String){
                broker.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,
                    summary:title,contextIdentity:{context},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                    execute:{executions+=1;done=$0},cancel:{stops+=1},completion:{_ in})
            }
            run(b,"First fresh ordinary can plan")
            let firstID=b.activeLocalRecyclingApprovalEvidence?["receiptID"] as?String
            check(executions==1 && prompts==0 && firstID != nil && b.authorizesRightArmTrial("First fresh ordinary can plan"),
                "Standing campaign binds a fresh exact ordinary can plan without another voice/file approval")
            check(b.activeLocalRecyclingApprovalEvidence?["standingCampaignID"] != nil &&
                b.activeLocalRecyclingApprovalEvidence?["sourceMessage"]==nil,"Fresh evidence binds standing source without leaking private instructions")
            done?(["status":"partial_grasp_held","transfer_completed":false,"batch_completed":4])
            check((b.standingLocalCanCampaignState?["completedTransfers"]as?NSNumber)?.intValue==0,
                "A grasp/hold or unverified count never consumes four transfers")
            let restarted=localBroker();restarted.standingCanCampaignDirectory=b.standingCanCampaignDirectory
            check(restarted.standingLocalCanCampaignActive && !restarted.isPending && executions==1,
                "Same campaign survives relaunch without resuming any old waypoint")
            context="fresh-source-B";run(restarted,"New app fresh normal plan")
            check(executions==2 && restarted.activeLocalRecyclingApprovalEvidence?["receiptID"]as?String != firstID,
                "Relaunch derives a new exact context and job identity")
            context=nil;restarted.tick()
            check(stops==1 && !restarted.isPending && restarted.standingLocalCanCampaignActive,
                "Lost connection/context holds the job but preserves standing authorization for revalidation")
            context="fresh-source-C"
            var restarts=0
            check(restarted.scheduleStandingLocalCanCampaignRecovery(reason:.transportLost,restart:{restarts+=1;run(restarted,"Fresh plan after recovery")}),
                "Typed transport recovery schedules a bounded fresh request")
            RunLoop.current.run(until:Date().addingTimeInterval(1.15))
            check(restarts==1 && executions==3 && restarted.authorizesRightArmTrial("Fresh plan after recovery"),
                "Automatic recovery invokes a new fresh plan, not the previous job/waypoint")
            done?(["status":"blocked","transfer_completed":false,"requires_intervention":true,"detail":"Real obstacle"])
            check(!restarted.scheduleStandingLocalCanCampaignRecovery(reason:.feedbackLost,restart:{check(false,"Collision auto retried")}),
                "A real obstacle/intervention result forbids automatic retry")
            let stateURL=restarted.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            let oldState=try Data(contentsOf:stateURL)
            restarted.cancel(reason:"User Stop: intervene now")
            check(!restarted.standingLocalCanCampaignActive && !restarted.scheduleStandingLocalCanCampaignRecovery(reason:.transportLost,restart:{}),
                "Stop revokes standing authority and queued retries")
            try oldState.write(to:stateURL)
            let afterStop=localBroker();afterStop.standingCanCampaignDirectory=restarted.standingCanCampaignDirectory
            check(!afterStop.standingLocalCanCampaignActive,"A restored old state cannot replay past the durable Stop tombstone")
            do{try afterStop.importLocalCanCampaignAuthorization(fromReceiptURL:input);check(false,"Stopped campaign reimported")}catch{check(true,"Stopped campaign cannot reimport")}
        }
        for change in ["scope","source","instruction","sourceType"] {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-invalid-"+change)
            let input=try standingFile(b){v in
                if change=="scope" {var scope=v["scope"]as![String:Any];scope["treads"]=true;v["scope"]=scope}
                if change=="source" {v["sourceMessageSHA256"]="bad"}
                if change=="instruction" {v["additionalUserInstruction"]="";v["additionalUserInstructionSHA256"]=hash("")}
                if change=="sourceType" {v["source"]="model_output"}
            }
            do{try b.importLocalCanCampaignAuthorization(fromReceiptURL:input);check(false,"Invalid standing authorization imported")}catch{check(!b.standingLocalCanCampaignActive,"Standing scope/source failure cannot grant")}
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-consumed")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b))
            var done:((NSDictionary)->Void)?
            b.requestRecyclingWorkspaceTask(command:"left_recycle_cans",arm:"left",canCount:4,summary:"Four native transfers",
                contextIdentity:{"fresh"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                execute:{done=$0},cancel:{},completion:{_ in})
            done?(["status":"accepted_unverified","transfer_completed":true,"batch_completed":4,"placement_verified":false])
            check(!b.standingLocalCanCampaignActive && b.standingLocalCanCampaignState?["state"]as?String=="consumed",
                "Four explicitly completed transfers consume the campaign")
            check((b.standingLocalCanCampaignState?["completedTransfers"]as?NSNumber)?.intValue==4 &&
                (b.standingLocalCanCampaignState?["verifiedLandings"]as?NSNumber)?.intValue==0,
                "Commanded/native transfer completion never claims camera-verified bucket landing")
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-calibration-excluded")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b));var executions=0
            b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:"Separate old actuator mode",
                contextIdentity:{"fresh"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                oneDegreeEmptyCalibrationStepEnabled:true,execute:{_ in executions+=1},cancel:{},completion:{_ in})
            check(executions==0 && !b.receiveSpokenAuthorization("yes proceed"),"Standing can authorization never grants old calibration modes or microphone strings")
            b.cancel(reason:"Fixture cleanup")
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-queued-stop")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b));var restarted=0
            check(b.scheduleStandingLocalCanCampaignRecovery(reason:.feedbackLost,restart:{restarted+=1}),"Fresh recovery can be queued")
            b.cancel(reason:"Explicit user intervention before retry")
            RunLoop.current.run(until:Date().addingTimeInterval(1.10))
            check(restarted==0 && !b.standingLocalCanCampaignActive,"Stop cancels the queued retry callback as well as its durable authorization")
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-bounded-retries")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b))
            for _ in 0..<3 {check(b.scheduleStandingLocalCanCampaignRecovery(reason:.transportLost,restart:{}),"A bounded recovery attempt is available")}
            check(!b.scheduleStandingLocalCanCampaignRecovery(reason:.transportLost,restart:{}) &&
                b.standingLocalCanCampaignState?["state"]as?String=="waiting_for_intervention",
                "Three attempts exhaust automatic recovery without silently retrying forever")
            b.cancel(reason:"Fixture cleanup")
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-stop-after-read-failure")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b))
            let stateURL=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            let oldState=try Data(contentsOf:stateURL)
            let id=(try JSONSerialization.jsonObject(with:oldState)as![String:Any])["campaignID"]as!String
            let authURL=b.standingCanCampaignDirectory.appendingPathComponent("authorization-"+id+".json")
            let original=try Data(contentsOf:authURL)
            try Data("corrupt source evidence".utf8).write(to:authURL)
            check(!b.standingLocalCanCampaignActive,"Corrupt archived source evidence closes the loader")
            b.cancel(reason:"User Stop while evidence is unavailable")
            try original.write(to:authURL);try oldState.write(to:stateURL)
            let restarted=localBroker();restarted.standingCanCampaignDirectory=b.standingCanCampaignDirectory
            check(!restarted.standingLocalCanCampaignActive,"Stop remains durable even if source validation failed before revocation")
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-possible-payload")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b));var executions=0
            var done:((NSDictionary)->Void)?
            func run(_ broker:ROBControllerArmApproval){
                broker.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,
                    summary:"Fresh EMPTY can attempt",contextIdentity:{"current"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                    execute:{executions+=1;done=$0},cancel:{},completion:{_ in})
            }
            run(b);try b.markLocalCanCampaignPossiblePayloadHeld()
            check(b.standingLocalCanCampaignState?["possiblePayloadHeld"]as?Bool==true,"Payload uncertainty is durable BEFORE actual close")
            done?(["status":"partial_held","possible_payload_held":true,"grasp_attempted":true,"transfer_completed":false])
            run(b)
            check(executions==1 && !b.isPending && b.standingLocalCanCampaignActive,
                "A held partial grasp blocks a new EMPTY job without revoking standing authorization")
            let restarted=localBroker();restarted.standingCanCampaignDirectory=b.standingCanCampaignDirectory;run(restarted)
            check(executions==1 && !restarted.isPending && restarted.standingLocalCanCampaignState?["possiblePayloadHeld"]as?Bool==true,
                "A new app session cannot reset possible payload into an empty grasp")
            check(!restarted.scheduleStandingLocalCanCampaignRecovery(reason:.transportLost,restart:{check(false,"Possible payload auto retried")}),
                "Connection recovery cannot automatically regrasp a possible payload")
            restarted.cancel(reason:"Fixture Stop")
            check(restarted.standingCanCampaignMayHoldPayload,"Stop revokes permission without declaring a held object empty")
            try restarted.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(restarted))
            check(restarted.standingLocalCanCampaignActive && restarted.standingCanCampaignMayHoldPayload,
                "Importing a different campaign cannot reset terminal held-payload state")
            run(restarted)
            check(executions==1 && !restarted.isPending,"A new authorization is not object-clear evidence")
            restarted.cancel(reason:"Fixture Stop")
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-supported-release")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b));var executions=0;var done:((NSDictionary)->Void)?
            func run(){b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:"EMPTY identification then can",
                contextIdentity:{"current"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                execute:{executions+=1;done=$0},cancel:{},completion:{_ in})}
            run();try b.markLocalCanCampaignPossiblePayloadHeld();try b.recordLocalCanCampaignSupportedRelease()
            done?(["status":"blocked","possible_payload_held":false,"transfer_completed":false])
            check(b.standingLocalCanCampaignState?["possiblePayloadHeld"]as?Bool==false,
                "Observed EMPTY identification opening clears only its own transient hold uncertainty")
            run();try b.markLocalCanCampaignPossiblePayloadHeld()
            done?(["status":"accepted_unverified","possible_payload_held":true,"transfer_completed":true,"batch_completed":1,"placement_verified":false])
            check(b.standingLocalCanCampaignState?["possiblePayloadHeld"]as?Bool==false &&
                (b.standingLocalCanCampaignState?["completedTransfers"]as?NSNumber)?.intValue==1,
                "Typed completed transfer/release evidence can clear a possible payload, without claiming a verified landing")
            run();check(executions==3,"A supported release allows a genuinely new empty attempt under the same authorization")
            b.cancel(reason:"Fixture Stop")
        }
        for legacy in [true,false] {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-unresolved-"+String(legacy))
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b))
            let stateURL=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            if legacy {
                var state=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL))as![String:Any]
                state.removeValue(forKey:"possiblePayloadHeld")
                try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]).write(to:stateURL)
            } else {
                b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:"Unfinished old process",
                    contextIdentity:{"old"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                    execute:{_ in},cancel:{},completion:{_ in})
            }
            let restarted=localBroker();restarted.standingCanCampaignDirectory=b.standingCanCampaignDirectory;var executed=false
            restarted.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:"New EMPTY request",
                contextIdentity:{"new"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                execute:{_ in executed=true},cancel:{},completion:{_ in})
            check(!executed && restarted.standingLocalCanCampaignActive,
                "Legacy unknown payload or unresolved prior app job cannot silently become EMPTY")
            check(restarted.standingCanCampaignMayHoldPayload,"Startup guard exposes legacy/unresolved object uncertainty")
            restarted.cancel(reason:"Fixture Stop")
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-startup-read-only")
            check(!b.standingCanCampaignMayHoldPayload,"Never-used campaign storage does not invent a payload")
            try FileManager.default.createDirectory(at:b.standingCanCampaignDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let state=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            try Data("unreadable campaign state".utf8).write(to:state)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:state.path)
            check(b.standingCanCampaignMayHoldPayload,"Unreadable existing state blocks automatic startup jaw calibration")
            try FileManager.default.removeItem(at:state)
            let orphan=b.standingCanCampaignDirectory.appendingPathComponent("authorization-orphan.json")
            try Data("orphaned authorization after interrupted persistence".utf8).write(to:orphan)
            check(b.standingCanCampaignMayHoldPayload,"Missing state with prior campaign history cannot silently imply EMPTY")
        }
        print("Controller/spoken arm approval and session reuse: \(checks) checks passed; no hardware access")
    }
}
