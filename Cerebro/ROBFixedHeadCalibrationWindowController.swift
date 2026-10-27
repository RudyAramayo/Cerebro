import AppKit
import CoreImage
import CryptoKit
import simd
import UniformTypeIdentifiers

/// Source-clock settling for a hardware mode change, without issuing motion.
struct ROBFixedHeadCaptureFrameGate {
    struct PreservedSource {
        let cameraGeneration:UUID,afterSequence:UInt64,afterCapturedAtMilliseconds:Double
        let runtimeCalibrationIdentity:String,cameraServiceSourceSHA256:String
    }
    let requestedAtMilliseconds: Double
    let previousCameraGeneration: UUID?
    let stereoMode: String
    let expectedHeight: Int
    let preservedSource:PreservedSource?
    private var generation: UUID?
    private var lastSequence: UInt64 = 0
    private var lastCapturedAt = 0.0
    private var firstEligible: Double?

    init(requestedAtMilliseconds: Double, previousCameraGeneration: UUID?, stereoMode: String, fullHeight: Bool = false,
         preservedSource:PreservedSource? = nil) {
        self.requestedAtMilliseconds = requestedAtMilliseconds
        self.previousCameraGeneration = previousCameraGeneration
        self.stereoMode = stereoMode
        expectedHeight = fullHeight ? 480 : 400
        self.preservedSource=preservedSource
    }

    mutating func accepts(cameraGeneration: UUID, sequence: UInt64, capturedAt: Double,
        nowMilliseconds: Double, width: Int, height: Int, intrinsics: CameraIntrinsics) -> Bool {
        guard capturedAt.isFinite, nowMilliseconds.isFinite,
              (0...500).contains(nowMilliseconds-capturedAt), capturedAt >= requestedAtMilliseconds,
              width == 640, height == expectedHeight,
              intrinsics.stereoMode == stereoMode, intrinsics.stereoModeSource == "sdk_initial_config_readback",
              intrinsics.stereoExtendedDisparity == (stereoMode == "near_field"),
              intrinsics.stereoSubpixel == (stereoMode == "standard"),
              intrinsics.isValid(forWidth: width, height: height) else { return false }
        if let preservedSource {
            guard cameraGeneration==preservedSource.cameraGeneration,
                  previousCameraGeneration==preservedSource.cameraGeneration,
                  sequence>preservedSource.afterSequence,capturedAt>preservedSource.afterCapturedAtMilliseconds,
                  intrinsics.runtimeCalibration?.cameraRole=="face",
                  intrinsics.runtimeCalibration?.identity==preservedSource.runtimeCalibrationIdentity,
                  intrinsics.cameraServiceSourceSHA256==preservedSource.cameraServiceSourceSHA256 else{return false}
        } else if previousCameraGeneration.map({cameraGeneration == $0}) ?? false {return false}
        if generation != cameraGeneration {
            generation = cameraGeneration; lastSequence = 0; lastCapturedAt = 0; firstEligible = nil
        }
        guard sequence > lastSequence, capturedAt > lastCapturedAt else { return false }
        lastSequence = sequence; lastCapturedAt = capturedAt
        if firstEligible == nil { firstEligible = capturedAt }
        return capturedAt-firstEligible! >= 2_000
    }
}

/// Acquires real fixed-view RGB-D evidence. This controller has no arm command
/// capability: model placement is an initializer, never a registration proof.
@MainActor @objcMembers final class ROBFixedHeadCalibrationWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ROBFixedHeadCalibrationWindowController()
    static let cameraDemandChanged = Notification.Name("ROBFixedHeadCalibrationCameraDemandDidChange")
    var readNeck: (() -> NSDictionary)?
    var holdCurrentView: (() -> Bool)?
    var cameraDemand: ((Bool) -> Void)?
    private(set) var isRunning = false
    private(set) var status = "Capture a fixed head view containing ROB's base and torso. Separate surface regions and later frames validate the fit."
    private(set) var lastCapturePath = ""
    private let side = NSPopUpButton()
    private let referenceError = NSTextField(string: "20")
    private let nearFieldDepth = NSButton(checkboxWithTitle: "Near-field body depth", target: nil, action: nil)
    private let fullCameraHeight = NSButton(checkboxWithTitle: "Full camera height (640 × 480)", target: nil, action: nil)
    private let holdCameraMode = NSButton(checkboxWithTitle: "Hold camera mode for review", target: nil, action: nil)
    private let image = NSImageView()
    private let details = NSTextView()
    private let captureButton = NSButton(title: "Capture + fit current head pose", target: nil, action: nil)
    private let captureOnlyButton = NSButton(title: "Capture RGB-D + IMU only", target:nil, action:nil)
    private let importButton = NSButton(title: "Import calibration evidence…", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop capture", target: nil, action: nil)
    @nonobjc private var task: Task<Void, Never>?
    @nonobjc private var process: Process?
    @nonobjc private var armOwner: UUID?
    private var captureBodyIdentity: String?
    private var activeCaptureID: UUID?
    private var cameraDemandCaptureID: UUID?
    private var cameraDemandResolution:String?
    private var cameraDemandStereoMode:String?
    @nonobjc private(set) var selectedEstimatedContext: ROBEstimatedFixedHeadCapture.Context?

    @nonobjc func currentEstimatedContext(model:ROBGhostRobotModel,frame:ROBArmRoutineVision.Frame) throws -> ROBEstimatedFixedHeadCapture.Context {
        let current = try scope(model:model,frame:frame)
        guard let context = selectedEstimatedContext,
              context.matches(currentScope:current,model:model),
              frame.intrinsics?.cameraServiceSourceSHA256 == context.cameraServiceSourceSHA256,
              frame.intrinsics?.rgbOutputUndistorted == true else {
            throw ROBGhostMotionError.blocked("The estimated neck/depth evidence does not match this exact held camera/body/arm context.")
        }
        return context
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Fixed-head camera-to-arm calibration"
        window.identifier = NSUserInterfaceItemIdentifier("fixed-head-registration")
        super.init(window: window)
        window.delegate = self
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
        nearFieldDepth.identifier = NSUserInterfaceItemIdentifier("fixed-head-near-field-depth")
        nearFieldDepth.toolTip = "Temporarily uses extended-disparity depth for nearby robot surfaces. Restores the previous camera demand after capture."
        root.addArrangedSubview(nearFieldDepth)
        fullCameraHeight.identifier = NSUserInterfaceItemIdentifier("fixed-head-full-camera-height")
        fullCameraHeight.toolTip = "Includes more of the scene above and below the usual crop, to help keep an object and ROB's body in one held view. Capture still requires fresh native depth and the selected dimensions."
        root.addArrangedSubview(fullCameraHeight)
        holdCameraMode.identifier = NSUserInterfaceItemIdentifier("fixed-head-hold-camera-mode")
        holdCameraMode.toolTip = "Keep this camera mode and source available after fitting or a diagnostic failure. Stop or close the window to restore ordinary camera demand."
        root.addArrangedSubview(holdCameraMode)
        let actions = NSStackView(); actions.spacing = 8
        captureButton.target = self; captureButton.action = #selector(captureCurrentView)
        captureButton.identifier = NSUserInterfaceItemIdentifier("fixed-head-capture-fit")
        captureOnlyButton.target=self;captureOnlyButton.action=#selector(captureOnly)
        captureOnlyButton.identifier=NSUserInterfaceItemIdentifier("fixed-head-capture-only")
        importButton.target = self; importButton.action = #selector(importLandmarks)
        stopButton.target = self; stopButton.action = #selector(stop)
        for b in [captureButton, captureOnlyButton, importButton, stopButton] { actions.addArrangedSubview(b) }
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
        captureOnlyButton.isEnabled = !isRunning
        side.isEnabled = !isRunning; referenceError.isEnabled = !isRunning
        nearFieldDepth.isEnabled = !isRunning
        fullCameraHeight.isEnabled = !isRunning
        holdCameraMode.isEnabled = !isRunning
        stopButton.isEnabled = isRunning || cameraDemandCaptureID != nil
        stopButton.title = isRunning ? "Stop capture" : "Stop camera review"
        NotificationCenter.default.post(name: Notification.Name("ROBFixedHeadRegistrationDidChange"), object: self)
    }

    @nonobjc static func intrinsicsIdentity(_ frame: ROBArmRoutineVision.Frame) throws -> String {
        guard let depth = frame.depth, let k = frame.intrinsics,
              k.isValid(forWidth: depth.width, height: depth.height) else {
            throw ROBGhostMotionError.blocked("Aligned depth and valid intrinsics are required.")
        }
        return try ROBFixedHeadRegistrationScope.cameraIntrinsicsIdentity(width: depth.width, height: depth.height,
            intrinsics: [k.fx,k.fy,k.cx,k.cy], stereoMode: k.stereoMode, stereoModeSource: k.stereoModeSource,
            extendedDisparity: k.stereoExtendedDisparity, subpixel: k.stereoSubpixel,
            runtimeCalibrationIdentity: k.runtimeCalibration?.identity)
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
        startCapture(fit:true)
    }
    @objc private func captureOnly() {startCapture(fit:false)}
    private func startCapture(fit:Bool) {
        guard !isRunning, task == nil else { return }
        // A held camera override is replaced atomically by beginCapture. An
        // OFF/ON roundtrip would unnecessarily restart the identical pipeline.
        let token = UUID(); activeCaptureID = token
        let keepModeForReview = holdCameraMode.state == .on
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.captureAndFit(token: token,fit:fit) }
            catch { self.display(error is CancellationError ? "Capture stopped; saved evidence retained." : error.localizedDescription) }
            self.finishCapture(token: token, holdModeForReview: keepModeForReview && !Task.isCancelled)
        }
    }
    private func beginCapture(token: UUID, stereoMode: String, resolution: String) throws {
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
        ROBArmRoutineVision.shared.setActive(true)
        cameraDemandCaptureID = token
        cameraDemandResolution=resolution;cameraDemandStereoMode=stereoMode
        NotificationCenter.default.post(name: Self.cameraDemandChanged, object: self,
            userInfo: ["active": true, "captureID": token.uuidString, "resolution": resolution, "stereoMode": stereoMode])
        display("Starting the RGB-D camera; waiting for fresh fixed-pose frames…")
    }
    private func releaseCameraDemand(token: UUID) {
        guard cameraDemandCaptureID == token else { return }
        cameraDemandCaptureID = nil
        cameraDemandResolution=nil;cameraDemandStereoMode=nil
        NotificationCenter.default.post(name: Self.cameraDemandChanged, object: self,
            userInfo: ["active": false, "captureID": token.uuidString])
    }
    private func finishCapture(token: UUID, holdModeForReview: Bool) {
        guard activeCaptureID == token else { return }
        // A rejected begin may still own the previous held review demand.
        // activeCaptureID above prevents stale tasks from clearing a newer one.
        let heldForReview = holdModeForReview && cameraDemandCaptureID != nil
        if !heldForReview,let demandToken=cameraDemandCaptureID {releaseCameraDemand(token:demandToken)}
        if let armOwner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: armOwner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: armOwner)
        }
        armOwner = nil; captureBodyIdentity = nil; activeCaptureID = nil; isRunning = false; task = nil; process = nil
        display(status + (heldForReview
            ? "\nCamera mode held for review. Stop restores ordinary camera mode. Holding the camera grants no registration or motion authority."
            : "\nOrdinary camera demand restored."))
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
    private func preservedCaptureSource(frame:ROBArmRoutineVision.Frame?,resolution:String,stereoMode:String)
        throws->ROBFixedHeadCaptureFrameGate.PreservedSource? {
        guard cameraDemandCaptureID != nil,cameraDemandResolution==resolution,cameraDemandStereoMode==stereoMode else{return nil}
        guard let frame,let depth=frame.depth,let k=frame.intrinsics,
              depth.width==640,depth.height==(resolution=="640x480" ? 480:400),
              k.isValid(forWidth:depth.width,height:depth.height),k.stereoMode==stereoMode,
              k.stereoModeSource=="sdk_initial_config_readback",k.stereoExtendedDisparity==(stereoMode=="near_field"),
              k.stereoSubpixel==(stereoMode=="standard"),let runtime=k.runtimeCalibration,runtime.cameraRole=="face",
              let service=k.cameraServiceSourceSHA256,service.count==64,service.allSatisfy(\.isHexDigit),
              frame.sequence>0,frame.capturedAt.isFinite else {
            throw ROBGhostMotionError.blocked("The held camera mode lacks its actual source/runtime readback. Wait for current native RGB-D frames; no pipeline reset was requested.")
        }
        return .init(cameraGeneration:frame.cameraGeneration,afterSequence:frame.sequence,afterCapturedAtMilliseconds:frame.capturedAt,
            runtimeCalibrationIdentity:runtime.identity,cameraServiceSourceSHA256:service)
    }
    private func captureAndFit(token: UUID,fit:Bool=true) async throws {
        guard let uncertainty = Double(referenceError.stringValue), (5...40).contains(uncertainty),
              let resources = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw ROBGhostMotionError.blocked("Use a CAD reference uncertainty between 5 and 40 mm; the bundled model must be available.")
        }
        let model = try ROBGhostRobotModel(directory: resources, physicalSide: side.indexOfSelectedItem == 0 ? "right" : "left")
        let stereoMode = nearFieldDepth.state == .on ? "near_field" : "standard"
        let fullHeight = fullCameraHeight.state == .on
        let resolution = fullHeight ? "640x480" : "640x400"
        let previousFrame=ROBArmRoutineVision.shared.snapshot()["face"]
        let previousCameraGeneration = previousFrame?.cameraGeneration
        let preservedSource=try preservedCaptureSource(frame:previousFrame,resolution:resolution,stereoMode:stereoMode)
        let requestedAtMilliseconds = Date().timeIntervalSince1970 * 1000
        try beginCapture(token: token, stereoMode: stereoMode, resolution: resolution)
        let expected = readNeck?() ?? [:]
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/FixedHeadRegistration/Captures")
        let destination = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lastCapturePath = destination.path
        var records: [[String: Any]] = [], firstScope: ROBFixedHeadRegistrationScope?
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        var frameGate = ROBFixedHeadCaptureFrameGate(requestedAtMilliseconds: requestedAtMilliseconds,
            previousCameraGeneration: previousCameraGeneration, stereoMode: stereoMode, fullHeight: fullHeight,preservedSource:preservedSource)
        while records.count < 5 {
            try checkPose(expected)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                let health = ROBArmRoutineVision.shared.healthSnapshot()
                var diagnostic = "No five fresh \(stereoMode) fixed-pose RGB-D frames arrived within 40 seconds.\n\(health)"
                if let current = ROBArmRoutineVision.shared.snapshot()["face"] {
                    diagnostic += "\nAnalyzed RGB: \(current.image.extent); depth: \(current.depth.map { "\($0.width)x\($0.height)" } ?? "missing"); usable depth: \(current.depthCoverage)"
                }
                try? diagnostic.write(to:destination.appendingPathComponent("capture-diagnostic.txt"),atomically:true,encoding:.utf8)
                throw ROBGhostMotionError.blocked(diagnostic)
            }
            guard let frame = ROBArmRoutineVision.shared.snapshot()["face"],
                  frame.depthCoverage > 0, let depth = frame.depth, let k = frame.intrinsics,
                  frameGate.accepts(cameraGeneration: frame.cameraGeneration, sequence: frame.sequence,
                    capturedAt: frame.capturedAt, nowMilliseconds: Date().timeIntervalSince1970*1000,
                    width: depth.width, height: depth.height, intrinsics: k) else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            // This fit consumes native depth and its native intrinsics. The
            // vision preview can be resized, and dark robot surfaces can be
            // sparse. Spatial support and held-out quality are decided by the
            // fitter, rather than a whole-image coverage/preview-size gate.
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
            var record: [String:Any] = ["depthPath": name + ".depth-u16le", "width": depth.width, "height": depth.height,
                "intrinsics": [k.fx,k.fy,k.cx,k.cy], "sequence": NSNumber(value: frame.sequence),
                "capturedAtMilliseconds": frame.capturedAt, "captureSHA256": ROBGhostRobotModel.hash(data),
                "cameraGeneration": frame.cameraGeneration.uuidString,
                "previewWidth":Int(frame.image.extent.width),"previewHeight":Int(frame.image.extent.height),
                "depthCoverage":frame.depthCoverage,
                "intrinsicsSource":k.calibrationSource ?? "unspecified",
                "depthAlignmentMethod":k.depthAlignmentMethod ?? "unspecified"]
            if let value = k.cameraServiceSourceSHA256 { record["cameraServiceSourceSHA256"] = value }
            if let value = k.runtimeCalibration {
                record["runtimeCalibration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                record["runtimeCalibrationIdentity"] = value.identity
            }
            if let value = k.rgbOutputUndistorted { record["rgbOutputUndistorted"] = value }
            if let imu = k.inertial {
                record["imu"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imu))
            }
            if let value = k.calibratedLensPosition { record["calibratedLensPosition"] = value }
            if let value = k.frameLensPosition { record["frameLensPosition"] = value }
            if let value = k.sourceSize { record["rgbSourceSize"] = value }
            if let value = k.sourceIntrinsics { record["rgbSourceIntrinsics"] = value }
            if let value = k.imageTransform { record["rgbImageTransform"] = value }
            if let value = k.depthIntrinsics { record["depthIntrinsics"] = value }
            if let value = k.depthIntrinsicsSource { record["depthIntrinsicsSource"] = value }
            if let value = k.depthSourceSize { record["depthSourceSize"] = value }
            if let value = k.depthSourceIntrinsics { record["depthSourceIntrinsics"] = value }
            if let value = k.depthImageTransform { record["depthImageTransform"] = value }
            if let value = k.depthRGBGeometryCorrespondence { record["depthRGBGeometryCorrespondence"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
            if let value = k.rgbTransformationSize { record["rgbTransformationSize"] = value }
            if let value = k.depthTransformationSize { record["depthTransformationSize"] = value }
            if let value = k.rgbSourceDistortionCoefficients { record["rgbSourceDistortionCoefficients"] = value }
            if let value = k.depthSourceDistortionCoefficients { record["depthSourceDistortionCoefficients"] = value }
            if let value = k.rgbSourceDistortionModel { record["rgbSourceDistortionModel"] = value }
            if let value = k.depthSourceDistortionModel { record["depthSourceDistortionModel"] = value }
            if let value = k.stereoMode { record["stereoMode"] = value }
            if let value = k.stereoModeSource { record["stereoModeSource"] = value }
            if let value = k.stereoExtendedDisparity { record["stereoExtendedDisparity"] = value }
            if let value = k.stereoSubpixel { record["stereoSubpixel"] = value }
            records.append(record)
            display("Captured \(records.count)/5 fixed-view frames. Head P\(scope.panTarget) L\(scope.lowerTarget) U\(scope.upperTarget). Arms unchanged.")
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scope = firstScope else { throw ROBGhostMotionError.blocked("Current head model initializer is unavailable.") }
        let initial: simd_double4x4
        let initializerSource: String
        if let fitted = ROBNeckRGBPoseDisplay.pose(model:model, panTarget:scope.panTarget,
            lowerTarget:scope.lowerTarget, upperTarget:scope.upperTarget) {
            // A better optimizer seed is not registration evidence. The CAD,
            // held-out depth, observability and uncertainty checks below stay
            // unchanged, and consume the original captured depth values.
            // The training initializer must never already contain the gravity
            // correction it is intended to independently estimate/validate.
            initial = fitted.unrefinedProvisionalCameraToModel
            initializerSource = fitted.usesPhotoHardwareOpticalOrigin
                ? "photo_mount_origin_unrefined_rgb_orientation_initializer_only" : "fitted_rgb_neck_candidate_unrefined_initializer_only"
        } else {
            guard let pan = expected["pan_degrees"] as? Double,
                  let pose = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians:pan * .pi / 180,
                    lowerTarget:scope.lowerTarget, upperTarget:scope.upperTarget, known:true),
                  let head = model.headPositions(pan:pose.panRadians, lowerPitch:pose.lowerPitch, upperPitch:pose.upperPitch),
                  let optical = model.frames(model.reference.merging(head) { _,new in new })["oak_optical_frame"],
                  let alignment = ROBWorkspaceDepthAlignment.snapshot() else {
                throw ROBGhostMotionError.blocked("Current head model initializer is unavailable.")
            }
            initial = alignment.applying(to:optical)
            initializerSource = "legacy_neck_prior_initializer_only"
        }
        let scopeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope))
        let input: [String: Any] = ["schemaVersion":1, "scope":scopeJSON, "cameraRole":"face", "requestedStereoMode":stereoMode,
            "validRobotVolume":["lowMeters":[-0.65,-0.95,0.05],"highMeters":[1.20,0.95,1.60]],
            "referenceUncertaintyMeters":uncertainty/1000,
            "initialCameraToRobotColumnMajor":(0..<4).flatMap { col in (0..<4).map { initial[col][$0] } },
            "initialCameraToRobotSource":initializerSource, "frames":records]
        let inputURL = destination.appendingPathComponent("capture-input.json"), outputURL = destination.appendingPathComponent("registration-input.json")
        try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted,.sortedKeys]).write(to: inputURL, options: .atomic)
        try checkPose(expected)
        if !fit {
            display("Saved five native RGB-D + IMU observations at P\(scope.panTarget) L\(scope.lowerTarget) U\(scope.upperTarget). No torso fit, registration installation or arm movement.\n\(inputURL.path)")
            return
        }
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
        display("Measured registration saved for its recorded camera mode. This does not authorize arm movement.\n" + (String(data: pretty, encoding: .utf8) ?? ""))
    }
    @objc private func importLandmarks() {
        guard !isRunning else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000 else { throw ROBGhostMotionError.blocked("Measured landmark file exceeds 2 MB.") }
            let kind = (try JSONSerialization.jsonObject(with:data) as? [String:Any])?["kind"] as? String
            guard let resources = Bundle.main.url(forResource:"ShadowPlanner",withExtension:nil),
                  let frame = ROBArmRoutineVision.shared.snapshot()["face"],
                  (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt) else {
                throw ROBGhostMotionError.blocked("Start a current fixed-view camera capture before importing measurements.")
            }
            let model = try ROBGhostRobotModel(directory:resources,physicalSide:side.indexOfSelectedItem == 0 ? "right" : "left")
            let current = try scope(model:model,frame:frame)
            if kind == "estimated_fixed_head_raw_corrected_union" {
                selectedEstimatedContext = nil
                let evidenceRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro",isDirectory:true)
                guard let service = Bundle.main.url(forResource:"Webcam_color",withExtension:"py") else {
                    throw ROBGhostMotionError.blocked("The installed camera-service source is unavailable for pixel-model verification.")
                }
                let serviceSHA = ROBGhostRobotModel.hash(try Data(contentsOf:service))
                let context = try ROBEstimatedFixedHeadCapture.load(packageURL:url,model:model,expectedScope:current,
                    evidenceRoot:evidenceRoot,verifiedCameraServiceSourceSHA256:[serviceSHA])
                selectedEstimatedContext = context
                ROBWorkspaceSearch.shared.depthAlignmentDidChange()
                display("Estimated fixed-head evidence loaded for the EMPTY right-arm probe only. Raw and corrected returns will both remain occupied. This does not authorize motion or enable grasping.\n" + context.metadata.description)
                return
            }
            _ = try JSONDecoder().decode(ROBFixedHeadRegistrationInput.self,from:data)
            let registration = try ROBFixedHeadRegistrationStore.shared.load(url,scope:current)
            selectedEstimatedContext = nil
            display("Measured landmark fit installed for the current recorded pose.\n\(registration)")
        } catch { display(error.localizedDescription) }
    }
    @objc func stop() {
        task?.cancel(); if process?.isRunning == true { process?.terminate() }
        if let token = cameraDemandCaptureID {
            releaseCameraDemand(token: token)
            if !isRunning { display("Camera review ended; ordinary camera demand restored.") }
        }
    }
    func windowWillClose(_ notification: Notification) { stop() }
    @objc private func bodyDidMove() {
        selectedEstimatedContext = nil
        stop()
        ROBWorkspaceSearch.shared.depthAlignmentDidChange()
        display("The body moved. Recorded fixed-head registrations are no longer current; capture a new view before arm travel.")
    }
    @objc private func showEvidence() {
        guard !lastCapturePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:lastCapturePath)])
    }
}
