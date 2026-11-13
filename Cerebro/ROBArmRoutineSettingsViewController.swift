import AppKit

private final class ROBArmSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Persistent robot behavior belongs here. Changing trials and their parameters
/// live in the Testing Sandbox rather than growing the preferences window.
@objcMembers final class ROBArmRoutineSettingsViewController: NSViewController {
    private let startup = NSButton(checkboxWithTitle: "Offer the arm startup route", target: nil, action: nil)
    private let passiveStartup = NSButton(checkboxWithTitle: "Passive arm and gripper startup", target: nil, action: nil)
    private let neckStartup = NSButton(checkboxWithTitle: "Run saved neck startup sequence after connecting", target: nil, action: nil)
    private let laserStartup = NSButton(checkboxWithTitle: "Run saved laser mount startup after connecting", target: nil, action: nil)
    private let laserOscillate = NSButton(checkboxWithTitle: "Oscillate laser pan before parking", target: nil, action: nil)
    private var laserFields: [NSTextField] = []
    private let laserResult = NSTextField(wrappingLabelWithString: "")
    private let gripperStartup = NSButton(checkboxWithTitle: "Calibrate empty grippers after connecting", target: nil, action: nil)
    private let sessionOnWake = NSButton(checkboxWithTitle: "Offer one arm session at launch / wake", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: "")
    private let inspectionPan = NSPopUpButton(frame: .zero, pullsDown: false)
    private let treadAcceleration = NSPopUpButton(frame: .zero, pullsDown: false)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 680))
        let title = NSTextField(labelWithString: "Arms and motion")
        title.font = .boldSystemFont(ofSize: 20)
        passiveStartup.state = UserDefaults.standard.bool(forKey: "ROBPassiveHardwareStartup") ? .on : .off
        passiveStartup.target = self; passiveStartup.action = #selector(changePassiveStartup)
        neckStartup.state = ROBServoControlStore.automaticStartupEnabled ? .on : .off
        neckStartup.target = self; neckStartup.action = #selector(changeNeckStartup)
        let neckHelp = NSTextField(wrappingLabelWithString:
            "The neck uses your saved three-phase sequence at launch and reconnect, independently of passive arm and gripper startup. Turn this off before servicing the neck. Changing this setting does not move or stop servos.")
        neckHelp.textColor = .secondaryLabelColor
        laserStartup.state = ROBBubbleRuntime.shared.automaticMountStartupEnabled ? .on : .off
        laserStartup.target = self; laserStartup.action = #selector(changeLaserStartup)
        let laserHelp = NSTextField(wrappingLabelWithString:
            "Laser startup centers pan, sweeps right/left twice, parks at the saved pan target, then parks tilt. Tilt stays untouched throughout pan travel. Targets are commanded values, not measured positions. Confirm directions and adequate settling time on the mount. Disable automatic startup before servicing. Saving settings does not move servos.")
        laserHelp.textColor = .secondaryLabelColor
        let animation = ROBBubbleRuntime.shared.startupAnimation ?? ROBLaserStartupAnimation()
        laserOscillate.state = animation.oscillate ? .on : .off
        let laserEditor = NSStackView()
        laserEditor.orientation = .vertical; laserEditor.alignment = .leading; laserEditor.spacing = 8
        laserEditor.addArrangedSubview(laserOscillate)
        let values = [String(animation.centerPan), String(animation.frontRightPan), String(animation.frontLeftPan),
                      String(animation.cycles), String(animation.panSettleSeconds), String(animation.tiltSettleSeconds)]
        let labels = ["Center pan", "Front-right pan", "Front-left pan", "Right/left cycles (1–4)",
                      "Settle after each pan target (seconds)", "Settle after tilt park (seconds)"]
        for (label, value) in zip(labels, values) {
            let field = NSTextField(string: value)
            field.setAccessibilityLabel("Laser startup " + label)
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            laserFields.append(field)
            let row = NSStackView(views: [NSTextField(labelWithString: label + ":"), field])
            row.spacing = 10; laserEditor.addArrangedSubview(row)
        }
        let laserBounds = NSTextField(wrappingLabelWithString: "Pan targets: 4000–8000; settling: 0.75–10 seconds. Defaults: 6000 / 7000 / 5000, two cycles, two seconds per target. With oscillation off, startup still parks pan before tilt. Final park values remain your saved mount calibration.")
        laserBounds.textColor = .secondaryLabelColor
        laserEditor.addArrangedSubview(laserBounds)
        laserEditor.addArrangedSubview(NSButton(title: "Save laser animation", target: self, action: #selector(saveLaserAnimation)))
        laserEditor.addArrangedSubview(laserResult)
        if ROBBubbleRuntime.shared.startupAnimation == nil { laserResult.stringValue = "Saved animation is invalid. Review and save to repair it; startup is blocked." }
        startup.state = UserDefaults.standard.bool(forKey: ROBArmRoutinePlan.startupDefaultsKey) ? .on : .off
        startup.target = self; startup.action = #selector(changeStartup)
        gripperStartup.state = ROBGripperStartupCalibration.enabled ? .on : .off
        gripperStartup.target = self; gripperStartup.action = #selector(changeGripperStartup)
        sessionOnWake.state = ROBArmRoutinePlan.sessionOnWake ? .on : .off
        sessionOnWake.target = self; sessionOnWake.action = #selector(changeSessionOnWake)
        for (title, degrees) in [("Center", 0), ("10° right", -10), ("10° left", 10)] {
            inspectionPan.addItem(withTitle: title)
            inspectionPan.lastItem?.representedObject = NSNumber(value: degrees)
        }
        inspectionPan.target = self; inspectionPan.action = #selector(changeInspectionPan)
        inspectionPan.setAccessibilityLabel("Arm inspection camera pan")
        let inspectionRow = NSStackView(views: [NSTextField(labelWithString: "Arm inspection camera pan:"), inspectionPan])
        inspectionRow.spacing = 10
        treadAcceleration.addItems(withTitles: ROBTreadMotionRamp.modeTitles)
        treadAcceleration.target = self; treadAcceleration.action = #selector(changeTreadAcceleration)
        treadAcceleration.setAccessibilityLabel("Local tread acceleration")
        let treadRow = NSStackView(views: [NSTextField(labelWithString: "Local tread acceleration:"), treadAcceleration])
        treadRow.spacing = 10
        let treadHelp = NSTextField(wrappingLabelWithString:
            "Gentle reaches full demand in 2.4 seconds, Medium in 1.2, Aggressive in 0.6. Lower speed limits are reached proportionally sooner. Release ramps down; Stop treads and Escape stop immediately.")
        treadHelp.textColor = .secondaryLabelColor
        let gripperHelp = NSTextField(wrappingLabelWithString:
            "Calibrate stationary, empty grippers after Amber connects, without raising the arms. Keep the jaws clear at startup. Stop, sleep or connection loss cancels calibration.")
        let behaviorHelp = NSTextField(wrappingLabelWithString:
            "Task motion uses one spoken or controller authorization for the complete operation. A supervised session covers its included routines. Returning empty arms to hanging needs no new approval. Say ‘relax’ to request an empty-arm return and turn off holding torque. Left-arm trial returns use fresh workspace geometry and a dynamically checked path; paired-arm routes retain their existing checks.")
        let sandboxHelp = NSTextField(wrappingLabelWithString:
            "Open Testing Sandbox for individual trials, custom parameters, motion previews and recordings.")
        for label in [gripperHelp, behaviorHelp, sandboxHelp] { label.textColor = .secondaryLabelColor }
        let sandbox = NSButton(title: "Open Testing Sandbox…", target: self, action: #selector(openSandbox))
        sandbox.identifier = NSUserInterfaceItemIdentifier("arms-open-testing-sandbox")
        let stop = NSButton(title: "Stop + hold", target: self, action: #selector(stop))
        stop.bezelColor = .systemRed
        state.isSelectable = true
        let stack = NSStackView(views: [title, neckStartup, neckHelp, laserStartup, laserHelp, laserEditor, passiveStartup, gripperStartup, gripperHelp, sessionOnWake, startup,
                                       inspectionRow, treadRow, treadHelp, behaviorHelp, sandbox, sandboxHelp, state, stop])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = ROBArmSettingsDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        view.addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        laserEditor.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        laserBounds.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        laserResult.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for label in [neckHelp, laserHelp, gripperHelp, treadHelp, behaviorHelp, sandboxHelp, state] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ROBTreadMotionRamp.settingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBArmRoutineDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBControllerArmApprovalDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .ROBGripperStartupCalibrationDidChange, object: nil)
        refresh()
    }
    @objc private func changeStartup() { UserDefaults.standard.set(startup.state == .on, forKey: ROBArmRoutinePlan.startupDefaultsKey) }
    @objc private func changePassiveStartup() { UserDefaults.standard.set(passiveStartup.state == .on, forKey: "ROBPassiveHardwareStartup") }
    @objc private func changeNeckStartup() { ROBServoControlStore.automaticStartupEnabled = neckStartup.state == .on }
    @objc private func changeLaserStartup() { ROBBubbleRuntime.shared.automaticMountStartupEnabled = laserStartup.state == .on }
    @objc private func saveLaserAnimation() {
        guard laserFields.count == 6,
              let center = Int(laserFields[0].stringValue), let right = Int(laserFields[1].stringValue),
              let left = Int(laserFields[2].stringValue), let cycles = Int(laserFields[3].stringValue),
              let panWait = Double(laserFields[4].stringValue), let tiltWait = Double(laserFields[5].stringValue) else {
            laserResult.stringValue = "Enter valid numbers in every laser animation field."; return
        }
        var animation = ROBLaserStartupAnimation()
        animation.oscillate = laserOscillate.state == .on
        animation.centerPan = center; animation.frontRightPan = right; animation.frontLeftPan = left
        animation.cycles = cycles; animation.panSettleSeconds = panWait; animation.tiltSettleSeconds = tiltWait
        laserResult.stringValue = ROBBubbleRuntime.shared.saveStartupAnimation(animation)
            ? "Saved for the next startup. No servo commands sent."
            : "Not saved: targets must be 4000–8000, cycles 1–4, settling 0.75–10 seconds."
    }
    @objc private func changeTreadAcceleration() { ROBTreadMotionRamp.selectedMode = treadAcceleration.indexOfSelectedItem }
    @objc private func changeGripperStartup() { ROBGripperStartupCalibration.enabled = gripperStartup.state == .on }
    @objc private func changeSessionOnWake() { UserDefaults.standard.set(sessionOnWake.state == .on, forKey: ROBArmRoutinePlan.sessionOnWakeKey) }
    @objc private func changeInspectionPan() {
        guard inspectionPan.isEnabled else { refresh(); return }
        UserDefaults.standard.set(inspectionPan.selectedItem?.representedObject as? NSNumber ?? 0,
                                  forKey: ROBArmRoutinePlan.inspectionPanDefaultsKey)
    }
    @objc private func refresh() {
        treadAcceleration.selectItem(at: ROBTreadMotionRamp.selectedMode)
        if ROBControllerArmApproval.shared.isPending { state.stringValue = ROBControllerArmApproval.shared.status }
        else if ROBGripperStartupCalibration.shared.isRunning { state.stringValue = ROBGripperStartupCalibration.shared.status }
        else { state.stringValue = ROBArmRoutineCoordinator.shared.status }
        state.stringValue += "\n" + ROBControllerArmApproval.shared.armSessionDetail
        inspectionPan.selectItem(at: [0.0, -10, 10].firstIndex(of: ROBArmRoutinePlan.inspectionPanDegrees()) ?? 0)
        inspectionPan.isEnabled = !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion && !ROBControllerArmApproval.shared.isPending
        gripperStartup.state = ROBGripperStartupCalibration.enabled ? .on : .off
    }
    @objc private func openSandbox() { ROBTestingSandboxWindowController.shared.showWindow(self) }
    @objc private func stop() {
        ROBBubbleRuntime.shared.stop(reason: "Stop requested in Arms settings")
        ROBArmRoutineCoordinator.shared.cancel(reason: "Stop requested in Arms settings")
        _ = ROBAmberGestureExecutor.shared.cancelCurrentGesture(reason: "Stop requested in Arms settings")
        _ = ROBAmberGestureExecutor.shared.requestPriorityHold()
    }
}
