import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
struct ROBRobotActionProtocolFixtureTests {
    static func main() throws {
        try testControllerHelloRoundTrip()
        try testRequestRoundTrip()
        try testStatusAndCancellationRoundTrip()
        try testInvalidAndExpiredRequests()
        try testOversizedPayloadsAreRejected()
        try testEnvelopeSenderBinding()
        try testAutonomySessionRoundTripAndBounds()
        try testAutonomyCoordinatorSessionAndLidar()
        print("ROB robot-action protocol fixtures passed")
    }

    private static func testControllerHelloRoundTrip() throws {
        let hello = ROBRobotActionMessage.controllerHello(
            senderID: "controller-1",
            acceptsActions: true,
            capabilities: ROBRobotActionMessage.supportedActions
        )
        let decoded = try roundTrip(hello)
        try expect(decoded.kind == .controllerHello, "Hello kind was not preserved")
        try expect(decoded.acceptsActions, "Hello acceptance state was not preserved")
        try expect(decoded.capabilities == ROBRobotActionMessage.supportedActions, "Capabilities changed")
    }

    private static func testRequestRoundTrip() throws {
        let request = ROBRobotActionMessage.actionRequest(
            callID: "gemini-call-1",
            action: "navigate_relative",
            arguments: [
                "distance_m": 0.25,
                "yaw_rad": -0.5,
                "speed_scale": 0.2
            ],
            senderID: "cerebro-1",
            recipientID: "controller-1",
            expiresAt: Date(timeIntervalSinceNow: 30)
        )
        let decoded = try roundTrip(request)
        try expect(decoded.callID == "gemini-call-1", "Call ID was not preserved")
        try expect(decoded.action == "navigate_relative", "Action was not preserved")
        try expect(decoded.senderID == "cerebro-1", "Sender was not preserved")
        try expect(decoded.recipientID == "controller-1", "Recipient was not preserved")
        try expect(decoded.state == .pending, "Request state must be pending")
        try expect(!decoded.isExpired, "Fresh request was marked expired")
    }

    private static func testStatusAndCancellationRoundTrip() throws {
        let accepted = ROBRobotActionMessage.actionStatus(
            callID: "gemini-call-2",
            state: .accepted,
            detail: "Approved once by operator",
            result: [:],
            senderID: "controller-1",
            recipientID: "cerebro-1"
        )
        let acceptedDecoded = try roundTrip(accepted)
        try expect(!acceptedDecoded.isTerminal, "Accepted must be an intermediate state")

        let completed = ROBRobotActionMessage.actionStatus(
            callID: "gemini-call-2",
            state: .completed,
            detail: "Operator confirmed physical completion",
            result: ["confirmed_by": "operator"],
            senderID: "controller-1",
            recipientID: "cerebro-1"
        )
        let completedDecoded = try roundTrip(completed)
        try expect(completedDecoded.isTerminal, "Completed must be terminal")
        try expect(completedDecoded.result["confirmed_by"] as? String == "operator", "Result changed")

        let cancel = ROBRobotActionMessage.actionCancel(
            callID: "gemini-call-2",
            reason: "Gemini cancelled the tool call",
            senderID: "cerebro-1",
            recipientID: "controller-1"
        )
        let cancelDecoded = try roundTrip(cancel)
        try expect(cancelDecoded.kind == .actionCancel, "Cancellation kind was not preserved")
        try expect(cancelDecoded.callID == "gemini-call-2", "Cancellation call ID changed")
        try expect(cancelDecoded.senderID == "cerebro-1", "Cancellation sender changed")
        try expect(cancelDecoded.recipientID == "controller-1", "Cancellation recipient changed")
    }

    private static func testInvalidAndExpiredRequests() throws {
        let mutableArguments: NSMutableDictionary = [
            "distance_m": 0.2,
            "yaw_rad": 0.0,
            "speed_scale": 0.1
        ]
        let immutableRequest = ROBRobotActionMessage.actionRequest(
            callID: "gemini-call-immutable",
            action: "navigate_relative",
            arguments: mutableArguments,
            senderID: "cerebro-1",
            recipientID: nil,
            expiresAt: Date(timeIntervalSinceNow: 30)
        )
        mutableArguments["distance_m"] = 0.8
        try expect(
            (immutableRequest.arguments["distance_m"] as? NSNumber)?.doubleValue == 0.2,
            "Protocol messages must defensively copy mutable arguments"
        )

        let invalid = ROBRobotActionMessage.actionRequest(
            callID: "gemini-call-3",
            action: "navigate_relative",
            arguments: [
                "distance_m": 4.0,
                "yaw_rad": 0.0,
                "speed_scale": 0.9
            ],
            senderID: "cerebro-1",
            recipientID: nil,
            expiresAt: Date(timeIntervalSinceNow: 30)
        )
        try expect(invalid.validationError != nil, "Out-of-bounds motion request was accepted")
        try expect(
            ROBRobotActionWireCodec.archive(invalid, legacySender: invalid.senderID) == nil,
            "Invalid request should not be serializable"
        )

        let expired = ROBRobotActionMessage.actionRequest(
            callID: "gemini-call-4",
            action: "stop_motion",
            arguments: [:],
            senderID: "cerebro-1",
            recipientID: nil,
            expiresAt: Date(timeIntervalSinceNow: -1)
        )
        try expect(expired.isExpired, "Past deadline was not recognized")

        let excessiveLifetime = ROBRobotActionMessage.actionRequest(
            callID: "gemini-call-5",
            action: "stop_motion",
            arguments: [:],
            senderID: "cerebro-1",
            recipientID: nil,
            expiresAt: Date(timeIntervalSinceNow: 121)
        )
        try expect(excessiveLifetime.validationError != nil, "Excessive request lifetime was accepted")
    }

    private static func testOversizedPayloadsAreRejected() throws {
        let oversizedDetail = ROBRobotActionMessage.actionStatus(
            callID: "gemini-call-oversized-detail",
            state: .failed,
            detail: String(repeating: "x", count: 2_049),
            result: [:],
            senderID: "controller-1",
            recipientID: "cerebro-1"
        )
        try expect(oversizedDetail.validationError != nil, "Oversized detail was accepted")
        try expect(
            ROBRobotActionWireCodec.archive(oversizedDetail, legacySender: oversizedDetail.senderID) == nil,
            "Oversized detail should not be serializable"
        )

        let oversizedResult = ROBRobotActionMessage.actionStatus(
            callID: "gemini-call-oversized-result",
            state: .failed,
            detail: "Bounded detail",
            result: ["diagnostic": String(repeating: "x", count: 70_000)],
            senderID: "controller-1",
            recipientID: "cerebro-1"
        )
        try expect(
            ROBRobotActionWireCodec.archive(oversizedResult, legacySender: oversizedResult.senderID) == nil,
            "Payloads larger than 64 KiB should not be serializable"
        )
    }

    private static func testEnvelopeSenderBinding() throws {
        let message = ROBRobotActionMessage.controllerHello(
            senderID: "controller-1",
            acceptsActions: false,
            capabilities: []
        )
        try expect(
            ROBRobotActionWireCodec.archive(message, legacySender: "spoofed-controller") == nil,
            "Outer and inner senders must match"
        )
        try expect(ROBRobotActionWireCodec.decodeEnvelopeData(Data("not an archive".utf8) as NSData) == nil,
                   "Malformed archive was accepted")
    }

    private static func testAutonomySessionRoundTripAndBounds() throws {
        let start = ROBAutonomySessionMessage.start(
            sessionID: "autonomy-1",
            sequence: 1,
            senderID: "controller-1",
            recipientID: "cerebro-1",
            profile: .socialRoam,
            zoneRadiusMeters: 5,
            maximumSpeedScale: 0.2,
            behaviors: ["talk", "look_at_person", "idle_gesture", "roam", "stop_motion"],
            expiresAt: Date(timeIntervalSinceNow: 8 * 60 * 60)
        )
        let archive = try require(
            ROBAutonomySessionWireCodec.archive(start, legacySender: start.senderID),
            "Could not encode a valid autonomy start"
        )
        let decoded = try require(
            ROBAutonomySessionWireCodec.decodeEnvelopeData(archive),
            "Could not decode a valid autonomy start"
        )
        try expect(decoded.kind == .start, "Autonomy start kind changed")
        try expect(decoded.profile == .socialRoam, "Autonomy profile changed")
        try expect(decoded.zoneRadiusMeters == 5, "Autonomy radius changed")
        try expect(decoded.maximumSpeedScale == 0.2, "Autonomy speed changed")
        try expect(decoded.behaviors.contains("roam"), "Autonomy behaviors changed")

        let invalidRadius = ROBAutonomySessionMessage.start(
            sessionID: "autonomy-invalid",
            sequence: 1,
            senderID: "controller-1",
            recipientID: "cerebro-1",
            profile: .socialRoam,
            zoneRadiusMeters: 100,
            maximumSpeedScale: 0.2,
            behaviors: ["roam"],
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        try expect(invalidRadius.validationError != nil, "Oversized autonomy zone was accepted")
        try expect(
            ROBAutonomySessionWireCodec.archive(invalidRadius, legacySender: invalidRadius.senderID) == nil,
            "Invalid autonomy request was serialized"
        )
        try expect(
            ROBAutonomySessionWireCodec.archive(start, legacySender: "spoofed-controller") == nil,
            "Autonomy envelope sender binding was not enforced"
        )

        let stop = ROBAutonomySessionMessage.stop(
            sessionID: start.sessionID,
            sequence: 2,
            senderID: start.senderID,
            recipientID: start.recipientID,
            reason: "Operator stopped autonomy"
        )
        let stopArchive = try require(
            ROBAutonomySessionWireCodec.archive(stop, legacySender: stop.senderID),
            "Could not encode autonomy stop"
        )
        let decodedStop = try require(
            ROBAutonomySessionWireCodec.decodeEnvelopeData(stopArchive),
            "Could not decode autonomy stop"
        )
        try expect(decodedStop.kind == .stop && decodedStop.sequence == 2, "Autonomy stop changed")
    }

    private final class AutonomyDelegate: NSObject, ROBAutonomyCoordinatorDelegate {
        var commands: [(Double, Double, Double)] = []
        var statuses: [ROBAutonomySessionMessage] = []
        var stopCount = 0

        func autonomyCoordinator(
            _ coordinator: ROBAutonomyCoordinator,
            applyLeftTread leftTread: Double,
            rightTread: Double,
            speedScale: Double
        ) {
            commands.append((leftTread, rightTread, speedScale))
        }

        func autonomyCoordinatorDidRequestBaseStop(_ coordinator: ROBAutonomyCoordinator) {
            stopCount += 1
        }

        func autonomyCoordinator(
            _ coordinator: ROBAutonomyCoordinator,
            publishStatus status: ROBAutonomySessionMessage
        ) {
            statuses.append(status)
        }

        func autonomyCoordinator(
            _ coordinator: ROBAutonomyCoordinator,
            requestConversationPrompt prompt: String
        ) {}
    }

    private static func testAutonomyCoordinatorSessionAndLidar() throws {
        let delegate = AutonomyDelegate()
        let coordinator = ROBAutonomyCoordinator(robotID: "cerebro-1")
        coordinator.delegate = delegate
        coordinator.updateLidarPayload(
            "0:0:0\n0:0:0\n" +
            ["2.0:-1.2", "2.0:-0.8", "2.0:-0.4", "2.0:-0.1", "2.0:0.1", "2.0:0.4", "2.0:0.8", "2.0:1.2"]
                .joined(separator: "\n")
        )
        let start = ROBAutonomySessionMessage.start(
            sessionID: "autonomy-coordinator",
            sequence: 1,
            senderID: "controller-1",
            recipientID: "cerebro-1",
            profile: .socialRoam,
            zoneRadiusMeters: 5,
            maximumSpeedScale: 0.2,
            behaviors: ["roam", "talk", "stop_motion"],
            expiresAt: Date(timeIntervalSinceNow: 60)
        )
        coordinator.handleSessionMessage(start)
        try expect(coordinator.active, "Coordinator did not activate")
        try expect(!delegate.commands.isEmpty, "Fresh clear Lidar did not produce a roam command")
        try expect(delegate.statuses.last?.state == .active, "Coordinator did not publish active status")

        // Duplicate start is idempotent and must not create a second session.
        coordinator.handleSessionMessage(start)
        try expect(coordinator.sessionID == start.sessionID, "Duplicate start replaced the session")

        let stop = ROBAutonomySessionMessage.stop(
            sessionID: start.sessionID,
            sequence: 2,
            senderID: start.senderID,
            recipientID: start.recipientID,
            reason: "Fixture stop"
        )
        coordinator.handleSessionMessage(stop)
        try expect(!coordinator.active, "Coordinator did not stop")
        try expect(delegate.stopCount > 0, "Coordinator stop did not reach the actuator delegate")
        try expect(delegate.statuses.last?.state == .inactive, "Coordinator did not publish inactive status")
    }

    private static func roundTrip(_ message: ROBRobotActionMessage) throws -> ROBRobotActionMessage {
        let archive = try require(
            ROBRobotActionWireCodec.archive(message, legacySender: message.senderID),
            "Could not archive message: \(message.validationError ?? "unknown validation error")"
        )
        return try require(
            ROBRobotActionWireCodec.decodeEnvelopeData(archive),
            "Could not decode archived message"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw FixtureFailure.failed(message)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw FixtureFailure.failed(message)
        }
        return value
    }
}
