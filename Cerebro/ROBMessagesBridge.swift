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
import CoreImage
import ImageIO
import SQLite3
import UniformTypeIdentifiers

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

enum ROBMessagesAdministratorPolicy {
    static let senderHandles: Set<String> = [
        "orbitus@orbitusrobotics.com",
        "+19253238322",
        "mkierie@gmail.com",
    ]

    static func isAdministrator(_ value: String) -> Bool {
        senderHandles.contains(ROBMessagesBridgeConfiguration.canonicalHandle(value))
    }
}

struct ROBMessagesAdministratorCommand: Codable, Equatable, Sendable {
    let id: String
    var isEnabled: Bool
    var command: String
    var confirmationPrompt: String
    var confirmationResponse: String
    var script: String

    static let shutdown = ROBMessagesAdministratorCommand(
        id: "shutdown",
        isEnabled: true,
        command: "Shutdown",
        confirmationPrompt: "Shut down ROB's computer? Reply YES within 90 seconds to confirm.",
        confirmationResponse: "YES",
        script: #"/usr/bin/osascript -e 'tell application id "com.apple.systemevents" to shut down'"#
    )

    func matches(_ text: String) -> Bool {
        isEnabled && command.caseInsensitiveCompare(text) == .orderedSame
    }

    func confirms(_ text: String) -> Bool {
        confirmationResponse.caseInsensitiveCompare(text) == .orderedSame
    }
}

enum ROBMessagesAdministratorCommandValidationError: LocalizedError {
    case tooMany
    case invalidCommand
    case duplicateCommand(String)
    case invalidConfirmation(String)
    case invalidScript(String)

    var errorDescription: String? {
        switch self {
        case .tooMany:
            return "At most 32 administrator commands may be configured."
        case .invalidCommand:
            return "Each command must be a single line between 1 and 80 characters."
        case .duplicateCommand(let command):
            return "The administrator command \"\(command)\" is duplicated."
        case .invalidConfirmation(let command):
            return "\"\(command)\" needs a confirmation question and a single-line confirmation reply."
        case .invalidScript(let command):
            return "\"\(command)\" needs a UTF-8 shell script no larger than 32 KB."
        }
    }
}

enum ROBMessagesAdministratorCommandStore {
    static let defaultsKey = "ROBMessagesBridgeAdministratorCommandsV1"
    static let maximumCommands = 32
    static let maximumCommandCharacters = 80
    static let maximumPromptCharacters = 500
    static let maximumResponseCharacters = 80
    static let maximumScriptBytes = 32 * 1_024

    static func load(defaults: UserDefaults = .standard) -> [ROBMessagesAdministratorCommand] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                  [ROBMessagesAdministratorCommand].self,
                  from: data
              ),
              let validated = try? validate(decoded) else {
            return [.shutdown]
        }
        return validated
    }

    static func save(
        _ commands: [ROBMessagesAdministratorCommand],
        defaults: UserDefaults = .standard
    ) throws {
        let validated = try validate(commands)
        defaults.set(try JSONEncoder().encode(validated), forKey: defaultsKey)
    }

    static func validate(
        _ commands: [ROBMessagesAdministratorCommand]
    ) throws -> [ROBMessagesAdministratorCommand] {
        guard commands.count <= maximumCommands else {
            throw ROBMessagesAdministratorCommandValidationError.tooMany
        }
        var seen = Set<String>()
        return try commands.map { candidate in
            var command = candidate
            command.command = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
            command.confirmationPrompt = command.confirmationPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
            command.confirmationResponse = command.confirmationResponse
                .trimmingCharacters(in: .whitespacesAndNewlines)
            command.script = command.script.trimmingCharacters(in: .newlines)
            guard !command.id.isEmpty,
                  !command.command.isEmpty,
                  command.command.count <= maximumCommandCharacters,
                  !command.command.contains(where: { $0.isNewline }) else {
                throw ROBMessagesAdministratorCommandValidationError.invalidCommand
            }
            let identity = command.command.lowercased()
            guard seen.insert(identity).inserted else {
                throw ROBMessagesAdministratorCommandValidationError
                    .duplicateCommand(command.command)
            }
            guard !command.confirmationPrompt.isEmpty,
                  command.confirmationPrompt.count <= maximumPromptCharacters,
                  !command.confirmationResponse.isEmpty,
                  command.confirmationResponse.count <= maximumResponseCharacters,
                  !command.confirmationResponse.contains(where: { $0.isNewline }) else {
                throw ROBMessagesAdministratorCommandValidationError
                    .invalidConfirmation(command.command)
            }
            guard !command.script.isEmpty,
                  command.script.utf8.count <= maximumScriptBytes,
                  !command.script.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ROBMessagesAdministratorCommandValidationError
                    .invalidScript(command.command)
            }
            return command
        }
    }
}

struct ROBMessagesBridgeConfiguration: Equatable, Sendable {
    let enabled: Bool
    let receivingAccount: String
    let allowedSenders: Set<String>
    let allowAllSenders: Bool
    let allowsImages: Bool
    let allowsGeminiImages: Bool
    let archivesTranscripts: Bool

    init(
        enabled: Bool,
        receivingAccount: String,
        allowedSenders: Set<String>,
        allowAllSenders: Bool,
        allowsImages: Bool = false,
        allowsGeminiImages: Bool = false,
        archivesTranscripts: Bool = false
    ) {
        self.enabled = enabled
        self.receivingAccount = receivingAccount
        self.allowedSenders = allowedSenders
        self.allowAllSenders = allowAllSenders
        self.allowsImages = allowsImages
        self.allowsGeminiImages = allowsImages && allowsGeminiImages
        self.archivesTranscripts = archivesTranscripts
    }

    static func canonicalHandle(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard trimmed.hasPrefix("+") else { return trimmed }

        // Messages stores phone handles in compact E.164 form even though its
        // UI commonly displays spaces, parentheses, dots, or hyphens. Treat
        // those presentation-only variants as the same explicit +country-code
        // identity without guessing a country code for bare local numbers.
        let allowedPhoneCharacters = CharacterSet(
            charactersIn: "+0123456789 ()-."
        ).union(.whitespaces)
        guard trimmed.unicodeScalars.allSatisfy({
            allowedPhoneCharacters.contains($0)
        }) else {
            return trimmed
        }
        let digits = trimmed.unicodeScalars.compactMap { scalar -> String? in
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            return String(scalar)
        }.joined()
        return digits.count >= 7 ? "+\(digits)" : trimmed
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

    static func normalizedImageCaption(_ value: String?) -> String? {
        guard let value else { return nil }
        // Messages may represent the single joined attachment inside its text
        // payload with U+FFFC. Remove only that known placeholder after policy
        // has proven there is exactly one supported image attachment.
        return normalized(value.replacingOccurrences(of: "\u{FFFC}", with: " "))
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

    static func plainText(
        from archive: Data,
        allowsAttachmentPlaceholder: Bool = false
    ) -> String? {
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
        return allowsAttachmentPlaceholder
            ? ROBMessagesPlainTextPolicy.normalizedImageCaption(decoded)
            : ROBMessagesPlainTextPolicy.normalized(decoded)
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
    private var allowAllSenders = false

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
        allowAllSenders = configuration.allowAllSenders
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
            !sender.isEmpty &&
            sender != receivingAccount &&
            (allowAllSenders ||
                allowedSenders.contains(sender) ||
                ROBMessagesAdministratorPolicy.isAdministrator(sender))
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
    let attachment: ROBMessagesInboundAttachment?
    let chatJoinCount: Int
    let text: String?
    let date: Date?
    let associatedMessageGUID: String?
    let itemType: Int
    let groupActionType: Int
}

struct ROBMessagesInboundAttachment: Equatable, Sendable {
    let filename: String
    let mimeType: String
    let uniformTypeIdentifier: String
    let declaredByteCount: Int64
    let isSticker: Bool

    var isSupportedImageDeclaration: Bool {
        guard !isSticker, !filename.isEmpty else { return false }
        let mime = mimeType.lowercased()
        let uti = uniformTypeIdentifier.lowercased()
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return ["image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif"]
            .contains(mime) ||
            ["public.jpeg", "public.png", "public.heic", "public.heif"]
            .contains(uti) ||
            ["jpg", "jpeg", "png", "heic", "heif"].contains(fileExtension)
    }
}

struct ROBMessagesImageInput: Sendable {
    let jpegData: Data
    let pixelWidth: Int
    let pixelHeight: Int
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
        // The receiving account is not sender authorization. Administrator
        // handles are fixed local policy; every other sender needs the
        // explicit allowlist or deliberately enabled public mode.
        guard configuration.allowAllSenders ||
                configuration.allowedSenders.contains(sender) ||
                ROBMessagesAdministratorPolicy.isAdministrator(sender) else {
            return .senderNotAllowed
        }
        guard message.participantCount == 1 else { return .groupChat }
        guard ROBMessagesBridgeConfiguration.canonicalHandle(message.soleChatParticipant)
                == sender else {
            return .participantMismatch
        }
        guard message.chatJoinCount == 1 else { return .ambiguousChat }
        let hasImage: Bool
        if message.attachmentCount == 0 {
            hasImage = false
        } else {
            guard configuration.allowsImages,
                  message.attachmentCount == 1,
                  message.attachment?.isSupportedImageDeclaration == true else {
                return .attachment
            }
            hasImage = true
        }
        guard !message.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingChat
        }
        guard message.itemType == 0,
              message.groupActionType == 0,
              message.associatedMessageGUID?.isEmpty != false else {
            return .unsupportedEvent
        }
        guard hasImage || ROBMessagesPlainTextPolicy.normalized(message.text) != nil else {
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

protocol ROBMessagesImageLoading: AnyObject, Sendable {
    func loadImage(_ attachment: ROBMessagesInboundAttachment) throws -> ROBMessagesImageInput
}

enum ROBMessagesImageError: LocalizedError {
    case unavailable
    case outsideMessagesAttachments
    case unsupported
    case tooLarge
    case invalidDimensions
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The Messages image attachment is not available on this Mac."
        case .outsideMessagesAttachments:
            return "The image path is outside the Messages attachments directory."
        case .unsupported:
            return "Only a single JPEG, PNG, or HEIC Messages image is supported."
        case .tooLarge:
            return "The Messages image exceeds the safe processing limit."
        case .invalidDimensions:
            return "The Messages image dimensions are invalid or too large."
        case .decodeFailed:
            return "The Messages image could not be decoded safely."
        }
    }
}

final class ROBMessagesImageLoader: ROBMessagesImageLoading, @unchecked Sendable {
    private static let maximumCompressedBytes = 10 * 1_024 * 1_024
    private static let maximumPixelCount = 24_000_000
    private static let maximumDimension = 12_000
    private static let normalizedMaximumDimension = 2_048
    private static let maximumNormalizedJPEGBytes = 4 * 1_024 * 1_024
    private static let allowedSourceTypes = Set([
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.heic.identifier,
        UTType.heif.identifier,
    ])

    private let attachmentsRootURL: URL

    init(attachmentsRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/Attachments", isDirectory: true)) {
        self.attachmentsRootURL = attachmentsRootURL
    }

    func loadImage(_ attachment: ROBMessagesInboundAttachment) throws -> ROBMessagesImageInput {
        guard attachment.isSupportedImageDeclaration else {
            throw ROBMessagesImageError.unsupported
        }
        let expandedPath = (attachment.filename as NSString).expandingTildeInPath
        guard !expandedPath.isEmpty else { throw ROBMessagesImageError.unavailable }
        let root = attachmentsRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let file = URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPrefix) else {
            throw ROBMessagesImageError.outsideMessagesAttachments
        }

        let values: URLResourceValues
        do {
            values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ROBMessagesImageError.unavailable
        }
        guard values.isRegularFile == true else { throw ROBMessagesImageError.unavailable }
        let declaredSize = attachment.declaredByteCount
        let fileSize = values.fileSize ?? 0
        guard fileSize > 0,
              fileSize <= Self.maximumCompressedBytes,
              declaredSize <= 0 || declaredSize <= Self.maximumCompressedBytes else {
            throw ROBMessagesImageError.tooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: file, options: [.mappedIfSafe])
        } catch {
            throw ROBMessagesImageError.unavailable
        }
        guard !data.isEmpty, data.count <= Self.maximumCompressedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source) as String?,
              Self.allowedSourceTypes.contains(sourceType),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ROBMessagesImageError.decodeFailed
        }
        let pixelWidth = width.intValue
        let pixelHeight = height.intValue
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= Self.maximumDimension,
              pixelHeight <= Self.maximumDimension,
              pixelWidth <= Self.maximumPixelCount / pixelHeight else {
            throw ROBMessagesImageError.invalidDimensions
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.normalizedMaximumDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw ROBMessagesImageError.decodeFailed
        }
        let normalized = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            normalized,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ROBMessagesImageError.decodeFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ROBMessagesImageError.decodeFailed
        }
        let jpegData = normalized as Data
        guard !jpegData.isEmpty,
              jpegData.count <= Self.maximumNormalizedJPEGBytes else {
            throw ROBMessagesImageError.tooLarge
        }
        return ROBMessagesImageInput(
            jpegData: jpegData,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}

protocol ROBMessagesReplySending: AnyObject, Sendable {
    func send(
        text: String,
        toChat chatID: String,
        account: String,
        originatingAccountAliases: [String],
        expectedSender: String
    ) throws
}

protocol ROBMessagesAdministratorCommandExecuting: AnyObject, Sendable {
    func execute(script: String) throws
}

enum ROBMessagesAdministratorCommandExecutionError: LocalizedError {
    case invalidScript
    case launchFailed(String)
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidScript:
            return "The administrator command script is empty or invalid."
        case .launchFailed(let detail):
            return "The administrator command could not start: \(detail)"
        case .timedOut:
            return "The administrator command exceeded its 30-second execution limit."
        case .failed(let detail):
            return "The administrator command failed: \(detail)"
        }
    }
}

final class ROBMessagesZshAdministratorCommandExecutor:
    ROBMessagesAdministratorCommandExecuting, @unchecked Sendable {
    private static let executionTimeout: DispatchTimeInterval = .seconds(30)

    func execute(script: String) throws {
        guard !script.isEmpty,
              script.utf8.count <= ROBMessagesAdministratorCommandStore.maximumScriptBytes,
              !script.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ROBMessagesAdministratorCommandExecutionError.invalidScript
        }

        // The operator-authored script is supplied on standard input to a fixed
        // interpreter. Inbound Messages text is never interpolated into a shell
        // command, environment variable, file path, or argument.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-s"]
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            throw ROBMessagesAdministratorCommandExecutionError
                .launchFailed(error.localizedDescription)
        }
        inputPipe.fileHandleForWriting.write(Data(("set -e\n" + script + "\n").utf8))
        try? inputPipe.fileHandleForWriting.close()

        if completion.wait(timeout: .now() + Self.executionTimeout) == .timedOut {
            process.terminate()
            throw ROBMessagesAdministratorCommandExecutionError.timedOut
        }
        guard process.terminationStatus == 0 else {
            throw ROBMessagesAdministratorCommandExecutionError.failed(
                "zsh exited with status \(process.terminationStatus)."
            )
        }
    }
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
            let hasAttachmentTable = try tableExists("attachment", database: database)
            let attachmentColumns = hasAttachmentTable
                ? try columns(in: "attachment", database: database)
                : []
            let requiredMessageColumns: Set<String> = [
                "guid", "text", "handle_id", "is_from_me", "date",
                "associated_message_guid", "item_type", "group_action_type",
            ]
            guard requiredMessageColumns.isSubset(of: messageColumns),
                  chatColumns.contains("guid"),
                  handleColumns.contains("id"),
                  hasAttachmentTable,
                  attachmentColumns.contains("filename"),
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
            func attachmentValue(_ column: String, fallback: String) -> String {
                guard attachmentColumns.contains(column) else { return fallback }
                return """
                (SELECT COALESCE(a.\(column), \(fallback))
                   FROM message_attachment_join attachment_join
                   JOIN attachment a ON a.ROWID = attachment_join.attachment_id
                  WHERE attachment_join.message_id = m.ROWID
                  LIMIT 1)
                """
            }
            let attachmentFilename = attachmentValue("filename", fallback: "''")
            let attachmentMIMEType = attachmentValue("mime_type", fallback: "''")
            let attachmentUTI = attachmentValue("uti", fallback: "''")
            let attachmentBytes = attachmentValue("total_bytes", fallback: "0")
            let attachmentSticker = attachmentValue("is_sticker", fallback: "0")
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
                   \(attachmentFilename),
                   \(attachmentMIMEType),
                   \(attachmentUTI),
                   \(attachmentBytes),
                   \(attachmentSticker),
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
                let attachmentStart = 15
                let chatAccountStart = attachmentStart + 5
                let chatAccounts = chatAccountExpressions.indices.map {
                    string(statement, column: Int32(chatAccountStart + $0)) ?? ""
                }
                let attributedBodyColumn = Int32(
                    chatAccountStart + chatAccountExpressions.count
                )
                let hasDatabaseText = sqlite3_column_int(statement, 13) != 0
                let attachmentCount = Int(sqlite3_column_int(statement, 11))
                let attachmentFilename = string(
                    statement,
                    column: Int32(attachmentStart),
                    maximumBytes: 4_096
                ) ?? ""
                let attachment = attachmentCount > 0 && !attachmentFilename.isEmpty
                    ? ROBMessagesInboundAttachment(
                        filename: attachmentFilename,
                        mimeType: string(
                            statement,
                            column: Int32(attachmentStart + 1),
                            maximumBytes: 256
                        ) ?? "",
                        uniformTypeIdentifier: string(
                            statement,
                            column: Int32(attachmentStart + 2),
                            maximumBytes: 256
                        ) ?? "",
                        declaredByteCount: sqlite3_column_int64(
                            statement,
                            Int32(attachmentStart + 3)
                        ),
                        isSticker: sqlite3_column_int(
                            statement,
                            Int32(attachmentStart + 4)
                        ) != 0
                    )
                    : nil
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
                    ).flatMap {
                        ROBMessagesAttributedBodyDecoder.plainText(
                            from: $0,
                            allowsAttachmentPlaceholder: attachmentCount == 1
                        )
                    }
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
                    attachmentCount: attachmentCount,
                    attachment: attachment,
                    chatJoinCount: Int(sqlite3_column_int(statement, 12)),
                    text: attachmentCount == 1
                        ? ROBMessagesPlainTextPolicy.normalizedImageCaption(selectedText)
                        : ROBMessagesPlainTextPolicy.normalized(selectedText),
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

    var diagnosticDescription: String {
        switch self {
        case .automationPermissionRequired:
            return "Automation permission is required."
        case .timedOut:
            return "Messages send timed out."
        case .failed(let detail):
            let flattened = detail
                .unicodeScalars
                .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
                .joined()
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !flattened.isEmpty else { return "Unknown Messages scripting error." }
            return String(flattened.unicodeScalars.prefix(240).map(String.init).joined())
        }
    }
}

final class ROBMessagesAppleScriptReplySender: ROBMessagesReplySending, @unchecked Sendable {
    private static let maximumAccountAliases = 8
    private static let maximumAccountAliasCharacters = 512

    private static let script = """
    on compactPhonePresentation(candidateValue, expectedValue)
      set candidateText to candidateValue as text
      set expectedText to expectedValue as text
      if expectedText does not start with "+" then return candidateText
      set compactText to ""
      repeat with characterValue in characters of candidateText
        set characterText to characterValue as text
        if characterText is not in {" ", "(", ")", "-", "."} then set compactText to compactText & characterText
      end repeat
      return compactText
    end compactPhonePresentation

    on accountMatchesAlias(accountDescription, accountID, expectedAlias)
      set comparedExpectedAlias to my compactPhonePresentation(expectedAlias, expectedAlias)
      set comparedAccountDescription to my compactPhonePresentation(accountDescription, expectedAlias)
      set comparedAccountID to my compactPhonePresentation(accountID, expectedAlias)
      set colonAccountSuffix to ":" & comparedExpectedAlias
      set semicolonAccountSuffix to ";" & comparedExpectedAlias
      ignoring case
        return comparedAccountDescription is comparedExpectedAlias or comparedAccountID is comparedExpectedAlias or comparedAccountID ends with colonAccountSuffix or comparedAccountID ends with semicolonAccountSuffix
      end ignoring
    end accountMatchesAlias

    on run argv
      if (count of argv) is less than 5 then error "Invalid Cerebro Messages arguments"
      set targetID to item 1 of argv
      set replyText to item 2 of argv
      set expectedAccount to item 3 of argv
      set expectedSender to item 4 of argv
      set expectedAccountAliases to items 5 thru -1 of argv
      tell application id "com.apple.MobileSMS"
        set matchingChats to every chat whose id is targetID
        if (count of matchingChats) is not 1 then error "Originating chat is unavailable"
        set targetChat to item 1 of matchingChats
        set targetAccount to account of targetChat
        set accountDescription to description of targetAccount as text
        set accountID to id of targetAccount as text
        set accountMatchesRoute to false
        repeat with expectedAliasValue in expectedAccountAliases
          if my accountMatchesAlias(accountDescription, accountID, expectedAliasValue as text) then set accountMatchesRoute to true
        end repeat
        if accountMatchesRoute is false then error "Originating chat account changed"
        set targetParticipants to participants of targetChat
        if (count of targetParticipants) is not 1 then error "Originating chat is no longer one-to-one"
        set participantHandle to handle of item 1 of targetParticipants as text
        set comparedParticipantHandle to my compactPhonePresentation(participantHandle, expectedSender)
        set comparedExpectedSender to my compactPhonePresentation(expectedSender, expectedSender)
        set comparedExpectedAccount to my compactPhonePresentation(expectedAccount, expectedAccount)
        ignoring case
          if comparedParticipantHandle is comparedExpectedAccount then error "Originating chat participant is the receiving account"
          if comparedParticipantHandle is not comparedExpectedSender then error "Originating chat participant changed"
        end ignoring
        repeat with expectedAliasValue in expectedAccountAliases
          set expectedAlias to expectedAliasValue as text
          set comparedParticipantAlias to my compactPhonePresentation(participantHandle, expectedAlias)
          set comparedExpectedAlias to my compactPhonePresentation(expectedAlias, expectedAlias)
          ignoring case
            if comparedParticipantAlias is comparedExpectedAlias then error "Originating chat participant is the receiving account"
          end ignoring
        end repeat
        send replyText to targetChat
      end tell
      return "sent"
    end run
    """

    func send(
        text: String,
        toChat chatID: String,
        account: String,
        originatingAccountAliases: [String],
        expectedSender: String
    ) throws {
        let accountAliases = Array(Set(originatingAccountAliases.compactMap { value -> String? in
            guard let normalized = ROBMessagesPlainTextPolicy.normalized(value),
                  normalized.count <= Self.maximumAccountAliasCharacters,
                  !normalized.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                return nil
            }
            let canonical = ROBMessagesBridgeConfiguration.canonicalHandle(normalized)
            return canonical.isEmpty ? nil : canonical
        })).sorted()
        guard let reply = ROBMessagesPlainTextPolicy.normalized(text),
              !chatID.isEmpty,
              !account.isEmpty,
              !expectedSender.isEmpty,
              account.caseInsensitiveCompare(expectedSender) != .orderedSame,
              !accountAliases.isEmpty,
              accountAliases.count <= Self.maximumAccountAliases,
              accountAliases.contains(where: {
                  ROBMessagesBridgePolicy.accountCandidate($0, matches: account)
              }) else {
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
        ] + accountAliases
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
    public let allowsImages: Bool
    public let allowsGeminiImages: Bool
    public let archivesTranscripts: Bool
    public let archivedTransactionCount: Int
    public let lastTranscriptError: String?
    public let pendingReplyCount: Int
    public let activeAIChatCount: Int
    public let activeAIProvider: String?
    public let lastAIProvider: String?
    public let lastAIError: String?
    public let lastDeliveryError: String?
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
    private static let allowsImagesDefaultsKey = "ROBMessagesBridgeAllowsImages"
    private static let allowsGeminiImagesDefaultsKey = "ROBMessagesBridgeAllowsGeminiImages"
    private static let archivesTranscriptsDefaultsKey = "ROBMessagesBridgeArchivesTranscripts"
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
        let originatingAccountAliases: [String]
        let archivesTranscript: Bool
        let generation: UInt64
    }

    private enum AdministratorConfirmationPhase: Equatable, Sendable {
        case sendingQuestion
        case awaitingResponse
    }

    private struct PendingAdministratorConfirmation: Sendable {
        let command: ROBMessagesAdministratorCommand
        let chatID: String
        let sender: String
        let receivingAccount: String
        let originatingAccountAliases: [String]
        let generation: UInt64
        var phase: AdministratorConfirmationPhase
        var expiresAt: Date
    }

    private let inbox: ROBMessagesInboxReading
    private let imageLoader: ROBMessagesImageLoading
    private let transcriptStore: ROBMessagesTranscriptStoring
    private let replySender: ROBMessagesReplySending
    private let administratorCommandExecutor: ROBMessagesAdministratorCommandExecuting
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
    private var pendingAdministratorConfirmations: [String: PendingAdministratorConfirmation] = [:]
    private var administratorCommands: [ROBMessagesAdministratorCommand]
    private var recentSubmissionDates: [Date] = []
    private var state = "disabled"
    private var detail = "Messages replies are disabled."
    private var lastInboundAt: Date?
    private var lastReplyAt: Date?
    private var lastDeliveryError: String?
    private var lastTranscriptError: String?
    private var hasStarted = false
    private var hasRequestedFullDiskAccessPermission = false
    private var hasOpenedFullDiskAccessSettings = false

    private override convenience init() {
        self.init(
            inbox: ROBMessagesSQLiteInbox(),
            imageLoader: ROBMessagesImageLoader(),
            transcriptStore: ROBMessagesTranscriptStore.shared,
            replySender: ROBMessagesAppleScriptReplySender(),
            administratorCommandExecutor: ROBMessagesZshAdministratorCommandExecutor(),
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
        imageLoader: ROBMessagesImageLoading = ROBMessagesImageLoader(),
        transcriptStore: ROBMessagesTranscriptStoring = ROBMessagesTranscriptStore.shared,
        replySender: ROBMessagesReplySending,
        administratorCommandExecutor: ROBMessagesAdministratorCommandExecuting =
            ROBMessagesZshAdministratorCommandExecutor(),
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
        self.imageLoader = imageLoader
        self.transcriptStore = transcriptStore
        self.replySender = replySender
        self.administratorCommandExecutor = administratorCommandExecutor
        self.aiResponder = aiResponder
        self.automationPermissionCheck = automationPermissionCheck
        configuration = Self.loadConfiguration()
        administratorCommands = ROBMessagesAdministratorCommandStore.load()
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

    public static func configuredAdministratorSenderHandles() -> [String] {
        ROBMessagesAdministratorPolicy.senderHandles.sorted()
    }

    public static func hasConfiguredAuthorizedSenders() -> Bool {
        !ROBMessagesAdministratorPolicy.senderHandles.isEmpty ||
            configuredAllowAllSenders() ||
            !ROBMessagesBridgeConfiguration.parseAllowedSenders(
                configuredAllowedSendersText()
            ).isEmpty
    }

    public static func configuredAllowAllSenders() -> Bool {
        UserDefaults.standard.bool(forKey: allowAllSendersDefaultsKey)
    }

    public static func setConfiguredAllowAllSenders(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: allowAllSendersDefaultsKey)
        postSettingsChange()
    }

    public static func configuredAllowsImages() -> Bool {
        UserDefaults.standard.bool(forKey: allowsImagesDefaultsKey)
    }

    public static func setConfiguredAllowsImages(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: allowsImagesDefaultsKey)
        if !value {
            UserDefaults.standard.set(false, forKey: allowsGeminiImagesDefaultsKey)
        }
        postSettingsChange()
    }

    public static func configuredAllowsGeminiImages() -> Bool {
        configuredAllowsImages() &&
            UserDefaults.standard.bool(forKey: allowsGeminiImagesDefaultsKey)
    }

    public static func setConfiguredAllowsGeminiImages(_ value: Bool) {
        UserDefaults.standard.set(
            value && configuredAllowsImages(),
            forKey: allowsGeminiImagesDefaultsKey
        )
        postSettingsChange()
    }

    public static func configuredArchivesTranscripts() -> Bool {
        UserDefaults.standard.bool(forKey: archivesTranscriptsDefaultsKey)
    }

    public static func setConfiguredArchivesTranscripts(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: archivesTranscriptsDefaultsKey)
        postSettingsChange()
    }

    /// Writes a deliberately explicit plaintext JSON export chosen by the
    /// operator. The normal database remains encrypted at rest.
    @objc(exportMessagesTranscriptTo:)
    public static func exportMessagesTranscript(to url: URL) -> NSString? {
        do {
            try ROBMessagesTranscriptStore.shared.exportDecryptedJSON(to: url)
            return nil
        } catch {
            return error.localizedDescription as NSString
        }
    }

    @objc(deleteMessagesTranscript)
    public static func deleteMessagesTranscript() -> NSString? {
        do {
            try ROBMessagesTranscriptStore.shared.deleteAll()
            // Provider sessions and local fallback histories can still retain
            // excerpts already supplied during this process. Reset them so
            // Clear Archive also removes future model access to those excerpts.
            if shared.hasStarted {
                shared.applyCurrentConfiguration()
            }
            return nil
        } catch {
            return error.localizedDescription as NSString
        }
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
        cancelPendingTranscriptTransactions()
        pendingRoutes.removeAll()
        pendingAdministratorConfirmations.removeAll()
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
        let archivedTransactionCount: Int
        if configuration.archivesTranscripts {
            do {
                archivedTransactionCount = try transcriptStore.statistics().transactionCount
            } catch {
                archivedTransactionCount = 0
                lastTranscriptError = error.localizedDescription
                state = "Transcript archive error"
                detail = error.localizedDescription
            }
        } else {
            archivedTransactionCount = 0
        }
        return ROBMessagesBridgeStatusSnapshot(
            enabled: configuration.enabled,
            state: state,
            detail: detail,
            configuredAccount: configuration.receivingAccount,
            allowedSenderCount: configuration.allowedSenders
                .union(ROBMessagesAdministratorPolicy.senderHandles).count,
            allowAllSenders: configuration.allowAllSenders,
            allowsImages: configuration.allowsImages,
            allowsGeminiImages: configuration.allowsGeminiImages,
            archivesTranscripts: configuration.archivesTranscripts,
            archivedTransactionCount: archivedTransactionCount,
            lastTranscriptError: lastTranscriptError,
            pendingReplyCount: pendingRoutes.count + pendingAdministratorConfirmations.count,
            activeAIChatCount: ai.activeChatCount,
            activeAIProvider: ai.activeProvider,
            lastAIProvider: ai.lastProvider,
            lastAIError: ai.lastError,
            lastDeliveryError: lastDeliveryError,
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
            allowAllSenders: configuredAllowAllSenders(),
            allowsImages: configuredAllowsImages(),
            allowsGeminiImages: configuredAllowsGeminiImages(),
            archivesTranscripts: configuredArchivesTranscripts()
        )
    }

    private func applyCurrentConfiguration() {
        generation &+= 1
        let previousConfiguration = configuration
        let updatedConfiguration = Self.loadConfiguration()
        let authorizationChanged = hasStarted && updatedConfiguration != previousConfiguration
        configuration = updatedConfiguration
        administratorCommands = ROBMessagesAdministratorCommandStore.load()
        if !configuration.archivesTranscripts {
            lastTranscriptError = nil
        }
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
        cancelPendingTranscriptTransactions()
        pendingRoutes.removeAll()
        pendingAdministratorConfirmations.removeAll()
        recentSubmissionDates.removeAll()
        aiResponder.shutdown()

        let hasAuthorizedConfiguration = hasStarted &&
            configuration.enabled &&
            !configuration.receivingAccount.isEmpty &&
            (configuration.allowAllSenders ||
                !configuration.allowedSenders.isEmpty ||
                !ROBMessagesAdministratorPolicy.senderHandles.isEmpty)
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
        guard configuration.allowAllSenders ||
                !configuration.allowedSenders.isEmpty ||
                !ROBMessagesAdministratorPolicy.senderHandles.isEmpty else {
            state = "configuration required"
            detail = "Add at least one locally approved sender before enabling replies."
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
            pendingAdministratorConfirmations = pendingAdministratorConfirmations.filter {
                _, pending in
                pending.generation == generation && pending.expiresAt > now
            }
            let preservesDeliveryFailure = batch.messages.isEmpty && (
                state == "Automation permission required" ||
                state == "AI unavailable" ||
                state == "Transcript archive error" ||
                state == "error" ||
                state == "running administrator command"
            )
            if !preservesDeliveryFailure {
                if batch.messages.isEmpty,
                   recentSubmissionDates.count >= Self.maximumRapidMessages {
                    state = "rate limited"
                    detail = "Messages input is temporarily rate limited to prevent automated loops."
                } else if !pendingAdministratorConfirmations.isEmpty {
                    let isSending = pendingAdministratorConfirmations.values.contains {
                        $0.phase == .sendingQuestion
                    }
                    state = isSending ? "processing" : "awaiting administrator confirmation"
                    detail = isSending
                        ? "Delivering an administrator command confirmation question."
                        : "Waiting for an exact administrator command confirmation reply."
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

        let canonicalSender = ROBMessagesBridgeConfiguration.canonicalHandle(message.sender)
        if processAdministratorCommandIfPresent(
            message,
            sender: canonicalSender,
            receivedAt: now
        ) {
            return
        }

        guard aiResponder.statusSnapshot().isConfigured else {
            state = "AI unavailable"
            detail = "Administrator commands remain active, but no isolated Messages AI provider is configured."
            return
        }

        let prompt = ROBMessagesPlainTextPolicy.normalized(message.text)
            ?? "Analyze this image and respond appropriately to the sender."
        let archivedInboundText = ROBMessagesPlainTextPolicy.normalized(message.text)
            ?? "[Image attached without a caption]"

        let contextID = "messages:\(UUID().uuidString.lowercased())"
        let scope = ROBMessagesTranscriptScope(
            receivingAccount: configuration.receivingAccount,
            sender: canonicalSender,
            chatID: message.chatID
        )
        pendingRoutes[contextID] = PendingRoute(
            chatID: message.chatID,
            messageGUID: message.guid,
            sender: scope.sender,
            receivingAccount: configuration.receivingAccount,
            originatingAccountAliases: message.chatAccountCandidates,
            archivesTranscript: configuration.archivesTranscripts,
            generation: generation
        )
        state = "processing"
        detail = message.attachment == nil
            ? "Waiting for \(pendingRoutes.count) isolated text reply\(pendingRoutes.count == 1 ? "" : "ies")."
            : "Safely preparing an approved Messages image for isolated analysis."
        publishStatus()
        let requestGeneration = generation
        let imageLoader = imageLoader
        let transcriptStore = transcriptStore
        let archivesTranscript = configuration.archivesTranscripts
        let attachment = message.attachment
        workerQueue.async { [weak self, imageLoader, transcriptStore] in
            var memoryContext: String?
            var archiveError: Error?
            if archivesTranscript {
                do {
                    try transcriptStore.recordInbound(
                        contextID: contextID,
                        messageGUID: message.guid,
                        scope: scope,
                        text: archivedInboundText,
                        hasImage: attachment != nil,
                        receivedAt: message.date ?? now
                    )
                    memoryContext = try transcriptStore.memoryContext(
                        scope: scope,
                        query: prompt,
                        excludingContextID: contextID
                    )
                } catch {
                    archiveError = error
                    try? transcriptStore.markCancelled(
                        contextIDs: [contextID],
                        at: Date()
                    )
                }
            }
            let imageResult: Result<ROBMessagesImageInput?, Error>
            if archiveError == nil {
                imageResult = Result { try attachment.map(imageLoader.loadImage) }
            } else {
                imageResult = .success(nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      requestGeneration == generation,
                      pendingRoutes[contextID] != nil else {
                    return
                }
                if let archiveError {
                    self.pendingRoutes.removeValue(forKey: contextID)
                    self.lastTranscriptError = archiveError.localizedDescription
                    self.state = "Transcript archive error"
                    self.detail = archiveError.localizedDescription
                    self.publishStatus()
                    return
                }
                switch imageResult {
                case .success(let image):
                    if archivesTranscript {
                        self.lastTranscriptError = nil
                    }
                    self.submitAI(
                        prompt: prompt,
                        image: image,
                        permitsGeminiImage: image != nil &&
                            self.configuration.allowsGeminiImages,
                        memoryContext: memoryContext,
                        chatID: message.chatID,
                        contextID: contextID
                    )
                case .failure(let error):
                    self.finishAIResponse(.failure(error), contextID: contextID)
                }
            }
        }
    }

    private func processAdministratorCommandIfPresent(
        _ message: ROBMessagesInboundMessage,
        sender: String,
        receivedAt now: Date
    ) -> Bool {
        guard ROBMessagesAdministratorPolicy.isAdministrator(sender),
              message.attachmentCount == 0,
              let text = ROBMessagesPlainTextPolicy.normalized(message.text) else {
            return false
        }

        pendingAdministratorConfirmations = pendingAdministratorConfirmations.filter {
            _, pending in
            pending.generation == generation && pending.expiresAt > now
        }
        let key = administratorConfirmationKey(
            account: configuration.receivingAccount,
            sender: sender,
            chatID: message.chatID
        )
        if let pending = pendingAdministratorConfirmations[key] {
            switch pending.phase {
            case .sendingQuestion:
                state = "processing"
                detail = "The administrator confirmation question is still being delivered."
                return true
            case .awaitingResponse:
                pendingAdministratorConfirmations.removeValue(forKey: key)
                if pending.command.confirms(text) {
                    executeAdministratorCommand(pending)
                    return true
                }
            }
        }

        guard let command = administratorCommands.first(where: { $0.matches(text) }) else {
            return false
        }
        requestAdministratorConfirmation(
            for: command,
            message: message,
            sender: sender,
            key: key,
            now: now
        )
        return true
    }

    private func administratorConfirmationKey(
        account: String,
        sender: String,
        chatID: String
    ) -> String {
        [account, sender, chatID].joined(separator: "\u{1f}")
    }

    private func requestAdministratorConfirmation(
        for command: ROBMessagesAdministratorCommand,
        message: ROBMessagesInboundMessage,
        sender: String,
        key: String,
        now: Date
    ) {
        let pending = PendingAdministratorConfirmation(
            command: command,
            chatID: message.chatID,
            sender: sender,
            receivingAccount: configuration.receivingAccount,
            originatingAccountAliases: message.chatAccountCandidates,
            generation: generation,
            phase: .sendingQuestion,
            expiresAt: now.addingTimeInterval(30)
        )
        pendingAdministratorConfirmations[key] = pending
        state = "processing"
        detail = "Sending the confirmation question for administrator command \"\(command.command)\"."
        publishStatus()

        let requestGeneration = generation
        let replySender = replySender
        let authorizationGate = replyAuthorizationGate
        workerQueue.async { [weak self, replySender, authorizationGate] in
            let result = Result<Void, Error> {
                guard authorizationGate.authorizes(
                    generation: requestGeneration,
                    account: pending.receivingAccount,
                    sender: pending.sender
                ) else {
                    throw ROBMessagesReplyError.failed(
                        "Administrator command authorization changed before confirmation delivery."
                    )
                }
                try replySender.send(
                    text: command.confirmationPrompt,
                    toChat: pending.chatID,
                    account: pending.receivingAccount,
                    originatingAccountAliases: pending.originatingAccountAliases,
                    expectedSender: pending.sender
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishAdministratorConfirmationDelivery(
                    result,
                    key: key,
                    commandID: command.id,
                    generation: requestGeneration
                )
            }
        }
    }

    private func finishAdministratorConfirmationDelivery(
        _ result: Result<Void, Error>,
        key: String,
        commandID: String,
        generation requestGeneration: UInt64
    ) {
        guard requestGeneration == generation,
              var pending = pendingAdministratorConfirmations[key],
              pending.command.id == commandID else {
            return
        }
        switch result {
        case .success:
            pending.phase = .awaitingResponse
            pending.expiresAt = Date().addingTimeInterval(90)
            pendingAdministratorConfirmations[key] = pending
            lastReplyAt = Date()
            lastDeliveryError = nil
            state = "awaiting administrator confirmation"
            detail = "Waiting 90 seconds for the exact confirmation reply to \"\(pending.command.command)\"."
        case .failure(let error):
            pendingAdministratorConfirmations.removeValue(forKey: key)
            if let replyError = error as? ROBMessagesReplyError {
                lastDeliveryError = replyError.diagnosticDescription
            } else {
                lastDeliveryError = "Administrator confirmation delivery failed."
            }
            state = "error"
            detail = error.localizedDescription
        }
        publishStatus()
    }

    private func executeAdministratorCommand(_ pending: PendingAdministratorConfirmation) {
        state = "running administrator command"
        detail = "Running confirmed administrator command \"\(pending.command.command)\"."
        publishStatus()

        let requestGeneration = generation
        let executor = administratorCommandExecutor
        let authorizationGate = replyAuthorizationGate
        workerQueue.async { [weak self, executor, authorizationGate] in
            let result = Result<Void, Error> {
                guard authorizationGate.authorizes(
                    generation: requestGeneration,
                    account: pending.receivingAccount,
                    sender: pending.sender
                ) else {
                    throw ROBMessagesAdministratorCommandExecutionError.failed(
                        "authorization changed before execution"
                    )
                }
                try executor.execute(script: pending.command.script)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, requestGeneration == self.generation else { return }
                switch result {
                case .success:
                    self.lastDeliveryError = nil
                    self.state = "listening"
                    self.detail = "Administrator command \"\(pending.command.command)\" completed."
                case .failure(let error):
                    self.lastDeliveryError = error.localizedDescription
                    self.state = "error"
                    self.detail = error.localizedDescription
                }
                self.publishStatus()
            }
        }
    }

    private func submitAI(
        prompt: String,
        image: ROBMessagesImageInput?,
        permitsGeminiImage: Bool,
        memoryContext: String?,
        chatID: String,
        contextID: String
    ) {
        aiResponder.submit(
            prompt: prompt,
            image: image,
            permitsGeminiImage: permitsGeminiImage,
            memoryContext: memoryContext,
            chatID: chatID,
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
            if route.archivesTranscript {
                let transcriptStore = transcriptStore
                workerQueue.async { [transcriptStore] in
                    try? transcriptStore.markCancelled(
                        contextIDs: [contextID],
                        at: Date()
                    )
                }
            }
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
        let transcriptStore = transcriptStore
        workerQueue.async { [weak self, replySender, replyAuthorizationGate, transcriptStore] in
            let sendResult: Result<Void, Error>
            var transcriptError: Error?
            do {
                guard replyAuthorizationGate.authorizes(
                    generation: requestGeneration,
                    account: account,
                    sender: route.sender
                ) else {
                    if route.archivesTranscript {
                        try? transcriptStore.markCancelled(
                            contextIDs: [contextID],
                            at: Date()
                        )
                    }
                    return
                }
                if route.archivesTranscript {
                    do {
                        try transcriptStore.recordReply(
                            contextID: contextID,
                            text: reply,
                            createdAt: Date()
                        )
                    } catch {
                        transcriptError = error
                        try? transcriptStore.markCancelled(
                            contextIDs: [contextID],
                            at: Date()
                        )
                        throw error
                    }
                }
                try replySender.send(
                    text: reply,
                    toChat: route.chatID,
                    account: account,
                    originatingAccountAliases: route.originatingAccountAliases,
                    expectedSender: route.sender
                )
                if route.archivesTranscript {
                    do {
                        try transcriptStore.markDelivered(contextID: contextID, at: Date())
                    } catch {
                        transcriptError = error
                    }
                }
                sendResult = .success(())
            } catch {
                if route.archivesTranscript, transcriptError == nil {
                    do {
                        try transcriptStore.markFailed(
                            contextID: contextID,
                            error: error.localizedDescription,
                            at: Date()
                        )
                    } catch {
                        transcriptError = error
                    }
                }
                sendResult = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishReply(
                    sendResult,
                    transcriptError: transcriptError,
                    generation: requestGeneration
                )
            }
        }
    }

    private func finishReply(
        _ result: Result<Void, Error>,
        transcriptError: Error?,
        generation requestGeneration: UInt64
    ) {
        guard requestGeneration == generation else { return }
        if let transcriptError {
            lastTranscriptError = transcriptError.localizedDescription
        }
        switch result {
        case .success:
            lastReplyAt = Date()
            lastDeliveryError = nil
            state = pendingRoutes.isEmpty ? "listening" : "processing"
            detail = pendingRoutes.isEmpty
                ? "Last isolated AI reply was sent to its originating Messages chat."
                : "Waiting for \(pendingRoutes.count) additional Messages replies."
        case .failure(let error):
            if error is ROBMessagesTranscriptError {
                lastDeliveryError = nil
                state = "Transcript archive error"
            } else if let replyError = error as? ROBMessagesReplyError {
                lastDeliveryError = replyError.diagnosticDescription
            } else {
                lastDeliveryError = "Unexpected Messages delivery error."
            }
            if case ROBMessagesReplyError.automationPermissionRequired = error {
                state = "Automation permission required"
            } else {
                state = "error"
            }
            detail = error.localizedDescription
        }
        if let transcriptError {
            lastDeliveryError = nil
            state = "Transcript archive error"
            detail = transcriptError.localizedDescription
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

    private func cancelPendingTranscriptTransactions() {
        let contextIDs = pendingRoutes.compactMap { contextID, route in
            route.archivesTranscript ? contextID : nil
        }
        guard !contextIDs.isEmpty else { return }
        let transcriptStore = transcriptStore
        workerQueue.async { [transcriptStore] in
            try? transcriptStore.markCancelled(contextIDs: contextIDs, at: Date())
        }
    }

    private func publishStatus() {
        NotificationCenter.default.post(name: .robMessagesBridgeDidChange, object: self)
    }
}
