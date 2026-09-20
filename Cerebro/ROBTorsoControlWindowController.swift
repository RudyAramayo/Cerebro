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
    private let source = NSSegmentedControl(labels: ["Rehearsal", "Live camera"], trackingMode: .selectOne, target: nil, action: nil)
    private let headingView = ROBTorsoHeadingView()
    private let observation = NSTextField(labelWithString: "—")
    private let velocity = NSTextField(labelWithString: "0.0°/s")
    private let sourceDetail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let motor = NSTextField(wrappingLabelWithString: "")
    private let heading = NSTextField(string: "0")
    private let dial = NSSlider(value: 0, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let lever = ROBTorsoVelocitySlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let maximumSpeed = NSSlider(value: 8, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let speedLabel = NSTextField(labelWithString: "8°/s maximum")
    private let armButton = NSButton(title: "Arm rehearsal", target: nil, action: nil)
    private let turnButton = NSButton(title: "Turn to heading", target: nil, action: nil)
    private var selectedHeading = 0.0

    init(center: ROBTorsoControlCenter) {
        self.center = center
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
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
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22)])

        stack.addArrangedSubview(label("Turn naturally. Let vision locate ROB.", size: 22, bold: true))
        source.selectedSegment = 0; source.target = self; source.action = #selector(sourceChanged)
        source.setAccessibilityIdentifier("ROB.Torso.Source")
        stack.addArrangedSubview(source)

        headingView.translatesAutoresizingMaskIntoConstraints = false
        headingView.widthAnchor.constraint(equalToConstant: 244).isActive = true
        headingView.heightAnchor.constraint(equalToConstant: 222).isActive = true
        let readouts = NSStackView(); readouts.orientation = .vertical; readouts.alignment = .leading; readouts.spacing = 10
        readouts.addArrangedSubview(label("Observed heading", bold: true))
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

        stack.addArrangedSubview(label("Turn speed — hold and slide; release to slow to a stop", bold: true))
        lever.target = self; lever.action = #selector(rateChanged); lever.isContinuous = true
        lever.numberOfTickMarks = 3; lever.allowsTickMarkValuesOnly = false
        lever.setAccessibilityIdentifier("ROB.Torso.Velocity")
        lever.widthAnchor.constraint(equalToConstant: 650).isActive = true
        stack.addArrangedSubview(lever)
        maximumSpeed.target = self; maximumSpeed.action = #selector(speedChanged); maximumSpeed.isContinuous = false
        maximumSpeed.widthAnchor.constraint(equalToConstant: 270).isActive = true
        stack.addArrangedSubview(row([label("Speed limit"), maximumSpeed, speedLabel]))

        armButton.target = self; armButton.action = #selector(arm)
        armButton.setAccessibilityIdentifier("ROB.Torso.Arm")
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopNow)); stop.keyEquivalent = "\u{1b}"
        let reobserve = NSButton(title: "Refresh camera estimate", target: self, action: #selector(reobserve))
        stack.addArrangedSubview(row([armButton, stop, reobserve]))
        status.font = .systemFont(ofSize: 13, weight: .medium); status.preferredMaxLayoutWidth = 660
        status.setAccessibilityIdentifier("ROB.Torso.Status"); stack.addArrangedSubview(status)
        motor.font = .systemFont(ofSize: 11); motor.textColor = .secondaryLabelColor; motor.preferredMaxLayoutWidth = 660
        stack.addArrangedSubview(motor)
    }

    @objc private func sourceChanged() { center.setLiveCamera(source.selectedSegment == 1) }
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
    }
    @objc private func turn() { headingChanged(); center.turnToHeading(selectedHeading) }
    @objc private func rateChanged() { center.setLever(lever.doubleValue, held: lever.isHeld) }
    @objc private func speedChanged() { center.setMaximumSpeed(maximumSpeed.doubleValue) }
    @objc private func arm() { center.isArmed ? center.stop() : center.arm() }
    @objc private func stopNow() { lever.doubleValue = 0; center.stop() }
    @objc private func reobserve() { center.reobserve() }

    @objc private func refresh() {
        observation.stringValue = center.observedHeading.isFinite ? String(format: "%.1f°", center.observedHeading) : "Unconfirmed"
        velocity.stringValue = String(format: "%+.2f°/s", center.commandedVelocity)
        sourceDetail.stringValue = center.visionDetail
        status.stringValue = center.status
        motor.stringValue = center.hardwareDetail + (center.usesLiveCamera ? " • 36,800 pulses/turn uses the existing ROB scale; validate before increasing speed." : " • Circular headings wrap through 360°. No homing move.")
        armButton.title = center.isArmed ? "Disarm" : (center.usesLiveCamera ? "Arm torso" : "Arm rehearsal")
        armButton.isEnabled = center.isArmed || center.canArm
        turnButton.isEnabled = center.isArmed
        lever.isEnabled = center.isArmed
        headingView.observed = center.observedHeading; headingView.live = center.usesLiveCamera
        speedLabel.stringValue = String(format: "%.1f°/s maximum", center.maximumSpeed)
        source.selectedSegment = center.usesLiveCamera ? 1 : 0
    }

    func windowWillClose(_ notification: Notification) { center.closeControls() }
}
