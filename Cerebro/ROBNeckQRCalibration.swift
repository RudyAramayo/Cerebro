import AppKit
import Vision
import simd

/// Known-size QR capture and neck-only commissioning. It never activates an
/// arm, changes jaw calibration, or promotes a fit to actuator registration.
@MainActor @objcMembers final class ROBNeckQRCalibration: NSObject {
    static let shared = ROBNeckQRCalibration()
    private(set) var isRunning = false
    private(set) var status = "Ready for the fixed 120 mm ROB:TABLE:001 target."
    private(set) var lastCapturePath = ""
    var readNeck: (() -> NSDictionary)?
    var cameraDemand: ((Bool) -> Void)?
    var prepareView: ((Double, Int) -> Bool)?
    var viewReady: ((Double, Int) -> Bool)?
    var canUseView: ((Double, Int) -> Bool)?
    var boundedPan: ((Double) -> Double)?
    @nonobjc private var task: Task<Void, Never>?
    @nonobjc private var fitTask: Task<Data, Error>?
    @nonobjc private var owner: UUID?
    @nonobjc private var captureAnchor = ROBWorkspaceCaptureAnchor()
    @nonobjc private var views: [[String: Any]] = []
    @nonobjc private var folder: URL?
    @nonobjc private var frameSequence: UInt64 = 0

    private func update(_ text: String) {
        status = text
        NotificationCenter.default.post(name: Notification.Name("ROBNeckQRCalibrationDidChange"), object: self)
    }
    private func begin() throws {
        guard !isRunning, !ROBLeftArmTrial.shared.isRunning,
              !ROBArmRoutineCoordinator.shared.isRunning, !ROBShowMotionCoordinator.shared.isRunning,
              !ROBAmberGestureExecutor.shared.isExecuting, !ROBControllerArmApproval.shared.isPending,
              !ROBGripperStartupCalibration.shared.isRunning else {
            throw ROBGhostMotionError.blocked("Finish the current operation before QR calibration.")
        }
        let id = UUID()
        guard ROBAmberArmMotionArbiter.shared.reserve(.left, owner: id) else {
            throw ROBGhostMotionError.blocked("An arm is owned by another operation.")
        }
        guard ROBAmberArmMotionArbiter.shared.reserve(.right, owner: id) else {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: id)
            throw ROBGhostMotionError.blocked("An arm is owned by another operation.")
        }
        owner = id; isRunning = true; frameSequence = 0
        captureAnchor = ROBWorkspaceCaptureAnchor()
        ROBArmRoutineVision.shared.setActive(true)
        cameraDemand?(true)
    }
    private func finish() {
        ROBArmRoutineVision.shared.setActive(false); cameraDemand?(false)
        if let owner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: owner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: owner)
        }
        owner = nil; task = nil; isRunning = false
        NotificationCenter.default.post(name: Notification.Name("ROBNeckQRCalibrationDidChange"), object: self)
    }
    private func newCapture(model: ROBGhostRobotModel) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cerebro/NeckQRCalibration", isDirectory: true)
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        folder = destination; views = []; lastCapturePath = destination.path
        try save(model: model)
    }
    private func save(model: ROBGhostRobotModel) throws {
        guard let folder else { return }
        let payload: [String: Any] = ["schemaVersion": 1, "targetID": ROBNeckQRMeasurement.targetID,
            "symbolSideMeters": ROBNeckQRMeasurement.symbolSideMeters,
            "targetSizeSource": "120 mm printed calibration sheet", "poseSource": "accepted_neck_commands",
            "modelID": model.modelID, "geometryID": model.geometryID,
            "registrationVerified": false, "views": views]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("capture.json"), options: .atomic)
    }
    private func model() throws -> ROBGhostRobotModel {
        guard let directory = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw ROBGhostMotionError.blocked("The bundled robot model is missing.")
        }
        return try ROBGhostRobotModel(directory: directory)
    }
    @nonobjc private func neck() throws -> (pan: Double, lower: Int, upper: Int, readyAt: Double) {
        guard let state = readNeck?(), state["known"] as? Bool == true,
              let pan = state["pan_degrees"] as? Double, pan.isFinite,
              let lower = state["lower"] as? Int, let upper = state["upper"] as? Int,
              let readyAt = state["ready_at"] as? Double, readyAt.isFinite else {
            throw ROBGhostMotionError.blocked("Accepted, settled neck targets are unavailable.")
        }
        return (pan, lower, upper, readyAt)
    }
    private func check() throws {
        try Task.checkCancellation()
        guard isRunning, captureAnchor.permitsCurrent(ROBArmRoutineVision.shared.cameraGeneration) else {
            throw ROBGhostMotionError.blocked("Camera identity changed; start a fresh QR capture.")
        }
    }
    @nonobjc private func observe(model: ROBGhostRobotModel, poseID: String, training: Bool,
                                 after minimumCapture: Double) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var accepted = 0
        while accepted < 3 {
            try check()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ROBGhostMotionError.blocked("The 120 mm QR target was not readable in this settled view. Captured views were saved.")
            }
            let pose = try neck()
            guard ProcessInfo.processInfo.systemUptime >= pose.readyAt else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            guard let frame = ROBArmRoutineVision.shared.snapshot()["face"],
                  frame.sequence > frameSequence, frame.capturedAt >= minimumCapture,
                  (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
                  let depth = frame.depth, let k = frame.intrinsics,
                  k.isValid(forWidth: depth.width, height: depth.height) else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            let imageAspect = frame.image.extent.width/frame.image.extent.height
            let depthAspect = Double(depth.width)/Double(depth.height)
            guard imageAspect.isFinite, abs(Double(imageAspect)/depthAspect-1) < 0.02 else {
                throw ROBGhostMotionError.blocked("RGB and aligned depth have different framing; QR pixel correspondence is unavailable.")
            }
            guard captureAnchor.accept(frameGeneration: frame.cameraGeneration,
                                      currentGeneration: ROBArmRoutineVision.shared.cameraGeneration) else {
                throw ROBGhostMotionError.blocked("The QR frame belongs to a replaced camera stream.")
            }
            let capturedUptime = ProcessInfo.processInfo.systemUptime -
                (Date().timeIntervalSince1970*1000-frame.capturedAt)/1000
            guard capturedUptime >= pose.readyAt else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            frameSequence = frame.sequence
            let corners: [SIMD2<Double>]? = try await Task.detached(priority: .userInitiated) {
                let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                try VNImageRequestHandler(ciImage: frame.image, orientation: .up, options: [:]).perform([request])
                guard let target = request.results?.first(where: { $0.payloadStringValue == ROBNeckQRMeasurement.targetID }) else { return nil }
                return [target.topLeft, target.topRight, target.bottomRight, target.bottomLeft].map {
                    SIMD2(Double($0.x), Double($0.y))
                }
            }.value
            try check()
            let current = try neck()
            guard current.lower == pose.lower, current.upper == pose.upper,
                  abs(current.pan-pose.pan) < 0.01, abs(current.readyAt-pose.readyAt) < 0.000001 else {
                throw ROBGhostMotionError.blocked("The neck changed during QR detection; the sample was not accepted.")
            }
            guard let corners else { continue }
            guard let estimate = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: pose.pan * .pi / 180,
                    lowerTarget: pose.lower, upperTarget: pose.upper, known: true),
                  let joints = model.headPositions(pan: estimate.panRadians, lowerPitch: estimate.lowerPitch,
                                                  upperPitch: estimate.upperPitch) else { continue }
            let transforms = model.frames(model.reference.merging(joints) { _, new in new })
            guard let optical = transforms["oak_optical_frame"], let neckFrame = transforms["upper_neck_link"] else {
                throw ROBGhostMotionError.blocked("Raw neck/camera model transforms are missing.")
            }
            let center = try ROBNeckQRMeasurement.centerNormalized(of: corners)
            let x = Int(center.x * Double(depth.width)), y = Int((1-center.y) * Double(depth.height))
            var depths: [Double] = []
            for dy in -3...3 { for dx in -3...3 {
                if let value = depth.distanceMillimeters(x: x+dx, y: y+dy), (150...5000).contains(value) {
                    depths.append(Double(value)/1000)
                }
            } }
            depths.sort()
            let measurement = try ROBNeckQRMeasurement.make(cornersNormalized: corners, depthWidth: depth.width,
                depthHeight: depth.height, intrinsics: [k.fx,k.fy,k.cx,k.cy], opticalToBase: optical,
                baseToNeck: neckFrame, capturedAtMilliseconds: frame.capturedAt, sequence: frame.sequence,
                neckPanDegrees: pose.pan, neckUpperTarget: pose.upper,
                centerDepthMeters: depths.count >= 8 ? depths[depths.count/2] : nil)
            var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(measurement)) as! [String: Any]
            record["id"] = "\(poseID)-\(accepted)"; record["training"] = training
            record["imageSize"] = [depth.width, depth.height]; record["lowerTarget"] = pose.lower
            record["intrinsicsSource"] = k.calibrationSource ?? "unspecified"
            if let value = k.calibratedLensPosition { record["calibratedLensPosition"] = value }
            if let value = k.frameLensPosition { record["frameLensPosition"] = value }
            if depths.count >= 8 { record["centerDepthMeters"] = depths[depths.count/2] }
            if let folder {
                let name = "\(poseID)-\(accepted)"
                let image = frame.image
                let destination = folder
                try await Task.detached(priority: .utility) {
                    let context = CIContext(options: [.useSoftwareRenderer: true])
                    guard let cg = context.createCGImage(image, from: image.extent),
                          let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
                        throw ROBGhostMotionError.blocked("The QR source image could not be saved; the sample was not accepted.")
                    }
                    try jpeg.write(to: destination.appendingPathComponent(name+".jpg"), options: .atomic)
                    try depth.millimetersLittleEndian.write(to: destination.appendingPathComponent(name+".depth-u16le"), options: .atomic)
                }.value
            }
            try check()
            views.append(record); try save(model: model); accepted += 1
            update("I see ROB:TABLE:001. \(views.count) synchronized samples saved; 120 mm target. Arms unchanged.")
        }
    }
    func captureCurrentView() {
        do {
            try begin()
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.finish() }
                do {
                    let model = try self.model(); try self.newCapture(model: model)
                    self.update("Reading the fixed 120 mm QR in the current settled neck view.")
                    let after = Date().timeIntervalSince1970*1000
                    try await self.observe(model: model, poseID: "reference", training: true, after: after)
                    self.update("QR confirmed: 120 mm ROB:TABLE:001. Three reference frames saved. Ready for the neck sweep.")
                } catch { self.update(error.localizedDescription) }
            }
        } catch { update(error.localizedDescription) }
    }
    func runSweep() {
        do {
            try begin()
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.finish() }
                do {
                    let model = try self.model(); try self.newCapture(model: model)
                    // Start at the existing table-inspection view, rather
                    // than preserving a greeting gaze above the workbench.
                    var upper = 6306
                    var pan = self.boundedPan?(0) ?? 0
                    let offsets: [(Double, Int, Bool)] = [(0,0,true),(-10,0,true),(-10,-150,true),
                        (0,-150,false),(10,-150,true),(10,0,true),(10,150,false),
                        (0,150,true),(-10,150,true),(-5,-75,false),(5,75,true),(0,0,false)]
                    for (index, item) in offsets.enumerated() {
                        try self.check()
                        let p = self.boundedPan?(pan+item.0) ?? pan+item.0, u = upper+item.1
                        guard self.canUseView?(p,u) == true else {
                            throw ROBGhostMotionError.blocked("The calibration view is outside the active neck range.")
                        }
                        self.update("Neck calibration view \(index+1)/\(offsets.count). Waiting for the camera to settle.")
                        let deadline = ProcessInfo.processInfo.systemUptime+12
                        while self.viewReady?(p,u) != true {
                            try self.check()
                            guard ProcessInfo.processInfo.systemUptime < deadline else {
                                throw ROBGhostMotionError.blocked("The neck did not settle at the calibration view.")
                            }
                            _ = self.prepareView?(p,u)
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        guard self.viewReady?(p,u) == true else {
                            throw ROBGhostMotionError.blocked("The neck view changed during settling.")
                        }
                        try await self.observe(model: model, poseID: "view-\(index)", training: item.2,
                            after: Date().timeIntervalSince1970*1000)
                        if index == 0, let first = self.views.last,
                           let center = first["centerPixel"] as? [Double], center.count == 2,
                           let k = first["cameraMatrix"] as? [Double], k.count == 4 {
                            // Center the remaining small sweep on the observed
                            // marker so it stays visible as pan and tilt vary.
                            let yaw = atan((center[0]-k[2])/k[0])*180 / .pi
                            let pitch = atan((center[1]-k[3])/k[1])*180 / .pi
                            pan = self.boundedPan?(p-yaw) ?? p-yaw
                            upper = max(5450, min(7300, u-Int((pitch*33.3333333333).rounded())))
                        }
                    }
                    self.update("Neck sweep complete: \(self.views.count) samples, with separate validation views. Fit recorded views next.")
                } catch { self.update(error.localizedDescription) }
            }
        } catch { update(error.localizedDescription) }
    }
    func fitLastCapture() {
        guard !isRunning, let folder else { update("Capture the fixed QR before fitting."); return }
        isRunning = true; update("Fitting the recorded neck/camera transform offline.")
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.task = nil; self.fitTask = nil; self.update(self.status) }
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> Data in
                    guard let resources = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
                        throw ROBGhostMotionError.blocked("The calibration worker is missing.")
                    }
                    let args = [resources.appendingPathComponent("qr_neck_calibration.py").path,
                        folder.appendingPathComponent("capture.json").path, folder.appendingPathComponent("fit.json").path]
                    let process = try ROBPythonRuntime.shared.newTask(withArguments: args)
                    let logURL = folder.appendingPathComponent("fit.log")
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                    let log = try FileHandle(forWritingTo: logURL)
                    defer { try? log.close() }
                    process.standardOutput = log; process.standardError = log
                    let completed = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in completed.signal() }
                    try process.run()
                    let deadline = ProcessInfo.processInfo.systemUptime+25
                    while completed.wait(timeout: .now()+0.1) == .timedOut {
                        if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                            if process.isRunning { process.terminate() }
                            throw ROBGhostMotionError.blocked("QR fitting stopped or exceeded its 25 second limit.")
                        }
                    }
                    guard process.terminationStatus == 0 else {
                        let bytes = try Data(contentsOf: logURL)
                        throw ROBGhostMotionError.blocked(String(data: bytes, encoding: .utf8) ?? "QR fit failed.")
                    }
                    return try Data(contentsOf: folder.appendingPathComponent("fit.json"))
                }
                self.fitTask = worker
                let result = try await worker.value
                try Task.checkCancellation()
                let report = try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:]
                let training = (report["trainingTranslationRMSEMeters"] as? Double ?? .nan)*1000
                let validation = (report["heldOutTranslationRMSEMeters"] as? Double ?? .nan)*1000
                self.update(String(format: "QR fit saved. Training drift %.1f mm; held-out drift %.1f mm. Registration remains unverified.\n%@", training, validation, folder.path))
            } catch { self.update(error.localizedDescription) }
        }
    }
    func openLastCapture() {
        if !lastCapturePath.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: lastCapturePath, isDirectory: true)) }
    }
    func stop() {
        task?.cancel(); fitTask?.cancel()
        update(isRunning ? "Stopping calibration; no additional neck targets will be sent." : "QR calibration stopped.")
    }
}
