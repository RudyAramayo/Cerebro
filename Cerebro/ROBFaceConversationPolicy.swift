//
//  ROBFaceConversationPolicy.swift
//  Cerebro
//
//  Deterministic spoken-consent parsing for hands-free friend enrollment.
//

import Foundation

enum ROBFaceFriendConversationAction: Equatable {
    case none
    case decline
    case askForName
    case proposeName(String)
    case enroll(String)
    case cancelEnrollment
}

enum ROBFaceConversationPolicy {
    static func action(
        for transcript: String,
        invitationActive: Bool,
        enrollmentActive: Bool,
        pendingName: String?
    ) -> ROBFaceFriendConversationAction {
        let normalized = normalizedTranscript(transcript)
        guard !normalized.isEmpty else { return .none }

        if enrollmentActive,
           containsAny(normalized, phrases: [
               "cancel enrollment", "stop enrollment", "do not remember me",
               "don't remember me", "forget me"
           ]) {
            return .cancelEnrollment
        }
        guard invitationActive else { return .none }

        if containsAny(normalized, phrases: [
            "no thanks", "no thank you", "do not remember me", "don't remember me",
            "do not store", "don't store", "not now", "nope"
        ]) || tokenSet(normalized).contains("no") {
            return .decline
        }

        let name = extractedName(from: normalized)
        let words = tokenSet(normalized)
        let explicitlyAgrees = !words.isDisjoint(with: ["yes", "yeah", "yep", "sure", "okay", "ok"])
            || containsAny(normalized, phrases: [
                "remember me", "you can remember", "you may remember",
                "store my face", "enroll me"
            ])

        if explicitlyAgrees {
            if let name { return .enroll(name) }
            if let pendingName { return .enroll(pendingName) }
            return .askForName
        }
        if let name { return .proposeName(name) }
        return .none
    }

    private static func normalizedTranscript(_ transcript: String) -> String {
        transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenSet(_ transcript: String) -> Set<String> {
        Set(transcript.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    private static func containsAny(_ transcript: String, phrases: [String]) -> Bool {
        phrases.contains(where: transcript.contains)
    }

    private static func extractedName(from transcript: String) -> String? {
        let markers = ["my name is ", "call me "]
        guard let match = markers.compactMap({ marker -> (String.Index, String)? in
            guard let range = transcript.range(of: marker) else { return nil }
            return (range.upperBound, marker)
        }).min(by: { $0.0 < $1.0 }) else {
            return nil
        }

        var remainder = String(transcript[match.0...])
        for terminator in [" and ", " please", " thank you", " thanks"] {
            if let range = remainder.range(of: terminator) {
                remainder = String(remainder[..<range.lowerBound])
            }
        }
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-' "))
        let cleaned = String(remainder.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : " " })
        let rejected = Set(["rob", "robbie", "robot", "yes", "no", "okay", "ok"])
        let components = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !rejected.contains($0) }
            .prefix(4)
        guard !components.isEmpty else {
            return nil
        }
        let name = components.joined(separator: " ").localizedCapitalized
        return name.count <= 120 ? name : String(name.prefix(120))
    }
}
