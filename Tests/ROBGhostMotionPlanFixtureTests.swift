import Foundation
import simd

@main struct GhostMotionFixtures {
    static func expectBlocked(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Unsafe or changed proposal was admitted") }
        catch { }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = try ROBGhostRobotModel(directory: root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
        precondition(model.modelID.count == 64 && model.joints.count == 44 && model.hulls.count >= 40)
        func head(_ pan: Double, _ lower: Double, _ upper: Double) -> [String: simd_double4x4] {
            var positions = model.reference
            positions.merge(model.headPositions(pan: pan, lowerPitch: lower, upperPitch: upper)!) { _, command in command }
            return model.frames(positions)
        }
        let upright = model.headPositions(pan: 0, lowerPitch: 0, upperPitch: 0)!
        precondition(upright["lower_neck"] == 0 && upright["upper_neck"] == 0 && upright["neck_pan"] == 0)
        // A captured lean-back pose must not survive an upright command.
        var zeroNeck = model.reference
        zeroNeck.merge(upright) { _, command in command }
        let lowerOnly = model.headPositions(pan: 0, lowerPitch: 0.1, upperPitch: 0)!
        precondition(lowerOnly["lower_neck"] == -0.1 && lowerOnly["upper_neck"] == 0)
        let level = head(0, 0, 0), down = head(0, 0, -.pi / 10), turned = head(.pi / 6, 0, -.pi / 10)
        let forward = level["oak_optical_frame"]!.columns.2
        let downForward = down["oak_optical_frame"]!.columns.2
        precondition(abs(forward.z) < 1e-8 && forward.x > 0.99)
        precondition(abs(atan2(downForward.z, hypot(downForward.x, downForward.y)) + .pi / 10) < 1e-8)
        precondition(turned["oak_optical_frame"]!.columns.2.y > 0.4)
        precondition(simd_distance(level["oak_optical_frame"]!.columns.3, down["oak_optical_frame"]!.columns.3) > 0.02)
        precondition(level["belly_oak_optical_frame"]! == turned["belly_oak_optical_frame"]!)
        precondition(level["lower_neck_link"]! == model.frames(zeroNeck)["lower_neck_link"]!)
        let lowerBent = head(0, 0.1, 0)
        let lowerAxis = lowerBent["lower_neck_link"]!.columns.2
        precondition(lowerAxis.x < -0.09 && lowerAxis.z > 0.99)
        precondition(simd_distance(lowerBent["neck_pan_link"]!.columns.3, level["neck_pan_link"]!.columns.3) > 0.01)
        precondition(head(0, -0.1, 0.1)["lower_neck_link"]! != level["lower_neck_link"]!)
        precondition(model.headPositions(pan: .nan, lowerPitch: 0, upperPitch: 0) == nil)
        print("Head FK: level/down/pan command priors articulate the camera and neck together; belly remains fixed")
        let oldFront = ROBLeftArmInteractionPlan.target(index: 18)!
        let center = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!
        let wave = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveRestIndex)!
        let oldXYZ = model.toolPosition(model.positions(vendorLeft: oldFront))!
        let centerXYZ = model.toolPosition(model.positions(vendorLeft: center))!
        let waveFrames = model.frames(model.positions(vendorLeft: wave))
        let waveXYZ = model.toolPosition(model.positions(vendorLeft: wave))!
        let shoulderZ = waveFrames["left_one_Link"]!.columns.3.z
        let j6CenterXYZ = model.toolPosition(model.positions(vendorLeft: ROBLeftArmInteractionPlan.target(index: 24)!))!
        precondition(abs(j6CenterXYZ.y) < 0.05 && j6CenterXYZ.y < oldXYZ.y - 0.1)
        precondition(centerXYZ.z > j6CenterXYZ.z + 0.18)
        precondition(waveXYZ.z > shoulderZ + 0.15)
        precondition(wave[4] == -1.4 && ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveIndex)![5] == -0.9)
        print("URDF: negative J6 centers the hand; larger J2 and negative J4 put the wave above shoulder height")

        let proposal = try ROBLeftGestureCompiler.compile(kind: "wave", name: "High wave", model: model,
            baseline: Array(repeating: 0, count: 7), generation: 42)
        try ROBLeftGestureCompiler.validate(proposal, model: model)
        precondition(proposal.steps.last!.positions == wave)
        precondition(proposal.steps.allSatisfy { (0.7...5).contains($0.seconds) })
        precondition(proposal.seconds < 20 && proposal.steps.count == 15)
        let approachFrom = ROBLeftArmInteractionPlan.target(index: 5)!, approachTo = ROBLeftArmInteractionPlan.target(index: 6)!
        precondition(abs(ROBLeftArmInteractionPlan.duration(from: approachFrom, to: approachTo)! * 4 -
            ROBArmRoutinePlan.duration(from: approachFrom, to: approachTo)!) < 1e-8)
        let crest = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveIndex)!
        precondition((0.7...0.75).contains(ROBLeftArmInteractionPlan.duration(from: wave, to: crest)!))
        let route = Array(ROBLeftArmInteractionPlan.waypoints[1...ROBLeftArmInteractionPlan.waveRestIndex])
        let compact = ROBLeftGestureCompiler.compactRoute(baseline: Array(repeating: 0, count: 7), targets: route)
        precondition(compact == [1,4,6,9,12,15,18,24,28,34,42].map { ROBLeftArmInteractionPlan.waypoints[$0] })
        // Changing a joint at a corner must not turn into a diagonal shortcut.
        let corner = [[0.1,0,0,0,0,0,0],[0.1,0.1,0,0,0,0,0],[0.2,0.1,0,0,0,0,0]]
        precondition(ROBLeftGestureCompiler.compactRoute(baseline: Array(repeating: 0, count: 7), targets: corner) == corner)
        precondition(proposal.steps.suffix(4).map(\.positions) == [crest,wave,crest,wave])
        print(String(format: "Reviewed pace: collinear increments joined with corners/reversals intact; full wave %.1f seconds scheduled", proposal.seconds))
        let encoded = try proposal.encoded()
        precondition(proposal.fingerprint == ROBGhostRobotModel.hash(encoded))
        let historical = try JSONDecoder().decode(ROBLeftGestureProposal.self, from: encoded)
        precondition(historical.steps.contains { $0.seconds >= 0.7 && $0.seconds < 0.8 })
        precondition(historical.validForReplay(model: model), "Fast recorded steps must replay without reauthorizing execution")
        let invalidReplay = ROBLeftGestureProposal(id: proposal.id, name: proposal.name, kind: proposal.kind, modelID: proposal.modelID,
            referenceID: proposal.referenceID, geometryID: proposal.geometryID, mappingID: proposal.mappingID,
            sessionGeneration: proposal.sessionGeneration, baseline: proposal.baseline, poses: proposal.poses,
            steps: [.init(positions: wave, seconds: 0.3)])
        precondition(!invalidReplay.validForReplay(model: model))
        let changed = ROBLeftGestureProposal(id: proposal.id, name: proposal.name, kind: proposal.kind, modelID: proposal.modelID,
            referenceID: proposal.referenceID, geometryID: proposal.geometryID, mappingID: proposal.mappingID,
            sessionGeneration: proposal.sessionGeneration, baseline: proposal.baseline,
            poses: proposal.poses, steps: Array(proposal.steps.dropLast()))
        expectBlocked { try ROBLeftGestureCompiler.validate(changed, model: model) }
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "wave", name: "Bad", model: model, baseline: center, generation: 0) }
        print("Frozen review: model/session identity, complete targets, timings and SHA256 are bound; tampering rejected")

        let returnIndices = ROBLeftArmInteractionPlan.route(from: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveIndex)!, hanging: false)!
        precondition(returnIndices == Array(stride(from: ROBLeftArmInteractionPlan.waveRestIndex, through: ROBLeftArmInteractionPlan.frontIndex, by: -1)))
        let lowering = ROBLeftArmInteractionPlan.route(from: wave, hanging: true)!
        precondition(lowering == Array(stride(from: ROBLeftArmInteractionPlan.waveRestIndex - 1, through: 0, by: -1)))
        precondition(ROBLeftArmInteractionPlan.stationaryFrontTarget(wave) == nil)
        print("Return: high wave reverses through every raised waypoint before centering/lowering; jaw-only wave-pose action rejected")

        var custom = model.positions(vendorLeft: center)
        custom["left_joint1"] = -0.95
        let gesture = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Small hello", poses: [custom], model: model,
            baseline: center, generation: 42)
        precondition(gesture.steps.last!.positions == center)
        precondition(gesture.steps.contains { abs($0.positions[0] + 0.95) < 0.00001 })
        var otherServo = custom; otherServo["neck_pan"] = 0.1
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Unmapped", poses: [otherServo], model: model, baseline: center, generation: 42) }
        var outside = custom; outside["left_joint2"] = 0
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Near treads", poses: [outside], model: model, baseline: center, generation: 42) }
        var nan = custom; nan["left_joint1"] = .nan
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Invalid", poses: [nan], model: model, baseline: center, generation: 42) }
        print("Custom gestures: bounded front workspace, interpolated steps, reverse return, unmapped axes and non-finite values blocked")

        let start = model.positions(vendorLeft: center)
        let target = model.toolPosition(start)! + SIMD3(0.015, 0, 0.01)
        let solution = model.solveLeft(target: target, from: start, frontWorkspace: true)
        precondition(solution != nil && simd_distance(model.toolPosition(solution!)!, target) < 0.012)
        _ = try ROBLeftGestureCompiler.compile(kind: "custom", name: "XYZ goal", poses: [solution!], model: model,
            baseline: center, generation: 42)
        print("XYZ ghost target: numerical IK reaches the requested nearby model position without hardware transport")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-currents-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = "elapsed_s,sequence,robot_arm,gateway_arm,joint,position_rad,current_raw,current_delta_raw,feedback_age_ms,phase\n"
        var rows = (1...7).map { "1,10,left,right,\($0),0,0.2,\($0 == 3 ? 9 : 0),1,gesture step 0\n" }.joined()
        try (header + rows).write(to: url, atomically: true, encoding: .utf8)
        let recording = try ROBGhostRecordingSample.load(url)
        precondition(recording.count == 1 && recording[0].deltas[2] == 9 && recording[0].step == 0)
        rows += "2,11,left,right,1,0,0.2,0,1,gesture step 1\n"
        try (header + rows).write(to: url, atomically: true, encoding: .utf8)
        expectBlocked { _ = try ROBGhostRecordingSample.load(url) }
        try (header + rows.replacingOccurrences(of: ",0.2,", with: ",nan,")).write(to: url, atomically: true, encoding: .utf8)
        expectBlocked { _ = try ROBGhostRecordingSample.load(url) }
        print("Current replay: per-joint spike retained; incomplete and non-finite samples rejected instead of hidden")
        print("Ghost motion plan fixtures passed; model preview assumptions are not physical calibration")
    }
}
