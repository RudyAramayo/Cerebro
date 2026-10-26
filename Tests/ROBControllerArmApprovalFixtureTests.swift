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
            check(b.pendingLocalRecyclingApprovalScope?["nominalModelAssumedSelfEnabled"]==nil,"OFF scope serialization must omit the new optional flag")
            check(b.pendingLocalRecyclingApprovalScope?["sourcePixelSelfReviewSHA256"]==nil,"OFF scope serialization must omit optional source-pixel evidence")
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
        do {
            let b=localBroker();var executed=0
            let summary="ONE model-assumed EMPTY RIGHT J2 nominal step with14keyframes; not observed self"
            b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:summary,
                contextIdentity:{"inert-model-assumed-context"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                nominalEmptyCommissioningStepEnabled:true,nominalModelAssumedSelfEnabled:true,
                execute:{_ in executed+=1},cancel:{},completion:{_ in})
            check(b.pendingLocalRecyclingApprovalScope?["nominalModelAssumedSelfEnabled"]as?Bool==true,"New model hypothesis flag must be explicit in immutable receipt")
            let changed=try receipt(b){value in var scope=value["scope"]as![String:Any];scope.removeValue(forKey:"nominalModelAssumedSelfEnabled");value["scope"]=scope}
            expectReceiptRejection(b,changed,"Legacy nominal receipt cannot authorize model-assumed source-group admission")
            try b.importLocalRecyclingSessionApproval(fromReceiptURL:receipt(b))
            check(executed==1 && b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right",modelAssumedSelfEnabled:true),"Exact native model-assumed flag admits only its dedicated experiment")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right"),"New assumption permission must not alias legacy nominal OFF binding")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"left",modelAssumedSelfEnabled:true),"Model assumption cannot cross physical side")
            b.cancel(reason:"fixture Stop")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right",modelAssumedSelfEnabled:true),"Stop revokes model-assumed commissioning")
        }
        for (side,nominal,oneDegree) in [("left",true,false),("right",false,false),("right",true,true)] {
            let b=localBroker();var rejected=false
            b.requestRecyclingWorkspaceTask(command:side+"_recycle_cans",arm:side,canCount:4,summary:"inert invalid model assumption",
                contextIdentity:{"inert"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                nominalEmptyCommissioningStepEnabled:nominal,nominalModelAssumedSelfEnabled:true,oneDegreeEmptyCalibrationStepEnabled:oneDegree,
                execute:{_ in},cancel:{},completion:{rejected=$0["status"]as?String=="rejected"})
            check(rejected && b.pendingLocalRecyclingApprovalScope==nil,"Model assumption requires RIGHT+nominal and excludes other calibration modes")
        }
        do {
            let b=localBroker();var executed=0,rejected=false
            b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:"DEBUG open-jaw approach then hold before close",
                contextIdentity:{"inert-approach-context"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                approachCanThenHoldEnabled:true,execute:{_ in executed+=1},cancel:{},completion:{rejected=$0["status"]as?String=="rejected"})
            #if DEBUG
            check(b.pendingLocalRecyclingApprovalScope?["approachCanThenHoldEnabled"]as?Bool==true,"Approach hold must be explicit immutable receipt scope")
            let wrong=try receipt(b){value in var scope=value["scope"]as![String:Any];scope.removeValue(forKey:"approachCanThenHoldEnabled");value["scope"]=scope}
            expectReceiptRejection(b,wrong,"Ordinary receipt cannot authorize approach-only scope")
            try b.importLocalRecyclingSessionApproval(fromReceiptURL:receipt(b))
            check(executed==1 && b.activeLocalRecyclingApprovalEvidence?["approachCanThenHoldEnabled"]as?Bool==true,"Exact approach receipt starts once and preserves scope")
            b.cancel(reason:"fixture Stop")
            #else
            check(rejected && executed==0 && b.pendingLocalRecyclingApprovalScope==nil,"Approach-only mode is DEBUG-only")
            #endif
        }
        do {
            let b=localBroker();var executed=0,rejected=false
            let summary="DEBUG LLM reviewed source pixels freshly matched; ONE EMPTY J2 step only"
            let evidence=String(repeating:"a",count:64)
            b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:summary,
                contextIdentity:{"inert-current-pixel-context"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                nominalEmptyCommissioningStepEnabled:true,sourcePixelSelfReviewSHA256:evidence,
                execute:{_ in executed+=1},cancel:{},completion:{rejected=$0["status"]as?String=="rejected"})
            #if DEBUG
            check(!rejected && executed==0,"Pixel evidence requests a new receipt, never starts motion")
            check(b.pendingLocalRecyclingApprovalScope?["sourcePixelSelfReviewSHA256"]as?String==evidence,"Current native pixel view hash must be visible in exact scope")
            let changed=try receipt(b){value in var scope=value["scope"]as![String:Any];scope.removeValue(forKey:"sourcePixelSelfReviewSHA256");value["scope"]=scope}
            expectReceiptRejection(b,changed,"Historical/default nominal receipt cannot grant reviewed source pixels")
            try b.importLocalRecyclingSessionApproval(fromReceiptURL:receipt(b))
            check(executed==1 && b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right",sourcePixelSelfReviewSHA256:evidence),"Exact fresh private receipt binds current native pixel evidence")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right"),"Pixel assumption cannot alias OFF nominal grant")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right",sourcePixelSelfReviewSHA256:String(repeating:"b",count:64)),"Changed pixel evidence requires new receipt")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right",modelAssumedSelfEnabled:true,sourcePixelSelfReviewSHA256:evidence),"Pixel evidence cannot enable MODEL hull fallback")
            b.cancel(reason:"fixture Stop")
            check(!b.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:"right",sourcePixelSelfReviewSHA256:evidence),"Stop revokes pixel commissioning receipt")
            #else
            check(rejected && executed==0 && b.pendingLocalRecyclingApprovalScope==nil,"Source-pixel commissioning must reject in nonDEBUG builds")
            #endif
        }
        #if DEBUG
        for (side,nominal,modelAssumed,receiptOnly,hash) in [("left",true,false,true,String(repeating:"a",count:64)),
            ("right",false,false,true,String(repeating:"a",count:64)),("right",true,true,true,String(repeating:"a",count:64)),
            ("right",true,false,false,String(repeating:"a",count:64)),("right",true,false,true,"bad")] {
            let b=localBroker();var rejected=false
            b.requestRecyclingWorkspaceTask(command:side+"_recycle_cans",arm:side,canCount:4,summary:"inert invalid source-pixel scope",contextIdentity:{"inert"},
                receiptOnly:receiptOnly,permitsUnmeasuredVisualCalibrationTrial:true,nominalEmptyCommissioningStepEnabled:nominal,
                nominalModelAssumedSelfEnabled:modelAssumed,sourcePixelSelfReviewSHA256:hash,execute:{_ in},cancel:{},completion:{rejected=$0["status"]as?String=="rejected"})
            check(rejected && b.pendingLocalRecyclingApprovalScope==nil,"Pixel commissioning requires RIGHT/nominal/private/validhash and NO MODEL fallback")
        }
        #endif
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
        for (command, arm, count) in [("left_wave", "left", 4), ("left_recycle_cans", "left", 0), ("left_recycle_cans", "left", 9), ("right_recycle_cans", "both", 4)] {
            let b = localBroker(); var rejected = false
            b.requestRecyclingWorkspaceTask(command: command, arm: arm, canCount: count,
                summary: "Invalid local scope", contextIdentity: { "context" }, receiptOnly: true,
                execute: { _ in check(false, "Invalid local scope executed") }, cancel: {},
                completion: { rejected = $0["status"] as? String == "rejected" })
            check(rejected && !b.isPending, "Local receipts reject unbounded counts, another gesture or an unspecified arm")
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
        for approach in [false,true] {
            let b=localBroker();var rejected=false
            b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:"Inert UNKNOWN advisory without standing source",
                contextIdentity:{"inert"},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                approachCanThenHoldEnabled:approach,approachUnknownAdvisoryEnabled:true,
                execute:{_ in check(false,"Missing standing UNKNOWN scope executed")},cancel:{},completion:{rejected=$0["status"]as?String=="rejected"})
            check(rejected && !b.isPending,"UNKNOWN advisory needs both approach-only and standing typed source")
        }
        do {
            let b=localBroker();b.standingCanCampaignDirectory=localDirectory.appendingPathComponent("standing-unknown-approach")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b))
            var executed=0,rejected=false,context="unknown-approach-A"
            let summary="DEBUG EMPTY open-jaw approach; unknown recorded advisory, occupied/self/person/Stop strict"
            b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,summary:summary,
                contextIdentity:{context},receiptOnly:true,permitsUnmeasuredVisualCalibrationTrial:true,
                approachCanThenHoldEnabled:true,approachUnknownAdvisoryEnabled:true,
                execute:{_ in executed+=1},cancel:{},completion:{rejected=$0["status"]as?String=="rejected"})
            #if DEBUG
            check(executed==1 && b.activeLocalRecyclingApprovalEvidence?["approachUnknownAdvisoryEnabled"]as?Bool==true,
                "Exact standing DEBUG subset carries immutable UNKNOWN advisory evidence")
            check(b.activeLocalRecyclingApprovalEvidence?["standingCampaignID"] != nil,"UNKNOWN subset retains original standing lineage")
            check(b.authorizesRightArmTrial(summary),"Fresh exact open-jaw UNKNOWN subset authorizes existing route gates")
            context="unknown-approach-B"
            check(!b.authorizesRightArmTrial(summary),"Changed UNKNOWN context invalidates the frozen job")
            #else
            check(rejected && executed==0,"UNKNOWN approach subset must remain DEBUG-only")
            #endif
            b.cancel(reason:"fixture Stop")
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
            check(b.activeLocalRecyclingApprovalEvidence?["approachUnknownAdvisoryEnabled"]==nil,"OFF remains absent from legacy scope serialization")
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
        // Schema2 has an explicit bounded target; legacy schema1 remains four.
        func boundedStandingFile(_ b: ROBControllerArmApproval, count: Int) throws -> URL {
            try standingFile(b) { value in
                value["schemaVersion"] = 2
                var scope = value["scope"] as! [String: Any]
                scope["canCount"] = count; scope["validUntil"] = "target_transfers_or_user_intervention"
                value["scope"] = scope
            }
        }
        for count in [1, 5, 8] {
            let b = localBroker(); b.standingCanCampaignDirectory = localDirectory.appendingPathComponent("bounded-standing-" + String(count))
            try b.importLocalCanCampaignAuthorization(fromReceiptURL: boundedStandingFile(b, count: count))
            var executed = 0; var done: ((NSDictionary) -> Void)?
            check((b.standingLocalCanCampaignState?["targetCanCount"] as? NSNumber)?.intValue == count &&
                (b.standingLocalCanCampaignState?["remainingTransfers"] as? NSNumber)?.intValue == count,
                "Schema2 imports the exact bounded campaign target")
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: count,
                summary: "Exact bounded can job", contextIdentity: { "fresh" }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true, execute: { executed += 1; done = $0 }, cancel: {}, completion: { _ in })
            check(executed == 1 && (b.activeLocalRecyclingApprovalEvidence?["canCount"] as? NSNumber)?.intValue == count,
                "Fresh derived receipt binds the exact target, not a hardcoded four")
            done?(["status": "accepted_unverified", "transfer_completed": true, "batch_completed": count])
            check(!b.standingLocalCanCampaignActive && (b.standingLocalCanCampaignState?["completedTransfers"] as? NSNumber)?.intValue == count,
                "Only the exact bounded target consumes the campaign")
            check(!b.receiveSpokenCanCampaignRestart("proceed with protections", targetCanCount: count),
                "A consumed campaign is not a stopped intent to reopen")
        }
        for count in [0, 9] {
            let b = localBroker()
            do { try b.importLocalCanCampaignAuthorization(fromReceiptURL: boundedStandingFile(b, count: count)); check(false, "Unbounded standing count imported") }
            catch { check(!b.standingLocalCanCampaignActive, "Invalid standing count grants nothing") }
        }
        do {
            let b = localBroker(); try b.importLocalCanCampaignAuthorization(fromReceiptURL: standingFile(b))
            let stateURL = b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            state["schemaVersion"] = 1; state.removeValue(forKey: "targetCanCount"); state.removeValue(forKey: "authorizationSource")
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL)
            check((b.standingLocalCanCampaignState?["targetCanCount"] as? NSNumber)?.intValue == 4,
                "Legacy state with no target field defaults to its original four-can authorization")
            b.cancel(reason: "Fixture cleanup")
        }
        do {
            let b = localBroker(); try b.importLocalCanCampaignAuthorization(fromReceiptURL: boundedStandingFile(b, count: 5))
            var executed = 0, outcome: NSDictionary = [:]
            b.requestRecyclingWorkspaceTask(command: "left_recycle_cans", arm: "left", canCount: 4,
                summary: "Mismatched standing count", contextIdentity: { "fresh" }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true, execute: { _ in executed += 1 }, cancel: {}, completion: { outcome = $0 })
            check(executed == 0 && !b.isPending && outcome["status"] as? String == "blocked" && b.standingLocalCanCampaignActive &&
                (b.standingLocalCanCampaignState?["targetCanCount"] as? NSNumber)?.intValue == 5,
                "A standing grant cannot silently authorize a differently counted job")
            b.cancel(reason: "Fixture cleanup")
        }
        do {
            let b = localBroker(); b.standingCanCampaignDirectory = localDirectory.appendingPathComponent("spoken-restart-positive")
            try b.importLocalCanCampaignAuthorization(fromReceiptURL: boundedStandingFile(b, count: 5))
            var executed = 0, cancelled = 0
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 5,
                summary: "Five-can initial job", contextIdentity: { "old-context" }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true, execute: { _ in executed += 1 }, cancel: { cancelled += 1 }, completion: { _ in })
            try b.recordLocalCanCampaignTransferProgress(2, bucketLandingVerified: true)
            let oldID = b.standingLocalCanCampaignState?["campaignID"] as! String
            b.cancel(reason: "Operator Stop after two transfers")
            let terminalURL = b.standingCanCampaignDirectory.appendingPathComponent("terminal-" + oldID + ".json")
            let authorizationURL = b.standingCanCampaignDirectory.appendingPathComponent("authorization-" + oldID + ".json")
            let oldTerminal = try Data(contentsOf: terminalURL), oldAuthorization = try Data(contentsOf: authorizationURL)
            check(b.spokenCanCampaignRestartTargetCanCount == 3 && !b.isPending && cancelled == 1,
                "Stopped intent retains only remaining transfers, never an old execution")
            for text in ["proceed with", "say proceed with protections", "proceed with protections but don't move", "no proceed with protections", "\"proceed with protections\""] {
                check(!b.isSpokenCanCampaignRestartCandidate(text) && !b.receiveSpokenCanCampaignRestart(text, targetCanCount: 3),
                    "Incomplete, quoted, negative or instructional speech cannot restart")
            }
            check(b.isSpokenCanCampaignRestartCandidate("ROB, proceed with protections!") && !b.standingLocalCanCampaignActive && executed == 1,
                "Candidate/partial endpointing alone grants nothing")
            check(!b.receiveSpokenAuthorization("proceed with protections"), "Ordinary spoken-approval API cannot restart a revoked local grant")
            for wrong in [0, 5, 9] {
                check(!b.receiveSpokenCanCampaignRestart("proceed with protections", targetCanCount: wrong) &&
                    b.standingLocalCanCampaignState?["campaignID"] as? String == oldID,
                    "Restart cannot broaden or replace the inherited remaining count")
            }
            check(b.receiveSpokenCanCampaignRestart("ROB, proceed with protections!", targetCanCount: 3),
                "Dedicated final-mic entry records a new protected restart authorization")
            let newID = b.standingLocalCanCampaignState?["campaignID"] as! String
            let newState = try JSONSerialization.jsonObject(with: Data(contentsOf: b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json"))) as! [String: Any]
            let newAuthorization = try JSONSerialization.jsonObject(with: Data(contentsOf: b.standingCanCampaignDirectory.appendingPathComponent("authorization-" + newID + ".json"))) as! [String: Any]
            let restart = newAuthorization["restart"] as! [String: Any]
            check(newID != oldID && executed == 1 && !b.isPending &&
                (b.standingLocalCanCampaignState?["targetCanCount"] as? NSNumber)?.intValue == 3 &&
                (b.standingLocalCanCampaignState?["completedTransfers"] as? NSNumber)?.intValue == 0 &&
                newState["lastJobID"] == nil && (newState["creditedJobCounts"] as? [String: Int])?.isEmpty == true,
                "Restart creates a fresh remaining-only campaign, never a saved job/waypoint")
            check(newAuthorization["source"] as? String == "final_clean_local_microphone" &&
                newAuthorization["sourceMessage"] as? String == "ROB, proceed with protections!" &&
                restart["previousCampaignID"] as? String == oldID &&
                (restart["previousCompletedTransfers"] as? NSNumber)?.intValue == 2 &&
                restart["previousTerminalSHA256"] as? String == SHA256.hash(data: oldTerminal).map { String(format: "%02x", $0) }.joined(),
                "New private provenance references the exact old terminal and truthful local microphone text")
            let unchangedTerminal = try Data(contentsOf: terminalURL), unchangedAuthorization = try Data(contentsOf: authorizationURL)
            check(unchangedTerminal == oldTerminal && unchangedAuthorization == oldAuthorization,
                "Restart never rewrites the old revoked terminal or source authorization")
            check(!b.receiveSpokenCanCampaignRestart("proceed with protections", targetCanCount: 3) &&
                b.standingLocalCanCampaignState?["campaignID"] as? String == newID && executed == 1,
                "Duplicate final callbacks cannot replace an already-active campaign or execute twice")
            let restarted = localBroker(); restarted.standingCanCampaignDirectory = b.standingCanCampaignDirectory
            check(restarted.standingLocalCanCampaignActive && !restarted.isPending,
                "New spoken campaign reloads as authority only, with no implicit execution")
            b.cancel(reason: "Stop during acknowledgement/preparation")
            do { try restarted.importLocalCanCampaignAuthorization(fromReceiptURL: b.standingCanCampaignDirectory.appendingPathComponent("authorization-" + newID + ".json")); check(false, "Microphone source imported as a written receipt") }
            catch { check(true, "File import cannot impersonate a final microphone event") }
            check(!b.standingLocalCanCampaignActive && !b.isPending && executed == 1,
                "Stop before the fresh-run hook revokes new authority without motion")
        }
        do {
            let b = localBroker()
            check(b.isSpokenCanCampaignRestartCandidate("proceed with protections") && b.spokenCanCampaignRestartTargetCanCount == 0 &&
                !b.receiveSpokenCanCampaignRestart("proceed with protections", targetCanCount: 5) && !b.standingLocalCanCampaignActive,
                "Unknown restart phrase is acknowledged as unavailable and creates no grant")
            check(b.spokenCanCampaignRestartStatus.contains("No stopped can task"), "Unavailable restart has an explicit native no-motion explanation")
        }
        do {
            let b = localBroker(); try b.importLocalCanCampaignAuthorization(fromReceiptURL: boundedStandingFile(b, count: 5))
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 5,
                summary: "Potential payload", contextIdentity: { "old" }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true, execute: { _ in }, cancel: {}, completion: { _ in })
            try b.markLocalCanCampaignPossiblePayloadHeld(); b.cancel(reason: "Stop with uncertain possession")
            check(b.receiveSpokenCanCampaignRestart("proceed with protections", targetCanCount: 5) && b.standingCanCampaignMayHoldPayload,
                "New authorization cannot reset possible held payload into EMPTY")
            var executed = false
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 5,
                summary: "Fresh empty job", contextIdentity: { "new" }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true, execute: { _ in executed = true }, cancel: {}, completion: { _ in })
            check(!executed && !b.isPending && b.standingLocalCanCampaignActive &&
                b.spokenCanCampaignRestartStatus.contains("Possible payload"),
                "Protected restart visibly retains object-state veto on a fresh empty grasp")
            b.cancel(reason: "Fixture cleanup")
        }

        // These exact words are synthetic object-state fixture input, not a
        // microphone callback or another arm-motion approval.
        func uncertainObjectStateBroker(_ label:String)throws->ROBControllerArmApproval {
            let old=localBroker();old.standingCanCampaignDirectory=localDirectory.appendingPathComponent("empty-observation-"+label)
            try old.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(old))
            old.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,
                summary:"Synthetic old job with uncertain contents",contextIdentity:{"old-job-context"},receiptOnly:true,
                permitsUnmeasuredVisualCalibrationTrial:true,execute:{_ in},cancel:{},completion:{_ in})
            try old.recordLocalCanCampaignTransferProgress(1,bucketLandingVerified:true)
            try old.markLocalCanCampaignPossiblePayloadHeld()
            let stateURL=old.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            var value=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL))as![String:Any]
            value["recoveryAttempts"]=2
            // Reproduce the crash guard's old-executing OR even when its
            // explicit payload flag was still false before the interruption.
            if label=="positive" {value["possiblePayloadHeld"]=false}
            try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:stateURL)
            let restarted=localBroker();restarted.standingCanCampaignDirectory=old.standingCanCampaignDirectory
            return restarted
        }
        func emptyObservationFile(_ b:ROBControllerArmApproval,mutate:(inout[String:Any])->Void={_ in})throws->URL {
            let file=localDirectory.appendingPathComponent(UUID().uuidString+"-empty-observation.json")
            try b.exportLocalCanCampaignEmptyObservationTemplate(to:file)
            var value=try JSONSerialization.jsonObject(with:Data(contentsOf:file))as![String:Any]
            value["sourceMessage"]="Both grippers are empty";value["sourceMessageSHA256"]=hash("Both grippers are empty")
            mutate(&value)
            try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:file)
            return file
        }
        do {
            let b=try uncertainObjectStateBroker("positive"),stateURL=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            let before=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL))as![String:Any]
            let campaign=before["campaignID"]as!String,authorizationURL=b.standingCanCampaignDirectory.appendingPathComponent("authorization-"+campaign+".json")
            let authorization=try Data(contentsOf:authorizationURL),holds=ROBAmberGatewayClient.shared.holds
            var commands=0,prompts=0
            b.send={_,_,_ in commands+=1;return true};b.announceApproval={_ in prompts+=1}
            check(b.canImportLocalCanCampaignEmptyObservation && b.standingCanCampaignMayHoldPayload,
                "Previous-app execution remains uncertain until actual object-state evidence")
            let file=try emptyObservationFile(b)
            check(b.standingCanCampaignMayHoldPayload && !b.isPending,"Export alone cleared contents or started work")
            try b.importLocalCanCampaignEmptyObservation(fromReceiptURL:file)
            let after=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL))as![String:Any]
            let mutable:Set<String>=["possiblePayloadHeld","state","detail"]
            let beforePreserved=before.filter{!mutable.contains($0.key)},afterPreserved=after.filter{!mutable.contains($0.key)}
            let beforeBytes=try JSONSerialization.data(withJSONObject:beforePreserved,options:.sortedKeys)
            let afterBytes=try JSONSerialization.data(withJSONObject:afterPreserved,options:.sortedKeys)
            check(beforeBytes==afterBytes,
                "EMPTY fact changed campaign authorization, transfer counts, attempts or job history")
            check(after["state"]as?String=="paused" && after["possiblePayloadHeld"]as?Bool==false &&
                !b.standingCanCampaignMayHoldPayload && !b.canImportLocalCanCampaignEmptyObservation,
                "Previous executing-state uncertainty reasserted after the explicit EMPTY fact")
            check(!b.isPending && b.standingLocalCanCampaignActive && commands==0 && prompts==0 &&
                ROBAmberGatewayClient.shared.holds==holds && !b.authorizesRightArmTrial("invented"),
                "Object-state import created motion authority, spoke approval or issued a command")
            let retainedAuthorization=try Data(contentsOf:authorizationURL)
            check(retainedAuthorization==authorization &&
                !FileManager.default.fileExists(atPath:b.standingCanCampaignDirectory.appendingPathComponent("terminal-"+campaign+".json").path),
                "Object-state evidence rewrote authorization or terminal history")
            let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:file))as![String:Any]
            let auditURL=b.localRecyclingApprovalAuditDirectory.appendingPathComponent("empty-observation-"+(receipt["observationID"]as!String)+".json")
            let audit=try JSONSerialization.jsonObject(with:Data(contentsOf:auditURL))as![String:Any]
            check(audit["source"]as?String=="explicit_user_observation" && audit["sourceMessage"]as?String=="Both grippers are empty" &&
                audit["motionAuthority"]as?Bool==false && audit["taskStarted"]as?Bool==false && audit["previousPossiblePayloadHeld"]as?Bool==true,
                "Object-state audit lost truthful source or claimed task authority")
            let permissions=try FileManager.default.attributesOfItem(atPath:auditURL.path)[.posixPermissions]as?NSNumber
            check(permissions?.intValue==0o600,"Object-state audit is not private0600")
            do {try b.importLocalCanCampaignEmptyObservation(fromReceiptURL:file);check(false,"Object observation replay imported")}
            catch {check(!b.isPending && !b.standingCanCampaignMayHoldPayload,"Replay changed EMPTY fact or started a task")}
            let restarted=localBroker();restarted.standingCanCampaignDirectory=b.standingCanCampaignDirectory
            check(!restarted.standingCanCampaignMayHoldPayload && restarted.standingLocalCanCampaignActive && !restarted.isPending,
                "Recorded EMPTY fact did not survive relaunch independently of motion authority")
            do {try restarted.importLocalCanCampaignEmptyObservation(fromReceiptURL:file);check(false,"Prior-app observation replay imported")}
            catch {check(!restarted.isPending,"Prior-app replay started a task")}
        }
        for invalid in ["stale","future","app","campaign","authorization","state_hash","last_job","last_job_app","nonce",
            "mic_source","model_source","message","hash","observation","scope","extra","nonce_expired","permissions","symlink","state_changed","pending","current_executing","revoked","consumed","audit_failure"] {
            let b=try uncertainObjectStateBroker(invalid),stateURL=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            var clock=b.now();b.now={clock}
            let file=try emptyObservationFile(b){value in
                switch invalid {
                case "stale":value["issuedAtMilliseconds"]=clock.timeIntervalSince1970*1000-600_001
                case "future":value["issuedAtMilliseconds"]=clock.timeIntervalSince1970*1000+1
                case "app":value["appSessionID"]=UUID().uuidString
                case "campaign":value["campaignID"]=UUID().uuidString
                case "authorization":value["authorizationSHA256"]=String(repeating:"0",count:64)
                case "state_hash":value["standingStateSHA256"]=String(repeating:"0",count:64)
                case "last_job":value["lastJobID"]="other-job"
                case "last_job_app":value["lastJobAppSessionID"]=UUID().uuidString
                case "nonce":value["observationID"]=UUID().uuidString
                case "mic_source":value["source"]="final_clean_local_microphone"
                case "model_source":value["source"]="model_output"
                case "message":value["sourceMessage"]="yes proceed";value["sourceMessageSHA256"]=hash("yes proceed")
                case "hash":value["sourceMessageSHA256"]=String(repeating:"0",count:64)
                case "observation":value["observation"]="left_gripper_empty"
                case "scope":var scope=value["scope"]as![String:Any];scope["armTravel"]=true;value["scope"]=scope
                case "extra":value["newAuthority"]=true
                default:break
                }
            }
            var input=file
            if invalid=="nonce_expired" {clock.addTimeInterval(601)}
            if invalid=="permissions" {try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)}
            if invalid=="symlink" {
                input=localDirectory.appendingPathComponent(UUID().uuidString+"-observation-link.json")
                try FileManager.default.createSymbolicLink(at:input,withDestinationURL:file)
            }
            if invalid=="state_changed" || invalid=="current_executing" {
                var value=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL))as![String:Any]
                if invalid=="state_changed" {value["recoveryAttempts"]=1}
                else {value["lastJobAppSessionID"]=b.localRecyclingApprovalSessionID}
                try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:stateURL)
            }
            if invalid=="pending" {b.request(operation:"manual",arm:"right",summary:"Synthetic pending task",execute:{_ in check(false,"Pending observation test executed")},cancel:{},completion:{_ in})}
            if invalid=="revoked" {b.cancel(reason:"Synthetic Stop before importing the fact")}
            if invalid=="consumed" {
                var value=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL))as![String:Any]
                value["state"]="consumed";value["completedTransfers"]=4
                try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:stateURL)
            }
            if invalid=="audit_failure" {
                let blocker=localDirectory.appendingPathComponent(UUID().uuidString+"-audit-is-file")
                try Data("not-a-directory".utf8).write(to:blocker);b.localRecyclingApprovalAuditDirectory=blocker
            }
            let before=try Data(contentsOf:stateURL),holds=ROBAmberGatewayClient.shared.holds
            do {try b.importLocalCanCampaignEmptyObservation(fromReceiptURL:input);check(false,"Invalid object-state receipt accepted: "+invalid)}
            catch {
                let retained=try Data(contentsOf:stateURL)
                check(retained==before && b.standingCanCampaignMayHoldPayload && ROBAmberGatewayClient.shared.holds==holds,
                    "Rejected observation changed contents/evidence or issued a command: "+invalid)
            }
        }
        for state in ["active","paused","recovering"] {
            let b=try uncertainObjectStateBroker("eligible-"+state),url=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            var value=try JSONSerialization.jsonObject(with:Data(contentsOf:url))as![String:Any]
            value["state"]=state;try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:url)
            check(b.canImportLocalCanCampaignEmptyObservation,"Eligible uncertain nonexecuting state lacked the object-state observation path")
            try b.importLocalCanCampaignEmptyObservation(fromReceiptURL:emptyObservationFile(b))
            check(!b.standingCanCampaignMayHoldPayload && !b.isPending && b.standingLocalCanCampaignState?["state"]as?String=="paused",
                "Object-state observation resumed a nonexecuting campaign")
        }
        do {
            let b=try uncertainObjectStateBroker("intervening-operation"),file=try emptyObservationFile(b)
            var done:((NSDictionary)->Void)?
            b.request(operation:"manual",arm:"right",summary:"Synthetic intervening operation",execute:{done=$0},cancel:{},completion:{_ in})
            check(b.receiveSpokenAuthorization("yes proceed") && done != nil,"Synthetic intervening operation did not start")
            done?(["status":"completed"])
            check(!b.isPending,"Synthetic intervening operation did not finish")
            do {try b.importLocalCanCampaignEmptyObservation(fromReceiptURL:file);check(false,"An old object observation crossed an intervening arm operation")}
            catch {check(b.standingCanCampaignMayHoldPayload && !b.isPending,"Old object fact changed uncertainty after another operation")}
        }
        do {
            let b=localBroker();try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b))
            var restarts=0
            check(b.scheduleStandingLocalCanCampaignRecovery(reason:.transportLost,restart:{restarts+=1}),"Synthetic recovery did not queue")
            let url=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            var value=try JSONSerialization.jsonObject(with:Data(contentsOf:url))as![String:Any]
            value["possiblePayloadHeld"]=true;try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:url)
            try b.importLocalCanCampaignEmptyObservation(fromReceiptURL:emptyObservationFile(b))
            RunLoop.current.run(until:Date().addingTimeInterval(1.1))
            check(restarts==0 && !b.isPending && !b.standingCanCampaignMayHoldPayload &&
                (b.standingLocalCanCampaignState?["recoveryAttempts"]as?NSNumber)?.intValue==1,
                "Import started queued recovery or reset its attempt count")
        }

        // Permission-state changes must materialize uncertainty inferred from
        // an old app's executing job before removing that inference condition.
        for transition in ["pause","revoke"] {
            let b=try uncertainObjectStateBroker("old-executing-"+transition)
            let stateURL=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            var value=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL))as![String:Any]
            value["possiblePayloadHeld"]=false
            try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:stateURL)
            check(b.standingCanCampaignMayHoldPayload,"Old executing job lost its implicit payload uncertainty")
            if transition=="pause" {b.pauseStandingLocalCanCampaign(reason:"Synthetic maintenance quit")}
            else {b.cancel(reason:"Synthetic Stop after crash")}
            let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL))as![String:Any]
            check(saved["possiblePayloadHeld"]as?Bool==true && saved["state"]as?String==(transition=="pause" ? "paused":"revoked") &&
                b.standingCanCampaignMayHoldPayload,"Permission transition silently cleared old-executing uncertainty: "+transition)
            check(saved["lastJobID"]as?String==value["lastJobID"]as?String &&
                saved["lastJobAppSessionID"]as?String==value["lastJobAppSessionID"]as?String &&
                (saved["completedTransfers"]as?NSNumber)?.intValue==1 && (saved["recoveryAttempts"]as?NSNumber)?.intValue==2,
                "Materializing object uncertainty changed the job history or counts")
            let restarted=localBroker();restarted.standingCanCampaignDirectory=b.standingCanCampaignDirectory
            check(restarted.standingCanCampaignMayHoldPayload,"Another restart silently cleared materialized object uncertainty")
        }
        do {
            let b=localBroker();try b.importLocalCanCampaignAuthorization(fromReceiptURL:standingFile(b))
            var done:((NSDictionary)->Void)?
            b.requestRecyclingWorkspaceTask(command:"right_recycle_cans",arm:"right",canCount:4,
                summary:"Synthetic completion-transition fixture",contextIdentity:{"current"},receiptOnly:true,
                permitsUnmeasuredVisualCalibrationTrial:true,execute:{done=$0},cancel:{},completion:{_ in})
            let url=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            var value=try JSONSerialization.jsonObject(with:Data(contentsOf:url))as![String:Any]
            // Inject a saved old-app record and completed counter only into
            // this socket-free fixture to exercise the private consume path.
            value["lastJobAppSessionID"]=UUID().uuidString;value["possiblePayloadHeld"]=false;value["completedTransfers"]=4
            try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:url)
            done?(["status":"not_found","arm_motion_sent":false,"reach_sent":false])
            let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:url))as![String:Any]
            check(saved["state"]as?String=="consumed" && saved["possiblePayloadHeld"]as?Bool==true &&
                b.standingCanCampaignMayHoldPayload && !b.standingLocalCanCampaignActive && !b.isPending,
                "Consuming permission erased old-executing payload uncertainty")
        }
        do {
            let b=try uncertainObjectStateBroker("confirmed-empty-maintenance")
            try b.importLocalCanCampaignEmptyObservation(fromReceiptURL:emptyObservationFile(b))
            b.pauseStandingLocalCanCampaign(reason:"Synthetic maintenance after actual EMPTY evidence")
            check(!b.standingCanCampaignMayHoldPayload && b.standingLocalCanCampaignState?["possiblePayloadHeld"]as?Bool==false,
                "Maintenance turned a supported EMPTY fact into payload uncertainty")
            b.cancel(reason:"Synthetic Stop after actual EMPTY evidence")
            let restarted=localBroker();restarted.standingCanCampaignDirectory=b.standingCanCampaignDirectory
            check(!restarted.standingCanCampaignMayHoldPayload,"Revoking known EMPTY permission fabricated a payload")
        }
        do {
            let b=try uncertainObjectStateBroker("failed-maintenance-save")
            let url=b.standingCanCampaignDirectory.appendingPathComponent("active-campaign.json")
            var value=try JSONSerialization.jsonObject(with:Data(contentsOf:url))as![String:Any]
            value["possiblePayloadHeld"]=false;try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:url)
            try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:b.standingCanCampaignDirectory.path)
            b.pauseStandingLocalCanCampaign(reason:"Synthetic maintenance with unwritable storage")
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:b.standingCanCampaignDirectory.path)
            check(b.standingCanCampaignMayHoldPayload,"A failed maintenance save exposed automatic EMPTY setup")
            let restarted=localBroker();restarted.standingCanCampaignDirectory=b.standingCanCampaignDirectory
            check(restarted.standingCanCampaignMayHoldPayload,"A failed pause lost uncertainty after another crash/restart")
            b.cancel(reason:"Synthetic Stop after maintenance I/O failure")
            check(b.standingCanCampaignMayHoldPayload && !b.standingLocalCanCampaignActive,
                "Fallback revocation after I/O failure erased uncertainty")
        }

        // Global typed Stop is authenticated independently of a task/card ID.
        // The notification consumer owns physical both-arm hold; this broker can
        // truthfully report only that Stop was requested and authority revoked.
        let stopHello = ROBRobotActionMessage.controllerHello(senderID: sender, acceptsActions: true,
            capabilities: ["arm_operation", "stop_motion"])
        func controllerStop(callID: String = UUID().uuidString, senderID: String = sender,
                            recipientID: String? = "Cerebro.arm-operations", arguments: NSDictionary = [:]) -> ROBRobotActionMessage {
            .actionRequest(callID: callID, action: "stop_motion", arguments: arguments,
                senderID: senderID, recipientID: recipientID, expiresAt: Date().addingTimeInterval(30))
        }
        do {
            let b = localBroker()
            try b.importLocalCanCampaignAuthorization(fromReceiptURL: standingFile(b))
            var executed = 0, cancelled = 0, notifications = 0, replies: [ROBRobotActionMessage] = []
            var cancelledBeforeNotification = false, notificationHasProvenance = false
            b.send = { message, target, targetSession in
                check(target == device && targetSession == session, "Stop reply stays in its authenticated transport session")
                replies.append(message); return true
            }
            _ = b.receive(stopHello, device: device, session: session)
            b.requestRecyclingWorkspaceTask(command: "right_recycle_cans", arm: "right", canCount: 4,
                summary: "Synthetic standing can job", contextIdentity: { "current-source" }, receiptOnly: true,
                permitsUnmeasuredVisualCalibrationTrial: true,
                execute: { _ in executed += 1 }, cancel: { cancelled += 1 }, completion: { _ in })
            check(executed == 1 && b.isPending && b.standingLocalCanCampaignActive,
                "Local job deliberately has no controller action-card approval")
            let observer = NotificationCenter.default.addObserver(forName: Notification.Name("ROBControllerOperatorPriorityStop"),
                object: b, queue: nil) { note in
                    notifications += 1
                    cancelledBeforeNotification = !b.isPending && !b.standingLocalCanCampaignActive && cancelled == 1
                    notificationHasProvenance = note.object as AnyObject? === b && !(note.userInfo?["reason"] as? String ?? "").isEmpty
                }
            defer { NotificationCenter.default.removeObserver(observer) }
            let stop = controllerStop()
            check(b.receive(stop, device: device, session: session), "Fresh unmatched-ID typed Stop is handled")
            check(notifications == 1 && cancelled == 1 && !b.isPending && !b.standingLocalCanCampaignActive,
                "Controller Stop ends a local standing job, not only a matching action card")
            check(cancelledBeforeNotification, "Revocation and executor cancellation finish before global hold notification")
            check(notificationHasProvenance, "Global Stop has exact broker provenance and a reason")
            let acknowledgement = replies.last!
            check(acknowledgement.callID == stop.callID && acknowledgement.state == .accepted &&
                acknowledgement.result["status"] as? String == "stop_requested" &&
                acknowledgement.result["physical_hold_confirmed"] as? Bool == false &&
                acknowledgement.result["automatic_lowering"] as? Bool == false,
                "Wire acknowledgement never claims measured hold or automatic lowering")
            _ = b.receive(stop, device: device, session: session)
            _ = b.receive(controllerStop(callID: stop.callID!), device: device, session: session)
            check(notifications == 1 && cancelled == 1 && replies.last?.state == .rejected &&
                replies.last?.result["status"] as? String == "rejected_replay",
                "Repeated message or new-message replay of the same call cannot reissue a Stop event")
        }
        for invalid in ["unknown", "wrongDevice", "wrongSession", "sender", "recipient", "nilRecipient",
                        "stale", "inactive", "capability", "withdrawn", "expired", "arguments"] {
            let b = localBroker(); var clock = Date(), notifications = 0
            b.now = { clock }
            try b.importLocalCanCampaignAuthorization(fromReceiptURL: standingFile(b))
            if invalid != "unknown" {
                _ = b.receive(invalid == "capability" ? hello : stopHello, device: device, session: session)
            }
            var stop = controllerStop()
            if invalid == "sender" { stop = controllerStop(senderID: "forged-alias") }
            if invalid == "recipient" { stop = controllerStop(recipientID: "another-cerebro") }
            if invalid == "nilRecipient" { stop = controllerStop(recipientID: nil) }
            if invalid == "arguments" { stop = controllerStop(arguments: ["return_to_hang": true]) }
            if invalid == "stale" { clock.addTimeInterval(15) }
            if invalid == "expired" {
                clock.addTimeInterval(31)
                _ = b.receive(stopHello, device: device, session: session)
            }
            if invalid == "inactive" { b.sessionIsActive = { _, _ in false } }
            if invalid == "withdrawn" {
                _ = b.receive(.controllerHello(senderID: sender, acceptsActions: false, capabilities: ["stop_motion"]),
                    device: device, session: session)
            }
            let observer = NotificationCenter.default.addObserver(forName: Notification.Name("ROBControllerOperatorPriorityStop"),
                object: b, queue: nil) { _ in notifications += 1 }
            let handled = b.receive(stop, device: invalid == "wrongDevice" ? UUID() : device,
                session: invalid == "wrongSession" ? UUID() : session)
            NotificationCenter.default.removeObserver(observer)
            check(!handled && notifications == 0 && b.standingLocalCanCampaignActive,
                "Invalid controller Stop must not alter a local campaign: " + invalid)
            b.cancel(reason: "Fixture cleanup")
        }
        do {
            let b = localBroker(); var restarts = 0, notifications = 0
            try b.importLocalCanCampaignAuthorization(fromReceiptURL: standingFile(b))
            check(b.scheduleStandingLocalCanCampaignRecovery(reason: .transportLost, restart: { restarts += 1 }),
                "A stationary campaign can have a queued fresh-plan recovery")
            _ = b.receive(stopHello, device: device, session: session)
            let observer = NotificationCenter.default.addObserver(forName: Notification.Name("ROBControllerOperatorPriorityStop"),
                object: b, queue: nil) { _ in notifications += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            check(b.receive(controllerStop(), device: device, session: session) && !b.standingLocalCanCampaignActive,
                "Global typed Stop also revokes idle standing authority")
            RunLoop.current.run(until: Date().addingTimeInterval(1.10))
            check(restarts == 0 && notifications == 1, "Typed Stop cancels queued recovery without commanding a return")
            check(b.receive(controllerStop(), device: device, session: session) && notifications == 2,
                "A distinct fresh operator Stop remains available after the previous job ended")
        }
        // New table relay is a distinct native written-user lane. No receipt,
        // source or arm scope from the older can campaign can authorize it.
        let relayCamera=UUID()
        func relayContextValue(camera:UUID?=nil,error:Double=0.035)->ROBTableRelayContext {
            .init(rightModelID:String(repeating:"c",count:64),rightReferenceID:String(repeating:"d",count:64),rightMappingID:String(repeating:"a",count:64),
                leftModelID:String(repeating:"c",count:64),leftReferenceID:String(repeating:"d",count:64),leftMappingID:String(repeating:"b",count:64),
                geometryID:String(repeating:"e",count:64),cameraGeneration:camera ?? relayCamera,bodyMotionIdentity:"synthetic stationary body",
                gatewayGeneration:7,runtimeCalibrationIdentity:String(repeating:"f",count:64),stereoPolicySHA256:String(repeating:"1",count:64),
                physicalProjectionIdentity:String(repeating:"2",count:64),assumedSpatialErrorMeters:error)
        }
        var relayContext:ROBTableRelayContext?=relayContextValue()
        func relayFeedback(right:Double=0,left:Double=0,age:Double=1,rightMode:Int=2,leftMode:Int=2,
            generation:UInt64=7,sequence:UInt64=100,rightStationary:Bool=true,leftStationary:Bool=true,leftAge:Double?=nil)->ROBTableRelayPhaseFeedback {
            .init(gatewayGeneration:generation,rightPositions:[right,0,0,0,0,0,0],leftPositions:[left,0,0,0,0,0,0],
                rightModes:Array(repeating:rightMode,count:7),leftModes:Array(repeating:leftMode,count:7),
                rightTelemetrySequence:sequence,leftTelemetrySequence:sequence,rightStationary:rightStationary,leftStationary:leftStationary,
                rightMotorAgeMilliseconds:age,leftMotorAgeMilliseconds:leftAge ?? age,rightGripperAgeMilliseconds:age,leftGripperAgeMilliseconds:leftAge ?? age)
        }
        func relayEmpty(_ b:ROBControllerArmApproval,source:String="audited_user_declared_empty_plus_no_acquisition_history",
            acquisition:Int=0,declaredAt:Double?=nil)->ROBTableRelayInitialEmptyEvidence {
            .init(source:source,declarationMessageSHA256:hash("Synthetic actual user fact: both grippers are empty"),
                declarationAuditSHA256:hash("Synthetic private declaration audit"),taskHistorySHA256:hash("Synthetic empty startup and bounded empty motion only"),
                declaredAtMilliseconds:declaredAt ?? b.now().timeIntervalSince1970*1000-1000,appSessionID:b.localRecyclingApprovalSessionID,
                rightDeclaredEmpty:true,leftDeclaredEmpty:true,rightAcquisitionCommandsSinceDeclaration:acquisition,
                leftAcquisitionCommandsSinceDeclaration:0,anyUncertainAcquisitionAcknowledgement:false,globalMayHoldPayload:false)
        }
        func relayReceipt(_ b:ROBControllerArmApproval,mutate:(inout[String:Any])->Void={_ in})throws->URL {
            var value=b.pendingTableRelayReceiptTemplate as! [String:Any]
            let source="Synthetic actual written user instruction: RIGHT picks up cans, places on a shared table; LEFT puts them in the orange bucket."
            let additional="Synthetic explicit instruction: both arms permitted one at a time, stationary torso and treads, protected visual trial."
            value["sourceMessage"]=source;value["sourceMessageSHA256"]=hash(source)
            value["additionalUserInstruction"]=additional;value["additionalUserInstructionSHA256"]=hash(additional)
            mutate(&value)
            let url=localDirectory.appendingPathComponent(UUID().uuidString+"-table-relay.json")
            try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            return url
        }
        func relayRequest(_ b:ROBControllerArmApproval,count:Int=1,execute:@escaping(@escaping(NSDictionary)->Void)->Void={_ in}) {
            b.requestTableRelayWorkspaceTask(canCount:count,summary:"Synthetic exact RIGHT-table-LEFT-bucket relay",
                currentContext:{relayContext},execute:execute,cancel:{},completion:{_ in})
        }
        func relayReject(_ label:String,_ operation:()throws->Void) {
            do {try operation();check(false,label)}catch {check(true,label)}
        }
        do {
            let b=localBroker();var executed=0
            relayRequest(b,execute:{_ in executed+=1})
            check(b.isPending && b.pendingTableRelayReceiptTemplate != nil && executed==0,"Relay starts only from its native file receipt")
            check(!b.receiveSpokenAuthorization("yes proceed"),"Spoken single-arm acknowledgement cannot import a relay receipt")
            let invalids:[(String,(inout[String:Any])->Void)]=[
                ("legacy version",{$0["schemaVersion"]=2}),
                ("fake microphone",{$0["source"]="final_clean_local_microphone"}),
                ("wrong pending job",{$0["pendingID"]=UUID().uuidString}),
                ("wrong count",{v in var s=v["scope"]as![String:Any];s["canCount"]=2;v["scope"]=s}),
                ("wrong route",{v in var s=v["scope"]as![String:Any];s["route"]=["right_pickup","orange_bucket"];v["scope"]=s}),
                ("simultaneous arms",{v in var s=v["scope"]as![String:Any];s["oneMovingArmAtATime"]=false;v["scope"]=s}),
                ("source hash",{$0["sourceMessageSHA256"]=hash("different")})]
            for (label,mutate) in invalids {relayReject(label){try b.importLocalTableRelayApproval(fromReceiptURL:relayReceipt(b,mutate:mutate))}}
            let receipt=try relayReceipt(b)
            relayReject("Legacy importer cannot accept relay"){try b.importLocalRecyclingSessionApproval(fromReceiptURL:receipt)}
            try b.importLocalTableRelayApproval(fromReceiptURL:receipt)
            check(executed==1 && b.tableRelayMayHoldPayload,"Relay import persists initial object uncertainty before execution")
            check(!b.authorizesRightArmTrial("Synthetic exact RIGHT-table-LEFT-bucket relay") &&
                !b.authorizesLeftArmTrial("Synthetic exact RIGHT-table-LEFT-bucket relay"),"Relay must not widen legacy arm grants")
            relayReject("Bare empty evidence not accepted"){try b.recordTableRelayInitialEmptyEvidence(relayEmpty(b,source:"arbitrary_hash"),feedback:relayFeedback())}
            relayReject("Acquisition history not empty"){try b.recordTableRelayInitialEmptyEvidence(relayEmpty(b,acquisition:1),feedback:relayFeedback())}
            relayReject("Initial stale opposite arm"){try b.recordTableRelayInitialEmptyEvidence(relayEmpty(b),feedback:relayFeedback(age:251))}
            try b.recordTableRelayInitialEmptyEvidence(relayEmpty(b),feedback:relayFeedback(rightMode:0,leftMode:0))
            check(!b.tableRelayMayHoldPayload && b.activeTableRelayLedger?["supportStage"]as?String=="initial_empty_ASSUMED_declared_task_history",
                "Audited declared-empty/no-acquisition chain works without a new prompt or measured-possession claim")
            var feedback:ROBTableRelayPhaseFeedback?=relayFeedback()
            let id=UUID(),proposal=hash("Synthetic immutable RIGHT pickup proposal")
            relayReject("Wrong first phase"){try b.bindTableRelayPhaseProposal(phase:"left_pickup",physicalArm:"left",proposalID:id,proposalSHA256:proposal,feedback:{feedback})}
            relayReject("Wrong physical side"){try b.bindTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"left",proposalID:id,proposalSHA256:proposal,feedback:{feedback})}
            try b.bindTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal,feedback:{feedback})
            check(b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Exact relay phase/proposal is live")
            check(!b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:hash("changed")),"Changed proposal hash rejected")
            relayReject("Second simultaneous binding"){try b.bindTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:UUID(),proposalSHA256:hash("second"),feedback:{feedback})}
            feedback=relayFeedback(right:0.1)
            check(b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Moving-arm q may advance within independently checked proposal")
            feedback=relayFeedback(left:0.01)
            check(!b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Idle physical LEFT movement invalidates RIGHT proposal")
            feedback=relayFeedback(leftStationary:false)
            check(!b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Nonselected arm must be independently stationary")
            feedback=relayFeedback(age:251)
            check(!b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Both-arm motor/gripper freshness is mandatory")
            feedback=relayFeedback(leftAge:251)
            check(!b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Fresh moving RIGHT cannot mask stale stationary LEFT feedback")
            feedback=relayFeedback(rightMode:0)
            check(!b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Moving arm mode must remain position mode")
            feedback=relayFeedback(generation:8)
            check(!b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Changed gateway invalidates proposal")
            feedback=relayFeedback(sequence:99)
            check(!b.authorizesTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal),"Feedback sequences cannot rewind")
            feedback=relayFeedback()
            try b.markTableRelayPossiblePayloadHeld(physicalArm:"right")
            check(b.tableRelayMayHoldPayload && b.activeTableRelayLedger?["rightPossiblePayloadHeld"]as?Bool==true,"Possible RIGHT acquisition is durable before grip ack")
            relayReject("No repeated grip in same phase"){try b.markTableRelayPossiblePayloadHeld(physicalArm:"right")}
            try b.endTableRelayPhaseProposal(proposalID:id,proposalSHA256:proposal)
            relayReject("No proposal replay"){try b.bindTableRelayPhaseProposal(phase:"right_pickup",physicalArm:"right",proposalID:id,proposalSHA256:proposal,feedback:{feedback})}
            try b.recordTableRelayPhaseCompletion(phase:"right_pickup",evidenceSHA256:hash("actual native positive visual grasp"),feedback:relayFeedback())
            check(b.activeTableRelayLedger?["phase"]as?String=="right_place_shared_table","Positive RIGHT grasp advances only to table placement")
            b.cancel(reason:"Synthetic Stop during possible RIGHT carry")
            check(!b.isPending && b.tableRelayMayHoldPayload && b.activeTableRelayLedger?["state"]as?String=="revoked","Stop revokes authority but preserves per-arm payload uncertainty")
            let restarted=localBroker();restarted.localRecyclingApprovalAuditDirectory=b.localRecyclingApprovalAuditDirectory
            check(restarted.tableRelayMayHoldPayload && restarted.activeTableRelayLedger==nil,"Restart reloads uncertainty, never relay authority")
            relayRequest(restarted)
            try restarted.importLocalTableRelayApproval(fromReceiptURL:relayReceipt(restarted))
            relayReject("Old empty declaration cannot erase possible acquisition"){try restarted.recordTableRelayInitialEmptyEvidence(relayEmpty(restarted),feedback:relayFeedback())}
            try restarted.recordTableRelayInitialEmptyEvidence(relayEmpty(restarted,source:"fresh_audited_user_declared_empty",
                declaredAt:restarted.now().timeIntervalSince1970*1000),feedback:relayFeedback())
            check(!restarted.tableRelayMayHoldPayload,"A newer actual declared-empty fact can resolve prior uncertain acquisition")
            restarted.cancel(reason:"Synthetic fixture stop")
        }
        do {
            let b=localBroker();var done:((NSDictionary)->Void)?;var completion:NSDictionary=[:]
            b.requestTableRelayWorkspaceTask(canCount:1,summary:"Synthetic complete native relay",currentContext:{relayContext},execute:{done=$0},cancel:{},completion:{completion=$0})
            try b.importLocalTableRelayApproval(fromReceiptURL:relayReceipt(b))
            try b.recordTableRelayInitialEmptyEvidence(relayEmpty(b),feedback:relayFeedback())
            let phases=["right_pickup","right_place_shared_table","right_retreat","left_pickup","left_place_bucket","left_retreat"]
            for (i,phase) in phases.enumerated() {
                let side=phase.hasPrefix("right_") ? "right":"left",id=UUID(),proposal=hash("synthetic phase \(i)")
                relayReject("Phase cannot complete without a consumed native proposal"){try b.recordTableRelayPhaseCompletion(phase:phase,evidenceSHA256:hash("unbound"),feedback:relayFeedback())}
                try b.bindTableRelayPhaseProposal(phase:phase,physicalArm:side,proposalID:id,proposalSHA256:proposal,feedback:{relayFeedback()})
                if phase.hasSuffix("pickup") {try b.markTableRelayPossiblePayloadHeld(physicalArm:side)}
                try b.endTableRelayPhaseProposal(proposalID:id,proposalSHA256:proposal)
                try b.recordTableRelayPhaseCompletion(phase:phase,evidenceSHA256:hash("synthetic positive native result \(i)"),feedback:relayFeedback(),bucketLandingVerified:phase=="left_place_bucket")
                if phase=="right_place_shared_table" {check(b.activeTableRelayLedger?["completedTransfers"]as?Int==0,"Table placement is not a recycled-can count")}
            }
            check(b.activeTableRelayLedger?["completedTransfers"]as?Int==1 && b.activeTableRelayLedger?["verifiedBucketLandings"]as?Int==1 && !b.tableRelayMayHoldPayload,
                "Only final ordered bucket release/retreat completes the relay")
            done?(["status":"completed"])
            check(!b.isPending && completion["status"]as?String=="completed" && b.activeTableRelayLedger?["state"]as?String=="consumed","Complete relay consumes its grant")
        }
        do {
            let b=localBroker();relayRequest(b)
            let receipt=try relayReceipt(b);let original=try JSONSerialization.jsonObject(with:Data(contentsOf:receipt))as![String:Any]
            try b.importLocalTableRelayApproval(fromReceiptURL:receipt);b.cancel(reason:"Synthetic cancellation")
            relayRequest(b)
            let replay=try relayReceipt(b){$0["receiptID"]=original["receiptID"]}
            relayReject("Consumed/revoked receipt ID tombstone rejects fresh-pending replay"){try b.importLocalTableRelayApproval(fromReceiptURL:replay)}
            b.cancel(reason:"Synthetic cleanup")
        }
        do {
            let b=localBroker();var stopped=0
            var clock=Date();b.now={clock}
            b.requestTableRelayWorkspaceTask(canCount:1,summary:"Synthetic context-bound relay",currentContext:{relayContext},execute:{_ in},cancel:{stopped+=1},completion:{_ in})
            try b.importLocalTableRelayApproval(fromReceiptURL:relayReceipt(b))
            relayContext=relayContextValue(camera:UUID());b.tick()
            check(!b.isPending && stopped==1,"Camera/body/model/gateway stable context change revokes active relay")
            relayContext=relayContextValue()
            relayRequest(b);try b.importLocalTableRelayApproval(fromReceiptURL:relayReceipt(b));clock.addTimeInterval(601);b.tick()
            check(!b.isPending,"Relay retains bounded600second execution")
        }
        do {
            for count in [0,9] {let b=localBroker();relayRequest(b,count:count);check(!b.isPending,"Relay count remains exact1...8")}
            relayContext=relayContextValue(error:0.04)
            let b=localBroker();relayRequest(b);check(!b.isPending,"Relay35mm assumption cannot silently change")
            relayContext=relayContextValue()
        }
        print("Controller/spoken arm approval and session reuse: \(checks) checks passed; no hardware access")
    }
}
