import AppKit
import CoreImage
import CryptoKit

/// Holds one current passive belly frame without queuing every camera update.
private final class ROBBellyQRFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ROBDepthCloudFrame?
    func offer(_ frame: ROBDepthCloudFrame) {
        guard frame.isBelly else { return }
        lock.lock(); latest = frame; lock.unlock()
    }
    func take() -> ROBDepthCloudFrame? {
        lock.lock(); defer { lock.unlock() }
        let frame = latest; latest = nil; return frame
    }
}

/// Passive two-target camera diagnostics. This window has no actuator,
/// ownership, neck, profile-installation or arm-approval capability.
@MainActor @objcMembers final class ROBBellyQRCalibrationWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ROBBellyQRCalibrationWindowController()
    static let changed = Notification.Name("ROBBellyQRCalibrationDidChange")
    private(set) var isRunning = false
    private(set) var status = "Open Belly Camera Diagnostics, place both targets in its view, then capture. ROB and both sheets should stay still."
    private(set) var lastCapturePath = ""
    private let spacing = NSTextField(string: "400")
    private let image = NSImageView()
    private let details = NSTextView()
    private let captureButton = NSButton(title: "Capture 5 belly frames", target: nil, action: nil)
    private let stopButton = NSButton(title: "Cancel capture", target: nil, action: nil)
    private let evidenceButton = NSButton(title: "Show saved evidence", target: nil, action: nil)
    @nonobjc private let mailbox = ROBBellyQRFrameMailbox()
    @nonobjc private var observer: NSObjectProtocol?
    @nonobjc private var task: Task<Void, Never>?
    @nonobjc private var process: Process?
    private var activeCapture: UUID?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Belly camera / QR calibration"
        window.identifier = NSUserInterfaceItemIdentifier("belly-qr-calibration")
        window.minSize = NSSize(width: 820, height: 700)
        super.init(window: window)
        window.delegate = self
        build(); window.center()
        let mailbox = self.mailbox
        observer = NotificationCenter.default.addObserver(forName: .ROBDepthCloudFrame, object: nil, queue: nil) { notification in
            guard let frame = notification.object as? ROBDepthCloudFrame else { return }
            mailbox.offer(frame)
        }
        // Do not post a change while shared is initializing: the sandbox may
        // be evaluating this singleton from its own refresh callback.
        details.string = status; stopButton.isEnabled = false; evidenceButton.isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("Use shared") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true); display(status)
    }
    func windowWillClose(_ notification: Notification) { if isRunning { stop() } }

    private func build() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        let help = NSTextField(wrappingLabelWithString: "Use the 120 mm B01 and B02 sheets, flat on the floor with their TOP arrows parallel and centers 400 mm apart. Keep every corner and white border visible. Capture reads the running belly camera without moving ROB. The report checks target geometry and raw depth; it does not install an arm calibration.")
        root.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let row = NSStackView(); row.spacing = 10
        row.addArrangedSubview(NSTextField(labelWithString: "Target center spacing (mm):"))
        spacing.setAccessibilityLabel("Belly QR center spacing millimeters")
        spacing.widthAnchor.constraint(equalToConstant: 80).isActive = true
        row.addArrangedSubview(spacing); root.addArrangedSubview(row)
        let actions = NSStackView(); actions.spacing = 8
        captureButton.target = self; captureButton.action = #selector(captureCurrentView)
        captureButton.identifier = NSUserInterfaceItemIdentifier("belly-qr-capture")
        stopButton.target = self; stopButton.action = #selector(stop)
        stopButton.identifier = NSUserInterfaceItemIdentifier("belly-qr-stop")
        evidenceButton.target = self; evidenceButton.action = #selector(showEvidence)
        evidenceButton.identifier = NSUserInterfaceItemIdentifier("belly-qr-evidence")
        for button in [captureButton, stopButton, evidenceButton] { actions.addArrangedSubview(button) }
        root.addArrangedSubview(actions)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("Frozen belly RGB calibration frame")
        root.addArrangedSubview(image)
        image.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        image.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        details.isEditable = false; details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.setAccessibilityIdentifier("belly-qr-calibration-status")
        details.frame = NSRect(x: 0, y: 0, width: 940, height: 200)
        details.isHorizontallyResizable = false; details.isVerticallyResizable = true
        details.autoresizingMask = [.width]; details.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = details; root.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func display(_ text: String) {
        status = text; details.string = text
        captureButton.isEnabled = !isRunning; spacing.isEnabled = !isRunning
        stopButton.isEnabled = isRunning; evidenceButton.isEnabled = !lastCapturePath.isEmpty
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func save(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(text) = self { return text }; return nil }
    }

    @objc func captureCurrentView() {
        guard !isRunning else { return }
        guard let millimeters = Double(spacing.stringValue), millimeters.isFinite,
              (150...1500).contains(millimeters) else {
            display("Enter the target center spacing between 150 and 1500 mm."); return
        }
        let capture = UUID(); activeCapture = capture; isRunning = true
        _ = mailbox.take()
        display("Waiting for fresh belly RGB-D frames. Keep Belly Camera Diagnostics open; no camera or robot motion is requested.")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeCapture == capture {
                    self.activeCapture = nil; self.isRunning = false; self.process = nil; self.task = nil
                    self.display(self.status)
                }
            }
            do { try await self.capture(capture, centerSpacingMeters: millimeters / 1000) }
            catch {
                if self.activeCapture == capture {
                    self.display(Task.isCancelled ? "Belly capture cancelled. Saved evidence remains diagnostic only." : error.localizedDescription)
                }
            }
        }
    }

    private func capture(_ capture: UUID, centerSpacingMeters: Double) async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/BellyQRCalibration/Captures", isDirectory: true)
        let destination = root.appendingPathComponent(capture.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lastCapturePath = destination.path
        var records: [[String: Any]] = [], missing = Set<String>()
        var stream: String?, lastSequence: UInt64?, lastFrameUptime = 0.0
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 25
        let context = CIContext()
        while records.count < 5 {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            guard activeCapture == capture else { throw CancellationError() }
            guard now < deadline else {
                throw Failure.invalid("Timed out waiting for five fresh belly RGB-D frames. Open Belly Camera Diagnostics and retry. Captured files remain in \(destination.path).")
            }
            guard let frame = mailbox.take(), frame.isBelly, frame.capturedUptime >= started,
                  (-0.05...0.7).contains(now - frame.capturedUptime), frame.capturedUptime > lastFrameUptime + 0.20,
                  (16...4096).contains(frame.width), (16...4096).contains(frame.height),
                  frame.millimetersLittleEndian.length == frame.width * frame.height * 2,
                  let rgb = frame.rgbPixelBuffer else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            if let sequence = frame.sourceSequence, let lastSequence, sequence <= lastSequence {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            if let sourceStream = frame.sourceCaptureStreamID {
                guard stream == nil || stream == sourceStream else {
                    throw Failure.invalid("The belly camera stream restarted during capture. Saved frames were not combined; capture again.")
                }
                stream = sourceStream
            } else { missing.insert("source camera stream ID") }
            let name = "frame-\(records.count)", source = CIImage(cvPixelBuffer: rgb)
            guard let cg = context.createCGImage(source, from: source.extent),
                  let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
                throw Failure.invalid("The belly RGB frame could not be saved.")
            }
            let depth = frame.millimetersLittleEndian as Data
            try Self.save(jpeg, to: destination.appendingPathComponent(name + ".jpg"))
            try Self.save(depth, to: destination.appendingPathComponent(name + ".depth-u16le"))
            var record: [String: Any] = ["imagePath": name + ".jpg", "imageSHA256": Self.hash(jpeg),
                "sourceImageSHA256": Self.hash(jpeg), "depthPath": name + ".depth-u16le", "depthSHA256": Self.hash(depth),
                "width": frame.width, "height": frame.height, "rgbWidth": cg.width, "rgbHeight": cg.height,
                "sourceCameraRole": "belly", "capturedUptime": frame.capturedUptime, "receivedUptime": frame.receivedUptime,
                "rgbGeometryMatchesNativeDepth": cg.width == frame.width && cg.height == frame.height]
            if let sequence = frame.sourceSequence {
                record["sequence"] = NSNumber(value: sequence); record["sequenceSource"] = "camera_frame_set"
                lastSequence = sequence
            } else { missing.insert("source camera sequence") }
            if let value = frame.sourceCapturedAtMilliseconds, value.isFinite, value > 0 {
                record["capturedAtMilliseconds"] = value
            } else { missing.insert("source capture timestamp") }
            if let value = frame.sourceTimestampNanoseconds { record["sourceTimestampNanoseconds"] = NSNumber(value: value) }
            if let value = frame.sourceCaptureStreamID { record["captureStreamID"] = value }
            if let k = frame.calibratedIntrinsics {
                if k.isValid(forWidth: frame.width, height: frame.height), cg.width == frame.width, cg.height == frame.height {
                    record["intrinsics"] = [k.fx, k.fy, k.cx, k.cy]
                } else { missing.insert("aligned native RGB/depth intrinsics") }
                if let value = k.rgbOutputUndistorted { record["rgbOutputUndistorted"] = value }
                else { missing.insert("RGB undistortion metadata") }
                if let value = k.cameraServiceSourceSHA256 { record["cameraServiceSourceSHA256"] = value }
                if let value = k.calibrationSource { record["intrinsicsSource"] = value }
                if let value = k.depthAlignmentMethod { record["depthAlignmentMethod"] = value }
                else { missing.insert("depth alignment metadata") }
                if let value = k.sourceSize { record["rgbSourceSize"] = value }
                if let value = k.sourceIntrinsics { record["rgbSourceIntrinsics"] = value }
                if let value = k.imageTransform { record["rgbImageTransform"] = value }
                if let value = k.calibratedLensPosition { record["calibratedLensPosition"] = value }
                if let value = k.frameLensPosition { record["frameLensPosition"] = value }
            } else { missing.insert("calibrated camera intrinsics and pixel metadata") }
            records.append(record); lastFrameUptime = frame.capturedUptime
            image.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            display("Saved \(records.count)/5 fresh belly frames. ROB, neck and arms unchanged.")
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        var input: [String: Any] = ["schemaVersion": 1, "kind": "belly_qr_capture", "cameraRole": "belly",
            "captureSessionID": capture.uuidString, "markerSizeMeters": 0.12, "centerSpacingMeters": centerSpacingMeters,
            "layout": ["symbolSideMeters": 0.12, "centerSeparationMeters": centerSpacingMeters,
                "b01IsPrintedLeft": true, "parallelPrintedTop": true],
            "frames": records, "missingSourceEvidence": missing.sorted(),
            "recordedAtUTC": ISO8601DateFormatter().string(from: Date()),
            "registrationVerified": false, "armMotionAuthorized": false]
        if let stream { input["captureStreamID"] = stream }
        let inputURL = destination.appendingPathComponent("capture-input.json")
        try Self.save(try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]), to: inputURL)
        try Task.checkCancellation()
        try await diagnose(inputURL: inputURL, destination: destination, missing: missing.sorted())
    }

    private func diagnose(inputURL: URL, destination: URL, missing: [String]) async throws {
        guard let resources = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw Failure.invalid("The bundled belly QR diagnostic worker is unavailable. Five RGB-D frames remain saved at \(destination.path).")
        }
        let worker = resources.appendingPathComponent("belly_qr_diagnostic.py")
        guard FileManager.default.isReadableFile(atPath: worker.path) else {
            throw Failure.invalid("The belly QR diagnostic worker is missing. Captured evidence remains saved.")
        }
        let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Cerebro/calibration-analysis-venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw Failure.invalid("The calibration-analysis Python environment is unavailable. Captured evidence remains saved at \(destination.path).")
        }
        let outputURL = destination.appendingPathComponent("diagnostic.json"), logURL = destination.appendingPathComponent("diagnostic.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
        let workerProcess = Process(); process = workerProcess
        workerProcess.executableURL = python
        workerProcess.arguments = ["-B", worker.path, "--input", inputURL.path, "--output", outputURL.path]
        workerProcess.currentDirectoryURL = resources
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"; environment["OPENBLAS_NUM_THREADS"] = "1"; environment["VECLIB_MAXIMUM_THREADS"] = "1"
        workerProcess.environment = environment; workerProcess.standardOutput = log; workerProcess.standardError = log
        try workerProcess.run()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            while workerProcess.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime - started < 90 else {
                    throw Failure.invalid("The belly QR diagnostic exceeded 90 seconds. Saved frames are available for offline inspection.")
                }
                display("Checking both printed targets and raw belly depth… \(Int(ProcessInfo.processInfo.systemUptime - started)) s\nNo robot commands or calibration installation.")
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch { if workerProcess.isRunning { workerProcess.terminate() }; throw error }
        let report = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "No diagnostic report was produced."
        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        }
        let missingText = missing.isEmpty ? "" : "\nMissing source evidence: " + missing.joined(separator: ", ")
        display("Belly QR diagnostic finished (exit \(workerProcess.terminationStatus)). No profile or arm registration installed.\(missingText)\n\(destination.path)\n" + String(report.suffix(16000)) + (workerProcess.terminationStatus == 0 ? "" : "\n" + String(logText.suffix(3000))))
    }

    @objc func stop() {
        activeCapture = nil; task?.cancel(); task = nil
        if process?.isRunning == true { process?.terminate() }; process = nil
        isRunning = false; display("Belly capture cancelled. Any saved frames remain diagnostic only.")
    }
    @objc func showEvidence() {
        guard !lastCapturePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastCapturePath)])
    }
}
