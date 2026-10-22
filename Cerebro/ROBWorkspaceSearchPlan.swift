import Foundation
import simd

enum ROBWorkspaceTarget: String, Codable, CaseIterable {
    case can, orangeBucket
    var spokenName: String { self == .can ? "Coke can" : "orange bucket" }
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
        guard let pose = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: panDegrees * .pi / 180,
            lowerTarget: 6011, upperTarget: upperTarget, known: true),
              let head = model.headPositions(pan: pose.panRadians, lowerPitch: pose.lowerPitch, upperPitch: pose.upperPitch) else { return nil }
        return model.frames(model.reference.merging(head) { _, new in new })["oak_optical_frame"]
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

struct ROBWorkspaceLocatedObject: Codable {
    let target: ROBWorkspaceTarget
    let position: [Double]
    let confidence: Double
    let capturedAt: Double
    let sequence: UInt64
    let view: ROBWorkspaceView
    var point: SIMD3<Double> { SIMD3(position[0], position[1], position[2]) }
    func agrees(with other: Self) -> Bool {
        target == other.target && sequence != other.sequence && other.capturedAt > capturedAt &&
            other.capturedAt - capturedAt < 30_000 && simd_distance(point, other.point) <= 0.05
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
                       capturedAt: Double, sequence: UInt64) -> ROBWorkspaceLocatedObject? {
        guard detection.usable, width > 0, height > 0, [fx, fy, cx, cy].allSatisfy(\.isFinite), fx > 0, fy > 0,
              (0..<Double(width)).contains(cx), (0..<Double(height)).contains(cy),
              let transform = view.cameraFrame(model: model) else { return nil }
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
            capturedAt: capturedAt, sequence: sequence, view: view)
    }

    static func task(can: ROBWorkspaceLocatedObject, bucket: ROBWorkspaceLocatedObject,
                     model: ROBGhostRobotModel) throws -> ROBGhostGesture {
        let center = model.positions(vendorLeft: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!)
        // Five semantic anchors, solved locally. Keep the first reach above the
        // can, lift vertically, and release above the bucket's measured rim.
        let points = [can.point + SIMD3(0, 0, 0.08), can.point, can.point + SIMD3(0, 0, 0.06),
                      bucket.point + SIMD3(0, 0, 0.12), bucket.point + SIMD3(0, 0, 0.20)]
        var seed = center, poses: [[String: Double]] = []
        for point in points {
            guard let pose = model.solveLeft(target: point, from: seed),
                  let tip = model.toolPosition(pose), simd_distance(tip, point) <= 0.012 else {
                throw ROBGhostMotionError.blocked("Found the can/bucket, but the left arm cannot reach the observed positions with the current model. Reposition them closer; no blind reach was sent.")
            }
            poses.append(pose); seed = pose
        }
        return .init(name: "Recycle Coke can into orange bucket", poses: poses, modelID: model.modelID,
            referenceID: model.referenceID, geometryID: model.geometryID, kind: "tabletop")
    }
}
