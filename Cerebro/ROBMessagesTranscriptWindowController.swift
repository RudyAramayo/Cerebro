//
//  ROBMessagesTranscriptWindowController.swift
//  Cerebro
//
//  Local, read-only browser for the encrypted Messages transcript archive.
//

import AppKit
import Foundation

private final class ROBMessagesTranscriptPersonCell: NSTableCellView {
    private let senderLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [senderLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(sender: String, detail: String) {
        senderLabel.stringValue = sender
        detailLabel.stringValue = detail
        setAccessibilityLabel("\(sender), \(detail)")
    }
}

@MainActor
@objc(ROBMessagesTranscriptWindowController)
public final class ROBMessagesTranscriptWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private struct PersonKey: Hashable {
        let receivingAccount: String
        let sender: String
    }

    private struct Person {
        let key: PersonKey
        let records: [ROBMessagesTranscriptRecord]
        let operatorReplies: [ROBMessagesOperatorReplyRecord]

        var lastActivity: Date {
            max(
                records.map(\.receivedAt).max() ?? .distantPast,
                operatorReplies.map(\.createdAt).max() ?? .distantPast
            )
        }
    }

    private enum ConversationEvent {
        case transaction(ROBMessagesTranscriptRecord)
        case operatorReply(ROBMessagesOperatorReplyRecord)

        var date: Date {
            switch self {
            case .transaction(let record): return record.receivedAt
            case .operatorReply(let record): return record.createdAt
            }
        }
    }

    public static let shared = ROBMessagesTranscriptWindowController()

    private let store = ROBMessagesTranscriptStore.shared
    private let searchField = NSSearchField()
    private let peopleTable = NSTableView()
    private let personHeading = NSTextField(labelWithString: "Select a person")
    private let accountLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let transcriptTextView = NSTextView()
    private let refreshButton = NSButton()
    private var snapshot = ROBMessagesTranscriptBrowseSnapshot(
        records: [],
        isTruncated: false
    )
    private var people: [Person] = []
    private var selectedKey: PersonKey?
    private var loadGeneration: UInt64 = 0

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    public convenience init() {
        self.init(window: nil)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc(showMessagesTranscriptWindow:)
    public static func showMessagesTranscriptWindow(_ sender: Any?) {
        shared.showWindow(sender)
    }

    public override func loadWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Messages Transcripts"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.delegate = self
        window.setFrameAutosaveName("ROBMessagesTranscriptWindow")
        window.center()
        self.window = window
        configureContent(of: window)
    }

    public override func showWindow(_ sender: Any?) {
        if window == nil { loadWindow() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshNow(sender)
    }

    @objc(refreshNow:)
    public func refreshNow(_ sender: Any?) {
        loadGeneration &+= 1
        let requestGeneration = loadGeneration
        refreshButton.isEnabled = false
        statusLabel.stringValue = "Opening encrypted transcript…"
        let store = store
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return (
                        try store.browseSnapshot(),
                        Optional<String>.none
                    )
                } catch {
                    return (
                        ROBMessagesTranscriptBrowseSnapshot(
                            records: [],
                            isTruncated: false
                        ),
                        error.localizedDescription
                    )
                }
            }.value
            guard let self, requestGeneration == self.loadGeneration else { return }
            self.refreshButton.isEnabled = true
            if let error = result.1 {
                self.snapshot = result.0
                self.rebuildPeople()
                self.statusLabel.stringValue = error
                return
            }
            self.snapshot = result.0
            self.rebuildPeople()
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        people.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard people.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("MessagesTranscriptPerson")
        let cell: ROBMessagesTranscriptPersonCell
        if let reused = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ROBMessagesTranscriptPersonCell {
            cell = reused
        } else {
            cell = ROBMessagesTranscriptPersonCell()
            cell.identifier = identifier
        }
        let person = people[row]
        let count = person.records.count + person.operatorReplies.count
        let detail = "\(count) turn\(count == 1 ? "" : "s") • \(dateFormatter.string(from: person.lastActivity))"
        cell.configure(sender: person.key.sender, detail: detail)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = peopleTable.selectedRow
        guard people.indices.contains(row) else {
            selectedKey = nil
            renderSelection()
            return
        }
        selectedKey = people[row].key
        renderSelection()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        rebuildPeople()
    }

    @objc private func exportTranscript(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Cerebro-Messages-Transcript.json"
        panel.canCreateDirectories = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let error = ROBMessagesBridge.exportMessagesTranscript(to: url)
            if let error {
                self?.presentError(
                    title: "Messages transcript export failed",
                    detail: error as String
                )
            } else {
                self?.statusLabel.stringValue = "Exported plaintext JSON to \(url.path)"
            }
        }
    }

    @objc private func clearTranscript(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently clear every Messages transcript?"
        alert.informativeText = "This deletes the encrypted archive and removes its history from future AI replies. This cannot be undone unless you made an export."
        alert.addButton(withTitle: "Clear Archive")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if let error = ROBMessagesBridge.deleteMessagesTranscript() {
                self?.presentError(
                    title: "Messages transcript could not be cleared",
                    detail: error as String
                )
            } else {
                self?.selectedKey = nil
                self?.refreshNow(sender)
            }
        }
    }

    private func configureContent(of window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let titleLabel = NSTextField(labelWithString: "Messages Transcripts")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Private, locally decrypted history from Messages conversations Cerebro handled. Select a sender or search message text."
        )
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 0

        let titleStack = NSStackView(views: [titleLabel, explanation])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshNow(_:))
        let exportButton = NSButton(
            title: "Export…",
            target: self,
            action: #selector(exportTranscript(_:))
        )
        exportButton.bezelStyle = .rounded
        let clearButton = NSButton(
            title: "Clear Archive…",
            target: self,
            action: #selector(clearTranscript(_:))
        )
        clearButton.bezelStyle = .rounded
        clearButton.hasDestructiveAction = true
        let actions = NSStackView(views: [refreshButton, exportButton, clearButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let header = NSStackView(views: [titleStack, actions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.setContentHuggingPriority(.required, for: .horizontal)

        searchField.placeholderString = "Search people and messages"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityIdentifier("ROB.MessagesTranscript.Search")

        let peopleColumn = NSTableColumn(identifier: .init("people"))
        peopleColumn.resizingMask = .autoresizingMask
        peopleTable.addTableColumn(peopleColumn)
        peopleTable.headerView = nil
        peopleTable.rowHeight = 52
        peopleTable.intercellSpacing = NSSize(width: 0, height: 1)
        peopleTable.dataSource = self
        peopleTable.delegate = self
        peopleTable.allowsEmptySelection = true
        peopleTable.setAccessibilityLabel("Archived Messages senders")
        let peopleScroll = NSScrollView()
        peopleScroll.hasVerticalScroller = true
        peopleScroll.autohidesScrollers = true
        peopleScroll.borderType = .bezelBorder
        peopleScroll.documentView = peopleTable

        let peopleTitle = NSTextField(labelWithString: "People")
        peopleTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let sidebar = NSView()
        [searchField, peopleTitle, peopleScroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: sidebar.topAnchor),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            peopleTitle.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            peopleTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            peopleScroll.topAnchor.constraint(equalTo: peopleTitle.bottomAnchor, constant: 6),
            peopleScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            peopleScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            peopleScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 235),
        ])

        personHeading.font = .systemFont(ofSize: 18, weight: .semibold)
        personHeading.lineBreakMode = .byTruncatingMiddle
        accountLabel.font = .systemFont(ofSize: 11)
        accountLabel.textColor = .secondaryLabelColor
        accountLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        transcriptTextView.isEditable = false
        transcriptTextView.isSelectable = true
        transcriptTextView.isRichText = true
        transcriptTextView.isAutomaticLinkDetectionEnabled = true
        transcriptTextView.isVerticallyResizable = true
        transcriptTextView.isHorizontallyResizable = false
        transcriptTextView.autoresizingMask = [.width]
        transcriptTextView.minSize = .zero
        transcriptTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        transcriptTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        transcriptTextView.textContainer?.widthTracksTextView = true
        transcriptTextView.textContainerInset = NSSize(width: 18, height: 16)
        transcriptTextView.backgroundColor = .textBackgroundColor
        transcriptTextView.setAccessibilityLabel("Messages transcript history")
        let transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.documentView = transcriptTextView

        let detailHeader = NSStackView(views: [personHeading, accountLabel, statusLabel])
        detailHeader.orientation = .vertical
        detailHeader.alignment = .leading
        detailHeader.spacing = 2
        let detail = NSView()
        [detailHeader, transcriptScroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview($0)
        }
        NSLayoutConstraint.activate([
            detailHeader.topAnchor.constraint(equalTo: detail.topAnchor),
            detailHeader.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            detailHeader.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: detailHeader.bottomAnchor, constant: 10),
            transcriptScroll.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        [header, split].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        renderSelection()
    }

    private func rebuildPeople() {
        let previousSelection = selectedKey
        let groupedRecords = Dictionary(grouping: snapshot.records) { record in
            PersonKey(
                receivingAccount: record.receivingAccount,
                sender: record.sender
            )
        }
        let groupedOperatorReplies = Dictionary(grouping: snapshot.operatorReplies) { record in
            PersonKey(
                receivingAccount: record.receivingAccount,
                sender: record.sender
            )
        }
        let query = normalizedSearch
        let keys = Set(groupedRecords.keys).union(groupedOperatorReplies.keys)
        people = keys.compactMap { key in
            let records = groupedRecords[key] ?? []
            let operatorReplies = groupedOperatorReplies[key] ?? []
            guard query.isEmpty || key.sender.localizedCaseInsensitiveContains(query) ||
                    key.receivingAccount.localizedCaseInsensitiveContains(query) ||
                    records.contains(where: { recordMatches($0, query: query) }) ||
                    operatorReplies.contains(where: {
                        $0.text.localizedCaseInsensitiveContains(query)
                    }) else {
                return nil
            }
            return Person(
                key: key,
                records: records,
                operatorReplies: operatorReplies
            )
        }.sorted { left, right in
            if left.lastActivity == right.lastActivity {
                return left.key.sender.localizedCaseInsensitiveCompare(right.key.sender)
                    == .orderedAscending
            }
            return left.lastActivity > right.lastActivity
        }
        peopleTable.reloadData()

        if let previousSelection,
           let row = people.firstIndex(where: { $0.key == previousSelection }) {
            peopleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectedKey = previousSelection
        } else if !people.isEmpty {
            peopleTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectedKey = people[0].key
        } else {
            peopleTable.deselectAll(nil)
            selectedKey = nil
        }
        renderSelection()
    }

    private func renderSelection() {
        let totalCount = snapshot.records.count + snapshot.operatorReplies.count
        guard let selectedKey,
              let person = people.first(where: { $0.key == selectedKey }) else {
            personHeading.stringValue = totalCount == 0
                ? "No archived conversations"
                : "No matching conversations"
            accountLabel.stringValue = totalCount == 0
                ? "Enable encrypted transcript memory to retain future Messages replies."
                : "Try a different search."
            if statusLabel.stringValue.hasPrefix("Opening") == false {
                statusLabel.stringValue = snapshot.isTruncated
                    ? "Showing the newest archived transactions."
                    : "\(totalCount) archived turn\(totalCount == 1 ? "" : "s")"
            }
            transcriptTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            return
        }

        let query = normalizedSearch
        let identityMatches = query.isEmpty ||
            selectedKey.sender.localizedCaseInsensitiveContains(query) ||
            selectedKey.receivingAccount.localizedCaseInsensitiveContains(query)
        let displayed = person.records.filter {
            identityMatches || recordMatches($0, query: query)
        }.sorted { $0.receivedAt < $1.receivedAt }
        let displayedOperatorReplies = person.operatorReplies.filter {
            identityMatches || $0.text.localizedCaseInsensitiveContains(query)
        }.sorted { $0.createdAt < $1.createdAt }

        personHeading.stringValue = selectedKey.sender
        accountLabel.stringValue = "Receiving account: \(selectedKey.receivingAccount)"
        let truncation = snapshot.isTruncated ? " • newest archive segment" : ""
        let displayedCount = displayed.count + displayedOperatorReplies.count
        let personCount = person.records.count + person.operatorReplies.count
        statusLabel.stringValue = "\(displayedCount) displayed of \(personCount) turn\(personCount == 1 ? "" : "s")\(truncation)"
        transcriptTextView.textStorage?.setAttributedString(
            transcript(for: displayed, operatorReplies: displayedOperatorReplies)
        )
        transcriptTextView.scrollToBeginningOfDocument(nil)
    }

    private var normalizedSearch: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordMatches(
        _ record: ROBMessagesTranscriptRecord,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return true }
        return record.inboundText.localizedCaseInsensitiveContains(query) ||
            record.replyText?.localizedCaseInsensitiveContains(query) == true ||
            record.deliveryError?.localizedCaseInsensitiveContains(query) == true ||
            record.deliveryStatus.localizedCaseInsensitiveContains(query)
    }

    private func transcript(
        for records: [ROBMessagesTranscriptRecord],
        operatorReplies: [ROBMessagesOperatorReplyRecord]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let events = records.map(ConversationEvent.transaction) +
            operatorReplies.map(ConversationEvent.operatorReply)
        for (index, event) in events.sorted(by: { $0.date < $1.date }).enumerated() {
            if index > 0 {
                output.append(NSAttributedString(
                    string: "\n────────────────────────────────────────\n\n",
                    attributes: [.foregroundColor: NSColor.separatorColor]
                ))
            }
            switch event {
            case .transaction(let record):
                output.append(styled(
                    "\(dateFormatter.string(from: record.receivedAt))  •  \(deliveryLabel(record.deliveryStatus))\n",
                    font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                    color: deliveryColor(record.deliveryStatus)
                ))
                output.append(styled(
                    "Sender\n",
                    font: .systemFont(ofSize: 13, weight: .semibold),
                    color: .systemBlue
                ))
                output.append(styled("\(record.inboundText)\n", font: .systemFont(ofSize: 14)))
                if record.hasImage {
                    output.append(styled(
                        "Image attached — pixels are not stored in the transcript archive.\n",
                        font: .systemFont(ofSize: 11),
                        color: .secondaryLabelColor
                    ))
                }
                if let reply = record.replyText {
                    output.append(styled(
                        "\nROB\n",
                        font: .systemFont(ofSize: 13, weight: .semibold),
                        color: .systemGreen
                    ))
                    output.append(styled("\(reply)\n", font: .systemFont(ofSize: 14)))
                } else {
                    output.append(styled(
                        "\nNo reply was recorded.\n",
                        font: .systemFont(ofSize: 12, weight: .medium),
                        color: .secondaryLabelColor
                    ))
                }
                if let error = record.deliveryError {
                    output.append(styled(
                        "\nDelivery error: \(error)\n",
                        font: .systemFont(ofSize: 11),
                        color: .systemRed
                    ))
                }
            case .operatorReply(let record):
                output.append(styled(
                    "\(dateFormatter.string(from: record.createdAt))  •  \(deliveryLabel(record.deliveryStatus))\n",
                    font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                    color: deliveryColor(record.deliveryStatus)
                ))
                output.append(styled(
                    "You (operator)\n",
                    font: .systemFont(ofSize: 13, weight: .semibold),
                    color: .systemPurple
                ))
                output.append(styled("\(record.text)\n", font: .systemFont(ofSize: 14)))
                if let error = record.deliveryError {
                    output.append(styled(
                        "\nDelivery error: \(error)\n",
                        font: .systemFont(ofSize: 11),
                        color: .systemRed
                    ))
                }
            }
        }
        return output
    }

    private func styled(
        _ text: String,
        font: NSFont,
        color: NSColor = .labelColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
    }

    private func deliveryLabel(_ status: String) -> String {
        switch status {
        case "pending_ai": return "Waiting for AI"
        case "delivery_pending": return "Sending"
        case "delivered": return "Delivered"
        case "failed": return "Delivery failed"
        case "cancelled": return "Cancelled"
        default: return status
        }
    }

    private func deliveryColor(_ status: String) -> NSColor {
        switch status {
        case "delivered": return .secondaryLabelColor
        case "failed": return .systemRed
        case "cancelled": return .systemOrange
        default: return .systemBlue
        }
    }

    private func presentError(title: String, detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

/// Compact, interactive Messages workspace embedded in Cerebro's main window.
/// It intentionally reads only the encrypted archive and sends through the
/// bridge's immutable-route authorization gate.
@MainActor
@objcMembers public final class ROBMessagesWorkspaceViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private struct PersonKey: Hashable {
        let receivingAccount: String
        let sender: String
    }

    private struct Person {
        let key: PersonKey
        let records: [ROBMessagesTranscriptRecord]
        let operatorReplies: [ROBMessagesOperatorReplyRecord]

        var lastActivity: Date {
            latestPreviewEvent?.date ?? .distantPast
        }

        var latestRecord: ROBMessagesTranscriptRecord? {
            records.max { $0.receivedAt < $1.receivedAt }
        }

        var preview: String {
            let text = latestPreviewEvent?.text ?? "No incoming message"
            return String(text.replacingOccurrences(of: "\n", with: " ").prefix(72))
        }

        private var latestPreviewEvent: (date: Date, text: String)? {
            var events = records.map { ($0.receivedAt, $0.inboundText) }
            events += records.compactMap { record in
                guard let reply = record.replyText else { return nil }
                return (record.replyCreatedAt ?? record.receivedAt, "ROB: \(reply)")
            }
            events += operatorReplies.map { ($0.createdAt, "You: \($0.text)") }
            return events.max { $0.0 < $1.0 }
        }
    }

    private enum TimelineEvent {
        case inbound(Date, String, Bool)
        case robot(Date, String, String)
        case operatorReply(Date, String, String, String?)

        var date: Date {
            switch self {
            case .inbound(let date, _, _),
                 .robot(let date, _, _),
                 .operatorReply(let date, _, _, _):
                return date
            }
        }
    }

    private let store = ROBMessagesTranscriptStore.shared
    private let bridge = ROBMessagesBridge.shared
    private let peopleTable = NSTableView()
    private let personHeading = NSTextField(labelWithString: "Select a conversation")
    private let accountLabel = NSTextField(labelWithString: "")
    private let transcriptTextView = NSTextView()
    private let replyField = NSTextField()
    private let sendButton = NSButton()
    private let stateDot = NSTextField(labelWithString: "●")
    private let stateLabel = NSTextField(labelWithString: "Messages unavailable")
    private let activityLabel = NSTextField(labelWithString: "")
    private let historyButton = NSButton()
    private let refreshButton = NSButton()
    private var snapshot = ROBMessagesTranscriptBrowseSnapshot(
        records: [],
        isTruncated: false
    )
    private var people: [Person] = []
    private var selectedKey: PersonKey?
    private var loadGeneration: UInt64 = 0
    private var isSending = false
    private var bridgeEnabled = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    public override func loadView() {
        view = NSView()
        configureContent()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bridgeDidChange(_:)),
            name: .robMessagesBridgeDidChange,
            object: bridge
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bridgeDidChange(_:)),
            name: .robMessagesBridgeSettingsDidChange,
            object: nil
        )
        updateBridgeStatus()
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        people.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard people.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("MainMessagesPerson")
        let cell: ROBMessagesTranscriptPersonCell
        if let reused = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ROBMessagesTranscriptPersonCell {
            cell = reused
        } else {
            cell = ROBMessagesTranscriptPersonCell()
            cell.identifier = identifier
        }
        let person = people[row]
        cell.configure(sender: person.key.sender, detail: person.preview)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard people.indices.contains(peopleTable.selectedRow) else {
            selectedKey = nil
            renderSelection()
            return
        }
        selectedKey = people[peopleTable.selectedRow].key
        renderSelection()
    }

    public func controlTextDidChange(_ obj: Notification) {
        updateComposerState()
    }

    @objc private func bridgeDidChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.bridgeDidChange(notification) }
            return
        }
        updateBridgeStatus()
        refresh()
    }

    @objc private func refreshClicked(_ sender: Any?) {
        refresh()
    }

    @objc private func showFullHistory(_ sender: Any?) {
        ROBMessagesTranscriptWindowController.shared.showWindow(sender)
    }

    @objc private func sendReply(_ sender: Any?) {
        guard !isSending,
              let person = selectedPerson,
              let route = person.latestRecord else {
            NSSound.beep()
            return
        }
        let text = replyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }

        isSending = true
        updateComposerState()
        activityLabel.stringValue = "Sending to \(person.key.sender)…"
        bridge.sendOperatorReply(text: text, to: route) { [weak self] result in
            guard let self else { return }
            self.isSending = false
            switch result {
            case .success:
                self.replyField.stringValue = ""
                self.activityLabel.stringValue = "Reply delivered"
                self.refresh()
            case .failure(let error):
                self.activityLabel.stringValue = error.localizedDescription
                NSSound.beep()
            }
            self.updateBridgeStatus()
            self.updateComposerState()
        }
    }

    private func configureContent() {
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Messages")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Reply as ROB to approved conversations")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        stateDot.font = .systemFont(ofSize: 9, weight: .bold)
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.lineBreakMode = .byTruncatingTail
        let stateStack = NSStackView(views: [stateDot, stateLabel])
        stateStack.orientation = .horizontal
        stateStack.alignment = .centerY
        stateStack.spacing = 5

        historyButton.title = "History"
        historyButton.image = NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: "Open full Messages history"
        )
        historyButton.imagePosition = .imageLeading
        historyButton.bezelStyle = .texturedRounded
        historyButton.target = self
        historyButton.action = #selector(showFullHistory(_:))
        historyButton.toolTip = "Open the searchable encrypted Messages archive"

        refreshButton.title = ""
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh Messages"
        )
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))
        refreshButton.toolTip = "Refresh Messages conversations"

        let headerActions = NSStackView(views: [historyButton, refreshButton])
        headerActions.orientation = .horizontal
        headerActions.spacing = 6
        let header = NSStackView(views: [titleStack, NSView(), stateStack, headerActions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let peopleColumn = NSTableColumn(identifier: .init("people"))
        peopleColumn.resizingMask = .autoresizingMask
        peopleTable.addTableColumn(peopleColumn)
        peopleTable.headerView = nil
        peopleTable.rowHeight = 54
        peopleTable.intercellSpacing = NSSize(width: 0, height: 2)
        peopleTable.dataSource = self
        peopleTable.delegate = self
        peopleTable.allowsEmptySelection = true
        peopleTable.backgroundColor = .clear
        peopleTable.setAccessibilityLabel("Recent Messages conversations")
        let peopleScroll = NSScrollView()
        peopleScroll.hasVerticalScroller = true
        peopleScroll.autohidesScrollers = true
        peopleScroll.drawsBackground = false
        peopleScroll.documentView = peopleTable

        personHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        personHeading.lineBreakMode = .byTruncatingMiddle
        accountLabel.font = .systemFont(ofSize: 10)
        accountLabel.textColor = .tertiaryLabelColor
        accountLabel.lineBreakMode = .byTruncatingMiddle
        let personHeader = NSStackView(views: [personHeading, accountLabel])
        personHeader.orientation = .vertical
        personHeader.alignment = .leading
        personHeader.spacing = 1

        transcriptTextView.isEditable = false
        transcriptTextView.isSelectable = true
        transcriptTextView.isRichText = true
        transcriptTextView.isAutomaticLinkDetectionEnabled = true
        transcriptTextView.isVerticallyResizable = true
        transcriptTextView.isHorizontallyResizable = false
        transcriptTextView.autoresizingMask = [.width]
        transcriptTextView.textContainer?.widthTracksTextView = true
        transcriptTextView.textContainerInset = NSSize(width: 12, height: 10)
        transcriptTextView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.72)
        transcriptTextView.setAccessibilityLabel("Selected Messages conversation")
        let transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.borderType = .noBorder
        transcriptScroll.wantsLayer = true
        transcriptScroll.layer?.cornerRadius = 9
        transcriptScroll.layer?.masksToBounds = true
        transcriptScroll.documentView = transcriptTextView

        replyField.placeholderString = "Reply to selected conversation"
        replyField.font = .systemFont(ofSize: 13)
        replyField.delegate = self
        replyField.target = self
        replyField.action = #selector(sendReply(_:))
        replyField.setAccessibilityLabel("Messages reply")
        sendButton.title = "Reply"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendReply(_:))
        sendButton.setAccessibilityLabel("Send Messages reply")
        let composer = NSStackView(views: [replyField, sendButton])
        composer.orientation = .horizontal
        composer.alignment = .centerY
        composer.spacing = 8

        activityLabel.font = .systemFont(ofSize: 10)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byTruncatingTail

        let detail = NSView()
        [personHeader, transcriptScroll, composer, activityLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview($0)
        }
        NSLayoutConstraint.activate([
            personHeader.topAnchor.constraint(equalTo: detail.topAnchor),
            personHeader.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            personHeader.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: personHeader.bottomAnchor, constant: 8),
            transcriptScroll.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            composer.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 8),
            composer.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            activityLabel.topAnchor.constraint(equalTo: composer.bottomAnchor, constant: 4),
            activityLabel.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 2),
            activityLabel.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            activityLabel.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(peopleScroll)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        peopleScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 145).isActive = true
        peopleScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 205).isActive = true
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 235).isActive = true

        [header, split].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    private func refresh() {
        loadGeneration &+= 1
        let generation = loadGeneration
        refreshButton.isEnabled = false
        let store = store
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try store.browseSnapshot(maximumRecords: 2_000) }
            }.value
            guard let self, generation == self.loadGeneration else { return }
            self.refreshButton.isEnabled = true
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.rebuildPeople()
            case .failure(let error):
                self.snapshot = ROBMessagesTranscriptBrowseSnapshot(
                    records: [],
                    isTruncated: false
                )
                self.people = []
                self.peopleTable.reloadData()
                self.activityLabel.stringValue = error.localizedDescription
                self.renderSelection()
            }
        }
    }

    private func rebuildPeople() {
        let previousSelection = selectedKey
        let records = Dictionary(grouping: snapshot.records) {
            PersonKey(receivingAccount: $0.receivingAccount, sender: $0.sender)
        }
        let replies = Dictionary(grouping: snapshot.operatorReplies) {
            PersonKey(receivingAccount: $0.receivingAccount, sender: $0.sender)
        }
        people = Set(records.keys).union(replies.keys).map { key in
            Person(
                key: key,
                records: records[key] ?? [],
                operatorReplies: replies[key] ?? []
            )
        }.sorted { $0.lastActivity > $1.lastActivity }
        peopleTable.reloadData()

        if let previousSelection,
           let row = people.firstIndex(where: { $0.key == previousSelection }) {
            selectedKey = previousSelection
            peopleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !people.isEmpty {
            selectedKey = people[0].key
            peopleTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            selectedKey = nil
            peopleTable.deselectAll(nil)
        }
        renderSelection()
    }

    private var selectedPerson: Person? {
        guard let selectedKey else { return nil }
        return people.first { $0.key == selectedKey }
    }

    private func renderSelection() {
        guard let person = selectedPerson else {
            personHeading.stringValue = "No archived conversations"
            accountLabel.stringValue = "Enable transcript memory in Settings to use the Messages workspace."
            transcriptTextView.string = ""
            updateComposerState()
            return
        }

        personHeading.stringValue = person.key.sender
        accountLabel.stringValue = "via \(person.key.receivingAccount)"
        var events: [TimelineEvent] = []
        for record in person.records {
            events.append(.inbound(record.receivedAt, record.inboundText, record.hasImage))
            if let reply = record.replyText {
                events.append(.robot(
                    record.replyCreatedAt ?? record.receivedAt,
                    reply,
                    record.deliveryStatus
                ))
            }
        }
        for reply in person.operatorReplies {
            events.append(.operatorReply(
                reply.createdAt,
                reply.text,
                reply.deliveryStatus,
                reply.deliveryError
            ))
        }
        transcriptTextView.textStorage?.setAttributedString(
            transcript(events.sorted { $0.date < $1.date })
        )
        transcriptTextView.scrollToEndOfDocument(nil)
        updateComposerState()
    }

    private func transcript(_ events: [TimelineEvent]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for event in events {
            let sender: String
            let body: String
            let color: NSColor
            let status: String?
            let hasImage: Bool
            let error: String?
            switch event {
            case .inbound(_, let text, let image):
                sender = "Sender"
                body = text
                color = .systemBlue
                status = nil
                hasImage = image
                error = nil
            case .robot(_, let text, let deliveryStatus):
                sender = "ROB AI"
                body = text
                color = .systemGreen
                status = deliveryStatus
                hasImage = false
                error = nil
            case .operatorReply(_, let text, let deliveryStatus, let deliveryError):
                sender = "You"
                body = text
                color = .systemPurple
                status = deliveryStatus
                hasImage = false
                error = deliveryError
            }

            output.append(NSAttributedString(
                string: "\(sender)  \(dateFormatter.string(from: event.date))\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: color,
                ]
            ))
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 10
            paragraph.lineSpacing = 2
            output.append(NSAttributedString(
                string: body + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
            if hasImage {
                output.append(secondary("Image attached — not retained in transcript.\n"))
            }
            if let status, status != "delivered" {
                output.append(secondary("Status: \(status)\n"))
            }
            if let error {
                output.append(NSAttributedString(
                    string: "Delivery error: \(error)\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.systemRed,
                    ]
                ))
            }
        }
        return output
    }

    private func secondary(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    private func updateBridgeStatus() {
        let status = bridge.statusSnapshot()
        bridgeEnabled = status.enabled
        stateLabel.stringValue = status.enabled ? status.state.capitalized : "Off"
        let healthyStates = ["listening", "processing", "starting"]
        stateDot.textColor = status.enabled && healthyStates.contains(status.state)
            ? .systemGreen
            : (status.enabled ? .systemOrange : .secondaryLabelColor)
        stateLabel.toolTip = status.detail
        if !status.archivesTranscripts {
            activityLabel.stringValue = "Turn on encrypted transcript memory in Settings to list chats."
        } else if activityLabel.stringValue.hasPrefix("Turn on") {
            activityLabel.stringValue = ""
        }
        updateComposerState()
    }

    private func updateComposerState() {
        let canReply = !isSending && bridgeEnabled && selectedPerson?.latestRecord != nil
        replyField.isEnabled = canReply
        sendButton.isEnabled = canReply && !replyField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.title = isSending ? "Sending…" : "Reply"
    }
}
