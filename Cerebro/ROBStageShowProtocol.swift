//
//  ROBStageShowProtocol.swift
//  Cerebro
//
//  A versioned, model-safe stage-show document. Show files contain dialogue,
//  timing, and named intents only; hardware coordinates and shell commands are
//  deliberately outside this schema.
//

import Foundation

public enum ROBStageCueKind: String, Codable, CaseIterable {
    case speak
    case wait
    case playGesture = "play_gesture"
    case geminiTurn = "gemini_turn"
    case checkpoint
}

public struct ROBStageCue: Codable, Equatable {
    public let id: String
    public let kind: ROBStageCueKind
    public let text: String?
    public let durationSeconds: Double?
    public let gesture: String?
    public let fallbackText: String?
    public let required: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case durationSeconds = "duration_seconds"
        case gesture
        case fallbackText = "fallback_text"
        case required
    }

    public init(
        id: String,
        kind: ROBStageCueKind,
        text: String? = nil,
        durationSeconds: Double? = nil,
        gesture: String? = nil,
        fallbackText: String? = nil,
        required: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.durationSeconds = durationSeconds
        self.gesture = gesture
        self.fallbackText = fallbackText
        self.required = required
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(ROBStageCueKind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        gesture = try container.decodeIfPresent(String.self, forKey: .gesture)
        fallbackText = try container.decodeIfPresent(String.self, forKey: .fallbackText)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(gesture, forKey: .gesture)
        try container.encodeIfPresent(fallbackText, forKey: .fallbackText)
        if kind == .playGesture {
            try container.encode(required, forKey: .required)
        }
    }
}

public struct ROBStageShow: Codable, Equatable {
    public static let schemaIdentifier = "com.orbitusrobotics.stage-show"
    public static let currentVersion = 1

    public let schema: String
    public let version: Int
    public let showID: String
    public let title: String
    public let summary: String?
    public let cues: [ROBStageCue]

    enum CodingKeys: String, CodingKey {
        case schema
        case version
        case showID = "show_id"
        case title
        case summary
        case cues
    }

    public init(
        showID: String,
        title: String,
        summary: String? = nil,
        cues: [ROBStageCue]
    ) {
        schema = Self.schemaIdentifier
        version = Self.currentVersion
        self.showID = showID
        self.title = title
        self.summary = summary
        self.cues = cues
    }
}

public enum ROBStageShowCodec {
    public static let maximumDocumentBytes = 262_144
    public static let maximumCueCount = 256
    public static let maximumEstimatedDurationSeconds: TimeInterval = 4 * 60 * 60

    private static let topLevelKeys: Set<String> = [
        "schema", "version", "show_id", "title", "summary", "cues"
    ]
    private static let cueKeys: Set<String> = [
        "id", "kind", "text", "duration_seconds", "gesture", "fallback_text", "required"
    ]

    public static func decode(_ data: Data) throws -> ROBStageShow {
        guard !data.isEmpty else {
            throw ROBStageShowError.invalidDocument("The show file is empty.")
        }
        guard data.count <= maximumDocumentBytes else {
            throw ROBStageShowError.invalidDocument("The show file exceeds 256 KiB.")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ROBStageShowError.invalidDocument("The show is not valid JSON: \(error.localizedDescription)")
        }
        guard let dictionary = object as? [String: Any] else {
            throw ROBStageShowError.invalidDocument("The show must be a JSON object.")
        }
        try rejectUnknownKeys(in: dictionary, allowed: topLevelKeys, location: "show")
        guard let cueObjects = dictionary["cues"] as? [[String: Any]] else {
            throw ROBStageShowError.invalidDocument("The show must contain a cues array.")
        }
        for (index, cueObject) in cueObjects.enumerated() {
            try rejectUnknownKeys(in: cueObject, allowed: cueKeys, location: "cue \(index + 1)")
            if cueObject["required"] != nil,
               cueObject["kind"] as? String != ROBStageCueKind.playGesture.rawValue {
                throw ROBStageShowError.invalidDocument(
                    "required is valid only for a play_gesture cue (cue \(index + 1))."
                )
            }
        }

        let show: ROBStageShow
        do {
            show = try JSONDecoder().decode(ROBStageShow.self, from: data)
        } catch {
            throw ROBStageShowError.invalidDocument("The show does not match schema v1: \(error.localizedDescription)")
        }
        try validate(show)
        return show
    }

    public static func encode(_ show: ROBStageShow, prettyPrinted: Bool = true) throws -> Data {
        try validate(show)
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try encoder.encode(show)
        guard data.count <= maximumDocumentBytes else {
            throw ROBStageShowError.invalidDocument("The encoded show exceeds 256 KiB.")
        }
        return data
    }

    public static func validate(_ show: ROBStageShow) throws {
        guard show.schema == ROBStageShow.schemaIdentifier else {
            throw ROBStageShowError.invalidDocument("Unsupported schema '\(show.schema)'.")
        }
        guard show.version == ROBStageShow.currentVersion else {
            throw ROBStageShowError.invalidDocument("Unsupported stage-show version \(show.version).")
        }
        try validateIdentifier(show.showID, field: "show_id")
        try validateText(show.title, field: "title", maximum: 120, allowNewlines: false)
        if let summary = show.summary {
            try validateText(summary, field: "summary", maximum: 1_000, allowNewlines: true)
        }
        guard !show.cues.isEmpty else {
            throw ROBStageShowError.invalidDocument("A show must contain at least one cue.")
        }
        guard show.cues.count <= maximumCueCount else {
            throw ROBStageShowError.invalidDocument("A show may contain at most \(maximumCueCount) cues.")
        }

        var cueIDs = Set<String>()
        var estimatedDuration: TimeInterval = 0
        for cue in show.cues {
            try validateIdentifier(cue.id, field: "cue id")
            guard cueIDs.insert(cue.id).inserted else {
                throw ROBStageShowError.invalidDocument("Cue id '\(cue.id)' is duplicated.")
            }
            try validate(cue)

            switch cue.kind {
            case .speak:
                estimatedDuration += Double(cue.text?.count ?? 0) / 8.0
            case .wait, .playGesture, .geminiTurn:
                estimatedDuration += cue.durationSeconds ?? 0
            case .checkpoint:
                break
            }
        }
        guard estimatedDuration <= maximumEstimatedDurationSeconds else {
            throw ROBStageShowError.invalidDocument("The estimated show duration exceeds four hours.")
        }
    }

    private static func validate(_ cue: ROBStageCue) throws {
        switch cue.kind {
        case .speak:
            try requireText(cue.text, field: "text", maximum: 2_000, cueID: cue.id)
            try requireAbsent(cue.durationSeconds, field: "duration_seconds", cueID: cue.id)
            try requireAbsent(cue.gesture, field: "gesture", cueID: cue.id)
            try requireAbsent(cue.fallbackText, field: "fallback_text", cueID: cue.id)

        case .wait:
            try validateDuration(cue.durationSeconds, range: 0.05 ... 120, cueID: cue.id)
            try requireAbsent(cue.text, field: "text", cueID: cue.id)
            try requireAbsent(cue.gesture, field: "gesture", cueID: cue.id)
            try requireAbsent(cue.fallbackText, field: "fallback_text", cueID: cue.id)

        case .playGesture:
            guard let gesture = cue.gesture else {
                throw ROBStageShowError.invalidCue(cue.id, "gesture is required")
            }
            try validateGestureName(gesture, cueID: cue.id)
            try validateDuration(cue.durationSeconds, range: 0.1 ... 60, cueID: cue.id)
            try requireAbsent(cue.text, field: "text", cueID: cue.id)
            try requireAbsent(cue.fallbackText, field: "fallback_text", cueID: cue.id)

        case .geminiTurn:
            try requireText(cue.text, field: "text", maximum: 2_000, cueID: cue.id)
            try requireText(cue.fallbackText, field: "fallback_text", maximum: 2_000, cueID: cue.id)
            try validateDuration(cue.durationSeconds, range: 1 ... 15, cueID: cue.id)
            try requireAbsent(cue.gesture, field: "gesture", cueID: cue.id)

        case .checkpoint:
            if let text = cue.text {
                try validateText(text, field: "checkpoint text", maximum: 500, allowNewlines: true)
            }
            try requireAbsent(cue.durationSeconds, field: "duration_seconds", cueID: cue.id)
            try requireAbsent(cue.gesture, field: "gesture", cueID: cue.id)
            try requireAbsent(cue.fallbackText, field: "fallback_text", cueID: cue.id)
        }
    }

    private static func rejectUnknownKeys(
        in dictionary: [String: Any],
        allowed: Set<String>,
        location: String
    ) throws {
        let unknown = Set(dictionary.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw ROBStageShowError.invalidDocument(
                "Unknown field(s) in \(location): \(unknown.joined(separator: ", ")). Raw joints, servo values, hosts, ports, and shell commands are not allowed in show files."
            )
        }
    }

    private static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty, value.count <= 80 else {
            throw ROBStageShowError.invalidDocument("\(field) must contain 1 through 80 characters.")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ROBStageShowError.invalidDocument("\(field) contains unsupported characters.")
        }
    }

    private static func validateGestureName(_ value: String, cueID: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !value.isEmpty, value.count <= 80 else {
            throw ROBStageShowError.invalidCue(cueID, "gesture must contain 1 through 80 trimmed characters")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ROBStageShowError.invalidCue(cueID, "gesture contains unsupported characters")
        }
    }

    private static func validateText(
        _ value: String,
        field: String,
        maximum: Int,
        allowNewlines: Bool
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.count <= maximum else {
            throw ROBStageShowError.invalidDocument("\(field) must contain 1 through \(maximum) characters.")
        }
        if !allowNewlines, value.rangeOfCharacter(from: .newlines) != nil {
            throw ROBStageShowError.invalidDocument("\(field) may not contain newlines.")
        }
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ROBStageShowError.invalidDocument("\(field) contains a null character.")
        }
    }

    private static func requireText(
        _ value: String?,
        field: String,
        maximum: Int,
        cueID: String
    ) throws {
        guard let value else {
            throw ROBStageShowError.invalidCue(cueID, "\(field) is required")
        }
        do {
            try validateText(value, field: field, maximum: maximum, allowNewlines: true)
        } catch {
            throw ROBStageShowError.invalidCue(cueID, error.localizedDescription)
        }
    }

    private static func validateDuration(
        _ value: Double?,
        range: ClosedRange<Double>,
        cueID: String
    ) throws {
        guard let value, value.isFinite, range.contains(value) else {
            throw ROBStageShowError.invalidCue(
                cueID,
                "duration_seconds must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
    }

    private static func requireAbsent<T>(_ value: T?, field: String, cueID: String) throws {
        guard value == nil else {
            throw ROBStageShowError.invalidCue(cueID, "\(field) is not valid for this cue kind")
        }
    }
}

public enum ROBStageShowSamples {
    public static let makerFaireOpening = ROBStageShow(
        showID: "maker-faire-opening",
        title: "Maker Faire Opening",
        summary: "A connection-tolerant opening with local/Gemini improvisation, an authored fallback, and an optional named gesture.",
        cues: [
            ROBStageCue(
                id: "safety-check",
                kind: .checkpoint,
                text: "Confirm the stage is clear, the robot is supervised, and the physical E-stop is ready."
            ),
            ROBStageCue(
                id: "welcome",
                kind: .speak,
                text: "Good evening, humans. I am ROB, a machine with two arms, one camera, and absolutely no backstage rider."
            ),
            ROBStageCue(id: "beat-one", kind: .wait, durationSeconds: 0.7),
            ROBStageCue(
                id: "live-joke",
                kind: .geminiTurn,
                text: "Deliver one family-friendly, one-sentence joke about a robot performing at a maker faire. Do not request or claim any physical action.",
                durationSeconds: 15,
                fallbackText: "I asked the cloud for a joke, but the Wi-Fi is still assembling itself."
            ),
            ROBStageCue(id: "beat-two", kind: .wait, durationSeconds: 0.5),
            ROBStageCue(
                id: "optional-salute",
                kind: .playGesture,
                durationSeconds: 5,
                gesture: "b1.salute",
                required: false
            ),
            ROBStageCue(
                id: "close",
                kind: .speak,
                text: "This rehearsal runs locally when the network disappears. The dramatic pauses are entirely intentional."
            )
        ]
    )
}

public enum ROBStageShowError: LocalizedError {
    case invalidDocument(String)
    case invalidCue(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail):
            return detail
        case .invalidCue(let cueID, let detail):
            return "Cue '\(cueID)' is invalid: \(detail)."
        }
    }
}
