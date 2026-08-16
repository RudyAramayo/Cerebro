import Foundation

private enum GripperFixtureFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let detail): detail }
    }
}

@main
struct ROBGripperControlProtocolFixtureTests {
    private static let now: Int64 = 1_725_000_000_000
    private static let controllerID = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!
    private static let sessionID = UUID(
        uuidString: "12345678-1234-5678-9abc-def012345678"
    )!

    static func main() throws {
        try commandRoundTripAndBounds()
        try stateAndDispositionStayUnverified()
        try schemaAndRoutingFailClosed()
        print("ROB gripper-control/1 protocol fixtures passed")
    }

    private static func commandRoundTripAndBounds() throws {
        let command = ROBGripperCommandIntentEnvelope(
            senderID: controllerID,
            sessionID: sessionID,
            sequence: 7,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 750,
            arm: .right,
            action: .hold,
            force: 12,
            deadManHeld: true
        )
        let data = try ROBGripperControlWireCodec.encode(
            command,
            nowUnixMilliseconds: now
        )
        guard case .commandIntent(let decoded)? = try ROBGripperControlWireCodec.decode(
            data,
            nowUnixMilliseconds: now
        ) else {
            throw GripperFixtureFailure.failed("Command intent did not decode")
        }
        try expect(decoded == command, "Command intent changed during round-trip")

        for force in [1, 21] {
            let invalid = ROBGripperCommandIntentEnvelope(
                senderID: controllerID,
                sessionID: sessionID,
                sequence: 8,
                issuedAtUnixMilliseconds: now,
                leaseMilliseconds: 750,
                arm: .left,
                action: .hold,
                force: force,
                deadManHeld: true
            )
            try expect(invalid.boundsValidationError != nil, "Unsafe Vision force was valid")
        }
        let expired = ROBGripperCommandIntentEnvelope(
            senderID: controllerID,
            sessionID: sessionID,
            sequence: 9,
            issuedAtUnixMilliseconds: now - 751,
            leaseMilliseconds: 750,
            arm: .left,
            action: .release,
            force: 5,
            deadManHeld: true
        )
        try expectThrows("Expired gripper command decoded") {
            _ = try ROBGripperControlWireCodec.decode(
                JSONEncoder().encode(expired),
                nowUnixMilliseconds: now
            )
        }
    }

    private static func stateAndDispositionStayUnverified() throws {
        let state = ROBGripperStateEnvelope(
            arm: .left,
            sequence: 2,
            sampledAtUnixMilliseconds: now,
            calibrationState: .commandAcceptedUnverified,
            calibrationVerified: false,
            feedbackAvailable: false,
            commandInFlight: false,
            lastAction: .hold,
            lastForce: 10,
            detail: "Amber accepted dispatch; physical completion is unverified."
        )
        let data = try ROBGripperControlWireCodec.encode(state)
        guard case .state(let decoded)? = try ROBGripperControlWireCodec.decode(data) else {
            throw GripperFixtureFailure.failed("State did not decode")
        }
        try expect(decoded == state, "State changed during round-trip")
        try expect(!decoded.calibrationVerified, "State claimed verified calibration")
        try expect(!decoded.feedbackAvailable, "State falsely claimed measured feedback")

        let falseState = ROBGripperStateEnvelope(
            arm: .right,
            sequence: 1,
            sampledAtUnixMilliseconds: now,
            calibrationState: .commandAcceptedUnverified,
            calibrationVerified: true,
            feedbackAvailable: false,
            commandInFlight: false,
            lastAction: nil,
            lastForce: nil,
            detail: "False verification"
        )
        try expectThrows("Protocol v1 encoded false calibration verification") {
            _ = try ROBGripperControlWireCodec.encode(falseState)
        }

        let disposition = ROBGripperCommandDispositionEnvelope(
            requestMessageID: UUID(),
            recipientID: controllerID,
            sessionID: sessionID,
            arm: .right,
            receivedAtUnixMilliseconds: now,
            disposition: .dispatchAcknowledgedUnverified,
            detail: "Core dispatch acknowledged; completion unverified.",
            calibrationState: .commandAcceptedUnverified,
            action: .hold,
            force: 8
        )
        let dispositionData = try ROBGripperControlWireCodec.encode(disposition)
        guard case .commandDisposition(let decodedDisposition)? =
                try ROBGripperControlWireCodec.decode(dispositionData) else {
            throw GripperFixtureFailure.failed("Disposition did not decode")
        }
        try expect(decodedDisposition == disposition, "Disposition changed")
    }

    private static func schemaAndRoutingFailClosed() throws {
        let command = ROBGripperCommandIntentEnvelope(
            senderID: controllerID,
            sessionID: sessionID,
            sequence: 10,
            issuedAtUnixMilliseconds: now,
            leaseMilliseconds: 750,
            arm: .left,
            action: .release,
            force: 5,
            deadManHeld: true
        )
        var object = try jsonObject(
            ROBGripperControlWireCodec.encode(command, nowUnixMilliseconds: now)
        )
        object["raw_joint_8"] = 1
        try expectThrows("Unknown raw gripper field was accepted") {
            _ = try ROBGripperControlWireCodec.decode(
                JSONSerialization.data(withJSONObject: object),
                nowUnixMilliseconds: now
            )
        }

        let malformed = Data(#"{"x":0,"protocol" : "rob-gripper-control/1""#.utf8)
        try expect(
            ROBGripperControlWireCodec.claimsProtocolForRouting(malformed),
            "Malformed claimed gripper frame could fall through"
        )
        var oversized = Data(repeating: 0x20, count: 8 * 1_024)
        oversized.append(Data(#"{"protocol":"rob-gripper-control/1"}"#.utf8))
        try expect(
            ROBGripperControlWireCodec.claimsProtocolForRouting(oversized),
            "Oversized claimed gripper frame could fall through"
        )
        try expectThrows("Oversized gripper frame decoded") {
            _ = try ROBGripperControlWireCodec.decode(oversized)
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GripperFixtureFailure.failed("Fixture was not a JSON object") }
        return object
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw GripperFixtureFailure.failed(detail) }
    }

    private static func expectThrows(_ detail: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw GripperFixtureFailure.failed(detail)
        } catch is GripperFixtureFailure {
            throw GripperFixtureFailure.failed(detail)
        } catch {}
    }
}
