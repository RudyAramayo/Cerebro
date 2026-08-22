//
//  ROBMessagesAdministratorCommandWindowController.swift
//  Cerebro
//
//  Local editor for administrator-only, confirmation-gated Messages commands.
//

import AppKit

@MainActor
@objc(ROBMessagesAdministratorCommandWindowController)
public final class ROBMessagesAdministratorCommandWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = ROBMessagesAdministratorCommandWindowController()

    private let tableView = NSTableView()
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let commandField = NSTextField()
    private let promptField = NSTextField()
    private let responseField = NSTextField()
    private let scriptTextView = NSTextView()
    private let removeButton = NSButton()
    private let saveButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var commands: [ROBMessagesAdministratorCommand] = []
    private var editingIndex: Int?
    private var isChangingSelection = false

    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
    }

    public override init(window: NSWindow?) {
        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc(showMessagesAdministratorCommands:)
    public static func showMessagesAdministratorCommands(_ sender: Any?) {
        shared.reloadFromStore()
        shared.showWindow(sender)
        shared.window?.center()
        shared.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        commands.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard commands.indices.contains(row), let identifier = tableColumn?.identifier else {
            return nil
        }
        let command = commands[row]
        let value: String
        switch identifier.rawValue {
        case "enabled": value = command.isEnabled ? "On" : "Off"
        case "confirmation": value = command.confirmationResponse
        default: value = command.command
        }
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        return label
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if !isChangingSelection {
            captureEditor()
        }
        let row = tableView.selectedRow
        editingIndex = commands.indices.contains(row) ? row : nil
        loadEditor()
    }

    private func configureWindow() {
        guard let window, let content = window.contentView else { return }
        window.title = "Messages Administrator Commands"
        window.minSize = NSSize(width: 900, height: 560)
        window.setFrameAutosaveName("ROBMessagesAdministratorCommandsWindow")

        let title = NSTextField(labelWithString: "Administrator Commands")
        title.font = .boldSystemFont(ofSize: 20)
        title.frame = NSRect(x: 20, y: 598, width: 500, height: 26)
        title.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(title)

        let administrators = ROBMessagesBridge.configuredAdministratorSenderHandles()
            .joined(separator: "  •  ")
        let explanation = wrappingLabel(
            "Only these exact one-to-one sender handles can trigger commands: \(administrators). " +
            "A command is matched as the entire message, then ROB sends its confirmation question. " +
            "The script runs only after the same sender replies with the exact confirmation text."
        )
        explanation.frame = NSRect(x: 20, y: 546, width: 980, height: 44)
        explanation.autoresizingMask = [.width, .minYMargin]
        content.addSubview(explanation)

        let commandColumn = NSTableColumn(identifier: .init("command"))
        commandColumn.title = "Command"
        commandColumn.width = 155
        let confirmationColumn = NSTableColumn(identifier: .init("confirmation"))
        confirmationColumn.title = "Reply"
        confirmationColumn.width = 75
        let enabledColumn = NSTableColumn(identifier: .init("enabled"))
        enabledColumn.title = "Status"
        enabledColumn.width = 55
        [commandColumn, confirmationColumn, enabledColumn].forEach(tableView.addTableColumn)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = NSTableHeaderView()
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.setAccessibilityIdentifier("ROB.MessagesCommands.Table")

        let tableScroll = NSScrollView(frame: NSRect(x: 20, y: 86, width: 300, height: 448))
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.autoresizingMask = [.height, .maxXMargin]
        content.addSubview(tableScroll)

        let addButton = button("Add", frame: NSRect(x: 20, y: 48, width: 90, height: 28), action: #selector(addCommand(_:)))
        removeButton.title = "Remove"
        removeButton.frame = NSRect(x: 118, y: 48, width: 90, height: 28)
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeCommand(_:))
        [addButton, removeButton].forEach {
            $0.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview($0)
        }

        let editorX: CGFloat = 344
        addLabel("Command message", x: editorX, y: 507, to: content)
        commandField.frame = NSRect(x: editorX, y: 476, width: 486, height: 26)
        commandField.placeholderString = "Shutdown"
        commandField.setAccessibilityIdentifier("ROB.MessagesCommands.Command")
        commandField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(commandField)

        enabledCheckbox.frame = NSRect(x: 846, y: 476, width: 140, height: 26)
        enabledCheckbox.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(enabledCheckbox)

        addLabel("Confirmation question sent by ROB", x: editorX, y: 443, to: content)
        promptField.frame = NSRect(x: editorX, y: 412, width: 642, height: 26)
        promptField.placeholderString = "Run this command? Reply YES within 90 seconds to confirm."
        promptField.setAccessibilityIdentifier("ROB.MessagesCommands.Question")
        promptField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(promptField)

        addLabel("Exact confirmation reply", x: editorX, y: 379, to: content)
        responseField.frame = NSRect(x: editorX, y: 348, width: 300, height: 26)
        responseField.placeholderString = "YES"
        responseField.setAccessibilityIdentifier("ROB.MessagesCommands.Response")
        responseField.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(responseField)

        let scriptLabel = NSTextField(labelWithString: "Shell script")
        scriptLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        scriptLabel.frame = NSRect(x: editorX, y: 315, width: 200, height: 20)
        scriptLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(scriptLabel)

        let warning = wrappingLabel(
            "Scripts run locally as the signed-in Cerebro user through /bin/zsh after confirmation. " +
            "Messages text is never inserted into the script. Review scripts as carefully as Terminal commands."
        )
        warning.textColor = .systemOrange
        warning.frame = NSRect(x: editorX + 205, y: 302, width: 437, height: 36)
        warning.autoresizingMask = [.width, .minYMargin]
        content.addSubview(warning)

        scriptTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scriptTextView.isRichText = false
        scriptTextView.isAutomaticQuoteSubstitutionEnabled = false
        scriptTextView.isAutomaticDashSubstitutionEnabled = false
        scriptTextView.isAutomaticTextReplacementEnabled = false
        scriptTextView.allowsUndo = true
        scriptTextView.isVerticallyResizable = true
        scriptTextView.isHorizontallyResizable = false
        scriptTextView.minSize = .zero
        scriptTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scriptTextView.textContainer?.containerSize = NSSize(
            width: 642,
            height: CGFloat.greatestFiniteMagnitude
        )
        scriptTextView.textContainer?.widthTracksTextView = true
        scriptTextView.setAccessibilityLabel("Administrator command shell script")
        scriptTextView.setAccessibilityIdentifier("ROB.MessagesCommands.Script")
        let scriptScroll = NSScrollView(frame: NSRect(x: editorX, y: 86, width: 642, height: 208))
        scriptTextView.frame = scriptScroll.contentView.bounds
        scriptTextView.autoresizingMask = [.width]
        scriptScroll.documentView = scriptTextView
        scriptScroll.hasVerticalScroller = true
        scriptScroll.autohidesScrollers = true
        scriptScroll.borderType = .bezelBorder
        scriptScroll.autoresizingMask = [.width, .height]
        content.addSubview(scriptScroll)

        saveButton.title = "Save Commands"
        saveButton.frame = NSRect(x: 846, y: 48, width: 140, height: 28)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveCommands(_:))
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(saveButton)

        statusLabel.frame = NSRect(x: editorX, y: 48, width: 480, height: 28)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(statusLabel)
    }

    private func reloadFromStore() {
        commands = ROBMessagesAdministratorCommandStore.load()
        tableView.reloadData()
        selectRow(commands.isEmpty ? nil : 0)
        statusLabel.stringValue = commands.isEmpty
            ? "No administrator commands are enabled."
            : "Select a command to inspect or edit its confirmation and script."
        loadEditor()
    }

    private func captureEditor() {
        guard let editingIndex, commands.indices.contains(editingIndex) else { return }
        commands[editingIndex].isEnabled = enabledCheckbox.state == .on
        commands[editingIndex].command = commandField.stringValue
        commands[editingIndex].confirmationPrompt = promptField.stringValue
        commands[editingIndex].confirmationResponse = responseField.stringValue
        commands[editingIndex].script = scriptTextView.string
        tableView.reloadData(forRowIndexes: IndexSet(integer: editingIndex), columnIndexes: IndexSet(integersIn: 0..<3))
    }

    private func loadEditor() {
        guard let editingIndex, commands.indices.contains(editingIndex) else {
            enabledCheckbox.isEnabled = false
            commandField.isEnabled = false
            promptField.isEnabled = false
            responseField.isEnabled = false
            scriptTextView.isEditable = false
            removeButton.isEnabled = false
            enabledCheckbox.state = .off
            commandField.stringValue = ""
            promptField.stringValue = ""
            responseField.stringValue = ""
            scriptTextView.string = ""
            return
        }
        enabledCheckbox.isEnabled = true
        commandField.isEnabled = true
        promptField.isEnabled = true
        responseField.isEnabled = true
        scriptTextView.isEditable = true
        removeButton.isEnabled = true
        let command = commands[editingIndex]
        enabledCheckbox.state = command.isEnabled ? .on : .off
        commandField.stringValue = command.command
        promptField.stringValue = command.confirmationPrompt
        responseField.stringValue = command.confirmationResponse
        scriptTextView.string = command.script
    }

    @objc private func addCommand(_ sender: Any?) {
        captureEditor()
        let command = ROBMessagesAdministratorCommand(
            id: UUID().uuidString.lowercased(),
            isEnabled: true,
            command: "New Command",
            confirmationPrompt: "Run this administrator command? Reply YES within 90 seconds to confirm.",
            confirmationResponse: "YES",
            script: "# Enter a zsh script here\n"
        )
        commands.append(command)
        tableView.reloadData()
        selectRow(commands.count - 1)
        commandField.selectText(nil)
    }

    @objc private func removeCommand(_ sender: Any?) {
        guard let editingIndex, commands.indices.contains(editingIndex) else { return }
        commands.remove(at: editingIndex)
        let next = min(editingIndex, commands.count - 1)
        tableView.reloadData()
        selectRow(next >= 0 ? next : nil)
        statusLabel.stringValue = "Removal is not permanent until Save Commands is clicked."
    }

    @objc private func saveCommands(_ sender: Any?) {
        captureEditor()
        let validated: [ROBMessagesAdministratorCommand]
        do {
            validated = try ROBMessagesAdministratorCommandStore.validate(commands)
        } catch {
            presentAlert(title: "Administrator commands are invalid", detail: error.localizedDescription)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Save executable Messages commands?"
        alert.informativeText =
            "After an exact command and confirmation from an administrator handle, Cerebro will run the saved script as the signed-in macOS user. Review every script before saving."
        alert.addButton(withTitle: "Save Commands")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try ROBMessagesAdministratorCommandStore.save(validated)
            commands = validated
            ROBMessagesBridge.shared.reloadConfiguration()
            tableView.reloadData()
            statusLabel.stringValue = "Saved \(commands.count) administrator command\(commands.count == 1 ? "" : "s")."
        } catch {
            presentAlert(title: "Administrator commands could not be saved", detail: error.localizedDescription)
        }
    }

    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, to content: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: x, y: y, width: 500, height: 20)
        label.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(label)
    }

    private func selectRow(_ row: Int?) {
        isChangingSelection = true
        if let row, commands.indices.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            editingIndex = row
        } else {
            tableView.deselectAll(nil)
            editingIndex = nil
        }
        isChangingSelection = false
        loadEditor()
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func button(_ title: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = frame
        button.bezelStyle = .rounded
        return button
    }

    private func presentAlert(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
