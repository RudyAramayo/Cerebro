import Foundation

@main
enum ROBFaceConversationPolicyFixtureTests {
    static func main() {
        for reply in [
            "ROB, yes, remember me. My name is Rudy.",
            "Yes, My name is Rudy",
            "Yeah, I'm Rudy",
            "Sure, call me Rudy",
            "Go ahead, my name's Rudy",
            "I'd like that. I'm Rudy.",
            "My name is Rudy, and yes.",
            "Yes, Rudy",
            "My name is Rudy and I'm okay with that",
            "My name is Rudy, it's fine",
            "Uh-huh, my name is Rudy"
        ] {
            expect(exchange([reply]).last == .enroll("Rudy"), "Natural consent and introduction: \(reply)")
        }
        expect(
            exchange(["yes", "my", "name", "is", "Rudy"]) ==
                [.askForName, .continueListening, .continueListening, .continueListening, .enroll("Rudy")],
            "A slow word-by-word answer must keep consent and the unfinished introduction"
        )
        expect(exchange(["yes", "Rudy"]).last == .enroll("Rudy"), "A name alone answers the name question")
        expect(exchange(["yes", "I'm", "Rudy"]).last == .enroll("Rudy"), "A contraction may span fragments")
        expect(
            exchange(["my name", "is", "Rudy", "yes"]).last == .enroll("Rudy"),
            "Name-first fragments must keep the name for follow-up consent"
        )
        expect(exchange(["I", "would like that", "call", "me", "Rudy"]).last == .enroll("Rudy"),
               "Consent and name phrases may both span chunks")
        expect(exchange(["sounds", "good", "my name is Rudy"]).last == .enroll("Rudy"),
               "A natural affirmative may arrive in two chunks")
        expect(
            exchange(["yes", "yes my", "yes my name", "yes my name is", "yes my name is Rudy"]).last == .enroll("Rudy"),
            "Cumulative transcripts must not duplicate the person's words"
        )
        expect(
            exchange(["yes my", "my name", "name is", "is Rudy"]).last == .enroll("Rudy"),
            "Overlapping transcript chunks must preserve the introduction"
        )
        expect(
            exchange(["my name is Rudy", "My name is Rudy.", "yes"]) ==
                [.proposeName("Rudy"), .continueListening, .enroll("Rudy")],
            "Duplicate transcriptions must not repeat prompts or damage the label"
        )
        expect(exchange(["Rudy my name is Rudy"]).last == .proposeName("Rudy"),
               "Repeated introductions must never produce Rudy My Name Is")
        expect(exchange(["yes my name is Rudy my name is", "Rudy"]).last == .enroll("Rudy"),
               "An unfinished repeated introduction must not be stored as a name")
        expect(exchange(["my name is Rudy", "actually my name is Rudy Jr", "yes"]).last == .enroll("Rudy Jr"),
               "An explicit name correction must replace the previous label")
        expect(exchange(["yes, my name is Anne-Marie O'Neill"]).last == .enroll("Anne-Marie O'Neill"),
               "Names retain hyphens and apostrophes")
        expect(exchange(["yes, my name is José"]).last == .enroll("José"), "Names retain accents")
        expect(exchange(["my name is Ada"]) == [.proposeName("Ada")], "A name is not consent")
        expect(exchange(["Rudy"]) == [.proposeName("Rudy")], "A short answer to the invitation still needs consent")
        expect(exchange(["yes, I am okay"]) == [.askForName], "Ordinary adjectives must not become names")

        for reply in [
            "no thanks", "no", "I don't want you to remember me", "please don't store my face",
            "yes, but don't remember me", "not now", "never mind", "never remember me", "I refuse to let you remember me"
        ] {
            expect(exchange(["yes", reply]).last == .decline, "A refusal overrides earlier agreement: \(reply)")
        }
        for reply in [
            "I'm not sure", "maybe", "if I say yes, will you remember me?",
            "he said yes", "what does remember me mean?", "are you going to remember me?"
        ] {
            expect(exchange([reply]).last == .clarifyConsent, "Uncertainty is not consent: \(reply)")
        }
        expect(
            exchange(["yes", "I'm not sure", "my name is Rudy"]).last == .proposeName("Rudy"),
            "Uncertainty withdraws earlier agreement"
        )
        expect(
            exchange(["yes", "tell me a joke", "my name is Rudy"]).last == ROBFaceFriendConversationAction.none,
            "An unrelated request ends the invitation and cannot inherit consent"
        )
        expect(exchange(["my name is Rudy", "not sure", "yes"]).last == .enroll("Rudy"),
               "A later clear affirmative can resolve uncertainty")
        expect(exchange(["what time is it?"]).last == ROBFaceFriendConversationAction.none,
               "Unrelated questions should reach normal conversation")
        expect(exchange(["I agree", "tell me a joke", "my name is Rudy"]).last == ROBFaceFriendConversationAction.none,
               "Completed consent phrases cannot contaminate later unrelated requests")
        expect(exchange(["no thanks", "yes my name is Rudy"]).last == ROBFaceFriendConversationAction.none,
               "Declined invitations cannot be revived by a later fragment")

        var policy = ROBFaceConversationPolicy()
        expect(policy.action(for: "yes my name is Rudy", at: 0) == .none, "No enrollment without an invitation")
        policy.beginInvitation(at: 0)
        expect(policy.action(for: "yes", at: 90) == .askForName, "Allow time to answer the invitation")
        expect(policy.action(for: "my name", at: 180) == .continueListening, "Relevant fragments extend the idle deadline")
        expect(policy.action(for: "is Rudy", at: 270) == .enroll("Rudy"), "A slow reply can take more than one minute")
        policy.beginInvitation(at: 300)
        _ = policy.action(for: "yes", at: 301)
        expect(policy.action(for: "my name is Rudy", at: 422) == .none, "Idle expiry discards old consent")
        policy.beginInvitation(at: 500)
        expect(policy.action(for: "my name is Rudy", at: 501) == .proposeName("Rudy"), "A new invitation starts without consent")
        policy.reset()
        expect(policy.action(for: "yes", at: 502) == .none, "Explicit reset discards the pending name")

        policy.beginInvitation(at: 0)
        for time in stride(from: 90, through: 540, by: 90) {
            _ = policy.action(for: "yes", at: TimeInterval(time))
        }
        expect(policy.action(for: "my name is Rudy", at: 600) == .none, "The exchange has an absolute lifetime bound")
        for reply in ["cancel enrollment", "stop enrollment", "don't remember me", "no thanks", "I've changed my mind"] {
            expect(policy.action(for: reply, enrollmentActive: true, at: 700) == .cancelEnrollment,
                   "Natural cancellation must stop an active enrollment: \(reply)")
        }
        expect(policy.action(for: "my name is Mallory", enrollmentActive: true, at: 701) == .none,
               "An ongoing enrollment does not enroll another person")
        print("ROB face conversation policy fixtures passed")
    }

    private static func exchange(_ fragments: [String]) -> [ROBFaceFriendConversationAction] {
        var policy = ROBFaceConversationPolicy()
        policy.beginInvitation(at: 0)
        return fragments.enumerated().map { index, text in
            policy.action(for: text, at: TimeInterval(index * 10 + 1))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
