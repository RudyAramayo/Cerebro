import Foundation

private enum TerminalFixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case .failed(let detail): return detail }
    }
}

@main
struct ROBAdministratorTerminalProtocolFixtureTests {
    private static let terminalID = UUID(
        uuidString: "12345678-1234-5678-9abc-def012345678"
    )!

    static func main() throws {
        try openRoundTripCarriesResumeAcknowledgement()
        try arbitraryTerminalBytesRoundTrip()
        try boundsAndDirectionFailClosed()
        try discriminatorClaimsMalformedFrames()
        print("ROB administrator-terminal/1 protocol fixtures passed")
    }

    private static func openRoundTripCarriesResumeAcknowledgement() throws {
        let request = ROBAdministratorTerminalMessage(
            kind: .open,
            terminalID: terminalID,
            sequence: 7,
            columns: 132,
            rows: 44,
            payload: ROBAdministratorTerminalProtocol.acknowledgementPayload(91)
        )
        let encoded = try ROBAdministratorTerminalProtocol.encode(request)
        let decoded = try ROBAdministratorTerminalProtocol.decode(encoded)
        try expect(decoded == request, "Open request changed during round-trip")
        try expect(
            ROBAdministratorTerminalProtocol.acknowledgement(from: decoded.payload) == 91,
            "Resume acknowledgement changed during round-trip"
        )
    }

    private static func arbitraryTerminalBytesRoundTrip() throws {
        let bytes = Data([0x00, 0x1b, 0x5b, 0x41, 0x0d, 0x0a, 0x80, 0xff])
        for kind in [ROBAdministratorTerminalMessageKind.input, .output] {
            let message = ROBAdministratorTerminalMessage(
                kind: kind,
                terminalID: terminalID,
                sequence: 8,
                columns: 0,
                rows: 0,
                payload: bytes
            )
            try expect(
                try ROBAdministratorTerminalProtocol.decode(
                    ROBAdministratorTerminalProtocol.encode(message)
                ) == message,
                "\(kind) changed arbitrary PTY bytes"
            )
        }
    }

    private static func boundsAndDirectionFailClosed() throws {
        let oversized = ROBAdministratorTerminalMessage(
            kind: .input,
            terminalID: terminalID,
            sequence: 1,
            columns: 0,
            rows: 0,
            payload: Data(repeating: 0x61, count: ROBAdministratorTerminalProtocol.maximumPayloadBytes + 1)
        )
        try expectThrows("Oversized terminal input encoded") {
            _ = try ROBAdministratorTerminalProtocol.encode(oversized)
        }

        let invalidResize = ROBAdministratorTerminalMessage(
            kind: .resize,
            terminalID: terminalID,
            sequence: 2,
            columns: 2,
            rows: 1,
            payload: Data()
        )
        try expectThrows("Unsafe terminal dimensions encoded") {
            _ = try ROBAdministratorTerminalProtocol.encode(invalidResize)
        }

        let invalidOutput = ROBAdministratorTerminalMessage(
            kind: .output,
            terminalID: terminalID,
            sequence: 3,
            columns: 80,
            rows: 24,
            payload: Data("output".utf8)
        )
        try expectThrows("Server output with request dimensions encoded") {
            _ = try ROBAdministratorTerminalProtocol.encode(invalidOutput)
        }
    }

    private static func discriminatorClaimsMalformedFrames() throws {
        let malformed = Data("ROBTPTY1bad".utf8)
        try expect(
            ROBAdministratorTerminalProtocol.claimsProtocol(malformed),
            "Malformed terminal frame could fall through to another protocol"
        )
        try expectThrows("Malformed claimed terminal frame decoded") {
            _ = try ROBAdministratorTerminalProtocol.decode(malformed)
        }
        try expect(
            !ROBAdministratorTerminalProtocol.claimsProtocol(Data("robot motion".utf8)),
            "Unrelated robot data was claimed as terminal traffic"
        )
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
        guard try condition() else { throw TerminalFixtureFailure.failed(detail) }
    }

    private static func expectThrows(_ detail: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw TerminalFixtureFailure.failed(detail)
        } catch is TerminalFixtureFailure {
            throw TerminalFixtureFailure.failed(detail)
        } catch {}
    }
}
