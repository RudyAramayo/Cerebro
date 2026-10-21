import AppKit

@objcMembers final class ROBArmRoutineSettingsViewController: NSViewController {
    private let startup = NSButton(checkboxWithTitle: "Calibrate arms on startup", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: "")
    private let inspectionPan = NSPopUpButton(frame: .zero, pullsDown: false)
    private let currentLimit = NSTextField(string: "0")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 580))
        let title = NSTextField(labelWithString: "Arms and grippers")
        title.font = .boldSystemFont(ofSize: 20)
        startup.state = UserDefaults.standard.bool(forKey: ROBArmRoutinePlan.startupDefaultsKey) ? .on : .off
        startup.target = self; startup.action = #selector(changeStartup)
        for (title, degrees) in [("Center", 0), ("10° right", -10), ("10° left", 10)] {
            inspectionPan.addItem(withTitle: title)
            inspectionPan.lastItem?.representedObject = NSNumber(value: degrees)
        }
        inspectionPan.selectItem(at: [0.0, -10, 10].firstIndex(of: ROBArmRoutinePlan.inspectionPanDegrees()) ?? 0)
        inspectionPan.target = self; inspectionPan.action = #selector(changeInspectionPan)
        inspectionPan.setAccessibilityLabel("Arm inspection camera pan")
        let inspectionRow = NSStackView(views: [NSTextField(labelWithString: "Arm inspection camera pan:"), inspectionPan])
        inspectionRow.spacing = 10
        let explanation = NSTextField(wrappingLabelWithString:
            "One Vision Pro or iPhone approval covers the complete taught arm route under your supervision, including an incomplete camera view. Watch the arms and keep Stop + hold ready. Startup brings hanging arms forward, checks calibration and requests both grippers open. Every Prepare opens both jaws automatically, reusing current calibration; empty-jaw calibration runs only when needed. Support any held object before approving preparation. Paired forward travel took about 22 seconds in one supervised trial; camera checks and gripper work take additional time.")
        let commands = NSTextField(wrappingLabelWithString:
            "Say or type ‘relax’ to lower the arms gently and turn off holding torque. ‘Grab this’ or ‘hold this’ brings the arms forward and attempts a gentle close when the camera sees the object between a gripper’s jaws. These commands are available without enabling startup calibration. Each complete operation needs one controller approval. Stop + hold is immediate.")
        let limitation = NSTextField(wrappingLabelWithString:
            "‘Copy my pose’ records five seconds from the main camera. Replay and greeting use only the taught arm route and leave the grippers unchanged; confirm empty jaws when approving. Live camera, person/hand detection, motor feedback and Stop remain active. Full human pose copying and general reaching need validated geometry.")
        limitation.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [button("Run startup now", #selector(runStartup)),
            button("Prepare to grab", #selector(prepareArms)), button("Relax arms", #selector(relax)),
            button("Stop + hold", #selector(stop))])
        buttons.spacing = 10
        let teaching = NSStackView(views: [button("Motion rehearsal…", #selector(rehearsal)), button("Record body demonstration", #selector(teach)),
            button("Replay last", #selector(replay)), button("Front-arm greeting", #selector(wave))])
        let speechTest = button("Test spoken arm warning", #selector(testArmSpeech))
        teaching.spacing = 10
        let leftTitle = NSTextField(labelWithString: "Left arm — supervised trial")
        leftTitle.font = .boldSystemFont(ofSize: 15)
        let leftHelp = NSTextField(wrappingLabelWithString: "Wave leaves the empty left arm in front. For an object: Present / open → put the object between the jaws → Grip object → support it in your hand → Release to hand → Lower arm. Each button sends one controller approval. Grip and release keep the arm stationary. Never close on a person's hand.")
        let leftButtons = NSStackView(views: [button("Wave left", #selector(leftWave)),
            button("Present / open", #selector(leftPrepare)), button("Grip object", #selector(leftGrip)),
            button("Release to hand", #selector(leftRelease)), button("Lower arm", #selector(leftRelax))])
        leftButtons.spacing = 8
        currentLimit.stringValue = String(UserDefaults.standard.double(forKey: ROBLeftArmTrial.currentLimitKey))
        currentLimit.widthAnchor.constraint(equalToConstant: 75).isActive = true
        currentLimit.target = self; currentLimit.action = #selector(changeCurrentLimit)
        currentLimit.setAccessibilityLabel("Left-arm current jump stop threshold in raw units")
        let currentRow = NSStackView(views: [NSTextField(labelWithString: "Current jump stop:"), currentLimit,
            NSTextField(labelWithString: "raw units; 0 = record only"), button("Show recording", #selector(showLeftRecording)),
            button("Stop + hold", #selector(stop))])
        currentRow.spacing = 8
        let recordingHelp = NSTextField(wrappingLabelWithString: "Current and position are recorded automatically. Set a current jump threshold after reviewing the raw values; it requests Stop + hold on a sample-to-sample jump. This is not a calibrated force limit.")
        recordingHelp.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, leftTitle, leftHelp, leftButtons, currentRow, recordingHelp, state,
            startup, inspectionRow, explanation, commands, buttons, teaching, speechTest, limitation])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = ROBArmSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; view.addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        for label in [explanation, commands, state, limitation, leftHelp, recordingHelp] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBArmRoutineDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBControllerArmApprovalDidChange"), object: nil)
        refresh()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func changeStartup() { UserDefaults.standard.set(startup.state == .on, forKey: ROBArmRoutinePlan.startupDefaultsKey) }
    @objc private func changeInspectionPan() {
        guard !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion, !ROBControllerArmApproval.shared.isPending else { refresh(); return }
        UserDefaults.standard.set(inspectionPan.selectedItem?.representedObject as? NSNumber ?? 0,
                                  forKey: ROBArmRoutinePlan.inspectionPanDefaultsKey)
    }
    @objc private func refresh() {
        state.stringValue = ROBArmRoutineCoordinator.shared.status
        inspectionPan.selectItem(at: [0.0, -10, 10].firstIndex(of: ROBArmRoutinePlan.inspectionPanDegrees()) ?? 0)
        inspectionPan.isEnabled = !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion && !ROBControllerArmApproval.shared.isPending
        currentLimit.isEnabled = inspectionPan.isEnabled
    }
    @objc private func changeCurrentLimit() {
        guard currentLimit.isEnabled, let value = Double(currentLimit.stringValue), value.isFinite, value >= 0 else {
            currentLimit.stringValue = String(UserDefaults.standard.double(forKey: ROBLeftArmTrial.currentLimitKey)); return
        }
        UserDefaults.standard.set(value, forKey: ROBLeftArmTrial.currentLimitKey)
    }
    @objc private func leftWave() { run("left_wave") }
    @objc private func leftPrepare() { run("left_prepare") }
    @objc private func leftGrip() { run("left_grip") }
    @objc private func leftRelease() { run("left_release") }
    @objc private func leftRelax() { run("left_relax") }
    @objc private func showLeftRecording() {
        let path = ROBLeftArmTrial.shared.lastRecordingPath
        if !path.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    @objc private func runStartup() { run("startup") }
    @objc private func prepareArms() { run("prepare") }
    @objc private func relax() { run("relax") }
    @objc private func teach() { run("teach") }
    @objc private func replay() { run("replay") }
    @objc private func wave() { run("wave") }
    @objc private func testArmSpeech() { ROBArmFeedbackAlerts.shared.testSpeech() }
    @objc private func rehearsal() { ROBShowMotionCoordinator.shared.showControls(self) }
    @objc private func stop() {
        ROBArmRoutineCoordinator.shared.cancel(reason: "Stop requested in Arms settings")
        _ = ROBAmberGestureExecutor.shared.cancelCurrentGesture(reason: "Stop requested in Arms settings")
        _ = ROBAmberGestureExecutor.shared.requestPriorityHold()
    }
    private func run(_ command: String) {
        view.window?.makeFirstResponder(nil)
        changeCurrentLimit()
        ROBArmRoutineCoordinator.shared.performCommand(command, target: "") { [weak self] result in
            self?.state.stringValue = result["detail"] as? String ?? "Arm routine ended"
        }
    }
}

private final class ROBArmSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
