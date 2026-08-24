//
//  ROBFaceIdentityWindowController.swift
//  Cerebro
//
//  Explicit consent, enrollment, and deletion controls for local identities.
//

import AppKit
import Foundation

@objcMembers public final class ROBFaceIdentityWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = ROBFaceIdentityWindowController()

    private let service = ROBFaceRecognitionService.shared
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enable face recognition", target: nil, action: nil)
    private let modelPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let pronunciationField = NSTextField()
    private let rolePopup = NSPopUpButton()
    private let trustField = NSTextField()
    private let consentCheckbox = NSButton(
        checkboxWithTitle: "The person explicitly consents to storing face samples on this Mac",
        target: nil,
        action: nil
    )
    private let startButton = NSButton(title: "Start Enrollment", target: nil, action: nil)
    private let refineButton = NSButton(title: "Refine Selected Identity", target: nil, action: nil)
    private let authorizeControllersButton = NSButton(
        title: "Authorize Active Controllers",
        target: nil,
        action: nil
    )
    private let cancelButton = NSButton(title: "Cancel Enrollment", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Selected Person", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "No enrollment in progress")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading face identity state…")
    private let table = NSTableView()
    private var profiles: [ROBFaceIdentityProfile] = []
    private var enrollingProfileID: UUID?

    private override init(window: NSWindow?) {
        super.init(window: window)
        buildWindow()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stateDidChange(_:)),
            name: .robFaceIdentityStateDidChange,
            object: service
        )
    }

    public convenience init() { self.init(window: nil) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        refresh()
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "People & Face Enrollment"
        window.minSize = NSSize(width: 820, height: 580)
        window.isReleasedWhenClosed = false
        self.window = window

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleEnabled(_:))
        enabledCheckbox.toolTip = "Recognition runs headlessly from the main camera when enabled."

        modelPopup.addItems(withTitles: ROBFaceEmbeddingModelOption.allCases.map(\.menuTitle))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        modelPopup.toolTip = "Choose the AdaFace embedding model used for new enrollment and recognition."

        nameField.placeholderString = "Name ROB should remember"
        pronunciationField.placeholderString = "Pronunciation (optional)"
        trustField.placeholderString = "Select Administrator to bind a paired controller"
        trustField.isEditable = false

        rolePopup.addItems(withTitles: ROBFaceIdentityRole.allCases.map(\.displayName))
        rolePopup.target = self
        rolePopup.action = #selector(roleChanged(_:))

        startButton.target = self
        startButton.action = #selector(startEnrollment(_:))
        refineButton.target = self
        refineButton.action = #selector(refineSelected(_:))
        refineButton.toolTip = "Add current lighting and pose coverage without changing this person's name or role."
        authorizeControllersButton.target = self
        authorizeControllersButton.action = #selector(authorizeControllersForSelected(_:))
        authorizeControllersButton.toolTip =
            "Replace the selected Administrator's allowlist with every active paired operator controller."
        cancelButton.target = self
        cancelButton.action = #selector(cancelEnrollment(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected(_:))

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(ROBFaceRecognitionService.enrollmentTargetSamples)

        progressLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 5
        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusLabel.setAccessibilityLabel("Live face enrollment guidance")

        let explanation = NSTextField(wrappingLabelWithString:
            "Face recognition remembers consenting people locally. Administrator is an identity label only: " +
            "robot motion, commands, pairing, secrets, and safety overrides still require a trusted controller credential."
        )
        explanation.textColor = .secondaryLabelColor

        let guidance = NSTextField(wrappingLabelWithString:
            "Live guidance will tell the person to stand closer, center one face, adjust lighting, hold still, and vary head position. Completed profiles can be refined later without changing their role."
        )
        guidance.textColor = .secondaryLabelColor

        for (identifier, title, width) in [
            ("name", "Person", CGFloat(165)),
            ("role", "Role", CGFloat(115)),
            ("model", "Model", CGFloat(145)),
            ("samples", "Samples", CGFloat(65)),
            ("controllers", "Controllers", CGFloat(90)),
            ("lighting", "Lighting range", CGFloat(110)),
            ("confirmed", "Last confirmed", CGFloat(145))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(tableSelectionChanged(_:))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table

        let enrollmentGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Face model"), modelPopup],
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Pronunciation"), pronunciationField],
            [NSTextField(labelWithString: "Role"), rolePopup],
            [NSTextField(labelWithString: "Trusted approval"), trustField]
        ])
        enrollmentGrid.rowSpacing = 8
        enrollmentGrid.columnSpacing = 12
        enrollmentGrid.column(at: 0).xPlacement = .trailing
        enrollmentGrid.column(at: 1).xPlacement = .fill

        let buttonRow = NSStackView(views: [
            startButton,
            refineButton,
            authorizeControllersButton,
            cancelButton,
            deleteButton
        ])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let content = NSStackView(views: [
            enabledCheckbox,
            explanation,
            guidance,
            NSBox.separator(),
            enrollmentGrid,
            consentCheckbox,
            buttonRow,
            progress,
            progressLabel,
            statusLabel,
            NSTextField(labelWithString: "Enrolled people"),
            scroll
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(content)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        enrollmentGrid.translatesAutoresizingMaskIntoConstraints = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            explanation.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            guidance.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            enrollmentGrid.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            consentCheckbox.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            progress.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        refreshControls()
    }

    private func refresh() {
        service.snapshot { [weak self] snapshot in self?.apply(snapshot) }
    }

    private func apply(_ snapshot: ROBFaceIdentityServiceSnapshot) {
        profiles = snapshot.profiles
        enrollingProfileID = snapshot.enrollingProfileID
        enabledCheckbox.state = snapshot.enabled ? .on : .off
        progress.maxValue = Double(max(1, snapshot.enrollmentTargetSamples))
        progress.doubleValue = Double(snapshot.enrollmentAcceptedSamples)
        if snapshot.enrollingProfileID == nil {
            progressLabel.stringValue = "No enrollment in progress"
        } else {
            let action = snapshot.enrollmentIsRefinement ? "Refinement" : "Enrollment"
            let remaining = max(0, snapshot.enrollmentTargetSamples - snapshot.enrollmentAcceptedSamples)
            progressLabel.stringValue =
                "\(action): \(snapshot.enrollmentAcceptedSamples) of \(snapshot.enrollmentTargetSamples) photos accepted • \(remaining) remaining"
        }
        statusLabel.stringValue = snapshot.status
        if let index = snapshot.availableModels.firstIndex(of: snapshot.selectedModel) {
            modelPopup.selectItem(at: index)
        }
        table.reloadData()
        refreshControls()
    }

    private func refreshControls() {
        let isEnrolling = enrollingProfileID != nil
        let selectedProfile = profiles.indices.contains(table.selectedRow)
            ? profiles[table.selectedRow]
            : nil
        startButton.isEnabled = !isEnrolling
        refineButton.isEnabled = !isEnrolling && selectedProfile?.enrollmentIsComplete == true
        authorizeControllersButton.isEnabled = !isEnrolling
            && selectedProfile?.role == .administrator
            && selectedProfile?.enrollmentIsComplete == true
            && !pairedOperatorControllers.isEmpty
        cancelButton.isEnabled = isEnrolling
        deleteButton.isEnabled = !isEnrolling && table.selectedRow >= 0
        nameField.isEnabled = !isEnrolling
        pronunciationField.isEnabled = !isEnrolling
        rolePopup.isEnabled = !isEnrolling
        modelPopup.isEnabled = !isEnrolling
        trustField.isEnabled = !isEnrolling && selectedRole == .administrator
        consentCheckbox.isEnabled = !isEnrolling
    }

    @objc private func stateDidChange(_ notification: Notification) { refresh() }

    @objc private func toggleEnabled(_ sender: NSButton) {
        service.enabled = sender.state == .on
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ROBFaceEmbeddingModelOption.allCases.indices.contains(index) else { return }
        let option = ROBFaceEmbeddingModelOption.allCases[index]
        service.selectModel(option) { [weak self] error in
            if let error {
                self?.showError(error.localizedDescription)
                self?.refresh()
            }
        }
    }

    @objc private func roleChanged(_ sender: NSPopUpButton) {
        if selectedRole == .administrator {
            let controllers = pairedOperatorControllers
            if !controllers.isEmpty {
                trustField.stringValue = controllers.map(\.deviceName).joined(separator: ", ")
                trustField.placeholderString =
                    "Binding \(controllers.count) active operator controller\(controllers.count == 1 ? "" : "s")"
                trustField.toolTip = controllers.map {
                    "\($0.deviceName): \($0.deviceID)"
                }.joined(separator: "\n")
            } else {
                trustField.stringValue = ""
                trustField.placeholderString = "Pair an operator controller before administrator imprinting"
                trustField.toolTip = nil
            }
        } else {
            trustField.stringValue = ""
            trustField.placeholderString = "Not required for a known person"
            trustField.toolTip = nil
        }
        refreshControls()
    }

    @objc private func tableSelectionChanged(_ sender: Any?) { refreshControls() }

    @objc private func startEnrollment(_ sender: Any?) {
        guard consentCheckbox.state == .on else {
            showError("Confirm the person's explicit consent before enrollment.")
            return
        }
        if selectedRole == .administrator {
            let controllers = pairedOperatorControllers
            guard !controllers.isEmpty else {
                showError("Pair a non-revoked operator controller before administrator imprinting.")
                return
            }
            let alert = NSAlert()
            alert.messageText = "Imprint Administrator?"
            alert.informativeText =
                "This stores a biometric identity label and authorizes \(controllers.count) active operator " +
                "controller\(controllers.count == 1 ? "" : "s") for administrator tools. Face identity alone " +
                "will not authorize robot motion; every control still requires its existing controller credential."
            alert.addButton(withTitle: "Begin Imprint")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if selectedRole == .administrator {
            service.startEnrollment(
                displayName: nameField.stringValue,
                pronunciation: pronunciationField.stringValue,
                role: selectedRole,
                consentConfirmed: true,
                trustedControllerIDs: pairedOperatorControllers.map(\.deviceID)
            ) { [weak self] error in
                if let error { self?.showError(error.localizedDescription) }
            }
        } else {
            service.startEnrollment(
                displayName: nameField.stringValue,
                pronunciation: pronunciationField.stringValue,
                role: selectedRole,
                consentConfirmed: true,
                trustedEnrollmentReference: "local-consent"
            ) { [weak self] error in
                if let error { self?.showError(error.localizedDescription) }
            }
        }
    }

    @objc private func cancelEnrollment(_ sender: Any?) {
        service.cancelEnrollment(deleteIncompleteProfile: true) { [weak self] error in
            if let error { self?.showError(error.localizedDescription) }
        }
    }

    @objc private func refineSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard profiles.indices.contains(row) else { return }
        guard consentCheckbox.state == .on else {
            showError("Confirm the person's explicit consent before refining recognition photos.")
            return
        }
        let profile = profiles[row]
        let alert = NSAlert()
        alert.messageText = "Refine \(profile.displayName)?"
        alert.informativeText =
            "Cerebro will add eight varied, quality-gated photos for the current lighting and pose. " +
            "The existing \(profile.role.displayName.lowercased()) role and trusted controller binding will not change."
        alert.addButton(withTitle: "Begin Refinement")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        service.refineEnrollment(profileID: profile.id, consentConfirmed: true) { [weak self] error in
            if let error { self?.showError(error.localizedDescription) }
        }
    }

    @objc private func authorizeControllersForSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard profiles.indices.contains(row) else { return }
        let profile = profiles[row]
        guard profile.role == .administrator, profile.enrollmentIsComplete else { return }
        let controllers = pairedOperatorControllers
        guard !controllers.isEmpty else {
            showError("Pair at least one non-revoked operator controller first.")
            return
        }
        let details = controllers.map { "• \($0.deviceName) — \($0.deviceID)" }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Authorize Active Controllers for \(profile.displayName)?"
        alert.informativeText =
            "This replaces the Administrator allowlist with the active operator controllers below. " +
            "Face samples and recognition data will not change. Revoked devices and lidar publishers are excluded.\n\n" +
            details
        alert.addButton(withTitle: "Authorize Controllers")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        service.authorizeActiveOperatorControllers(profileID: profile.id) { [weak self] error in
            if let error { self?.showError(error.localizedDescription) }
            self?.refresh()
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard profiles.indices.contains(row) else { return }
        let profile = profiles[row]
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(profile.displayName)?"
        alert.informativeText =
            "This permanently removes the encrypted profile, embeddings, and all retained face samples from this Mac."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        service.deleteProfile(id: profile.id) { [weak self] error in
            if let error { self?.showError(error.localizedDescription) }
        }
    }

    private var selectedRole: ROBFaceIdentityRole {
        ROBFaceIdentityRole.allCases.indices.contains(rolePopup.indexOfSelectedItem)
            ? ROBFaceIdentityRole.allCases[rolePopup.indexOfSelectedItem]
            : .knownPerson
    }

    private var pairedOperatorControllers: [ROBControlPairedDevice] {
        ROBControlPairing.pairedDevices().filter {
            !$0.isRevoked && $0.roleName == "operatorController"
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Face Enrollment"
        alert.informativeText = text
        alert.runModal()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard profiles.indices.contains(row), let tableColumn else { return nil }
        let profile = profiles[row]
        let value: String
        switch tableColumn.identifier.rawValue {
        case "name": value = profile.displayName
        case "role": value = profile.role.displayName
        case "model":
            value = ROBFaceEmbeddingModelOption(rawValue: profile.modelIdentifier)?.displayName
                .replacingOccurrences(of: "AdaFace R18 — ", with: "")
                ?? "Legacy"
        case "samples": value = "\(profile.samples.count)"
        case "controllers":
            value = profile.role == .administrator
                ? "\(profile.administratorControllerIDs.count) trusted"
                : "—"
        case "lighting":
            let values = profile.samples.compactMap(\.luminance)
            if let darkest = values.min(), let brightest = values.max() {
                value = String(format: "%d–%d%%", Int(darkest * 100), Int(brightest * 100))
            } else {
                value = "Not measured"
            }
        case "confirmed":
            value = profile.lastConfirmedAt.map { Self.dateFormatter.string(from: $0) } ?? "Never"
        default: value = ""
        }
        let identifier = NSUserInterfaceItemIdentifier("FaceIdentityCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let field = NSTextField(labelWithString: value)
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = value
        return cell
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
