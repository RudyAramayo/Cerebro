import Foundation
import simd

private struct AdvisoryMap:ROBWorkspaceCollisionMap {
    let sceneID:UUID,cameraGeneration:UUID,sessionGeneration:UInt64
    let modelID:String,geometryID:String,mappingID:String
    let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0
    let voxelSizeMeters=0.025
    var registrationID:String?=nil
    let registrationUncertaintyMeters:Double?=nil
    var point:SIMD3<Double>?=nil
    var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope?
    var fingerprint:String {ROBGhostRobotModel.hash(Data("unknown-advisory-fixture:\(point.debugDescription)".utf8))}
    func cell(_ p:SIMD3<Double>)->[Int] {(0..<3).map{Int(floor(p[$0]/voxelSizeMeters))}}
    func state(at p:SIMD3<Double>)->ROBWorkspaceVoxelState {
        if let point,cell(point)==cell(p){return .occupied}
        return .unknown
    }
    // Deliberately return UNKNOWN even for mixed occupied/unknown volumes.
    // The advisory path must still inspect every actual occupied cell.
    func state(inBoundsLow:SIMD3<Double>,high:SIMD3<Double>)->ROBWorkspaceVoxelState {.unknown}
    func occupiedSampleBounds(at p:SIMD3<Double>)->(low:SIMD3<Double>,high:SIMD3<Double>)? {
        guard let point,cell(point)==cell(p) else{return nil};return(point,point)
    }
    func occupiedSampleSubBounds(at p:SIMD3<Double>)->[ROBWorkspaceOccupiedReturnBounds]? {
        guard let b=occupiedSampleBounds(at:p) else{return nil}
        return [.init(lowMeters:[b.low.x,b.low.y,b.low.z],highMeters:[b.high.x,b.high.y,b.high.z])]
    }
}

@main enum UnknownApproachFixtures {
    static func blocked(_ expected:String,_ body:()throws->Void) {
        do {try body();preconditionFailure("Unsafe unknown advisory admission")}
        catch {precondition(error.localizedDescription.contains(expected),error.localizedDescription)}
    }
    static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),directory=root.appendingPathComponent("Cerebro/Resources/ShadowPlanner")
        let model=try ROBGhostRobotModel(directory:directory,physicalSide:"right")
        let hash=String(repeating:"a",count:64),scene=UUID(),camera=UUID(),generation:UInt64=42
        let start=Array(repeating:0.0,count:7),safe=[0.0,-0.075,0,0,0,0,0]
        var map=AdvisoryMap(sceneID:scene,cameraGeneration:camera,sessionGeneration:generation,
            modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            visualCalibrationScope:.init(bodyMotionIdentity:"fixture",bodyContextIsCurrent:true,
                estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2))
        func trial(_ source:AdvisoryMap,_ q:[Double]=start,_ enabled:Bool?=nil,
            command:String="right_recycle_cans",receipt:String=hash)->ROBWorkspaceVisualCalibrationTrial {
            .init(receiptID:"fixture",receiptSHA256:receipt,appSessionID:"fixture",command:command,canCount:5,
                summarySHA256:hash,authorizationContextIdentity:"fixture",sessionGeneration:generation,sceneID:scene,
                cameraGeneration:camera,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                mapFingerprint:source.fingerprint,bodyMotionIdentity:"fixture",estimatedCameraProjectionIdentity:hash,
                observationPoseIdentity:hash,currentPoseIdentity:hash,baseline:q,issuedAtMilliseconds:1000,
                expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.05,operatorClearedUnknownApproach:enabled)
        }
        func initial(_ permit:ROBWorkspaceVisualCalibrationTrial,_ source:AdvisoryMap=map)throws->ROBWorkspaceInitialEmptyRetreat {
            try ROBWorkspaceCollisionPlan.reviewInitialEmptyVisualCalibrationRetreat(from:start,to:safe,map:source,model:model,
                generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:permit,
                measuredAtMilliseconds:1000,emptyTrialEligibility:true,emptyStateEvidenceSource:"operator_declared_empty")
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let legacy=trial(map),encodedLegacy=try encoder.encode(legacy)
        let legacyObject=try JSONSerialization.jsonObject(with:encodedLegacy)as![String:Any]
        precondition(legacyObject["operatorClearedUnknownApproach"]==nil,"OFF changed legacy archive keys")
        blocked("unobserved") {_=try initial(legacy)}
        let enabled=trial(map,start,true)
        #if DEBUG
        precondition(enabled.valid && enabled.usesOperatorClearedUnknownApproach)
        let encodedEnabled=try encoder.encode(enabled)
        precondition(encodedEnabled != encodedLegacy,"Immutable advisory flag was absent from hash input")
        precondition(!trial(map,start,true,command:"left_recycle_cans").valid)
        blocked("scope") {_=try initial(trial(map,start,true,receipt:"not-a-hash"))}
        let proof=try initial(enabled)
        precondition(proof.step.seconds==4 && proof.maximumHullTravelMeters<=0.06 && proof.step.jawAction==nil)
        precondition(proof.endpointProxyClearancesMeters.values.allSatisfy{$0>=0.03})
        guard let audit=proof.context.unknownSpaceAdvisory else{preconditionFailure("Missing initial advisory audit")}
        precondition(audit.broadPhaseUnknownCellVisits>0 && audit.exampleQueries.count<=16 &&
            !audit.observedFreeInferred && !audit.occupiedFilteringChanged)
        precondition(map.state(at:SIMD3(0,0,0)) == .unknown,"Advisory rewrote unknown as free")
        blocked("changed") {try proof.validate(map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,
            nowMilliseconds:1001,trial:legacy,measuredAtMilliseconds:1001,measuredBaseline:start,
            emptyTrialEligibility:true,emptyStateEvidenceSource:"operator_declared_empty")}
        let safeTrial=trial(map,safe,true)
        let connector=try ROBWorkspaceCollisionPlan.makeVisualCalibrationTrial(from:safe,to:safe,map:map,model:model,
            generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:safeTrial)
        precondition(connector.context.unknownSpaceAdvisory?.broadPhaseUnknownCellVisits ?? 0 > 0,
            "Generic connector lost its actual-route advisory audit")
        try connector.validateVisualCalibrationTrial(map:map,model:model,generation:generation,sceneID:scene,
            cameraGeneration:camera,nowMilliseconds:1001,trial:safeTrial)
        for action in [ROBLeftGestureProposal.JawAction.grip,.release] {
            blocked("EMPTY open-jaw") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:safe,
                steps:[.init(positions:safe,seconds:0.8,jawAction:action)],map:map,model:model,generation:generation,
                sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:safeTrial)}
        }
        let payload=ROBWorkspaceCarriedObject(measurementID:"fixture",centerInToolMeters:[0,0,0],halfExtentsMeters:[0.03,0.03,0.06])
        blocked("EMPTY open-jaw") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:safe,
            steps:[.init(positions:safe,seconds:0.8)],map:map,model:model,generation:generation,sceneID:scene,
            cameraGeneration:camera,nowMilliseconds:1000,trial:safeTrial,payload:payload,carryingAtStart:true)}
        let frame=model.frames(model.positions(vendorLeft:safe))["right_five_Link"]!
        let hull=try ROBEstimatedConvexHull(text:String(contentsOf:directory.appendingPathComponent(model.hulls["right_five_Link"]!),encoding:.utf8))
        let local=hull.vertices.reduce(SIMD3<Double>.zero,+)/Double(hull.vertices.count),world=frame*SIMD4(local,1)
        map.point=SIMD3(world.x,world.y,world.z)
        let obstacleTrial=trial(map,safe,true)
        blocked("observed workspace obstacle") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:safe,
            steps:[.init(positions:safe,seconds:0.8)],map:map,model:model,generation:generation,sceneID:scene,
            cameraGeneration:camera,nowMilliseconds:1000,trial:obstacleTrial)}
        precondition(map.state(at:map.point!) == .occupied && map.occupiedSampleSubBounds(at:map.point!)?.count==1)
        // Force the production unavailable-convex fallback in an isolated copy.
        // Its broad provider says UNKNOWN first; the later occupied cell must veto.
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at:directory,to:temporary);defer{try? FileManager.default.removeItem(at:temporary)}
        let fallback=try ROBGhostRobotModel(directory:temporary,physicalSide:"right")
        try Data("unavailable hull".utf8).write(to:temporary.appendingPathComponent(fallback.hulls["right_five_Link"]!))
        blocked("observed workspace obstacle") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:safe,
            steps:[.init(positions:safe,seconds:0.8)],map:map,model:fallback,generation:generation,sceneID:scene,
            cameraGeneration:camera,nowMilliseconds:1000,trial:obstacleTrial)}
        print("PASS DEBUG unknown-advisory approach: initial4s/60mm/self endpoint, generic-route audit/revalidation, unchanged UNKNOWN/raw subgroup, occupied-behind-UNKNOWN fallback veto, receipt/flag/left/grip/release/payload negatives; no native authority or actuators")
        #else
        precondition(!enabled.valid && !enabled.usesOperatorClearedUnknownApproach)
        blocked("scope") {_=try initial(enabled)}
        print("PASS nonDEBUG: UNKNOWN advisory flag unavailable; default legacy UNKNOWN veto/archive unchanged")
        #endif
    }
}
