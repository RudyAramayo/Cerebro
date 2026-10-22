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
        let acceptedUpright = ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 6011,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        precondition(acceptedUpright.lowerPitch == 0 && acceptedUpright.upperPitch == 0)
        let acceptedSocial = ROBHeadCameraPoseEstimator.estimate(panRadians: .pi / 6, lowerTarget: 6011,
            upperTarget: 6306, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        precondition(abs(acceptedSocial.upperPitch + .pi / 10) < 1e-9 && acceptedSocial.lowerPitch == 0)
        precondition(ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 6011,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: false) == nil)
        precondition(ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 0,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true) == nil)
        precondition(ROBHeadCameraPoseEstimator.estimate(panRadians: .nan, lowerTarget: 6011,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true) == nil)
        // A captured lean-back pose must not survive an upright command.
        var zeroNeck = model.reference
        zeroNeck.merge(upright) { _, command in command }
        let lowerOnly = model.headPositions(pan: 0, lowerPitch: 0.1, upperPitch: 0)!
        precondition(lowerOnly["lower_neck"] == 0.1 && lowerOnly["upper_neck"] == 0)
        func opticalPitch(_ frames: [String: simd_double4x4]) -> Double {
            let direction = frames["oak_optical_frame"]!.columns.2
            return atan2(direction.z, hypot(direction.x, direction.y))
        }
        let displayNeutral = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 6011, upperTarget: 6906, known: true)!
        let displayFrames = head(0, displayNeutral.lowerPitch, displayNeutral.upperPitch)
        precondition(displayNeutral.lowerPitch == 0 && displayNeutral.upperPitch == 0)
        precondition(abs(opticalPitch(displayFrames)) < 1e-8,
            "Observed upright posture must place the front camera parallel to the floor")
        let neckUp = displayFrames["lower_neck_link"]!.columns.2
        precondition(simd_distance(SIMD3(neckUp.x, neckUp.y, neckUp.z), SIMD3<Double>(0, 0, 1)) < 1e-8)
        let displayLowerMoved = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 6411, upperTarget: 6906, known: true)!
        let displayUpperMoved = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 6011, upperTarget: 6506, known: true)!
        for changed in [displayLowerMoved, displayUpperMoved] {
            precondition(abs(opticalPitch(head(0, changed.lowerPitch, changed.upperPitch)) + 12 * .pi / 180) < 1e-8,
                "Observed neutral must remain articulated by each accepted neck command")
        }
        let inferredCandidate = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 7014, upperTarget: 7790, known: true)!
        precondition(abs(inferredCandidate.lowerPitch) > 0.5 && abs(inferredCandidate.upperPitch) > 0.4,
            "A later live target pair must not silently replace the operator-confirmed display zero")
        precondition(ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 6011, upperTarget: 6906, known: false) == nil)
        precondition(ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 0, upperTarget: 6906, known: true) == nil)
        let acceptedForward = ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 7014,
            upperTarget: 7790, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        let forwardHead = head(acceptedForward.panRadians, acceptedForward.lowerPitch, acceptedForward.upperPitch)
        precondition(abs(opticalPitch(forwardHead) + 3.57 * .pi / 180) < 1e-8,
            "Accepted lower/upper commands must counter-rotate, not point the cloud at the ceiling")
        let acceptedLowerOnly = ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 6411,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        precondition(abs(opticalPitch(head(0, acceptedLowerOnly.lowerPitch, acceptedLowerOnly.upperPitch)) + 12 * .pi / 180) < 1e-8,
            "Increasing the accepted lower target must pitch the optical direction downward")
        let acceptedCompensated = ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 6411,
            upperTarget: 7306, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        let compensated = head(0, acceptedCompensated.lowerPitch, acceptedCompensated.upperPitch)
        precondition(abs(opticalPitch(compensated)) < 1e-8,
            "Equal positive lower/upper command deltas must preserve the level optical direction")
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
        precondition(lowerAxis.x > 0.09 && lowerAxis.z > 0.99)
        precondition(simd_distance(lowerBent["neck_pan_link"]!.columns.3, level["neck_pan_link"]!.columns.3) > 0.01)
        precondition(head(0, -0.1, 0.1)["lower_neck_link"]! != level["lower_neck_link"]!)
        precondition(model.headPositions(pan: .nan, lowerPitch: 0, upperPitch: 0) == nil)
        precondition(compensated["lower_neck_link"]! != level["lower_neck_link"]!,
            "Level camera compensation must not freeze the lower-neck joint")
        print("Head FK: upright/upper-only preserved; lower rotates down, paired commands counter-rotate, 7014/7790 predicts -3.57 degrees; belly remains fixed")
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
        precondition(proposal.seconds < 20 && proposal.steps.count == 11)
        let approachFrom = ROBLeftArmInteractionPlan.target(index: 5)!, approachTo = ROBLeftArmInteractionPlan.target(index: 6)!
        precondition(abs(ROBLeftArmInteractionPlan.duration(from: approachFrom, to: approachTo)! * 4 -
            ROBArmRoutinePlan.duration(from: approachFrom, to: approachTo)!) < 1e-8)
        let crest = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveIndex)!
        precondition((0.7...0.75).contains(ROBLeftArmInteractionPlan.duration(from: wave, to: crest)!))
        let route = Array(ROBLeftArmInteractionPlan.waypoints[1...ROBLeftArmInteractionPlan.waveRestIndex])
        let compact = ROBLeftGestureCompiler.compactRoute(baseline: Array(repeating: 0, count: 7), targets: route)
        precondition(compact == [1,4,6,9,12,15,18,24,28,34,42].map { ROBLeftArmInteractionPlan.waypoints[$0] })
        let zero = Array(repeating: 0.0, count: 7)
        let centerRoute = ROBLeftArmInteractionPlan.executionRoute(from: zero, hanging: false)!
        let centerStops = ROBLeftArmInteractionPlan.compactRoute(from: zero, indices: centerRoute)!
        precondition(ROBLeftArmInteractionPlan.route(from: zero, hanging: false)!.count == 28)
        precondition(centerStops == [1,4,6,18,28])
        let returnStops = ROBLeftArmInteractionPlan.compactRoute(from: center,
            indices: ROBLeftArmInteractionPlan.executionRoute(from: center, hanging: true)!)!
        precondition(returnStops == [18,6,4,1,0])
        let centerProposal = try ROBLeftGestureCompiler.compile(kind: "center", name: "Smooth handoff", model: model,
            baseline: zero, generation: 42)
        precondition(centerProposal.steps.map(\.positions) == centerStops.map { ROBLeftArmInteractionPlan.waypoints[$0] },
            "Normal controls and ghost preview must traverse the same retained corners")
        for start in 0...ROBLeftArmInteractionPlan.waveRestIndex {
            for hanging in [false, true] {
                var previous = ROBLeftArmInteractionPlan.waypoints[start]
                let original = ROBLeftArmInteractionPlan.executionRoute(from: previous, hanging: hanging)!
                let reduced = ROBLeftArmInteractionPlan.compactRoute(from: previous, indices: original)!
                for index in reduced {
                    precondition(ROBLeftArmInteractionPlan.allowsDirectMove(from: previous, to: index))
                    previous = ROBLeftArmInteractionPlan.waypoints[index]
                }
                precondition(original.last == reduced.last)
            }
        }
        print(String(format: "Normal handoff: 28 stops reduced to 5, %.1f seconds scheduled; ghost path and reverse corners agree", centerProposal.seconds))
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
        let object = ROBWorkspaceDetection(visible: true, confidence: 0.85, box: [0.3,0.3,0.7,0.7],
            aim: [0.5,0.5], depthPoint: [0.5,0.35])
        let absent = ROBWorkspaceDetection(visible: false, confidence: 0, box: [], aim: [], depthPoint: [])
        let observation = ROBWorkspaceObservation(can: object, orangeBucket: absent,
            leftArmHanging: true, rightArmHanging: false, hangingConfidence: 0.8)
        let observationJSON = String(data: try JSONEncoder().encode(observation), encoding: .utf8)!
        let decodedObservation = try ROBWorkspaceObservation.decode(observationJSON)
        precondition(decodedObservation.can.usable)
        expectBlocked { _ = try ROBWorkspaceObservation.decode(observationJSON + " move the motors") }
        expectBlocked { _ = try ROBWorkspaceObservation.decode(observationJSON.replacingOccurrences(of: "0.85", with: "1.85")) }
        let view = ROBWorkspaceView(panDegrees: 0, upperTarget: 6906)
        func ground(_ depth: @escaping (Int,Int) -> UInt16?) -> ROBWorkspaceLocatedObject? {
            ROBWorkspaceGrounding.locate(target: .can, detection: object, width: 640, height: 480,
                fx: 500, fy: 500, cx: 319.5, cy: 239.5, depth: depth,
                view: view, model: model, capturedAt: 1000, sequence: 1)
        }
        let located = ground { _,_ in 700 }!
        let frame = view.cameraFrame(model: model)!
        let expected = frame * SIMD4<Double>(0,0,0.7,1)
        precondition(simd_distance(located.point, SIMD3(expected.x,expected.y,expected.z)) < 1e-8)
        precondition(ground { _,_ in nil } == nil)
        precondition(ground { x,_ in x % 2 == 0 ? 700 : 1800 } == nil,
            "Mixed foreground/background depth was accepted")
        let confirmed = ROBWorkspaceLocatedObject(target: .can, position: located.position, confidence: 0.8,
            capturedAt: 1500, sequence: 2, view: view)
        precondition(located.agrees(with: confirmed) && !located.agrees(with: located))
        let changedObject = ROBWorkspaceLocatedObject(target: .can, position: [10,10,10], confidence: 0.8,
            capturedAt: 1500, sequence: 2, view: view)
        precondition(!located.agrees(with: changedObject))
        let hint = ROBWorkspacePointingHint(x: 0.65, y: 0.5, dx: 0.15, dy: 0, distanceMeters: 1)
        precondition(hint.agrees(with: hint) && hint.guidedView(from: view).panDegrees < 0)
        precondition(!hint.agrees(with: .init(x: 0.65, y: 0.5, dx: -0.15, dy: 0, distanceMeters: 1)))
        print("Local search: typed observations, calibrated depth projection, distinct-frame confirmation and pointing direction; missing/mixed depth and invalid facts rejected")

        let hand = model.toolPosition(model.positions(vendorLeft: center))!
        let can = ROBWorkspaceLocatedObject(target: .can, position: [hand.x,hand.y,hand.z], confidence: 0.9,
            capturedAt: 1000, sequence: 1, view: view)
        let bucket = ROBWorkspaceLocatedObject(target: .orangeBucket, position: [hand.x,hand.y + 0.08,hand.z - 0.10],
            confidence: 0.9, capturedAt: 1500, sequence: 2, view: view)
        let task = try ROBWorkspaceGrounding.task(can: can, bucket: bucket, model: model)
        let tabletop = try ROBLeftGestureCompiler.compile(kind: "tabletop", name: task.name, poses: task.poses,
            model: model, baseline: zero, generation: 42)
        try ROBLeftGestureCompiler.validate(tabletop, model: model)
        precondition(tabletop.steps.compactMap(\.jawAction) == [.prepare,.grip,.release])
        precondition(tabletop.steps.prefix(5).map(\.positions) == centerStops.map { ROBLeftArmInteractionPlan.waypoints[$0] })
        precondition(tabletop.steps.last!.stage == "Retreat")
        var tamperedSteps = tabletop.steps; tamperedSteps[0].jawAction = .grip
        let tampered = ROBLeftGestureProposal(id: tabletop.id, name: tabletop.name, kind: tabletop.kind,
            modelID: tabletop.modelID, referenceID: tabletop.referenceID, geometryID: tabletop.geometryID,
            mappingID: tabletop.mappingID, sessionGeneration: 42, baseline: zero, poses: tabletop.poses, steps: tamperedSteps)
        expectBlocked { try ROBLeftGestureCompiler.validate(tampered, model: model) }
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "tabletop", name: "Incomplete", poses: Array(task.poses.prefix(4)),
            model: model, baseline: zero, generation: 42) }
        print("Recycling plan: observed can/bucket → local IK → five-anchor route, five-segment presentation, exact prepare/grip/release boundaries and tamper rejection")
        print("Ghost motion plan fixtures passed; model preview assumptions are not physical calibration")
    }
}
