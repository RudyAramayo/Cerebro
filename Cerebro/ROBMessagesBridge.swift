//
//  ROBMessagesBridge.swift
//  Cerebro
//
//  Permission-aware, read-only Apple Messages inbox bridge. It never writes
//  to chat.db; replies are sent to the immutable originating chat through the
//  Messages scripting interface.
//

import Foundation
import Cocoa
import ApplicationServices
import SQLite3

private let ROBMessagesSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

extension Notification.Name {
    static let robMessagesBridgeSettingsDidChange = Notification.Name(
        "ROBMessagesBridgeSettingsDidChange"
    )
    static let robMessagesBridgeDidChange = Notification.Name(
        "ROBMessagesBridgeDidChange"
    )
}

struct ROBMessagesBridgeConfiguration: Equatable, Sendable {
    let enabled: Bool
    let receivingAccount: String
    let allowedSenders: Set<String>
    let allowAllSenders: Bool

    static func canonicalHandle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func parseAllowedSenders(_ value: String) -> Set<String> {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ","))
        return Set(value.components(separatedBy: separators).compactMap { item in
            let canonical = canonicalHandle(item)
            return canonical.isEmpty ? nil : canonical
        })
    }
}

/// Shared text boundary for both SQLite values and decoded attributed bodies.
/// In particular, Process arguments cannot represent embedded NUL bytes, so
/// controls are rejected here rather than silently truncating a prompt/reply.
enum ROBMessagesPlainTextPolicy {
    static let maximumCharacters = 4_000
    static let maximumUTF8Bytes = maximumCharacters * 4

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count <= maximumCharacters,
              text.utf8.count <= maximumUTF8Bytes else {
            return nil
        }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                continue // tab, line feed, and carriage return are plain text
            case 0x00...0x1F, 0x7F...0x9F, 0xFFFC, 0xFFFD:
                return nil // controls, attachments, and app-message placeholders
            default:
                continue
            }
        }
        return text
    }
}

/// A deliberately narrow decoder for the legacy NSArchiver typed-stream
/// envelope used by ordinary Messages attributedBody rows. It does not invoke
/// NSUnarchiver (which could instantiate arbitrary archived Objective-C
/// classes); only exact NSAttributedString/NSString class chains are accepted.
enum ROBMessagesAttributedBodyDecoder {
    static let maximumArchiveBytes = 64 * 1_024

    private static let valueMarker: [UInt8] = [0x84, 0x01, 0x2B]
    private static let valueTerminator: [UInt8] = [0x86, 0x84, 0x02, 0x69, 0x49, 0x01]
    private static let dictionaryMarker: [UInt8] = [
        0x92, 0x84, 0x84, 0x84, 0x0C,
        0x4E, 0x53, 0x44, 0x69, 0x63, 0x74, 0x69, 0x6F, 0x6E, 0x61, 0x72, 0x79,
        0x00,
    ]

    private static let allowedPrefixes: [[UInt8]] = [
        archivePrefix(
            attributedClasses: ["NSAttributedString", "NSObject"],
            stringClasses: ["NSString"],
            objectReference: 0x94
        ),
        archivePrefix(
            attributedClasses: ["NSMutableAttributedString", "NSAttributedString", "NSObject"],
            stringClasses: ["NSMutableString", "NSString"],
            objectReference: 0x95
        ),
    ]

    static func plainText(from archive: Data) -> String? {
        guard !archive.isEmpty, archive.count <= maximumArchiveBytes else { return nil }
        let bytes = [UInt8](archive)
        guard occurrences(of: valueMarker, in: bytes, stoppingAfter: 1) == 1,
              let prefix = allowedPrefixes.first(where: { bytes.starts(with: $0) }) else {
            return nil
        }

        var cursor = prefix.count
        guard let byteCount = decodeCanonicalUnsignedInteger(bytes, cursor: &cursor),
              byteCount > 0,
              byteCount <= ROBMessagesPlainTextPolicy.maximumUTF8Bytes + 2,
              byteCount <= bytes.count - cursor else {
            return nil
        }
        let payloadEnd = cursor + byteCount
        let encodedText = Data(bytes[cursor..<payloadEnd])
        let decoded: String?
        if encodedText.starts(with: [0xFF, 0xFE]) {
            let utf16Bytes = encodedText.dropFirst(2)
            guard utf16Bytes.count.isMultiple(of: 2) else { return nil }
            decoded = String(data: Data(utf16Bytes), encoding: .utf16LittleEndian)
        } else {
            decoded = String(data: encodedText, encoding: .utf8)
        }
        guard let decoded else { return nil }

        cursor = payloadEnd
        guard consume(valueTerminator, from: bytes, cursor: &cursor),
              let attributedLength = decodeCanonicalUnsignedInteger(bytes, cursor: &cursor),
              attributedLength == decoded.utf16.count,
              consume(dictionaryMarker, from: bytes, cursor: &cursor),
              bytes.count >= 2,
              bytes.suffix(2).elementsEqual([0x86, 0x86]) else {
            return nil
        }
        return ROBMessagesPlainTextPolicy.normalized(decoded)
    }

    private static func archivePrefix(
        attributedClasses: [String],
        stringClasses: [String],
        objectReference: UInt8
    ) -> [UInt8] {
        var result: [UInt8] = [
            0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D,
            0x74, 0x79, 0x70, 0x65, 0x64, // "streamtyped"
            0x81, 0xE8, 0x03, 0x84, 0x01, 0x40,
        ]
        appendClassChain(attributedClasses, terminator: 0x00, to: &result)
        result.append(contentsOf: [0x85, 0x92])
        appendClassChain(stringClasses, terminator: 0x01, to: &result)
        result.append(contentsOf: [objectReference])
        result.append(contentsOf: valueMarker)
        return result
    }

    private static func appendClassChain(
        _ classes: [String],
        terminator: UInt8,
        to result: inout [UInt8]
    ) {
        for (index, name) in classes.enumerated() {
            result.append(contentsOf: index == 0 ? [0x84, 0x84, 0x84] : [0x84, 0x84])
            let nameBytes = Array(name.utf8)
            precondition(nameBytes.count <= 0x7F)
            result.append(UInt8(nameBytes.count))
            result.append(contentsOf: nameBytes)
            result.append(terminator)
        }
    }

    private static func decodeCanonicalUnsignedInteger(
        _ bytes: [UInt8],
        cursor: inout Int
    ) -> Int? {
        guard cursor < bytes.count else { return nil }
        let marker = bytes[cursor]
        cursor += 1
        if marker <= 0x7F {
            return Int(marker)
        }
        if marker == 0x81 {
            guard cursor <= bytes.count - 2 else { return nil }
            let value = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            cursor += 2
            return value >= 0x80 ? value : nil
        }
        if marker == 0x82 {
            guard cursor <= bytes.count - 4 else { return nil }
            let value = UInt32(bytes[cursor]) |
                (UInt32(bytes[cursor + 1]) << 8) |
                (UInt32(bytes[cursor + 2]) << 16) |
                (UInt32(bytes[cursor + 3]) << 24)
            cursor += 4
            return value >= 0x8000 ? Int(value) : nil
        }
        return nil
    }

    private static func consume(
        _ expected: [UInt8],
        from bytes: [UInt8],
        cursor: inout Int
    ) -> Bool {
        guard expected.count <= bytes.count - cursor,
              bytes[cursor..<(cursor + expected.count)].elementsEqual(expected) else {
            return false
        }
        cursor += expected.count
        return true
    }

    private static func occurrences(
        of needle: [UInt8],
        in haystack: [UInt8],
        stoppingAfter limit: Int
    ) -> Int {
        guard !needle.isEmpty, needle.count <= haystack.count else { return 0 }
        var count = 0
        for index in 0...(haystack.count - needle.count) where
            haystack[index..<(index + needle.count)].elementsEqual(needle) {
            count += 1
            if count > limit { return count }
        }
        return count
    }
}

/// A small lock-protected authorization snapshot used by queued reply work.
/// The worker rechecks this immediately before invoking Messages, closing the
/// race where the operator disables the bridge after a reply was queued but
/// before the serial worker begins sending it.
private final class ROBMessagesReplyAuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var isActive = false
    private var receivingAccount = ""
    private var allowedSenders = Set<String>()

    func update(
        generation: UInt64,
        configuration: ROBMessagesBridgeConfiguration,
        isActive: Bool
    ) {
        lock.lock()
        self.generation = generation
        self.isActive = isActive
        receivingAccount = configuration.receivingAccount
        allowedSenders = configuration.allowedSenders
        lock.unlock()
    }

    func authorizes(
        generation: UInt64,
        account: String,
        sender: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive &&
            self.generation == generation &&
            receivingAccount == account &&
            allowedSenders.contains(sender)
    }
}

struct ROBMessagesInboundMessage: Sendable {
    let rowID: Int64
    let guid: String
    let chatID: String
    let sender: String
    let chatAccountCandidates: [String]
    let soleChatParticipant: String
    let isFromMe: Bool
    let participantCount: Int
    let attachmentCount: Int
    let chatJoinCount: Int
    let text: String?
    let date: Date?
    let associatedMessageGUID: String?
    let itemType: Int
    let groupActionType: Int
}

enum ROBMessagesMessageRejection: Equatable, Sendable {
    case disabled
    case wrongAccount
    case outboundOrSelf
    case senderNotAllowed
    case groupChat
    case ambiguousChat
    case participantMismatch
    case attachment
    case missingChat
    case unsupportedEvent
    case nonText
    case stale
    case duplicate
}

enum ROBMessagesBridgePolicy {
    static let maximumInboundCharacters = ROBMessagesPlainTextPolicy.maximumCharacters
    static let maximumMessageAge: TimeInterval = 10 * 60
    static let maximumFutureClockSkew: TimeInterval = 2 * 60

    static func accountCandidate(
        _ candidate: String,
        matches configuredAccount: String
    ) -> Bool {
        let expected = ROBMessagesBridgeConfiguration.canonicalHandle(configuredAccount)
        guard !expected.isEmpty else { return false }
        let canonical = ROBMessagesBridgeConfiguration.canonicalHandle(candidate)
        if canonical == expected { return true }
        let separators = CharacterSet(charactersIn: ";:,| ")
        return canonical.components(separatedBy: separators).contains(expected)
    }

    static func rejection(
        for message: ROBMessagesInboundMessage,
        configuration: ROBMessagesBridgeConfiguration,
        now: Date,
        seenGUIDs: Set<String>
    ) -> ROBMessagesMessageRejection? {
        guard configuration.enabled else { return .disabled }
        let configuredAccount = ROBMessagesBridgeConfiguration.canonicalHandle(
            configuration.receivingAccount
        )
        guard !configuredAccount.isEmpty,
              message.chatAccountCandidates.contains(where: {
                  accountCandidate($0, matches: configuredAccount)
              }) else {
            return .wrongAccount
        }
        let sender = ROBMessagesBridgeConfiguration.canonicalHandle(message.sender)
        guard !message.isFromMe, !sender.isEmpty, sender != configuredAccount else {
            return .outboundOrSelf
        }
        // The receiving account is not sender authorization. An empty list is
        // deliberately fail-closed, even for one-to-one chats, unless allowAllSenders is active.
        guard configuration.allowAllSenders || configuration.allowedSenders.contains(sender) else {
            return .senderNotAllowed
        }
        guard message.participantCount == 1 else { return .groupChat }
        guard ROBMessagesBridgeConfiguration.canonicalHandle(message.soleChatParticipant)
                == sender else {
            return .participantMismatch
        }
        guard message.chatJoinCount == 1 else { return .ambiguousChat }
        guard message.attachmentCount == 0 else { return .attachment }
        guard !message.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingChat
        }
        guard message.itemType == 0,
              message.groupActionType == 0,
              message.associatedMessageGUID?.isEmpty != false else {
            return .unsupportedEvent
        }
        guard ROBMessagesPlainTextPolicy.normalized(message.text) != nil else {
            return .nonText
        }
        guard let date = message.date else { return .stale }
        let age = now.timeIntervalSince(date)
        if age > maximumMessageAge || age < -maximumFutureClockSkew {
            return .stale
        }
        guard !message.guid.isEmpty, !seenGUIDs.contains(message.guid) else {
            return .duplicate
        }
        return nil
    }
}

struct ROBMessagesInboxBatch: Sendable {
    let messages: [ROBMessagesInboundMessage]
    let highWaterRowID: Int64
}

protocol ROBMessagesInboxReading: AnyObject, Sendable {
    func highestRowID() throws -> Int64
    func messages(after rowID: Int64, limit: Int) throws -> ROBMessagesInboxBatch
}

protocol ROBMessagesReplySending: AnyObject, Sendable {
    func send(
        text: String,
        toChat chatID: String,
        account: String,
        expectedSender: String
    ) throws
}

enum ROBMessagesInboxError: LocalizedError {
    case fullDiskAccessRequired
    case unsupportedSchema(String)
    case database(String)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired:
            return "Full Disk Access is required to read the local Messages inbox."
        case .unsupportedSchema(let detail):
            return "The installed Messages database schema is unsupported: \(detail)"
        case .database(let detail):
            return "Messages database error: \(detail)"
        }
    }
}

final class ROBMessagesSQLiteInbox: ROBMessagesInboxReading, @unchecked Sendable {
    private let databaseURL: URL

    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")) {
        self.databaseURL = databaseURL
    }

    func highestRowID() throws -> Int64 {
        try withDatabase { database in
            let statement = try prepare(
                "SELECT IFNULL(MAX(ROWID), 0) FROM message",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw databaseError(database)
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func messages(after rowID: Int64, limit: Int) throws -> ROBMessagesInboxBatch {
        try withDatabase { database in
            try inReadTransaction(database) {
            let boundedLimit = max(1, min(limit, 100))
            let upperStatement = try prepare(
                "SELECT ROWID FROM message WHERE ROWID > ? ORDER BY ROWID LIMIT ?",
                database: database
            )
            defer { sqlite3_finalize(upperStatement) }
            sqlite3_bind_int64(upperStatement, 1, rowID)
            sqlite3_bind_int(upperStatement, 2, Int32(boundedLimit))
            var highWater = rowID
            while true {
                let step = sqlite3_step(upperStatement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw databaseError(database) }
                highWater = sqlite3_column_int64(upperStatement, 0)
            }
            guard highWater > rowID else {
                return ROBMessagesInboxBatch(messages: [], highWaterRowID: rowID)
            }

            let messageColumns = try columns(in: "message", database: database)
            let chatColumns = try columns(in: "chat", database: database)
            let handleColumns = try columns(in: "handle", database: database)
            let requiredMessageColumns: Set<String> = [
                "guid", "text", "handle_id", "is_from_me", "date",
                "associated_message_guid", "item_type", "group_action_type",
            ]
            guard requiredMessageColumns.isSubset(of: messageColumns),
                  chatColumns.contains("guid"),
                  handleColumns.contains("id"),
                  try tableExists("chat_message_join", database: database),
                  try tableExists("chat_handle_join", database: database),
                  try tableExists("message_attachment_join", database: database) else {
                throw ROBMessagesInboxError.unsupportedSchema(
                    "required message/chat/handle columns or joins are missing"
                )
            }

            var chatAccountExpressions: [String] = []
            if chatColumns.contains("last_addressed_handle") {
                chatAccountExpressions.append("COALESCE(c.last_addressed_handle, '')")
            }
            if chatColumns.contains("account_login") {
                chatAccountExpressions.append("COALESCE(c.account_login, '')")
            }
            if chatColumns.contains("account_id") {
                chatAccountExpressions.append("COALESCE(c.account_id, '')")
            }
            guard !chatAccountExpressions.isEmpty else {
                throw ROBMessagesInboxError.unsupportedSchema(
                    "a chat route account identity is required"
                )
            }

            let boundedText = """
            CASE WHEN m.text IS NULL THEN NULL
                 WHEN length(CAST(m.text AS BLOB)) <= \(ROBMessagesPlainTextPolicy.maximumUTF8Bytes)
                 THEN m.text ELSE NULL END
            """
            let attributedBody = messageColumns.contains("attributedBody")
                ? "CASE WHEN typeof(m.attributedBody) = 'blob' AND length(m.attributedBody) <= \(ROBMessagesAttributedBodyDecoder.maximumArchiveBytes) THEN m.attributedBody ELSE NULL END"
                : "NULL"
            let chatAccountSelect = chatAccountExpressions.joined(separator: ", ")
            let query = """
            SELECT m.ROWID, COALESCE(m.guid, ''), \(boundedText),
                   COALESCE(m.is_from_me, 0), COALESCE(m.date, 0),
                   COALESCE(h.id, ''), COALESCE(c.guid, ''),
                   COALESCE(m.associated_message_guid, ''),
                   COALESCE(m.item_type, 0), COALESCE(m.group_action_type, 0),
                   (SELECT COUNT(*) FROM chat_handle_join chj
                    WHERE chj.chat_id = c.ROWID),
                   (SELECT COUNT(*) FROM message_attachment_join maj
                    WHERE maj.message_id = m.ROWID),
                   (SELECT COUNT(*) FROM chat_message_join cmj_count
                    WHERE cmj_count.message_id = m.ROWID),
                   CASE WHEN m.text IS NULL THEN 0 ELSE 1 END,
                   (SELECT COALESCE(participant.id, '')
                      FROM chat_handle_join participant_join
                      JOIN handle participant
                        ON participant.ROWID = participant_join.handle_id
                     WHERE participant_join.chat_id = c.ROWID
                     LIMIT 1),
                   \(chatAccountSelect),
                   \(attributedBody)
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
              JOIN chat c ON c.ROWID = cmj.chat_id
              LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE m.ROWID > ? AND m.ROWID <= ?
             ORDER BY m.ROWID
            """
            let statement = try prepare(query, database: database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, rowID)
            sqlite3_bind_int64(statement, 2, highWater)

            var messages: [ROBMessagesInboundMessage] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw databaseError(database) }
                let rawDate = sqlite3_column_int64(statement, 4)
                let chatAccountStart = 15
                let chatAccounts = chatAccountExpressions.indices.map {
                    string(statement, column: Int32(chatAccountStart + $0)) ?? ""
                }
                let attributedBodyColumn = Int32(
                    chatAccountStart + chatAccountExpressions.count
                )
                let hasDatabaseText = sqlite3_column_int(statement, 13) != 0
                let selectedText: String?
                if hasDatabaseText {
                    // Presence wins even when invalid/oversize; never bypass a
                    // malformed canonical value with attributedBody fallback.
                    selectedText = string(
                        statement,
                        column: 2,
                        maximumBytes: ROBMessagesPlainTextPolicy.maximumUTF8Bytes
                    )
                } else {
                    selectedText = data(
                        statement,
                        column: attributedBodyColumn,
                        maximumBytes: ROBMessagesAttributedBodyDecoder.maximumArchiveBytes
                    ).flatMap(ROBMessagesAttributedBodyDecoder.plainText(from:))
                }
                messages.append(ROBMessagesInboundMessage(
                    rowID: sqlite3_column_int64(statement, 0),
                    guid: string(statement, column: 1) ?? "",
                    chatID: string(statement, column: 6) ?? "",
                    sender: string(statement, column: 5) ?? "",
                    chatAccountCandidates: chatAccounts,
                    soleChatParticipant: string(statement, column: 14) ?? "",
                    isFromMe: sqlite3_column_int(statement, 3) != 0,
                    participantCount: Int(sqlite3_column_int(statement, 10)),
                    attachmentCount: Int(sqlite3_column_int(statement, 11)),
                    chatJoinCount: Int(sqlite3_column_int(statement, 12)),
                    text: ROBMessagesPlainTextPolicy.normalized(selectedText),
                    date: Self.messagesDate(rawDate),
                    associatedMessageGUID: string(statement, column: 7),
                    itemType: Int(sqlite3_column_int(statement, 8)),
                    groupActionType: Int(sqlite3_column_int(statement, 9))
                ))
            }
            return ROBMessagesInboxBatch(messages: messages, highWaterRowID: highWater)
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            if result == SQLITE_AUTH || result == SQLITE_CANTOPEN || result == SQLITE_PERM {
                throw ROBMessagesInboxError.fullDiskAccessRequired
            }
            throw ROBMessagesInboxError.database("SQLite open failed (\(result)).")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        return try body(database)
    }

    private func inReadTransaction<T>(
        _ database: OpaquePointer,
        _ body: () throws -> T
    ) throws -> T {
        guard sqlite3_exec(database, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        do {
            let value = try body()
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw databaseError(database)
            }
            return value
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        return statement
    }

    private func columns(in table: String, database: OpaquePointer) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))", database: database)
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw databaseError(database) }
            if let name = string(statement, column: 1) {
                names.insert(name)
            }
        }
        return names
    }

    private func tableExists(_ table: String, database: OpaquePointer) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        let bindResult = table.withCString { value in
            sqlite3_bind_text(
                statement,
                1,
                value,
                -1,
                ROBMessagesSQLiteTransient
            )
        }
        guard bindResult == SQLITE_OK else {
            throw databaseError(database)
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func databaseError(_ database: OpaquePointer) -> ROBMessagesInboxError {
        ROBMessagesInboxError.database(String(cString: sqlite3_errmsg(database)))
    }

    private func string(
        _ statement: OpaquePointer,
        column: Int32,
        maximumBytes: Int = ROBMessagesPlainTextPolicy.maximumUTF8Bytes
    ) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              sqlite3_column_bytes(statement, column) >= 0 else {
            return nil
        }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount <= maximumBytes else { return nil }
        if byteCount == 0 { return "" }
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(data: Data(bytes: bytes, count: byteCount), encoding: .utf8)
    }

    private func data(
        _ statement: OpaquePointer,
        column: Int32,
        maximumBytes: Int
    ) -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { return nil }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount > 0, byteCount <= maximumBytes,
              let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private static func messagesDate(_ rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let magnitude = Double(rawValue)
        let seconds: Double
        if magnitude > 10_000_000_000_000_000 {
            seconds = magnitude / 1_000_000_000
        } else if magnitude > 10_000_000_000_000 {
            seconds = magnitude / 1_000_000
        } else if magnitude > 10_000_000_000 {
            seconds = magnitude / 1_000
        } else {
            seconds = magnitude
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

enum ROBMessagesReplyError: LocalizedError {
    case automationPermissionRequired
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .automationPermissionRequired:
            return "Automation permission is required to send replies through Messages."
        case .timedOut:
            return "Messages did not finish sending the reply."
        case .failed(let detail):
            return "Messages reply failed: \(detail)"
        }
    }
}

final class ROBMessagesAppleScriptReplySender: ROBMessagesReplySending, @unchecked Sendable {
    private static let script = """
    on run argv
      if (count of argv) is not 4 then error "Invalid Cerebro Messages arguments"
      set targetID to item 1 of argv
      set replyText to item 2 of argv
      set expectedAccount to item 3 of argv
      set expectedSender to item 4 of argv
      tell application id "com.apple.MobileSMS"
        set matchingChats to every chat whose id is targetID
        if (count of matchingChats) is not 1 then error "Originating chat is unavailable"
        set targetChat to item 1 of matchingChats
        set targetAccount to account of targetChat
        set accountDescription to description of targetAccount as text
        set accountID to id of targetAccount as text
        set colonAccountSuffix to ":" & expectedAccount
        set semicolonAccountSuffix to ";" & expectedAccount
        ignoring case
          if accountDescription is not expectedAccount and accountID is not expectedAccount and accountID does not end with colonAccountSuffix and accountID does not end with semicolonAccountSuffix then error "Originating chat account changed"
        end ignoring
        set targetParticipants to participants of targetChat
        if (count of targetParticipants) is not 1 then error "Originating chat is no longer one-to-one"
        set participantHandle to handle of item 1 of targetParticipants as text
        ignoring case
          if participantHandle is expectedAccount then error "Originating chat participant is the receiving account"
          if participantHandle is not expectedSender then error "Originating chat participant changed"
        end ignoring
        send replyText to targetChat
      end tell
      return "sent"
    end run
    """

    func send(
        text: String,
        toChat chatID: String,
        account: String,
        expectedSender: String
    ) throws {
        guard let reply = ROBMessagesPlainTextPolicy.normalized(text),
              !chatID.isEmpty,
              !account.isEmpty,
              !expectedSender.isEmpty,
              account.caseInsensitiveCompare(expectedSender) != .orderedSame else {
            throw ROBMessagesReplyError.failed("The correlated reply was not safe plain text.")
        }
        do {
            try ROBAppleScriptPermissionProbe.requestControl(
                application: "com.apple.MobileSMS",
                script: """
                tell application id "com.apple.MobileSMS"
                  return name
                end tell
                """
            )
        } catch {
            // Map permission probe failures into the same visible failure mode as runtime send failures.
            if let probeError = error as? ROBAppleScriptPermissionProbeError {
                switch probeError {
                case .permissionRequired:
                    throw ROBMessagesReplyError.automationPermissionRequired
                case .applicationUnavailable:
                    throw ROBMessagesReplyError.failed("Messages is currently unavailable.")
                case .executionFailed(let detail):
                    throw ROBMessagesReplyError.failed(detail)
                }
            }
            throw ROBMessagesReplyError.failed(error.localizedDescription)
        }
        let boundedReply = reply
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", Self.script, "--", chatID, boundedReply, account, expectedSender
        ]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            throw ROBMessagesReplyError.failed(error.localizedDescription)
        }
        if completion.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            throw ROBMessagesReplyError.timedOut
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data.prefix(1_024), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Apple Events error"
            if detail.localizedCaseInsensitiveContains("not authorized") ||
                detail.localizedCaseInsensitiveContains("not permitted") ||
                detail.contains("-1743") {
                throw ROBMessagesReplyError.automationPermissionRequired
            }
            throw ROBMessagesReplyError.failed(detail)
        }
    }
}

private enum ROBAppleScriptPermissionProbeError: Error {
    case permissionRequired
    case applicationUnavailable
    case executionFailed(String)
}

private enum ROBAppleEventAutomationPermission {
    static func errorDescription(
        bundleIdentifier: String,
        applicationName: String,
        askUserIfNeeded: Bool
    ) -> String? {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            typeWildCard,
            typeWildCard,
            askUserIfNeeded
        )
        switch status {
        case noErr:
            return nil
        case OSStatus(errAEEventNotPermitted):
            return "Automation permission for \(applicationName) is denied. Enable Cerebro → \(applicationName) in System Settings → Privacy & Security → Automation."
        case OSStatus(errAEEventWouldRequireUserConsent):
            return "Automation permission for \(applicationName) has not been granted yet. Click Request \(applicationName) Automation Access to show the macOS consent prompt."
        case OSStatus(procNotFound):
            return "\(applicationName) is unavailable. Open \(applicationName), then check Automation access again."
        default:
            return "Unable to verify \(applicationName) Automation permission (OSStatus \(status))."
        }
    }
}

private enum ROBAppleScriptPermissionProbe {
    static func requestControl(application: String, script: String) throws {
        if Thread.isMainThread {
            try run(script: script)
            return
        }
        var capturedError: Error?
        DispatchQueue.main.sync {
            do {
                try run(script: script)
            } catch {
                capturedError = error
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    private static func run(script: String) throws {
        guard let appleScript = NSAppleScript(source: script) else {
            throw ROBAppleScriptPermissionProbeError.executionFailed("The local AppleScript engine is unavailable.")
        }
        var error: NSDictionary?
        _ = appleScript.executeAndReturnError(&error)
        if error == nil {
            return
        }
        throw mapped(error)
    }

    private static func mapped(_ error: NSDictionary?) -> ROBAppleScriptPermissionProbeError {
        let code = error?[NSAppleScript.errorNumber] as? Int
        let detail = (error?[NSAppleScript.errorMessage] as? String) ?? "Unknown Apple Events error"
        let lower = detail.lowercased()

        let permissionSignals = [
            "not authorized",
            "not permitted",
            "not allowed",
            "automation permission",
            "doesn’t have permission",
            "does not have permission",
        ]
        if code == -1743 || permissionSignals.contains(where: { lower.contains($0) }) {
            return .permissionRequired
        }

        let availabilitySignals = [
            "application isn’t running",
            "application isn't running",
            "application \"messages\" can’t be found",
            "application \"messages\" can't be found",
            "application \"com.apple.mobilesms\" can’t be found",
            "application \"com.apple.mobilesms\" can't be found",
            "application \"music\" can’t be found",
            "application \"music\" can't be found",
            "application \"com.apple.music\" can’t be found",
            "application \"com.apple.music\" can't be found",
            "doesn’t exist",
            "not found",
        ]
        if availabilitySignals.contains(where: { lower.contains($0) }) {
            return .applicationUnavailable
        }

        let bounded = Self.bounded(detail, maximum: 200)
        return .executionFailed(bounded)
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        let flattened = value
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !flattened.isEmpty else { return "" }
        return String(flattened.unicodeScalars.prefix(maximum).map(String.init).joined())
    }
}

public struct ROBMessagesBridgeStatusSnapshot: Sendable {
    public let enabled: Bool
    public let state: String
    public let detail: String
    public let configuredAccount: String
    public let allowedSenderCount: Int
    public let allowAllSenders: Bool
    public let pendingReplyCount: Int
    public let activeAIChatCount: Int
    public let activeAIProvider: String?
    public let lastAIProvider: String?
    public let lastAIError: String?
    public let lastInboundAt: Date?
    public let lastReplyAt: Date?
}

@MainActor
@objcMembers public final class ROBMessagesBridge: NSObject {
    public static let shared = ROBMessagesBridge()
    public static let defaultAccountIdentifier = "rob@orbitusrobotics.com"

    private static let enabledDefaultsKey = "ROBMessagesBridgeEnabled"
    private static let accountDefaultsKey = "ROBMessagesBridgeReceivingAccount"
    private static let allowedSendersDefaultsKey = "ROBMessagesBridgeAllowedSenders"
    private static let allowAllSendersDefaultsKey = "ROBMessagesBridgeAllowAllSenders"
    private static let cursorDefaultsKey = "ROBMessagesBridgeLastMessageRowID"
    private static let recentGUIDsDefaultsKey = "ROBMessagesBridgeRecentMessageGUIDs"
    private static let pollingInterval: TimeInterval = 2
    private static let maximumRecentGUIDs = 512
    private static let maximumRapidMessages = 5
    private static let rapidMessageWindow: TimeInterval = 60

    private struct PendingRoute: Sendable {
        let chatID: String
        let messageGUID: String
        let sender: String
        let receivingAccount: String
        let generation: UInt64
    }

    private let inbox: ROBMessagesInboxReading
    private let replySender: ROBMessagesReplySending
    private let aiResponder: ROBMessagesAIResponder
    private let automationPermissionCheck: (_ askUserIfNeeded: Bool) -> String?
    private let replyAuthorizationGate = ROBMessagesReplyAuthorizationGate()
    private let workerQueue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.MessagesBridge")
    private var configuration: ROBMessagesBridgeConfiguration
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var generation: UInt64 = 0
    private var cursor: Int64?
    private var recentGUIDs: [String]
    private var pendingRoutes: [String: PendingRoute] = [:]
    private var recentSubmissionDates: [Date] = []
    private var state = "disabled"
    private var detail = "Messages replies are disabled."
    private var lastInboundAt: Date?
    private var lastReplyAt: Date?
    private var hasStarted = false
    private var hasRequestedFullDiskAccessPermission = false
    private var hasOpenedFullDiskAccessSettings = false

    private override convenience init() {
        self.init(
            inbox: ROBMessagesSQLiteInbox(),
            replySender: ROBMessagesAppleScriptReplySender(),
            aiResponder: ROBMessagesAIResponder(),
            automationPermissionCheck: { askUserIfNeeded in
                ROBAppleEventAutomationPermission.errorDescription(
                    bundleIdentifier: "com.apple.MobileSMS",
                    applicationName: "Messages",
                    askUserIfNeeded: askUserIfNeeded
                )
            }
        )
    }

    init(
        inbox: ROBMessagesInboxReading,
        replySender: ROBMessagesReplySending,
        aiResponder: ROBMessagesAIResponder,
        automationPermissionCheck: @escaping (_ askUserIfNeeded: Bool) -> String? = {
            askUserIfNeeded in
            ROBAppleEventAutomationPermission.errorDescription(
                bundleIdentifier: "com.apple.MobileSMS",
                applicationName: "Messages",
                askUserIfNeeded: askUserIfNeeded
            )
        }
    ) {
        self.inbox = inbox
        self.replySender = replySender
        self.aiResponder = aiResponder
        self.automationPermissionCheck = automationPermissionCheck
        configuration = Self.loadConfiguration()
        let defaults = UserDefaults.standard
        cursor = (defaults.object(forKey: Self.cursorDefaultsKey) as? NSNumber)?.int64Value
        recentGUIDs = (defaults.array(forKey: Self.recentGUIDsDefaultsKey) as? [String]) ?? []
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .robMessagesBridgeSettingsDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public static func configuredEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    public static func setConfiguredEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
        postSettingsChange()
    }

    /// Checks the current Messages Automation decision and asks macOS for
    /// consent when it has not been decided yet. Returns nil only when granted.
    @objc public static func requestMessagesAutomationPermission() -> NSString? {
        ROBAppleEventAutomationPermission.errorDescription(
            bundleIdentifier: "com.apple.MobileSMS",
            applicationName: "Messages",
            askUserIfNeeded: true
        ).map(NSString.init(string:))
    }

    /// Checks the current TCC decision without presenting a consent prompt.
    @objc public static func checkMessagesAutomationPermission() -> NSString? {
        ROBAppleEventAutomationPermission.errorDescription(
            bundleIdentifier: "com.apple.MobileSMS",
            applicationName: "Messages",
            askUserIfNeeded: false
        ).map(NSString.init(string:))
    }

    public static func configuredAccountIdentifier() -> String {
        let stored = UserDefaults.standard.string(forKey: accountDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored?.isEmpty == false ? stored! : defaultAccountIdentifier
    }

    public static func setConfiguredAccountIdentifier(_ account: String) {
        let canonical = ROBMessagesBridgeConfiguration.canonicalHandle(account)
        if canonical.isEmpty || canonical == defaultAccountIdentifier {
            UserDefaults.standard.removeObject(forKey: accountDefaultsKey)
        } else {
            UserDefaults.standard.set(canonical, forKey: accountDefaultsKey)
        }
        postSettingsChange()
    }

    public static func configuredAllowedSendersText() -> String {
        UserDefaults.standard.string(forKey: allowedSendersDefaultsKey) ?? ""
    }

    public static func setConfiguredAllowedSendersText(_ value: String) {
        let senders = ROBMessagesBridgeConfiguration.parseAllowedSenders(value).sorted()
        if senders.isEmpty {
            UserDefaults.standard.removeObject(forKey: allowedSendersDefaultsKey)
        } else {
            UserDefaults.standard.set(
                senders.joined(separator: "\n"),
                forKey: allowedSendersDefaultsKey
            )
        }
        postSettingsChange()
    }

    public static func configuredAllowAllSenders() -> Bool {
        UserDefaults.standard.bool(forKey: allowAllSendersDefaultsKey)
    }

    public static func setConfiguredAllowAllSenders(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: allowAllSendersDefaultsKey)
        postSettingsChange()
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        applyCurrentConfiguration()
    }

    public func stop() {
        guard hasStarted else { return }
        hasStarted = false
        generation &+= 1
        hasRequestedFullDiskAccessPermission = false
        hasOpenedFullDiskAccessSettings = false
        replyAuthorizationGate.update(
            generation: generation,
            configuration: configuration,
            isActive: false
        )
        pollTimer?.invalidate()
        pollTimer = nil
        pollInFlight = false
        pendingRoutes.removeAll()
        aiResponder.shutdown()
        state = "stopped"
        detail = "Messages bridge stopped."
        publishStatus()
    }

    public func reloadConfiguration() {
        guard hasStarted else { return }
        applyCurrentConfiguration()
    }

    private func checkMessagesAutomationPermission() -> Bool {
        if let automationError = automationPermissionCheck(false) {
            state = "Automation permission required"
            detail = "Messages automation: \(automationError)"
            publishStatus()
            return false
        }
        return true
    }

    private func openSystemSettings(forPrivacySection section: String) -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(section)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security.extension?\(section)",
            "x-apple.systempreferences:com.apple.preference.security?\(section)"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    private func openFullDiskAccessSettingsIfNeeded() {
        guard !hasOpenedFullDiskAccessSettings else { return }
        hasOpenedFullDiskAccessSettings = true
        if !openSystemSettings(forPrivacySection: "Privacy_AllFiles") {
            state = "error"
            detail = "Unable to open System Settings Privacy & Security → Full Disk Access."
            publishStatus()
        }
    }

    private func requestFullDiskAccessPermissionIfNeeded() {
        guard !hasRequestedFullDiskAccessPermission else { return }
        hasRequestedFullDiskAccessPermission = true
        state = "Checking Full Disk Access"
        detail = "Verifying read-only Messages inbox permissions."
        publishStatus()

        let requestGeneration = generation
        let inbox = inbox
        workerQueue.async { [weak self] in
            var failure: Error?
            do {
                _ = try inbox.highestRowID()
            } catch {
                failure = error
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard requestGeneration == generation else { return }
                guard let error = failure else { return }
                if case ROBMessagesInboxError.fullDiskAccessRequired = error {
                    self.state = "Full Disk Access required"
                    self.detail = error.localizedDescription
                    self.openFullDiskAccessSettingsIfNeeded()
                    self.publishStatus()
                    return
                }
                self.state = "error"
                self.detail = error.localizedDescription
                self.publishStatus()
            }
        }
    }

    public func statusSnapshot() -> ROBMessagesBridgeStatusSnapshot {
        let ai = aiResponder.statusSnapshot()
        return ROBMessagesBridgeStatusSnapshot(
            enabled: configuration.enabled,
            state: state,
            detail: detail,
            configuredAccount: configuration.receivingAccount,
            allowedSenderCount: configuration.allowedSenders.count,
            allowAllSenders: configuration.allowAllSenders,
            pendingReplyCount: pendingRoutes.count,
            activeAIChatCount: ai.activeChatCount,
            activeAIProvider: ai.activeProvider,
            lastAIProvider: ai.lastProvider,
            lastAIError: ai.lastError,
            lastInboundAt: lastInboundAt,
            lastReplyAt: lastReplyAt
        )
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        if Thread.isMainThread {
            reloadConfiguration()
        } else {
            DispatchQueue.main.async { [weak self] in self?.reloadConfiguration() }
        }
    }

    private static func postSettingsChange() {
        NotificationCenter.default.post(name: .robMessagesBridgeSettingsDidChange, object: nil)
    }

    private static func loadConfiguration() -> ROBMessagesBridgeConfiguration {
        ROBMessagesBridgeConfiguration(
            enabled: configuredEnabled(),
            receivingAccount: ROBMessagesBridgeConfiguration.canonicalHandle(
                configuredAccountIdentifier()
            ),
            allowedSenders: ROBMessagesBridgeConfiguration.parseAllowedSenders(
                configuredAllowedSendersText()
            ),
            allowAllSenders: configuredAllowAllSenders()
        )
    }

    private func applyCurrentConfiguration() {
        generation &+= 1
        let previousConfiguration = configuration
        let updatedConfiguration = Self.loadConfiguration()
        let authorizationChanged = hasStarted && updatedConfiguration != previousConfiguration
        configuration = updatedConfiguration
        if authorizationChanged {
            // Never process messages accumulated while disabled or under a
            // different account/sender authorization. The next valid enable
            // seeds the then-current MAX(ROWID), while an unchanged app
            // restart continues from its persisted cursor.
            cursor = nil
            UserDefaults.standard.removeObject(forKey: Self.cursorDefaultsKey)
            hasRequestedFullDiskAccessPermission = false
            hasOpenedFullDiskAccessSettings = false
        }
        replyAuthorizationGate.update(
            generation: generation,
            configuration: configuration,
            isActive: false
        )
        pollTimer?.invalidate()
        pollTimer = nil
        pollInFlight = false

        // A local settings change is an authorization-boundary change. Drop
        // every in-flight route before disconnecting its isolated session so
        // a late completion cannot reply after the bridge was disabled or to
        // a chat whose configured receiving account has changed.
        pendingRoutes.removeAll()
        recentSubmissionDates.removeAll()
        aiResponder.shutdown()

        let hasAuthorizedConfiguration = hasStarted &&
            configuration.enabled &&
            !configuration.receivingAccount.isEmpty &&
            (configuration.allowAllSenders || !configuration.allowedSenders.isEmpty) &&
            aiResponder.statusSnapshot().isConfigured
        replyAuthorizationGate.update(
            generation: generation,
            configuration: configuration,
            isActive: hasAuthorizedConfiguration
        )

        guard configuration.enabled else {
            hasRequestedFullDiskAccessPermission = false
            hasOpenedFullDiskAccessSettings = false
            state = "disabled"
            detail = "Messages replies are disabled."
            publishStatus()
            return
        }
        guard !configuration.receivingAccount.isEmpty else {
            state = "configuration required"
            detail = "Enter the Messages account that receives ROB conversations."
            publishStatus()
            return
        }
        guard configuration.allowAllSenders || !configuration.allowedSenders.isEmpty else {
            state = "configuration required"
            detail = "Add at least one locally approved sender before enabling replies."
            publishStatus()
            return
        }
        guard aiResponder.statusSnapshot().isConfigured else {
            state = "AI unavailable"
            detail = "Neither Gemini nor an on-device local text provider is available for the isolated Messages AI profile."
            publishStatus()
            return
        }
        guard checkMessagesAutomationPermission() else {
            return
        }
        requestFullDiskAccessPermissionIfNeeded()

        state = "starting"
        detail = "Checking read-only Messages inbox access."
        let timer = Timer(timeInterval: Self.pollingInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollInbox()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollInbox()
        publishStatus()
    }

    private func pollInbox() {
        guard hasStarted, configuration.enabled, !pollInFlight else { return }
        pollInFlight = true
        let requestGeneration = generation
        let currentCursor = cursor
        let inbox = inbox
        workerQueue.async { [weak self, inbox] in
            let result: Result<ROBMessagesInboxBatch?, Error>
            do {
                if let currentCursor {
                    let currentHighWater = try inbox.highestRowID()
                    if currentHighWater < currentCursor {
                        // Messages may replace chat.db during migration or
                        // account repair. Reseed at the new high-water mark so
                        // the old ROWID cannot suppress every future message,
                        // while still refusing to replay replacement history.
                        result = .success(ROBMessagesInboxBatch(
                            messages: [],
                            highWaterRowID: currentHighWater
                        ))
                    } else {
                        result = .success(try inbox.messages(
                            after: currentCursor,
                            limit: 100
                        ))
                    }
                } else {
                    let highWater = try inbox.highestRowID()
                    result = .success(ROBMessagesInboxBatch(
                        messages: [],
                        highWaterRowID: highWater
                    ))
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishPoll(result, generation: requestGeneration)
            }
        }
    }

    private func finishPoll(
        _ result: Result<ROBMessagesInboxBatch?, Error>,
        generation requestGeneration: UInt64
    ) {
        guard requestGeneration == generation else { return }
        pollInFlight = false
        switch result {
        case .failure(let error):
            if case ROBMessagesInboxError.fullDiskAccessRequired = error {
            state = "Full Disk Access required"
            openFullDiskAccessSettingsIfNeeded()
            } else {
                state = "error"
            }
            detail = error.localizedDescription
            publishStatus()
        case .success(let optionalBatch):
            guard let batch = optionalBatch else { return }
            if cursor != batch.highWaterRowID {
                cursor = batch.highWaterRowID
                UserDefaults.standard.set(
                    NSNumber(value: batch.highWaterRowID),
                    forKey: Self.cursorDefaultsKey
                )
            }
            let now = Date()
            recentSubmissionDates.removeAll {
                now.timeIntervalSince($0) > Self.rapidMessageWindow
            }
            let preservesDeliveryFailure = batch.messages.isEmpty && (
                state == "Automation permission required" ||
                state == "AI unavailable" ||
                state == "error"
            )
            if !preservesDeliveryFailure {
                if batch.messages.isEmpty,
                   recentSubmissionDates.count >= Self.maximumRapidMessages {
                    state = "rate limited"
                    detail = "Messages input is temporarily rate limited to prevent automated loops."
                } else {
                    state = pendingRoutes.isEmpty ? "listening" : "processing"
                    detail = pendingRoutes.isEmpty
                        ? "Listening for approved senders on the configured Messages account."
                        : "Waiting for \(pendingRoutes.count) isolated text reply\(pendingRoutes.count == 1 ? "" : "ies")."
                }
            }
            for message in batch.messages {
                process(message)
            }
            publishStatus()
            if batch.messages.count >= 100 {
                pollInbox()
            }
        }
    }

    private func process(_ message: ROBMessagesInboundMessage) {
        let seen = Set(recentGUIDs)
        guard ROBMessagesBridgePolicy.rejection(
            for: message,
            configuration: configuration,
            now: Date(),
            seenGUIDs: seen
        ) == nil else {
            return
        }
        let now = Date()
        recentSubmissionDates.removeAll {
            now.timeIntervalSince($0) > Self.rapidMessageWindow
        }
        guard recentSubmissionDates.count < Self.maximumRapidMessages else {
            state = "rate limited"
            detail = "Messages input is temporarily rate limited to prevent automated loops."
            return
        }
        recentSubmissionDates.append(now)
        rememberMessageGUID(message.guid)
        lastInboundAt = now

        let contextID = "messages:\(UUID().uuidString.lowercased())"
        pendingRoutes[contextID] = PendingRoute(
            chatID: message.chatID,
            messageGUID: message.guid,
            sender: ROBMessagesBridgeConfiguration.canonicalHandle(message.sender),
            receivingAccount: configuration.receivingAccount,
            generation: generation
        )
        guard let prompt = ROBMessagesPlainTextPolicy.normalized(message.text) else { return }
        aiResponder.submit(
            prompt: prompt,
            chatID: message.chatID,
            contextID: contextID
        ) { [weak self] result in
            self?.finishAIResponse(result, contextID: contextID)
        }
    }

    private func finishAIResponse(_ result: Result<String, Error>, contextID: String) {
        guard let route = pendingRoutes.removeValue(forKey: contextID) else { return }
        guard replyAuthorizationGate.authorizes(
            generation: route.generation,
            account: route.receivingAccount,
            sender: route.sender
        ) else {
            return
        }
        let reply: String
        switch result {
        case .success(let text):
            reply = text
        case .failure(let error):
            state = "AI unavailable"
            detail = error.localizedDescription
            reply = "ROB is temporarily unable to answer in Messages. Please try again shortly."
        }
        let account = route.receivingAccount
        let requestGeneration = route.generation
        let replySender = replySender
        let replyAuthorizationGate = replyAuthorizationGate
        workerQueue.async { [weak self, replySender, replyAuthorizationGate] in
            let sendResult: Result<Void, Error>
            do {
                guard replyAuthorizationGate.authorizes(
                    generation: requestGeneration,
                    account: account,
                    sender: route.sender
                ) else {
                    return
                }
                try replySender.send(
                    text: reply,
                    toChat: route.chatID,
                    account: account,
                    expectedSender: route.sender
                )
                sendResult = .success(())
            } catch {
                sendResult = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishReply(sendResult, generation: requestGeneration)
            }
        }
    }

    private func finishReply(_ result: Result<Void, Error>, generation requestGeneration: UInt64) {
        guard requestGeneration == generation else { return }
        switch result {
        case .success:
            lastReplyAt = Date()
            state = pendingRoutes.isEmpty ? "listening" : "processing"
            detail = pendingRoutes.isEmpty
                ? "Last isolated AI reply was sent to its originating Messages chat."
                : "Waiting for \(pendingRoutes.count) additional Messages replies."
        case .failure(let error):
            if case ROBMessagesReplyError.automationPermissionRequired = error {
                state = "Automation permission required"
            } else {
                state = "error"
            }
            detail = error.localizedDescription
        }
        publishStatus()
    }

    private func rememberMessageGUID(_ guid: String) {
        recentGUIDs.removeAll { $0 == guid }
        recentGUIDs.append(guid)
        if recentGUIDs.count > Self.maximumRecentGUIDs {
            recentGUIDs.removeFirst(recentGUIDs.count - Self.maximumRecentGUIDs)
        }
        UserDefaults.standard.set(recentGUIDs, forKey: Self.recentGUIDsDefaultsKey)
    }

    private func publishStatus() {
        NotificationCenter.default.post(name: .robMessagesBridgeDidChange, object: self)
    }
}
