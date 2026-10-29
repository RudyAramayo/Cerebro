import Foundation
import simd

/// Offline regression for the reported bow-entry tread collision. Starts at
/// hanging zero, including the first clip; it never connects to hardware.
@main struct AnimationEntryGeometryTests {
    static func main() throws {
        setbuf(stdout, nil)
        func check(_ value: @autoclosure () -> Bool, _ detail: String = "Animation entry invariant failed") {
            guard value() else { fputs("FAIL: " + detail + "\n", stderr); exit(1) }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let document = try ROBAnimationStore.decode(Data(contentsOf: root.appendingPathComponent("Animations/japanese-bow.json")))
        try document.validate()
        let sequence = document.sequences[0]
        check(sequence.clips.count == 8)
        let directory = root.appendingPathComponent("Cerebro/Resources/ShadowPlanner")
        var baseline: [String: Double] = ["maestro.0":6000, "maestro.1":6011, "maestro.2":6906]
        for side in ["right", "left"] { for j in 1...7 { baseline["arm.\(side).j\(j)"] = 0 } }
        for side in ["right", "left"] {
            let model = try ROBGhostRobotModel(directory: directory, physicalSide: side)
            var proxy = ROBWorkspaceSelfProxyClearance(model: model)
            let zero = Array(repeating: 0.0, count: 7)
            let initial = try proxy.separations(vendorLeft: zero)
            let narrow = Set(initial.filter { $0.value < 0.03 }.keys)
            func joints(_ values: [String:Double]) -> [Double] { (1...7).map { values["arm.\(side).j\($0)"]! } }
            let lift = joints(ROBAnimationDocument.sample(sequence, at: sequence.clips[0].transition, baseline: baseline))
            let orient = joints(ROBAnimationDocument.sample(sequence, at: sequence.clips[0].duration + sequence.clips[1].transition, baseline: baseline))
            check([3,5,6,7].allSatisfy { sequence.clips[0].pose.values["arm.\(side).j\($0)"] == nil }, "Lift must retain the measured wrist/forearm pose, not rotate it to zero")
            var changedBaseline = baseline
            for j in [3,5,6,7] { changedBaseline["arm.\(side).j\(j)"] = 0.1 }
            let inherited = ROBAnimationDocument.sample(sequence, at: sequence.clips[0].transition / 2, baseline: changedBaseline)
            check([3,5,6,7].allSatisfy { inherited["arm.\(side).j\($0)"] == 0.1 }, "Lift changed an omitted wrist or forearm channel")
            check([0,1,2,3].allSatisfy { lift[$0] == orient[$0] }, "Orientation clip lowered the shoulder/elbow before rotating the gripper")
            let liftHeight = model.torsoTurnVerticalClearance(vendorJoints: lift)!
            print("Checking \(side) lift-envelope height \(liftHeight)m")
            check(liftHeight >= 0.05, "The whole raised arm/open-gripper envelope needs modeled height above the treads before rotation: \(side) \(liftHeight)")
            // The former shortcut rotated the wrist while still below the
            // tread envelope. Keep that failure observable in this fixture.
            let oldTarget = joints(sequence.clips[2].pose.values)
            let shortcut = oldTarget.map { $0 * 0.2 }
            check(abs(shortcut[4]) > 0.1 && model.torsoTurnVerticalClearance(vendorJoints: shortcut)! < 0.05)
            var time = 0.0, previous = zero, worst = Double.infinity
            for (index, clip) in sequence.clips.enumerated() {
                let goal = joints(ROBAnimationDocument.sample(sequence, at: time + clip.transition, baseline: baseline))
                let delta = zip(previous, goal).map { abs($1-$0) }.max()!
                check(delta * (clip.easing == .smooth ? 1.5 : 1) / clip.transition <= 0.20 + 1e-9)
                let count = max(20, Int(ceil(delta / 0.01)))
                let required = initial.mapValues { index == 0 ? min(0.03, $0) : 0.03 }
                for sample in 0...count {
                    let values = ROBAnimationDocument.sample(sequence, at: time + clip.transition * Double(sample) / Double(count), baseline: baseline)
                    let q = joints(values)
                    check(zip(q, ROBWorkspaceCollisionPlan.jointBounds(model: model)).allSatisfy { $1.contains($0) })
                    let gaps = try proxy.separations(vendorLeft: q, forceNarrowPairs: narrow, minimumRetreatBounds: required)
                    check(gaps.keys == initial.keys)
                    for (pair, gap) in gaps {
                        check(gap + 1e-8 >= required[pair]!, "\(side), clip \(index+1), sample \(sample)/\(count): \(pair) approaches treads (\(gap), required \(required[pair]!))")
                        if index > 0 { worst = min(worst, gap) }
                    }
                }
                previous = goal; time += clip.duration
            }
            print("PASS \(side): complete zero-to-bow path; wrists held through lift; raised envelope \(liftHeight)m; subsequent tread-separation bound \(worst)m")
        }
        print("Model-only geometry; external obstacles, motor mapping and physical clearance still require observation. No robot transport linked.")
    }
}
