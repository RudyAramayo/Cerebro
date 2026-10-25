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
    var prepareCalibrationView: ((Double, Int, Int) -> Bool)?
    var calibrationViewAllowed: ((Double, Int, Int) -> Bool)?
    var calibrationViewReady: ((Double, Int, Int) -> Bool)?
    private(set) var selectedTargetID = ROBNeckQRMeasurement.targetID
    private(set) var awaitingProtractor = false
    @nonobjc private var task: Task<Void, Never>?
    @nonobjc private var fitTask: Task<Data, Error>?
    @nonobjc private var owner: UUID?
    @nonobjc private var captureAnchor = ROBWorkspaceCaptureAnchor()
    @nonobjc private var views: [[String: Any]] = []
    @nonobjc private var folder: URL?
    @nonobjc private var frameSequence: UInt64 = 0
    @nonobjc private var firstDeliveredFreshFrameTimestamp: Double?
    private static let initialCameraWarmupMilliseconds = 1000.0
    // Local floor visibility prediction only; never a servo calibration gain.
    private static let floorVisibilityUpperTargetsPerLowerTarget = 0.823
    @nonobjc private var captureKind = "reference"
    @nonobjc private var stepContext: [String: Any] = [:]
    @nonobjc private var protractorReadings: [[String: Any]] = []
    @nonobjc private var advanceRequested = false
    @nonobjc private var captureDisplayCorrection: ROBWorkspaceDepthAlignment.Snapshot?
    @nonobjc private var surveySessionID: String?
    private struct SurveySeed {
        let targetID: String
        let pan: Double
        let lower: Int
        let upper: Int
        let score: Double
        let center: SIMD2<Double>
        let intrinsics: [Double]
        let evidence: String
    }
    private enum QRObservationError: LocalizedError {
        case unreadable
        var errorDescription: String? {
            "The 120 mm QR target was not readable in this settled view. Captured views were saved."
        }
    }

    func selectTarget(_ identifier: String) {
        guard !isRunning, ROBNeckQRMeasurement.supportedTargetIDs.contains(identifier) else { return }
        selectedTargetID = identifier
        update("Selected \(identifier), 120 mm. Keep this target and ROB fixed during a capture.")
    }

    private func update(_ text: String) {
        status = text
        NotificationCenter.default.post(name: Notification.Name("ROBNeckQRCalibrationDidChange"), object: self)
    }
    private func report(_ error: Error) {
        update(error is CancellationError ? "QR calibration stopped. Captured samples are saved." : error.localizedDescription)
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
        owner = id; isRunning = true; frameSequence = 0; surveySessionID = nil
        firstDeliveredFreshFrameTimestamp = nil
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
        owner = nil; task = nil; isRunning = false; awaitingProtractor = false
        NotificationCenter.default.post(name: Notification.Name("ROBNeckQRCalibrationDidChange"), object: self)
    }
    private func newCapture(model: ROBGhostRobotModel, kind: String = "reference") throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cerebro/NeckQRCalibration", isDirectory: true)
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        folder = destination; views = []; lastCapturePath = destination.path
        UserDefaults.standard.set(destination.path, forKey: "ROBNeckQRLastCapturePath")
        captureKind = kind; stepContext = [:]; protractorReadings = []
        captureDisplayCorrection = ROBWorkspaceDepthAlignment.snapshot()
        try save(model: model)
    }
    private func save(model: ROBGhostRobotModel) throws {
        guard let folder else { return }
        var payload: [String: Any] = ["schemaVersion": 1, "targetID": selectedTargetID,
            "symbolSideMeters": ROBNeckQRMeasurement.symbolSideMeters,
            "targetSizeSource": "120 mm printed calibration sheet", "poseSource": "accepted_neck_commands",
            "modelID": model.modelID, "geometryID": model.geometryID,
            "registrationVerified": false, "views": views, "captureKind": captureKind,
            "initialCameraWarmupMilliseconds": Self.initialCameraWarmupMilliseconds,
            "initialCameraWarmupPolicy": "fixed_interval_from_first_delivered_fresh_frame_not_proven_exposure_stability",
            "protractorReadings": protractorReadings]
        if let firstDeliveredFreshFrameTimestamp {
            payload["firstDeliveredFreshFrameTimestampMilliseconds"] = firstDeliveredFreshFrameTimestamp
        }
        if selectedTargetID.hasPrefix("ROB:FLOOR:") {
            payload["floorVisibilityPrediction"] = ["upperTargetsPerLowerTarget":Self.floorVisibilityUpperTargetsPerLowerTarget,
                "purpose":"empirical_visibility_prediction_not_calibration","registrationVerified":false] as [String:Any]
        }
        if let correction = captureDisplayCorrection {
            payload["displayDepthCorrection"] = ["towardRobotMeters": correction.towardRobotMeters,
                "downwardPitchDegrees": correction.downwardPitchDegrees, "identity": correction.identity]
        }
        if let surveySessionID {
            payload["surveySessionID"] = surveySessionID
            payload["sceneContextID"] = surveySessionID
            payload["trainingPolicy"] = "stable_actual_pose_hash_mod3"
        }
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
        guard ROBWorkspaceDepthAlignment.snapshot() == captureDisplayCorrection else {
            throw ROBGhostMotionError.blocked("The display depth correction changed during calibration; start a fresh capture.")
        }
    }
    private func checkRequestedPose() throws {
        guard let pan = stepContext["requestedPanDegrees"] as? Double,
              let lower = stepContext["requestedLowerTarget"] as? Int,
              let upper = stepContext["requestedUpperTarget"] as? Int else { return }
        guard calibrationViewReady?(pan, lower, upper) == true else {
            throw ROBGhostMotionError.blocked("The neck moved away from the requested calibration hold. The step was not accepted.")
        }
    }
    /// A fixed startup interval, not an auto-exposure stability detector. Start
    /// at an actual delivered fresh frame, since camera launch can take seconds.
    @nonobjc private func cameraWarmupComplete(_ capturedAt: Double) -> Bool {
        if firstDeliveredFreshFrameTimestamp == nil { firstDeliveredFreshFrameTimestamp = capturedAt }
        return capturedAt >= firstDeliveredFreshFrameTimestamp! + Self.initialCameraWarmupMilliseconds
    }
    @nonobjc private func observe(model: ROBGhostRobotModel, poseID: String, training: Bool,
                                 after minimumCapture: Double) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + (firstDeliveredFreshFrameTimestamp == nil ? 15 : 8)
        var accepted = 0, eligibleFreshFrames = 0
        while accepted < 3 {
            try check()
            try checkRequestedPose()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                guard eligibleFreshFrames > 0 else {
                    throw ROBGhostMotionError.blocked("Camera unavailable: no eligible fresh RGB/depth frames arrived after startup warmup. QR visibility was not evaluated.")
                }
                throw QRObservationError.unreadable
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
            guard cameraWarmupComplete(frame.capturedAt) else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            eligibleFreshFrames += 1
            let expectedTarget = selectedTargetID
            let corners: [SIMD2<Double>]? = try await Task.detached(priority: .userInitiated) {
                let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                try VNImageRequestHandler(ciImage: frame.image, orientation: .up, options: [:]).perform([request])
                guard let target = request.results?.first(where: { $0.payloadStringValue == expectedTarget }) else { return nil }
                return [target.topLeft, target.topRight, target.bottomRight, target.bottomLeft].map {
                    SIMD2(Double($0.x), Double($0.y))
                }
            }.value
            try check()
            try checkRequestedPose()
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
            let measurement = try ROBNeckQRMeasurement.make(payload: expectedTarget, cornersNormalized: corners, depthWidth: depth.width,
                depthHeight: depth.height, intrinsics: [k.fx,k.fy,k.cx,k.cy], opticalToBase: optical,
                baseToNeck: neckFrame, capturedAtMilliseconds: frame.capturedAt, sequence: frame.sequence,
                neckPanDegrees: pose.pan, neckUpperTarget: pose.upper,
                centerDepthMeters: depths.count >= 8 ? depths[depths.count/2] : nil)
            var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(measurement)) as! [String: Any]
            record["id"] = "\(poseID)-\(accepted)"
            record["training"] = surveySessionID == nil ? training : Self.poseTraining(pan: pose.pan, lower: pose.lower, upper: pose.upper)
            record["imageSize"] = [depth.width, depth.height]; record["lowerTarget"] = pose.lower
            record.merge(stepContext) { _, new in new }
            record["intrinsicsSource"] = k.calibrationSource ?? "unspecified"
            if let value = k.cameraServiceSourceSHA256 { record["cameraServiceSourceSHA256"] = value }
            if let value = k.runtimeCalibration {
                record["runtimeCalibration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                record["runtimeCalibrationIdentity"] = value.identity
            }
            if let value = k.stereoMode { record["stereoMode"] = value }
            if let value = k.stereoModeSource { record["stereoModeSource"] = value }
            if let value = k.stereoExtendedDisparity { record["stereoExtendedDisparity"] = value }
            if let value = k.stereoSubpixel { record["stereoSubpixel"] = value }
            if let value = k.rgbOutputUndistorted { record["rgbOutputUndistorted"] = value }
            if let value = k.calibratedLensPosition { record["calibratedLensPosition"] = value }
            if let value = k.frameLensPosition { record["frameLensPosition"] = value }
            if let value = k.sourceSize { record["rgbSourceSize"] = value }
            if let value = k.sourceIntrinsics { record["rgbSourceIntrinsics"] = value }
            if let value = k.imageTransform { record["rgbImageTransform"] = value }
            record["depthAlignmentMethod"] = k.depthAlignmentMethod ?? "unspecified"
            if let imu = k.inertial {
                record["imu"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imu))
            }
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
            update("I see \(selectedTargetID). P \(String(format: "%.2f", pose.pan))°, L \(pose.lower), U \(pose.upper). \(views.count) samples saved.")
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
                    self.update("QR confirmed: 120 mm \(self.selectedTargetID). Three reference frames saved.")
                } catch { self.report(error) }
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
                    let model = try self.model(); try self.newCapture(model: model, kind: "pan_upper_sweep")
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
                } catch { self.report(error) }
            }
        } catch { update(error.localizedDescription) }
    }
    /// Isolate upper motion, then revisit interior targets from both directions.
    /// The protractor variant holds indefinitely at each captured position.
    func runUpperNeckCheck() { runMeasuredSweep(protractor: false, postures: false) }
    func startProtractorCheck() { runMeasuredSweep(protractor: true, postures: false) }
    func runPostureSweep() { runMeasuredSweep(protractor: false, postures: true) }

    /// Use actual accepted pose keys consistently across markers and segments.
    /// Repeated center holds must never leak between training and validation.
    @nonobjc private static func poseTraining(pan: Double, lower: Int, upper: Int) -> Bool {
        let key = String(format: "%.6f|%d|%d", pan, lower, upper)
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return hash % 3 != 2
    }

    private func writeSurvey(_ manifest: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("survey.json"), options: .atomic)
        UserDefaults.standard.set(directory.path, forKey:"ROBNeckQRLastSurveyPath")
    }

    /// Command hints only. A hint never supplies a world coordinate or a
    /// current observation; two new frames must reconfirm its actual ID.
    @nonobjc private func cachedSurveySeeds(_ identifiers: [String]) -> [SurveySeed] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cerebro/NeckQRCalibration/SurveySessions",isDirectory:true)
            .resolvingSymlinksInPath()
        var directories: [URL] = []
        if let path = UserDefaults.standard.string(forKey:"ROBNeckQRLastSurveyPath") {
            directories.append(URL(fileURLWithPath:path,isDirectory:true))
        }
        let existing = (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
        directories += existing.sorted {
            ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var result: [String:SurveySeed] = [:]
        for directory in directories {
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root.path+"/"),
                  let data = try? Data(contentsOf:directory.appendingPathComponent("survey.json")), data.count < 2_000_000,
                  let manifest = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let seeds = manifest["seeds"] as? [[String:Any]] else { continue }
            for value in seeds {
                guard let id = value["targetID"] as? String, identifiers.contains(id), result[id] == nil,
                      let pan = value["panDegrees"] as? Double, pan.isFinite, abs(pan) <= 70,
                      let lower = value["lowerTarget"] as? Int,
                      (5811...Int(ROBNeckSafetyForwardOverlookLowerMaximumTarget)).contains(lower),
                      let upper = value["upperTarget"] as? Int, (5300...7500).contains(upper),
                      let name = value["evidence"] as? String, !name.contains("/"), !name.contains(".."),
                      let evidence = try? Data(contentsOf:directory.appendingPathComponent(name)),
                      let record = try? JSONSerialization.jsonObject(with:evidence) as? [String:Any],
                      let k = record["cameraMatrix"] as? [Double], k.count == 4, k.allSatisfy(\.isFinite),
                      let detections = record["detections"] as? [[String:Any]],
                      let detection = detections.first(where:{ $0["targetID"] as? String == id }),
                      let center = detection["centerNormalized"] as? [Double], center.count == 2 else { continue }
                result[id] = SurveySeed(targetID:id,pan:pan,lower:lower,upper:upper,
                    score:value["score"] as? Double ?? 0,center:SIMD2(center[0],center[1]),intrinsics:k,evidence:name)
            }
            if result.count == identifiers.count { break }
        }
        return Array(result.values)
    }

    @nonobjc private func verifySeed(_ hint: SurveySeed, directory: URL, index: inout Int) async throws -> SurveySeed? {
        stepContext = ["requestedPanDegrees":hint.pan,"requestedLowerTarget":hint.lower,"requestedUpperTarget":hint.upper]
        try await settleCalibration(pan:hint.pan,lower:hint.lower,upper:hint.upper)
        let found = try await discoverTargets(directory:directory,index:index)
        index += 1
        return found.first(where:{ $0.targetID == hint.targetID })
    }

    @nonobjc private func predictedFloorUpper(anchorLower: Int, anchorUpper: Int, lower: Int) -> Int {
        max(5300,min(7500,anchorUpper+Int((Self.floorVisibilityUpperTargetsPerLowerTarget*Double(lower-anchorLower)).rounded())))
    }

    @nonobjc private func floorForwardTargets(_ targetID: String, pan: Double, referenceLower: Int, upper: Int) -> [Int] {
        var candidates = [6111,6186]
        if targetID.hasPrefix("ROB:FLOOR:") {
            candidates += [6261,6495,Int(ROBNeckSafetyForwardOverlookLowerMaximumTarget)]
        }
        return candidates.filter {
            calibrationViewAllowed?(pan,$0,predictedFloorUpper(anchorLower:referenceLower,anchorUpper:upper,lower:$0)) == true
        }
    }

    /// Peek past a hanging arm at fixed pan, predicting upper pitch to retain
    /// framing. These raw commands do not assert measured shaft angles.
    @nonobjc private func verifyFloorForward(_ targetID: String, pan: Double, referenceLower: Int, upper: Int,
                                             directory: URL, index: inout Int) async throws -> SurveySeed? {
        var best: SurveySeed?
        for lower in floorForwardTargets(targetID,pan:pan,referenceLower:referenceLower,upper:upper) {
            try check()
            let predictedUpper = predictedFloorUpper(anchorLower:referenceLower,anchorUpper:upper,lower:lower)
            guard calibrationViewAllowed?(pan,lower,predictedUpper) == true else { continue }
            stepContext = ["requestedPanDegrees":pan,"requestedLowerTarget":lower,
                           "requestedUpperTarget":predictedUpper,"floorForwardPeek":true,
                           "floorVisibilityAnchorLower":referenceLower,"floorVisibilityAnchorUpper":upper,
                           "floorVisibilityUpperTargetsPerLowerTarget":Self.floorVisibilityUpperTargetsPerLowerTarget,
                           "floorVisibilityPredictionOnly":true]
            update("Finding \(targetID): forward neck peek L \(lower), predicted U \(predictedUpper), same pan.")
            try await settleCalibration(pan:pan,lower:lower,upper:predictedUpper)
            let found = try await discoverTargets(directory:directory,index:index)
            index += 1
            if let measured = found.first(where: { $0.targetID == targetID }) {
                if let previous = best {
                    if measured.lower > previous.lower || (measured.lower == previous.lower && measured.score > previous.score) {
                        best = measured
                    }
                } else { best = measured }
            }
        }
        return best
    }

    /// Discovery is separate from metric capture folders, so each marker's
    /// 9 + 28 holds remain bounded to 111 observations. No location guesses.
    @nonobjc private func discoverTargets(directory: URL, index: Int) async throws -> [SurveySeed] {
        let deadline = ProcessInfo.processInfo.systemUptime + (firstDeliveredFreshFrameTimestamp == nil ? 15 : 4)
        let after = Date().timeIntervalSince1970*1000
        var count = 0, eligibleFreshFrames = 0, confirmations: [String: Int] = [:], candidates: [String: SurveySeed] = [:]
        while count < 2, ProcessInfo.processInfo.systemUptime < deadline {
            try check(); try checkRequestedPose()
            let pose = try neck()
            guard let frame = ROBArmRoutineVision.shared.snapshot()["face"],
                  frame.sequence > frameSequence, frame.capturedAt >= after,
                  (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
                  let depth = frame.depth, let k = frame.intrinsics,
                  k.isValid(forWidth: depth.width, height: depth.height) else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            let age = (Date().timeIntervalSince1970*1000-frame.capturedAt)/1000
            guard ProcessInfo.processInfo.systemUptime-age >= pose.readyAt else { continue }
            guard abs(Double(frame.image.extent.width/frame.image.extent.height)/(Double(depth.width)/Double(depth.height))-1) < 0.02,
                  captureAnchor.accept(frameGeneration: frame.cameraGeneration,
                                       currentGeneration: ROBArmRoutineVision.shared.cameraGeneration) else {
                throw ROBGhostMotionError.blocked("Survey RGB/depth framing or camera identity changed.")
            }
            frameSequence = frame.sequence
            guard cameraWarmupComplete(frame.capturedAt) else {
                try await Task.sleep(nanoseconds: 100_000_000); continue
            }
            eligibleFreshFrames += 1
            let detections: [(String, [SIMD2<Double>])] = try await Task.detached(priority: .userInitiated) {
                let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                try VNImageRequestHandler(ciImage: frame.image, orientation: .up, options: [:]).perform([request])
                return (request.results ?? []).compactMap { observation in
                    guard let id = observation.payloadStringValue,
                          ROBNeckQRMeasurement.supportedTargetIDs.contains(id) else { return nil }
                    let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
                        .map { SIMD2(Double($0.x), Double($0.y)) }
                    return (id, corners)
                }
            }.value
            try check(); try checkRequestedPose()
            let current = try neck()
            guard current.lower == pose.lower, current.upper == pose.upper,
                  abs(current.pan-pose.pan) < 0.01, abs(current.readyAt-pose.readyAt) < 0.000001 else {
                throw ROBGhostMotionError.blocked("The neck changed during survey detection.")
            }
            let name = "discovery-\(index)-\(count)"
            let image = frame.image
            try await Task.detached(priority: .utility) {
                let context = CIContext(options: [.useSoftwareRenderer: true])
                guard let cg = context.createCGImage(image, from: image.extent),
                      let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
                    throw ROBGhostMotionError.blocked("The discovery source image could not be saved.")
                }
                try jpeg.write(to: directory.appendingPathComponent(name+".jpg"), options: .atomic)
                try depth.millimetersLittleEndian.write(to: directory.appendingPathComponent(name+".depth-u16le"), options: .atomic)
            }.value
            var evidence: [[String: Any]] = []
            let identityCounts = Dictionary(grouping:detections,by:{ $0.0 }).mapValues { $0.count }
            for (id, corners) in detections {
                guard identityCounts[id] == 1 else { continue }
                guard let center = try? ROBNeckQRMeasurement.centerNormalized(of: corners) else { continue }
                let twiceArea = (0..<4).reduce(0.0) { value, i in
                    value + corners[i].x*corners[(i+1)%4].y-corners[i].y*corners[(i+1)%4].x
                }
                let margin = corners.reduce(1.0) { min($0, min($1.x, min(1-$1.x, min($1.y, 1-$1.y)))) }
                let score = abs(twiceArea)/2 * min(1, max(0, margin)/0.08)
                confirmations[id, default: 0] += 1
                let seed = SurveySeed(targetID: id, pan: pose.pan, lower: pose.lower, upper: pose.upper,
                                      score: score, center: center, intrinsics: [k.fx,k.fy,k.cx,k.cy], evidence: name+".json")
                if score > (candidates[id]?.score ?? -1) { candidates[id] = seed }
                evidence.append(["targetID": id, "cornersNormalized": corners.map { [$0.x,$0.y] },
                                 "centerNormalized": [center.x,center.y], "areaMarginScore": score])
            }
            var record: [String: Any] = ["schemaVersion": 1, "sequence": frame.sequence,
                "capturedAtMilliseconds": frame.capturedAt, "imageSize": [depth.width,depth.height],
                "cameraMatrix": [k.fx,k.fy,k.cx,k.cy], "neckPanDegrees": pose.pan,
                "lowerTarget": pose.lower, "neckUpperTarget": pose.upper,
                "poseSource": "accepted_neck_commands", "registrationVerified": false, "detections": evidence]
            record.merge(stepContext) { _, new in new }
            if let imu = k.inertial { record["imu"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(imu)) }
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name+".json"), options: .atomic)
            count += 1
        }
        try check(); try checkRequestedPose()
        guard eligibleFreshFrames > 0 else {
            throw ROBGhostMotionError.blocked("Camera unavailable: no eligible fresh RGB/depth frames arrived after startup warmup. QR visibility was not evaluated.")
        }
        return candidates.values.filter { confirmations[$0.targetID, default: 0] >= 2 }
    }

    /// One local, neck-only survey. The base and both arms remain stationary.
    func calibrateAllFourTargets() { runTargetSurvey(requestedIDs:ROBNeckQRMeasurement.supportedTargetIDs) }
    func measureSelectedTarget() { runTargetSurvey(requestedIDs:[selectedTargetID]) }

    @nonobjc private func runTargetSurvey(requestedIDs: [String]) {
        do {
            try begin()
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.finish() }
                let session = UUID().uuidString
                let root = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Cerebro/NeckQRCalibration/SurveySessions/\(session)", isDirectory: true)
                var manifest: [String: Any] = ["schemaVersion": 1, "captureKind": "multi_target_neck_survey",
                    "sessionID": session, "sceneContextID": session, "robotBaseStationary": true,
                    "registrationVerified": false, "status": "discovering", "captures": [[String: Any]](),
                    "initialCameraWarmupMilliseconds": Self.initialCameraWarmupMilliseconds,
                    "initialCameraWarmupPolicy": "fixed_interval_from_first_delivered_fresh_frame_not_proven_exposure_stability",
                    "targetIDs": requestedIDs,
                    "trainingPolicy": "stable_actual_pose_hash_mod3",
                    "layoutSource": "operator reported ROB repositioned; all four fixed QR sheets placed; bucket beside left floor marker; two cans on table",
                    "oldWorldCoordinatesReused": false, "armCommands": false]
                var discoveryIndex = 0, captures: [[String: Any]] = [], seeds: [String: SurveySeed] = [:]
                do {
                    let hints = self.cachedSurveySeeds(requestedIDs)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    self.surveySessionID = session
                    self.captureDisplayCorrection = ROBWorkspaceDepthAlignment.snapshot()
                    self.folder = nil; self.views = []
                    UserDefaults.standard.removeObject(forKey:"ROBNeckQRLastCapturePath")
                    self.lastCapturePath = root.path
                    try self.writeSurvey(manifest, to: root)
                    let model = try self.model()
                    // Keep a useful current view before visiting older command
                    // hints. Only two fresh settled frames establish its ID.
                    if let pose = try? self.neck(),
                       self.calibrationViewAllowed?(pose.pan,pose.lower,pose.upper) == true {
                        self.stepContext = ["requestedPanDegrees":pose.pan,"requestedLowerTarget":pose.lower,
                                            "requestedUpperTarget":pose.upper,"currentViewFirst":true]
                        try await self.settleCalibration(pan:pose.pan,lower:pose.lower,upper:pose.upper)
                        let observed = try await self.discoverTargets(directory:root,index:discoveryIndex)
                        for measured in observed where requestedIDs.contains(measured.targetID) {
                            seeds[measured.targetID] = measured
                        }
                        discoveryIndex += 1
                    }
                    for hint in hints {
                        if seeds[hint.targetID] != nil { continue }
                        self.update("Reconfirming \(hint.targetID) in two fresh frames; saved commands are search hints only.")
                        let verified: SurveySeed?
                        if hint.targetID.hasPrefix("ROB:FLOOR:") {
                            verified = try await self.verifyFloorForward(hint.targetID,pan:hint.pan,referenceLower:hint.lower,upper:hint.upper,
                                directory:root,index:&discoveryIndex)
                        } else {
                            verified = try await self.verifySeed(hint,directory:root,index:&discoveryIndex)
                        }
                        if let verified {
                            seeds[verified.targetID] = verified
                        }
                    }
                    // A selected floor marker may be visible only after leaning
                    // forward at the operator's current view. Try that before
                    // an upright scan can move away from the useful view.
                    if requestedIDs.count == 1, let id = requestedIDs.first,
                       id.hasPrefix("ROB:FLOOR:"), seeds[id] == nil {
                        let pose = try self.neck()
                        if let verified = try await self.verifyFloorForward(id,pan:pose.pan,referenceLower:pose.lower,upper:pose.upper,
                            directory:root,index:&discoveryIndex) { seeds[id] = verified }
                    }
                    // Every search view is accepted and settled through the
                    // existing bounded neck path, then read in two fresh frames.
                    for pass in 0..<2 {
                        let pans: [Double] = pass == 0 ? [0,-20,-40,-55,20,40,55] : [0,-10,-30,-50,-65,10,30,50,65]
                        for upper in [6306,5700,5300,6906,7300] {
                            for requestedPan in pans {
                                try self.check()
                                if seeds.count == requestedIDs.count { break }
                                let pan = self.boundedPan?(requestedPan) ?? requestedPan
                                self.stepContext = ["requestedPanDegrees": pan, "requestedLowerTarget": 6011, "requestedUpperTarget": upper]
                                self.update("Finding requested QR targets: \(seeds.count)/\(requestedIDs.count) confirmed. Scan \(discoveryIndex+1), P \(Int(pan))°, U \(upper).")
                                try await self.settleCalibration(pan: pan, lower: 6011, upper: upper)
                                if pass > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                                for seed in try await self.discoverTargets(directory: root, index: discoveryIndex) {
                                    guard requestedIDs.contains(seed.targetID) else { continue }
                                    if seed.score > (seeds[seed.targetID]?.score ?? -1) { seeds[seed.targetID] = seed }
                                }
                                discoveryIndex += 1
                                manifest["discoveryViews"] = discoveryIndex
                                manifest["foundTargetIDs"] = seeds.keys.sorted()
                                manifest["seeds"] = seeds.values.map {
                                    ["targetID":$0.targetID,"panDegrees":$0.pan,"lowerTarget":$0.lower,
                                     "upperTarget":$0.upper,"score":$0.score,"evidence":$0.evidence] as [String:Any]
                                }
                                try self.writeSurvey(manifest, to: root)
                            }
                            if seeds.count == requestedIDs.count { break }
                        }
                        if seeds.count == requestedIDs.count { break }
                    }
                    manifest["status"] = "capturing"
                    manifest["seeds"] = seeds.values.map {
                        ["targetID":$0.targetID,"panDegrees":$0.pan,"lowerTarget":$0.lower,
                         "upperTarget":$0.upper,"score":$0.score,"evidence":$0.evidence] as [String:Any]
                    }
                    for id in requestedIDs {
                        try self.check()
                        guard var seed = seeds[id] else { continue }
                        self.selectedTargetID = id
                        let floorTarget = id.hasPrefix("ROB:FLOOR:")
                        // Keep the last measured seed distinct from a proposed
                        // endpoint. Never start a metric sweep from an unchecked
                        // final prediction or a failed recentering attempt.
                        let originalSeed = seed
                        var proposed = seed, lastVerified: SurveySeed?
                        for attempt in 0..<(floorTarget ? 0 : 3) {
                            guard let measured = try await self.verifySeed(proposed,directory:root,index:&discoveryIndex) else { break }
                            lastVerified = measured
                            let yaw = atan((measured.center.x-0.5)*640/measured.intrinsics[0])*180 / .pi
                            let pitch = atan((0.5-measured.center.y)*400/measured.intrinsics[1])*180 / .pi
                            if attempt == 2 || (abs(yaw) < 2 && abs(pitch) < 2) { break }
                            proposed = SurveySeed(targetID:id,
                                pan:self.boundedPan?(measured.pan-max(-8,min(8,yaw))) ?? measured.pan,
                                lower:measured.lower,
                                upper:max(5300,min(7350,measured.upper-max(-150,min(150,Int((pitch*16.6666667).rounded()))))),
                                score:measured.score,center:measured.center,intrinsics:measured.intrinsics,evidence:measured.evidence)
                        }
                        var verifiedStart: SurveySeed?
                        if floorTarget {
                            verifiedStart = try await self.verifyFloorForward(id,pan:seed.pan,referenceLower:seed.lower,upper:seed.upper,
                                directory:root,index:&discoveryIndex)
                        } else {
                            if let lastVerified { verifiedStart = try await self.verifySeed(lastVerified,directory:root,index:&discoveryIndex) }
                            if verifiedStart == nil { verifiedStart = try await self.verifySeed(originalSeed,directory:root,index:&discoveryIndex) }
                        }
                        guard let verifiedStart else {
                            captures.append(["targetID":id,"status":"not_readable_at_verified_seed","samples":0])
                            manifest["captures"] = captures; try self.writeSurvey(manifest,to:root)
                            continue
                        }
                        seed = verifiedStart
                        try self.newCapture(model: model, kind: "survey_upper_and_lower_postures")
                        let markerFolder = self.folder!
                        let captureIndex = captures.count
                        captures.append(["targetID":id,"capturePath":markerFolder.appendingPathComponent("capture.json").path,
                                         "status":"capturing","samples":0])
                        manifest["captures"] = captures
                        try self.writeSurvey(manifest,to:root)
                        var complete = true, failure = "", retryCount = 0
                        var missedHolds: [[String:Any]] = [], policySkippedHolds: [[String:Any]] = [], consecutiveMisses = 0
                        let panSpan: Double = floorTarget ? 4 : 8
                        let forwardTargets = floorTarget ? self.floorForwardTargets(id,pan:seed.pan,referenceLower:seed.lower,upper:seed.upper) : []
                        let lowerTargets = floorTarget ? [6111,forwardTargets.max() ?? 6111,6111,6011] : [6011,5811,6211,6011]
                        let upperOffset = floorTarget ? 50 : 75
                        var holds: [(Double,Int,Int)] = floorTarget
                            ? lowerTargets.map { (seed.pan,$0,self.predictedFloorUpper(anchorLower:seed.lower,anchorUpper:seed.upper,lower:$0)) } : []
                        holds += [0,-75,-150,-75,0,75,150,75,0]
                            .map { (seed.pan,floorTarget ? seed.lower : 6011,max(5300,min(7500,seed.upper+$0))) }
                        for lower in lowerTargets {
                            let left = self.boundedPan?(seed.pan-panSpan) ?? seed.pan-panSpan
                            let right = self.boundedPan?(seed.pan+panSpan) ?? seed.pan+panSpan
                            // Visibility predictions do not establish a pose;
                            // each accepted endpoint still needs fresh QR.
                            let center = floorTarget ? self.predictedFloorUpper(anchorLower:seed.lower,anchorUpper:seed.upper,lower:lower)
                                : max(5300,min(7500,seed.upper+max(-150,min(150,lower-6011))))
                            if !floorTarget { holds.append((seed.pan,lower,center)) }
                            holds += [(left,lower,center),(left,lower,max(5300,center-upperOffset)),
                                      (seed.pan,lower,max(5300,center-upperOffset)),(right,lower,max(5300,center-upperOffset)),
                                      (right,lower,center),(seed.pan,lower,center)]
                        }
                        for index in holds.indices {
                            try self.check()
                            let (pan,lower,upper) = holds[index]
                            if floorTarget, self.calibrationViewAllowed?(pan,lower,upper) != true {
                                complete = false
                                policySkippedHolds.append(["stepIndex":index,"requestedPanDegrees":pan,
                                    "requestedLowerTarget":lower,"requestedUpperTarget":upper,
                                    "reason":"Outside the active command policy; no movement requested."])
                                captures[captureIndex]["policySkippedHolds"] = policySkippedHolds
                                manifest["captures"] = captures
                                try self.writeSurvey(manifest,to:root)
                                continue
                            }
                            self.stepContext = ["stepIndex": index, "requestedPanDegrees": pan,
                                "requestedLowerTarget": lower, "requestedUpperTarget": upper]
                            if floorTarget {
                                self.stepContext.merge(["floorVisibilityAnchorLower":seed.lower,"floorVisibilityAnchorUpper":seed.upper,
                                    "floorVisibilityUpperTargetsPerLowerTarget":Self.floorVisibilityUpperTargetsPerLowerTarget,
                                    "floorVisibilityPredictionOnly":true]) { _, new in new }
                            }
                            self.update("\(id): hold \(index+1)/37, \(self.views.count)/111 samples. P \(String(format:"%.2f",pan))°, L \(lower), U \(upper).")
                            do {
                                try await self.settleCalibration(pan: pan, lower: lower, upper: upper)
                                try await self.observe(model: model, poseID: "step-\(index)", training: true,
                                    after: Date().timeIntervalSince1970*1000)
                                consecutiveMisses = 0
                                if !floorTarget, index >= 9, (index-9)%7 == 0, lower != 6011,
                                   let baseline = self.views.first?["centerPixel"] as? [Double],
                                   let observed = self.views.last?["centerPixel"] as? [Double],
                                   let k = self.views.last?["cameraMatrix"] as? [Double],
                                   baseline.count == 2, observed.count == 2, k.count == 4 {
                                    let bearing = atan((observed[1]-baseline[1])/k[1])*180 / .pi
                                    let correction = max(-150,min(150,-Int((bearing*16.6666667).rounded())))
                                    for next in (index+1)...min(index+6,holds.count-1) {
                                        holds[next].2 = max(5300,min(7500,holds[next].2+correction))
                                    }
                                }
                            } catch {
                                try self.check()
                                let originalFailure = error.localizedDescription
                                if floorTarget, error is QRObservationError {
                                    complete = false; failure = originalFailure; consecutiveMisses += 1
                                    missedHolds.append(["stepIndex":index,"requestedPanDegrees":pan,
                                        "requestedLowerTarget":lower,"requestedUpperTarget":upper,"reason":originalFailure])
                                    captures[captureIndex]["missedHolds"] = missedHolds
                                    captures[captureIndex]["samples"] = self.views.count
                                    manifest["captures"] = captures
                                    try self.writeSurvey(manifest,to:root)
                                    // Do not abandon the next forward hold just
                                    // because the upright/occluded view failed.
                                    if missedHolds.count <= 6, consecutiveMisses <= 3 { continue }
                                    break
                                }
                                // A floor motion, pose, camera, or storage error
                                // must not be mistaken for a visibility miss.
                                if floorTarget { throw error }
                                var recovered = false, localAttempt = 0
                                while retryCount < 3, self.views.count+3 <= 128 {
                                    retryCount += 1; localAttempt += 1
                                    guard let reacquired = try await self.verifySeed(seed,directory:root,index:&discoveryIndex) else { break }
                                    seed = reacquired
                                    let fraction = pow(0.5,Double(localAttempt))
                                    let retryPan = self.boundedPan?(seed.pan+(pan-seed.pan)*fraction) ?? seed.pan
                                    let retryLower = seed.lower+Int((Double(lower-seed.lower)*fraction).rounded())
                                    let retryUpper = seed.upper+Int((Double(upper-seed.upper)*fraction).rounded())
                                    self.stepContext = ["stepIndex":index,"requestedPanDegrees":retryPan,
                                        "requestedLowerTarget":retryLower,"requestedUpperTarget":retryUpper,
                                        "originalPlannedPanDegrees":pan,"originalPlannedLowerTarget":lower,
                                        "originalPlannedUpperTarget":upper,"visibilityReduced":true,
                                        "retryOrdinal":retryCount,"visibilityDeltaFraction":fraction]
                                    do {
                                        try await self.settleCalibration(pan:retryPan,lower:retryLower,upper:retryUpper)
                                        try await self.observe(model:model,poseID:"step-\(index)-retry-\(retryCount)",training:true,
                                            after:Date().timeIntervalSince1970*1000)
                                        recovered = true; break
                                    } catch { try self.check() }
                                }
                                if !recovered { complete = false; failure = originalFailure; break }
                            }
                            captures[captureIndex]["samples"] = self.views.count
                            manifest["captures"] = captures
                            try self.writeSurvey(manifest,to:root)
                        }
                        var uprightRevisit: [String:Any] = [:]
                        if floorTarget {
                            try self.check()
                            let returnUpper = self.predictedFloorUpper(anchorLower:seed.lower,anchorUpper:seed.upper,lower:6011)
                            guard self.calibrationViewAllowed?(seed.pan,6011,returnUpper) == true else {
                                throw ROBGhostMotionError.blocked("The upright floor revisit is outside the active command policy.")
                            }
                            self.stepContext = ["requestedPanDegrees":seed.pan,"requestedLowerTarget":6011,
                                "requestedUpperTarget":returnUpper,"uprightReturnRevisit":true,
                                "floorVisibilityAnchorLower":seed.lower,"floorVisibilityAnchorUpper":seed.upper,
                                "floorVisibilityUpperTargetsPerLowerTarget":Self.floorVisibilityUpperTargetsPerLowerTarget,
                                "floorVisibilityPredictionOnly":true]
                            try await self.settleCalibration(pan:seed.pan,lower:6011,upper:returnUpper)
                            let returned = try await self.discoverTargets(directory:root,index:discoveryIndex)
                            discoveryIndex += 1
                            uprightRevisit = ["panDegrees":seed.pan,"lowerTarget":6011,"upperTarget":returnUpper,
                                "targetConfirmedInFreshFrames":returned.contains(where: { $0.targetID == id }),
                                "discoveryIndex":discoveryIndex-1]
                        }
                        captures[captureIndex] = ["targetID":id,"capturePath":markerFolder.appendingPathComponent("capture.json").path,
                            "status":complete ? "complete" : "partial","samples":self.views.count,
                            "failure":failure,"seedPanDegrees":seed.pan,"seedLowerTarget":seed.lower,"seedUpperTarget":seed.upper,
                            "seedEvidence":seed.evidence,"retryCount":retryCount,
                            "missedHolds":missedHolds,"policySkippedHolds":policySkippedHolds,"uprightRevisit":uprightRevisit,
                            "floorForwardLowerTargets":forwardTargets,
                            "floorVisibilityUpperTargetsPerLowerTarget":floorTarget ? Self.floorVisibilityUpperTargetsPerLowerTarget : 0,
                            "floorVisibilityPredictionOnly":floorTarget,
                            "visibilityProfile":floorTarget ? "floor_forward_occlusion_relief" : "standard"]
                        manifest["captures"] = captures
                        try self.writeSurvey(manifest,to:root)
                    }
                    manifest["status"] = "capture_complete_unverified"
                    manifest["missingTargetIDs"] = requestedIDs.filter { seeds[$0] == nil }
                    try self.writeSurvey(manifest,to:root)
                    self.lastCapturePath = root.path
                    self.update("Target survey saved: \(captures.filter { $0["status"] as? String == "complete" }.count)/\(requestedIDs.count) complete, \(seeds.count)/\(requestedIDs.count) found. No calibration applied.\n\(root.path)")
                } catch {
                    if let marker = self.folder,
                       let i = captures.firstIndex(where: { $0["capturePath"] as? String == marker.appendingPathComponent("capture.json").path }) {
                        captures[i]["status"] = "partial"
                        captures[i]["samples"] = self.views.count
                    }
                    manifest["captures"] = captures; manifest["status"] = "stopped_or_failed"
                    manifest["failure"] = error.localizedDescription
                    try? self.writeSurvey(manifest,to:root)
                    self.lastCapturePath = root.path
                    self.report(error)
                }
            }
        } catch { report(error) }
    }

    func advanceProtractor(_ pitchDegrees: NSNumber?) {
        guard isRunning, awaitingProtractor else { return }
        do { try checkRequestedPose() } catch { task?.cancel(); update(error.localizedDescription); return }
        if let pitchDegrees {
            let angle = pitchDegrees.doubleValue
            guard angle.isFinite, (-180...180).contains(angle) else {
                update("Enter a finite protractor pitch from −180° to 180°, positive nose-up."); return
            }
            var reading = stepContext
            reading["pitchDegrees"] = angle
            reading["reference"] = "operator protractor, camera housing relative to the same level reference; positive nose-up"
            protractorReadings.append(reading)
        }
        advanceRequested = true; awaitingProtractor = false
    }

    private func settleCalibration(pan: Double, lower: Int, upper: Int) async throws {
        guard prepareCalibrationView != nil, calibrationViewReady != nil else {
            throw ROBGhostMotionError.blocked("The neck calibration command path is unavailable.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 18
        // Establish exclusive inspection context even when the first target
        // already matches: stop following/base heartbeat and disable tracking.
        _ = prepareCalibrationView?(pan, lower, upper)
        while calibrationViewReady?(pan, lower, upper) != true {
            try check()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ROBGhostMotionError.blocked("The calibration neck target was not accepted and settled. Captured steps were saved.")
            }
            _ = prepareCalibrationView?(pan, lower, upper)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try check()
        guard calibrationViewReady?(pan, lower, upper) == true else {
            throw ROBGhostMotionError.blocked("The neck changed during calibration settling.")
        }
    }

    private func runMeasuredSweep(protractor: Bool, postures: Bool) {
        do {
            try begin()
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.finish() }
                do {
                    let model = try self.model(), initial = try self.neck()
                    guard initial.lower == 6011 else {
                        throw ROBGhostMotionError.blocked("Start this calibration from the upright lower-neck target 6011; no automatic reposition was performed.")
                    }
                    let kind = postures ? "multiple_lower_postures" : "upper_neck_forward_reverse"
                    try self.newCapture(model: model, kind: kind)
                    let center = initial.upper
                    guard (5450...7350).contains(center), abs(initial.pan) <= 70 else {
                        throw ROBGhostMotionError.blocked("Center the selected target in a normal inspection view before this sweep.")
                    }
                    let offsets = [0, -75, -150, -75, 0, 75, 150, 75, 0]
                    let lowerTargets = postures ? [6011, 5811, 6211, 6011] : [6011]
                    let count = lowerTargets.count * (postures ? 7 : offsets.count)
                    var index = 0
                    for lower in lowerTargets {
                        let left = self.boundedPan?(initial.pan-8) ?? initial.pan-8
                        let right = self.boundedPan?(initial.pan+8) ?? initial.pan+8
                        var poses: [(Double, Int)] = postures
                            ? [(initial.pan,center), (left,center), (left,center-75),
                               (initial.pan,center-75), (right,center-75), (right,center), (initial.pan,center)]
                            : offsets.map { (initial.pan, center+$0) }
                        for position in poses.indices {
                            let (pan, upper) = poses[position]
                            try self.check()
                            self.stepContext = ["stepIndex": index, "requestedPanDegrees": pan,
                                "requestedLowerTarget": lower, "requestedUpperTarget": upper]
                            self.update("Neck check \(index+1)/\(count): P \(String(format: "%.2f", pan))°, L \(lower), U \(upper). Settling, then checking QR.")
                            try await self.settleCalibration(pan: pan, lower: lower, upper: upper)
                            try await self.observe(model: model, poseID: "step-\(index)", training: index % 3 != 2,
                                after: Date().timeIntervalSince1970*1000)
                            if postures, position == 0, lower != 6011,
                               let baseline = self.views.first?["centerPixel"] as? [Double],
                               let observed = self.views.last?["centerPixel"] as? [Double],
                               let k = self.views.last?["cameraMatrix"] as? [Double],
                               baseline.count == 2, observed.count == 2, k.count == 4 {
                                // A bounded visibility prior only. Each new
                                // endpoint still needs its own QR measurement;
                                // this does not change the calibrated mapping.
                                let bearing = atan((observed[1]-baseline[1])/k[1])*180 / .pi
                                let adjustment = max(-150, min(150, -Int((bearing*33.3333333333).rounded())))
                                for next in 1..<poses.count {
                                    poses[next].1 = max(5300, min(7500, poses[next].1+adjustment))
                                }
                            }
                            if protractor {
                                self.advanceRequested = false; self.awaitingProtractor = true
                                self.update("Holding \(index+1)/\(count): P \(String(format: "%.2f", pan))°, L \(lower), U \(upper). QR captured. Read the camera-housing protractor, then Record angle / next position. Blank skips the reading.")
                                while !self.advanceRequested {
                                    try self.check(); try self.checkRequestedPose()
                                    try await Task.sleep(nanoseconds: 100_000_000)
                                }
                                try self.save(model: model)
                            }
                            index += 1
                        }
                    }
                    self.update("Neck check complete: \(count) measured holds, \(self.views.count) QR samples. Raw targets and protractor readings saved; no calibration applied.\n\(self.lastCapturePath)")
                } catch { self.report(error) }
            }
        } catch { update(error.localizedDescription) }
    }

    func fitLastCapture() { fitRecordedCapture(jointMapping: false) }
    func fitNeckMapping() { fitRecordedCapture(jointMapping: true) }

    private func restoreLastCaptureIfNeeded() {
        guard folder == nil, let path = UserDefaults.standard.string(forKey: "ROBNeckQRLastCapturePath") else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cerebro/NeckQRCalibration").resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath:path,isDirectory:true).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path+"/"),
              let bytes = try? Data(contentsOf:candidate.appendingPathComponent("capture.json")), bytes.count < 2_000_000,
              let payload = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let target = payload["targetID"] as? String, ROBNeckQRMeasurement.supportedTargetIDs.contains(target),
              let records = payload["views"] as? [[String:Any]], records.count <= 128 else { return }
        folder = candidate; lastCapturePath = candidate.path; selectedTargetID = target; views = records
    }

    private func fitRecordedCapture(jointMapping: Bool) {
        restoreLastCaptureIfNeeded()
        guard !isRunning, let folder else { update("Capture the fixed QR before fitting."); return }
        let runFolder = folder.appendingPathComponent("Fits/\(UUID().uuidString)",isDirectory:true)
        do { try FileManager.default.createDirectory(at:runFolder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
        catch { report(error); return }
        isRunning = true
        update(jointMapping ? "Refining the printed QR corners and fitting the neck mapping offline." : "Fitting the recorded neck/camera transform offline.")
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.task = nil; self.fitTask = nil; self.update(self.status) }
            do {
                let worker = Task.detached(priority: .userInitiated) { () async throws -> Data in
                    guard let resources = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
                        throw ROBGhostMotionError.blocked("The calibration worker is missing.")
                    }
                    let jobs = jointMapping
                        ? [("qr_corner_refinement.py", "capture.json", "refined-capture.json"),
                           ("qr_neck_joint_calibration.py", "refined-capture.json", "joint-fit.json")]
                        : [("qr_neck_calibration.py", "capture.json", "fit.json")]
                    for (script, input, output) in jobs {
                        try Task.checkCancellation()
                        let inputFolder = input == "capture.json" ? folder : runFolder
                        let args = [resources.appendingPathComponent(script).path,
                            inputFolder.appendingPathComponent(input).path, runFolder.appendingPathComponent(output).path]
                        let process = try ROBPythonRuntime.shared.newTask(withArguments: args)
                        let logURL = runFolder.appendingPathComponent(output+".log")
                        FileManager.default.createFile(atPath: logURL.path, contents: nil)
                        let log = try FileHandle(forWritingTo: logURL)
                        defer { if process.isRunning { process.terminate() }; try? log.close() }
                        process.standardOutput = log; process.standardError = log
                        try process.run()
                        let deadline = ProcessInfo.processInfo.systemUptime+(script == "qr_corner_refinement.py" ? 120 : 45)
                        while process.isRunning {
                            try Task.checkCancellation()
                            guard ProcessInfo.processInfo.systemUptime < deadline else {
                                throw ROBGhostMotionError.blocked("The offline calibration worker exceeded its time limit. Captures remain saved.")
                            }
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                        guard process.terminationStatus == 0 else {
                            let bytes = try Data(contentsOf: logURL)
                            throw ROBGhostMotionError.blocked(String(data: bytes, encoding: .utf8) ?? "QR fit failed.")
                        }
                    }
                    return try Data(contentsOf: runFolder.appendingPathComponent(jointMapping ? "joint-fit.json" : "fit.json"))
                }
                self.fitTask = worker
                let result = try await worker.value
                try Task.checkCancellation()
                let report = try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:]
                if jointMapping {
                    let training = report["trainingReprojectionRMSEPixels"] as? Double ?? .nan
                    let validation = report["heldOutReprojectionRMSEPixels"] as? Double ?? .nan
                    let refined = (try? Data(contentsOf:runFolder.appendingPathComponent("refined-capture.json")))
                        .flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
                    let quality = refined?["cornerRefinement"] as? [String:Any]
                    let accepted = quality?["acceptedViews"] as? Int ?? 0
                    let rejected = quality?["rejectedViews"] as? Int ?? 0
                    self.update(String(format: "Offline neck mapping saved. Training %.3f px; held-out %.3f px. Refinement: %d accepted, %d raw-retained/rejected. Candidate remains unverified; no URDF change applied.\n%@", training, validation, accepted, rejected, runFolder.path))
                } else {
                    let training = (report["trainingTranslationRMSEMeters"] as? Double ?? .nan)*1000
                    let validation = (report["heldOutTranslationRMSEMeters"] as? Double ?? .nan)*1000
                    self.update(String(format: "QR fit saved. Training drift %.1f mm; held-out drift %.1f mm. Registration remains unverified.\n%@", training, validation, runFolder.path))
                }
            } catch { self.report(error) }
        }
    }
    func openLastCapture() {
        restoreLastCaptureIfNeeded()
        if !lastCapturePath.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: lastCapturePath, isDirectory: true)) }
    }
    func stop() {
        task?.cancel(); fitTask?.cancel()
        update(isRunning ? "Stopping calibration; no additional neck targets will be sent." : "QR calibration stopped.")
    }
}
