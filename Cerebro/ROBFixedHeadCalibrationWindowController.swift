import AppKit
import CoreImage
import CryptoKit
import simd
import UniformTypeIdentifiers

/// Acquires real fixed-view RGB-D evidence. This controller has no arm command
/// capability: model placement is an initializer, never a registration proof.
@MainActor @objcMembers final class ROBFixedHeadCalibrationWindowController: NSWindowController {
    static let shared = ROBFixedHeadCalibrationWindowController()
    var readNeck: (() -> NSDictionary)?
    var holdCurrentView: (() -> Bool)?
    var cameraDemand: ((Bool) -> Void)?
    private(set) var isRunning = false
    private(set) var status = "Capture a fixed head view containing ROB's base and torso. Separate surface regions and later frames validate the fit."
    private(set) var lastCapturePath = ""
    private let side = NSPopUpButton()
    private let referenceError = NSTextField(string: "20")
    private let image = NSImageView()
    private let details = NSTextView()
    private let captureButton = NSButton(title: "Capture + fit current head pose", target: nil, action: nil)
    private let importButton = NSButton(title: "Import measured landmarks…", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop capture", target: nil, action: nil)
    @nonobjc private var task: Task<Void, Never>?
    @nonobjc private var process: Process?
    @nonobjc private var armOwner: UUID?
    private var captureBodyIdentity: String?
    private var cameraHeld = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Fixed-head camera-to-arm calibration"
        window.identifier = NSUserInterfaceItemIdentifier("fixed-head-registration")
        super.init(window: window)
        build()
        window.center()
        NotificationCenter.default.addObserver(self, selector:#selector(bodyDidMove),
            name:Notification.Name("ROBFixedHeadBodyDidMove"),object:nil)
    }
    required init?(coder: NSCoder) { fatalError("Use shared") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true); display(status)
    }
    private func build() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        let help = NSTextField(wrappingLabelWithString: "Hold ROB and the head still. Capture uses the current head pose without moving an arm. The fitted transform is valid only for its recorded pose, camera, model, arm mapping and measured volume. A fit that fails validation stays diagnostic.")
        root.addArrangedSubview(help)
        let row = NSStackView(); row.spacing = 10
        side.addItems(withTitles: ["Right arm", "Left arm"])
        side.setAccessibilityLabel("Calibration physical arm")
        referenceError.setAccessibilityLabel("Assumed CAD reference uncertainty millimeters")
        referenceError.widthAnchor.constraint(equalToConstant: 64).isActive = true
        row.addArrangedSubview(side)
        row.addArrangedSubview(NSTextField(labelWithString: "Assumed CAD reference uncertainty (mm):"))
        row.addArrangedSubview(referenceError); root.addArrangedSubview(row)
        let actions = NSStackView(); actions.spacing = 8
        captureButton.target = self; captureButton.action = #selector(captureCurrentView)
        captureButton.identifier = NSUserInterfaceItemIdentifier("fixed-head-capture-fit")
        importButton.target = self; importButton.action = #selector(importLandmarks)
        stopButton.target = self; stopButton.action = #selector(stop)
        for b in [captureButton, importButton, stopButton] { actions.addArrangedSubview(b) }
        let folder = NSButton(title: "Show evidence", target: self, action: #selector(showEvidence))
        actions.addArrangedSubview(folder); root.addArrangedSubview(actions)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("Frozen fixed-head RGB measurement")
        root.addArrangedSubview(image)
        image.heightAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        image.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        details.isEditable = false; details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.setAccessibilityIdentifier("fixed-head-registration-status")
        details.frame = NSRect(x:0,y:0,width:900,height:190)
        details.isHorizontallyResizable = false; details.isVerticallyResizable = true
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = details
        root.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }
    private func display(_ text: String) {
        status = text; details.string = text
        captureButton.isEnabled = !isRunning; importButton.isEnabled = !isRunning
        side.isEnabled = !isRunning; referenceError.isEnabled = !isRunning
        stopButton.isEnabled = isRunning
        NotificationCenter.default.post(name: Notification.Name("ROBFixedHeadRegistrationDidChange"), object: self)
    }

    @nonobjc static func intrinsicsIdentity(_ frame: ROBArmRoutineVision.Frame) throws -> String {
        guard let depth = frame.depth, let k = frame.intrinsics,
              k.isValid(forWidth: depth.width, height: depth.height) else {
            throw ROBGhostMotionError.blocked("Aligned depth and valid intrinsics are required.")
        }
        let data = try JSONSerialization.data(withJSONObject: [Double(depth.width), Double(depth.height), k.fx, k.fy, k.cx, k.cy])
        return ROBGhostRobotModel.hash(data)
    }
    @nonobjc func scope(model: ROBGhostRobotModel, frame: ROBArmRoutineVision.Frame) throws -> ROBFixedHeadRegistrationScope {
        let neck = readNeck?() ?? [:]
        guard neck["known"] as? Bool == true, neck["stationary"] as? Bool == true,
              let pan = neck["pan"] as? Int, let lower = neck["lower"] as? Int,
              let upper = neck["upper"] as? Int,
              let ready = neck["ready_at"] as? Double, ready <= ProcessInfo.processInfo.systemUptime,
              ProcessInfo.processInfo.systemUptime - (Date().timeIntervalSince1970*1000-frame.capturedAt)/1000 >= ready,
              let correction = ROBWorkspaceDepthAlignment.snapshot(),
              let generation = (ROBAmberGatewayClient.shared.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value,
              generation > 0, frame.cameraGeneration == ROBArmRoutineVision.shared.cameraGeneration else {
            throw ROBGhostMotionError.blocked("Fresh stationary neck, camera and authenticated arm session are required for registration.")
        }
        return ROBFixedHeadRegistrationScope(modelID: model.modelID, geometryID: model.geometryID,
            mappingID: model.selectedMappingID, cameraGeneration: frame.cameraGeneration,
            gatewaySessionGeneration: generation,
            displayCorrectionIdentity: correction.identity + ":body:" + ROBFixedHeadBodyMotionIdentity.currentIdentity,
            panTarget: pan, lowerTarget: lower, upperTarget: upper,
            intrinsicsIdentity: try Self.intrinsicsIdentity(frame))
    }
    @nonobjc func registration(model: ROBGhostRobotModel, frame: ROBArmRoutineVision.Frame) throws -> ROBFixedHeadRegistration? {
        ROBFixedHeadRegistrationStore.shared.resolve(scope: try scope(model: model, frame: frame))
    }

    @objc func captureCurrentView() {
        guard !isRunning, task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.captureAndFit() }
            catch { self.display(error is CancellationError ? "Capture stopped; saved evidence retained." : error.localizedDescription) }
            self.finishCapture()
        }
    }
    private func beginCapture() throws {
        guard !ROBLeftArmTrial.shared.isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
              !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion, !ROBNeckQRCalibration.shared.isRunning,
              !ROBAmberGestureExecutor.shared.isExecuting, !ROBShowMotionCoordinator.shared.isRunning,
              !ROBGripperStartupCalibration.shared.isRunning, !ROBControllerArmApproval.shared.isPending,
              holdCurrentView?() == true else { throw ROBGhostMotionError.blocked("Finish the active operation and hold a known stationary head pose before calibration.") }
        let id = UUID()
        guard ROBAmberArmMotionArbiter.shared.reserve(.left, owner: id) else { throw ROBGhostMotionError.blocked("Left arm is owned by another operation.") }
        guard ROBAmberArmMotionArbiter.shared.reserve(.right, owner: id) else {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: id)
            throw ROBGhostMotionError.blocked("Right arm is owned by another operation.")
        }
        armOwner = id; captureBodyIdentity = ROBFixedHeadBodyMotionIdentity.currentIdentity; isRunning = true
        ROBArmRoutineVision.shared.setActive(true); cameraDemand?(true); cameraHeld = true
        display("Starting the RGB-D camera; waiting for fresh fixed-pose frames…")
    }
    private func finishCapture() {
        if let armOwner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: armOwner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: armOwner)
        }
        armOwner = nil; captureBodyIdentity = nil; isRunning = false; task = nil; process = nil
        // Keep the camera stream and fixed head alive: restarting it invalidates
        // the evidence identity. A later task acquires its own arm ownership.
        display(status)
    }
    private func checkPose(_ expected: NSDictionary) throws {
        try Task.checkCancellation()
        let current = readNeck?() ?? [:]
        guard captureBodyIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity,
              current["known"] as? Bool == true, current["stationary"] as? Bool == true,
              ["pan", "lower", "upper"].allSatisfy({ (current[$0] as? Int) == (expected[$0] as? Int) }),
              let ready = current["ready_at"] as? Double, ready <= ProcessInfo.processInfo.systemUptime else {
            throw ROBGhostMotionError.blocked("The head or base changed during fixed-view capture. Saved evidence was not installed.")
        }
    }
    private func captureAndFit() async throws {
        guard let uncertainty = Double(referenceError.stringValue), (5...40).contains(uncertainty),
              let resources = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw ROBGhostMotionError.blocked("Use a CAD reference uncertainty between 5 and 40 mm; the bundled model must be available.")
        }
        let model = try ROBGhostRobotModel(directory: resources, physicalSide: side.indexOfSelectedItem == 0 ? "right" : "left")
        try beginCapture()
        let expected = readNeck?() ?? [:]
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/FixedHeadRegistration/Captures")
        let destination = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lastCapturePath = destination.path
        var records: [[String: Any]] = [], firstScope: ROBFixedHeadRegistrationScope?, lastSequence: UInt64 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        var firstEligible: Double?
        while records.count < 5 {
            try checkPose(expected)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                let health = ROBArmRoutineVision.shared.healthSnapshot()
                var diagnostic = "No five fresh fixed-pose RGB-D frames arrived within 25 seconds.\n\(health)"
                if let current = ROBArmRoutineVision.shared.snapshot()["face"] {
                    diagnostic += "\nAnalyzed RGB: \(current.image.extent); depth: \(current.depth.map { "\($0.width)x\($0.height)" } ?? "missing"); usable depth: \(current.depthCoverage)"
                }
                try? diagnostic.write(to:destination.appendingPathComponent("capture-diagnostic.txt"),atomically:true,encoding:.utf8)
                throw ROBGhostMotionError.blocked(diagnostic)
            }
            guard let frame = ROBArmRoutineVision.shared.snapshot()["face"], frame.sequence > lastSequence,
                  (0...500).contains(Date().timeIntervalSince1970 * 1000 - frame.capturedAt),
                  frame.depthCoverage > 0, let depth = frame.depth, let k = frame.intrinsics,
                  k.isValid(forWidth: depth.width, height: depth.height) else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            // This fit consumes native depth and its native intrinsics. The
            // vision preview can be resized, and dark robot surfaces can be
            // sparse. Spatial support and held-out quality are decided by the
            // fitter, rather than a whole-image coverage/preview-size gate.
            lastSequence = frame.sequence
            if firstEligible == nil { firstEligible = frame.capturedAt }
            guard frame.capturedAt - firstEligible! >= 1000 else { continue }
            let scope = try self.scope(model: model, frame: frame)
            if let firstScope { guard scope == firstScope else { throw ROBGhostMotionError.blocked("Camera, head, model or session identity changed during capture.") } }
            else { firstScope = scope }
            var data = Data(capacity: depth.width * depth.height * 2)
            for y in 0..<depth.height { for x in 0..<depth.width {
                let mm = depth.distanceMillimeters(x: x, y: y) ?? 0
                data.append(UInt8(mm & 255)); data.append(UInt8(mm >> 8))
            } }
            let name = "frame-\(records.count)"
            try data.write(to: destination.appendingPathComponent(name + ".depth-u16le"), options: .atomic)
            if let cg = CIContext().createCGImage(frame.image, from: frame.image.extent) {
                let bitmap = NSBitmapImageRep(cgImage: cg)
                try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95])?.write(to: destination.appendingPathComponent(name + ".jpg"), options: .atomic)
                image.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            records.append(["depthPath": name + ".depth-u16le", "width": depth.width, "height": depth.height,
                "intrinsics": [k.fx,k.fy,k.cx,k.cy], "sequence": NSNumber(value: frame.sequence),
                "capturedAtMilliseconds": frame.capturedAt, "captureSHA256": ROBGhostRobotModel.hash(data),
                "previewWidth":Int(frame.image.extent.width),"previewHeight":Int(frame.image.extent.height),
                "depthCoverage":frame.depthCoverage])
            display("Captured \(records.count)/5 fixed-view frames. Head P\(scope.panTarget) L\(scope.lowerTarget) U\(scope.upperTarget). Arms unchanged.")
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scope = firstScope, let pan = expected["pan_degrees"] as? Double,
              let pose = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: pan * .pi / 180,
                lowerTarget: scope.lowerTarget, upperTarget: scope.upperTarget, known: true),
              let head = model.headPositions(pan: pose.panRadians, lowerPitch: pose.lowerPitch, upperPitch: pose.upperPitch),
              let optical = model.frames(model.reference.merging(head) { _,new in new })["oak_optical_frame"],
              let alignment = ROBWorkspaceDepthAlignment.snapshot() else { throw ROBGhostMotionError.blocked("Current head model initializer is unavailable.") }
        let initial = alignment.applying(to: optical)
        let scopeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope))
        let input: [String: Any] = ["schemaVersion":1, "scope":scopeJSON,
            "validRobotVolume":["lowMeters":[-0.65,-0.95,0.05],"highMeters":[1.20,0.95,1.60]],
            "referenceUncertaintyMeters":uncertainty/1000,
            "initialCameraToRobotColumnMajor":(0..<4).flatMap { col in (0..<4).map { initial[col][$0] } }, "frames":records]
        let inputURL = destination.appendingPathComponent("capture-input.json"), outputURL = destination.appendingPathComponent("registration-input.json")
        try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted,.sortedKeys]).write(to: inputURL, options: .atomic)
        try checkPose(expected)
        let worker = Process(); process = worker
        worker.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3")
        worker.arguments = ["-B",resources.appendingPathComponent("fixed_head_registration.py").path,"--input",inputURL.path,"--output",outputURL.path]
        worker.currentDirectoryURL = resources
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"; environment["OPENBLAS_NUM_THREADS"] = "1"; environment["VECLIB_MAXIMUM_THREADS"] = "1"
        worker.environment = environment
        let log = destination.appendingPathComponent("fit.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions:0o600])
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        worker.standardOutput = handle; worker.standardError = handle
        try worker.run()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            while worker.isRunning {
                try checkPose(expected)
                guard ProcessInfo.processInfo.systemUptime-started < 180 else { throw ROBGhostMotionError.blocked("Fixed-view fitting exceeded three minutes; no registration installed.") }
                display("Fitting visible robot surfaces and checking held-out regions/frames… \(Int(ProcessInfo.processInfo.systemUptime-started)) s\nThe model prior is only an initializer.")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch { if worker.isRunning { worker.terminate() }; throw error }
        guard worker.terminationStatus == 0 else {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? "No fit diagnostic"
            throw ROBGhostMotionError.blocked("Fixed-view registration was not validated.\n" + String(message.suffix(5000)))
        }
        let measured = try JSONDecoder().decode(ROBFixedHeadRegistrationInput.self, from: Data(contentsOf: outputURL))
        guard measured.scope == scope else { throw ROBGhostMotionError.blocked("Fit returned a different capture scope.") }
        try checkPose(expected)
        guard let current = ROBArmRoutineVision.shared.snapshot()["face"],
              (0...700).contains(Date().timeIntervalSince1970*1000-current.capturedAt),
              try self.scope(model:model,frame:current) == scope else {
            throw ROBGhostMotionError.blocked("Camera or arm connection changed during fitting; capture this held view again.")
        }
        let registration = try ROBFixedHeadRegistrationStore.shared.install(measured)
        let report: [String:Any] = ["id":registration.id, "fitRMSEMeters":registration.fitRMSEMeters,
            "validationRMSEMeters":registration.validationRMSEMeters,"validationMaximumMeters":registration.validationMaximumMeters,
            "uncertaintyMeters":registration.uncertaintyMeters,"trainingCount":registration.trainingCount,
            "validationCount":registration.validationCount,"scope":scopeJSON,
            "cameraToRobotColumnMajor":(0..<4).flatMap { col in (0..<4).map { registration.cameraToRobot[col][$0] } }]
        let pretty = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        display("Fixed-pose measured registration installed. This does not authorize arm movement.\n" + (String(data: pretty, encoding: .utf8) ?? ""))
    }
    @objc private func importLandmarks() {
        guard !isRunning else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000 else { throw ROBGhostMotionError.blocked("Measured landmark file exceeds 2 MB.") }
            _ = try JSONDecoder().decode(ROBFixedHeadRegistrationInput.self, from: data)
            guard let resources = Bundle.main.url(forResource:"ShadowPlanner",withExtension:nil),
                  let frame = ROBArmRoutineVision.shared.snapshot()["face"],
                  (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt) else {
                throw ROBGhostMotionError.blocked("Start a current fixed-view camera capture before importing measurements.")
            }
            let model = try ROBGhostRobotModel(directory:resources,physicalSide:side.indexOfSelectedItem == 0 ? "right" : "left")
            let current = try scope(model:model,frame:frame)
            let registration = try ROBFixedHeadRegistrationStore.shared.load(url,scope:current)
            display("Measured landmark fit installed for the current recorded pose.\n\(registration)")
        } catch { display(error.localizedDescription) }
    }
    @objc func stop() { task?.cancel(); if process?.isRunning == true { process?.terminate() } }
    @objc private func bodyDidMove() {
        stop()
        ROBWorkspaceSearch.shared.depthAlignmentDidChange()
        display("The body moved. Recorded fixed-head registrations are no longer current; capture a new view before arm travel.")
    }
    @objc private func showEvidence() {
        guard !lastCapturePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:lastCapturePath)])
    }
}
