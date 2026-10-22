import Foundation
import simd

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

/// Visual rehearsal only. Deliberately separate from executable proposals:
/// selecting a right-hand model does not assert a right-arm hardware mapping.
struct ROBCanGrabPreview {
    struct Step {
        let pose: [String: Double]
        let seconds: Double
        let stage: String
    }
    let can: ROBWorkspaceLocatedObject
    let side: String
    let baseline: [String: Double]
    let steps: [Step]
    let graspError: Double
    let gripperTiltDegrees: Double
    let reachesCan: Bool
    var seconds: Double { steps.reduce(0) { $0 + $1.seconds } }
    var helpRequest: String? {
        // An orientation-only failure must not be described as too far away.
        graspError > 0.012 ? ROBWorkspaceReachError.outOfReach(.can).helpRequest : nil
    }

    static func make(can: ROBWorkspaceLocatedObject, model: ROBGhostRobotModel,
                     baseline: [String: Double], side: String = "left", now: Double = Date().timeIntervalSince1970 * 1000) throws -> Self {
        guard can.target == .can, can.position.count == 3, can.position.allSatisfy(\.isFinite),
              ["left", "right"].contains(side),
              can.confidence.isFinite, (0.35...1).contains(can.confidence), can.sequence > 0,
              can.capturedAt.isFinite, now.isFinite, (0...60_000).contains(now - can.capturedAt),
              baseline.values.allSatisfy(\.isFinite) else {
            throw ROBGhostMotionError.blocked("Find the can again; its measured position is missing or older than 60 seconds.")
        }
        func tip(_ q: [String: Double]) -> SIMD3<Double> {
            let frame = model.frames(q)[side + "_tool"]!
            return SIMD3(frame.columns.3.x, frame.columns.3.y, frame.columns.3.z)
        }
        let chain = model.joints.filter { $0.name.hasPrefix(side + "_joint") }
        // Captured gripper: +Z approaches, +Y spans the jaw opening; +X is
        // its thin plane normal. Keep +Y/+Z horizontal, including wrist roll.
        func features(_ q: [String: Double]) -> [Double] {
            let frame = model.frames(q)[side + "_tool"]!
            return [frame.columns.3.x, frame.columns.3.y, frame.columns.3.z,
                frame.columns.1.z * 0.25, frame.columns.2.z * 0.25]
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
            var q = seed, best = seed, bestLoss = Double.infinity
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
                    q[joint.name] = max(joint.lower, min(joint.upper, q[joint.name, default: 0] + change * scale))
                }
            }
            // Equivalent half-turns preserve the horizontal jaw line. Prefer
            // the branch nearest the starting wrist, avoiding approach flips.
            let wrist = side + "_joint7"
            let reference = seed[wrist, default: baseline[wrist, default: 0]]
            let joint = chain.first { $0.name == wrist }!
            for delta in [-Double.pi, Double.pi] {
                let candidate = best[wrist, default: 0] + delta
                if (joint.lower...joint.upper).contains(candidate), abs(candidate-reference) < abs(best[wrist, default: 0]-reference) {
                    best[wrist] = candidate
                }
            }
            return best
        }
        var seed = baseline
        let front = model.positions(vendorLeft: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!)
        for i in 1...6 { seed["\(side)_joint\(i)"] = (side == "left" ? 1 : -1) * front["left_joint\(i)"]! }
        var previous = baseline, steps: [Step] = []
        func append(_ pose: [String: Double], _ stage: String, dwell: Double = 0) {
            let angle = chain.map { abs(pose[$0.name, default: 0] - previous[$0.name, default: 0]) }.max() ?? 0
            steps.append(.init(pose: pose, seconds: max(0.8, angle / 0.6) + dwell, stage: stage)); previous = pose
        }
        append(seed, "Present ghost hand")
        let frontTip = tip(seed)
        let level = closest(frontTip, seed)
        append(level, "Level gripper horizontally")
        let raised = closest(SIMD3(frontTip.x, frontTip.y, max(frontTip.z, can.point.z + 0.15)), level)
        append(raised, "Raise before crossing")
        let approachTarget = can.point + SIMD3(0, 0, 0.12)
        var approach = closest(approachTarget, raised)
        // A cross-body target can trap the numerical solver in a local
        // minimum. Compare bounded shoulder seeds; never move the target.
        for shoulder in [-1.5, -0.5, 0.5, 1.5] where simd_distance(tip(approach), approachTarget) > 0.012 || tiltDegrees(approach) > 5 {
            var alternate = raised; alternate[side + "_joint1"] = shoulder
            let candidate = closest(approachTarget, alternate)
            if loss(candidate, approachTarget) < loss(approach, approachTarget) { approach = candidate }
        }
        append(approach, "Cross above can (table clearance unverified)")
        var grasp = approach
        for index in 1...4 {
            grasp = closest(can.point + SIMD3(0, 0, 0.12 * (1 - Double(index)/4)), grasp)
            if index < 4 { append(grasp, "Final approach — horizontal jaws") }
        }
        let error = simd_distance(tip(grasp), can.point)
        let tilt = tiltDegrees(grasp)
        let ready = error <= 0.012 && tilt <= 5
        append(grasp, ready ? "Grasp pose" : "Closest horizontal reach — grasp unconfirmed")
        if ready {
            append(grasp, "Close jaws (simulation)", dwell: 1)
            let liftTarget = can.point + SIMD3(0, 0, 0.06)
            let lift = closest(liftTarget, grasp)
            if simd_distance(tip(lift), liftTarget) <= 0.012 && tiltDegrees(lift) <= 5 { append(lift, "Lift 6 cm (simulation)", dwell: 1) }
        }
        return .init(can: can, side: side, baseline: baseline, steps: steps, graspError: error,
            gripperTiltDegrees: tilt, reachesCan: ready)
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
