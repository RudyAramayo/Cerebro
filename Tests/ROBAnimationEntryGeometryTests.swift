import Foundation
import simd

/// Offline regression for the reported bow and raised-hands tread collisions.
/// Starts at hanging zero, including the first clip; no hardware is linked.
@main struct AnimationEntryGeometryTests {
    static func main() throws {
        setbuf(stdout, nil)
        func check(_ value: @autoclosure () -> Bool, _ detail: String = "Animation entry invariant failed") {
            guard value() else { fputs("FAIL: " + detail + "\n", stderr); exit(1) }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let documents = try ["japanese-bow", "basic-gestures"].map {
            try ROBAnimationStore.decode(Data(contentsOf: root.appendingPathComponent("Animations/\($0).json")))
        }
        for document in documents { try document.validate() }
        let sequences = documents.flatMap(\.sequences).filter {
            ["Japanese Greeting · Prayer Bow", "Hands Folded Up", "Kung Fu · Guard and Flow"].contains($0.name)
        }
        check(sequences.count == 3)
        let directory = root.appendingPathComponent("Cerebro/Resources/ShadowPlanner")
        var baseline: [String: Double] = ["maestro.0":6000, "maestro.1":6011, "maestro.2":6906]
        for side in ["right", "left"] { for j in 1...7 { baseline["arm.\(side).j\(j)"] = 0 } }
        for sequence in sequences {
          check(sequence.armSpeed == 0.25, "Reported collision paths must ship at the requested slower trial speed")
          check(Array(sequence.clips.prefix(3).map(\.transition)) == [6, 10, 12.5], "Compact lift must preserve the working transition times")
          for side in ["right", "left"] {
            let model = try ROBGhostRobotModel(directory: directory, physicalSide: side)
            var proxy = ROBWorkspaceSelfProxyClearance(model: model)
            let zero = Array(repeating: 0.0, count: 7)
            let initial = try proxy.separations(vendorLeft: zero)
            let narrow = Set(initial.filter { $0.value < 0.03 }.keys)
            func joints(_ values: [String:Double]) -> [Double] { (1...7).map { values["arm.\(side).j\($0)"]! } }
            let entry = Array(sequence.clips.prefix(3))
            func sampleEntryEnd(_ index: Int) -> [Double] {
                let time = entry.prefix(index).reduce(0) { $0 + sequence.playbackDuration(for: $1) }
                    + sequence.armTransition(for: entry[index])
                return joints(ROBAnimationDocument.sample(sequence, at: time, baseline: baseline))
            }
            let outward = sampleEntryEnd(0), lift = sampleEntryEnd(1), orient = sampleEntryEnd(2)
            check(entry.prefix(2).allSatisfy { clip in [3,5,6,7].allSatisfy { clip.pose.values["arm.\(side).j\($0)"] == nil } }, "Both lift stages must retain the measured wrist/forearm pose, not rotate it to zero")
            check(entry.allSatisfy { $0.pose.values["arm.\(side).j3"] == nil }, "Do not fold the forearm inward while the shoulders remain spread")
            check([5,6,7].allSatisfy { entry[2].pose.values["arm.\(side).j\($0)"] != nil }, "Keep wrist pitch and roll coordinated above the treads")
            var changedBaseline = baseline
            for j in [3,5,6,7] { changedBaseline["arm.\(side).j\(j)"] = 0.1 }
            for index in 0...1 {
                let time = entry.prefix(index).reduce(0) { $0 + sequence.playbackDuration(for: $1) }
                    + sequence.armTransition(for: entry[index]) / 2
                let inherited = ROBAnimationDocument.sample(sequence, at: time, baseline: changedBaseline)
                check([3,5,6,7].allSatisfy { inherited["arm.\(side).j\($0)"] == 0.1 }, "Lift changed an omitted wrist or forearm channel")
            }
            check([0,1,2,3].allSatisfy { abs(lift[$0] - orient[$0]) < 1e-9 }, "Orientation clip lowered the shoulder/elbow before rotating the gripper")
            let initialTool = model.toolPosition(model.positions(vendorLeft: zero))!
            let outwardTool = model.toolPosition(model.positions(vendorLeft: outward))!
            check(abs(outwardTool.y) > abs(initialTool.y) + 0.15, "First lift must move the gripper outward before elbow folding")
            let liftHeight = model.torsoTurnVerticalClearance(vendorJoints: lift)!
            print("Checking \(sequence.name), \(side) lift-envelope height \(liftHeight)m")
            check(liftHeight >= 0.12, "The revised lift needs more modeled gripper height before rotation: \(side) \(liftHeight)")
            // The former shortcut rotated the wrist while still below the
            // tread envelope. Keep that failure observable in this fixture.
            let oldTarget = joints(sequence.clips[3].pose.values)
            let shortcut = oldTarget.map { $0 * 0.2 }
            check(abs(shortcut[4]) > 0.1 && model.torsoTurnVerticalClearance(vendorJoints: shortcut)! < 0.05)
            var time = 0.0, previous = zero, worst = Double.infinity
            for (index, clip) in sequence.clips.enumerated() {
                let transition = sequence.armTransition(for: clip)
                let goal = joints(ROBAnimationDocument.sample(sequence, at: time + transition, baseline: baseline))
                let delta = zip(previous, goal).map { abs($1-$0) }.max()!
                check(delta * (clip.easing == .smooth ? 1.5 : 1) / transition <= 0.05 + 1e-9, "Quarter-speed trial exceeds its nominal arm rate")
                let count = max(20, Int(ceil(delta / 0.01)))
                let required = initial.mapValues { index == 0 ? min(0.03, $0) : 0.03 }
                for sample in 0...count {
                    let values = ROBAnimationDocument.sample(sequence, at: time + transition * Double(sample) / Double(count), baseline: baseline)
                    let q = joints(values)
                    check(zip(q, ROBWorkspaceCollisionPlan.jointBounds(model: model)).allSatisfy { $1.contains($0) })
                    if index == 2 {
                        check(model.torsoTurnVerticalClearance(vendorJoints: q)! >= 0.12, "Wrist orientation lost the extra modeled height above the treads")
                    }
                    let gaps = try proxy.separations(vendorLeft: q, forceNarrowPairs: narrow, minimumRetreatBounds: required)
                    check(gaps.keys == initial.keys)
                    for (pair, gap) in gaps {
                        check(gap + 1e-8 >= required[pair]!, "\(side), clip \(index+1), sample \(sample)/\(count): \(pair) approaches treads (\(gap), required \(required[pair]!))")
                        if index > 0 { worst = min(worst, gap) }
                    }
                }
                previous = goal; time += sequence.playbackDuration(for: clip)
            }
            print("PASS \(sequence.name), \(side): complete zero-entry path at 25%; wrists held through both lift stages; raised envelope \(liftHeight)m; subsequent tread-separation bound \(worst)m")
          }
          try AnimationWholeBodyEntryReview(directory: directory).review(sequence, baseline: baseline)
        }
        print("Model-only geometry; external obstacles, motor mapping and physical clearance still require observation. No robot transport linked.")
    }
}

/// Review the paired arms against each other and the body as well as the
/// treads. Mechanically adjacent hulls (within three joints) are excluded.
/// Existing conservative model intersections at hanging may not deepen.
private final class AnimationWholeBodyEntryReview {
    private let left: ROBGhostRobotModel
    private let right: ROBGhostRobotModel
    private let hulls: [String: ROBEstimatedConvexHull]
    private let pairs: [(String, String)]
    private var axes: [String: SIMD3<Double>] = [:]

    init(directory: URL) throws {
        left = try ROBGhostRobotModel(directory: directory, physicalSide: "left")
        right = try ROBGhostRobotModel(directory: directory, physicalSide: "right")
        var loaded: [String: ROBEstimatedConvexHull] = [:]
        for (link, path) in left.hulls {
            loaded[link] = try ROBEstimatedConvexHull(text: String(contentsOf: directory.appendingPathComponent(path)))
        }
        hulls = loaded
        var graph: [String: Set<String>] = [:]
        for joint in left.joints {
            graph[joint.parent, default: []].insert(joint.child)
            graph[joint.child, default: []].insert(joint.parent)
        }
        func near(_ a: String, _ b: String) -> Bool {
            var seen: Set<String> = [a], edge: Set<String> = [a]
            for _ in 0..<3 {
                edge = Set(edge.flatMap { graph[$0] ?? [] }).subtracting(seen); seen.formUnion(edge)
            }
            return seen.contains(b)
        }
        func arm(_ link: String) -> Bool { link.hasSuffix("_Link") || link.hasSuffix("_tool") }
        let links = loaded.keys.sorted()
        pairs = links.enumerated().flatMap { i, a in
            links.dropFirst(i + 1).compactMap { b in (arm(a) || arm(b)) && !near(a, b) ? (a, b) : nil }
        }
    }

    private func positions(_ values: [String: Double]) -> [String: Double] {
        var positions = left.reference
        for model in [left, right] {
            let q = (1...7).map { values["arm.\(model.physicalSide).j\($0)"]! }
            let mapped = model.positions(vendorLeft: q)
            for j in 1...7 { positions[model.armJointPrefix + "\(j)"] = mapped[model.armJointPrefix + "\(j)"] }
        }
        if let lean = values["preview.bodyLeanDegrees"] { positions["body_lean"] = lean * .pi / 180 }
        if let pan = values["maestro.0"], let lower = values["maestro.1"], let upper = values["maestro.2"],
           let estimate = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: (pan - 6000) / 33.3333333333 * .pi / 180,
               lowerTarget: Int(lower), upperTarget: Int(upper), known: true),
           let head = left.headPositions(pan: estimate.panRadians, lowerPitch: estimate.lowerPitch, upperPitch: estimate.upperPitch) {
            positions.merge(head) { _, new in new }
        }
        return positions
    }

    private func envelope(_ values: [String: Double]) -> (span: Double, front: Double) {
        let bounds = left.worldCollisionBounds(positions: positions(values)).filter {
            $0.key.hasSuffix("_Link") || $0.key.hasSuffix("_tool")
        }
        let low = bounds.map { $0.value.low.y - ($0.key.hasSuffix("_tool") ? 0.03 : 0) }.min()!
        let high = bounds.map { $0.value.high.y + ($0.key.hasSuffix("_tool") ? 0.03 : 0) }.max()!
        return (high - low, bounds.values.map { $0.high.x }.max()!)
    }

    private func separations(_ values: [String: Double]) throws -> [String: Double] {
        let mapped = positions(values)
        let frames = left.frames(mapped), bounds = left.worldCollisionBounds(positions: mapped)
        var result: [String: Double] = [:]
        for (a, b) in pairs {
            let first = bounds[a]!, second = bounds[b]!, key = a + "|" + b
            var gap = simd_length(simd_max(.zero, simd_max(first.low - second.high, second.low - first.high)))
            if gap < 0.03 {
                if let axis = axes[key] {
                    gap = try hulls[a]!.supportPlaneGap(to: hulls[b]!, frame: frames[a]!, otherFrame: frames[b]!, axis: axis)
                }
                if axes[key] == nil || gap <= 0 {
                    let witness = try hulls[a]!.separationWitness(to: hulls[b]!, frame: frames[a]!, otherFrame: frames[b]!)
                    gap = witness.gap; axes[key] = witness.axis
                }
            }
            result[key] = gap
        }
        return result
    }

    func review(_ sequence: ROBAnimationSequence, baseline: [String: Double]) throws {
        let initial = try separations(baseline)
        // Keep the physically tried wide entry as an explicit comparison.
        // The compact path must save space, not merely rename the same lift.
        var wide = sequence
        for index in 0..<3 {
            for (side, sign) in [("right", 1.0), ("left", -1.0)] {
                for (joint, value) in zip([1,2,4], index == 0 ? [0.1,-0.65,-0.15] : [0.1,-1.85,-1.0]) {
                    wide.clips[index].pose.values["arm.\(side).j\(joint)"] = sign * value
                }
            }
        }
        var compactSpan = 0.0, wideSpan = 0.0, compactFront = 0.0, wideFront = 0.0
        var orientationToolGap = Double.infinity
        var time = 0.0, previous = baseline, samples = 0
        for (index, clip) in sequence.clips.enumerated() {
            let transition = sequence.armTransition(for: clip)
            let delta = clip.pose.values.filter { $0.key.hasPrefix("arm.") }.map { abs($0.value - previous[$0.key]!) }.max() ?? 0
            let count = max(20, Int(ceil(delta / 0.025)))
            for n in 0...count {
                let values = ROBAnimationDocument.sample(sequence, at: time + transition * Double(n) / Double(count), baseline: baseline)
                let gaps = try separations(values)
                if index == 2 { orientationToolGap = min(orientationToolGap, gaps["left_tool|right_tool"]!) }
                if index < 4 {
                    let compact = envelope(values)
                    let old = envelope(ROBAnimationDocument.sample(wide, at: time + transition * Double(n) / Double(count), baseline: baseline))
                    compactSpan = max(compactSpan, compact.span); wideSpan = max(wideSpan, old.span)
                    compactFront = max(compactFront, compact.front); wideFront = max(wideFront, old.front)
                }
                for (pair, gap) in gaps where gap + 1e-8 < min(0, initial[pair]!) {
                    throw ROBAnimationError.invalid("\(sequence.name), clip \(index + 1): new/deeper whole-body intersection at \(pair): \(gap)m")
                }
                samples += 1
            }
            previous.merge(clip.pose.values) { _, new in new }; time += sequence.playbackDuration(for: clip)
        }
        guard compactSpan <= wideSpan - 0.15, compactFront <= wideFront + 0.02 else {
            throw ROBAnimationError.invalid("Compact entry did not reduce width by 15 cm while retaining forward reach: \(wideSpan) → \(compactSpan), forward \(wideFront) → \(compactFront)")
        }
        guard orientationToolGap >= 0.06 else {
            throw ROBAnimationError.invalid("Compact orientation crowds the open-gripper allowance: \(orientationToolGap)m")
        }
        // A separate full-pitch-before-roll candidate really does intersect
        // the modeled torso. Keep that failure observable in this fixture.
        var pitchOnly = baseline
        for clip in wide.clips.prefix(2) { pitchOnly.merge(clip.pose.values) { _, new in new } }
        for side in ["left", "right"] { pitchOnly["arm.\(side).j6"] = sequence.clips[2].pose.values["arm.\(side).j6"] }
        let wrongPath = try separations(pitchOnly)
        guard wrongPath.contains(where: { $0.value < min(0, initial[$0.key]!) - 0.001 }) else {
            throw ROBAnimationError.invalid("Whole-body check failed to detect the rejected pitch-only path")
        }
        print("PASS \(sequence.name): \(samples) paired whole-body samples; no new/deeper model intersections; rejected pitch-only shortcut detected")
        print("PASS compact envelope: width \(wideSpan)m → \(compactSpan)m; forward \(wideFront)m → \(compactFront)m; orientation gripper separation \(orientationToolGap)m")
    }
}
