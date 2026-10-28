import Cocoa

/// The old debug slider now represents velocity. Mouse-up always returns to
/// zero, including a release outside the control. Keyboard nudges cannot latch
/// a motor velocity; keyboard users can use the separate heading control.
@objcMembers final class ROBTorsoVelocitySlider: NSSlider {
    private(set) var isHeld = false
    override func mouseDown(with event: NSEvent) {
        isHeld = true
        super.mouseDown(with: event)
        isHeld = false; doubleValue = 0
        sendAction(action, to: target)
    }
    override func keyDown(with event: NSEvent) {
        isHeld = false; doubleValue = 0
        sendAction(action, to: target)
    }
}

private final class ROBTorsoHeadingView: NSView {
    var observed = Double.nan { didSet { needsDisplay = true } }
    var target = 0.0 { didSet { needsDisplay = true } }
    var live = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.40
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                             width: 2 * radius, height: 2 * radius))
        NSColor.separatorColor.setStroke(); ring.lineWidth = 2; ring.stroke()
        for degree in stride(from: 0, to: 360, by: 30) {
            let r = Double(degree) * .pi / 180
            let line = NSBezierPath()
            line.move(to: NSPoint(x: center.x - sin(r) * (radius - 7), y: center.y + cos(r) * (radius - 7)))
            line.line(to: NSPoint(x: center.x - sin(r) * radius, y: center.y + cos(r) * radius))
            line.stroke()
        }
        func needle(_ degrees: Double, _ color: NSColor, _ length: Double, _ width: Double) {
            guard degrees.isFinite else { return }
            let r = degrees * .pi / 180
            let path = NSBezierPath(); path.move(to: center)
            path.line(to: NSPoint(x: center.x - sin(r) * radius * length, y: center.y + cos(r) * radius * length))
            color.setStroke(); path.lineWidth = width; path.lineCapStyle = .round; path.stroke()
        }
        needle(target, .systemOrange, 0.94, 3)
        needle(observed, live ? .systemGreen : .systemCyan, 0.76, 7)
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
        let title = "ROB front · 0°" as NSString
        title.draw(at: NSPoint(x: center.x - 45, y: center.y + radius + 10),
                   withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

final class ROBTorsoControlWindowController: NSWindowController, NSWindowDelegate {
    private let center: ROBTorsoControlCenter
    private let source = NSSegmentedControl(labels: ["Rehearsal", "Live camera", "TIC count estimate"], trackingMode: .selectOne, target: nil, action: nil)
    private let headingView = ROBTorsoHeadingView()
    private let observation = NSTextField(labelWithString: "—")
    private let velocity = NSTextField(labelWithString: "0.0°/s")
    private let sourceDetail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let motor = NSTextField(wrappingLabelWithString: "")
    private let power = NSTextField(wrappingLabelWithString: "")
    private let energizeButton = NSButton(title: "Energize", target: nil, action: nil)
    private let deenergizeButton = NSButton(title: "De-energize", target: nil, action: nil)
    private let heading = NSTextField(string: "0")
    private let counts = NSTextField(string: "92")
    private let countSlider = NSSlider(value: 92, minValue: -8907, maxValue: 9091, target: nil, action: nil)
    private let countRangeLabel = NSTextField(labelWithString: "")
    private let baseReference = NSTextField(string: "0")
    private let referenceButton = NSButton(title: "Set software reference", target: nil, action: nil)
    private let cable = NSTextField(wrappingLabelWithString: "")
    private let unwind = NSButton(title: "Unwind tracked debug turn", target: nil, action: nil)
    private let dial = NSSlider(value: 0, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let lever = ROBTorsoVelocitySlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let maximumSpeed = NSSlider(value: 8, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let speedLabel = NSTextField(labelWithString: "8°/s maximum")
    private let armButton = NSButton(title: "Arm rehearsal", target: nil, action: nil)
    private let turnButton = NSButton(title: "Turn to heading", target: nil, action: nil)
    private var selectedHeading = 0.0

    init(center: ROBTorsoControlCenter) {
        self.center = center
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 830),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Torso Rotation"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        makeContent()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ROBTorsoControlCenter.changed, object: center)
        window.center(); refresh()
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let value = NSTextField(labelWithString: text)
        value.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return value
    }
    private func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let value = NSStackView(views: views); value.orientation = .horizontal
        value.spacing = spacing; value.alignment = .centerY; return value
    }

    private func makeContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22)])

        stack.addArrangedSubview(label("Torso alignment and rotation", size: 22, bold: true))
        source.selectedSegment = 0; source.target = self; source.action = #selector(sourceChanged)
        source.setAccessibilityIdentifier("ROB.Torso.Source")
        stack.addArrangedSubview(source)

        headingView.translatesAutoresizingMaskIntoConstraints = false
        headingView.widthAnchor.constraint(equalToConstant: 210).isActive = true
        headingView.heightAnchor.constraint(equalToConstant: 170).isActive = true
        let readouts = NSStackView(); readouts.orientation = .vertical; readouts.alignment = .leading; readouts.spacing = 10
        readouts.addArrangedSubview(label("Torso heading · positive is ROB-left", bold: true))
        observation.font = .monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        observation.setAccessibilityIdentifier("ROB.Torso.ObservedHeading")
        readouts.addArrangedSubview(observation)
        sourceDetail.font = .systemFont(ofSize: 12); sourceDetail.textColor = .secondaryLabelColor
        sourceDetail.preferredMaxLayoutWidth = 360; readouts.addArrangedSubview(sourceDetail)
        readouts.addArrangedSubview(label("Requested speed", bold: true))
        velocity.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        readouts.addArrangedSubview(velocity)
        readouts.addArrangedSubview(label("Orange: destination  •  Blue/green: observation", size: 11))
        stack.addArrangedSubview(row([headingView, readouts], spacing: 26))

        dial.sliderType = .circular; dial.target = self; dial.action = #selector(dialChanged)
        dial.widthAnchor.constraint(equalToConstant: 52).isActive = true
        dial.heightAnchor.constraint(equalToConstant: 52).isActive = true
        dial.setAccessibilityLabel("Destination heading, circular")
        heading.alignment = .right; heading.target = self; heading.action = #selector(headingChanged)
        heading.widthAnchor.constraint(equalToConstant: 72).isActive = true
        heading.setAccessibilityIdentifier("ROB.Torso.TargetHeading")
        turnButton.target = self; turnButton.action = #selector(turn)
        stack.addArrangedSubview(row([label("Destination", bold: true), dial, heading, label("degrees"), turnButton]))

        counts.widthAnchor.constraint(equalToConstant: 90).isActive = true
        counts.target = self; counts.action = #selector(countChanged)
        counts.setAccessibilityIdentifier("ROB.Torso.TargetCount")
        countSlider.widthAnchor.constraint(equalToConstant: 310).isActive = true
        countSlider.target = self; countSlider.action = #selector(countSliderChanged)
        countSlider.isContinuous = true
        countSlider.setAccessibilityIdentifier("ROB.Torso.CalibratedCountRange")
        countSlider.setAccessibilityLabel("Destination TIC count preview")
        countSlider.toolTip = "Select a destination; the count and degree fields update while dragging. Turn to heading starts the move."
        stack.addArrangedSubview(row([label("Count target"), counts, countSlider]))
        countRangeLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(countRangeLabel)
        stack.addArrangedSubview(label("Count slider previews a destination. Select Turn to heading to move after arming rotation.", size: 11))
        baseReference.widthAnchor.constraint(equalToConstant: 65).isActive = true
        baseReference.setAccessibilityIdentifier("ROB.Torso.SoftwareBaseReference")
        referenceButton.target = self; referenceButton.action = #selector(setReference)
        stack.addArrangedSubview(row([label("Physically observed base-relative angle"), baseReference, label("°"), referenceButton]))
        stack.addArrangedSubview(label("Reference updates the software offset only. Use 0° when torso faces the tread base front.", size: 11))

        stack.addArrangedSubview(label("Turn speed — hold and slide; release to slow to a stop", bold: true))
        lever.target = self; lever.action = #selector(rateChanged); lever.isContinuous = true
        lever.numberOfTickMarks = 3; lever.allowsTickMarkValuesOnly = false
        lever.setAccessibilityIdentifier("ROB.Torso.Velocity")
        lever.widthAnchor.constraint(equalToConstant: 650).isActive = true
        stack.addArrangedSubview(lever)
        maximumSpeed.target = self; maximumSpeed.action = #selector(speedChanged); maximumSpeed.isContinuous = false
        maximumSpeed.widthAnchor.constraint(equalToConstant: 270).isActive = true
        stack.addArrangedSubview(row([label("Speed limit"), maximumSpeed, speedLabel]))

        energizeButton.target = self; energizeButton.action = #selector(energize)
        energizeButton.setAccessibilityIdentifier("ROB.Torso.Energize")
        energizeButton.toolTip = "Power the stepper at zero speed. Rotation is armed separately once both arms clear the treads."
        deenergizeButton.target = self; deenergizeButton.action = #selector(deenergize)
        deenergizeButton.setAccessibilityIdentifier("ROB.Torso.Deenergize")
        stack.addArrangedSubview(row([energizeButton, deenergizeButton, label("Energize holds at zero speed", size: 11)]))
        power.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        power.preferredMaxLayoutWidth = 700; power.setAccessibilityIdentifier("ROB.Torso.MotorPower")
        stack.addArrangedSubview(power)

        armButton.target = self; armButton.action = #selector(arm)
        armButton.setAccessibilityIdentifier("ROB.Torso.Arm")
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopNow)); stop.keyEquivalent = "\u{1b}"
        let reobserve = NSButton(title: "Refresh camera estimate", target: self, action: #selector(reobserve))
        stack.addArrangedSubview(row([armButton, stop, reobserve]))
        unwind.target = self; unwind.action = #selector(unwindTurn)
        unwind.setAccessibilityIdentifier("ROB.Torso.Unwind")
        cable.font = .systemFont(ofSize: 11); cable.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(row([unwind, cable]))
        status.font = .systemFont(ofSize: 13, weight: .medium); status.preferredMaxLayoutWidth = 660
        status.setAccessibilityIdentifier("ROB.Torso.Status"); stack.addArrangedSubview(status)
        motor.font = .systemFont(ofSize: 11); motor.textColor = .secondaryLabelColor; motor.preferredMaxLayoutWidth = 660
        stack.addArrangedSubview(motor)
    }

    @objc private func sourceChanged() {
        if source.selectedSegment == 2 { center.setCountEstimate() }
        else { center.setLiveCamera(source.selectedSegment == 1) }
    }
    @objc private func countChanged() {
        guard let value = Double(counts.stringValue), value.isFinite,
              (Double(Int32.min)...Double(Int32.max)).contains(value) else { return }
        selectHeading(center.heading(forCount: value))
    }
    @objc private func countSliderChanged() { selectHeading(center.heading(forCount: countSlider.doubleValue)) }
    @objc private func setReference() {
        guard let value = Double(baseReference.stringValue) else { return }
        center.setSoftwareReference(value); selectHeading(selectedHeading)
    }
    @objc private func unwindTurn() { center.unwindDebugTurn() }
    @objc private func dialChanged() { selectHeading(dial.doubleValue) }
    @objc private func headingChanged() {
        guard let value = Double(heading.stringValue), value.isFinite else { heading.stringValue = String(format: "%.1f", selectedHeading); return }
        selectHeading(value)
    }
    private func selectHeading(_ degrees: Double) {
        selectedHeading = ROBTorsoMotionPolicy.wrap(degrees)
        heading.stringValue = String(format: "%.1f", selectedHeading)
        dial.doubleValue = selectedHeading < 0 ? selectedHeading + 360 : selectedHeading
        headingView.target = selectedHeading
        counts.stringValue = String(format: "%.0f", center.count(forHeading: selectedHeading))
        countSlider.doubleValue = center.count(forHeading: selectedHeading)
    }
    @objc private func turn() { headingChanged(); center.turnToHeading(selectedHeading) }
    @objc private func rateChanged() { center.setLever(lever.doubleValue, held: lever.isHeld) }
    @objc private func speedChanged() { center.setMaximumSpeed(maximumSpeed.doubleValue) }
    @objc private func arm() { center.isArmed ? center.stop() : center.arm() }
    @objc private func energize() { center.energize() }
    @objc private func deenergize() { lever.doubleValue = 0; center.deenergize() }
    @objc private func stopNow() { lever.doubleValue = 0; center.stop() }
    @objc private func reobserve() { center.reobserve() }

    @objc private func refresh() {
        func show(_ field: NSTextField, _ text: String) { if field.stringValue != text { field.stringValue = text } }
        show(observation, center.observedHeading.isFinite ? String(format: "%.1f°", center.observedHeading) : "Unconfirmed")
        show(velocity, String(format: "%+.2f°/s", center.commandedVelocity))
        show(sourceDetail, center.visionDetail)
        show(status, center.usesCountEstimate ? center.status.replacingOccurrences(of: "Camera", with: "Count estimate").replacingOccurrences(of: "camera", with: "count estimate").replacingOccurrences(of: "visually", with: "in controller counts") : center.status)
        show(motor, center.hardwareDetail + " • 35,996 counts/turn. No hardware homing or position reset.")
        show(power, center.motorPowerDetail)
        energizeButton.isEnabled = center.canEnergize
        deenergizeButton.isEnabled = center.usesHardware
        let armTitle = center.isArmed ? "Disarm" : (center.usesHardware ? "Arm torso" : "Arm rehearsal")
        if armButton.title != armTitle { armButton.title = armTitle }
        armButton.isEnabled = center.isArmed || center.canArm
        turnButton.isEnabled = center.isArmed
        lever.isEnabled = center.isArmed
        if !center.isArmed { lever.doubleValue = 0 }
        headingView.observed = center.observedHeading; headingView.live = center.usesLiveCamera
        referenceButton.isEnabled = center.canSetSoftwareReference
        if countSlider.minValue != center.count(forHeading: 90) || countSlider.maxValue != center.count(forHeading: -90) {
            countSlider.minValue = center.count(forHeading: 90)
            countSlider.maxValue = center.count(forHeading: -90)
            selectHeading(selectedHeading)
        }
        show(countRangeLabel, String(format: "Software targets: %.0f left 90° · %.0f front · %.0f right 90° · full rotation supported",
            center.count(forHeading:90),center.countReference,center.count(forHeading:-90)))
        unwind.isEnabled = center.canUnwind
        show(cable, !center.debugCableMode ? "Untethered: unrestricted rotation via slipring" : center.cableTravelDegrees.isFinite ? String(format: "Debug tether: %+.1f° since tracking began. Heading requests prefer unwinding. Earlier cable twist is unknown.", center.cableTravelDegrees) : "Debug tether: turn history unavailable; existing cable twist is unknown.")
        show(speedLabel, String(format: "%.1f°/s maximum", center.maximumSpeed))
        source.selectedSegment = center.usesCountEstimate ? 2 : center.usesLiveCamera ? 1 : 0
    }

    func windowWillClose(_ notification: Notification) { center.closeControls() }
}
