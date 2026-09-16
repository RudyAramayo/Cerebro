import AppKit

/// A passive preview. Opening this window never produces a control command.
@MainActor
final class ROBControlLatencyWindowController: NSWindowController, NSWindowDelegate {
    private let diagnostics: ROBControlLatencyDiagnostics
    private let networkSummary: @MainActor () -> String
    private var refreshTimer: Timer?
    private let inputView = ROBControlInputPreviewView()
    private let inputLabel = NSTextField(wrappingLabelWithString: "Waiting for controller input…")
    private let timingLabel = NSTextField(wrappingLabelWithString: "")
    private let networkLabel = NSTextField(wrappingLabelWithString: "")

    init(
        diagnostics: ROBControlLatencyDiagnostics = .shared,
        networkSummary: @escaping @MainActor () -> String
    ) {
        self.diagnostics = diagnostics
        self.networkSummary = networkSummary
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Control Latency"
        window.minSize = NSSize(width: 740, height: 740)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(labelWithString: "Controller → Cerebro → Base")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Live received input • read-only • updates 4 times a second")
        subtitle.textColor = .secondaryLabelColor
        inputView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        inputLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        timingLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        networkLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        for label in [inputLabel, timingLabel, networkLabel] { label.isSelectable = true }
        let explanation = NSTextField(wrappingLabelWithString:
            "Main queue wait isolates Cerebro scheduling stalls. Handler time includes parsing and synchronous output. " +
            "Connection round trip includes both apps’ scheduling. Serial write measures the OS write call, not motor response. " +
            "Sender age is an estimate requiring synchronized clocks. Preview shows received input, not applied motor state.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        let reset = NSButton(title: "Reset peaks", target: self, action: #selector(resetPeaks))
        let stack = NSStackView(views: [title, subtitle, inputView, inputLabel, timingLabel, networkLabel, explanation, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        window.contentView = root
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])
        for view in [inputView, inputLabel, timingLabel, networkLabel, explanation] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        self.window = window
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        if window == nil { loadWindow() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refresh()
        if refreshTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func resetPeaks() {
        diagnostics.resetPeaks()
        refresh()
    }

    private func refresh() {
        let snapshot = diagnostics.snapshot()
        let age = snapshot.input.map { max(0, ProcessInfo.processInfo.systemUptime - $0.receivedUptime) }
        inputView.input = snapshot.input
        inputView.isStale = (age ?? .infinity) > 0.5
        inputView.needsDisplay = true
        if let input = snapshot.input, let age {
            let senderAge = input.senderClockAgeMilliseconds.map { String(format: "%.1f ms", $0) } ?? "unavailable"
            inputLabel.stringValue = "\(input.controller)  •  sequence \(input.sequence)\n" +
                String(format: "Received %.2f s ago  •  speed %.0f%%  •  brake %@\n", age, input.speed, input.brake ? "ON" : "off") +
                "Sender clock age: \(senderAge)  •  received frames: \(snapshot.receivedInputs)"
        } else {
            inputLabel.stringValue = "Waiting for controller input…\nNo received tread preview yet.\nReceived frames: 0"
        }
        func timing(_ name: String, _ timing: ROBControlTiming) -> String {
            guard let last = timing.lastMilliseconds else { return "\(name): waiting for a sample" }
            return String(format: "%@: %.1f ms  |  peak %.1f ms", name, last, timing.peakMilliseconds)
        }
        let serialStatus = snapshot.serialWriteSucceeded.map { $0 ? "OS accepted bytes" : "unavailable / incomplete write" } ?? "no write observed"
        timingLabel.stringValue = [
            timing("Main queue wait", snapshot.mainQueue),
            timing("Command handler", snapshot.commandHandler),
            timing("Base serial write", snapshot.serialWrite),
            "Serial status: \(serialStatus)",
        ].joined(separator: "\n")
        networkLabel.stringValue = networkSummary()
    }
}

@MainActor
private final class ROBControlInputPreviewView: NSView {
    var input: ROBControlInputPreview?
    var isStale = true

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        for (index, label, point) in [(0, "LEFT TREAD", input?.left), (1, "RIGHT TREAD", input?.right)] {
            let center = CGPoint(x: bounds.width * (index == 0 ? 0.25 : 0.75), y: 93)
            let radius: CGFloat = 52
            NSColor.separatorColor.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 2
            ring.stroke()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: center.x - radius, y: center.y))
            cross.line(to: CGPoint(x: center.x + radius, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - radius))
            cross.line(to: CGPoint(x: center.x, y: center.y + radius))
            cross.stroke()
            let active = point.map { abs($0.x) <= 1 && abs($0.y) <= 1 } ?? false
            let position = active ? point! : .zero
            (isStale || !active ? NSColor.secondaryLabelColor : NSColor.systemBlue).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x + position.x * radius - 6, y: center.y + position.y * radius - 6, width: 12, height: 12)).fill()
            let caption = label + (isStale ? " · STALE / IDLE" : active ? " · ACTIVE" : " · RELEASED")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = (caption as NSString).size(withAttributes: attributes)
            (caption as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: 12), withAttributes: attributes)
        }
    }
}
