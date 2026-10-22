import AppKit

@objcMembers final class ROBArmRoutineSettingsViewController: NSViewController {
    private let startup = NSButton(checkboxWithTitle: "Calibrate arms on startup", target: nil, action: nil)
    private let sessionOnWake = NSButton(checkboxWithTitle: "Offer one arm session at launch / wake", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: "")
    private let inspectionPan = NSPopUpButton(frame: .zero, pullsDown: false)
    private let currentLimit = NSTextField(string: "0")
    private let cycleContinue = NSButton(title: "Continue object cycle", target: nil, action: nil)
    private var displayedCycleStage = ""
    private var observingLeftOperation = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 580))
        let title = NSTextField(labelWithString: "Arms and grippers")
        title.font = .boldSystemFont(ofSize: 20)
        startup.state = UserDefaults.standard.bool(forKey: ROBArmRoutinePlan.startupDefaultsKey) ? .on : .off
        startup.target = self; startup.action = #selector(changeStartup)
        sessionOnWake.state = ROBArmRoutinePlan.sessionOnWake ? .on : .off
        sessionOnWake.target = self; sessionOnWake.action = #selector(changeSessionOnWake)
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
            "Say or type ‘relax’ to lower the arms gently and turn off holding torque. ‘Grab this’ or ‘hold this’ brings the arms forward and attempts a gentle close when the camera sees the object between a gripper’s jaws. These commands are available without enabling startup calibration. Task motions need one spoken or controller authorization; a rehearsal session covers its included left-arm routines. Returning empty arms to hanging needs no approval. Stop + hold is immediate.")
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
        let workspaceHelp = NSTextField(wrappingLabelWithString: "Recycle can scans for an empty Coke can and an open orange bucket with an offline object detector, asks a nearby person to point if needed, then attempts a locally planned pick-and-place under ONE spoken or controller authorization. Search only and Check hanging move only the neck camera and need no arm approval or gateway connection. No cloud conversation is required after the vision model is installed. Camera-to-arm geometry is provisional; supervise the attempt and keep Stop + hold ready.")
        let workspaceButtons = NSStackView(views: [button("Start 15-minute left-arm session", #selector(startArmSession)),
            button("End arm session", #selector(endArmSession)), button("Recycle can → orange bucket", #selector(recycleCan)),
            button("Search only", #selector(searchWorkspace)), button("Preview can grab", #selector(previewCan)), button("Check hanging", #selector(checkHanging))])
        workspaceButtons.orientation = .vertical; workspaceButtons.alignment = .leading; workspaceButtons.spacing = 6
        let leftHelp = NSTextField(wrappingLabelWithString: "Grip and return uses one controller approval for the complete left-arm cycle: raise and open empty jaws, grip at intensity 2, release into a supporting hand, then lower the empty arm. Continue when the object is placed with fingers clear, when the receiver supports it, and when it is clear of the jaws. These readiness steps stay inside the same approval. Keep the controller open; Stop + hold remains available. Wave and Ghost gestures open the blue preview. Never grip a person's hand.")
        let cycleStart = button("Grip and return · one approval", #selector(leftObjectCycle))
        cycleStart.identifier = NSUserInterfaceItemIdentifier("left-cycle-start")
        let leftButtons = NSStackView(views: [cycleStart, button("Wave left", #selector(leftWave)), button("Ghost gestures…", #selector(openGhost))])
        let individualButtons = NSStackView(views: [button("Present / open", #selector(leftPrepare)), button("Grip object", #selector(leftGrip)),
            button("Release to hand", #selector(leftRelease)), button("Lower arm", #selector(leftRelax))])
        leftButtons.spacing = 8
        individualButtons.spacing = 8
        cycleContinue.target = self; cycleContinue.action = #selector(continueObjectCycle)
        cycleContinue.identifier = NSUserInterfaceItemIdentifier("left-cycle-continue")
        cycleContinue.isHidden = true
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
        let stack = NSStackView(views: [title, sessionOnWake, workspaceHelp, workspaceButtons, state, leftTitle, leftHelp, leftButtons, cycleContinue, individualButtons, currentRow, recordingHelp,
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
        for label in [explanation, commands, state, limitation, leftHelp, recordingHelp, workspaceHelp] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBArmRoutineDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBControllerArmApprovalDidChange"), object: nil)
        refresh()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func changeStartup() { UserDefaults.standard.set(startup.state == .on, forKey: ROBArmRoutinePlan.startupDefaultsKey) }
    @objc private func changeSessionOnWake() { UserDefaults.standard.set(sessionOnWake.state == .on, forKey: ROBArmRoutinePlan.sessionOnWakeKey) }
    @objc private func changeInspectionPan() {
        guard !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion, !ROBControllerArmApproval.shared.isPending else { refresh(); return }
        UserDefaults.standard.set(inspectionPan.selectedItem?.representedObject as? NSNumber ?? 0,
                                  forKey: ROBArmRoutinePlan.inspectionPanDefaultsKey)
    }
    @objc private func refresh() {
        let left = ROBLeftArmTrial.shared
        if left.isRunning {
            state.stringValue = left.status
        } else if ROBControllerArmApproval.shared.isPending {
            state.stringValue = ROBControllerArmApproval.shared.status
        } else {
            state.stringValue = left.isRunning || observingLeftOperation ? left.status : ROBArmRoutineCoordinator.shared.status
        }
        state.stringValue += "\n" + ROBControllerArmApproval.shared.armSessionDetail
        displayedCycleStage = left.interactionStage
        switch displayedCycleStage {
        case "object_placed": cycleContinue.title = "Object placed; fingers clear → Grip"
        case "receiver_supporting": cycleContinue.title = "Hand supporting object → Release"
        case "object_clear": cycleContinue.title = "Object clear of jaws → Lower empty arm"
        default: cycleContinue.title = "Continue object cycle"
        }
        cycleContinue.isHidden = displayedCycleStage.isEmpty
        cycleContinue.isEnabled = left.isRunning && !displayedCycleStage.isEmpty
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
    @objc private func leftWave() { showGhost("wave") }
    @objc private func openGhost() { showGhost("center") }
    private func showGhost(_ preset: String) {
        observingLeftOperation = true
        NotificationCenter.default.post(name: Notification.Name("ROBShowControllerInputDiagnostics"), object: self,
            userInfo: ["ghostPreset": preset])
    }
    @objc private func leftPrepare() { run("left_prepare") }
    @objc private func leftObjectCycle() { run("left_object_cycle") }
    @objc private func startArmSession() { run("arm_session") }
    @objc private func endArmSession() { run("end_arm_session") }
    @objc private func recycleCan() { run("left_recycle_can") }
    @objc private func searchWorkspace() { run("left_search_workspace") }
    @objc private func previewCan() { showGhost("can") }
    @objc private func checkHanging() { run("left_check_hanging") }
    @objc private func continueObjectCycle() {
        _ = ROBLeftArmTrial.shared.continueOperation(stage: displayedCycleStage)
        refresh()
    }
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
        observingLeftOperation = ROBLeftArmTrial.commands.contains(command)
        ROBArmRoutineCoordinator.shared.performCommand(command, target: "") { [weak self] result in
            self?.refresh()
        }
    }
}

private final class ROBArmSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
