import Foundation

// Compile with the real protocols, binding, and gripper bridge. These boundary
// doubles contain no network or hardware APIs.
extension Notification.Name {
    static let ROBAmberGatewayGripperDidUpdate = Self("fixture.gripper")
    static let ROBAmberGatewayCommandDidComplete = Self("fixture.command")
    static let ROBAmberGatewayStateDidChange = Self("fixture.gateway")
    static let ROBAmberDebugAuthorityDidChange = Self("fixture.authority")
}

enum ROBAmberGatewayState: Int { case ready = 1 }

final class ROBAmberGatewayClient: NSObject {
    static let shared = ROBAmberGatewayClient()
    var snapshots: [String: NSDictionary] = [:]
    var queriedArms: [String] = []
    var commands: [(arm: String, action: String, force: Int)] = []
    func isReady() -> Bool { true }
    func queryGripperState(forArm arm: String) -> UInt64 {
        queriedArms.append(arm)
        return 1
    }
    func gripperSnapshot(forArm arm: String) -> NSDictionary {
        snapshots[arm] ?? ["arm": arm, "calibrationState": "required"]
    }
    func controlGripper(forArm arm: String, action: String, force: Int) -> UInt64 {
        commands.append((arm, action, force))
        return UInt64(commands.count)
    }
}

final class ROBAmberDebugAuthority: NSObject {
    static let shared = ROBAmberDebugAuthority()
    func authorizesController() -> Bool { true }
}

enum ROBControlLiveSessionRegistry {
    static func isActiveOperator(controllerID: UUID, sessionID: UUID) -> Bool { true }
}

final class AutoNetServer {
    var messages: [ROBGripperControlDecodedMessage] = []
    func sendGripperControlMessage(_ data: Data, to: UUID?, sessionID: UUID?) -> Bool {
        if let decoded = try? ROBGripperControlWireCodec.decode(data) {
            messages.append(decoded)
        }
        return true
    }
    var states: [ROBGripperStateEnvelope] {
        messages.compactMap { if case .state(let state) = $0 { return state }; return nil }
    }
    var dispositions: [ROBGripperCommandDispositionEnvelope] {
        messages.compactMap {
            if case .commandDisposition(let disposition) = $0 { return disposition }; return nil
        }
    }
}

@main
struct ROBAmberArmBindingFixtureTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) {
        guard condition() else { fatalError(detail) }
    }

    static func snapshot(_ wireArm: String, calibrated: Bool, force: Int) -> NSDictionary {
        ["arm": wireArm,
         "calibrationState": calibrated ? "command_accepted_unverified" : "required",
         "lastForce": force, "lastAction": "hold", "commandInFlight": false]
    }

    static func main() throws {
        for (physical, core, port, wire) in [
            (ROBArmSide.left, "R11", 26002, "right"),
            (ROBArmSide.right, "L10", 26001, "left"),
        ] {
            expect(physical.amberGatewayArm == wire, "Wrong outbound core")
            expect(physical.amberCoreName == core, "Wrong core label")
            expect(physical.amberUDPPort == port, "Wrong port label")
            expect(ROBArmSide(amberGatewayArm: wire) == physical, "Wrong inbound side")
            expect(ROBArmSide(amberGatewayArm: wire.uppercased()) == physical,
                   "Case normalization changed side")
            let json = try JSONEncoder().encode(physical)
            expect(String(data: json, encoding: .utf8) == "\"\(physical.rawValue)\"",
                   "Physical ROBControl protocol side was changed")
        }
        expect(ROBArmSide(amberGatewayArm: "L10") == nil, "Unknown wire key was guessed")

        let gateway = ROBAmberGatewayClient.shared
        // Only ROB-left/R11 is calibrated. ROB-right/L10 must remain blocked.
        gateway.snapshots["right"] = snapshot("right", calibrated: true, force: 19)
        gateway.snapshots["left"] = snapshot("left", calibrated: false, force: 11)
        let server = AutoNetServer()
        let bridge = ROBGripperControllerBridge(server: server)
        bridge.start()
        defer { bridge.stop() }
        expect(gateway.queriedArms == ["right", "left"], "Queries crossed physical sides")
        expect(server.states.first(where: { $0.arm == .left })?.lastForce == 19,
               "Left initial state came from L10")
        expect(server.states.first(where: { $0.arm == .right })?.lastForce == 11,
               "Right initial state came from R11")

        let controller = UUID(), session = UUID()
        func submit(_ arm: ROBArmSide, sequence: UInt64) throws -> UUID {
            let intent = ROBGripperCommandIntentEnvelope(
                senderID: controller, sessionID: session, sequence: sequence,
                issuedAtUnixMilliseconds: ROBGripperControlWireCodec.currentUnixMilliseconds(),
                leaseMilliseconds: 750, arm: arm, action: .hold, force: 8, deadManHeld: true
            )
            let data = try ROBGripperControlWireCodec.encode(intent)
            expect(bridge.consumeInbound(data, authenticatedControllerID: controller,
                                         authenticatedSessionID: session), "Intent was not consumed")
            return intent.messageID
        }
        func acknowledge(_ command: UInt64, wireArm: String) {
            NotificationCenter.default.post(
                name: .ROBAmberGatewayCommandDidComplete, object: gateway,
                userInfo: ["operation": "gripper_control", "commandID": NSNumber(value: command),
                           "arm": wireArm, "accepted": true]
            )
        }

        _ = try submit(.right, sequence: 1)
        expect(gateway.commands.isEmpty, "Right command borrowed left calibration")
        expect(server.dispositions.last?.arm == .right, "Rejection named wrong physical side")
        expect(server.dispositions.last?.disposition == .rejectedCalibrationRequired,
               "Uncalibrated physical side was admitted")

        let leftRequest = try submit(.left, sequence: 2)
        expect(gateway.commands.count == 1 && gateway.commands[0].arm == "right",
               "Physical left gripper was sent to UDP 26001/L10")
        expect(gateway.commands[0].action == "hold" && gateway.commands[0].force == 8,
               "Mapping changed the requested gripper action")
        acknowledge(1, wireArm: "right")
        expect(server.dispositions.last?.requestMessageID == leftRequest,
               "Acknowledgement lost request correlation")
        expect(server.dispositions.last?.arm == .left, "Acknowledgement crossed sides")
        expect(server.dispositions.last?.disposition == .dispatchAcknowledgedUnverified,
               "Dispatch acknowledgement was lost")

        // Reverse calibration availability to catch either one-way mapping bug.
        gateway.snapshots["right"] = snapshot("right", calibrated: false, force: 19)
        gateway.snapshots["left"] = snapshot("left", calibrated: true, force: 11)
        _ = try submit(.left, sequence: 3)
        expect(gateway.commands.count == 1, "Left command borrowed right calibration")
        let rightRequest = try submit(.right, sequence: 4)
        expect(gateway.commands.count == 2 && gateway.commands[1].arm == "left",
               "Physical right gripper was sent to UDP 26002/R11")
        acknowledge(2, wireArm: "left")
        expect(server.dispositions.last?.requestMessageID == rightRequest
               && server.dispositions.last?.arm == .right, "Right acknowledgement crossed sides")

        for (wire, physical, force) in [("left", ROBArmSide.right, 11), ("right", .left, 19)] {
            let previousCount = server.states.count
            NotificationCenter.default.post(
                name: .ROBAmberGatewayGripperDidUpdate, object: gateway,
                userInfo: ["snapshot": gateway.gripperSnapshot(forArm: wire)]
            )
            expect(server.states.count == previousCount + 1, "Feedback published both sides")
            expect(server.states.last?.arm == physical && server.states.last?.lastForce == force,
                   "Live gripper feedback crossed physical sides")
        }
        print("Amber physical-side routing fixtures passed; no hardware APIs linked")
    }
}

final class ROBArmRoutineCoordinator {
    static let shared = ROBArmRoutineCoordinator()
    let isRunning = false
}
