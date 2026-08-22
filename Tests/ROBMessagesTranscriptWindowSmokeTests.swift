import AppKit
import Foundation

// Standalone bridge surface required by the window. Production builds link the
// real ROBMessagesBridge implementation instead.
@MainActor
@objcMembers
final class ROBMessagesBridge: NSObject {
    static func exportMessagesTranscript(to url: URL) -> NSString? { nil }
    static func deleteMessagesTranscript() -> NSString? { nil }
}

@main
@MainActor
private struct ROBMessagesTranscriptWindowSmokeTests {
    static func main() throws {
        let controller = ROBMessagesTranscriptWindowController.shared
        controller.loadWindow()
        guard let window = controller.window else {
            throw SmokeFailure.failed("Transcript browser did not create a window")
        }
        guard window.title == "Messages Transcripts",
              window.styleMask.contains(.resizable),
              window.minSize.width >= 700,
              window.contentView != nil else {
            throw SmokeFailure.failed("Transcript browser window configuration is incomplete")
        }
        controller.close()
        print("ROB Messages transcript window smoke tests passed")
    }

    private enum SmokeFailure: Error {
        case failed(String)
    }
}
