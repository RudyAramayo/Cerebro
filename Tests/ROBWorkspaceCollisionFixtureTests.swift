import Foundation
import simd

private struct SyntheticMap: ROBWorkspaceCollisionMap {
    let sceneID: UUID
    let cameraGeneration: UUID
    let sessionGeneration: UInt64
    let modelID: String
    let geometryID: String
    let mappingID: String
    var createdAtMilliseconds = 1_000.0
    var oldestCapturedAtMilliseconds = 1_000.0
    var lastCapturedAtMilliseconds = 1_000.0
    let voxelSizeMeters = 0.025
    var registrationID: String? = "isolated synthetic measured registration"
    var registrationUncertaintyMeters: Double? = 0
    var obstacleLow: SIMD3<Double>?
    var obstacleHigh: SIMD3<Double>?
    var observed = true
    var visualCalibrationScope: ROBWorkspaceVisualCalibrationMapScope? = nil
    var fingerprint: String {
        ROBGhostRobotModel.hash(Data("synthetic-map:\(obstacleLow.debugDescription):\(obstacleHigh.debugDescription):\(observed)".utf8))
    }
    func state(at point: SIMD3<Double>) -> ROBWorkspaceVoxelState {
        guard observed, (0..<3).allSatisfy({ abs(point[$0]) <= 3 }) else { return .unknown }
        if let low = obstacleLow, let high = obstacleHigh, (0..<3).allSatisfy({ (low[$0]...high[$0]).contains(point[$0]) }) { return .occupied }
        return .free
    }
    func state(inBoundsLow low:SIMD3<Double>,high:SIMD3<Double>) -> ROBWorkspaceVoxelState {
        guard observed, (0..<3).allSatisfy({ low[$0] >= -3 && high[$0] <= 3 }) else { return .unknown }
        if let a = obstacleLow, let b = obstacleHigh, (0..<3).allSatisfy({ low[$0] <= b[$0] && high[$0] >= a[$0] }) { return .occupied }
        return .free
    }
}

@main struct WorkspaceCollisionFixtures {
    static func blocked(_ expected: String? = nil,line:UInt = #line,_ body: () throws -> Void) {
        do { try body(); preconditionFailure("An unsafe workspace path was admitted") }
        catch { if let expected { precondition(error.localizedDescription.contains(expected),"Fixture line \(line): \(error.localizedDescription)") } }
    }
    static func main() throws {
        setbuf(stdout,nil)
        let tetra="""
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 0 0 1
        f 1 3 2
        f 1 2 4
        f 1 4 3
        f 2 3 4
        """
        let identity=matrix_identity_double4x4
        let cornerGap=try ROBWorkspaceVerifiedConvexEnvelope.distance(hullText:tetra,frame:identity,low:SIMD3(0.75,0.75,0.75),high:SIMD3(0.80,0.80,0.80))
        precondition(cornerGap>0.70,"AABB-overlapping corners must not become convex contact")
        let contactGap=try ROBWorkspaceVerifiedConvexEnvelope.distance(hullText:tetra,frame:identity,low:SIMD3(0.1,0.1,0.1),high:SIMD3(0.2,0.2,0.2))
        precondition(contactGap==0,"True occupied/unknown whole-box contact remains blocked")
        // A 25mm whole-cell distance ALREADY accounts for its extent. The
        // center-sphere lower bound is conservative, never an extra error.
        let cellLow=SIMD3<Double>(-0.085,0.10,0.10),cellHigh=SIMD3<Double>(-0.060,0.125,0.125)
        let faceGap=try ROBWorkspaceVerifiedConvexEnvelope.distance(hullText:tetra,frame:identity,low:cellLow,high:cellHigh)
        precondition(abs(faceGap-0.060)<1e-9)
        let centerDistance=try ROBEstimatedConvexHull(text:tetra).distance(to:(cellLow+cellHigh)/2)
        precondition(centerDistance-sqrt(3)*0.025/2<=faceGap && faceGap<=centerDistance)
        let distantRaw=try ROBWorkspaceVerifiedConvexEnvelope.distance(hullText:tetra,frame:identity,low:SIMD3(-0.12,0.10,0.10),high:SIMD3(-0.12,0.10,0.10))
        precondition(abs(distantRaw-0.12)<1e-9 && distantRaw>faceGap,"Original return bounds and dilated cell are distinct representations, never discarded samples")
        blocked("malformed") {_ = try ROBWorkspaceVerifiedConvexEnvelope.distance(hullText:"v 0 0 0",frame:identity,low:.zero,high:.zero)}
        print("Exact convex: AABB corner artifact removed; whole-cell/raw bounds retain contact, uncertainty and conservative center-sphere relation; malformed hull rejects")
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let model = try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
        let scene = UUID(), camera = UUID(), generation: UInt64 = 42
        let map = SyntheticMap(sceneID:scene,cameraGeneration:camera,sessionGeneration:generation,
            modelID:model.modelID,geometryID:model.geometryID,mappingID:ROBGhostRobotModel.mappingID)
        let front = ROBLeftArmInteractionPlan.target(index:ROBLeftArmInteractionPlan.frontIndex)!, hanging = [Double](repeating:0,count:7)
        if CommandLine.arguments.last == "describe" {
            for (name,q) in [("front",front),("18",ROBLeftArmInteractionPlan.target(index:18)!),("6",ROBLeftArmInteractionPlan.target(index:6)!),("hanging",hanging)] {
                print(name,q,"tread",model.treadSeparation(vendorLeft:q))
                for (link,bounds) in model.worldCollisionBounds(positions:model.positions(vendorLeft:q)).sorted(by:{ $0.key < $1.key })
                    where link.hasPrefix("left_") && (link.hasSuffix("_Link") || link == "left_tool") {
                    print(link,bounds.low,bounds.high)
                }
            }
            return
        }
        func make(_ from:[Double],_ to:[Double],_ map:SyntheticMap = map) throws -> ROBWorkspaceCollisionPlan {
            try .make(from:from,to:to,map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
        }
        let historicalRawBounds: [ClosedRange<Double>] = [(-2.4435)...2.4435,(-2.3213)...2.3213,
            (-2.2863)...2.2863,(-2.2863)...2.2863,(-2.2863)...2.2863,(-2.2863)...2.2863,(-3.05)...3.05]
        precondition(ROBArmJointLimits.radians == historicalRawBounds && ROBArmControlProtocol.targetJointBoundsRadians == historicalRawBounds,
            "Shared extraction changed an existing raw transport bound")
        let modelBounds = ROBWorkspaceCollisionPlan.jointBounds(model:model)
        for (index,bound) in modelBounds.enumerated() {
            precondition(historicalRawBounds[index].contains(bound.lowerBound) && historicalRawBounds[index].contains(bound.upperBound))
            for edge in [historicalRawBounds[index].lowerBound,historicalRawBounds[index].upperBound] {
                var raw = Array(repeating:0.0,count:7); raw[index] = edge
                precondition(ROBArmControlProtocol.containsTargetPositions(raw))
            }
        }
        precondition(modelBounds[1].upperBound == 2.3213 && modelBounds[3].lowerBound == -2.2863 && modelBounds[5].upperBound == 2.2863)
        precondition(modelBounds[1].lowerBound > historicalRawBounds[1].lowerBound && modelBounds[3].upperBound < historicalRawBounds[3].upperBound &&
            modelBounds[5].lowerBound > historicalRawBounds[5].lowerBound,"The stricter converted model limits were widened")
        for (index,value) in [(1,2.5),(3,-2.5),(5,2.30)] {
            var bad = front; bad[index] = value
            precondition(!ROBArmControlProtocol.containsTargetPositions(bad))
            blocked("transport joint bounds") { _ = try make(front,bad) }
            blocked("transport joint bounds") {
                _ = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:[.init(positions:bad,seconds:0.7)],map:map,
                    model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
            }
        }
        for value in [1e20,-1e20,1e300,-1e300,Double.greatestFiniteMagnitude,-Double.greatestFiniteMagnitude,Double.infinity,Double.nan] {
            var huge = front; huge[0] = value
            blocked("transport joint bounds") {
                _ = try ROBWorkspaceCollisionPlan.review(baseline:huge,steps:[.init(positions:front,seconds:0.7)],map:map,
                    model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
            }
            blocked("transport joint bounds") {
                _ = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:[.init(positions:huge,seconds:0.7)],map:map,
                    model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
            }
        }
        print("Raw bounds: gateway/protocol/planner share unchanged J1...J7 ranges, stricter converted model bounds retained; huge finite/nonfinite endpoints reject before integer sampling conversion")
        let q = zip(front,hanging).map { $0+($1-$0)*0.05 }
        let measuredPayload = ROBWorkspaceCarriedObject(measurementID:"isolated measured payload",centerInToolMeters:[0,0,0],
            halfExtentsMeters:[0.06,0.04,0.04])
        let carryingSteps: [ROBLeftGestureProposal.Step] = [.init(positions:front,seconds:0.7,jawAction:.grip),
            .init(positions:q,seconds:0.7),.init(positions:q,seconds:0.7,jawAction:.release)]
        for steps in [carryingSteps,Array(carryingSteps.prefix(1)),Array(carryingSteps.suffix(1))] {
            blocked("measured payload") {
                _ = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:steps,map:map,model:model,generation:generation,
                    sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
            }
        }
        let measuredCarry = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:carryingSteps,map:map,model:model,generation:generation,
            sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000,payload:measuredPayload)
        precondition(measuredCarry.payload == measuredPayload)
        try measuredCarry.validate(map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001)
        _ = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:[.init(positions:front,seconds:0.7,jawAction:.prepare)],map:map,
            model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
        print("Payload admission: measured grasp/carry/release passes; nil payload rejects complete routes and individual grip/release steps; empty preparation remains valid")
        let clear = try make(front,q)
        try clear.validate(map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001)
        precondition(clear.steps.last?.positions == q && clear.steps.allSatisfy({ $0.jawAction == nil }))
        let compiled = try ROBLeftGestureCompiler.compile(kind:"workspace_collision",name:"Observed connector",model:model,
            baseline:front,generation:generation,workspaceCollisionPlan:clear,collisionMap:map,collisionSceneID:scene,
            collisionCameraGeneration:camera,nowMilliseconds:1_000)
        try ROBLeftGestureCompiler.validate(compiled,model:model,collisionMap:map,collisionSceneID:scene,
            collisionCameraGeneration:camera,nowMilliseconds:1_001)
        blocked("matching live") { try ROBLeftGestureCompiler.validate(compiled,model:model) }
        let decoded = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:compiled.encoded())
        precondition(decoded == compiled && compiled.workspaceCollisionPlan == clear)
        if CommandLine.arguments.last == "combined-recycling" {
            let historicalURL = root.appendingPathComponent("docs/calibration/evidence/2026-10-22-recycling/first-confirmed-recycle.proposal.json")
            let historical = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:Data(contentsOf:historicalURL))
            try ROBLeftGestureCompiler.validate(historical,model:model)
            let entry = try make(q,front)
            func recycling(entry:ROBWorkspaceCollisionPlan?, proof:ROBWorkspaceCollisionPlan? = nil,
                           liveMap: (any ROBWorkspaceCollisionMap)? = map) throws -> ROBLeftGestureProposal {
                try ROBLeftGestureCompiler.compile(kind:"recycling",name:"Entire observed recycling route",poses:historical.poses,
                    model:model,baseline:q,generation:generation,recyclingActions:historical.recyclingActions,
                    workspaceCollisionPlan:proof,workspaceApproachPlan:entry,collisionMap:liveMap,
                    collisionSceneID:scene,collisionCameraGeneration:camera,nowMilliseconds:1_000)
            }
            let body = try ROBLeftGestureCompiler.compile(kind:"recycling",name:"Entire observed recycling route",poses:historical.poses,
                model:model,baseline:front,generation:generation,recyclingActions:historical.recyclingActions)
            let complete = try recycling(entry:entry)
            precondition(complete.kind == "recycling" && complete.baseline == q && complete.workspaceApproachPlan == entry)
            precondition(complete.steps == entry.steps+body.steps && complete.poses == historical.poses)
            precondition(complete.recyclingActions == historical.recyclingActions && complete.steps.compactMap(\.jawAction) == [.prepare,.grip,.release])
            blocked("measured payload") {
                _ = try ROBWorkspaceCollisionPlan.review(baseline:q,steps:complete.steps,map:map,model:model,generation:generation,
                    sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
            }
            let fullReview = try ROBWorkspaceCollisionPlan.review(baseline:q,steps:complete.steps,map:map,model:model,generation:generation,
                sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000,payload:measuredPayload)
            let frozen = try recycling(entry:entry,proof:fullReview)
            precondition(frozen.steps == complete.steps && frozen.workspaceCollisionPlan == fullReview)
            try ROBLeftGestureCompiler.validate(frozen,model:model,collisionMap:map,collisionSceneID:scene,
                collisionCameraGeneration:camera,nowMilliseconds:1_001)
            let decoded = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:frozen.encoded())
            precondition(decoded == frozen)
            blocked("matching live") { try ROBLeftGestureCompiler.validate(frozen,model:model) }
            blocked("live map") { _ = try recycling(entry:entry,liveMap:nil) }
            blocked("exact front") { _ = try recycling(entry:clear) }
            blocked("matching live") { _ = try recycling(entry:entry,proof:clear) }
            blocked("another gesture") {
                _ = try ROBLeftGestureCompiler.compile(kind:"center",name:"Wrong scope",model:model,baseline:q,
                    generation:generation,workspaceApproachPlan:entry,collisionMap:map,collisionSceneID:scene,
                    collisionCameraGeneration:camera,nowMilliseconds:1_000)
            }
            print("Entire recycling route: dynamic \(entry.steps.count)-step approach + \(body.steps.count)-step body frozen before any movement; exact front join, original jaws/kind/actions preserved; whole-route proof roundtrips and missing/mismatched maps rejected; legacy archive remains valid")
            return
        }
        var unknown = map; unknown.observed = false
        blocked("unobserved") { _ = try make(front,q,unknown) }
        var unregistered = map; unregistered.registrationID = nil; unregistered.registrationUncertaintyMeters = nil
        blocked("registration") { _ = try make(front,q,unregistered) }
        // The explicit local experimental lane retains nil registration and
        // exactly the same obstacle, unknown, whole-arm and payload checker.
        let fixtureHash = ROBGhostRobotModel.hash(Data("isolated visual-trial fixture".utf8))
        unregistered.visualCalibrationScope = .init(bodyMotionIdentity:"fixture body",bodyContextIsCurrent:true,
            estimatedCameraProjectionIdentity:fixtureHash,observationPoseIdentity:fixtureHash,observedFrameCount:2)
        func trial(_ source:SyntheticMap,baseline:[Double] = front,receipt:String = fixtureHash,command:String = "left_recycle_cans",
                   expiry:Double = 2_000,allowance:Double = 0.05) -> ROBWorkspaceVisualCalibrationTrial {
            .init(receiptID:"isolated local receipt",receiptSHA256:receipt,appSessionID:"isolated app session",
                command:command,canCount:4,summarySHA256:fixtureHash,authorizationContextIdentity:"isolated broker scope",
                sessionGeneration:generation,sceneID:scene,cameraGeneration:camera,modelID:model.modelID,
                geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:source.fingerprint,
                bodyMotionIdentity:"fixture body",estimatedCameraProjectionIdentity:fixtureHash,observationPoseIdentity:fixtureHash,
                currentPoseIdentity:fixtureHash,baseline:baseline,issuedAtMilliseconds:1_000,expiresAtMilliseconds:expiry,
                assumedSpatialErrorMeters:allowance)
        }
        let permit = trial(unregistered)
        let estimated = try ROBWorkspaceCollisionPlan.makeVisualCalibrationTrial(from:front,to:q,map:unregistered,model:model,
            generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000,trial:permit)
        precondition(unregistered.registrationID == nil && unregistered.registrationUncertaintyMeters == nil &&
            estimated.context.registrationID == nil && estimated.context.registrationUncertaintyMeters == nil &&
            estimated.context.visualTrial == permit && estimated.context.spatialErrorAllowanceMeters == 0.05)
        try estimated.validateVisualCalibrationTrial(map:unregistered,model:model,generation:generation,sceneID:scene,
            cameraGeneration:camera,nowMilliseconds:1_001,trial:permit)
        blocked("registration") { _ = try make(front,q,unregistered) }
        blocked("registration") {
            try estimated.validate(map:unregistered,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001)
        }
        blocked("registration") {
            _ = try ROBLeftGestureCompiler.compile(kind:"workspace_collision",name:"No implicit estimated authority",model:model,
                baseline:front,generation:generation,workspaceCollisionPlan:estimated,collisionMap:unregistered,
                collisionSceneID:scene,collisionCameraGeneration:camera,nowMilliseconds:1_001)
        }
        let experimental = try ROBLeftGestureCompiler.compile(kind:"workspace_collision",name:"Explicit visual calibration trial",model:model,
            baseline:front,generation:generation,workspaceCollisionPlan:estimated,collisionMap:unregistered,
            collisionSceneID:scene,collisionCameraGeneration:camera,visualCalibrationTrial:permit,nowMilliseconds:1_001)
        let imported = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:experimental.encoded())
        blocked("registration") {
            try ROBLeftGestureCompiler.validate(imported,model:model,collisionMap:unregistered,collisionSceneID:scene,
                collisionCameraGeneration:camera,nowMilliseconds:1_001)
        }
        try ROBLeftGestureCompiler.validate(imported,model:model,collisionMap:unregistered,collisionSceneID:scene,
            collisionCameraGeneration:camera,visualCalibrationTrial:permit,nowMilliseconds:1_001)
        blocked("scope") {
            _ = try ROBWorkspaceCollisionPlan.makeVisualCalibrationTrial(from:front,to:q,map:unregistered,model:model,generation:generation,
                sceneID:scene,cameraGeneration:camera,nowMilliseconds:2_001,trial:permit)
        }
        for bad in [trial(unregistered,receipt:"not a receipt hash"),trial(unregistered,allowance:0),trial(unregistered,allowance:0.151),
                    trial(unregistered,command:"right_recycle_cans"),trial(unregistered,command:"left_recycle_can")] {
            blocked("scope") { _ = try ROBWorkspaceCollisionPlan.validateVisualCalibrationTrialMap(unregistered,model:model,
                generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001,trial:bad) }
        }
        let otherReceipt = trial(unregistered,receipt:ROBGhostRobotModel.hash(Data("different receipt".utf8)))
        blocked("changed") { try estimated.validateVisualCalibrationTrial(map:unregistered,model:model,generation:generation,
            sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001,trial:otherReceipt) }
        var missingScope = unregistered; missingScope.visualCalibrationScope = nil
        var movedBody = unregistered; movedBody.visualCalibrationScope = .init(bodyMotionIdentity:"fixture body",bodyContextIsCurrent:false,
            estimatedCameraProjectionIdentity:fixtureHash,observationPoseIdentity:fixtureHash,observedFrameCount:2)
        var changedProjection = unregistered; changedProjection.visualCalibrationScope = .init(bodyMotionIdentity:"fixture body",bodyContextIsCurrent:true,
            estimatedCameraProjectionIdentity:String(repeating:"0",count:64),observationPoseIdentity:fixtureHash,observedFrameCount:2)
        for invalid in [missingScope,movedBody,changedProjection] {
            blocked("scope") { _ = try ROBWorkspaceCollisionPlan.validateVisualCalibrationTrialMap(invalid,model:model,
                generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001,trial:permit) }
        }
        blocked("pose") { _ = try ROBWorkspaceCollisionPlan.makeVisualCalibrationTrial(from:q,to:front,map:unregistered,model:model,
            generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001,trial:permit) }
        var unseenTrialMap = unregistered; unseenTrialMap.observed = false
        blocked("unobserved") { _ = try ROBWorkspaceCollisionPlan.makeVisualCalibrationTrial(from:front,to:q,map:unseenTrialMap,model:model,
            generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001,trial:trial(unseenTrialMap)) }
        var obstructedTrialMap = unregistered
        obstructedTrialMap.obstacleLow = [0.17,0.23,0.95]; obstructedTrialMap.obstacleHigh = [0.20,0.26,0.98]
        blocked("obstacle") { _ = try ROBWorkspaceCollisionPlan.makeVisualCalibrationTrial(from:front,to:q,map:obstructedTrialMap,model:model,
            generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001,trial:trial(obstructedTrialMap)) }
        blocked("payload") { _ = try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:front,steps:carryingSteps,
            map:unregistered,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001,trial:permit) }
        _ = try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:front,steps:carryingSteps,map:unregistered,
            model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001,trial:permit,payload:measuredPayload)
        var hangingProxyDeficit=false
        var hangingConvexFailure:String?
        if model.treadSeparation(vendorLeft:hanging) < 0.030 {
            var expectedFailure:String?
            do {
                var narrow=ROBWorkspaceSelfProxyClearance(model:model)
                hangingProxyDeficit=try narrow.minimum(vendorLeft:hanging)<0.030
                if hangingProxyDeficit {expectedFailure="nonworsening retreat"}
            } catch {
                // This LEFT scan includes an unverifiable convex proxy. Its
                // failure must remain a veto, rather than reverting to an
                // optimistic narrow phase or an initial-retreat exemption.
                expectedFailure=error.localizedDescription
                hangingConvexFailure=expectedFailure
                precondition(expectedFailure!.contains("malformed, open, nonmanifold or nonconvex"))
            }
            if let expectedFailure {
                blocked(expectedFailure) { _ = try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:hanging,
                    steps:[.init(positions:hanging,seconds:0.7)],map:unregistered,model:model,generation:generation,sceneID:scene,
                    cameraGeneration:camera,nowMilliseconds:1_001,trial:trial(unregistered,baseline:hanging)) }
            }
        }
        // Existing measured archives omit the new optional lane entirely.
        let encoder = JSONEncoder(); var oldContext = try JSONSerialization.jsonObject(with:encoder.encode(clear.context)) as! [String:Any]
        oldContext.removeValue(forKey:"visualTrial")
        let oldDecoded = try JSONDecoder().decode(ROBWorkspaceCollisionContext.self,from:JSONSerialization.data(withJSONObject:oldContext))
        precondition(oldDecoded == clear.context && oldDecoded.registrationID != nil)
        print("Visual trial: explicit exact receipt/map/pose/expiry lane preserves nil registration; ordinary/imported compiler calls reject; obstacles, unknown space, payload, limits and initial self-proxy overlap remain blocked; measured archives readable")
        var uncertain = map; uncertain.registrationUncertaintyMeters = 0.051
        blocked("registration") { _ = try make(front,q,uncertain) }
        var stale = map; stale.oldestCapturedAtMilliseconds = -60_000
        blocked("stale") { _ = try make(front,q,stale) }
        blocked("another") { _ = try ROBWorkspaceCollisionPlan.validateMap(map,model:model,generation:generation+1,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000) }
        blocked("another") { _ = try ROBWorkspaceCollisionPlan.validateMap(map,model:model,generation:generation,sceneID:UUID(),cameraGeneration:camera,nowMilliseconds:1_000) }
        blocked("another") { _ = try ROBWorkspaceCollisionPlan.validateMap(map,model:model,generation:generation,sceneID:scene,cameraGeneration:UUID(),nowMilliseconds:1_000) }
        for (modelID,geometryID,mappingID) in [("wrong-model",model.geometryID,ROBGhostRobotModel.mappingID),
                                              (model.modelID,"wrong-geometry",ROBGhostRobotModel.mappingID),
                                              (model.modelID,model.geometryID,"wrong-mapping")] {
            let wrong = SyntheticMap(sceneID:scene,cameraGeneration:camera,sessionGeneration:generation,
                modelID:modelID,geometryID:geometryID,mappingID:mappingID)
            blocked("another") { _ = try make(front,q,wrong) }
        }
        var changed = map; changed.obstacleLow = [2,2,2]; changed.obstacleHigh = [2.1,2.1,2.1]
        blocked("changed") { try clear.validate(map:changed,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001) }
        var elbow = map; elbow.obstacleLow = [0.17,0.23,0.95]; elbow.obstacleHigh = [0.20,0.26,0.98]
        let toolBounds = model.worldCollisionBounds(positions:model.positions(vendorLeft:front))["left_tool"]!
        precondition(toolBounds.low.x > elbow.obstacleHigh!.x+0.1,"Elbow fixture unexpectedly also blocks the TCP")
        blocked("left_") { _ = try make(front,q,elbow) }
        var table = map; table.obstacleLow = [0.30,-0.20,0.60]; table.obstacleHigh = [0.85,0.50,0.70]
        var previous = front
        let oldParkingSteps = [18,6,4,1,0].map { index -> ROBLeftGestureProposal.Step in
            let target = ROBLeftArmInteractionPlan.target(index:index)!
            let duration = ROBLeftArmInteractionPlan.duration(from:previous,to:target,padding:ROBArmRoutinePlan.tolerance)!
            previous = target
            return .init(positions:target,seconds:duration,stage:"Historical empty parking route")
        }
        blocked("obstacle") {
            _ = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:oldParkingSteps,map:table,model:model,generation:generation,
                sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
        }
        var sideGoal = ROBLeftArmInteractionPlan.target(index:6)!; sideGoal[0] = 0.25
        blocked("obstacle") {
            let duration = ROBLeftArmInteractionPlan.duration(from:front,to:sideGoal,padding:ROBArmRoutinePlan.tolerance)!
            _ = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:[.init(positions:sideGoal,seconds:duration)],
                map:table,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
        }
        let alternative = try make(front,sideGoal,table)
        try alternative.validate(map:table,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_001)
        precondition(alternative.goal == sideGoal && alternative.baseline == front && alternative.steps.count <= 80)
        if hangingProxyDeficit || hangingConvexFailure != nil {
            blocked(hangingConvexFailure ?? "tread") { _ = try make(front,hanging) }
        }
        let toolFrame = model.frames(model.positions(vendorLeft:front))["left_tool"]!
        let payloadCenter4 = toolFrame*SIMD4<Double>(0,0,0.45,1)
        let payloadCenter = SIMD3(payloadCenter4.x,payloadCenter4.y,payloadCenter4.z)
        var payloadObstacle = map; payloadObstacle.obstacleLow = payloadCenter-SIMD3(repeating:0.015)
        payloadObstacle.obstacleHigh = payloadCenter+SIMD3(repeating:0.015)
        let stationary: [ROBLeftGestureProposal.Step] = [.init(positions:front,seconds:0.7)]
        _ = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:stationary,map:payloadObstacle,model:model,generation:generation,
            sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000)
        let payload = ROBWorkspaceCarriedObject(measurementID:"synthetic object envelope",centerInToolMeters:[0,0,0.45],halfExtentsMeters:[0.02,0.02,0.02])
        blocked("carried object") {
            _ = try ROBWorkspaceCollisionPlan.review(baseline:front,steps:stationary,map:payloadObstacle,model:model,generation:generation,
                sceneID:scene,cameraGeneration:camera,nowMilliseconds:1_000,payload:payload)
        }
        print("Table regression: old registered parking route rejected; dynamically planned alternative has \(alternative.steps.count) steps and \(alternative.checkedPoseCount) fully checked poses")
        print("Workspace collision: fresh registered free map accepted; unknown, stale, unregistered, changed scene/camera/session/map rejected; all output stays hardware-free")
    }
}
