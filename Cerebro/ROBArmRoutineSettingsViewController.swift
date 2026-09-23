import AppKit

@objcMembers final class ROBArmRoutineSettingsViewController: NSViewController {
    private let startup = NSButton(checkboxWithTitle: "Calibrate arms on startup", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 580))
        let title = NSTextField(labelWithString: "Arms and grippers")
        title.font = .boldSystemFont(ofSize: 20)
        startup.state = UserDefaults.standard.bool(forKey: ROBArmRoutinePlan.startupDefaultsKey) ? .on : .off
        startup.target = self; startup.action = #selector(changeStartup)
        let explanation = NSTextField(wrappingLabelWithString:
            "On launch or wake, request approval on Vision Pro or iPhone, then check the main face camera, bring both hanging arms into view, calibrate both empty grippers and open them. The arms stay ready in front. Planned arm travel takes about 21 seconds plus camera and gripper checks; automatic timing has not been verified on hardware.")
        let commands = NSTextField(wrappingLabelWithString:
            "Say or type ‘relax’ to lower the arms gently and turn off holding torque. ‘Grab this’ or ‘hold this’ brings the arms forward and attempts a gentle close when the camera sees the object between a gripper’s jaws. These commands are available without enabling startup calibration. Each complete operation needs one controller approval. Stop + hold is immediate.")
        let limitation = NSTextField(wrappingLabelWithString:
            "‘Copy my pose’ records five seconds from the main camera. ‘Replay that movement’ performs a bounded symmetric rendition; ‘wave’ uses a small front-arm greeting. Full human pose copying and general reaching need validated geometry. Gripper acceptance is not force feedback.")
        limitation.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [button("Run startup now", #selector(runStartup)),
            button("Prepare to grab", #selector(prepareArms)), button("Relax arms", #selector(relax)),
            button("Stop + hold", #selector(stop))])
        buttons.spacing = 10
        let teaching = NSStackView(views: [button("Motion rehearsal…", #selector(rehearsal)), button("Record body demonstration", #selector(teach)),
            button("Replay last", #selector(replay)), button("Front-arm greeting", #selector(wave))])
        teaching.spacing = 10
        let stack = NSStackView(views: [title, startup, explanation, commands, buttons, teaching, state, limitation])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
        ])
        for label in [explanation, commands, state, limitation] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBArmRoutineDidChange"), object: nil)
        refresh()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func changeStartup() { UserDefaults.standard.set(startup.state == .on, forKey: ROBArmRoutinePlan.startupDefaultsKey) }
    @objc private func refresh() { state.stringValue = ROBArmRoutineCoordinator.shared.status }
    @objc private func runStartup() { run("startup") }
    @objc private func prepareArms() { run("prepare") }
    @objc private func relax() { run("relax") }
    @objc private func teach() { run("teach") }
    @objc private func replay() { run("replay") }
    @objc private func wave() { run("wave") }
    @objc private func rehearsal() { ROBShowMotionCoordinator.shared.showControls(self) }
    @objc private func stop() {
        ROBArmRoutineCoordinator.shared.cancel(reason: "Stop requested in Arms settings")
        _ = ROBAmberGestureExecutor.shared.cancelCurrentGesture(reason: "Stop requested in Arms settings")
        _ = ROBAmberGestureExecutor.shared.requestPriorityHold()
    }
    private func run(_ command: String) {
        ROBArmRoutineCoordinator.shared.performCommand(command, target: "") { [weak self] result in
            self?.state.stringValue = result["detail"] as? String ?? "Arm routine ended"
        }
    }
}
