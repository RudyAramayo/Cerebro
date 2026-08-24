import Foundation

@main
enum ROBFaceConversationPolicyFixtureTests {
    static func main() {
        expect(
            ROBFaceConversationPolicy.action(
                for: "ROB, yes, remember me. My name is Rudy.",
                invitationActive: true,
                enrollmentActive: false,
                pendingName: nil
            ) == .enroll("Rudy"),
            "Explicit consent plus a name must enroll"
        )
        expect(
            ROBFaceConversationPolicy.action(
                for: "ROB, my name is Ada",
                invitationActive: true,
                enrollmentActive: false,
                pendingName: nil
            ) == .proposeName("Ada"),
            "A name without explicit consent must require confirmation"
        )
        expect(
            ROBFaceConversationPolicy.action(
                for: "yes",
                invitationActive: true,
                enrollmentActive: false,
                pendingName: "Ada"
            ) == .enroll("Ada"),
            "Explicit follow-up consent must use the pending name"
        )
        expect(
            ROBFaceConversationPolicy.action(
                for: "yes, I am okay",
                invitationActive: true,
                enrollmentActive: false,
                pendingName: nil
            ) == .askForName,
            "Ordinary words after I am must not become a face label"
        )
        expect(
            ROBFaceConversationPolicy.action(
                for: "no thanks",
                invitationActive: true,
                enrollmentActive: false,
                pendingName: nil
            ) == .decline,
            "Declining must never enroll"
        )
        expect(
            ROBFaceConversationPolicy.action(
                for: "ROB, cancel enrollment",
                invitationActive: false,
                enrollmentActive: true,
                pendingName: nil
            ) == .cancelEnrollment,
            "Spoken cancellation must stop hands-free enrollment"
        )
        expect(
            ROBFaceConversationPolicy.action(
                for: "my name is Mallory",
                invitationActive: false,
                enrollmentActive: false,
                pendingName: nil
            ) == .none,
            "Names outside an active invitation must be ignored"
        )
        print("ROB face conversation policy fixtures passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        precondition(condition(), message)
    }
}
