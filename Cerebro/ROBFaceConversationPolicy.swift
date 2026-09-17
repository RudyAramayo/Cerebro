//
//  ROBFaceConversationPolicy.swift
//  Cerebro
//
//  Invitation-scoped intent and speech-fragment memory for friend enrollment.
//

import Foundation

enum ROBFaceFriendConversationAction: Equatable {
    case none
    case continueListening
    case decline
    case askForName
    case proposeName(String)
    case clarifyConsent
    case enroll(String)
    case cancelEnrollment
}

struct ROBFaceConversationPolicy {
    // Each relevant reply gives a slow speaker more time, without retaining
    // consent indefinitely or carrying it into another person's invitation.
    static let invitationIdleLifetime: TimeInterval = 120
    static let invitationMaximumLifetime: TimeInterval = 600

    private(set) var invitationExpiresAtUptime: TimeInterval?
    private var invitationDeadlineUptime: TimeInterval = 0
    private var fragments: [String] = []
    private var consentConfirmed = false
    private var pendingName: String?
    private var lastPrompt: ROBFaceFriendConversationAction?

    mutating func beginInvitation(at now: TimeInterval) {
        reset()
        invitationExpiresAtUptime = now + Self.invitationIdleLifetime
        invitationDeadlineUptime = now + Self.invitationMaximumLifetime
    }

    mutating func reset() { self = Self() }

    @discardableResult mutating func expireInvitationIfNeeded(at now: TimeInterval) -> Bool {
        guard let expiration = invitationExpiresAtUptime, now >= expiration else { return false }
        reset()
        return true
    }

    mutating func action(
        for transcript: String,
        enrollmentActive: Bool = false,
        at now: TimeInterval
    ) -> ROBFaceFriendConversationAction {
        expireInvitationIfNeeded(at: now)
        let words = Self.words(in: transcript)
        guard !words.isEmpty else { return .none }

        if enrollmentActive {
            return Self.declines(words) ? .cancelEnrollment : .none
        }
        guard invitationExpiresAtUptime != nil else { return .none }

        let combined = Self.merging(fragments, with: words)
        // A current refusal overrides remembered agreement. Negated or
        // hypothetical agreement must never become consent via a "yes" token.
        if Self.declines(words) || Self.declines(combined) {
            reset()
            return .decline
        }
        if Self.isUncertain(words) {
            guard Self.contains(words, phrases: [
                "not", "maybe", "perhaps", "might", "if", "whether", "cannot", "said", "say",
                "face", "remember", "enroll", "consent", "permission", "yes"
            ]) else {
                reset()
                return .none
            }
            consentConfirmed = false
            fragments = []
            refreshDeadline(at: now)
            return promptOnce(.clarifyConsent)
        }

        let name = Self.extractedName(from: combined)
            ?? (pendingName == nil && fragments.isEmpty ? Self.bareName(in: words) : nil)
            ?? (pendingName == nil && consentConfirmed ? Self.bareName(in: words) : nil)
            ?? (Self.agrees(words) ? Self.bareName(in: Array(Self.withoutAddress(words).drop(while: Self.affirmatives.contains))) : nil)
        let agrees = Self.agrees(words) || Self.agrees(combined)
            || (name != nil && words.last.map(Self.affirmatives.contains) == true)
        let continuation = Self.incompletePhrase(in: combined)
        guard agrees || name != nil || !continuation.isEmpty else {
            // An unrelated request ends this exchange; its words must not be
            // combined with a later "yes" or become part of a person's name.
            reset()
            return .none
        }

        fragments = continuation
        refreshDeadline(at: now)
        if agrees { consentConfirmed = true }
        if let name { pendingName = name }
        if consentConfirmed, let pendingName { return .enroll(pendingName) }
        if let pendingName { return promptOnce(.proposeName(pendingName)) }
        if consentConfirmed { return promptOnce(.askForName) }
        return .continueListening
    }

    private mutating func refreshDeadline(at now: TimeInterval) {
        invitationExpiresAtUptime = min(now + Self.invitationIdleLifetime, invitationDeadlineUptime)
    }

    private mutating func promptOnce(_ action: ROBFaceFriendConversationAction) -> ROBFaceFriendConversationAction {
        guard lastPrompt != action else { return .continueListening }
        lastPrompt = action
        return action
    }

    private static func words(in transcript: String) -> [String] {
        var text = transcript.lowercased().replacingOccurrences(of: "’", with: "'")
        for (contraction, expansion) in [
            ("i'm", "i am"), ("it's", "it is"), ("that's", "that is"),
            ("name's", "name is"), ("don't", "do not"), ("can't", "cannot"),
            ("i'd", "i would"), ("isn't", "is not"), ("uh huh", "yes"), ("uh-huh", "yes")
        ] {
            text = text.replacingOccurrences(of: "\\b\(contraction)\\b", with: expansion, options: .regularExpression)
        }
        return text.components(separatedBy: CharacterSet.letters
            .union(.decimalDigits).union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty && $0 != "um" && $0 != "uh" }
    }

    private static func merging(_ previous: [String], with next: [String]) -> [String] {
        guard !previous.isEmpty else { return next }
        // Apple Speech may repeat a cumulative hypothesis; another provider
        // may send just a suffix or overlapping chunks of the same sentence.
        if next.starts(with: previous) { return next }
        if previous.starts(with: next) || previous.suffix(next.count).elementsEqual(next) { return previous }
        for count in stride(from: min(previous.count, next.count), through: 1, by: -1) {
            if previous.suffix(count).elementsEqual(next.prefix(count)) {
                return previous + next.dropFirst(count)
            }
        }
        return previous + next
    }

    private static func contains(_ words: [String], phrases: [String]) -> Bool {
        let text = " " + words.joined(separator: " ") + " "
        return phrases.contains { text.contains(" " + $0 + " ") }
    }

    private static func withoutAddress(_ words: [String]) -> [String] {
        Array(words.drop(while: { ["rob", "robbie", "robot", "hey", "hello", "hi", "well"].contains($0) }))
    }

    private static func declines(_ words: [String]) -> Bool {
        let reply = withoutAddress(words)
        return reply.first == "no" || reply.first == "nope" || contains(reply, phrases: [
            "no thanks", "no thank you", "do not remember", "do not store",
            "do not save", "do not enroll", "do not want", "not now", "not interested",
            "never remember", "never store", "never save", "never enroll", "i refuse", "i decline",
            "cancel", "stop", "forget me", "never mind", "changed my mind"
        ])
    }

    private static func isUncertain(_ words: [String]) -> Bool {
        contains(words, phrases: [
            "not", "maybe", "perhaps", "might", "if", "whether", "cannot",
            "what", "why", "how", "should", "said", "say", "does", "do you", "can you",
            "are you", "will you", "would you", "could you", "can i", "may i", "did you"
        ])
    }

    private static func agrees(_ words: [String]) -> Bool {
        guard !isUncertain(words) else { return false }
        let reply = withoutAddress(words)
        if let first = reply.first, affirmatives.contains(first) {
            return true
        }
        return contains(reply, phrases: consentPhrases)
    }

    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "okay", "ok", "absolutely", "certainly", "fine"
    ]

    private static let consentPhrases = [
        "remember me", "remember my face", "save my face", "store my face", "enroll me",
        "i agree", "i consent", "you have my permission", "you have permission", "i give you permission",
        "go ahead", "sounds good", "that is fine", "that is okay", "it is okay", "it is fine", "please do",
        "i am okay with that", "i am fine with that", "i would like that", "i would love that"
    ]

    private static let nameMarkers = [
        ["my", "name", "is"], ["the", "name", "is"], ["call", "me"],
        ["i", "am"], ["it", "is"], ["this", "is"]
    ]

    private static func extractedName(from words: [String]) -> String? {
        // The most recent introduction wins, so a correction is not appended
        // to the previous name. Consent remains its own invitation-scoped slot.
        for start in words.indices.reversed() {
            for marker in nameMarkers where words[start...].starts(with: marker) {
                let tail = Array(words.dropFirst(start + marker.count))
                guard !tail.isEmpty else { return nil }
                let nameWords = Array(tail.prefix(while: { !nameTerminators.contains($0) }))
                if let name = bareName(in: nameWords) { return name }
            }
        }
        return nil
    }

    private static func incompletePhrase(in words: [String]) -> [String] {
        var longest: [String] = []
        // Keep full name introducers, but only unfinished consent phrases.
        // A completed "I agree" lives in consentConfirmed, not in the buffer
        // where it could turn a later unrelated request into agreement.
        let consentPrefixes = consentPhrases.map { Array($0.components(separatedBy: " ").dropLast()) }
        for marker in nameMarkers + consentPrefixes {
            for count in 1...marker.count where words.suffix(count).elementsEqual(marker.prefix(count)) {
                if count > longest.count { longest = Array(words.suffix(count)) }
            }
        }
        return longest
    }

    private static let nameTerminators: Set<String> = [
        "and", "but", "please", "thank", "thanks", "yes", "yeah", "yep", "yup",
        "sure", "okay", "ok", "you", "i", "remember", "save", "store", "enroll",
        "go", "sounds", "that", "it", "this", "my"
    ]

    private static func bareName(in words: [String]) -> String? {
        let rejected: Set<String> = nameTerminators.union([
            "my", "name", "is", "am", "it", "this", "the", "call", "me", "a", "to", "of",
            "no", "nope", "not", "do", "can", "may", "will", "would", "could", "should",
            "what", "why", "how", "who", "where", "when", "if", "whether", "said", "say",
            "hello", "hi", "hey", "well", "fine", "good", "great", "happy", "ready", "here",
            "maybe", "perhaps", "hmm", "huh", "absolutely", "certainly", "permission",
            "agree", "consent", "want", "like", "tell", "play", "help", "stop", "cancel", "wait"
        ])
        guard (1...4).contains(words.count),
              words.allSatisfy({ word in
                  !rejected.contains(word) && word.unicodeScalars.contains(where: CharacterSet.letters.contains)
                      && word.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || "'-".unicodeScalars.contains($0) }
              }) else { return nil }
        let name = words.joined(separator: " ").components(separatedBy: "'")
            .map(\.localizedCapitalized).joined(separator: "'")
        return name.count <= 120 ? name : nil
    }
}
