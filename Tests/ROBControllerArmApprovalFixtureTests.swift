import Foundation

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
            time.addTimeInterval(31); b.tick()
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
                time.addTimeInterval(31)
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
        print("Controller arm approval: \(checks) checks passed; no hardware access")
    }
}
