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

        var lastActivity: Date {
            records.map(\.receivedAt).max() ?? .distantPast
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
        let count = person.records.count
        let detail = "\(count) transaction\(count == 1 ? "" : "s") • \(dateFormatter.string(from: person.lastActivity))"
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
        let grouped = Dictionary(grouping: snapshot.records) { record in
            PersonKey(
                receivingAccount: record.receivingAccount,
                sender: record.sender
            )
        }
        let query = normalizedSearch
        people = grouped.compactMap { key, records in
            guard query.isEmpty || key.sender.localizedCaseInsensitiveContains(query) ||
                    key.receivingAccount.localizedCaseInsensitiveContains(query) ||
                    records.contains(where: { recordMatches($0, query: query) }) else {
                return nil
            }
            return Person(key: key, records: records)
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
        guard let selectedKey,
              let person = people.first(where: { $0.key == selectedKey }) else {
            personHeading.stringValue = snapshot.records.isEmpty
                ? "No archived conversations"
                : "No matching conversations"
            accountLabel.stringValue = snapshot.records.isEmpty
                ? "Enable encrypted transcript memory to retain future Messages replies."
                : "Try a different search."
            if statusLabel.stringValue.hasPrefix("Opening") == false {
                statusLabel.stringValue = snapshot.isTruncated
                    ? "Showing the newest archived transactions."
                    : "\(snapshot.records.count) archived transaction\(snapshot.records.count == 1 ? "" : "s")"
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

        personHeading.stringValue = selectedKey.sender
        accountLabel.stringValue = "Receiving account: \(selectedKey.receivingAccount)"
        let truncation = snapshot.isTruncated ? " • newest archive segment" : ""
        statusLabel.stringValue = "\(displayed.count) displayed of \(person.records.count) transaction\(person.records.count == 1 ? "" : "s")\(truncation)"
        transcriptTextView.textStorage?.setAttributedString(
            transcript(for: displayed)
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
        for records: [ROBMessagesTranscriptRecord]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, record) in records.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(
                    string: "\n────────────────────────────────────────\n\n",
                    attributes: [.foregroundColor: NSColor.separatorColor]
                ))
            }
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
