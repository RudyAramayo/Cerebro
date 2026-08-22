//
//  ROBRecordingWindowController.swift
//  Cerebro
//
//  Operator controls for synchronized training corpora and independent video.
//

import AppKit
import Foundation

@objcMembers public final class ROBRecordingWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = ROBRecordingWindowController()

    private let coordinator = ROBRecordingCoordinator.shared
    private let trainingFace = NSButton(checkboxWithTitle: "Face RGB-D", target: nil, action: nil)
    private let trainingBelly = NSButton(checkboxWithTitle: "Belly RGB-D", target: nil, action: nil)
    private let trainingRate = NSPopUpButton()
    private let trainingButton = NSButton()
    private let acceptableButton = NSButton()
    private let rejectedButton = NSButton()
    private let blockedButton = NSButton()
    private let trainingStatus = NSTextField(wrappingLabelWithString: "Not recording")

    private let footageFace = NSButton(checkboxWithTitle: "Face", target: nil, action: nil)
    private let footageBelly = NSButton(checkboxWithTitle: "Belly", target: nil, action: nil)
    private let footageInsta360 = NSButton(checkboxWithTitle: "Insta360", target: nil, action: nil)
    private let faceResolution = NSPopUpButton()
    private let bellyResolution = NSPopUpButton()
    private let insta360Resolution = NSPopUpButton()
    private let footageButton = NSButton()
    private let footageStatus = NSTextField(wrappingLabelWithString: "Not recording")
    private let revealButton = NSButton()
    private var refreshTimer: Timer?

    private override init(window: NSWindow?) {
        let createdWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: createdWindow)
        createdWindow.title = "ROB Recording Control"
        createdWindow.isReleasedWhenClosed = false
        createdWindow.minSize = NSSize(width: 660, height: 560)
        createdWindow.delegate = self
        createdWindow.center()
        configureContent()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingStateDidChange(_:)),
            name: .robRecordingStateDidChange,
            object: coordinator
        )
        refresh()
    }

    public convenience init() { self.init(window: nil) }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "Recording sessions")
        heading.font = .boldSystemFont(ofSize: 21)
        let intro = NSTextField(wrappingLabelWithString:
            "Training mode persists synchronized learning evidence. Camera footage is a separate product and is never added to the training corpus automatically."
        )
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 0

        trainingFace.state = .on
        trainingBelly.state = .on
        trainingRate.addItems(withTitles: ["1 fps", "2 fps", "5 fps"])
        trainingRate.selectItem(withTitle: "2 fps")
        trainingButton.title = "Start Training Session"
        trainingButton.bezelStyle = .rounded
        trainingButton.target = self
        trainingButton.action = #selector(toggleTraining(_:))

        acceptableButton.title = "Mark Acceptable"
        rejectedButton.title = "Mark Rejected"
        blockedButton.title = "Mark Blocked / Stall"
        for button in [acceptableButton, rejectedButton, blockedButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        acceptableButton.action = #selector(markAcceptable(_:))
        rejectedButton.action = #selector(markRejected(_:))
        blockedButton.action = #selector(markBlocked(_:))

        let trainingOptions = horizontal([trainingFace, trainingBelly, NSTextField(labelWithString: "Keyframes:"), trainingRate, NSView()])
        let trainingActions = horizontal([trainingButton, acceptableButton, rejectedButton, blockedButton, NSView()])
        let trainingNote = NSTextField(wrappingLabelWithString:
            "Writes timestamped JPEG keyframes, aligned uint16 depth, rectified stereo views, intrinsics/extrinsics, RPLidar scans, local pose/odometry, tread commands, and provenance-aware labels."
        )
        trainingNote.textColor = .secondaryLabelColor
        trainingNote.font = .systemFont(ofSize: 11)
        trainingStatus.maximumNumberOfLines = 0
        let trainingBox = box(
            title: "Traversability training corpus",
            minimumHeight: 200,
            views: [trainingOptions, trainingActions, trainingStatus, trainingNote]
        )

        footageFace.state = .on
        footageBelly.state = .on
        footageInsta360.state = .off
        let robotResolutions = ["Source", "1280x720", "1920x1080", "3840x2160"]
        faceResolution.addItems(withTitles: robotResolutions)
        bellyResolution.addItems(withTitles: robotResolutions)
        faceResolution.selectItem(withTitle: "1920x1080")
        bellyResolution.selectItem(withTitle: "1920x1080")
        insta360Resolution.addItems(withTitles: ["Source", "1920x960", "3840x1920"])
        insta360Resolution.selectItem(withTitle: "3840x1920")
        footageButton.title = "Start Camera Footage"
        footageButton.bezelStyle = .rounded
        footageButton.target = self
        footageButton.action = #selector(toggleFootage(_:))
        revealButton.title = "Reveal Latest Recordings"
        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(revealLatest(_:))

        let faceRow = cameraResolutionRow(check: footageFace, popup: faceResolution)
        let bellyRow = cameraResolutionRow(check: footageBelly, popup: bellyResolution)
        let instaRow = cameraResolutionRow(check: footageInsta360, popup: insta360Resolution)
        let footageActions = horizontal([footageButton, revealButton, NSView()])
        let footageNote = NSTextField(wrappingLabelWithString:
            "A selected hardware resolution can exceed autonomy's normal stream. The camera may briefly restart; the manifest records both requested encoding size and observed source size. Insta360 4K uses the Pro camera's documented 3840×1920 stitched preview."
        )
        footageNote.textColor = .secondaryLabelColor
        footageNote.font = .systemFont(ofSize: 11)
        footageStatus.maximumNumberOfLines = 0
        let footageBox = box(
            title: "Camera footage (not training data)",
            minimumHeight: 280,
            views: [faceRow, bellyRow, instaRow, footageActions, footageStatus, footageNote]
        )

        let privacy = NSTextField(wrappingLabelWithString:
            "Recording begins only when you press Start and continues if this panel is closed. Stop the session explicitly before removing power. Training data is stored in Application Support; footage is stored in Movies/ROB Recordings."
        )
        privacy.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: 11)
        privacy.maximumNumberOfLines = 0

        let stack = NSStackView(views: [heading, intro, trainingBox, footageBox, privacy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        content.addSubview(scroll)

        for view in [heading, intro, trainingBox, footageBox, privacy] {
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            trainingBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footageBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func cameraResolutionRow(check: NSButton, popup: NSPopUpButton) -> NSView {
        check.widthAnchor.constraint(equalToConstant: 100).isActive = true
        popup.widthAnchor.constraint(equalToConstant: 145).isActive = true
        return horizontal([check, NSTextField(labelWithString: "Recording resolution:"), popup, NSView()])
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        for view in views where view is NSControl {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return stack
    }

    private func box(
        title: String,
        minimumHeight: CGFloat,
        views: [NSView]
    ) -> NSBox {
        let box = NSBox()
        box.title = title
        box.boxType = .primary
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        if let content = box.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            ])
        }
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
        box.setContentCompressionResistancePriority(.required, for: .vertical)
        return box
    }

    @objc private func toggleTraining(_ sender: Any?) {
        let status = coordinator.statusSnapshot()
        if status.trainingActive {
            coordinator.stopTraining()
            refresh()
            return
        }
        let rateText = trainingRate.titleOfSelectedItem ?? "2 fps"
        let rate = Double(rateText.split(separator: " ").first ?? "2") ?? 2
        do {
            try coordinator.startTraining(ROBTrainingRecordingConfiguration(
                faceCameraEnabled: trainingFace.state == .on,
                bellyCameraEnabled: trainingBelly.state == .on,
                keyframesPerSecond: rate
            ))
        } catch {
            present(error)
        }
        refresh()
    }

    @objc private func toggleFootage(_ sender: Any?) {
        let status = coordinator.statusSnapshot()
        if status.footageActive {
            coordinator.stopFootage()
            refresh()
            return
        }
        do {
            try coordinator.startFootage(ROBFootageRecordingConfiguration(
                faceResolution: footageFace.state == .on ? faceResolution.titleOfSelectedItem : nil,
                bellyResolution: footageBelly.state == .on ? bellyResolution.titleOfSelectedItem : nil,
                insta360Resolution: footageInsta360.state == .on ? insta360Resolution.titleOfSelectedItem : nil
            ))
        } catch {
            present(error)
        }
        refresh()
    }

    @objc private func markAcceptable(_ sender: Any?) { coordinator.addOperatorLabel("acceptable") }
    @objc private func markRejected(_ sender: Any?) { coordinator.addOperatorLabel("operator_rejected") }
    @objc private func markBlocked(_ sender: Any?) { coordinator.addOperatorLabel("blocked") }

    @objc private func revealLatest(_ sender: Any?) {
        let snapshot = coordinator.statusSnapshot()
        let urls = [snapshot.footageDirectory, snapshot.trainingDirectory].compactMap { $0 }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func recordingStateDidChange(_ notification: Notification) { refresh() }

    private func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        let snapshot = coordinator.statusSnapshot()
        trainingButton.title = snapshot.trainingActive ? "Stop Training Session" : "Start Training Session"
        footageButton.title = snapshot.footageActive ? "Stop Camera Footage" : "Start Camera Footage"
        for control in [trainingFace, trainingBelly, trainingRate] { control.isEnabled = !snapshot.trainingActive }
        for control in [footageFace, footageBelly, footageInsta360, faceResolution, bellyResolution, insta360Resolution] {
            control.isEnabled = !snapshot.footageActive
        }
        for button in [acceptableButton, rejectedButton, blockedButton] { button.isEnabled = snapshot.trainingActive }

        if snapshot.trainingActive {
            trainingStatus.stringValue = "● RECORDING TRAINING — \(snapshot.trainingFrameCount) keyframes, \(snapshot.lidarScanCount) lidar scans\n\(snapshot.trainingDirectory?.path ?? "")"
            trainingStatus.textColor = .systemRed
        } else {
            trainingStatus.stringValue = snapshot.trainingDirectory.map { "Stopped — latest: \($0.path)" } ?? "Not recording"
            trainingStatus.textColor = .labelColor
        }
        if snapshot.footageActive {
            footageStatus.stringValue = "● RECORDING FOOTAGE — \(snapshot.footageFrameCount) accepted frames\n\(snapshot.footageDirectory?.path ?? "")"
            footageStatus.textColor = .systemRed
        } else {
            footageStatus.stringValue = snapshot.footageDirectory.map { "Stopped — latest: \($0.path)" } ?? "Not recording"
            footageStatus.textColor = .labelColor
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Recording could not start"
        if let window { alert.beginSheetModal(for: window) }
    }
}
