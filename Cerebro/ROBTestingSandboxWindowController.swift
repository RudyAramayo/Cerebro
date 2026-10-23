import AppKit

/// A catalog of changing commissioning trials, separate from robot preferences.
/// Every physical action still enters the normal coordinator approval path.
@objcMembers public final class ROBTestingSandboxWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = ROBTestingSandboxWindowController()

    private enum ParameterSet: Equatable { case recycling, current, none }
    private struct Action {
        let title: String
        let command: String
    }
    private struct Trial {
        let id: String
        let title: String
        let detail: String
        let parameters: ParameterSet
        let actions: [Action]
    }
    private static let trials: [Trial] = [
        Trial(id: "recycling", title: "Recycle can", detail: "Find an upright empty can and an open orange bucket using the neck camera. Grasp the can at its middle, lift, carry and release above the opening. Search and preview do not move the arms. A run uses one complete-task authorization or an active supervised session.", parameters: .recycling,
              actions: [Action(title: "Run recycle test", command: "left_recycle_can"), Action(title: "Search only", command: "left_search_workspace"), Action(title: "Preview grasp…", command: "ghost:can")]),
        Trial(id: "object-cycle", title: "Grip and return", detail: "Present the left arm, grip a supported object gently, release into a supporting hand, then return the empty arm. Readiness confirmations remain within the same task authorization. Keep fingers clear of the jaws.", parameters: .current,
              actions: [Action(title: "Run grip and return", command: "left_object_cycle")]),
        Trial(id: "stationary-grippers", title: "Stationary gripper setup", detail: "Calibrate empty grippers while both arms are hanging and inactive. This does not lift or activate the arms. Keep both jaws clear; Amber acknowledges commands but jaw completion is not measured.", parameters: .none,
              actions: [Action(title: "Set up stationary empty grippers", command: "gripper-setup")]),
        Trial(id: "preparation", title: "Arm preparation and return", detail: "Exercise individual registered routes and stationary jaw commands. These are optional commissioning checks; recycling does not require a separate preparation test. Support any held object before preparation or return.", parameters: .current,
              actions: [Action(title: "Present / open left", command: "left_prepare"), Action(title: "Grip object", command: "left_grip"), Action(title: "Release to hand", command: "left_release"), Action(title: "Lower empty left arm", command: "left_relax"), Action(title: "Check hanging", command: "left_check_hanging"), Action(title: "Run both-arm startup route", command: "startup"), Action(title: "Relax empty arms", command: "relax")]),
        Trial(id: "ghost", title: "Ghost motion rehearsal", detail: "Inspect and review a simulated arm path before requesting its execution. Open the controller input scene to edit a gesture or inspect the wave preset.", parameters: .none,
              actions: [Action(title: "Open ghost editor…", command: "ghost:center"), Action(title: "Preview left wave…", command: "ghost:wave"), Action(title: "Motion rehearsal…", command: "show-rehearsal")]),
        Trial(id: "demonstration", title: "Body demonstration", detail: "Record a short camera demonstration, then replay the taught arm route or test the front-arm greeting.", parameters: .none,
              actions: [Action(title: "Record body demonstration", command: "teach"), Action(title: "Replay last", command: "replay"), Action(title: "Front-arm greeting", command: "wave")]),
        Trial(id: "feedback", title: "Spoken feedback", detail: "Check the spoken arm warning without starting an arm movement.", parameters: .none,
              actions: [Action(title: "Test spoken arm warning", command: "speech-test")])
    ]

    private let table = NSTableView()
    private let detailStack = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let session = NSTextField(wrappingLabelWithString: "")
    private let continueCycle = NSButton(title: "Continue", target: nil, action: nil)
    private let save = NSButton(title: "Save test parameters", target: nil, action: nil)
    private var fields: [String: NSTextField] = [:]
    private var actionButtons: [NSButton] = []
    private var displayedCycleStage = ""
    private var parameterMessage = ""
    private var observingLeftOperation = false
    private var hasCalibrationFields = false
    private var startSessionButton: NSButton!
    private var endSessionButton: NSButton!
    private var selectedTrial: Trial { Self.trials[max(0, min(table.selectedRow, Self.trials.count - 1))] }
    private var canEdit: Bool {
        !ROBLeftArmTrial.shared.isRunning && !ROBArmRoutineCoordinator.shared.isRunning &&
            !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion && !ROBControllerArmApproval.shared.isPending &&
            !ROBGripperStartupCalibration.shared.isRunning
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Testing Sandbox"
        window.identifier = NSUserInterfaceItemIdentifier("rob-testing-sandbox")
        window.minSize = NSSize(width: 870, height: 760)
        super.init(window: window)
        buildInterface()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBArmRoutineDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBControllerArmApprovalDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .ROBGripperStartupCalibrationDidChange, object: nil)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Use shared") }
    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                                     root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                                     root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
        let heading = NSTextField(labelWithString: "Testing Sandbox"); heading.font = .boldSystemFont(ofSize: 22)
        root.addArrangedSubview(heading)
        let sessionRow = NSStackView(); sessionRow.spacing = 8
        startSessionButton = NSButton(title: "Start 15-minute left-arm session", target: self, action: #selector(startSession))
        startSessionButton.identifier = NSUserInterfaceItemIdentifier("sandbox-start-arm-session")
        endSessionButton = NSButton(title: "End session", target: self, action: #selector(endSession))
        let stop = NSButton(title: "Stop + hold", target: self, action: #selector(stop)); stop.bezelColor = .systemRed
        stop.identifier = NSUserInterfaceItemIdentifier("sandbox-stop")
        for item in [startSessionButton!, endSessionButton!, stop] { sessionRow.addArrangedSubview(item) }
        root.addArrangedSubview(sessionRow); root.addArrangedSubview(session)
        let split = NSStackView(); split.orientation = .horizontal; split.alignment = .top; split.spacing = 18
        let listScroll = NSScrollView(); listScroll.borderType = .bezelBorder; listScroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test")); column.title = "Tests"; column.width = 240
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 40
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("Sandbox tests")
        table.identifier = NSUserInterfaceItemIdentifier("sandbox-test-list")
        listScroll.documentView = table
        listScroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        split.addArrangedSubview(listScroll)
        let detailScroll = NSScrollView(); detailScroll.hasVerticalScroller = true; detailScroll.autohidesScrollers = true
        let document = ROBTestingSandboxDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = document
        detailStack.orientation = .vertical; detailStack.alignment = .leading; detailStack.spacing = 12
        detailStack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(detailStack)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
                                     detailStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
                                     detailStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
                                     detailStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
                                     detailStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)])
        split.addArrangedSubview(detailScroll)
        root.addArrangedSubview(split)
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        listScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        detailScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        continueCycle.target = self; continueCycle.action = #selector(continueObjectCycle)
        continueCycle.identifier = NSUserInterfaceItemIdentifier("left-cycle-continue")
        root.addArrangedSubview(continueCycle)
        status.isSelectable = true; status.font = .systemFont(ofSize: 12)
        status.identifier = NSUserInterfaceItemIdentifier("sandbox-test-status")
        let statusScroll = NSScrollView(); statusScroll.hasVerticalScroller = true; statusScroll.autohidesScrollers = true
        statusScroll.borderType = .bezelBorder
        let statusDocument = ROBTestingSandboxDocumentView(); statusDocument.translatesAutoresizingMaskIntoConstraints = false
        statusScroll.documentView = statusDocument
        status.translatesAutoresizingMaskIntoConstraints = false; statusDocument.addSubview(status)
        NSLayoutConstraint.activate([statusDocument.widthAnchor.constraint(equalTo: statusScroll.contentView.widthAnchor),
                                     status.leadingAnchor.constraint(equalTo: statusDocument.leadingAnchor, constant: 8),
                                     status.trailingAnchor.constraint(equalTo: statusDocument.trailingAnchor, constant: -8),
                                     status.topAnchor.constraint(equalTo: statusDocument.topAnchor, constant: 8),
                                     status.bottomAnchor.constraint(equalTo: statusDocument.bottomAnchor, constant: -8),
                                     statusScroll.heightAnchor.constraint(equalToConstant: 120)])
        root.addArrangedSubview(statusScroll)
        statusScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        session.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { Self.trials.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: Self.trials[row].title)
        label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                                     label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                                     label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    public func tableViewSelectionDidChange(_ notification: Notification) { buildDetail(); refresh() }

    private func buildDetail() {
        detailStack.arrangedSubviews.forEach { detailStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        fields.removeAll(); actionButtons.removeAll(); parameterMessage = ""; hasCalibrationFields = false
        let trial = selectedTrial
        let title = NSTextField(labelWithString: trial.title); title.font = .boldSystemFont(ofSize: 18)
        detailStack.addArrangedSubview(title)
        addHelp(trial.detail)
        if trial.parameters == .recycling {
            do {
                let parameters = try ROBRecyclingTestParameters.load()
                addField("motionPace", "Motion pace", parameters.motionPace, note: "1.0–1.25 · keeps existing motion limits")
                addField("jawSettleSeconds", "Jaw settling time (s)", parameters.jawSettleSeconds, note: "1.0–2.0")
                addField("pathAdjustment", "Maximum path adjustment (mm)", parameters.maximumPathDeviationMeters * 1000, note: "0–5")
                let calibration = try readCalibration()
                let translation = calibration["translationMeters"] as? [Double] ?? []
                guard translation.count == 3 else { throw ROBGhostMotionError.blocked("The reach calibration needs three translation values.") }
                hasCalibrationFields = true
                for (index, axis) in ["X", "Y", "Z"].enumerated() {
                    addField("translation\(index)", "Reach \(axis) correction (cm)", translation[index] * 100, note: "−15–15")
                }
                addField("canOutwardMeters", "Additional reach toward can (cm)", (calibration["canOutwardMeters"] as? Double ?? 0) * 100, note: "0–3")
                if let base = calibration["tabletopCanBaseHeightMeters"] as? Double {
                    addField("tabletopCanBaseHeightMeters", "Calibrated can-base height (cm)", base * 100, note: "30–140")
                    addHelp("The detected can height sets the middle grasp above this calibrated base. Reach Z correction is used only when no calibrated base height is present.")
                }
                addField("bucketYawDegrees", "Bucket release rotation (°)", calibration["bucketYawDegrees"] as? Double ?? 0, note: "−30–30")
                addField("bucketInwardMeters", "Release toward robot (cm)", (calibration["bucketInwardMeters"] as? Double ?? 0) * 100, note: "0–8")
            } catch { parameterMessage = error.localizedDescription; addHelp("Parameters unavailable: \(error.localizedDescription)") }
        }
        if trial.parameters != .none {
            addField("currentLimit", "Current jump stop (raw units)", UserDefaults.standard.double(forKey: ROBLeftArmTrial.currentLimitKey), note: "0 = record only")
            addHelp("Current is recorded automatically. This sample-to-sample threshold is not a measured force limit.")
            save.target = self; save.action = #selector(saveParameters)
            save.identifier = NSUserInterfaceItemIdentifier("sandbox-save-parameters")
            detailStack.addArrangedSubview(save)
        }
        let actionTitle = NSTextField(labelWithString: "Actions"); actionTitle.font = .boldSystemFont(ofSize: 13)
        detailStack.addArrangedSubview(actionTitle)
        for (index, action) in trial.actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(performTrialAction(_:)))
            button.tag = index; button.identifier = NSUserInterfaceItemIdentifier("sandbox-\(trial.id)-\(index)")
            detailStack.addArrangedSubview(button); actionButtons.append(button)
        }
        detailStack.addArrangedSubview(NSButton(title: "Show latest recording", target: self, action: #selector(showRecording)))
    }
    private func addHelp(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
    }
    private func addField(_ key: String, _ title: String, _ value: Double, note: String) {
        let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 245).isActive = true
        let field = NSTextField(string: String(format: "%.10g", value))
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        field.setAccessibilityLabel(title); field.identifier = NSUserInterfaceItemIdentifier("sandbox-parameter-\(key)")
        fields[key] = field
        let hint = NSTextField(labelWithString: note); hint.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, field, hint]); row.spacing = 8; detailStack.addArrangedSubview(row)
    }

    private func readCalibration() throws -> [String: Any] {
        let data = try Data(contentsOf: ROBLeftCanReachCalibration.file)
        guard data.count <= 16_384, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let directory = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw ROBGhostMotionError.blocked("A valid local reach calibration is required before editing it.")
        }
        let model = try ROBGhostRobotModel(directory: directory)
        _ = try ROBLeftCanReachCalibration.loadBucketYaw(model: model)
        guard value["modelID"] as? String == model.modelID, value["referenceID"] as? String == model.referenceID,
              value["mappingID"] as? String == ROBGhostRobotModel.mappingID else {
            throw ROBGhostMotionError.blocked("The reach calibration belongs to a different robot model.")
        }
        return value
    }
    private func value(_ key: String, within range: ClosedRange<Double>) throws -> Double {
        guard let field = fields[key], let number = Double(field.stringValue), number.isFinite, range.contains(number) else {
            throw ROBGhostMotionError.blocked("Enter a value from \(range.lowerBound) to \(range.upperBound) for \(fields[key]?.accessibilityLabel() ?? key).")
        }
        return number
    }
    @discardableResult private func storeParameters() -> Bool {
        guard canEdit else { parameterMessage = "Finish or stop the active operation before changing test parameters."; refresh(); return false }
        window?.makeFirstResponder(nil)
        guard selectedTrial.parameters != .none else { return true }
        do {
            let current = try value("currentLimit", within: 0...Double.greatestFiniteMagnitude)
            if selectedTrial.parameters == .recycling {
                let parameters = ROBRecyclingTestParameters(motionPace: try value("motionPace", within: 1...1.25),
                    jawSettleSeconds: try value("jawSettleSeconds", within: 1...2),
                    maximumPathDeviationMeters: try value("pathAdjustment", within: 0...5) / 1000)
                var calibrationData: Data?
                if hasCalibrationFields {
                    var calibration = try readCalibration()
                    calibration["translationMeters"] = try (0..<3).map { try value("translation\($0)", within: -15...15) / 100 }
                    calibration["canOutwardMeters"] = try value("canOutwardMeters", within: 0...3) / 100
                    calibration["bucketYawDegrees"] = try value("bucketYawDegrees", within: -30...30)
                    calibration["bucketInwardMeters"] = try value("bucketInwardMeters", within: 0...8) / 100
                    if fields["tabletopCanBaseHeightMeters"] != nil {
                        calibration["tabletopCanBaseHeightMeters"] = try value("tabletopCanBaseHeightMeters", within: 30...140) / 100
                    }
                    let data = try JSONSerialization.data(withJSONObject: calibration, options: [.prettyPrinted, .sortedKeys])
                    guard data.count <= 16_384 else { throw ROBGhostMotionError.blocked("The reach calibration is too large.") }
                    calibrationData = data
                }
                try parameters.save()
                // Preserve model identity, source and every unknown optional field.
                if let calibrationData { try calibrationData.write(to: ROBLeftCanReachCalibration.file, options: .atomic) }
            }
            UserDefaults.standard.set(current, forKey: ROBLeftArmTrial.currentLimitKey)
            parameterMessage = "Parameters saved for the next test."
            refresh(); return true
        } catch { parameterMessage = error.localizedDescription; refresh(); return false }
    }
    @objc private func saveParameters() { _ = storeParameters() }
    @objc private func performTrialAction(_ sender: NSButton) {
        guard canEdit, selectedTrial.actions.indices.contains(sender.tag) else { return }
        let command = selectedTrial.actions[sender.tag].command
        if selectedTrial.parameters != .none && command != "left_search_workspace" && !storeParameters() { return }
        if command.hasPrefix("ghost:") {
            NotificationCenter.default.post(name: Notification.Name("ROBShowControllerInputDiagnostics"), object: self,
                                            userInfo: ["ghostPreset": String(command.dropFirst(6))])
        } else if command == "gripper-setup" {
            observingLeftOperation = false; parameterMessage = ""
            Task { @MainActor [weak self] in
                do { try await ROBGripperStartupCalibration.shared.prepareStationaryEmptyGrippers() }
                catch { self?.parameterMessage = error.localizedDescription }
                self?.refresh()
            }
        } else if command == "show-rehearsal" { ROBShowMotionCoordinator.shared.showControls(self) }
        else if command == "speech-test" { ROBArmFeedbackAlerts.shared.testSpeech() }
        else { run(command) }
    }
    @objc private func startSession() { run("arm_session") }
    @objc private func endSession() { run("end_arm_session") }
    private func run(_ command: String) {
        parameterMessage = ""
        observingLeftOperation = ROBLeftArmTrial.commands.contains(command)
        ROBArmRoutineCoordinator.shared.performCommand(command, target: "") { [weak self] _ in self?.refresh() }
        refresh()
    }
    @objc private func continueObjectCycle() {
        _ = ROBLeftArmTrial.shared.continueOperation(stage: displayedCycleStage); refresh()
    }
    @objc private func showRecording() {
        let path = ROBLeftArmTrial.shared.lastRecordingPath
        if !path.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    @objc private func stop() {
        ROBArmRoutineCoordinator.shared.cancel(reason: "Stop requested in Testing Sandbox")
        _ = ROBAmberGestureExecutor.shared.cancelCurrentGesture(reason: "Stop requested in Testing Sandbox")
        _ = ROBAmberGestureExecutor.shared.requestPriorityHold()
        refresh()
    }
    @objc private func refresh() {
        let left = ROBLeftArmTrial.shared
        if ROBControllerArmApproval.shared.isPending {
            // Keep the complete operation scope visible while approval is pending.
            status.stringValue = ROBControllerArmApproval.shared.status
        } else if left.isRunning || observingLeftOperation {
            status.stringValue = left.status
        } else if ROBGripperStartupCalibration.shared.isRunning {
            status.stringValue = ROBGripperStartupCalibration.shared.status
        } else {
            status.stringValue = ROBArmRoutineCoordinator.shared.status
        }
        if !parameterMessage.isEmpty { status.stringValue = parameterMessage + "\n" + status.stringValue }
        session.stringValue = ROBControllerArmApproval.shared.armSessionDetail
        displayedCycleStage = left.interactionStage
        switch displayedCycleStage {
        case "object_placed": continueCycle.title = "Object placed; fingers clear → Grip"
        case "receiver_supporting": continueCycle.title = "Hand supporting object → Release"
        case "object_clear": continueCycle.title = "Object clear of jaws → Lower empty arm"
        default: continueCycle.title = "Continue object cycle"
        }
        continueCycle.isHidden = displayedCycleStage.isEmpty
        continueCycle.isEnabled = left.isRunning && !displayedCycleStage.isEmpty
        for field in fields.values { field.isEnabled = canEdit }
        save.isEnabled = canEdit
        for button in actionButtons { button.isEnabled = canEdit }
        startSessionButton.isEnabled = canEdit && !ROBControllerArmApproval.shared.armSessionActive
        endSessionButton.isEnabled = ROBControllerArmApproval.shared.armSessionActive
    }
}

private final class ROBTestingSandboxDocumentView: NSView {
    override var isFlipped: Bool { true }
}
