import Foundation
import simd

/// Operator-adjusted head-depth placement for visual commissioning. This is a
/// base_link translation and local optical-camera pitch, not camera-to-arm
/// registration, a sensor-depth edit, or a change to a saved reach correction.
enum ROBWorkspaceDepthAlignment {
    static let preferenceKey = "ROBWorkspaceHeadDepthAlignment.v1"
    private static let lock = NSLock()

    struct Snapshot: Equatable {
        let towardRobotMeters: Double
        let downwardPitchDegrees: Double
        /// Bind captured scenes to this identity, including edits made without
        /// restarting the camera. Saving even the same value invalidates them.
        let identity: String

        fileprivate init(towardRobotMeters: Double, downwardPitchDegrees: Double = 0, revision: String) {
            self.towardRobotMeters = towardRobotMeters
            self.downwardPitchDegrees = downwardPitchDegrees
            identity = "provisional-head-depth-placement-v2:\(towardRobotMeters.bitPattern):\(downwardPitchDegrees.bitPattern):\(revision)"
        }

        /// ROB's +X axis points forward. Left multiplication translates in the
        /// robot frame. The optical axes are X-right/Y-down/Z-forward, so a
        /// negative local-X rotation points the camera farther down, including
        /// after neck pan. Rotate about the lens, without moving its origin or
        /// altering the distances between observed points.
        func applying(to cameraFrame: simd_double4x4) -> simd_double4x4 {
            var translation = matrix_identity_double4x4
            translation.columns.3.x = -towardRobotMeters
            return translation * applyingPitch(to: cameraFrame)
        }

        /// Camera-model orientation only; the display mesh must not inherit
        /// the independent provisional translation of observed depth points.
        func applyingPitch(to cameraFrame: simd_double4x4) -> simd_double4x4 {
            guard downwardPitchDegrees != 0 else { return cameraFrame }
            let pitch = simd_double4x4(simd_quatd(angle: -downwardPitchDegrees * .pi / 180,
                axis: SIMD3<Double>(1, 0, 0)))
            return cameraFrame * pitch
        }
    }

    private struct Parameters: Codable {
        let version: Int
        let towardRobotMeters: Double
        var downwardPitchDegrees: Double? = nil
        let revision: UUID
    }

    enum ConfigurationError: LocalizedError {
        case invalidTranslation
        case invalidPitch
        case invalidStoredConfiguration
        var errorDescription: String? {
            switch self {
            case .invalidTranslation: return "Head depth adjustment must be a finite distance from 0 to 30 cm toward ROB."
            case .invalidPitch: return "Face-camera downward pitch must be a finite angle from 0 to 30 degrees."
            case .invalidStoredConfiguration: return "The saved head-depth placement is invalid; apply valid distance and pitch values together."
            }
        }
    }

    /// Read the single persisted blob while holding the same lock as writers.
    /// A missing setting means raw placement; damaged settings fail closed so
    /// callers cannot unknowingly use a different transform for collision work.
    static func snapshot(defaults: UserDefaults = .standard) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return readSnapshot(defaults: defaults)
    }

    private static func readSnapshot(defaults: UserDefaults) -> Snapshot? {
        guard let stored = defaults.object(forKey: preferenceKey) else {
            return Snapshot(towardRobotMeters: 0, revision: "raw")
        }
        guard let data = stored as? Data, data.count <= 1_024,
              let parameters = try? JSONDecoder().decode(Parameters.self, from: data),
              parameters.version == 1, valid(parameters.towardRobotMeters),
              validPitch(parameters.downwardPitchDegrees ?? 0) else { return nil }
        return Snapshot(towardRobotMeters: parameters.towardRobotMeters,
            downwardPitchDegrees: parameters.downwardPitchDegrees ?? 0,
            revision: parameters.revision.uuidString)
    }

    /// Persist an explicit commissioning adjustment. No default is applied
    /// silently on launch, and this never supplies registration or an arm grant.
    @discardableResult static func setTowardRobotMeters(_ meters: Double,
                                                       defaults: UserDefaults = .standard) throws -> Snapshot {
        guard valid(meters) else { throw ConfigurationError.invalidTranslation }
        lock.lock()
        defer { lock.unlock() }
        guard let current = readSnapshot(defaults: defaults) else { throw ConfigurationError.invalidStoredConfiguration }
        return try persist(towardRobotMeters: meters, downwardPitchDegrees: current.downwardPitchDegrees, defaults: defaults)
    }

    @discardableResult static func setDownwardPitchDegrees(_ degrees: Double,
                                                         defaults: UserDefaults = .standard) throws -> Snapshot {
        guard validPitch(degrees) else { throw ConfigurationError.invalidPitch }
        lock.lock()
        defer { lock.unlock() }
        guard let current = readSnapshot(defaults: defaults) else { throw ConfigurationError.invalidStoredConfiguration }
        return try persist(towardRobotMeters: current.towardRobotMeters, downwardPitchDegrees: degrees, defaults: defaults)
    }

    /// Both placement parameters form one persisted revision. This can also
    /// replace a malformed setting without guessing an omitted parameter.
    @discardableResult static func setAlignment(towardRobotMeters: Double, downwardPitchDegrees: Double,
                                              defaults: UserDefaults = .standard) throws -> Snapshot {
        guard valid(towardRobotMeters) else { throw ConfigurationError.invalidTranslation }
        guard validPitch(downwardPitchDegrees) else { throw ConfigurationError.invalidPitch }
        lock.lock()
        defer { lock.unlock() }
        return try persist(towardRobotMeters: towardRobotMeters, downwardPitchDegrees: downwardPitchDegrees, defaults: defaults)
    }

    private static func persist(towardRobotMeters: Double, downwardPitchDegrees: Double, defaults: UserDefaults) throws -> Snapshot {
        let normalized = towardRobotMeters == 0 ? 0 : towardRobotMeters
        let pitch = downwardPitchDegrees == 0 ? 0 : downwardPitchDegrees
        let parameters = Parameters(version: 1, towardRobotMeters: normalized, downwardPitchDegrees: pitch, revision: UUID())
        let data = try JSONEncoder().encode(parameters)
        defaults.set(data, forKey: preferenceKey)
        return Snapshot(towardRobotMeters: normalized, downwardPitchDegrees: pitch, revision: parameters.revision.uuidString)
    }

    private static func valid(_ meters: Double) -> Bool { meters.isFinite && (0...0.30).contains(meters) }
    private static func validPitch(_ degrees: Double) -> Bool { degrees.isFinite && (0...30).contains(degrees) }
}

enum ROBWorkspaceTarget: String, Codable, CaseIterable {
    case can, orangeBucket
    var spokenName: String { self == .can ? "Coke can" : "orange bucket" }
}

/// Announce confirmed discoveries once per search, including what remains.
/// Visual confirmation is deliberately independent of grasp/drop geometry.
struct ROBWorkspaceSearchSpeech {
    private var announced = Set<ROBWorkspaceTarget>()
    mutating func confirmed(_ visible: Set<ROBWorkspaceTarget>, targets: [ROBWorkspaceTarget]) -> String? {
        let requested = Set(targets)
        let seen = visible.intersection(requested)
        let new = seen.subtracting(announced)
        guard !new.isEmpty else { return nil }
        announced.formUnion(new)
        if new.count == 2 { return "I see the can and bucket." }
        let name = new.contains(.can) ? "can" : "bucket"
        let missing = requested.subtracting(seen)
        guard !missing.isEmpty else { return "I see the \(name)." }
        return "I see the \(name). I'm still looking for the \(missing.contains(.can) ? "can" : "bucket")."
    }
}

enum ROBWorkspaceReachError: LocalizedError {
    case outOfReach(ROBWorkspaceTarget)
    var helpRequest: String {
        switch self {
        case .outOfReach(.can): return "Please bring the can closer."
        case .outOfReach(.orangeBucket): return "Please bring the bucket closer."
        }
    }
    var errorDescription: String? { helpRequest + " I'll need to check its new position before reaching." }
}

struct ROBWorkspaceView: Codable, Equatable {
    let panDegrees: Double
    let upperTarget: Int
    static let sweep: [Self] = {
        var views = [0.0, -15, -30, -45].map { Self(panDegrees: $0, upperTarget: 6306) }
        // Continuous raster rather than alternating distant left/right jumps.
        // The 5300 row includes the lower workspace/floor beside the table.
        for (index, upper) in [5650, 5300, 6306, 6906].enumerated() {
            let pans = index.isMultiple(of: 2) ? [-45.0,-30,-15,0,15,30,45] : [45.0,30,15,0,-15,-30,-45]
            views += pans.map { Self(panDegrees: $0, upperTarget: upper) }
        }
        return views
    }()
    func cameraFrame(model: ROBGhostRobotModel) -> simd_double4x4? {
        guard let alignment = ROBWorkspaceDepthAlignment.snapshot(),
              let frame = rawCameraFrame(model: model) else { return nil }
        return alignment.applying(to: frame)
    }
    func rawCameraFrame(model: ROBGhostRobotModel) -> simd_double4x4? {
        guard let pose = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: panDegrees * .pi / 180,
            lowerTarget: 6011, upperTarget: upperTarget, known: true),
              let head = model.headPositions(pan: pose.panRadians, lowerPitch: pose.lowerPitch, upperPitch: pose.upperPitch) else { return nil }
        return model.frames(model.reference.merging(head) { _, new in new })["oak_optical_frame"]
    }
}

/// Durable attention hints only. A remembered sighting never satisfies a live
/// detection, depth measurement, or arm authorization, even after a restart.
struct ROBWorkspaceRecall: Codable {
    struct Sighting: Codable {
        let target: ROBWorkspaceTarget
        let view: ROBWorkspaceView
        let box: [Double]
        let confidence: Double
        let capturedAt: Double
        var valid: Bool {
            box.count == 4 && box.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
                box[2] > box[0] && box[3] > box[1] && confidence.isFinite && (0.35...1).contains(confidence) &&
                capturedAt.isFinite && view.panDegrees.isFinite && abs(view.panDegrees) <= 70 && (5300...7500).contains(view.upperTarget)
        }
        var centeredView: ROBWorkspaceView {
            let x = (box[0] + box[2]) / 2, y = (box[1] + box[3]) / 2
            return .init(panDegrees: max(-45, min(45, view.panDegrees - (x - 0.5) * 69)),
                upperTarget: max(5300, min(7500, view.upperTarget - Int((y - 0.5) * 1500))))
        }
    }
    let modelID: String
    let geometryID: String
    var sightings: [Sighting] = []
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/WorkspaceSearch") }
    static var file: URL { directory.appendingPathComponent("recall-v1.json") }
    static func load(model: ROBGhostRobotModel, directory: URL = directory, now: Double = Date().timeIntervalSince1970 * 1000) -> Self {
        let file = directory.appendingPathComponent("recall-v1.json")
        if let data = try? Data(contentsOf: file), data.count < 32_000,
           let value = try? JSONDecoder().decode(Self.self, from: data), value.modelID == model.modelID,
           value.geometryID == model.geometryID, value.sightings.count <= ROBWorkspaceTarget.allCases.count,
           value.sightings.allSatisfy({ $0.valid }) { return value }
        var result = Self(modelID: model.modelID, geometryID: model.geometryID)
        // Migrate the previous session's on-disk observations. Require two
        // agreeing camera frames; imported positions are deliberately ignored.
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "recall-v1.json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for url in files.prefix(16) {
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let views = report["views"] as? [[String: Any]] else { continue }
            var candidates: [Sighting] = []
            var previous: [ROBWorkspaceTarget: (Sighting, UInt64)] = [:]
            for entry in views {
                guard let pan = entry["pan"] as? Double, let upper = entry["upper"] as? Int,
                      let sequence = (entry["sequence"] as? NSNumber)?.uint64Value,
                      let capturedAt = entry["captured_at_ms"] as? Double, (0...86_400_000).contains(now - capturedAt),
                      let inference = entry["local_inference"] as? [String: Any],
                      let boxes = inference["candidates"] as? [[String: Any]] else { continue }
                for target in ROBWorkspaceTarget.allCases {
                    let matches = boxes.filter { $0["target"] as? String == target.rawValue && ($0["score"] as? Double ?? 0) >= 0.35 }
                    guard let best = matches.max(by: { ($0["score"] as? Double ?? 0) < ($1["score"] as? Double ?? 0) }),
                          let box = best["box"] as? [Double], let score = best["score"] as? Double else { previous.removeValue(forKey: target); continue }
                    let sighting = Sighting(target: target, view: .init(panDegrees: pan, upperTarget: upper), box: box, confidence: score, capturedAt: capturedAt)
                    guard sighting.valid else { continue }
                    if let prior = previous[target], prior.1 != sequence, prior.0.view == sighting.view,
                       zip(prior.0.box, box).allSatisfy({ abs($0 - $1) < 0.08 }) { candidates.append(sighting) }
                    previous[target] = (sighting, sequence)
                }
            }
            for target in ROBWorkspaceTarget.allCases where !result.sightings.contains(where: { $0.target == target }) {
                // Prefer an unclipped, centered observation within the latest
                // usable search over the last glimpse at the edge of a sweep.
                if let best = candidates.filter({ $0.target == target }).min(by: {
                    abs(($0.box[0] + $0.box[2])/2 - 0.5) < abs(($1.box[0] + $1.box[2])/2 - 0.5)
                }) { result.sightings.append(best) }
            }
        }
        return result
    }
    mutating func remember(target: ROBWorkspaceTarget, detection: ROBWorkspaceDetection, view: ROBWorkspaceView, capturedAt: Double) {
        let value = Sighting(target: target, view: view, box: detection.box, confidence: detection.confidence, capturedAt: capturedAt)
        guard detection.visuallyUsable, value.valid else { return }
        sightings.removeAll { $0.target == target }; sightings.append(value)
    }
    func save(to file: URL = file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
    func views(targets: [ROBWorkspaceTarget], now: Double = Date().timeIntervalSince1970 * 1000) -> [ROBWorkspaceView] {
        targets.compactMap { target in sightings.first { $0.target == target && $0.valid && (0...86_400_000).contains(now - $0.capturedAt) } }
            .flatMap { [$0.view, $0.centeredView] }
            .reduce(into: []) { result, view in
                if !result.contains(where: { abs($0.panDegrees - view.panDegrees) < 3 && abs($0.upperTarget - view.upperTarget) < 100 }) { result.append(view) }
            }
    }
}

struct ROBWorkspaceDetection: Codable {
    let visible: Bool
    let confidence: Double
    /// Normalized, top-left image coordinates; depthPoint lies on a visible
    /// solid surface (the can wall or orange rim), aim is the grasp/opening.
    let box: [Double]
    let aim: [Double]
    let depthPoint: [Double]
    // Detector-specific raw score threshold, supplied only by native code.
    // VLM JSON cannot change it or promote its own confidence.
    var confidenceThreshold = 0.6
    private enum CodingKeys: String, CodingKey { case visible, confidence, box, aim, depthPoint }
    var center: [Double] { box.count == 4 ? [(box[0] + box[2]) / 2, (box[1] + box[3]) / 2] : [] }
    var visuallyUsable: Bool {
        visible && confidence.isFinite && confidenceThreshold.isFinite &&
        (0...1).contains(confidenceThreshold) && (confidenceThreshold...1).contains(confidence) &&
        box.count == 4 && box.allSatisfy({ $0.isFinite && (0...1).contains($0) }) &&
        box[2] - box[0] >= 0.015 && box[3] - box[1] >= 0.015
    }
    var usable: Bool {
        visuallyUsable && validShape
    }
    var validShape: Bool {
        box.count == 4 && aim.count == 2 && depthPoint.count == 2 &&
        (box + aim + depthPoint).allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        box[2] - box[0] >= 0.015 && box[3] - box[1] >= 0.015 &&
        [aim, depthPoint].allSatisfy { (box[0]...box[2]).contains($0[0]) && (box[1]...box[3]).contains($0[1]) }
    }
}

struct ROBWorkspaceObservation: Codable {
    let can: ROBWorkspaceDetection
    let orangeBucket: ROBWorkspaceDetection
    let leftArmHanging: Bool
    let rightArmHanging: Bool
    let hangingConfidence: Double
    var cans: [ROBWorkspaceDetection]? = nil
    subscript(_ target: ROBWorkspaceTarget) -> ROBWorkspaceDetection { target == .can ? can : orangeBucket }
    static let prompt = """
    Inspect this robot camera image. Output ONLY this exact JSON structure, replacing the
    example false/empty values with your observations. No explanation or Markdown:
    {"can":{"visible":false,"confidence":0.0,"box":[],"aim":[],"depthPoint":[]},"orangeBucket":{"visible":false,"confidence":0.0,"box":[],"aim":[],"depthPoint":[]},"leftArmHanging":false,"rightArmHanging":false,"hangingConfidence":0.0}
    Each box is [left,top,right,bottom], each aim/depthPoint is [x,y].
    All image coordinates are normalized 0..1, origin TOP LEFT. Missing objects: visible=false,
    confidence=0, box=[], aim=[], depthPoint=[]. Can means a real red/silver Coke beverage can;
    ignore drawings, screens and text. Its aim is the middle of its side wall for a side grasp.
    OrangeBucket means a real orange recycling bucket with a visible open top. Its box encloses
    that top, aim is the CENTER OF THE OPENING and depthPoint is a clearly visible ORANGE RIM
    pixel, not the background or bucket bottom. A closed orange box is not a bucket opening.
    Arm facts concern the ROBOT's physical left/right arms. Hanging requires seeing the actual
    arm hanging down; an invisible arm is false. Confidence is an observation, not permission.
    Never output instructions, joint targets, markdown, tools, or facts not visible in the image.
    """
    static func decode(_ text: String) throws -> Self {
        let bytes = Array(text.utf8)
        guard bytes.count <= 8192, let start = bytes.firstIndex(of: 0x7b) else {
            throw ROBWorkspaceObservationError.format("Local vision did not return a JSON observation.")
        }
        var nesting = 0, quoted = false, escaped = false, end: Int?
        for index in start..<bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false } else if byte == 0x5c { escaped = true } else if byte == 0x22 { quoted = false }
            } else if byte == 0x22 { quoted = true }
            else if byte == 0x7b { nesting += 1 }
            else if byte == 0x7d { nesting -= 1; if nesting == 0 { end = index; break } }
        }
        guard let end else { throw ROBWorkspaceObservationError.format("Local vision returned incomplete JSON.") }
        let suffix = String(decoding: bytes.dropFirst(end + 1), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix.isEmpty || suffix == "```" else {
            throw ROBWorkspaceObservationError.format("Local vision returned multiple answers or trailing content.")
        }
        let data = Data(bytes[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["can", "orangeBucket", "leftArmHanging", "rightArmHanging", "hangingConfidence"]) else {
            throw ROBWorkspaceObservationError.format("Local vision fields did not match the search schema.")
        }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ROBWorkspaceObservationError.format("Local vision observation has invalid field types.") }
        guard result.hangingConfidence.isFinite, (0...1).contains(result.hangingConfidence),
              [result.can, result.orangeBucket].allSatisfy({ detection in
                  detection.confidence.isFinite && (0...1).contains(detection.confidence) &&
                      (!detection.visible || detection.validShape)
              }) else { throw ROBWorkspaceObservationError.values("Local search coordinates or confidence are invalid.") }
        return result
    }
}

enum ROBWorkspaceObservationError: LocalizedError {
    case format(String), values(String)
    var errorDescription: String? { switch self { case .format(let text), .values(let text): return text } }
    var canRetryFormat: Bool { if case .format = self { return true }; return false }
}

/// Upright can geometry measured from three independent RGB-D body bands.
/// The detector's full box supplies endpoints only after unclipped depth and
/// plausible physical height/diameter checks; these are observations, not poses.
struct ROBWorkspaceCanSections: Codable {
    /// An explicit local-trial object prior, never a depth-band measurement or
    /// camera/body registration. Live source/receipt admission belongs to the
    /// search executor; these fields preserve how its geometry was estimated.
    struct ShapePriorEvidence: Codable {
        let kind: String
        let source: String
        let assumedHeightMeters: Double
        let assumedDiameterMeters: Double
        let planeRMSEMeters: Double
        let planePointCount: Int
        let planeSupportFraction: Double
        let silhouetteIoU: Double
        let silhouetteMaximumEdgeErrorPixels: Double
        var valid:Bool {
            kind=="local_visual_trial_known_empty_coke_cylinder" &&
                source=="fresh_RGB_base_ray_local_depth_table_plane_and_silhouette" &&
                assumedHeightMeters==0.120 && assumedDiameterMeters==0.066 &&
                planeRMSEMeters.isFinite && planeRMSEMeters>=0 && (3...10000).contains(planePointCount) &&
                planeSupportFraction.isFinite && planeSupportFraction>0 && planeSupportFraction<=1 &&
                silhouetteIoU.isFinite && silhouetteIoU>0 && silhouetteIoU<=1 &&
                silhouetteMaximumEdgeErrorPixels.isFinite && silhouetteMaximumEdgeErrorPixels>=0
        }
    }
    let top: [Double]
    let middle: [Double]
    let bottom: [Double]
    let heightMeters: Double
    let diameterMeters: Double
    /// RGB-D bands sample the visible wall. A measured projection may shift
    /// them to an estimated cylinder axis; legacy section records lack this.
    var surfaceToAxisOffsetMeters: [Double]? = nil
    var shapePriorEvidence: ShapePriorEvidence? = nil
    var valid: Bool {
        guard [top,middle,bottom].allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
              heightMeters.isFinite, (0.09...0.18).contains(heightMeters),
              diameterMeters.isFinite, (0.04...0.09).contains(diameterMeters) else { return false }
        if let prior=shapePriorEvidence {
            guard prior.valid,abs(heightMeters-prior.assumedHeightMeters)<1e-9,
                  abs(diameterMeters-prior.assumedDiameterMeters)<1e-9,
                  surfaceToAxisOffsetMeters==nil else {return false}
        }
        if let offset = surfaceToAxisOffsetMeters {
            guard offset.count == 3, offset.allSatisfy(\.isFinite),
                  abs(simd_length(SIMD3(offset[0],offset[1],offset[2]))-diameterMeters/2) <= 0.000001 else { return false }
        }
        let a = SIMD3(top[0],top[1],top[2]), b = SIMD3(bottom[0],bottom[1],bottom[2])
        let m = SIMD3(middle[0],middle[1],middle[2]), axis = a-b, length = simd_length(axis)
        return length.isFinite && abs(length-heightMeters) <= 0.001 && axis.z >= 0.6*length &&
            simd_distance(m,(a+b)/2) <= 0.001
    }
    /// Pure construction after a separately admitted local visual trial has
    /// checked its table plane, fresh silhouette and exact source. `base` is
    /// the estimated AXIS base center, not a measured reflective-wall sample.
    static func localKnownEmptyCokeCylinder(base:SIMD3<Double>,axis:SIMD3<Double>,planeRMSEMeters:Double,
        planePointCount:Int,planeSupportFraction:Double,silhouetteIoU:Double,
        silhouetteMaximumEdgeErrorPixels:Double)->Self? {
        guard [base,axis].allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}),simd_length(axis)>1e-9 else {return nil}
        let evidence=ShapePriorEvidence(kind:"local_visual_trial_known_empty_coke_cylinder",
            source:"fresh_RGB_base_ray_local_depth_table_plane_and_silhouette",assumedHeightMeters:0.120,
            assumedDiameterMeters:0.066,planeRMSEMeters:planeRMSEMeters,planePointCount:planePointCount,
            planeSupportFraction:planeSupportFraction,silhouetteIoU:silhouetteIoU,
            silhouetteMaximumEdgeErrorPixels:silhouetteMaximumEdgeErrorPixels)
        guard evidence.valid else {return nil}
        let delta=simd_normalize(axis)*0.120,top=base+delta,middle=base+delta/2
        let value=Self(top:[top.x,top.y,top.z],middle:[middle.x,middle.y,middle.z],bottom:[base.x,base.y,base.z],
            heightMeters:0.120,diameterMeters:0.066,surfaceToAxisOffsetMeters:nil,shapePriorEvidence:evidence)
        return value.valid ? value:nil
    }
    static func fit(topBand:SIMD3<Double>,middleBand:SIMD3<Double>,bottomBand:SIMD3<Double>,
                    diameterMeters:Double) -> Self? {
        guard [topBand,middleBand,bottomBand].allSatisfy({ [$0.x,$0.y,$0.z].allSatisfy(\.isFinite) }),
              diameterMeters.isFinite, (0.04...0.09).contains(diameterMeters) else { return nil }
        let axis = topBand-bottomBand, length = simd_length(axis), height = length/0.64
        guard length.isFinite, (0.09...0.18).contains(height), axis.z >= 0.6*length,
              simd_distance(middleBand,(topBand+bottomBand)/2) <= 0.025 else { return nil }
        let top = topBand + axis*(0.18/0.64), bottom = bottomBand-axis*(0.18/0.64), middle = (top+bottom)/2
        let result = Self(top:[top.x,top.y,top.z],middle:[middle.x,middle.y,middle.z],
            bottom:[bottom.x,bottom.y,bottom.z],heightMeters:height,diameterMeters:diameterMeters)
        return result.valid ? result : nil
    }
    static func measure(detection:ROBWorkspaceDetection,width:Int,height:Int,
                        fx:Double,fy:Double,cx:Double,cy:Double,depth:(Int,Int)->UInt16?,
                        view:ROBWorkspaceView,model:ROBGhostRobotModel, cameraToRobot:simd_double4x4? = nil) -> Self? {
        measureWithDiagnostics(detection:detection,width:width,height:height,fx:fx,fy:fy,cx:cx,cy:cy,
            depth:depth,view:view,model:model,cameraToRobot:cameraToRobot).sections
    }
    /// Bounded evidence from the same raw samples and unchanged fit gates.
    /// A failed band does not hide the remaining two bands from diagnostics.
    static func measureWithDiagnostics(detection:ROBWorkspaceDetection,width:Int,height:Int,
                        fx:Double,fy:Double,cx:Double,cy:Double,depth:(Int,Int)->UInt16?,
                        view:ROBWorkspaceView,model:ROBGhostRobotModel,cameraToRobot:simd_double4x4? = nil)
                        -> (sections:Self?,diagnostics:[String:Any]) {
        func number(_ value:Double)->Any {value.isFinite ? value as Any : NSNull()}
        var info:[String:Any]=["schema_version":1,"status":"rejected","box":detection.box.map(number),
            "width":width,"height":height,"intrinsics":[fx,fy,cx,cy].map(number),"bands":[],
            "thresholds":["minimum_valid_samples":9,"depth_min_mm":150,"depth_max_mm":3000,
                "maximum_MAD_m":0.025,"maximum_p90_p10_m":0.06,"height_m":[0.09,0.18],
                "diameter_m":[0.04,0.09],"minimum_axis_up_fraction":0.6,"maximum_middle_deviation_m":0.025]]
        func rejected(_ stage:String)->(sections:Self?,diagnostics:[String:Any]) {
            info["rejection_stage"]=stage;return(nil,info)
        }
        guard detection.usable else {return rejected("unusable_detection")}
        guard detection.box.allSatisfy({(0.02...0.98).contains($0)}) else {return rejected("clipped_box")}
        guard width>1,height>1,[fx,fy,cx,cy].allSatisfy(\.isFinite),fx>0,fy>0,
              (0..<Double(width)).contains(cx),(0..<Double(height)).contains(cy) else {return rejected("invalid_intrinsics")}
        guard let transform=cameraToRobot ?? view.cameraFrame(model:model) else {return rejected("camera_projection_unavailable")}
        let left = detection.box[0]*Double(width-1), right = detection.box[2]*Double(width-1)
        let top = detection.box[1]*Double(height-1), bottom = detection.box[3]*Double(height-1), u = (left+right)/2
        let radiusX = max(1,min(3,Int((right-left)*0.12))), radiusY = max(1,min(3,Int((bottom-top)*0.04)))
        var bandReports:[[String:Any]]=[]
        func band(_ label:String,_ fraction:Double) -> (point:SIMD3<Double>,depth:Double)? {
            let v = top+(bottom-top)*fraction, x = Int(u.rounded()), y = Int(v.rounded())
            var samples:[Double]=[],raw:[Any]=[],zeros=0,missing=0,outOfRange=0,outside=0
            for dy in -radiusY...radiusY { for dx in -radiusX...radiusX {
                guard (0..<width).contains(x+dx),(0..<height).contains(y+dy) else {outside+=1;continue}
                guard let mm=depth(x+dx,y+dy) else {missing+=1;raw.append(NSNull());continue}
                raw.append(Int(mm))
                if mm==0 {zeros+=1}
                if (150...3000).contains(mm) {samples.append(Double(mm)/1000)} else {outOfRange+=1}
            } }
            var report:[String:Any]=["label":label,"fraction":fraction,"pixel_center":[u,v],
                "rounded_pixel_center":[x,y],"radii":[radiusX,radiusY],"sample_count":raw.count,
                "valid_count":samples.count,"zero_count":zeros,"missing_count":missing,
                "out_of_range_count":outOfRange,"outside_image_count":outside,"raw_mm":raw]
            guard !samples.isEmpty else {
                report["rejection_stage"]="insufficient_valid_samples";report["minimum_count_pass"]=false
                bandReports.append(report);return nil
            }
            samples.sort();let z=samples[samples.count/2],deviations=samples.map{abs($0-z)}.sorted()
            let mad=deviations[deviations.count/2],p10=samples[samples.count/10],p90=samples[samples.count*9/10],spread=p90-p10
            let point = transform*SIMD4((u-cx)*z/fx,(v-cy)*z/fy,z,1)
            report["median_m"]=number(z);report["MAD_m"]=number(mad);report["p10_m"]=number(p10);report["p90_m"]=number(p90)
            report["spread_m"]=number(spread);report["median_xyz_m"]=[point.x,point.y,point.z].map(number)
            report["minimum_count_pass"]=samples.count>=9;report["MAD_pass"]=mad<=0.025;report["spread_pass"]=spread<=0.06
            let failure=samples.count<9 ? "insufficient_valid_samples" : mad>0.025 ? "MAD_exceeded" : spread>0.06 ? "p90_p10_exceeded" : nil
            report["rejection_stage"]=failure as Any? ?? NSNull();bandReports.append(report)
            guard failure==nil else {return nil}
            return (SIMD3(point.x,point.y,point.z),z)
        }
        let upperBand=band("top",0.18),middleBand=band("middle",0.50),lowerBand=band("bottom",0.82)
        info["bands"]=bandReports
        guard let upper=upperBand,let middle=middleBand,let lower=lowerBand else {
            let failed=bandReports.filter{($0["rejection_stage"] as? String) != nil}.map{($0["label"] as! String)+":"+($0["rejection_stage"] as! String)}
            info["failed_bands"]=failed;return rejected("band_depth_quality")
        }
        let diameter = (right-left)*middle.depth/fx
        let bandAxis=upper.point-lower.point,length=simd_length(bandAxis),fittedHeight=length/0.64
        let middleDeviation=simd_distance(middle.point,(upper.point+lower.point)/2)
        info["diameter_m"]=number(diameter);info["fitted_height_m"]=number(fittedHeight)
        info["axis_up_fraction"]=length>0 ? number(bandAxis.z/length):NSNull()
        info["middle_deviation_m"]=number(middleDeviation)
        guard let surface = fit(topBand:upper.point,middleBand:middle.point,bottomBand:lower.point,
            diameterMeters:diameter) else {
            if !diameter.isFinite || !(0.04...0.09).contains(diameter) {return rejected("diameter_outside_can_range")}
            if !length.isFinite || !(0.09...0.18).contains(fittedHeight) {return rejected("height_outside_can_range")}
            if !(bandAxis.z>=0.6*length) {return rejected("axis_not_upright")}
            if !(middleDeviation<=0.025) {return rejected("middle_band_not_on_axis")}
            return rejected("invalid_fitted_sections")
        }
        let a = SIMD3(surface.top[0],surface.top[1],surface.top[2])
        let b = SIMD3(surface.bottom[0],surface.bottom[1],surface.bottom[2])
        let axis = simd_normalize(a-b)
        let origin = SIMD3(transform.columns.3.x,transform.columns.3.y,transform.columns.3.z)
        let ray = middle.point-origin, radial = ray-axis*simd_dot(ray,axis)
        info["radial_ray_length_m"]=number(simd_length(radial))
        guard simd_length(radial) > 0.01 else { return rejected("radial_ray_too_short") }
        let offset = simd_normalize(radial)*(diameter/2)
        func shifted(_ p:[Double])->[Double] { [p[0]+offset.x,p[1]+offset.y,p[2]+offset.z] }
        let sections=Self(top:shifted(surface.top),middle:shifted(surface.middle),bottom:shifted(surface.bottom),
            heightMeters:surface.heightMeters,diameterMeters:diameter,
            surfaceToAxisOffsetMeters:[offset.x,offset.y,offset.z])
        info["status"]="accepted";info["rejection_stage"]=NSNull()
        return(sections,info)
    }
}

struct ROBWorkspaceLocatedObject: Codable {
    let target: ROBWorkspaceTarget
    let position: [Double]
    let confidence: Double
    let capturedAt: Double
    let sequence: UInt64
    let view: ROBWorkspaceView
    var openingRadius: Double? = nil
    var bucketShapePrior: ROBWorkspaceBucketOpeningPrior.Evidence? = nil
    var floorCorrectionDegrees: Double? = nil
    var sections: ROBWorkspaceCanSections? = nil
    var registrationID: String? = nil
    var point: SIMD3<Double> { SIMD3(position[0], position[1], position[2]) }
    func agrees(with other: Self) -> Bool {
        target == other.target && sequence != other.sequence && other.capturedAt > capturedAt &&
            other.capturedAt - capturedAt < 30_000 && simd_distance(point, other.point) <= 0.05
    }
}

/// Fresh world-space measurements can agree across neck views. A missing
/// depth sample supplies no evidence; it does not erase the last valid sample.
struct ROBWorkspaceLocationConfirmation {
    private var prior: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]
    mutating func observe(_ object: ROBWorkspaceLocatedObject) -> ROBWorkspaceLocatedObject? {
        let previous = prior[object.target]
        prior[object.target] = object
        guard let previous, previous.agrees(with:object) else { return nil }
        if object.target == .orangeBucket {
            guard let a = previous.openingRadius, let b = object.openingRadius,
                  a.isFinite, b.isFinite, abs(a-b) <= 0.02 else { return nil }
        } else if previous.sections != nil || object.sections != nil {
            guard let a = previous.sections, let b = object.sections, a.valid, b.valid,
                  abs(a.heightMeters-b.heightMeters) <= 0.015,
                  abs(a.diameterMeters-b.diameterMeters) <= 0.015 else { return nil }
        }
        return object
    }
    mutating func invalidate(_ target:ROBWorkspaceTarget) { prior.removeValue(forKey:target) }
}

/// Local preferences for one sandbox experiment. These are copied into the
/// immutable proposal; editing the file never changes an active operation.
/// Pace removes optional timing padding only. The existing trajectory minimum,
/// telemetry, lease and joint limits continue to apply to every dispatched step.
/// The sandbox supplies a finite task count before the one operation approval.
/// Legacy command names keep their original counts; perception and completion
/// checks are still repeated for every item by the executor.
enum ROBRecyclingBatchRequest {
    static let maximumCount = 8
    static let configuredCommands = ["left_recycle_cans", "right_recycle_cans"]

    /// The authorization keeps its exact target count; a resumed campaign job
    /// executes only its frozen remaining transfers. No grasp/hold earns credit.
    static func executionCount(requestedCount:Int,standingRemainingTransfers:Int?=nil)->Int? {
        guard (1...maximumCount).contains(requestedCount) else{return nil}
        guard let remaining=standingRemainingTransfers else{return requestedCount}
        guard (1...requestedCount).contains(remaining) else{return nil}
        return remaining
    }

    static func requestedCount(command: String, target: String) throws -> Int? {
        if configuredCommands.contains(command) {
            let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let count = Int(text), (1...maximumCount).contains(count) else {
                throw ROBGhostMotionError.blocked("Choose a whole number of cans from 1 to \(maximumCount) before requesting recycling.")
            }
            return count
        }
        switch command {
        case "left_recycle_can", "right_recycle_can": return 1
        case "left_recycle_two_cans", "right_recycle_two_cans": return 2
        case "right_recycle_three_cans": return 3
        default: return nil
        }
    }
}

struct ROBRecyclingTestParameters: Codable, Equatable {
    var motionPace: Double = 1.25
    var jawSettleSeconds: Double = 1.5
    var maximumPathDeviationMeters: Double = 0.003
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/TestingSandbox/recycling.json")
    }
    var isValid: Bool {
        motionPace.isFinite && (1...1.25).contains(motionPace) &&
        jawSettleSeconds.isFinite && (1...2).contains(jawSettleSeconds) &&
        maximumPathDeviationMeters.isFinite && (0...0.005).contains(maximumPathDeviationMeters)
    }
    static func load(file: URL = file) throws -> Self {
        guard FileManager.default.fileExists(atPath:file.path) else { return .init() }
        let data = try Data(contentsOf:file)
        guard data.count <= 4_096, let value = try? JSONDecoder().decode(Self.self,from:data), value.isValid else {
            throw ROBGhostMotionError.blocked("The recycling sandbox parameters are invalid; check pace, jaw settling and path adjustment.")
        }
        return value
    }
    func save(file: URL = Self.file) throws {
        guard isValid else { throw ROBGhostMotionError.blocked("The recycling sandbox parameters exceed their supported bounds.") }
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(self).write(to:file,options:.atomic)
    }
}

/// Operator-measured reach correction, bound to this robot's model/reference.
/// Raw sightings remain unchanged and never become permission. No default
/// offset is inferred when this local calibration file is absent.
struct ROBLeftCanReachCalibration: Codable {
    let modelID: String
    let referenceID: String
    let mappingID: String
    let translationMeters: [Double]
    let source: String
    /// A new measured optical transform needs its own local residual. Historical
    /// left-reach tuning belongs to the old provisional camera frame.
    var registrationID: String? = nil
    var toolLink: String? = nil
    var validRegionLowMeters: [Double]? = nil
    var validRegionHighMeters: [Double]? = nil
    var bucketYawDegrees: Double? = nil
    var bucketInwardMeters: Double? = nil
    var recoveryGraspClearanceMeters: Double? = nil
    var canOutwardMeters: Double? = nil
    var tabletopGraspHeightMeters: Double? = nil
    var tabletopCanBaseHeightMeters: Double? = nil
    /// Head-depth placement in effect when translationMeters was calibrated.
    /// Older files predate that adjustment and therefore use the raw frame.
    var depthTowardRobotMetersAtCalibration: Double? = nil
    static var file: URL { file(forPhysicalSide:"left") }
    static func file(forPhysicalSide side:String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/\(side == "right" ? "Right" : "Left")ArmCalibration/can-reach.json")
    }
    func effectiveTranslation(depthAlignment: ROBWorkspaceDepthAlignment.Snapshot? = ROBWorkspaceDepthAlignment.snapshot()) throws -> SIMD3<Double> {
        guard let depthAlignment, translationMeters.count == 3,
              translationMeters.allSatisfy({ $0.isFinite && abs($0) <= 0.15 }),
              (depthTowardRobotMetersAtCalibration ?? 0).isFinite,
              (0...0.30).contains(depthTowardRobotMetersAtCalibration ?? 0) else {
            throw ROBGhostMotionError.blocked("The can reach calibration or current head depth adjustment is invalid.")
        }
        // The camera observation moved toward ROB by this delta. Rebase its
        // residual reach offset in the opposite direction, preserving the
        // successful robot-frame target instead of shifting it a second time.
        let delta = depthAlignment.towardRobotMeters - (depthTowardRobotMetersAtCalibration ?? 0)
        let result = SIMD3(translationMeters[0]+delta,translationMeters[1],translationMeters[2])
        guard [result.x,result.y,result.z].allSatisfy({ $0.isFinite && abs($0) <= 0.15 }) else {
            throw ROBGhostMotionError.blocked("The rebased can reach correction exceeds its bounded translation.")
        }
        return result
    }
    static func load(model: ROBGhostRobotModel, can: ROBWorkspaceLocatedObject? = nil, file: URL? = nil,
                     depthAlignment: ROBWorkspaceDepthAlignment.Snapshot? = ROBWorkspaceDepthAlignment.snapshot(),
                     estimatedCameraProjectionIdentity:String? = nil) throws -> SIMD3<Double> {
        // A photo-origin estimate is a different coordinate model. Never read
        // or rebase legacy camera-space tuning into it. Measured local
        // registration residuals keep their existing independent precedence.
        if can?.registrationID == nil,estimatedCameraProjectionIdentity != nil {return .zero}
        guard let value = try scopedConfiguration(model:model,file:file ?? Self.file(forPhysicalSide:model.physicalSide),registrationID:can?.registrationID) else { return .zero }
        if let registration=can?.registrationID {
            guard value.registrationID==registration,value.toolLink==model.toolLink,
                  let low=value.validRegionLowMeters,let high=value.validRegionHighMeters,
                  low.count==3,high.count==3,let point=can?.point,
                  (0..<3).allSatisfy({point[$0]>=low[$0] && point[$0]<=high[$0]}) else { return .zero }
            // A residual taught in measured robot XYZ is not rebased by the
            // visualization-only head shift and does not inherit old tabletop Z.
            return SIMD3(value.translationMeters[0],value.translationMeters[1],value.translationMeters[2])
        }
        guard value.registrationID == nil else { return .zero }
        guard let depthAlignment else {
            throw ROBGhostMotionError.blocked("The current head depth adjustment is invalid.")
        }
        var correction = try value.effectiveTranslation(depthAlignment:depthAlignment)
        let outward = value.canOutwardMeters ?? 0
        if outward > 0 || value.tabletopGraspHeightMeters != nil || value.tabletopCanBaseHeightMeters != nil {
            guard let can, can.target == .can, can.position.count == 3, can.position.allSatisfy(\.isFinite) else {
                throw ROBGhostMotionError.blocked("Find the can again before applying its measured reach calibration.")
            }
            if outward > 0 {
                // The legacy outward nudge was taught in raw head placement.
                // Keep that direction when the cloud shifts or its residual
                // translation is resaved with a newer depth baseline.
                let direction = SIMD2(can.position[0]+depthAlignment.towardRobotMeters,can.position[1]), distance = simd_length(direction)
                guard distance.isFinite, distance >= 0.1 else {
                    throw ROBGhostMotionError.blocked("The can direction is too close to the robot origin for its outward reach calibration.")
                }
                let offset = direction / distance * outward
                correction += SIMD3(offset.x,offset.y,0)
            }
            if let base = value.tabletopCanBaseHeightMeters {
                guard let sections = can.sections, sections.valid else {
                    throw ROBGhostMotionError.blocked("Measure the can's top, middle and base before planning a middle-body grasp.")
                }
                correction.z = base + sections.heightMeters/2 - can.position[2]
            } else if let height = value.tabletopGraspHeightMeters {
                // A measured height is valid only on the calibrated tabletop.
                // Preserve the raw camera observation and bound its correction.
                correction.z = height - can.position[2]
            }
        }
        guard [correction.x,correction.y,correction.z].allSatisfy({ $0.isFinite && abs($0) <= 0.15 }) else {
            throw ROBGhostMotionError.blocked("The calibrated can reach correction exceeds its bounded translation.")
        }
        return correction
    }
    static func loadBucketYaw(model:ROBGhostRobotModel,file:URL? = nil,registrationID:String? = nil,
        estimatedCameraProjectionIdentity:String? = nil) throws -> Double {
        if registrationID == nil,estimatedCameraProjectionIdentity != nil {return 0}
        guard let value=try scopedConfiguration(model:model,file:file ?? Self.file(forPhysicalSide:model.physicalSide),registrationID:registrationID) else{return 0}
        return value.bucketYawDegrees ?? 0
    }
    static func loadBucketInward(model:ROBGhostRobotModel,file:URL? = nil,registrationID:String? = nil,
        estimatedCameraProjectionIdentity:String? = nil) throws -> Double {
        if registrationID == nil,estimatedCameraProjectionIdentity != nil {return 0}
        guard let value=try scopedConfiguration(model:model,file:file ?? Self.file(forPhysicalSide:model.physicalSide),registrationID:registrationID) else{return 0}
        return value.bucketInwardMeters ?? 0
    }
    static func loadRecoveryGraspClearance(model:ROBGhostRobotModel,file:URL? = nil) throws -> Double {
        try configuration(model:model,file:file ?? Self.file(forPhysicalSide:model.physicalSide))?.recoveryGraspClearanceMeters ?? 0
    }
    static func loadTabletopCanBaseHeight(model:ROBGhostRobotModel,file:URL? = nil,registrationID:String? = nil,
        estimatedCameraProjectionIdentity:String? = nil) throws -> Double? {
        if registrationID == nil,estimatedCameraProjectionIdentity != nil {return nil}
        return try scopedConfiguration(model:model,file:file ?? Self.file(forPhysicalSide:model.physicalSide),registrationID:registrationID)?.tabletopCanBaseHeightMeters
    }
    static func registeredFile(base:URL,registrationID:String)->URL {
        base.deletingLastPathComponent().appendingPathComponent("RegisteredReach")
            .appendingPathComponent(ROBGhostRobotModel.hash(Data(registrationID.utf8))+".json")
    }
    /// Explicit experiment correction; it preserves the historical prior-frame
    /// file and is valid only for this registration, tool and measured region.
    @discardableResult static func saveRegisteredResidual(model:ROBGhostRobotModel,registrationID:String,
        regionLowMeters:[Double],regionHighMeters:[Double],translationMeters:[Double],source:String,baseFile:URL) throws ->URL {
        guard !registrationID.isEmpty,registrationID.utf8.count<=512,!source.isEmpty,source.utf8.count<=1024,
              translationMeters.count==3,translationMeters.allSatisfy({$0.isFinite && abs($0)<=0.15}),
              regionLowMeters.count==3,regionHighMeters.count==3,
              (0..<3).allSatisfy({regionLowMeters[$0].isFinite && regionHighMeters[$0].isFinite &&
                  abs(regionLowMeters[$0])<=5 && abs(regionHighMeters[$0])<=5 && regionLowMeters[$0]<regionHighMeters[$0]}) else {
            throw ROBGhostMotionError.blocked("A reach correction needs a measured registration, tool, finite local region and translation within 15 cm.")
        }
        let value=Self(modelID:model.modelID,referenceID:model.referenceID,mappingID:model.selectedMappingID,
            translationMeters:translationMeters,source:source,registrationID:registrationID,toolLink:model.toolLink,
            validRegionLowMeters:regionLowMeters,validRegionHighMeters:regionHighMeters)
        let destination=registeredFile(base:baseFile,registrationID:registrationID)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(value).write(to:destination,options:.atomic)
        return destination
    }
    private static func scopedConfiguration(model:ROBGhostRobotModel,file:URL,registrationID:String?) throws ->Self? {
        guard let registrationID else { return try configuration(model:model,file:file) }
        let scoped=registeredFile(base:file,registrationID:registrationID)
        let candidate=FileManager.default.fileExists(atPath:scoped.path) ? scoped : file
        guard FileManager.default.fileExists(atPath:candidate.path) else{return nil}
        let data=try Data(contentsOf:candidate)
        guard data.count<=16_384 else{throw ROBGhostMotionError.blocked("The local reach calibration is too large.")}
        // An old provisional-frame file is not a measured-frame residual.
        // Its translation, tabletop datum and release offsets are ignored.
        guard let metadata=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              metadata["registrationID"] as? String==registrationID else{return nil}
        return try configuration(model:model,file:candidate)
    }
    private static func configuration(model:ROBGhostRobotModel,file:URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        let data = try Data(contentsOf:file)
        guard data.count <= 16_384, let value = try? JSONDecoder().decode(Self.self,from:data),
              value.modelID == model.modelID, value.referenceID == model.referenceID,
              value.mappingID == model.selectedMappingID, !value.source.isEmpty,
              value.translationMeters.count == 3, value.translationMeters.allSatisfy({ $0.isFinite && abs($0) <= 0.15 }),
              (value.bucketYawDegrees ?? 0).isFinite, abs(value.bucketYawDegrees ?? 0) <= 30,
              (value.bucketInwardMeters ?? 0).isFinite, (0...0.08).contains(value.bucketInwardMeters ?? 0),
              (value.recoveryGraspClearanceMeters ?? 0).isFinite, (0...0.15).contains(value.recoveryGraspClearanceMeters ?? 0),
              (value.canOutwardMeters ?? 0).isFinite, (0...0.03).contains(value.canOutwardMeters ?? 0),
              value.tabletopGraspHeightMeters.map({ $0.isFinite && (0.30...1.40).contains($0) }) ?? true,
              value.tabletopCanBaseHeightMeters.map({ $0.isFinite && (0.30...1.40).contains($0) }) ?? true,
              value.depthTowardRobotMetersAtCalibration.map({ $0.isFinite && (0...0.30).contains($0) }) ?? true,
              value.tabletopGraspHeightMeters == nil || value.tabletopCanBaseHeightMeters == nil,
              value.registrationID.map({!$0.isEmpty && $0.utf8.count<=512}) ?? true,
              value.toolLink.map({$0==model.toolLink}) ?? true,
              value.registrationID==nil || (value.toolLink==model.toolLink && value.validRegionLowMeters?.count==3 && value.validRegionHighMeters?.count==3),
              (value.validRegionLowMeters==nil && value.validRegionHighMeters==nil) ||
                (value.validRegionLowMeters?.count==3 && value.validRegionHighMeters?.count==3 &&
                 (0..<3).allSatisfy({ i in
                    let low=value.validRegionLowMeters![i],high=value.validRegionHighMeters![i]
                    return low.isFinite && high.isFinite && abs(low)<=5 && abs(high)<=5 && low<high
                 })) else {
            throw ROBGhostMotionError.blocked("The local can reach calibration is invalid or belongs to another physical arm/model.")
        }
        return value
    }
}

/// Measure vertical from a dominant floor plane before interpreting a low
/// bucket through the provisional neck-angle prior. This is a per-frame
/// camera correction, not a replacement for arm calibration or a saved grant.
enum ROBWorkspaceFloorAlignment {
    struct Result {
        let cameraFrame: simd_double4x4
        let correctionDegrees: Double
        let supportFraction: Double
    }
    static func fit(points: [SIMD3<Double>], cameraFrame: simd_double4x4) -> Result? {
        guard (300...10_000).contains(points.count), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        let camera = SIMD3(cameraFrame.columns.3.x,cameraFrame.columns.3.y,cameraFrame.columns.3.z)
        var best: (normal: SIMD3<Double>, height: Double, count: Int)?
        for i in 0..<600 {
            let a = points[(i*17)%points.count], b = points[(i*37+points.count/3)%points.count], c = points[(i*61+points.count*2/3)%points.count]
            let cross = simd_cross(b-a,c-a), length = simd_length(cross)
            guard length > 0.001 else { continue }
            var normal = cross/length
            if normal.z < 0 { normal = -normal }
            let d = -simd_dot(normal,a), height = simd_dot(normal,camera)+d
            guard normal.z >= cos(35 * .pi/180), (0.8...1.3).contains(height) else { continue }
            let count = points.reduce(0) { $0 + (abs(simd_dot(normal,$1)+d) <= 0.015 ? 1 : 0) }
            if count > (best?.count ?? 0) { best = (normal,height,count) }
        }
        guard let best, Double(best.count)/Double(points.count) >= 0.35 else { return nil }
        let rotation = simd_double4x4(simd_quatd(from: best.normal,to: SIMD3<Double>(0,0,1)))
        var corrected = rotation * cameraFrame
        corrected.columns.3 = SIMD4(camera.x,camera.y,best.height,1)
        return .init(cameraFrame: corrected, correctionDegrees: acos(min(1,best.normal.z))*180 / .pi,
            supportFraction: Double(best.count)/Double(points.count))
    }
}

/// A bucket release point comes from an observed horizontal circular rim and
/// recessed interior, never the center of a detector rectangle.
enum ROBWorkspaceBucketRim {
    static func fit(orange: [SIMD3<Double>], scene: [SIMD3<Double>]) -> (center: SIMD3<Double>, radius: Double)? {
        let points = orange.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard points.count >= 40 else { return nil }
        let heights = points.map(\.z).sorted(), top = heights[heights.count * 98 / 100]
        let rim = points.filter { abs($0.z - top) <= 0.018 }
        guard rim.count >= 25 else { return nil }
        var best: (SIMD2<Double>, Double, [SIMD3<Double>])?
        for iteration in 0..<120 {
            let a = rim[(iteration * 17) % rim.count], b = rim[(iteration * 37 + rim.count/3) % rim.count], c = rim[(iteration * 61 + rim.count*2/3) % rim.count]
            let ab = SIMD2(b.x-a.x, b.y-a.y), ac = SIMD2(c.x-a.x, c.y-a.y)
            let determinant = 2 * (ab.x*ac.y - ab.y*ac.x)
            guard abs(determinant) > 0.0001 else { continue }
            let d = SIMD2((simd_length_squared(ab)*ac.y - simd_length_squared(ac)*ab.y) / determinant,
                (ab.x*simd_length_squared(ac) - ac.x*simd_length_squared(ab)) / determinant)
            let center = SIMD2(a.x,a.y) + d, radius = simd_length(d)
            guard (0.06...0.28).contains(radius) else { continue }
            let inliers = rim.filter { abs(simd_distance(SIMD2($0.x,$0.y), center) - radius) <= 0.012 }
            if inliers.count > (best?.2.count ?? 0) { best = (center, radius, inliers) }
        }
        guard let (center, radius, inliers) = best, inliers.count >= 25, Double(inliers.count)/Double(rim.count) >= 0.65 else { return nil }
        let angles = inliers.map { atan2($0.y-center.y, $0.x-center.x) }.sorted()
        let gaps = zip(angles, angles.dropFirst()).map { $1 - $0 } + [angles[0] + 2 * .pi - angles.last!]
        guard 2 * Double.pi - gaps.max()! >= 160 * .pi / 180 else { return nil }
        let rimZ = inliers.map(\.z).sorted()[inliers.count/2]
        let interior = scene.filter { simd_distance(SIMD2($0.x,$0.y), center) < radius * 0.5 }
        guard interior.count >= 12,
              Double(interior.filter { $0.z < rimZ - 0.04 }.count) / Double(interior.count) >= 0.8 else { return nil }
        return (SIMD3(center.x,center.y,rimZ), radius)
    }
}

/// Explicit RGB/floor SHAPE PRIOR for the locally approved calibration trial.
/// It never reports a measured rim or a measured recessed interior. The
/// admitted tapered-bucket family is deliberately recorded with the result.
enum ROBWorkspaceBucketOpeningPrior {
    struct Evidence: Codable {
        let kind: String, source: String
        let assumedHeightToOpeningDiameterRange: [Double]
        let assumedBottomToOpeningRadiusRange: [Double]
        let contourRMSEPixels: Double, contourPointCount: Int
        let floorRMSEMeters: Double, floorPointCount: Int, floorSupportFraction: Double
        let commonOpeningRadiusMeters: Double, shapeInsetMeters: Double
        let maximumVariantCenterXYSpreadMeters: Double, maximumRimHeightMeters: Double
        let maximumBottomProjectionErrorPixels: Double
        var valid:Bool {
            kind == "local_visual_trial_RGB_opening_floor_shape_prior" &&
            source == "fresh_orange_upper_contour_surrounding_depth_floor_and_declared_tapered_bucket_family" &&
            assumedHeightToOpeningDiameterRange == [0.8,1.2] && assumedBottomToOpeningRadiusRange == [0.6,1.0] &&
            [contourRMSEPixels,floorRMSEMeters,floorSupportFraction,commonOpeningRadiusMeters,shapeInsetMeters,
             maximumVariantCenterXYSpreadMeters,maximumRimHeightMeters,maximumBottomProjectionErrorPixels].allSatisfy(\.isFinite) &&
            contourPointCount >= 30 && floorPointCount >= 40 && floorSupportFraction >= 0.35 && floorSupportFraction <= 1 &&
            contourRMSEPixels >= 0 && floorRMSEMeters >= 0 && floorRMSEMeters <= 0.012 &&
            commonOpeningRadiusMeters >= 0.068 && commonOpeningRadiusMeters <= 0.28 && shapeInsetMeters >= 0.010 &&
            maximumVariantCenterXYSpreadMeters >= 0 && maximumRimHeightMeters.isFinite && maximumBottomProjectionErrorPixels >= 0
        }
    }
    struct Estimate { let center:SIMD3<Double>, radius:Double, evidence:Evidence }
    private static func solve(_ rows:[SIMD3<Double>],_ values:[Double])->SIMD3<Double>? {
        guard rows.count==values.count,rows.count>=3 else{return nil}
        var a=Array(repeating:Array(repeating:0.0,count:4),count:3)
        for (r,v) in zip(rows,values) {for i in 0..<3 {for j in 0..<3 {a[i][j]+=r[i]*r[j]};a[i][3]+=r[i]*v}}
        for c in 0..<3 {let p=(c..<3).max(by:{abs(a[$0][c])<abs(a[$1][c])})!;guard abs(a[p][c])>1e-10 else{return nil};a.swapAt(c,p)
            let d=a[c][c];for j in c..<4 {a[c][j]/=d};for i in 0..<3 where i != c {let f=a[i][c];for j in c..<4 {a[i][j]-=f*a[c][j]}}}
        let r=SIMD3(a[0][3],a[1][3],a[2][3]);return [r.x,r.y,r.z].allSatisfy(\.isFinite) ? r:nil
    }
    static func estimate(box:[Double],width:Int,height:Int,fx:Double,fy:Double,cx:Double,cy:Double,
                         cameraToRobot:simd_double4x4,depth:(Int,Int)->UInt16?,
                         color:(Int,Int)->SIMD3<Double>?) -> Estimate? {
        guard box.count==4,box.allSatisfy({$0.isFinite && (0.02...0.98).contains($0)}),box[2]>box[0],box[3]>box[1],
              width>1,height>1,[fx,fy,cx,cy].allSatisfy(\.isFinite),fx>0,fy>0 else{return nil}
        let x0=Int(box[0]*Double(width-1)),x1=Int(box[2]*Double(width-1)),y0=Int(box[1]*Double(height-1)),y1=Int(box[3]*Double(height-1))
        let w=x1-x0+1,h=y1-y0+1,scale=max(1,Double(width)/640)
        guard w>=24,h>=24,w*h<=180_000 else{return nil}
        var mask=Array(repeating:false,count:w*h)
        for y in 0..<h {for x in 0..<w {if let c=color(x+x0,y+y0),[c.x,c.y,c.z].allSatisfy(\.isFinite) {
            mask[y*w+x]=c.x>0.3 && c.x-c.y>0.22 && c.x-c.z>0.32
        }}}
        var visited=Array(repeating:false,count:mask.count),component:[Int]=[]
        for seed in mask.indices where mask[seed] && !visited[seed] {
            var queue=[seed],index=0;visited[seed]=true
            while index<queue.count {let p=queue[index];index+=1;let x=p%w,y=p/w
                for q in [x>0 ? p-1:-1,x+1<w ? p+1:-1,y>0 ? p-w:-1,y+1<h ? p+w:-1] where q>=0 && mask[q] && !visited[q] {visited[q]=true;queue.append(q)}}
            if queue.count>component.count {component=queue}
        }
        guard component.count>=200,Double(component.count)/Double(w*h)<0.9 else{return nil}
        var columns=Array(repeating:[Int](),count:w)
        for p in component {columns[p%w].append(p/w)}
        let edges=columns.enumerated().compactMap {x,ys -> SIMD2<Double>? in guard ys.count>=4,let y=ys.min() else{return nil};return SIMD2(Double(x+x0),Double(y+y0))}
        guard edges.count>=30,let xmin=edges.map(\.x).min(),let xmax=edges.map(\.x).max(),xmax-xmin>=24 else{return nil}
        let mid=(xmin+xmax)/2,half=(xmax-xmin)/2
        var ellipse:(cx:Double,cy:Double,a:Double,b:Double,rmse:Double,support:[SIMD2<Double>])?
        for center in stride(from:mid-3*scale,through:mid+3*scale,by:0.5*scale) {
            for radius in stride(from:half-scale,through:half+3.5*scale,by:0.5*scale) where radius>0 {
                let selected=edges.filter{abs(($0.x-center)/radius)<0.94};guard selected.count>=30 else{continue}
                let xs=selected.map{sqrt(max(0,1-pow(($0.x-center)/radius,2)))},ys=selected.map(\.y)
                let n=Double(xs.count),sx=xs.reduce(0,+),sy=ys.reduce(0,+),sxx=xs.reduce(0){$0+$1*$1},sxy=zip(xs,ys).reduce(0){$0+$1.0*$1.1}
                let det=n*sxx-sx*sx;guard det>1e-8 else{continue}
                let b=(sx*sy-n*sxy)/det,c=(sy+b*sx)/n
                guard b>radius*0.25,b<radius*1.2 else{continue}
                let error=sqrt(zip(xs,ys).reduce(0){$0+pow($1.1-(c-b*$1.0),2)}/n)
                if error<(ellipse?.rmse ?? .infinity) {ellipse=(center,c,radius,b,error,selected)}
            }
        }
        guard let e=ellipse,e.rmse<=2.5*scale,e.cx-e.a>Double(x0)-5*scale,e.cx+e.a<Double(x1)+5*scale else{return nil}
        let middleY=component.filter{abs(Double($0%w+x0)-e.cx)<e.a*0.3}.map{Double($0/w+y0)}.sorted()
        guard middleY.count>=20 else{return nil}
        let bottom=middleY[middleY.count*99/100]
        guard bottom-e.cy-e.b>=e.b*0.1,bottom-e.cy-e.b<=e.b*1.2 else{return nil}
        // An observed shadowed interior below a bright curved lip is required;
        // a flat uniform orange disk does not become an opening from its box.
        func luma(_ c:SIMD3<Double>)->Double {0.299*c.x+0.587*c.y+0.114*c.z}
        let lip=e.support.compactMap{color(Int($0.x),min(height-1,Int($0.y)+3))}.map(luma)
        let inside=(-2...2).flatMap{dy in (-2...2).compactMap{dx in color(Int(e.cx)+dx,Int(e.cy)+dy)}}.map(luma)
        guard !lip.isEmpty,!inside.isEmpty,lip.reduce(0,+)/Double(lip.count)-inside.reduce(0,+)/Double(inside.count)>=0.045 else{return nil}
        let origin=SIMD3(cameraToRobot.columns.3.x,cameraToRobot.columns.3.y,cameraToRobot.columns.3.z)
        func ray(_ x:Double,_ y:Double)->SIMD3<Double> {let r=cameraToRobot*SIMD4((x-cx)/fx,(y-cy)/fy,1,0);return SIMD3(r.x,r.y,r.z)}
        var points:[SIMD3<Double>]=[];let pad=Int(50*scale),step=max(2,Int(3*scale))
        for y in stride(from:max(0,y0-pad),through:min(height-1,y1+pad),by:step) {for x in stride(from:max(0,x0-pad),through:min(width-1,x1+pad),by:step) {
            if (x0-3...x1+3).contains(x) && (y0-3...y1+3).contains(y) {continue}
            if let mm=depth(x,y),(200...3000).contains(mm) {points.append(origin+ray(Double(x),Double(y))*Double(mm)/1000)}
        }}
        guard points.count>=80 else{return nil}
        var best:(n:SIMD3<Double>,d:Double,support:[SIMD3<Double>])?
        for i in 0..<128 {let a=points[(i*17)%points.count],b=points[(i*37+points.count/3)%points.count],c=points[(i*61+points.count*2/3)%points.count]
            let cross=simd_cross(b-a,c-a),length=simd_length(cross);guard length>0.001 else{continue};var n=cross/length;if n.z<0 {n = -n};let d = -simd_dot(n,a)
            guard n.z>=cos(35 * .pi/180),(0.6...1.5).contains(simd_dot(n,origin)+d) else{continue}
            let support=points.filter{abs(simd_dot(n,$0)+d)<=0.015};if support.count>(best?.support.count ?? 0) {best=(n,d,support)}
        }
        guard let floor=best,floor.support.count>=40,Double(floor.support.count)/Double(points.count)>=0.35,
              let ab=solve(floor.support.map{SIMD3($0.x,$0.y,1)},floor.support.map(\.z)) else{return nil}
        let n=simd_normalize(SIMD3(-ab.x,-ab.y,1)),d = -ab.z/sqrt(ab.x*ab.x+ab.y*ab.y+1),cameraHeight=simd_dot(n,origin)+d
        let floorRMSE=sqrt(floor.support.reduce(0){$0+pow(simd_dot(n,$1)+d,2)}/Double(floor.support.count))
        guard n.z>=cos(35 * .pi/180),floorRMSE<=0.012,cameraHeight>0.6,cameraHeight<1.5 else{return nil}
        let axis=simd_normalize(SIMD3(1,0,0)-n*n.x),other=simd_cross(n,axis)
        var ground:[SIMD3<Double>]=[]
        for p in e.support {let r=ray(p.x,p.y),den=simd_dot(n,r);guard den < -0.1 else{return nil};let distance = -cameraHeight/den;guard distance>0,distance<3 else{return nil};ground.append(origin+r*distance)}
        let uv=ground.map{SIMD2(simd_dot($0,axis),simd_dot($0,other))}
        guard let circle=solve(uv.map{SIMD3(2*$0.x,2*$0.y,1)},uv.map{simd_length_squared($0)}) else{return nil}
        let radicand=circle.z+circle.x*circle.x+circle.y*circle.y;guard radicand>0 else{return nil}
        let r0=sqrt(radicand),c0=axis*circle.x+other*circle.y-n*d
        let radialRMSE=sqrt(uv.reduce(0){$0+pow(simd_distance($1,SIMD2(circle.x,circle.y))-r0,2)}/Double(uv.count))
        guard radialRMSE<=0.012 else{return nil}
        let inverse=simd_inverse(cameraToRobot)
        func project(_ p:SIMD3<Double>)->SIMD2<Double>? {let q=inverse*SIMD4(p.x,p.y,p.z,1);guard q.z>0 else{return nil};return SIMD2(fx*q.x/q.z+cx,fy*q.y/q.z+cy)}
        var variants:[(c:SIMD3<Double>,r:Double,h:Double)]=[],bottomError=0.0
        for aspect in [0.8,1.0,1.2] {let h=2*aspect*r0/(1+2*aspect*r0/cameraHeight),fraction=(cameraHeight-h)/cameraHeight
            let c=origin+(c0-origin)*fraction,r=r0*fraction;guard (0.12...0.5).contains(h),(0.06...0.28).contains(r) else{return nil};variants.append((c,r,h))
            // The admitted taper family must explain visible floor contact
            // within the explicitly assumed35mm local trial precision.
            var bestError=Double.infinity
            for taper in [0.6,0.8,1.0] {var projected:[SIMD2<Double>]=[]
                for k in 0..<72 {let angle=Double(k)*2 * .pi/72;if let p=project(c-n*h+(axis*cos(angle)+other*sin(angle))*r*taper) {projected.append(p)}}
                if let low=projected.max(by:{$0.y<$1.y}) {bestError=min(bestError,simd_distance(low,SIMD2(e.cx,bottom)))}
            }
            bottomError=max(bottomError,bestError)
        }
        guard bottomError<=18*scale else{return nil}
        let selected=variants[1].c,xy=SIMD2(selected.x,selected.y)
        let spread=variants.map{simd_distance(SIMD2($0.c.x,$0.c.y),xy)}.max()!,rimHeight=variants.map{$0.c.z+sqrt(max(0,1-n.z*n.z))*$0.r}.max()!
        let inset=max(0.010,floorRMSE+3*radialRMSE+e.rmse*cameraHeight/min(fx,fy))
        let common=variants.map{$0.r*n.z-simd_distance(SIMD2($0.c.x,$0.c.y),xy)}.min()!-inset
        guard common>=0.068 else{return nil}
        let evidence=Evidence(kind:"local_visual_trial_RGB_opening_floor_shape_prior",source:"fresh_orange_upper_contour_surrounding_depth_floor_and_declared_tapered_bucket_family",
            assumedHeightToOpeningDiameterRange:[0.8,1.2],assumedBottomToOpeningRadiusRange:[0.6,1.0],contourRMSEPixels:e.rmse,contourPointCount:e.support.count,
            floorRMSEMeters:floorRMSE,floorPointCount:floor.support.count,floorSupportFraction:Double(floor.support.count)/Double(points.count),
            commonOpeningRadiusMeters:common,shapeInsetMeters:inset,maximumVariantCenterXYSpreadMeters:spread,maximumRimHeightMeters:rimHeight,maximumBottomProjectionErrorPixels:bottomError)
        guard evidence.valid else{return nil}
        return Estimate(center:SIMD3(xy.x,xy.y,rimHeight),radius:common,evidence:evidence)
    }
}

/// Shared numerical horizontal-jaw IK only. It neither checks the world nor
/// grants motion; zero tool offset preserves the original grasp preview math.
fileprivate struct ROBCanHorizontalIK {
    let chain:[ROBGhostRobotModel.Joint]
    let allowed:[String:ClosedRange<Double>]
    let tip:([String:Double])->SIMD3<Double>
    let tiltDegrees:([String:Double])->Double
    let loss:([String:Double],SIMD3<Double>)->Double
    let closest:(SIMD3<Double>,[String:Double])->[String:Double]
    init(model:ROBGhostRobotModel,baseline:[String:Double],side:String,pointInTool:SIMD3<Double> = .zero)throws {
        func tip(_ q: [String: Double]) -> SIMD3<Double> {
            let frame = model.frames(q)[side + "_tool"]!
            if pointInTool == .zero {return SIMD3(frame.columns.3.x,frame.columns.3.y,frame.columns.3.z)}
            let p=frame*SIMD4(pointInTool.x,pointInTool.y,pointInTool.z,1)
            return SIMD3(p.x,p.y,p.z)
        }
        let chain = model.joints.filter { $0.name.hasPrefix(side + "_joint") }
        let selectedModel=model.physicalSide==side ? model:try ROBGhostRobotModel(directory:model.directory,physicalSide:side)
        let rawBounds=ROBWorkspaceCollisionPlan.jointBounds(model:selectedModel)
        let allowed=Dictionary(uniqueKeysWithValues:(0..<7).map { index in
            let lower=rawBounds[index].lowerBound-selectedModel.armUprightPrior[index]
            let upper=rawBounds[index].upperBound-selectedModel.armUprightPrior[index]
            return (side+"_joint\(index+1)",lower...upper)
        })
        // Captured gripper: +Z approaches, +Y spans the jaw opening; +X is
        // its thin plane normal. Keep +Y/+Z horizontal, including wrist roll.
        func features(_ q: [String: Double]) -> [Double] {
            let frame = model.frames(q)[side + "_tool"]!
            let point:SIMD3<Double>
            if pointInTool == .zero {point=SIMD3(frame.columns.3.x,frame.columns.3.y,frame.columns.3.z)}
            else {let p=frame*SIMD4(pointInTool.x,pointInTool.y,pointInTool.z,1);point=SIMD3(p.x,p.y,p.z)}
            return [point.x,point.y,point.z,frame.columns.1.z * 0.25,frame.columns.2.z * 0.25]
        }
        func tiltDegrees(_ q: [String: Double]) -> Double {
            let values = features(q)
            return asin(min(1, max(abs(values[3]), abs(values[4])) / 0.25)) * 180 / .pi
        }
        func loss(_ q: [String: Double], _ target: SIMD3<Double>) -> Double {
            let values = features(q)
            return simd_length_squared(tip(q) - target) + values[3]*values[3] + values[4]*values[4]
        }
        func solve(_ matrix: [Double], _ rhs: [Double]) -> [Double]? {
            var a = matrix, b = rhs
            for column in 0..<5 {
                let pivot = (column..<5).max { abs(a[$0*5+column]) < abs(a[$1*5+column]) }!
                guard abs(a[pivot*5+column]) > 1e-12 else { return nil }
                for k in 0..<5 { a.swapAt(column*5+k, pivot*5+k) }; b.swapAt(column, pivot)
                let divisor = a[column*5+column]
                for k in column..<5 { a[column*5+k] /= divisor }; b[column] /= divisor
                for row in 0..<5 where row != column {
                    let factor = a[row*5+column]
                    for k in column..<5 { a[row*5+k] -= factor * a[column*5+k] }
                    b[row] -= factor * b[column]
                }
            }
            return b.allSatisfy(\.isFinite) ? b : nil
        }
        func closest(_ target: SIMD3<Double>, _ seed: [String: Double]) -> [String: Double] {
            var q=seed
            for joint in chain {
                let range=allowed[joint.name]!
                q[joint.name]=max(range.lowerBound,min(range.upperBound,seed[joint.name,default:0]))
            }
            var best=q,bestLoss=Double.infinity
            let goal = [target.x, target.y, target.z, 0, 0]
            for _ in 0..<250 {
                let current = features(q), delta = zip(goal, current).map(-)
                let loss = delta.reduce(0) { $0 + $1*$1 }
                if loss < bestLoss { bestLoss = loss; best = q }
                if sqrt(delta.prefix(3).reduce(0) { $0 + $1*$1 }) < 0.004 && max(abs(current[3]), abs(current[4])) < 0.008 { break }
                let columns = chain.map { joint -> [Double] in
                    var shifted = q; shifted[joint.name, default: 0] += 0.0001
                    return zip(features(shifted), current).map { ($0 - $1) / 0.0001 }
                }
                var normal = [Double](repeating: 0, count: 25)
                for row in 0..<5 { for col in 0..<5 {
                    normal[row*5+col] = columns.reduce(row == col ? 0.0004 : 0) { $0 + $1[row]*$1[col] }
                } }
                guard let correction = solve(normal, delta) else { break }
                let changes = columns.map { zip($0, correction).reduce(0) { $0 + $1.0*$1.1 } }
                let scale = min(1, 0.06 / max(0.000001, changes.map(abs).max() ?? 0))
                for (joint, change) in zip(chain, changes) {
                    let range=allowed[joint.name]!
                    q[joint.name] = max(range.lowerBound, min(range.upperBound, q[joint.name, default: 0] + change * scale))
                }
            }
            // Equivalent half-turns preserve the horizontal jaw line. Prefer
            // the branch nearest the starting wrist, avoiding approach flips.
            let wrist = side + "_joint7"
            let reference = seed[wrist, default: baseline[wrist, default: 0]]
            let wristRange=allowed[wrist]!
            for delta in [-Double.pi, Double.pi] {
                let candidate = best[wrist, default: 0] + delta
                if wristRange.contains(candidate), abs(candidate-reference) < abs(best[wrist, default: 0]-reference) {
                    best[wrist] = candidate
                }
            }
            return best
        }
        self.chain=chain;self.allowed=allowed;self.tip=tip
        self.tiltDegrees=tiltDegrees;self.loss=loss;self.closest=closest
    }
}

/// Visual rehearsal only. Deliberately separate from executable proposals:
/// selecting a right-hand model does not assert a right-arm hardware mapping.
struct ROBCanGrabPreview {
    struct Step {
        let pose: [String: Double]
        let seconds: Double
        let stage: String
        var jawAction: ROBLeftGestureProposal.JawAction? = nil
    }
    let can: ROBWorkspaceLocatedObject
    let side: String
    let baseline: [String: Double]
    let steps: [Step]
    let graspError: Double
    let gripperTiltDegrees: Double
    let reachesCan: Bool
    var reachOffset: [Double] = [0,0,0]
    /// Ghost prefix from the measured start through a can-derived pregrasp.
    /// Physical callers plan every connector separately against the live map.
    var dynamicEntryStepCount: Int = 0
    var dynamicEntryWaypoints: [[String:Double]] {
        Array(steps.prefix(dynamicEntryStepCount+1).dropFirst().map(\.pose))
    }
    var recyclingBodySteps: ArraySlice<Step> { steps.dropFirst(dynamicEntryStepCount) }
    var calibratedGraspPoint: SIMD3<Double> { can.point + SIMD3(reachOffset[0],reachOffset[1],reachOffset[2]) }
    var seconds: Double { steps.reduce(0) { $0 + $1.seconds } }
    /// Every generated entry connector receives the same registered full-arm,
    /// open-jaw and observed-space checks as an ordinary workspace path.
    func plannedDynamicEntry(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,
                             generation:UInt64,sceneID:UUID,cameraGeneration:UUID,
                             nowMilliseconds:Double) throws -> ROBWorkspaceCollisionPlan {
        guard dynamicEntryStepCount>0,dynamicEntryStepCount<steps.count,
              model.physicalSide==side,!dynamicEntryWaypoints.isEmpty else {
            throw ROBGhostMotionError.blocked("The can-derived entry prefix is incomplete.")
        }
        let start=model.vendorLeft(baseline)
        var previous=start,segments:[ROBLeftGestureProposal.Step]=[]
        for pose in dynamicEntryWaypoints {
            let goal=model.vendorLeft(pose)
            let connector=try ROBWorkspaceCollisionPlan.make(from:previous,to:goal,map:map,model:model,
                generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
            segments += connector.steps.map { .init(positions:$0.positions,seconds:$0.seconds,
                jawAction:nil,stage:"Corkscrew entry from measured start") }
            previous=goal
        }
        return try ROBWorkspaceCollisionPlan.review(baseline:start,steps:segments,map:map,model:model,
            generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
    }
    var helpRequest: String? {
        // An orientation-only failure must not be described as too far away.
        graspError > 0.012 ? ROBWorkspaceReachError.outOfReach(.can).helpRequest : nil
    }

    /// Compare distal collision-hull centers, rather than the tool alone, to
    /// choose rearward shoulder rotation in the current side's FK convention.
    static func rearwardJoint1Direction(model: ROBGhostRobotModel, baseline: [String:Double], side: String) -> Double {
        let name=side+"_joint1",joint=model.joints.first { $0.name==name }!
        let links=["three","four","five","six","seven"].map { side+"_"+$0+"_Link" }
        func meanX(_ pose:[String:Double])->Double {
            let bounds=model.worldCollisionBounds(positions:pose)
            let centers=links.compactMap { bounds[$0].map { ($0.low.x+$0.high.x)/2 } }
            return centers.reduce(0,+)/Double(max(1,centers.count))
        }
        let origin=meanX(baseline)
        let candidates=[1.0,-1.0].map { sign -> (Double,Double) in
            var pose=baseline
            pose[name]=max(joint.lower,min(joint.upper,baseline[name,default:0]+sign*0.05))
            return (sign,meanX(pose)-origin)
        }
        return candidates.min { $0.1<$1.1 }!.0
    }

    private static func forearmHullCenters(model:ROBGhostRobotModel,pose:[String:Double],side:String)->[SIMD3<Double>] {
        let bounds=model.worldCollisionBounds(positions:pose)
        return (["four","five","six","seven"].map { side+"_"+$0+"_Link" }+[side+"_tool"]).compactMap {
            bounds[$0].map { ($0.low+$0.high)/2 }
        }
    }
    static func outwardJoint2Direction(model:ROBGhostRobotModel,baseline:[String:Double],side:String)->Double {
        let name=side+"_joint2",joint=model.joints.first { $0.name==name }!
        return [1.0,-1.0].map { sign -> (Double,Double) in
            var pose=baseline;pose[name]=max(joint.lower,min(joint.upper,baseline[name,default:0]+sign*0.05))
            let centers=forearmHullCenters(model:model,pose:pose,side:side)
            return (sign,centers.reduce(0) { $0+abs($1.y) }/Double(max(1,centers.count)))
        }.max { $0.1<$1.1 }!.0
    }
    static func forwardJoint3Direction(model:ROBGhostRobotModel,baseline:[String:Double],side:String)->Double {
        let name=side+"_joint3",joint=model.joints.first { $0.name==name }!
        return [1.0,-1.0].map { sign -> (Double,Double) in
            var pose=baseline;pose[name]=max(joint.lower,min(joint.upper,baseline[name,default:0]+sign*0.05))
            let centers=forearmHullCenters(model:model,pose:pose,side:side)
            return (sign,centers.reduce(0) { $0+$1.x }/Double(max(1,centers.count)))
        }.max { $0.1<$1.1 }!.0
    }

    static func make(can: ROBWorkspaceLocatedObject, model: ROBGhostRobotModel,
                     baseline: [String: Double], side: String = "left", now: Double = Date().timeIntervalSince1970 * 1000,
                     bucket: ROBWorkspaceLocatedObject? = nil, reachOffset: SIMD3<Double> = .zero,
                     bucketYawDegrees: Double = 0, bucketInwardMeters: Double = 0,
                     rearwardJoint1Radians: Double = 0.24) throws -> Self {
        guard can.target == .can, can.position.count == 3, can.position.allSatisfy(\.isFinite),
              ["left", "right"].contains(side),
              can.confidence.isFinite, (0.35...1).contains(can.confidence), can.sequence > 0,
              can.capturedAt.isFinite, now.isFinite, (0...60_000).contains(now - can.capturedAt),
              baseline.values.allSatisfy(\.isFinite),
              [reachOffset.x,reachOffset.y,reachOffset.z].allSatisfy({ $0.isFinite && abs($0) <= 0.15 }),
              bucketYawDegrees.isFinite, abs(bucketYawDegrees) <= 30,
              bucketInwardMeters.isFinite, (0...0.08).contains(bucketInwardMeters),
              rearwardJoint1Radians.isFinite, (0.12...0.40).contains(rearwardJoint1Radians) else {
            throw ROBGhostMotionError.blocked("Find the can again; its measured position is missing or older than 60 seconds.")
        }
        let graspPoint = can.point + reachOffset
        let ik=try ROBCanHorizontalIK(model:model,baseline:baseline,side:side)
        let chain=ik.chain,allowed=ik.allowed
        let tip=ik.tip,tiltDegrees=ik.tiltDegrees,loss=ik.loss,closest=ik.closest
        var previous = baseline, steps: [Step] = []
        func append(_ pose: [String: Double], _ stage: String, dwell: Double = 0, action: ROBLeftGestureProposal.JawAction? = nil) {
            let angle = chain.map { abs(pose[$0.name, default: 0] - previous[$0.name, default: 0]) }.max() ?? 0
            steps.append(.init(pose: pose, seconds: max(0.8, angle / 0.6) + dwell, stage: stage, jawAction: action)); previous = pose
        }
        append(baseline, "Measured start (ghost only; clearance unverified)")
        func shifted(_ pose:[String:Double],joint index:Int,delta:Double)->[String:Double] {
            let name=side+"_joint\(index)",range=allowed[name]!
            var result=pose;result[name]=max(range.lowerBound,min(range.upperBound,pose[name,default:0]+delta));return result
        }
        let outwardJ2=outwardJoint2Direction(model:model,baseline:baseline,side:side)
        let outwardLift=shifted(baseline,joint:2,delta:outwardJ2*0.10)
        append(outwardLift,"Corkscrew: small J2 outward lift (clearance unverified)")
        let rearward=rearwardJoint1Direction(model:model,baseline:outwardLift,side:side)
        let forwardJ3=forwardJoint3Direction(model:model,baseline:outwardLift,side:side)
        var spiral=shifted(outwardLift,joint:1,delta:rearward*rearwardJoint1Radians)
        spiral=shifted(spiral,joint:2,delta:outwardJ2*0.10)
        spiral=shifted(spiral,joint:3,delta:forwardJ3*rearwardJoint1Radians*0.75)
        append(spiral,"Corkscrew: J1 rearward + J2 outward + J3 forearm forward (clearance unverified)")
        let spiralTip=tip(spiral),outward=side=="left" ? 1.0 : -1.0
        let liftTarget=SIMD3(spiralTip.x,spiralTip.y+outward*0.02,max(spiralTip.z+0.18,graspPoint.z+0.12))
        let raised=closest(liftTarget,spiral)
        append(raised,"Corkscrew: lift and level forearm (clearance unverified)")
        let approachTarget = graspPoint + SIMD3(0, 0, 0.12)
        var approach = closest(approachTarget, raised)
        // A cross-body target can trap the numerical solver in a local
        // minimum. Compare bounded shoulder seeds; never move the target.
        for shoulder in [-1.5, -0.5, 0.5, 1.5] where simd_distance(tip(approach), approachTarget) > 0.012 || tiltDegrees(approach) > 5 {
            var alternate = raised; alternate[side + "_joint1"] = shoulder
            let candidate = closest(approachTarget, alternate)
            if loss(candidate, approachTarget) < loss(approach, approachTarget) { approach = candidate }
        }
        append(approach, "Can-derived horizontal pregrasp (clearance unverified)")
        let entryStepCount=steps.count-1
        var grasp = approach
        for index in 1...4 {
            grasp = closest(graspPoint + SIMD3(0, 0, 0.12 * (1 - Double(index)/4)), grasp)
            if index < 4 { append(grasp, "Final approach — horizontal jaws") }
        }
        let error = simd_distance(tip(grasp), graspPoint)
        let tilt = tiltDegrees(grasp)
        let ready = error <= 0.012 && tilt <= 5
        append(grasp, ready ? "Grasp pose" : "Closest horizontal reach — grasp unconfirmed")
        if ready {
            append(grasp, "Close jaws (simulation)", dwell: 1, action: .grip)
            let liftTarget = graspPoint + SIMD3(0, 0, 0.06)
            let lift = closest(liftTarget, grasp)
            if simd_distance(tip(lift), liftTarget) <= 0.012 && tiltDegrees(lift) <= 5 { append(lift, "Lift 6 cm (simulation)", dwell: 1) }
            else if bucket != nil { throw ROBWorkspaceReachError.outOfReach(.can) }
        }
        if let bucket {
            guard ready else { throw ROBWorkspaceReachError.outOfReach(.can) }
            guard bucket.target == .orangeBucket, bucket.position.count == 3, bucket.position.allSatisfy(\.isFinite),
                  (0...60_000).contains(now - bucket.capturedAt), bucket.confidence >= 0.35,
                  let radius = bucket.openingRadius, (0.06...0.28).contains(radius) else {
                throw ROBGhostMotionError.blocked("Measure the open bucket rim again before planning a release.")
            }
            // Explicit operator calibration: rotate the model's release target
            // toward ROB's left around the shoulder, then shift it horizontally
            // toward that shoulder. Raw sightings, height and measured opening
            // radius remain unchanged.
            let pivotFrame = model.frames(baseline)[side + "_one_Link"]!
            let pivot = SIMD2(pivotFrame.columns.3.x,pivotFrame.columns.3.y)
            let delta = SIMD2(bucket.point.x,bucket.point.y)-pivot, yaw = bucketYawDegrees * .pi/180
            let rotatedDelta = SIMD2(cos(yaw)*delta.x-sin(yaw)*delta.y,sin(yaw)*delta.x+cos(yaw)*delta.y)
            var bucketXY = pivot + rotatedDelta
            if bucketInwardMeters > 0 {
                let distance = simd_length(rotatedDelta)
                guard distance.isFinite, distance > bucketInwardMeters + 0.05 else {
                    throw ROBGhostMotionError.blocked("The calibrated bucket release point is too close to the selected shoulder.")
                }
                bucketXY -= rotatedDelta / distance * bucketInwardMeters
            }
            let bucketPoint = SIMD3(bucketXY.x,bucketXY.y,bucket.point.z)
            func travel(_ target: SIMD3<Double>, stage: String) throws {
                let origin = tip(previous), count = max(1, Int(ceil(simd_distance(origin, target)/0.03)))
                for index in 1...count {
                    let point = origin + (target-origin) * (Double(index)/Double(count))
                    let pose = closest(point, previous)
                    guard simd_distance(tip(pose), point) <= 0.012, tiltDegrees(pose) <= 5 else {
                        throw ROBWorkspaceReachError.outOfReach(.orangeBucket)
                    }
                    append(pose, stage)
                }
            }
            // Release from above and let gravity do the drop. The hand never
            // has to descend to a floor-level bucket. An inward release point
            // still leaves 5.5 cm of opening radius for the can and fit error.
            let towardHand = SIMD2(graspPoint.x-bucketPoint.x,graspPoint.y-bucketPoint.y)
            let offset = simd_length(towardHand) > 0.001 ? simd_normalize(towardHand) * min(0.04,max(0,radius-0.055)) : .zero
            // The RGB/floor prior contains one common gravity-drop disk for
            // every admitted shape variant. Keep its center and full inset;
            // legacy inward/yaw/handward corrections cannot spend that disk.
            if let prior=bucket.bucketShapePrior {
                guard prior.valid,bucket.registrationID == nil,bucketYawDegrees==0,bucketInwardMeters==0,
                      abs(radius-prior.commonOpeningRadiusMeters)<0.000001 else {
                    throw ROBGhostMotionError.blocked("The explicitly estimated bucket opening or its common drop disk changed.")
                }
            }
            let dropXY = bucket.bucketShapePrior == nil ? bucketXY + offset : SIMD2(bucket.point.x,bucket.point.y)
            var releaseTarget: SIMD3<Double>?
            for extra in [0.15,0.10,0.20,0.25] {
                let point = SIMD3(dropXY.x,dropXY.y,max(graspPoint.z+extra,bucket.point.z+0.12))
                let candidate = closest(point,previous)
                if simd_distance(tip(candidate),point) <= 0.012 && tiltDegrees(candidate) <= 5 { releaseTarget = point; break }
            }
            guard let releaseTarget else { throw ROBWorkspaceReachError.outOfReach(.orangeBucket) }
            let carryZ = releaseTarget.z
            try travel(SIMD3(graspPoint.x, graspPoint.y, carryZ), stage: "Raise can for transfer")
            try travel(releaseTarget, stage: "Carry above bucket for gravity drop")
            append(previous, "Release above bucket", action: .release)
            try travel(releaseTarget + SIMD3(0,0,0.08), stage: "Retreat above bucket")
        }
        return .init(can: can, side: side, baseline: baseline, steps: steps, graspError: error,
            gripperTiltDegrees: tilt, reachesCan: ready, reachOffset:[reachOffset.x,reachOffset.y,reachOffset.z],
            dynamicEntryStepCount:entryStepCount)
    }
}

/// Pure continuation from an already held, independently validated payload.
/// It never enters from hanging, prepares jaws, grips or grants arm motion.
struct ROBCanCarryPreview {
    struct DropContainmentEvidence:Codable,Equatable {
        let payloadMeasurementID:String
        let destinationSequence:UInt64
        let destinationCapturedAtMilliseconds:Double
        let usedCommonOpeningPrior:Bool
        let openingCenterMeters:[Double]
        let openingRadiusMeters:Double
        let payloadCenterAtReleaseMeters:[Double]
        let payloadProjectedRadiusMeters:Double
        let payloadCenterOffsetMeters:Double
        let assumedDropUncertaintyMeters:Double
        let containmentInsetMeters:Double
        let remainingOpeningMarginMeters:Double
        let minimumPayloadBottomAboveRimMeters:Double
        let toolTiltDegrees:Double
        let releaseTargetErrorMeters:Double
    }
    let can:ROBWorkspaceLocatedObject
    let destination:ROBWorkspaceLocatedObject
    let attachedPayload:ROBWorkspaceCarriedObject
    let baseline:[String:Double]
    let side:String
    let steps:[ROBCanGrabPreview.Step]
    let releaseIndex:Int
    let dropContainmentEvidence:DropContainmentEvidence
    var seconds:Double {steps.reduce(0){$0+$1.seconds}}

    static func make(from baseline:[String:Double],can:ROBWorkspaceLocatedObject,
        attachedPayload:ROBWorkspaceCarriedObject,destination:ROBWorkspaceLocatedObject,
        model:ROBGhostRobotModel,side:String,now:Double,dropUncertaintyMeters:Double)throws->Self {
        guard model.physicalSide==side,["left","right"].contains(side),
              baseline.values.allSatisfy(\.isFinite),now.isFinite,
              can.target == .can,can.position.count==3,can.position.allSatisfy(\.isFinite),
              can.confidence.isFinite,(0.35...1).contains(can.confidence),can.sequence>0,
              can.capturedAt.isFinite,(0...60_000).contains(now-can.capturedAt),
              let sections=can.sections,sections.valid,attachedPayload.valid,
              destination.target == .orangeBucket,destination.position.count==3,destination.position.allSatisfy(\.isFinite),
              destination.confidence.isFinite,(0.35...1).contains(destination.confidence),destination.sequence>0,
              destination.capturedAt.isFinite,(0...60_000).contains(now-destination.capturedAt),
              let radius=destination.openingRadius,radius.isFinite,(0.06...0.28).contains(radius),
              dropUncertaintyMeters.isFinite,(0...0.15).contains(dropUncertaintyMeters) else {
            throw ROBGhostMotionError.blocked("Carry planning needs a fresh can, an explicit attached payload, an observed bucket opening and bounded drop uncertainty.")
        }
        let center=SIMD3(attachedPayload.centerInToolMeters[0],attachedPayload.centerInToolMeters[1],attachedPayload.centerInToolMeters[2])
        let half=SIMD3(attachedPayload.halfExtentsMeters[0],attachedPayload.halfExtentsMeters[1],attachedPayload.halfExtentsMeters[2])
        guard (0..<3).allSatisfy({half[$0]+1e-9>=min(sections.diameterMeters/2,sections.heightMeters/2)}),
              simd_length(half)+1e-9>=sections.heightMeters/2 else {
            throw ROBGhostMotionError.blocked("The supplied attached envelope is too small for the measured can.")
        }
        var rimZ=destination.point.z
        if let prior=destination.bucketShapePrior {
            guard prior.valid,destination.registrationID==nil,abs(radius-prior.commonOpeningRadiusMeters)<0.000001 else {
                throw ROBGhostMotionError.blocked("The estimated bucket opening or its common drop disk changed.")
            }
            rimZ=max(rimZ,prior.maximumRimHeightMeters)
        }
        let ik=try ROBCanHorizontalIK(model:model,baseline:baseline,side:side,pointInTool:center)
        guard ik.chain.count==7,ik.chain.allSatisfy({joint in
            baseline[joint.name].map{ik.allowed[joint.name]!.contains($0)} ?? false
        }),ik.tiltDegrees(baseline)<=5 else {
            throw ROBGhostMotionError.blocked("The measured held arm must be within joint limits with horizontal jaws before carrying.")
        }
        func corners(_ pose:[String:Double])->[SIMD3<Double>] {
            let frame=model.frames(pose)[model.toolLink]!
            var result:[SIMD3<Double>]=[]
            for x in [-1.0,1] {for y in [-1.0,1] {for z in [-1.0,1] {
                let p=frame*SIMD4(center.x+x*half.x,center.y+y*half.y,center.z+z*half.z,1)
                result.append(SIMD3(p.x,p.y,p.z))
            }}}
            return result
        }
        let startCenter=ik.tip(baseline),openingXY=SIMD2(destination.point.x,destination.point.y)
        let inset=0.010
        func containment(_ pose:[String:Double],target:SIMD3<Double>)->DropContainmentEvidence? {
            let actual=ik.tip(pose),vertices=corners(pose)
            guard [actual.x,actual.y,actual.z].allSatisfy(\.isFinite),vertices.count==8,
                  vertices.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}) else {return nil}
            let footprint=vertices.map{hypot($0.x-actual.x,$0.y-actual.y)}.max()!
            let offset=simd_distance(SIMD2(actual.x,actual.y),openingXY)
            let margin=radius-offset-footprint-dropUncertaintyMeters-inset
            let bottom=vertices.map(\.z).min()!-rimZ
            let error=simd_distance(actual,target),tilt=ik.tiltDegrees(pose)
            guard margin>=0,bottom>=dropUncertaintyMeters+0.020,error<=0.012,tilt<=5 else {return nil}
            return .init(payloadMeasurementID:attachedPayload.measurementID,destinationSequence:destination.sequence,
                destinationCapturedAtMilliseconds:destination.capturedAt,usedCommonOpeningPrior:destination.bucketShapePrior != nil,
                openingCenterMeters:[openingXY.x,openingXY.y,rimZ],openingRadiusMeters:radius,
                payloadCenterAtReleaseMeters:[actual.x,actual.y,actual.z],payloadProjectedRadiusMeters:footprint,
                payloadCenterOffsetMeters:offset,assumedDropUncertaintyMeters:dropUncertaintyMeters,
                containmentInsetMeters:inset,remainingOpeningMarginMeters:margin,
                minimumPayloadBottomAboveRimMeters:bottom,toolTiltDegrees:tilt,releaseTargetErrorMeters:error)
        }
        // The full attached BOX is projected. No cylinder axis, fresh world
        // grasp point or occupied/free evidence is invented from its name.
        let startFootprint=corners(baseline).map{hypot($0.x-startCenter.x,$0.y-startCenter.y)}.max()!
        let towardHand=SIMD2(startCenter.x,startCenter.y)-openingXY
        let availableHandward=max(0,radius-startFootprint-dropUncertaintyMeters-inset-0.012)
        let handward=destination.bucketShapePrior==nil && simd_length(towardHand)>0.001
            ? simd_normalize(towardHand)*min(0.04,availableHandward):.zero
        let dropXY=openingXY+handward
        var reachableButUncontained=false,containedCandidate=false
        for extra in [0.15,0.10,0.20,0.25] {
            let releaseTarget=SIMD3(dropXY.x,dropXY.y,max(startCenter.z+extra,rimZ+simd_length(half)+0.12))
            let candidate=ik.closest(releaseTarget,baseline)
            guard simd_distance(ik.tip(candidate),releaseTarget)<=0.012,ik.tiltDegrees(candidate)<=5 else {continue}
            guard containment(candidate,target:releaseTarget) != nil else {reachableButUncontained=true;continue}
            containedCandidate=true
            var previous=baseline,steps:[ROBCanGrabPreview.Step]=[]
            func step(_ pose:[String:Double],_ stage:String,action:ROBLeftGestureProposal.JawAction?=nil)throws {
                let angle=ik.chain.map{abs(pose[$0.name,default:0]-previous[$0.name,default:0])}.max() ?? 0
                let seconds=max(0.8,angle/0.6)
                guard seconds.isFinite,seconds<=5 else {throw ROBWorkspaceReachError.outOfReach(.orangeBucket)}
                steps.append(.init(pose:pose,seconds:seconds,stage:stage,jawAction:action));previous=pose
            }
            func travel(_ target:SIMD3<Double>,stage:String)throws {
                let origin=ik.tip(previous),distance=simd_distance(origin,target)
                guard distance.isFinite,distance<=3 else {throw ROBWorkspaceReachError.outOfReach(.orangeBucket)}
                let initialCount=max(1,Int(ceil(distance/0.025)))
                // Numerical IK residuals must not enlarge a nominal3cm
                // spacing into an actual larger payload-center movement.
                for factor in [1,2,4] where initialCount*factor<=256 {
                    let count=initialCount*factor
                    var cursor=previous,route:[[String:Double]]=[]
                    for index in 1...count {
                        let point=origin+(target-origin)*(Double(index)/Double(count)),pose=ik.closest(point,cursor)
                        guard simd_distance(ik.tip(pose),point)<=0.012,ik.tiltDegrees(pose)<=5,
                              simd_distance(ik.tip(pose),ik.tip(cursor))<=0.030+1e-9 else {route=[];break}
                        route.append(pose);cursor=pose
                    }
                    if route.count==count {for pose in route {try step(pose,stage)};return}
                }
                throw ROBWorkspaceReachError.outOfReach(.orangeBucket)
            }
            do {
                try step(baseline,"Measured held start; carrying explicit payload")
                try travel(SIMD3(startCenter.x,startCenter.y,releaseTarget.z),stage:"Raise held can for transfer")
                try travel(releaseTarget,stage:"Carry held can above bucket for gravity drop")
                guard let evidence=containment(previous,target:releaseTarget) else {continue}
                let releaseIndex=steps.count,actualRelease=ik.tip(previous)
                try step(previous,"Release held can above bucket",action:.release)
                try travel(actualRelease+SIMD3(0,0,0.08),stage:"Empty retreat above bucket")
                guard steps.count<=512,steps.reduce(0,{$0+$1.seconds})<=135 else {continue}
                return .init(can:can,destination:destination,attachedPayload:attachedPayload,baseline:baseline,side:side,
                    steps:steps,releaseIndex:releaseIndex,dropContainmentEvidence:evidence)
            } catch is ROBWorkspaceReachError {continue}
        }
        if reachableButUncontained && !containedCandidate {
            throw ROBGhostMotionError.blocked("The attached payload box and drop uncertainty do not fit inside the observed opening.")
        }
        throw ROBWorkspaceReachError.outOfReach(.orangeBucket)
    }
}

struct ROBWorkspacePointingHint: Equatable {
    let x: Double, y: Double
    let dx: Double, dy: Double
    let distanceMeters: Double
    func agrees(with other: Self) -> Bool {
        let norm = hypot(dx, dy) * hypot(other.dx, other.dy)
        return norm > 0.0001 && (dx * other.dx + dy * other.dy) / norm >= 0.90 &&
            hypot(x - other.x, y - other.y) < 0.15
    }
    func guidedView(from view: ROBWorkspaceView, horizontalFOV: Double = 69, extensionScale: Double = 3) -> ROBWorkspaceView {
        let aimX = max(0, min(1, x + dx * extensionScale)), aimY = max(0, min(1, y + dy * extensionScale))
        return .init(panDegrees: max(-70, min(70, view.panDegrees - (aimX - 0.5) * horizontalFOV)),
            upperTarget: max(5300, min(7500, view.upperTarget - Int((aimY - 0.5) * 45 * 33.333333))))
    }
    func searchViews(from view: ROBWorkspaceView, boundedPan: (Double) -> Double) -> [ROBWorkspaceView] {
        var views: [ROBWorkspaceView] = []
        func append(_ value: ROBWorkspaceView) {
            let value = ROBWorkspaceView(panDegrees: boundedPan(value.panDegrees), upperTarget: value.upperTarget)
            if !views.contains(where: { abs($0.panDegrees - value.panDegrees) < 3 && abs($0.upperTarget - value.upperTarget) < 150 }) { views.append(value) }
        }
        for scale in [3.0, 1.5, 6] {
            let center = guidedView(from: view, extensionScale: scale)
            append(center)
            for (row, tilt) in [-800, -400, 400].enumerated() {
                let offsets = row.isMultiple(of: 2) ? [-12.0, 0, 12] : [12.0, 0, -12]
                for offset in offsets {
                    append(.init(panDegrees: center.panDegrees + offset, upperTarget: max(5300, min(7500, center.upperTarget + tilt))))
                }
            }
        }
        return views
    }
}

enum ROBWorkspaceGrounding {
    /// Project measured aligned depth with factory intrinsics and the current
    /// articulated camera prior. This is explicitly provisional arm geometry.
    static func locate(target: ROBWorkspaceTarget, detection: ROBWorkspaceDetection,
                       width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double,
                       depth: (Int, Int) -> UInt16?, view: ROBWorkspaceView, model: ROBGhostRobotModel,
                       capturedAt: Double, sequence: UInt64, cameraToRobot:simd_double4x4? = nil, registrationID:String? = nil) -> ROBWorkspaceLocatedObject? {
        guard detection.usable, width > 0, height > 0, [fx, fy, cx, cy].allSatisfy(\.isFinite), fx > 0, fy > 0,
              (0..<Double(width)).contains(cx), (0..<Double(height)).contains(cy),
              let transform = cameraToRobot ?? view.cameraFrame(model: model) else { return nil }
        let x = Int(detection.depthPoint[0] * Double(width - 1)), y = Int(detection.depthPoint[1] * Double(height - 1))
        var samples: [Double] = []
        for dy in -3...3 { for dx in -3...3 {
            if let mm = depth(x + dx, y + dy), (150...3000).contains(mm) { samples.append(Double(mm) / 1000) }
        } }
        guard samples.count >= 9 else { return nil }
        samples.sort(); let z = samples[samples.count / 2]
        let deviations = samples.map { abs($0 - z) }.sorted()
        guard deviations[deviations.count / 2] <= 0.04,
              samples[samples.count * 9 / 10] - samples[samples.count / 10] <= 0.08 else { return nil }
        let u = detection.aim[0] * Double(width - 1), v = detection.aim[1] * Double(height - 1)
        let position = transform * SIMD4((u - cx) * z / fx, (v - cy) * z / fy, z, 1)
        guard [position.x, position.y, position.z].allSatisfy(\.isFinite) else { return nil }
        return .init(target: target, position: [position.x, position.y, position.z], confidence: detection.confidence,
            capturedAt: capturedAt, sequence: sequence, view: view, registrationID:registrationID)
    }

    static func task(can: ROBWorkspaceLocatedObject, bucket: ROBWorkspaceLocatedObject,
                     model: ROBGhostRobotModel) throws -> ROBGhostGesture {
        let center = model.positions(vendorLeft: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!)
        // Five semantic anchors, solved locally. Keep the first reach above the
        // can, lift vertically, and release above the bucket's measured rim.
        let points = [can.point + SIMD3(0, 0, 0.08), can.point, can.point + SIMD3(0, 0, 0.06),
                      bucket.point + SIMD3(0, 0, 0.12), bucket.point + SIMD3(0, 0, 0.20)]
        var seed = center, poses: [[String: Double]] = []
        for (index, point) in points.enumerated() {
            guard let pose = model.solveLeft(target: point, from: seed),
                  let tip = model.toolPosition(pose), simd_distance(tip, point) <= 0.012 else {
                throw ROBWorkspaceReachError.outOfReach(index < 3 ? .can : .orangeBucket)
            }
            poses.append(pose); seed = pose
        }
        return .init(name: "Recycle Coke can into orange bucket", poses: poses, modelID: model.modelID,
            referenceID: model.referenceID, geometryID: model.geometryID, kind: "tabletop")
    }
}

/// Camera attention only. Every selected view still needs settled live frames,
/// local detection and two agreeing depth measurements before it can locate an object.
struct ROBWorkspaceSearchSchedule {
    private struct Job { let view: ROBWorkspaceView; let target: ROBWorkspaceTarget? }
    private var pending: [Job]
    private let requested: Set<ROBWorkspaceTarget>
    private(set) var attempted: [ROBWorkspaceView] = []
    let recallViews: [ROBWorkspaceView]
    let plannedViewCount: Int
    let surveysFrontTable: Bool

    init(targets: [ROBWorkspaceTarget], recall: ROBWorkspaceRecall,
         now: Double = Date().timeIntervalSince1970 * 1000,
         frontTableSide: String? = nil,
         boundedPan: (Double) -> Double = { max(-45,min(45,$0)) }) {
        requested = Set(targets)
        surveysFrontTable = frontTableSide != nil
        if let side = frontTableSide {
            // Preview the immediate table on BOTH sides before choosing a can.
            // Recall cannot jump this survey to an old across-table target.
            let sign = side == "right" ? -1.0 : 1.0
            recallViews = []
            pending = [sign * 30, 0, -sign * 30].map {
                Job(view: .init(panDegrees: boundedPan($0), upperTarget: 6306), target: nil)
            }
            plannedViewCount = pending.count
            return
        }
        var recalled: [Job] = [], nearby: [Job] = []
        for target in targets {
            guard let sighting = recall.sightings.first(where: {
                $0.target == target && $0.valid && (0...86_400_000).contains(now-$0.capturedAt)
            }) else { continue }
            // An old clipped glimpse is a direction hint: first look toward
            // its center, rather than repeating the clipped camera pose.
            let views = Self.clipped(sighting.box) ? [sighting.centeredView,sighting.view] : [sighting.view,sighting.centeredView]
            recalled += views.map { Job(view:$0,target:target) }
            let center = sighting.view
            nearby += [(-15.0,0),(15.0,0),(0.0,-350),(0.0,350)].map { pan,upper in
                Job(view:.init(panDegrees:boundedPan(center.panDegrees+pan),
                    upperTarget:max(5300,min(7500,center.upperTarget+upper))),target:target)
            }
        }
        recallViews = recalled.map(\.view)
        let fallback = targets.isEmpty ? [ROBWorkspaceView(panDegrees:0,upperTarget:5300),
            .init(panDegrees:-35,upperTarget:5300),.init(panDegrees:35,upperTarget:5300)] : ROBWorkspaceView.sweep
        // After the robot/table rotates, useful old views may no longer exist.
        // Cover the broad front and both sides before the detailed raster.
        let coarse = !targets.isEmpty && recalled.isEmpty ? [
            ROBWorkspaceView(panDegrees:0,upperTarget:6306),.init(panDegrees:-30,upperTarget:6306),
            .init(panDegrees:30,upperTarget:6306),.init(panDegrees:0,upperTarget:5650),
            .init(panDegrees:30,upperTarget:5650),.init(panDegrees:-30,upperTarget:5650)] : []
        // Calibrated pan gain makes native ±55° approximately the physical
        // side bearings. The old ±45° raster misses objects directly beside
        // ROB. Cover both side-floor heights after recall even when recall
        // exists for only one requested object. The native envelope owns the
        // admitted pan: absent a wider configured envelope, remain at ±45°.
        var sideFloor:[ROBWorkspaceView]=[]
        if !targets.isEmpty {
            for sign in [1.0,-1.0] {
                for (upper,pans) in [(5650,[55.0,60.0]),(5300,[60.0,55.0])] {
                    for candidate in pans {
                        let pan=boundedPan(sign*candidate)
                        guard pan.isFinite,abs(pan)>45,
                              !sideFloor.contains(where:{abs($0.panDegrees-pan)<3 && abs($0.upperTarget-upper)<100}) else {continue}
                        sideFloor.append(.init(panDegrees:pan,upperTarget:upper))
                    }
                }
            }
        }
        pending = recalled + sideFloor.map {Job(view:$0,target:nil)} + nearby + (coarse + fallback).map { Job(view:$0,target:nil) }
        plannedViewCount = pending.count
    }
    static func clipped(_ box: [Double]) -> Bool {
        box.count != 4 || box[0] <= 0.02 || box[1] <= 0.02 || box[2] >= 0.98 || box[3] >= 0.98
    }
    static func recallQuality(_ box: [Double]) -> Double {
        guard box.count == 4 else { return -.infinity }
        return (clipped(box) ? -10 : 0)-hypot((box[0]+box[2])/2-0.5,(box[1]+box[3])/2-0.5)
    }
    static func distinctCans(_ detections: [ROBWorkspaceDetection]) -> [ROBWorkspaceDetection] {
        var kept: [ROBWorkspaceDetection] = []
        for candidate in detections.filter(\.visuallyUsable).sorted(by:{ $0.confidence > $1.confidence }) {
            let box = candidate.box
            let duplicate = kept.contains { existing in
                let other = existing.box
                let intersection = max(0,min(box[2],other[2])-max(box[0],other[0])) *
                    max(0,min(box[3],other[3])-max(box[1],other[1]))
                let area = (box[2]-box[0])*(box[3]-box[1]) + (other[2]-other[0])*(other[3]-other[1])-intersection
                return area > 0 && intersection/area >= 0.5
            }
            if !duplicate { kept.append(candidate) }
            if kept.count == 8 { break }
        }
        return kept
    }
    func hasAttempted(_ view: ROBWorkspaceView) -> Bool {
        attempted.contains { abs($0.panDegrees-view.panDegrees) < 3 && abs($0.upperTarget-view.upperTarget) < 100 }
    }
    mutating func record(_ view: ROBWorkspaceView) {
        if !hasAttempted(view) { attempted.append(view) }
    }
    mutating func next(confirmed: Set<ROBWorkspaceTarget>) -> ROBWorkspaceView? {
        if !surveysFrontTable && !requested.isEmpty && requested.isSubset(of:confirmed) { return nil }
        while !pending.isEmpty {
            let job = pending.removeFirst()
            if let target = job.target, confirmed.contains(target) { continue }
            if hasAttempted(job.view) { continue }
            record(job.view)
            return job.view
        }
        return nil
    }
}
