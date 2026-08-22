import Foundation

private enum VisionReplyPolicyFixtureFailure: Error {
    case failed(String)
}

@main
struct ROBMessagesVisionReplyPolicyFixtureTests {
    static func main() throws {
        let analysis = "A golden retriever is sitting beside a red bicycle on a concrete path."
        let generic = "I understand. I apologize for the inconvenience. If there's anything else I can help you with, feel free to ask."
        try expect(
            ROBMessagesVisionReplyPolicy.preferredReply(
                refined: generic,
                groundedAnalysis: analysis
            ) == analysis,
            "A generic apology replaced the grounded Swift MLX analysis"
        )

        let useful = "A golden retriever is sitting next to a red bicycle."
        try expect(
            ROBMessagesVisionReplyPolicy.preferredReply(
                refined: useful,
                groundedAnalysis: analysis
            ) == useful,
            "A grounded conversational refinement was rejected"
        )

        try expect(
            ROBMessagesVisionReplyPolicy.preferredReply(
                refined: "Tomorrow's weather should be pleasant.",
                groundedAnalysis: analysis
            ) == analysis,
            "An unrelated refinement replaced grounded image content"
        )

        try expect(
            ROBMessagesVisionReplyPolicy.preferredReply(
                refined: "The clearly visible number is 42.",
                groundedAnalysis: "The label displays the number 42 in black text."
            ) == "The clearly visible number is 42.",
            "A visually grounded numeric answer was rejected"
        )

        try expect(
            !ROBMessagesVisionReplyPolicy.isGenericDeflection(
                "I understand why you asked: the diagram shows a damaged red cable."
            ),
            "One natural acknowledgement incorrectly triggered the generic-reply gate"
        )
        print("ROB Messages vision reply policy fixtures passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() { throw VisionReplyPolicyFixtureFailure.failed(message) }
    }
}
