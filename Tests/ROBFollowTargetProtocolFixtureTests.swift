import Foundation

private enum FollowFixtureFailure: Error { case failed(String) }

@main
struct ROBFollowTargetProtocolFixtureTests {
    static func main() throws {
        let controller = UUID()
        let session = UUID()
        let request = UUID()
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let candidate = ROBFollowTargetCandidate(
            id: UUID(), x: 1_000, y: 900, width: 2_400, height: 7_800,
            confidencePermille: 940, distanceMillimeters: 1_850
        )
        let messages = [
            ROBFollowTargetMessage(
                kind: .previewRequest, requestID: request, controllerID: controller,
                sessionID: session, sequence: 1, sentAtMilliseconds: now
            ),
            ROBFollowTargetMessage(
                kind: .preview, requestID: request, controllerID: controller,
                sessionID: session, sequence: 2, sentAtMilliseconds: now,
                state: .previewReady, detail: "Select a person",
                previewJPEG: Data([0xff, 0xd8, 0xff, 0xd9]), candidates: [candidate]
            ),
            ROBFollowTargetMessage(
                kind: .authorize, requestID: request, controllerID: controller,
                sessionID: session, sequence: 3, sentAtMilliseconds: now,
                selectedCandidateID: candidate.id
            ),
            ROBFollowTargetMessage(
                kind: .status, requestID: request, controllerID: controller,
                sessionID: session, sequence: 4, sentAtMilliseconds: now,
                state: .following, detail: "Main camera locked"
            ),
            ROBFollowTargetMessage(
                kind: .stop, requestID: request, controllerID: controller,
                sessionID: session, sequence: 5, sentAtMilliseconds: now,
                detail: "Operator stop"
            )
        ]
        for message in messages {
            let encoded = try ROBFollowTargetProtocol.encode(message)
            try expect(ROBFollowTargetProtocol.claimsProtocol(encoded), "Follow frame was not claimed")
            try expect(try ROBFollowTargetProtocol.decode(encoded) == message, "Follow frame changed during round trip")
        }
        try expect(
            ROBFollowTargetProtocol.isFresh(messages[0], nowMilliseconds: now + 14_999),
            "Fresh visual selection was rejected"
        )
        try expect(
            !ROBFollowTargetProtocol.isFresh(messages[0], nowMilliseconds: now + 15_001),
            "Expired visual selection was accepted"
        )
        try expectThrows("Out-of-bounds person rectangle encoded") {
            _ = try ROBFollowTargetProtocol.encode(ROBFollowTargetMessage(
                kind: .preview, requestID: request, controllerID: controller,
                sessionID: session, sequence: 6, sentAtMilliseconds: now,
                state: .previewReady, previewJPEG: Data([1]), candidates: [
                    ROBFollowTargetCandidate(
                        id: UUID(), x: 9_000, y: 0, width: 2_000, height: 5_000,
                        confidencePermille: 900, distanceMillimeters: nil
                    )
                ]
            ))
        }
        let malformed = Data("ROBFOLLOW1not-json".utf8)
        try expect(ROBFollowTargetProtocol.claimsProtocol(malformed), "Malformed follow frame could fall through")
        try expectThrows("Malformed follow JSON decoded") {
            _ = try ROBFollowTargetProtocol.decode(malformed)
        }
        print("ROB follow-target protocol fixtures passed")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw FollowFixtureFailure.failed(message) }
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw FollowFixtureFailure.failed(message)
        } catch is FollowFixtureFailure {
            throw FollowFixtureFailure.failed(message)
        } catch {}
    }
}
