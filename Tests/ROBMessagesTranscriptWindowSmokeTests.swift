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

        try verifyRefreshPreservesReadingPosition(workspace, host: host)

        controller.close()
        print("ROB Messages transcript window smoke tests passed")
    }

    private static func verifyRefreshPreservesReadingPosition(
        _ workspace: ROBMessagesWorkspaceViewController,
        host: NSView
    ) throws {
        let hostWindow = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = host
        defer { hostWindow.close() }
        let views = descendants(of: workspace.view)
        guard let transcript = views.compactMap({ $0 as? NSTextView }).first,
              let scroll = transcript.enclosingScrollView,
              let search = views.compactMap({ $0 as? NSSearchField }).first,
              let people = views.compactMap({ $0 as? NSTableView }).first,
              let storage = transcript.textStorage else {
            throw SmokeFailure.failed("Missing Messages controls for refresh regression")
        }
        let editCounter = TextEditCounter()
        storage.delegate = editCounter
        var records = (0..<50).map { fixtureRecord($0) }
        func snapshot() -> ROBMessagesTranscriptBrowseSnapshot {
            ROBMessagesTranscriptBrowseSnapshot(records: records, isTruncated: false)
        }
        func settleLayout() {
            host.layoutSubtreeIfNeeded()
            if let container = transcript.textContainer {
                transcript.layoutManager?.ensureLayout(for: container)
            }
        }
        func expectAtBottom(_ reason: String) throws {
            guard scroll.documentVisibleRect.maxY >= transcript.bounds.maxY - 2 else {
                throw SmokeFailure.failed(reason)
            }
        }

        workspace.applySnapshot(snapshot())
        settleLayout()
        guard transcript.bounds.height > scroll.documentVisibleRect.height * 2 else {
            throw SmokeFailure.failed("Scroll fixture must be longer than the viewport")
        }
        try expectAtBottom("Opening a conversation should show its newest messages")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        transcript.setSelectedRange(NSRange(location: 30, length: 12))
        hostWindow.makeFirstResponder(search)
        let originalOrigin = scroll.documentVisibleRect.origin
        let originalSelection = transcript.selectedRanges
        let originalResponder = hostWindow.firstResponder
        let originalEdits = editCounter.count

        for _ in 0..<10 { workspace.applySnapshot(snapshot()) }
        settleLayout()
        guard editCounter.count == originalEdits,
              scroll.documentVisibleRect.origin == originalOrigin,
              transcript.selectedRanges == originalSelection,
              hostWindow.firstResponder === originalResponder else {
            throw SmokeFailure.failed("Idle polling rewrote, scrolled, or focused the conversation")
        }

        records.append(fixtureRecord(50))
        workspace.applySnapshot(snapshot())
        settleLayout()
        guard transcript.string.contains("Message 50"),
              scroll.documentVisibleRect.origin == originalOrigin,
              transcript.selectedRanges == originalSelection,
              hostWindow.firstResponder === originalResponder else {
            throw SmokeFailure.failed("An incoming message interrupted reading older messages")
        }

        let beforeOtherConversation = editCounter.count
        records.append(fixtureRecord(51, sender: "other@example.test"))
        workspace.applySnapshot(snapshot())
        settleLayout()
        guard editCounter.count == beforeOtherConversation,
              scroll.documentVisibleRect.origin == originalOrigin,
              transcript.string.contains("reader@example.test"),
              !transcript.string.contains("other@example.test"),
              hostWindow.firstResponder === originalResponder else {
            throw SmokeFailure.failed("Reordering conversations disturbed the selected transcript")
        }

        transcript.scrollToEndOfDocument(nil)
        settleLayout()
        records.append(fixtureRecord(52))
        workspace.applySnapshot(snapshot())
        settleLayout()
        try expectAtBottom("New messages should follow the end when already at the bottom")

        let editsBeforeStatus = editCounter.count
        records[records.count - 1] = fixtureRecord(52, deliveryStatus: "failed")
        workspace.applySnapshot(snapshot())
        settleLayout()
        guard editCounter.count > editsBeforeStatus,
              transcript.string.contains("Delivery failed") else {
            throw SmokeFailure.failed("Delivery status changes were missed with unchanged message IDs")
        }
        people.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        settleLayout()
        guard transcript.string.contains("other@example.test") else {
            throw SmokeFailure.failed("Explicit conversation selection did not update the transcript")
        }
        try expectAtBottom("Switching conversations should show the selected conversation's end")
        print("Messages refresh regression passed: idle polls, reading position, focus, new messages, delivery status, and conversation switches")
    }

    private static func fixtureRecord(
        _ index: Int,
        sender: String = "reader@example.test",
        deliveryStatus: String = "delivered"
    ) -> ROBMessagesTranscriptRecord {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        return ROBMessagesTranscriptRecord(
            contextID: "fixture-\(index)",
            receivingAccount: "robot@example.test",
            sender: sender,
            chatID: sender,
            receivedAt: date,
            inboundText: "Message \(index): some longer conversation text to read while the inbox polls.",
            hasImage: false,
            replyText: "Reply \(index)",
            replyCreatedAt: date.addingTimeInterval(0.1),
            deliveryStatus: deliveryStatus,
            deliveryFinishedAt: date.addingTimeInterval(0.2),
            deliveryError: nil
        )
    }

    private final class TextEditCounter: NSObject, NSTextStorageDelegate {
        var count = 0

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            count += 1
        }
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
