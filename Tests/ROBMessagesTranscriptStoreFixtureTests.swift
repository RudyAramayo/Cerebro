import Foundation

private enum TranscriptFixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
struct ROBMessagesTranscriptStoreFixtureTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ROBMessagesTranscriptStoreFixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("archive.sqlite3")
        let exportURL = directory.appendingPathComponent("export.json")
        let key = Data((0..<32).map(UInt8.init))
        let store = ROBMessagesTranscriptStore(
            databaseURL: databaseURL,
            encryptionKey: key
        )
        let alice = ROBMessagesTranscriptScope(
            receivingAccount: "rob@orbitusrobotics.com",
            sender: "alice@example.com",
            chatID: "chat-alice"
        )
        let bob = ROBMessagesTranscriptScope(
            receivingAccount: "rob@orbitusrobotics.com",
            sender: "bob@example.com",
            chatID: "chat-bob"
        )
        let aliceOtherAccount = ROBMessagesTranscriptScope(
            receivingAccount: "private-robot@example.com",
            sender: "alice@example.com",
            chatID: "chat-alice-other-account"
        )
        let start = Date(timeIntervalSince1970: 1_787_300_000)

        try store.recordInbound(
            contextID: "messages:alice-1",
            messageGUID: "guid-alice-1",
            scope: alice,
            text: "My daughter's name is Zephyr and she likes astronomy.",
            hasImage: false,
            receivedAt: start
        )
        try store.recordReply(
            contextID: "messages:alice-1",
            text: "I'll remember that within our private Messages archive.",
            createdAt: start.addingTimeInterval(1)
        )
        try store.markDelivered(
            contextID: "messages:alice-1",
            at: start.addingTimeInterval(2)
        )

        try store.recordInbound(
            contextID: "messages:bob-1",
            messageGUID: "guid-bob-1",
            scope: bob,
            text: "My private launch phrase is cobalt lighthouse.",
            hasImage: true,
            receivedAt: start.addingTimeInterval(10)
        )
        try store.recordReply(
            contextID: "messages:bob-1",
            text: "That remains scoped to Bob's sender identity.",
            createdAt: start.addingTimeInterval(11)
        )
        try store.markDelivered(
            contextID: "messages:bob-1",
            at: start.addingTimeInterval(12)
        )

        try store.recordInbound(
            contextID: "messages:alice-other-account",
            messageGUID: "guid-alice-other-account",
            scope: aliceOtherAccount,
            text: "My other-account passphrase is saffron comet.",
            hasImage: false,
            receivedAt: start.addingTimeInterval(15)
        )
        try store.recordReply(
            contextID: "messages:alice-other-account",
            text: "That stays isolated to the other receiving account.",
            createdAt: start.addingTimeInterval(16)
        )
        try store.markDelivered(
            contextID: "messages:alice-other-account",
            at: start.addingTimeInterval(17)
        )

        try store.recordInbound(
            contextID: "messages:alice-failed",
            messageGUID: "guid-alice-failed",
            scope: alice,
            text: "This attempted reply will fail delivery.",
            hasImage: false,
            receivedAt: start.addingTimeInterval(20)
        )
        try store.recordReply(
            contextID: "messages:alice-failed",
            text: "This response was not delivered.",
            createdAt: start.addingTimeInterval(21)
        )
        try store.markFailed(
            contextID: "messages:alice-failed",
            error: "Fixture delivery failure",
            at: start.addingTimeInterval(22)
        )

        let aliceMemory = try require(
            store.memoryContext(
                scope: alice,
                query: "What is my daughter's name?",
                excludingContextID: "messages:new"
            ),
            "Alice memory context was empty"
        )
        try expect(aliceMemory.contains("Zephyr"), "Relevant same-sender fact was not retrieved")
        try expect(
            !aliceMemory.contains("cobalt lighthouse")
                && !aliceMemory.contains("bob@example.com")
                && !aliceMemory.contains("saffron comet"),
            "Another sender or receiving account leaked into Alice's context"
        )
        try expect(
            !aliceMemory.contains("This response was not delivered"),
            "A failed delivery was treated as conversational memory"
        )

        let statistics = try store.statistics()
        try expect(statistics.transactionCount == 4, "Archive transaction count is wrong")
        try expect(statistics.deliveredCount == 3, "Archive delivered count is wrong")

        let browser = try store.browseSnapshot()
        try expect(
            browser.records.count == 4 && !browser.isTruncated,
            "The readable transcript browser snapshot omitted stored transactions"
        )
        let browserAlice = try require(
            browser.records.first(where: { $0.contextID == "messages:alice-1" }),
            "The readable transcript snapshot omitted Alice's delivered turn"
        )
        try expect(
            browserAlice.receivingAccount == "rob@orbitusrobotics.com"
                && browserAlice.sender == "alice@example.com"
                && browserAlice.inboundText.contains("Zephyr")
                && browserAlice.replyText?.contains("remember") == true
                && browserAlice.deliveryStatus == "delivered",
            "The readable transcript snapshot decrypted the wrong fields"
        )
        let boundedBrowser = try store.browseSnapshot(maximumRecords: 2)
        try expect(
            boundedBrowser.records.count == 2 && boundedBrowser.isTruncated,
            "The readable transcript browser did not report bounded truncation"
        )

        let privateNeedles = [
            "alice@example.com", "bob@example.com", "Zephyr",
            "cobalt lighthouse", "saffron comet", "Fixture delivery failure"
        ]
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where FileManager.default.fileExists(atPath: url.path) {
            let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            for needle in privateNeedles {
                try expect(
                    !raw.contains(needle),
                    "Private plaintext '\(needle)' appeared in \(url.lastPathComponent)"
                )
            }
        }

        try store.exportDecryptedJSON(to: exportURL)
        let exported = String(decoding: try Data(contentsOf: exportURL), as: UTF8.self)
        try expect(
            exported.contains("alice@example.com")
                && exported.contains("Zephyr")
                && exported.contains("Fixture delivery failure"),
            "Explicit decrypted export omitted transcript content"
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: exportURL.path)[
            .posixPermissions
        ] as? NSNumber
        try expect(permissions?.intValue == 0o600, "Decrypted export permissions are not 0600")

        try store.deleteAll()
        let cleared = try store.statistics()
        try expect(
            cleared.transactionCount == 0 && cleared.deliveredCount == 0,
            "Clear transcript did not remove every transaction"
        )
        let clearedBrowser = try store.browseSnapshot()
        try expect(
            clearedBrowser.records.isEmpty,
            "The readable transcript browser retained cleared transactions"
        )
        print("ROB encrypted Messages transcript fixtures passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() { throw TranscriptFixtureFailure.failed(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TranscriptFixtureFailure.failed(message) }
        return value
    }
}
