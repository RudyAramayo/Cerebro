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

@main struct InitialEmptyRetreatFixtures {
    static func blocked(_ expected:String?=nil,_ body:()throws->Void) {
        do {try body();preconditionFailure("Unsafe initial retreat admitted")}
        catch {if let expected {precondition(error.localizedDescription.contains(expected),error.localizedDescription)}}
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
        let scene=UUID(),camera=UUID(),generation:UInt64=42,hanging=Array(repeating:0.0,count:7)
        let hash=ROBGhostRobotModel.hash(Data("initial-empty-retreat-fixture".utf8))
        var map=SyntheticMap(sceneID:scene,cameraGeneration:camera,sessionGeneration:generation,
            modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID)
        map.registrationID=nil;map.registrationUncertaintyMeters=nil
        map.visualCalibrationScope = .init(bodyMotionIdentity:"fixture",bodyContextIsCurrent:true,
            estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
        func trial(_ source:SyntheticMap,baseline:[Double]=hanging,allowance:Double=0.05)->ROBWorkspaceVisualCalibrationTrial {
            .init(receiptID:"fixture",receiptSHA256:hash,appSessionID:"fixture",command:"right_recycle_cans",canCount:4,
                summarySHA256:hash,authorizationContextIdentity:"fixture",sessionGeneration:generation,sceneID:scene,
                cameraGeneration:camera,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                mapFingerprint:source.fingerprint,bodyMotionIdentity:"fixture",estimatedCameraProjectionIdentity:hash,
                observationPoseIdentity:hash,currentPoseIdentity:hash,baseline:baseline,issuedAtMilliseconds:1000,
                expiresAtMilliseconds:2000,assumedSpatialErrorMeters:allowance)
        }
        func review(_ goal:[Double],source:SyntheticMap?=nil,start:[Double]=hanging,age:Double=0,eligible:Bool=true,
                    emptySource:String="local_first_attempt_no_arm_travel_or_task_grip") throws->ROBWorkspaceInitialEmptyRetreat {
            let m=source ?? map
            return try ROBWorkspaceCollisionPlan.reviewInitialEmptyVisualCalibrationRetreat(from:start,to:goal,map:m,
                model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(m,baseline:start),
                measuredAtMilliseconds:1000-age,emptyTrialEligibility:eligible,emptyStateEvidenceSource:emptySource)
        }
        precondition(trial(map,allowance:0.025).valid && trial(map,allowance:0.15).valid)
        precondition(!trial(map,allowance:0.0249).valid && !trial(map,allowance:0.1501).valid)
        blocked("EMPTY eligibility") {_=try review(hanging,eligible:false)}
        blocked("EMPTY eligibility") {_=try review(hanging,emptySource:"inferred_from_gripper_release_command")}
        blocked("fresh measured hanging") {_=try review(hanging,age:251)}
        var outside=hanging;outside[1]=0.201
        blocked("0.20 rad") {_=try review(outside)}
        var notHanging=hanging;notHanging[0]=0.026
        blocked("fresh measured hanging") {_=try review(notHanging,start:notHanging)}
        blocked("nonworsening retreat") {_=try review(hanging)}
        var candidates:[ROBWorkspaceInitialEmptyRetreat]=[]
        for goal in [[0.0,-0.075,0,0,0,0,0],[0.0,-0.071,0,0,0,0,0],[-0.04,-0.06,0.02,0,0,0,0]] {
            let delta=goal[1]
            do {let proof=try review(goal);candidates.append(proof);print("RIGHT J2",delta,"PASS maxHullTravel",proof.maximumHullTravelMeters,"endpoint",proof.endpointProxyClearancesMeters.values.min()!)}
            catch {print("RIGHT J2",delta,"BLOCKED",error.localizedDescription)}
        }
        guard let proof=candidates.first else {
            print("ACTUAL MODEL REMAINS BLOCKED: bounded J2/coupled candidates failed; actual depth evidence remains mandatory.")
            return
        }
        precondition(proof.step.seconds==4 && proof.step.jawAction==nil && proof.maximumHullTravelMeters<=0.06 && proof.initialEmptyStateAssumed)
        precondition(proof.endpointProxyClearancesMeters.values.allSatisfy{$0>=0.03})
        precondition(model.treadSeparation(vendorLeft:proof.goal)<0.03,
            "The actual rotated-hull fixture no longer exercises its AABB false positive")
        var narrow=ROBWorkspaceSelfProxyClearance(model:model)
        let endpointNarrow=try narrow.minimum(vendorLeft:proof.goal)
        precondition(endpointNarrow>=0.03)
        _ = try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:proof.goal,
            steps:[.init(positions:proof.goal,seconds:4)],map:map,model:model,generation:generation,
            sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map,baseline:proof.goal))
        try proof.validate(map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,
            nowMilliseconds:1001,trial:trial(map),measuredAtMilliseconds:1001,measuredBaseline:hanging,
            emptyTrialEligibility:true,emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")
        // Ordinary planning never inherits this distinct start-only proof.
        blocked("nonworsening retreat") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:hanging,
            steps:[proof.step],map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,
            nowMilliseconds:1000,trial:trial(map))}
        var unseen=map;unseen.observed=false
        blocked("unobserved") {_=try review(proof.goal,source:unseen)}
        var obstacle=map;let tool=model.worldCollisionBounds(positions:model.positions(vendorLeft:hanging))[model.toolLink]!
        obstacle.obstacleLow=tool.low;obstacle.obstacleHigh=tool.high
        blocked("obstacle") {_=try review(proof.goal,source:obstacle)}
        var wrongPose=hanging;wrongPose[0]=0.005
        blocked("fresh measured start") {try proof.validate(map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,
            nowMilliseconds:1001,trial:trial(map),measuredAtMilliseconds:1001,measuredBaseline:wrongPose,
            emptyTrialEligibility:true,emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")}
        let data=try JSONEncoder().encode(proof),decoded=try JSONDecoder().decode(ROBWorkspaceInitialEmptyRetreat.self,from:data)
        precondition(decoded==proof)
        print("PASS distinct initial-empty retreat: actual RIGHT scan model, monotonically improving pre-existing proxy deficits, >=30mm endpoint, <=60mm full-hull travel, one slow4s/no-jaw step, fresh hanging/history eligibility, map/unknown/occupied/pose rejection, ordinary lane unchanged, Codable proof")
    }
}
