//
//  ROBServoControlWindowController.swift
//  Cerebro
//
//  Operator editor for named camera poses, phased servo sequences, and
//  relative gestures. Sequence editing intentionally owns the largest panel.
//

import AppKit
import Foundation

@objcMembers public final class ROBServoControlWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
    public static let shared = ROBServoControlWindowController()

    public weak var serialBox: ROBSerialBox? {
        didSet { runtime.serialBox = serialBox; refreshStatus() }
    }

    private let store = ROBServoControlStore.shared
    private let runtime = ROBServoControlRuntime()
    private let positionsTable = NSTableView()
    private let sequencesTable = NSTableView()
    private let gesturesTable = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Ready")
    private var positions: [ROBServoCameraPosition] = []
    private var phases: [ROBServoSequencePhase] = []
    private var gestures: [ROBServoRelativeGesture] = []
    private var refreshTimer: Timer?

    private override init(window: NSWindow?) {
        let createdWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: createdWindow)
        createdWindow.title = "ROB Servo Control"
        createdWindow.isReleasedWhenClosed = false
        createdWindow.minSize = NSSize(width: 920, height: 720)
        createdWindow.delegate = self
        createdWindow.center()
        runtime.statusDidChange = { [weak self] status in
            self?.statusLabel.stringValue = status
            self?.refreshStatus(appendTo: status)
        }
        configureTables()
        configureContent()
        reloadDrafts()
    }

    public convenience init() { self.init(window: nil) }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        reloadDrafts()
        refreshStatus()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in self?.refreshStatus()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === positionsTable { return positions.count }
        if tableView === sequencesTable { return phases.count }
        return gestures.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue else { return nil }
        let cell = NSTableCellView()
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(columnID)
        field.stringValue = value(tableView: tableView, column: columnID, row: row)
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        for table in [positionsTable, sequencesTable, gesturesTable] {
            let row = table.row(for: field)
            let column = table.column(for: field)
            if row >= 0, column >= 0 {
                let columnID = table.tableColumns[column].identifier.rawValue
                update(tableView: table, column: columnID, row: row, value: field.stringValue)
                return
            }
        }
    }

    private func configureTables() {
        configure(
            table: positionsTable,
            columns: [("name", "Position", 360), ("lower", "Lower", 180), ("upper", "Upper", 180)]
        )
        configure(
            table: sequencesTable,
            columns: [
                ("sequence", "Sequence", 125), ("index", "Phase", 62),
                ("phaseName", "Phase name", 220), ("camera", "Camera position", 145),
                ("pan", "Pan", 95), ("lower", "Lower", 95), ("upper", "Upper", 95),
                ("hold", "Hold (s)", 90),
            ]
        )
        configure(
            table: gesturesTable,
            columns: [
                ("name", "Gesture", 240), ("servo", "Servo", 180),
                ("delta", "Delta", 150), ("repetitions", "Repetitions", 150),
                ("interval", "Interval (s)", 150),
            ]
        )
    }

    private func configure(
        table: NSTableView,
        columns: [(String, String, CGFloat)]
    ) {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 25
        table.headerView = NSTableHeaderView()
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = min(60, width)
            column.isEditable = true
            table.addTableColumn(column)
        }
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "Servo Control")
        heading.font = .boldSystemFont(ofSize: 22)
        let intro = NSTextField(wrappingLabelWithString:
            "Edit named camera positions, phased servo sequences, and relative gestures. Saved commands still pass through ROB’s live neck safety window; a limited target stops a sequence instead of silently overriding the restriction."
        )
        intro.textColor = .secondaryLabelColor

        let positionBox = section(
            title: "Camera positions",
            table: positionsTable,
            buttons: [
                button("Add", #selector(addPosition(_:))),
                button("Delete", #selector(deletePosition(_:))),
                button("Apply Selected", #selector(applyPosition(_:))),
            ]
        )
        positionBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let sequenceBox = section(
            title: "Servo sequences — startup must remain phases 1, 2, and 3",
            table: sequencesTable,
            buttons: [
                button("Add Phase", #selector(addPhase(_:))),
                button("Delete Phase", #selector(deletePhase(_:))),
                button("Run Selected Sequence", #selector(runSequence(_:))),
                button("Run Startup", #selector(runStartup(_:))),
                button("Stop", #selector(stopRuntime(_:))),
            ]
        )
        // Sequence design is the primary task in this window and deliberately
        // receives more vertical space than either catalog table.
        sequenceBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        sequenceBox.setContentHuggingPriority(.defaultLow, for: .vertical)

        let gestureBox = section(
            title: "Relative gestures — delta is applied around the current servo target",
            table: gesturesTable,
            buttons: [
                button("Add", #selector(addGesture(_:))),
                button("Delete", #selector(deleteGesture(_:))),
                button("Play Selected", #selector(playGesture(_:))),
                button("Stop", #selector(stopRuntime(_:))),
            ]
        )
        gestureBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let save = button("Save Configuration", #selector(saveConfiguration(_:)))
        save.keyEquivalent = "\r"
        let restore = button("Restore Shipped Defaults", #selector(restoreDefaults(_:)))
        let actions = horizontal([save, restore, NSView()])
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            heading, intro, positionBox, sequenceBox, gestureBox, actions, statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [intro, positionBox, sequenceBox, gestureBox, actions, statusLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        for view in [heading, intro, positionBox, sequenceBox, gestureBox, actions, statusLabel] {
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14),
        ])
    }

    private func section(
        title: String,
        table: NSTableView,
        buttons: [NSButton]
    ) -> NSBox {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let row = horizontal(buttons + [NSView()])
        let stack = NSStackView(views: [scroll, row])
        stack.orientation = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let box = NSBox()
        box.title = title
        box.contentView?.addSubview(stack)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            ])
        }
        return box
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func reloadDrafts() {
        positions = store.cameraPositionsSnapshot()
        phases = store.sequencePhasesSnapshot()
        gestures = store.gesturesSnapshot()
        positionsTable.reloadData()
        sequencesTable.reloadData()
        gesturesTable.reloadData()
        if !positions.isEmpty { positionsTable.selectRowIndexes([0], byExtendingSelection: false) }
        if !phases.isEmpty { sequencesTable.selectRowIndexes([0], byExtendingSelection: false) }
        if !gestures.isEmpty { gesturesTable.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func saveConfiguration(_ sender: Any?) {
        _ = saveDrafts()
    }

    @discardableResult private func saveDrafts() -> Bool {
        window?.makeFirstResponder(nil)
        do {
            try store.replaceConfiguration(
                cameraPositions: positions,
                sequencePhases: phases,
                gestures: gestures
            )
            statusLabel.stringValue = "Configuration saved. Future startup runs will use this validated three-phase snapshot."
            return true
        } catch {
            statusLabel.stringValue = "Not saved: \(error.localizedDescription)"
            NSSound.beep()
            return false
        }
    }

    @objc private func addPosition(_ sender: Any?) {
        positions.append(ROBServoCameraPosition(
            name: uniqueName(prefix: "position", existing: positions.map(\.name)),
            lowerTarget: 6011,
            upperTarget: 6073
        ))
        positionsTable.reloadData()
        positionsTable.selectRowIndexes([positions.count - 1], byExtendingSelection: false)
    }

    @objc private func deletePosition(_ sender: Any?) {
        let row = positionsTable.selectedRow
        guard positions.indices.contains(row), positions.count > 1 else { NSSound.beep(); return }
        positions.remove(at: row)
        positionsTable.reloadData()
    }

    @objc private func applyPosition(_ sender: Any?) {
        let row = positionsTable.selectedRow
        guard positions.indices.contains(row), saveDrafts() else { NSSound.beep(); return }
        runtime.apply(cameraPosition: positions[row])
    }

    @objc private func addPhase(_ sender: Any?) {
        let selectedSequence = phases.indices.contains(sequencesTable.selectedRow)
            ? phases[sequencesTable.selectedRow].sequenceName : "sequence"
        let next = (phases.filter { $0.sequenceName == selectedSequence }.map(\.phaseIndex).max() ?? 0) + 1
        phases.append(ROBServoSequencePhase(
            sequenceName: selectedSequence,
            phaseIndex: next,
            phaseName: "Phase \(next)",
            cameraPositionName: "upright",
            panTarget: 5799,
            lowerTarget: 6011,
            upperTarget: 6073,
            holdSeconds: 0.25
        ))
        sortPhases()
        selectPhase(sequence: selectedSequence, index: next)
    }

    @objc private func deletePhase(_ sender: Any?) {
        let row = sequencesTable.selectedRow
        guard phases.indices.contains(row) else { NSSound.beep(); return }
        phases.remove(at: row)
        sequencesTable.reloadData()
    }

    @objc private func runSequence(_ sender: Any?) {
        let row = sequencesTable.selectedRow
        guard phases.indices.contains(row), saveDrafts() else { NSSound.beep(); return }
        runtime.run(sequenceNamed: phases[row].sequenceName)
    }

    @objc private func runStartup(_ sender: Any?) {
        guard saveDrafts() else { return }
        runtime.run(sequenceNamed: "startup")
    }

    @objc private func addGesture(_ sender: Any?) {
        gestures.append(ROBServoRelativeGesture(
            name: uniqueName(prefix: "gesture", existing: gestures.map(\.name)),
            servo: "upper",
            delta: 120,
            repetitions: 1,
            intervalSeconds: 0.35
        ))
        gesturesTable.reloadData()
        gesturesTable.selectRowIndexes([gestures.count - 1], byExtendingSelection: false)
    }

    @objc private func deleteGesture(_ sender: Any?) {
        let row = gesturesTable.selectedRow
        guard gestures.indices.contains(row) else { NSSound.beep(); return }
        gestures.remove(at: row)
        gesturesTable.reloadData()
    }

    @objc private func playGesture(_ sender: Any?) {
        let row = gesturesTable.selectedRow
        guard gestures.indices.contains(row), saveDrafts() else { NSSound.beep(); return }
        runtime.run(gesture: gestures[row])
    }

    @objc private func stopRuntime(_ sender: Any?) {
        runtime.stop()
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Restore shipped servo configuration?"
        alert.informativeText = "This replaces saved camera positions, sequences, and gestures. It does not move hardware."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runtime.stop()
        store.restoreDefaults()
        reloadDrafts()
        statusLabel.stringValue = "Shipped servo configuration restored; no servo command was sent."
    }

    private func value(tableView: NSTableView, column: String, row: Int) -> String {
        if tableView === positionsTable {
            let item = positions[row]
            switch column {
            case "name": return item.name
            case "lower": return String(item.lowerTarget)
            default: return String(item.upperTarget)
            }
        }
        if tableView === sequencesTable {
            let item = phases[row]
            switch column {
            case "sequence": return item.sequenceName
            case "index": return String(item.phaseIndex)
            case "phaseName": return item.phaseName
            case "camera": return item.cameraPositionName
            case "pan": return String(item.panTarget)
            case "lower": return String(item.lowerTarget)
            case "upper": return String(item.upperTarget)
            default: return String(format: "%.2f", item.holdSeconds)
            }
        }
        let item = gestures[row]
        switch column {
        case "name": return item.name
        case "servo": return item.servo
        case "delta": return String(item.delta)
        case "repetitions": return String(item.repetitions)
        default: return String(format: "%.2f", item.intervalSeconds)
        }
    }

    private func update(
        tableView: NSTableView,
        column: String,
        row: Int,
        value: String
    ) {
        if tableView === positionsTable, positions.indices.contains(row) {
            let item = positions[row]
            if column == "name" { item.name = value }
            else if column == "lower", let parsed = Int(value) { item.lowerTarget = parsed }
            else if column == "upper", let parsed = Int(value) { item.upperTarget = parsed }
            else { invalidCell(tableView, row: row); return }
        } else if tableView === sequencesTable, phases.indices.contains(row) {
            let item = phases[row]
            switch column {
            case "sequence": item.sequenceName = value
            case "index": if let parsed = Int(value) { item.phaseIndex = parsed } else { invalidCell(tableView, row: row); return }
            case "phaseName": item.phaseName = value
            case "camera": item.cameraPositionName = value
            case "pan": if let parsed = Int(value) { item.panTarget = parsed } else { invalidCell(tableView, row: row); return }
            case "lower": if let parsed = Int(value) { item.lowerTarget = parsed } else { invalidCell(tableView, row: row); return }
            case "upper": if let parsed = Int(value) { item.upperTarget = parsed } else { invalidCell(tableView, row: row); return }
            default: if let parsed = Double(value) { item.holdSeconds = parsed } else { invalidCell(tableView, row: row); return }
            }
            sortPhases()
        } else if gestures.indices.contains(row) {
            let item = gestures[row]
            switch column {
            case "name": item.name = value
            case "servo": item.servo = value.lowercased()
            case "delta": if let parsed = Int(value) { item.delta = parsed } else { invalidCell(tableView, row: row); return }
            case "repetitions": if let parsed = Int(value) { item.repetitions = parsed } else { invalidCell(tableView, row: row); return }
            default: if let parsed = Double(value) { item.intervalSeconds = parsed } else { invalidCell(tableView, row: row); return }
            }
        }
    }

    private func invalidCell(_ table: NSTableView, row: Int) {
        statusLabel.stringValue = "That cell requires a valid number."
        NSSound.beep()
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0 ..< table.numberOfColumns))
    }

    private func sortPhases() {
        phases.sort {
            let order = $0.sequenceName.localizedCaseInsensitiveCompare($1.sequenceName)
            return order == .orderedSame ? $0.phaseIndex < $1.phaseIndex : order == .orderedAscending
        }
        sequencesTable.reloadData()
    }

    private func selectPhase(sequence: String, index: Int) {
        sortPhases()
        if let row = phases.firstIndex(where: { $0.sequenceName == sequence && $0.phaseIndex == index }) {
            sequencesTable.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    private func uniqueName(prefix: String, existing: [String]) -> String {
        let names = Set(existing.map { $0.lowercased() })
        var index = 1
        while names.contains("\(prefix)_\(index)") { index += 1 }
        return "\(prefix)_\(index)"
    }

    private func refreshStatus(appendTo message: String? = nil) {
        guard let box = serialBox else {
            if message == nil { statusLabel.stringValue = "Waiting for ROB's serial service." }
            return
        }
        let pose = box.isNeckCommandStateKnown
            ? "Commanded P \(box.commandedNeckPanTarget) • L \(box.commandedLowerNeckTiltTarget) • U \(box.commandedUpperNeckTiltTarget)"
            : "Commanded neck pose unknown"
        if let message {
            statusLabel.stringValue = "\(message)  \(pose)"
        } else if !runtime.isRunning {
            statusLabel.stringValue = "\(pose) — \(box.neckCommandSafetyStatus)"
        }
    }
}
