import AppKit

/// Persistent robot behavior belongs here. Changing trials and their parameters
/// live in the Testing Sandbox rather than growing the preferences window.
@objcMembers final class ROBArmRoutineSettingsViewController: NSViewController {
    private let startup = NSButton(checkboxWithTitle: "Offer the arm startup route", target: nil, action: nil)
    private let gripperStartup = NSButton(checkboxWithTitle: "Calibrate empty grippers after connecting", target: nil, action: nil)
    private let sessionOnWake = NSButton(checkboxWithTitle: "Offer one arm session at launch / wake", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: "")
    private let inspectionPan = NSPopUpButton(frame: .zero, pullsDown: false)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 580))
        let title = NSTextField(labelWithString: "Arms and grippers")
        title.font = .boldSystemFont(ofSize: 20)
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
        let stack = NSStackView(views: [title, gripperStartup, gripperHelp, sessionOnWake, startup,
                                       inspectionRow, behaviorHelp, sandbox, sandboxHelp, state, stop])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])
        for label in [gripperHelp, behaviorHelp, sandboxHelp, state] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBArmRoutineDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBControllerArmApprovalDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .ROBGripperStartupCalibrationDidChange, object: nil)
        refresh()
    }
    @objc private func changeStartup() { UserDefaults.standard.set(startup.state == .on, forKey: ROBArmRoutinePlan.startupDefaultsKey) }
    @objc private func changeGripperStartup() { ROBGripperStartupCalibration.enabled = gripperStartup.state == .on }
    @objc private func changeSessionOnWake() { UserDefaults.standard.set(sessionOnWake.state == .on, forKey: ROBArmRoutinePlan.sessionOnWakeKey) }
    @objc private func changeInspectionPan() {
        guard inspectionPan.isEnabled else { refresh(); return }
        UserDefaults.standard.set(inspectionPan.selectedItem?.representedObject as? NSNumber ?? 0,
                                  forKey: ROBArmRoutinePlan.inspectionPanDefaultsKey)
    }
    @objc private func refresh() {
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
        ROBArmRoutineCoordinator.shared.cancel(reason: "Stop requested in Arms settings")
        _ = ROBAmberGestureExecutor.shared.cancelCurrentGesture(reason: "Stop requested in Arms settings")
        _ = ROBAmberGestureExecutor.shared.requestPriorityHold()
    }
}
