import Foundation
import SQLite3

private let FixtureSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

private enum ProductionFixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

// Test double compiled in place of Cerebro/ROBMessagesAIResponder.swift. This
// lets the real bridge and inbox run without opening Gemini or Messages.
struct ROBMessagesAIStatusSnapshot: Sendable {
    let isConfigured: Bool
    let activeChatCount: Int
    let pendingTurnCount: Int
    let readyChatCount: Int
    let activeProvider: String?
    let lastProvider: String?
    let lastError: String?
}

@MainActor
final class ROBMessagesAIResponder: NSObject {
    typealias Completion = @MainActor (Result<String, Error>) -> Void

    struct Submission {
        let prompt: String
        let chatID: String
        let contextID: String
    }

    private(set) var submissions: [Submission] = []
    private(set) var shutdownCount = 0
    private var completions: [String: Completion] = [:]

    override init() {
        super.init()
    }

    func submit(
        prompt: String,
        chatID: String,
        contextID: String,
        completion: @escaping Completion
    ) {
        submissions.append(.init(prompt: prompt, chatID: chatID, contextID: contextID))
        completions[contextID] = completion
    }

    func shutdown() {
        shutdownCount += 1
        let pending = completions.values
        completions.removeAll()
        for completion in pending {
            completion(.failure(ProductionFixtureFailure.failed("Fixture AI stopped")))
        }
    }

    func statusSnapshot() -> ROBMessagesAIStatusSnapshot {
        ROBMessagesAIStatusSnapshot(
            isConfigured: true,
            activeChatCount: Set(submissions.map(\.chatID)).count,
            pendingTurnCount: completions.count,
            readyChatCount: Set(submissions.map(\.chatID)).count,
            activeProvider: nil,
            lastProvider: nil,
            lastError: nil
        )
    }

    @discardableResult
    func complete(contextID: String, response: String) -> Bool {
        guard let completion = completions.removeValue(forKey: contextID) else {
            return false
        }
        completion(.success(response))
        return true
    }
}

private final class FixtureReplySender: ROBMessagesReplySending, @unchecked Sendable {
    struct Reply: Equatable {
        let text: String
        let chatID: String
        let account: String
        let expectedSender: String
    }

    private let lock = NSLock()
    private var replies: [Reply] = []

    func send(
        text: String,
        toChat chatID: String,
        account: String,
        expectedSender: String
    ) {
        lock.lock()
        replies.append(.init(
            text: text,
            chatID: chatID,
            account: account,
            expectedSender: expectedSender
        ))
        lock.unlock()
    }

    func snapshot() -> [Reply] {
        lock.lock()
        defer { lock.unlock() }
        return replies
    }
}

private final class FixtureMessagesDatabase {
    let url: URL
    private let directoryURL: URL
    private var database: OpaquePointer?

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ROBMessagesBridgeFixture-\(UUID().uuidString)", isDirectory: true)
        url = directoryURL.appendingPathComponent("chat.db")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw ProductionFixtureFailure.failed("Could not create the synthetic chat.db")
        }
        sqlite3_busy_timeout(database, 2_000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("""
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            guid TEXT,
            text TEXT,
            attributedBody BLOB,
            handle_id INTEGER,
            is_from_me INTEGER DEFAULT 0,
            date INTEGER,
            account TEXT,
            destination_caller_id TEXT,
            associated_message_guid TEXT,
            item_type INTEGER DEFAULT 0,
            group_action_type INTEGER DEFAULT 0
        );
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            guid TEXT,
            account_id TEXT,
            last_addressed_handle TEXT
        );
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT
        );
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        """)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func addHandle(_ identifier: String) throws -> Int64 {
        try execute("INSERT INTO handle (id) VALUES (?)", values: [.text(identifier)])
        return sqlite3_last_insert_rowid(database)
    }

    func addChat(guid: String, account: String, participants: [Int64]) throws -> Int64 {
        try execute(
            "INSERT INTO chat (guid, account_id, last_addressed_handle) VALUES (?, ?, ?)",
            values: [.text(guid), .text("opaque-account-id"), .text(account)]
        )
        let rowID = sqlite3_last_insert_rowid(database)
        for participant in participants {
            try execute(
                "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)",
                values: [.integer(rowID), .integer(participant)]
            )
        }
        return rowID
    }

    @discardableResult
    func addMessage(
        guid: String,
        text: String?,
        senderHandleRowID: Int64,
        chatRowID: Int64,
        account: String,
        isFromMe: Bool = false,
        attributedBody: Data? = nil,
        date: Date? = Date()
    ) throws -> Int64 {
        let messagesDate = date.map {
            Value.integer(Int64($0.timeIntervalSinceReferenceDate * 1_000_000_000))
        } ?? .null
        try execute(
            """
            INSERT INTO message
                (guid, text, attributedBody, handle_id, is_from_me, date, account,
                 destination_caller_id, associated_message_guid, item_type, group_action_type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, '', 0, 0)
            """,
            values: [
                .text(guid),
                text.map(Value.text) ?? .null,
                attributedBody.map(Value.blob) ?? .null,
                .integer(senderHandleRowID),
                .integer(isFromMe ? 1 : 0),
                messagesDate,
                .text(account),
                .text(account),
            ]
        )
        let rowID = sqlite3_last_insert_rowid(database)
        try execute(
            "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
            values: [.integer(chatRowID), .integer(rowID)]
        )
        return rowID
    }

    func addAttachment(to messageRowID: Int64, attachmentID: Int64 = 1) throws {
        try execute(
            "INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)",
            values: [.integer(messageRowID), .integer(attachmentID)]
        )
    }

    func joinMessage(_ messageRowID: Int64, toChat chatRowID: Int64) throws {
        try execute(
            "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
            values: [.integer(chatRowID), .integer(messageRowID)]
        )
    }

    private enum Value {
        case text(String)
        case integer(Int64)
        case blob(Data)
        case null
    }

    private func execute(_ sql: String, values: [Value] = []) throws {
        guard let database else {
            throw ProductionFixtureFailure.failed("Synthetic chat.db was closed")
        }
        if values.isEmpty {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
            defer { sqlite3_free(errorMessage) }
            guard result == SQLITE_OK else {
                let detail = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
                throw ProductionFixtureFailure.failed(detail)
            }
            return
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ProductionFixtureFailure.failed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string):
                let utf8 = Data(string.utf8)
                _ = utf8.withUnsafeBytes { bytes in
                    sqlite3_bind_text(
                        statement,
                        index,
                        bytes.bindMemory(to: CChar.self).baseAddress,
                        Int32(bytes.count),
                        FixtureSQLiteTransient
                    )
                }
            case .integer(let integer):
                sqlite3_bind_int64(statement, index, integer)
            case .blob(let data):
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        FixtureSQLiteTransient
                    )
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ProductionFixtureFailure.failed(String(cString: sqlite3_errmsg(database)))
        }
    }
}

@main
@MainActor
private struct ROBMessagesBridgeProductionFixtureTests {
    private static let account = "rob@orbitusrobotics.com"
    private static let defaultsKeys = [
        "ROBMessagesBridgeEnabled",
        "ROBMessagesBridgeReceivingAccount",
        "ROBMessagesBridgeAllowedSenders",
        "ROBMessagesBridgeAllowAllSenders",
        "ROBMessagesBridgeLastMessageRowID",
        "ROBMessagesBridgeRecentMessageGUIDs",
    ]

    static func main() async throws {
        try expect(
            Bundle.main.bundleIdentifier != "com.orbitusrobotics.Cerebro",
            "The fixture must run as its standalone test executable, not inside Cerebro"
        )
        try testAttributedBodyDecoder()
        try testAttributedBodyInboxSelection()
        try expect(
            ROBMessagesBridgeConfiguration.canonicalHandle("+1 (925) 323-8322")
                == "+19253238322",
            "Formatted E.164 sender handles are not canonicalized"
        )
        resetFixtureDefaults()
        defer { resetFixtureDefaults() }

        let database = try FixtureMessagesDatabase()
        let owner = try database.addHandle("owner@example.com")
        let trustedFriend = try database.addHandle("friend@example.com")
        let outsider = try database.addHandle("outsider@example.com")
        let localAccountHandle = try database.addHandle(account)
        let chatA = try database.addChat(
            guid: "fixture-chat-A",
            account: account,
            participants: [owner]
        )
        let chatB = try database.addChat(
            guid: "fixture-chat-B",
            account: account,
            participants: [trustedFriend]
        )
        let outsiderChat = try database.addChat(
            guid: "fixture-outsider-chat",
            account: account,
            participants: [outsider]
        )
        let wrongAccountChat = try database.addChat(
            guid: "fixture-wrong-account-chat",
            account: "other@example.com",
            participants: [owner]
        )
        let groupChat = try database.addChat(
            guid: "fixture-group-chat",
            account: account,
            participants: [owner, trustedFriend]
        )
        let selfHandleChat = try database.addChat(
            guid: "fixture-self-handle-chat",
            account: account,
            participants: [localAccountHandle]
        )
        let historicalRowID = try database.addMessage(
            guid: "historical-guid",
            text: "Do not replay history",
            senderHandleRowID: owner,
            chatRowID: chatA,
            account: account
        )

        ROBMessagesBridge.setConfiguredAccountIdentifier(account)
        ROBMessagesBridge.setConfiguredAllowedSendersText(
            "owner@example.com\nfriend@example.com"
        )
        ROBMessagesBridge.setConfiguredEnabled(true)

        let ai = ROBMessagesAIResponder()
        let replies = FixtureReplySender()
        let inbox = ROBMessagesSQLiteInbox(databaseURL: database.url)
        var automationPermissionChecks: [Bool] = []
        let bridge = ROBMessagesBridge(
            inbox: inbox,
            replySender: replies,
            aiResponder: ai,
            automationPermissionCheck: { askUserIfNeeded in
                automationPermissionChecks.append(askUserIfNeeded)
                return nil
            }
        )
        bridge.start()
        defer { bridge.stop() }

        try await waitUntil("The production bridge did not seed its first-start cursor") {
            bridge.statusSnapshot().state == "listening"
        }
        let listeningStatus = bridge.statusSnapshot()
        try expect(
            automationPermissionChecks == [false],
            "Bridge initialization did not perform one non-prompting Automation check"
        )
        try expect(!listeningStatus.allowAllSenders, "Restricted mode was reported as public")
        try expect(listeningStatus.activeAIProvider == nil, "A fixture AI provider was reported active")
        try expect(listeningStatus.lastAIProvider == nil, "A fixture AI provider was reported as last")
        try expect(listeningStatus.lastAIError == nil, "A fixture AI error was reported")
        try expect(listeningStatus.lastDeliveryError == nil, "A fixture delivery error was reported")
        try expect(
            ROBMessagesReplyError.failed("Originating chat participant changed\n")
                .diagnosticDescription == "Originating chat participant changed",
            "Messages delivery diagnostics were not flattened safely"
        )
        try expect(
            ai.submissions.isEmpty,
            "First startup replayed an existing Messages history row into the AI"
        )
        try expect(
            UserDefaults.standard.object(forKey: "ROBMessagesBridgeLastMessageRowID") as? Int64
                == historicalRowID,
            "The production bridge did not persist the initial high-water row"
        )

        let validARow = try database.addMessage(
            guid: "valid-A-guid",
            text: "Question A",
            senderHandleRowID: owner,
            chatRowID: chatA,
            account: account
        )
        _ = try database.addMessage(
            guid: "valid-B-guid",
            text: "Question B",
            senderHandleRowID: trustedFriend,
            chatRowID: chatB,
            account: account
        )
        _ = try database.addMessage(
            guid: "wrong-account-guid",
            text: "Wrong account",
            senderHandleRowID: owner,
            chatRowID: wrongAccountChat,
            account: "other@example.com"
        )
        _ = try database.addMessage(
            guid: "unapproved-sender-guid",
            text: "Unapproved sender",
            senderHandleRowID: outsider,
            chatRowID: outsiderChat,
            account: account
        )
        _ = try database.addMessage(
            guid: "group-guid",
            text: "Group message",
            senderHandleRowID: owner,
            chatRowID: groupChat,
            account: account
        )
        _ = try database.addMessage(
            guid: "outbound-guid",
            text: "Outbound echo",
            senderHandleRowID: owner,
            chatRowID: chatA,
            account: account,
            isFromMe: true
        )
        _ = try database.addMessage(
            guid: "self-handle-guid",
            text: "Local account must not become a remote sender",
            senderHandleRowID: localAccountHandle,
            chatRowID: selfHandleChat,
            account: account
        )

        let policyBatch = try inbox.messages(after: historicalRowID, limit: 100)
        let policyConfiguration = ROBMessagesBridgeConfiguration(
            enabled: true,
            receivingAccount: account,
            allowedSenders: ["owner@example.com", "friend@example.com"],
            allowAllSenders: false
        )
        let rejectionByGUID = Dictionary(uniqueKeysWithValues: policyBatch.messages.map {
            (
                $0.guid,
                ROBMessagesBridgePolicy.rejection(
                    for: $0,
                    configuration: policyConfiguration,
                    now: Date(),
                    seenGUIDs: []
                )
            )
        })
        try expect(rejectionByGUID["valid-A-guid"]! == nil, "A valid account/sender row was rejected")
        try expect(rejectionByGUID["valid-B-guid"]! == nil, "The second approved chat was rejected")
        try expect(
            rejectionByGUID["wrong-account-guid"]! == .wrongAccount,
            "A row for a different receiving account passed policy"
        )
        try expect(
            rejectionByGUID["unapproved-sender-guid"]! == .senderNotAllowed,
            "An unapproved sender passed policy"
        )
        try expect(
            rejectionByGUID["group-guid"]! == .groupChat,
            "A group chat passed the one-to-one policy"
        )
        try expect(
            rejectionByGUID["outbound-guid"]! == .outboundOrSelf,
            "An outgoing echo passed the inbound policy"
        )
        try expect(
            rejectionByGUID["self-handle-guid"]! == .outboundOrSelf,
            "The local receiving account was conflated with a remote sender"
        )

        let senderModeCases: [(
            name: String,
            configuration: ROBMessagesBridgeConfiguration,
            outsiderRejection: ROBMessagesMessageRejection?
        )] = [
            (
                "restricted",
                ROBMessagesBridgeConfiguration(
                    enabled: true,
                    receivingAccount: account,
                    allowedSenders: ["owner@example.com", "friend@example.com"],
                    allowAllSenders: false
                ),
                .senderNotAllowed
            ),
            (
                "public",
                ROBMessagesBridgeConfiguration(
                    enabled: true,
                    receivingAccount: account,
                    allowedSenders: [],
                    allowAllSenders: true
                ),
                nil
            ),
        ]
        for senderMode in senderModeCases {
            func rejection(_ guid: String) -> ROBMessagesMessageRejection? {
                guard let message = policyBatch.messages.first(where: { $0.guid == guid }) else {
                    return .duplicate
                }
                return ROBMessagesBridgePolicy.rejection(
                    for: message,
                    configuration: senderMode.configuration,
                    now: Date(),
                    seenGUIDs: []
                )
            }
            try expect(
                rejection("unapproved-sender-guid") == senderMode.outsiderRejection,
                "\(senderMode.name) sender policy produced the wrong outsider disposition"
            )
            try expect(
                rejection("wrong-account-guid") == .wrongAccount,
                "\(senderMode.name) mode bypassed receiving-account isolation"
            )
            try expect(
                rejection("self-handle-guid") == .outboundOrSelf,
                "\(senderMode.name) mode accepted the local account as a remote sender"
            )
        }

        bridge.reloadConfiguration()
        try await waitUntil("The production bridge did not submit both approved rows") {
            ai.submissions.count == 2
        }
        try expect(
            Set(ai.submissions.map(\.prompt)) == ["Question A", "Question B"],
            "A rejected account, sender, group, or outbound row reached the AI"
        )
        try expect(
            ai.submissions.allSatisfy { $0.contextID.hasPrefix("messages:") },
            "A production Messages request lost its protected context prefix"
        )

        let submissionByPrompt = Dictionary(
            uniqueKeysWithValues: ai.submissions.map { ($0.prompt, $0) }
        )
        let requestA = try require(submissionByPrompt["Question A"], "Missing request A")
        let requestB = try require(submissionByPrompt["Question B"], "Missing request B")
        try expect(
            ai.complete(contextID: requestB.contextID, response: "Answer B"),
            "Could not finish fixture request B"
        )
        try await waitUntil("Reply B was not sent") { replies.snapshot().count == 1 }
        try expect(
            ai.complete(contextID: requestA.contextID, response: "Answer A"),
            "Could not finish fixture request A"
        )
        try await waitUntil("Reply A was not sent") { replies.snapshot().count == 2 }
        try expect(
            replies.snapshot() == [
                .init(
                    text: "Answer B",
                    chatID: "fixture-chat-B",
                    account: account,
                    expectedSender: "friend@example.com"
                ),
                .init(
                    text: "Answer A",
                    chatID: "fixture-chat-A",
                    account: account,
                    expectedSender: "owner@example.com"
                ),
            ],
            "Concurrent production replies crossed chats, accounts, or expected participants"
        )

        _ = try database.addMessage(
            guid: "valid-A-guid",
            text: "Duplicate GUID",
            senderHandleRowID: owner,
            chatRowID: chatA,
            account: account
        )
        bridge.reloadConfiguration()
        try await waitUntil("The duplicate fixture row was not polled") {
            let cursor = UserDefaults.standard.object(
                forKey: "ROBMessagesBridgeLastMessageRowID"
            ) as? Int64
            return cursor.map { $0 > validARow } ?? false
        }
        try expect(ai.submissions.count == 2, "A persisted duplicate GUID reached the AI twice")

        _ = try database.addMessage(
            guid: "pending-settings-guid",
            text: "Cancel on settings change",
            senderHandleRowID: owner,
            chatRowID: chatA,
            account: account
        )
        bridge.reloadConfiguration()
        try await waitUntil("The settings-cancellation request was not submitted") {
            ai.submissions.count == 3
        }
        let settingsRequest = ai.submissions[2]
        let repliesBeforeSettingsChange = replies.snapshot().count
        let shutdownsBeforeSettingsChange = ai.shutdownCount
        ROBMessagesBridge.setConfiguredAccountIdentifier("replacement@example.com")
        try await waitUntil("Account settings did not reload the bridge") {
            bridge.statusSnapshot().configuredAccount == "replacement@example.com"
        }
        let lateSettingsCompletion = ai.complete(
            contextID: settingsRequest.contextID,
            response: "Must not escape after account change"
        )
        try await settleWorkerQueues()
        try expect(
            bridge.statusSnapshot().pendingReplyCount == 0,
            "An account settings change retained a pending route"
        )
        try expect(
            ai.shutdownCount > shutdownsBeforeSettingsChange,
            "An account settings change did not cancel the isolated AI request"
        )
        try expect(
            !lateSettingsCompletion && replies.snapshot().count == repliesBeforeSettingsChange,
            "A late AI completion escaped after the receiving account changed"
        )

        let reauthorizedHighWater = try inbox.highestRowID()
        ROBMessagesBridge.setConfiguredAccountIdentifier(account)
        try await waitUntil("Reauthorizing the account did not seed a fresh cursor") {
            let savedCursor = UserDefaults.standard.object(
                forKey: "ROBMessagesBridgeLastMessageRowID"
            ) as? Int64
            return bridge.statusSnapshot().state == "listening" &&
                savedCursor == reauthorizedHighWater
        }
        _ = try database.addMessage(
            guid: "pending-disable-guid",
            text: "Cancel on disable",
            senderHandleRowID: owner,
            chatRowID: chatA,
            account: account
        )
        bridge.reloadConfiguration()
        try await waitUntil("The disable-cancellation request was not submitted") {
            ai.submissions.count == 4
        }
        let disableRequest = ai.submissions[3]
        let repliesBeforeDisable = replies.snapshot().count
        let shutdownsBeforeDisable = ai.shutdownCount
        ROBMessagesBridge.setConfiguredEnabled(false)
        try await waitUntil("Disabling did not reload the bridge") {
            bridge.statusSnapshot().state == "disabled"
        }
        let lateDisabledCompletion = ai.complete(
            contextID: disableRequest.contextID,
            response: "Must not escape after disable"
        )
        try await settleWorkerQueues()
        try expect(
            bridge.statusSnapshot().pendingReplyCount == 0,
            "Disabling retained a pending Messages reply route"
        )
        try expect(
            ai.shutdownCount > shutdownsBeforeDisable,
            "Disabling did not cancel the isolated AI request"
        )
        try expect(
            !lateDisabledCompletion && replies.snapshot().count == repliesBeforeDisable,
            "A late AI completion sent a Messages reply after the bridge was disabled"
        )

        let disabledGapRow = try database.addMessage(
            guid: "disabled-gap-guid",
            text: "Must not replay after re-enable",
            senderHandleRowID: owner,
            chatRowID: chatA,
            account: account
        )
        ROBMessagesBridge.setConfiguredEnabled(true)
        try await waitUntil("Re-enabling did not seed past the disabled interval") {
            let savedCursor = UserDefaults.standard.object(
                forKey: "ROBMessagesBridgeLastMessageRowID"
            ) as? Int64
            return bridge.statusSnapshot().state == "listening" && savedCursor == disabledGapRow
        }
        try expect(
            ai.submissions.count == 4,
            "A message received during the disabled interval was replayed into the AI"
        )
        _ = try database.addMessage(
            guid: "post-enable-guid",
            text: "Allowed after re-enable",
            senderHandleRowID: owner,
            chatRowID: chatA,
            account: account
        )
        bridge.reloadConfiguration()
        try await waitUntil("A new post-enable message was not submitted") {
            ai.submissions.count == 5
        }
        try expect(
            ai.submissions.last?.prompt == "Allowed after re-enable",
            "The post-enable prompt was not the newly authorized message"
        )

        ROBMessagesBridge.setConfiguredAllowedSendersText("")
        ROBMessagesBridge.setConfiguredAllowAllSenders(true)
        try await waitUntil("Public mode did not become ready") {
            bridge.statusSnapshot().state == "listening"
                && bridge.statusSnapshot().allowAllSenders
        }
        _ = try database.addMessage(
            guid: "public-reply-guid",
            text: "Public sender reply",
            senderHandleRowID: outsider,
            chatRowID: outsiderChat,
            account: account
        )
        bridge.reloadConfiguration()
        try await waitUntil("A public sender did not reach the AI") {
            ai.submissions.count == 6
        }
        let publicRequest = ai.submissions[5]
        let repliesBeforePublicCompletion = replies.snapshot().count
        try expect(
            ai.complete(contextID: publicRequest.contextID, response: "Public reply"),
            "The public sender AI request could not be completed"
        )
        try await waitUntil("The public sender reply was discarded by the final gate") {
            replies.snapshot().count == repliesBeforePublicCompletion + 1
        }
        try expect(
            replies.snapshot().last?.expectedSender == "outsider@example.com",
            "The public reply lost its immutable originating sender"
        )

        var deniedAutomationChecks: [Bool] = []
        let deniedAutomationBridge = ROBMessagesBridge(
            inbox: inbox,
            replySender: FixtureReplySender(),
            aiResponder: ROBMessagesAIResponder(),
            automationPermissionCheck: { askUserIfNeeded in
                deniedAutomationChecks.append(askUserIfNeeded)
                return "Fixture Automation permission denied"
            }
        )
        deniedAutomationBridge.start()
        try expect(
            deniedAutomationBridge.statusSnapshot().state
                == "Automation permission required",
            "A denied startup Automation check entered Listening"
        )
        deniedAutomationBridge.reloadConfiguration()
        try expect(
            deniedAutomationChecks == [false, false]
                && deniedAutomationBridge.statusSnapshot().state
                    == "Automation permission required",
            "A configuration reload bypassed the denied Automation check"
        )
        deniedAutomationBridge.stop()

        print("ROB production Messages bridge fixtures passed")
    }

    private static func testAttributedBodyDecoder() throws {
        let immutable = try require(
            Data(base64Encoded: "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQITlNTdHJpbmcBlIQBKxZIZWxsbyBvcmRpbmFyeSBtZXNzYWdlhoQCaUkBFpKEhIQMTlNEaWN0aW9uYXJ5AJSEAWkAhoY="),
            "The immutable attributed-body fixture is invalid"
        )
        let mutable = try require(
            Data(base64Encoded: "BAtzdHJlYW10eXBlZIHoA4QBQISEhBlOU011dGFibGVBdHRyaWJ1dGVkU3RyaW5nAISEEk5TQXR0cmlidXRlZFN0cmluZwCEhAhOU09iamVjdACFkoSEhA9OU011dGFibGVTdHJpbmcBhIQITlNTdHJpbmcBlYQBKw1tdXRhYmxlIGhlbGxvhoQCaUkBDZKEhIQMTlNEaWN0aW9uYXJ5AJWEAWkAhoY="),
            "The mutable attributed-body fixture is invalid"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(from: immutable)
                == "Hello ordinary message",
            "The exact immutable NSAttributedString typed stream did not decode"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(from: mutable) == "mutable hello",
            "The exact mutable NSAttributedString typed stream did not decode"
        )

        let twoByteLengthText = String(repeating: "x", count: 200)
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: attributedArchive(text: twoByteLengthText)
            ) == twoByteLengthText,
            "A canonical 0x81 typed-stream length did not decode"
        )

        let utf16Text = "BOM text 👋"
        var utf16Payload = Data([0xFF, 0xFE])
        utf16Payload.append(utf16Text.data(using: .utf16LittleEndian)!)
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: attributedArchive(
                    encodedText: utf16Payload,
                    attributedLength: utf16Text.utf16.count
                )
            ) == utf16Text,
            "An explicitly BOM-tagged UTF-16LE typed-stream string did not decode"
        )

        var truncated = immutable
        truncated.removeLast()
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(from: truncated) == nil,
            "A truncated attributedBody archive was accepted"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: attributedArchive(
                    encodedText: Data("short".utf8),
                    attributedLength: 5,
                    encodedByteLength: [0x81, 0x05, 0x00]
                )
            ) == nil,
            "A noncanonical 0x81 length was accepted"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: attributedArchive(
                    encodedText: Data(repeating: 0x78, count: 200),
                    attributedLength: 200,
                    encodedByteLength: [0x82, 0xC8, 0x00, 0x00, 0x00]
                )
            ) == nil,
            "A noncanonical 0x82 length was accepted"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: attributedArchive(text: String(repeating: "x", count: 32_768))
            ) == nil,
            "A canonical 0x82 length bypassed the 4,000-character text boundary"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: attributedArchive(
                    encodedText: Data([0xC3, 0x28]),
                    attributedLength: 2
                )
            ) == nil,
            "Invalid UTF-8 was accepted from attributedBody"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: Data(repeating: 0, count: ROBMessagesAttributedBodyDecoder.maximumArchiveBytes + 1)
            ) == nil,
            "An oversize attributedBody blob was accepted"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: attributedArchive(text: "contains\u{0000}control")
            ) == nil,
            "A NUL control escaped the Messages text boundary"
        )
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(
                from: attributedArchive(text: "attachment\u{FFFC}")
            ) == nil,
            "An attachment placeholder was treated as an ordinary message"
        )
        var ambiguous = immutable
        ambiguous.insert(contentsOf: [0x84, 0x01, 0x2B], at: ambiguous.count - 2)
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(from: ambiguous) == nil,
            "An archive with multiple candidate string markers was accepted"
        )
        var forgedLength = immutable
        let immutablePrefixLength = 73
        forgedLength[immutablePrefixLength] = 0x7F
        try expect(
            ROBMessagesAttributedBodyDecoder.plainText(from: forgedLength) == nil,
            "A forged payload length was accepted"
        )
    }

    private static func testAttributedBodyInboxSelection() throws {
        let database = try FixtureMessagesDatabase()
        let owner = try database.addHandle("owner@example.com")
        let friend = try database.addHandle("friend@example.com")
        let chat = try database.addChat(
            guid: "attributed-fixture-chat",
            account: account,
            participants: [owner]
        )
        let friendChat = try database.addChat(
            guid: "participant-mismatch-chat",
            account: account,
            participants: [friend]
        )
        let secondChat = try database.addChat(
            guid: "second-matching-chat",
            account: account,
            participants: [owner]
        )
        let wrongRouteChat = try database.addChat(
            guid: "wrong-route-account-chat",
            account: "other@example.com",
            participants: [owner]
        )
        let plainArchive = attributedArchive(text: "Attributed-only question")
        _ = try database.addMessage(
            guid: "attributed-only",
            text: nil,
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account,
            attributedBody: plainArchive
        )
        _ = try database.addMessage(
            guid: "text-precedence",
            text: "Canonical database text",
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account,
            attributedBody: plainArchive
        )
        _ = try database.addMessage(
            guid: "malformed-attributed",
            text: nil,
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account,
            attributedBody: Data([0x04, 0x0B, 0x73])
        )
        _ = try database.addMessage(
            guid: "oversize-attributed",
            text: nil,
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account,
            attributedBody: Data(
                repeating: 0,
                count: ROBMessagesAttributedBodyDecoder.maximumArchiveBytes + 1
            )
        )
        _ = try database.addMessage(
            guid: "invalid-canonical-text",
            text: "safe\u{0000}truncated-if-c-string",
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account,
            attributedBody: plainArchive
        )
        _ = try database.addMessage(
            guid: "oversize-canonical-text",
            text: String(repeating: "x", count: ROBMessagesPlainTextPolicy.maximumUTF8Bytes + 1),
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account,
            attributedBody: plainArchive
        )
        let attachmentRow = try database.addMessage(
            guid: "attachment-row",
            text: "caption",
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account
        )
        try database.addAttachment(to: attachmentRow)
        _ = try database.addMessage(
            guid: "participant-mismatch",
            text: "must not route",
            senderHandleRowID: owner,
            chatRowID: friendChat,
            account: account
        )
        _ = try database.addMessage(
            guid: "wrong-route-account",
            text: "message metadata cannot override the route",
            senderHandleRowID: owner,
            chatRowID: wrongRouteChat,
            account: account
        )
        let ambiguousRow = try database.addMessage(
            guid: "ambiguous-chat-join",
            text: "must have one route",
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account
        )
        try database.joinMessage(ambiguousRow, toChat: secondChat)
        _ = try database.addMessage(
            guid: "missing-date",
            text: "must have a timestamp",
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account,
            date: nil
        )
        _ = try database.addMessage(
            guid: "future-date",
            text: "too far in the future",
            senderHandleRowID: owner,
            chatRowID: chat,
            account: account,
            date: Date().addingTimeInterval(5 * 60)
        )

        let inbox = ROBMessagesSQLiteInbox(databaseURL: database.url)
        let rows = try inbox.messages(after: 0, limit: 100).messages
        let byGUID = Dictionary(grouping: rows, by: \.guid)
        try expect(
            byGUID["attributed-only"]?.first?.text == "Attributed-only question",
            "SQLite inbox did not use attributedBody when message.text was NULL"
        )
        try expect(
            byGUID["text-precedence"]?.first?.text == "Canonical database text",
            "SQLite inbox let attributedBody override a present message.text"
        )
        for guid in [
            "malformed-attributed", "oversize-attributed",
            "invalid-canonical-text", "oversize-canonical-text",
        ] {
            try expect(
                byGUID[guid]?.first?.text == nil,
                "SQLite inbox accepted or bypassed invalid text for \(guid)"
            )
        }

        let configuration = ROBMessagesBridgeConfiguration(
            enabled: true,
            receivingAccount: account,
            allowedSenders: ["owner@example.com"],
            allowAllSenders: false
        )
        func rejection(_ guid: String) -> ROBMessagesMessageRejection? {
            guard let row = byGUID[guid]?.first else { return .duplicate }
            return ROBMessagesBridgePolicy.rejection(
                for: row,
                configuration: configuration,
                now: Date(),
                seenGUIDs: []
            )
        }
        try expect(rejection("attachment-row") == .attachment, "An attachment row passed policy")
        try expect(
            rejection("participant-mismatch") == .participantMismatch,
            "A mismatched message sender/chat participant passed policy"
        )
        try expect(
            rejection("wrong-route-account") == .wrongAccount,
            "Message account metadata overrode a mismatched chat route account"
        )
        try expect(
            rejection("ambiguous-chat-join") == .ambiguousChat,
            "A message joined to multiple chats retained a routable destination"
        )
        try expect(rejection("missing-date") == .stale, "A row without a date passed policy")
        try expect(rejection("future-date") == .stale, "A far-future row passed policy")
    }

    private static func attributedArchive(text: String) -> Data {
        attributedArchive(
            encodedText: Data(text.utf8),
            attributedLength: text.utf16.count
        )
    }

    private static func attributedArchive(
        encodedText: Data,
        attributedLength: Int,
        encodedByteLength: [UInt8]? = nil
    ) -> Data {
        var archive = Data(base64Encoded: "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQITlNTdHJpbmcBlIQBKw==")!
        archive.append(contentsOf: encodedByteLength ?? typedStreamInteger(encodedText.count))
        archive.append(encodedText)
        archive.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x49, 0x01])
        archive.append(contentsOf: typedStreamInteger(attributedLength))
        archive.append(contentsOf: [
            0x92, 0x84, 0x84, 0x84, 0x0C,
            0x4E, 0x53, 0x44, 0x69, 0x63, 0x74, 0x69, 0x6F, 0x6E, 0x61, 0x72, 0x79,
            0x00, 0x94, 0x84, 0x01, 0x69, 0x00, 0x86, 0x86,
        ])
        return archive
    }

    private static func typedStreamInteger(_ value: Int) -> [UInt8] {
        precondition(value >= 0 && value <= Int(UInt32.max))
        if value <= 0x7F { return [UInt8(value)] }
        if value <= 0x7FFF {
            return [0x81, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
        }
        return [
            0x82,
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private static func resetFixtureDefaults() {
        for key in defaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func settleWorkerQueues() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private static func waitUntil(
        _ failure: String,
        attempts: Int = 1_000,
        predicate: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw ProductionFixtureFailure.failed(failure)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw ProductionFixtureFailure.failed(message)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProductionFixtureFailure.failed(message) }
        return value
    }
}
