import AppKit
import Foundation

// Standalone bridge surface required by the window. Production builds link the
// real ROBMessagesBridge implementation instead.
@MainActor
@objcMembers
final class ROBMessagesBridge: NSObject {
    static let shared = ROBMessagesBridge()

    static func exportMessagesTranscript(to url: URL) -> NSString? { nil }
    static func deleteMessagesTranscript() -> NSString? { nil }

    func statusSnapshot() -> ROBMessagesBridgeStatusSnapshot {
        ROBMessagesBridgeStatusSnapshot(
            enabled: true,
            state: "listening",
            detail: "Ready",
            archivesTranscripts: true
        )
    }

    @nonobjc func sendOperatorReply(
        text: String,
        to record: ROBMessagesTranscriptRecord,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        completion(.success(()))
    }
}

struct ROBMessagesBridgeStatusSnapshot {
    let enabled: Bool
    let state: String
    let detail: String
    let archivesTranscripts: Bool
}

extension Notification.Name {
    static let robMessagesBridgeSettingsDidChange = Notification.Name(
        "ROBMessagesBridgeSettingsDidChange"
    )
    static let robMessagesBridgeDidChange = Notification.Name(
        "ROBMessagesBridgeDidChange"
    )
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

        let workspace = ROBMessagesWorkspaceViewController()
        workspace.loadView()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 600, height: 680)
        workspace.view.layoutSubtreeIfNeeded()
        let workspaceViews = descendants(of: workspace.view)
        guard workspaceViews.contains(where: {
            ($0 as? NSSearchField)?.placeholderString == "Search people and message text"
        }), workspaceViews.contains(where: {
            ($0 as? NSButton)?.title == "Reply"
        }), workspaceViews.contains(where: {
            ($0 as? NSTextField)?.stringValue == "Text Messages"
        }) else {
            throw SmokeFailure.failed(
                "Embedded Messages workspace does not expose search, transcript, and reply controls"
            )
        }
        guard !workspace.view.hasAmbiguousLayout,
              !workspaceViews.contains(where: \.hasAmbiguousLayout) else {
            throw SmokeFailure.failed("Embedded Messages workspace has ambiguous layout constraints")
        }

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_272, height: 730))
        let aiPane = NSView()
        let messagesPane = workspace.view
        aiPane.translatesAutoresizingMaskIntoConstraints = false
        messagesPane.translatesAutoresizingMaskIntoConstraints = false
        let communicationSplit = NSSplitView()
        communicationSplit.isVertical = true
        communicationSplit.addArrangedSubview(aiPane)
        communicationSplit.addArrangedSubview(messagesPane)
        communicationSplit.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(communicationSplit)
        NSLayoutConstraint.activate([
            communicationSplit.topAnchor.constraint(equalTo: host.topAnchor),
            communicationSplit.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            communicationSplit.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            communicationSplit.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            aiPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            messagesPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 430),
        ])
        host.layoutSubtreeIfNeeded()
        guard aiPane.frame.width >= 500,
              messagesPane.frame.width >= 430,
              aiPane.frame.height > 0,
              messagesPane.frame.height > 0 else {
            throw SmokeFailure.failed(
                "Main communication split collapsed a transcript pane: " +
                "AI \(aiPane.frame), Messages \(messagesPane.frame)"
            )
        }

        controller.close()
        print("ROB Messages transcript window smoke tests passed")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { subview in
            [subview] + descendants(of: subview)
        }
    }

    private enum SmokeFailure: Error {
        case failed(String)
    }
}
