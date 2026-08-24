import Foundation

private enum DesktopFixtureFailure: Error { case failed(String) }

@main
struct ROBRemoteDesktopControlProtocolFixtureTests {
    static func main() throws {
        try lifecycleAndPointerRoundTrip()
        try unicodeAndKeysRoundTrip()
        try malformedMessagesFailClosed()
        print("ROB remote desktop control protocol fixtures passed")
    }

    private static func lifecycleAndPointerRoundTrip() throws {
        for message in [
            ROBRemoteDesktopControlMessage(kind: .start, sequence: 1),
            ROBRemoteDesktopControlMessage(
                kind: .pointerMoved,
                sequence: 2,
                normalizedX: 32_768,
                normalizedY: 16_384
            ),
            ROBRemoteDesktopControlMessage(
                kind: .scroll,
                sequence: 3,
                normalizedX: 20_000,
                normalizedY: 30_000,
                scrollX: -12,
                scrollY: 48
            ),
            ROBRemoteDesktopControlMessage(kind: .stop, sequence: 4)
        ] {
            let encoded = try ROBRemoteDesktopControlProtocol.encode(message)
            try expect(ROBRemoteDesktopControlProtocol.claimsProtocol(encoded), "Frame was not claimed")
            try expect(
                try ROBRemoteDesktopControlProtocol.decode(encoded) == message,
                "Desktop message changed during round-trip"
            )
        }
    }

    private static func unicodeAndKeysRoundTrip() throws {
        let text = ROBRemoteDesktopControlMessage(
            kind: .text,
            sequence: 5,
            payload: Data("Rudy 🤖 — Cerebro".utf8)
        )
        try expect(
            try ROBRemoteDesktopControlProtocol.decode(
                ROBRemoteDesktopControlProtocol.encode(text)
            ) == text,
            "Unicode desktop input changed during round-trip"
        )
        let shortcut = ROBRemoteDesktopControlMessage(
            kind: .key,
            sequence: 6,
            modifiers: ROBRemoteDesktopControlProtocol.modifierCommand,
            key: .letterA
        )
        try expect(
            try ROBRemoteDesktopControlProtocol.decode(
                ROBRemoteDesktopControlProtocol.encode(shortcut)
            ) == shortcut,
            "Desktop shortcut changed during round-trip"
        )
    }

    private static func malformedMessagesFailClosed() throws {
        let malformed = Data("ROBDESK1not-json".utf8)
        try expect(
            ROBRemoteDesktopControlProtocol.claimsProtocol(malformed),
            "Malformed desktop data could fall through to robot command parsing"
        )
        try expectThrows("Malformed desktop JSON decoded") {
            _ = try ROBRemoteDesktopControlProtocol.decode(malformed)
        }
        try expectThrows("Oversized synthesized text encoded") {
            _ = try ROBRemoteDesktopControlProtocol.encode(
                ROBRemoteDesktopControlMessage(
                    kind: .text,
                    sequence: 7,
                    payload: Data(repeating: 0x61, count: 4_097)
                )
            )
        }
        try expectThrows("Unknown modifier bits encoded") {
            _ = try ROBRemoteDesktopControlProtocol.encode(
                ROBRemoteDesktopControlMessage(
                    kind: .key,
                    sequence: 8,
                    modifiers: 0x80,
                    key: .escape
                )
            )
        }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw DesktopFixtureFailure.failed(message) }
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw DesktopFixtureFailure.failed(message)
        } catch is DesktopFixtureFailure {
            throw DesktopFixtureFailure.failed(message)
        } catch {}
    }
}
