import AppKit
import Foundation

@objcMembers public final class ROBInsta360DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    private let service = ROBInsta360CameraService.shared
    private let imageView = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let metricsLabel = NSTextField(labelWithString: "")
    private let restartButton = NSButton(title: "Restart Camera Service", target: nil, action: nil)
    private let stabilizationToggle = NSButton(checkboxWithTitle: "Gyro stabilization", target: nil, action: nil)

    public init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Insta360 Stream Diagnostics"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        configure(window)
        NotificationCenter.default.addObserver(self, selector: #selector(serviceChanged(_:)),
                                               name: .robInsta360CameraServiceDidChange, object: service)
        refresh()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refresh()
    }

    private func configure(_ window: NSWindow) {
        let content = NSView()
        window.contentView = content
        let heading = NSTextField(labelWithString: "Background camera service")
        heading.font = .boldSystemFont(ofSize: 17)
        let help = NSTextField(wrappingLabelWithString: "Cerebro owns the Pro 2 and receives this stream without the Insta360 Pro app. This window only observes the already-running background service; closing it does not interrupt robot vision.")
        help.textColor = .secondaryLabelColor
        stateLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        urlLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        metricsLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        restartButton.target = self
        restartButton.action = #selector(restart(_:))
        stabilizationToggle.target = self
        stabilizationToggle.action = #selector(stabilizationChanged(_:))
        // Diagnostic/show mode favors using every available pixel. A 360°
        // equirectangular feed is intentionally wide, and this keeps the
        // preview attached to every window edge while the operator resizes it.
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let status = NSStackView(views: [stateLabel, NSView(), stabilizationToggle, restartButton])
        status.orientation = .horizontal
        let stack = NSStackView(views: [heading, help, status, urlLabel, imageView, metricsLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            urlLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
    }

    @objc private func restart(_ sender: Any?) { service.restart() }
    @objc private func stabilizationChanged(_ sender: NSButton) {
        service.gyroStabilizationEnabled = sender.state == .on
    }
    @objc private func serviceChanged(_ notification: Notification) { refresh() }

    private func refresh() {
        stateLabel.stringValue = service.lastError.map { "\(service.state) — \($0)" } ?? service.state
        stabilizationToggle.state = service.gyroStabilizationEnabled ? .on : .off
        urlLabel.stringValue = service.streamURL
        metricsLabel.stringValue = String(format: "Frames %llu   Decoded %@   FPS %.1f",
            service.framesReceived,
            ByteCountFormatter.string(fromByteCount: Int64(service.decodedBytes), countStyle: .file),
            service.framesPerSecond)
        if let frame = service.latestFrame { imageView.image = frame }
    }
}
