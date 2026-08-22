//
//  ROBMessagesVisionReplyPolicy.swift
//  Cerebro
//
//  Prevents generic language-model acknowledgements from replacing a
//  grounded Messages image analysis.
//

import Foundation

enum ROBMessagesVisionReplyPolicy {
    /// Returns the language-model refinement only when it remains visibly
    /// grounded in the Swift MLX analysis. The analysis is the safe fallback.
    static func preferredReply(
        refined: String?,
        groundedAnalysis: String
    ) -> String {
        let analysis = normalized(groundedAnalysis)
        guard !analysis.isEmpty else { return normalized(refined ?? "") }
        guard let refined else { return analysis }
        let reply = normalized(refined)
        guard !reply.isEmpty,
              !isGenericDeflection(reply),
              isGrounded(reply: reply, analysis: analysis) else {
            return analysis
        }
        return reply
    }

    static func isGenericDeflection(_ value: String) -> Bool {
        let text = normalized(value).lowercased()
        guard !text.isEmpty else { return true }
        let strongDeflections = [
            "sorry for the inconvenience",
            "apologize for the inconvenience",
            "cannot help with that",
            "can't help with that",
            "unable to help with that",
            "do not have access to the image",
            "don't have access to the image",
            "cannot see the image",
            "can't see the image",
            "please provide the image",
            "please upload the image"
        ]
        if strongDeflections.contains(where: text.contains) { return true }

        let genericAcknowledgements = [
            "i understand",
            "i apologize",
            "anything else i can help",
            "anything more i can help",
            "feel free to ask",
            "how else can i assist"
        ]
        return genericAcknowledgements.filter { text.contains($0) }.count >= 2
    }

    private static func isGrounded(reply: String, analysis: String) -> Bool {
        let analysisTerms = groundingTerms(analysis)
        guard !analysisTerms.isEmpty else { return reply == analysis }
        return !analysisTerms.isDisjoint(with: groundingTerms(reply))
    }

    private static func groundingTerms(_ value: String) -> Set<String> {
        let stopWords: Set<String> = [
            "about", "after", "also", "analysis", "appears", "are", "because",
            "been", "before", "being", "can", "could", "does", "from", "have",
            "here", "image", "into", "looks", "more", "photo", "photograph",
            "picture", "request", "sender", "should", "shows", "that", "their",
            "there", "these", "they", "this", "those", "through", "very", "visible",
            "was", "were", "what", "when", "where", "which", "while", "with",
            "would", "your"
        ]
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return Set(folded.split { !$0.isLetter && !$0.isNumber }.compactMap { token in
            let term = String(token).lowercased()
            let isUsefulNumber = term.count >= 1 && term.allSatisfy(\.isNumber)
            let isUsefulWord = term.count >= 3 && !stopWords.contains(term)
            return isUsefulNumber || isUsefulWord ? term : nil
        })
    }

    private static func normalized(_ value: String) -> String {
        value.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
