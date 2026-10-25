import Foundation
import simd

private struct ContactMap:ROBWorkspaceCollisionMap {
    struct Key:Hashable {let x:Int,y:Int,z:Int}
    let sceneID=UUID(),cameraGeneration=UUID()
    let sessionGeneration:UInt64=42
    let modelID:String,geometryID:String,mappingID:String
    let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0
    let voxelSizeMeters=0.025
    var registrationID:String?="synthetic measured registration"
    var registrationUncertaintyMeters:Double?=0
    var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope? = nil
    var points:[SIMD3<Double>]=[]
    var unknown:Key?
    var sampleBoundsAvailable=true
    var observationPresent=true
    var fingerprint:String { ROBGhostRobotModel.hash(Data("\(points):\(unknown.debugDescription):\(sampleBoundsAvailable):\(observationPresent)".utf8)) }
    func key(_ point:SIMD3<Double>)->Key { .init(x:Int(floor(point.x/voxelSizeMeters)),y:Int(floor(point.y/voxelSizeMeters)),z:Int(floor(point.z/voxelSizeMeters))) }
    func state(at point:SIMD3<Double>)->ROBWorkspaceVoxelState {
        let k=key(point)
        if points.contains(where:{key($0)==k}) {return .occupied}
        return k==unknown ? .unknown : .free
    }
    func state(inBoundsLow low:SIMD3<Double>,high:SIMD3<Double>)->ROBWorkspaceVoxelState {
        let a=key(low),b=key(high)
        func includes(_ k:Key)->Bool { (a.x...b.x).contains(k.x) && (a.y...b.y).contains(k.y) && (a.z...b.z).contains(k.z) }
        if points.contains(where:{includes(key($0))}) {return .occupied}
        return unknown.map(includes) == true ? .unknown : .free
    }
    func containsTargetObservation(sequence:UInt64,capturedAtMilliseconds:Double)->Bool { observationPresent && sequence==12 && capturedAtMilliseconds==1000 }
    func occupiedSampleBounds(at point:SIMD3<Double>)->(low:SIMD3<Double>,high:SIMD3<Double>)? {
        guard sampleBoundsAvailable else {return nil}
        let inCell=points.filter {key($0)==key(point)}
        guard let first=inCell.first else {return nil}
        return (inCell.reduce(first){simd_min($0,$1)},inCell.reduce(first){simd_max($0,$1)})
    }
}

@main enum ContactFixtures {
    static func rejected(_ expected:String?=nil,_ body:()throws->Void) {
        do {try body();fatalError("Unscoped/obstructed contact was admitted")}
        catch {if let expected {precondition(error.localizedDescription.contains(expected),error.localizedDescription)}}
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
        let q=model.recyclingFrontTarget
        var map=ContactMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID)
        let axis=SIMD3<Double>(0.7125,0.1125,0.9625),surface=axis+SIMD3(0.032,0,0)
        map.points=[surface-SIMD3(repeating:0.0001),surface+SIMD3(repeating:0.0001)]
        let steps:[ROBLeftGestureProposal.Step]=[
            .init(positions:q,seconds:0.7,jawAction:.prepare),
            .init(positions:q,seconds:0.7,jawAction:.grip),
            .init(positions:q,seconds:0.7,jawAction:.release)]
        let tool=model.frames(model.positions(vendorLeft:q))[model.toolLink]!
        let local=simd_inverse(tool)*SIMD4(axis.x,axis.y,axis.z,1)
        let payload=ROBWorkspaceCarriedObject(measurementID:"measured-can-12",centerInToolMeters:[local.x,local.y,local.z],halfExtentsMeters:[0.08,0.08,0.08])
        func proof(_ map:ContactMap=map,first:Int=0,center:SIMD3<Double> = axis,release:Int?=2,terminal:Bool?=nil)->ROBWorkspaceIntentionalContact {
            .init(measurementID:payload.measurementID,observationSequence:12,capturedAtMilliseconds:1000,
                sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,mapFingerprint:map.fingerprint,
                modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,toolLink:model.toolLink,
                topCenterMeters:[center.x,center.y,center.z+0.06],bottomCenterMeters:[center.x,center.y,center.z-0.06],diameterMeters:0.066,
                firstContactStepIndex:first,gripStepIndex:1,releaseStepIndex:release,stepCount:3,terminalGraspHold:terminal)
        }
        func review(_ map:ContactMap=map,contact:ROBWorkspaceIntentionalContact?=nil,substep:Int?=nil,
            steps selected:[ROBLeftGestureProposal.Step]?=nil) throws ->ROBWorkspaceCollisionPlan {
            try .review(baseline:q,steps:selected ?? steps,map:map,model:model,generation:42,sceneID:map.sceneID,
                cameraGeneration:map.cameraGeneration,nowMilliseconds:1000,payload:payload,intentionalContact:contact,contactStepIndex:substep)
        }
        rejected("obstacle") {_=try review()}
        let contact=proof()
        let cell=map.key(surface)
        let cellCenter=SIMD3((Double(cell.x)+0.5)*0.025,(Double(cell.y)+0.5)*0.025,(Double(cell.z)+0.5)*0.025)
        precondition(!contact.containsWholeVoxel(center:cellCenter,size:0.025),"The surface-cell fixture must actually straddle the can boundary")
        precondition(contact.containsMeasuredBounds(low:map.points[0],high:map.points[1]))
        let accepted=try review(contact:contact)
        precondition(accepted.intentionalContact==contact && accepted.context.intentionalContactFingerprint==contact.fingerprint)
        try accepted.validate(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1001)
        let decoded=try JSONDecoder().decode(ROBWorkspaceCollisionPlan.self,from:JSONEncoder().encode(accepted))
        precondition(decoded==accepted)
        _=try review(contact:contact,substep:1,steps:[steps[1]])
        _=try review(contact:contact,substep:2,steps:[steps[2]])
        rejected("obstacle") {_=try review(contact:proof(first:1))}

        var conservative=map;conservative.sampleBoundsAvailable=false
        rejected("obstacle") {_=try review(conservative,contact:proof(conservative))}
        var table=map
        // Same occupied cell now contains a second observed point beyond the
        // can radius. Keeping every source point prevents clearing that return.
        table.points.append(SIMD3(0.7499,axis.y,axis.z))
        rejected("obstacle") {_=try review(table,contact:proof(table))}
        var unknown=map;unknown.unknown=unknown.key(SIMD3(0.72,0.13,0.96))
        rejected("unobserved") {_=try review(unknown,contact:proof(unknown))}
        var missing=map;missing.observationPresent=false
        rejected("recorded observation") {_=try review(missing,contact:proof(missing))}
        rejected("exact scene") {_=try review(table,contact:contact)}
        var wrongStage=contact;wrongStage=ROBWorkspaceIntentionalContact(measurementID:contact.measurementID,
            observationSequence:contact.observationSequence,capturedAtMilliseconds:contact.capturedAtMilliseconds,
            sceneID:contact.sceneID,cameraGeneration:contact.cameraGeneration,mapFingerprint:contact.mapFingerprint,
            modelID:contact.modelID,geometryID:contact.geometryID,mappingID:contact.mappingID,toolLink:"right_tool",
            topCenterMeters:contact.topCenterMeters,bottomCenterMeters:contact.bottomCenterMeters,diameterMeters:contact.diameterMeters,
            firstContactStepIndex:0,gripStepIndex:1,releaseStepIndex:2,stepCount:3)
        rejected("exact scene") {_=try review(contact:wrongStage)}
        rejected("stages") {_=try review(contact:contact,steps:[steps[0],steps[2],steps[1]])}
        rejected("index") {_=try review(contact:contact,substep:80)}
        var changed=accepted;changed.intentionalContact?.radialFitUncertaintyMeters=0.001
        rejected("changed") {try changed.validate(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1001)}

        // A typed terminal grasp hold is a different local-trial disposition,
        // not a fake release index or a measured registration.
        let holdSteps:[ROBLeftGestureProposal.Step]=[steps[0],steps[1],
            .init(positions:q,seconds:0.7,stage:"Verification lift")]
        let measuredHold=proof(release:nil,terminal:true)
        precondition(measuredHold.valid && measuredHold.releaseStepIndex == nil)
        rejected("local visual-calibration") {_=try review(contact:measuredHold,steps:holdSteps)}
        rejected("local visual-calibration") {
            _=try ROBWorkspaceCollisionPlan.make(from:q,to:q,map:map,model:model,generation:42,sceneID:map.sceneID,
                cameraGeneration:map.cameraGeneration,nowMilliseconds:1000,payload:payload,intentionalContact:measuredHold,contactStepIndex:2)
        }
        var localMap=map;localMap.registrationID=nil;localMap.registrationUncertaintyMeters=nil
        let hash=ROBGhostRobotModel.hash(Data("isolated terminal grasp hold".utf8))
        localMap.visualCalibrationScope = .init(bodyMotionIdentity:"fixture body",bodyContextIsCurrent:true,
            estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
        let trial=ROBWorkspaceVisualCalibrationTrial(receiptID:"isolated receipt",receiptSHA256:hash,appSessionID:"isolated app",
            command:"left_recycle_cans",canCount:4,summarySHA256:hash,authorizationContextIdentity:"isolated scope",
            sessionGeneration:42,sceneID:localMap.sceneID,cameraGeneration:localMap.cameraGeneration,modelID:model.modelID,
            geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:localMap.fingerprint,
            bodyMotionIdentity:"fixture body",estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,
            currentPoseIdentity:hash,baseline:q,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.035)
        let localContact=proof(localMap,release:nil,terminal:true)
        func holdReview(_ selected:[ROBLeftGestureProposal.Step]=holdSteps,substep:Int?=nil)throws->ROBWorkspaceCollisionPlan {
            try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:selected,map:localMap,model:model,generation:42,
                sceneID:localMap.sceneID,cameraGeneration:localMap.cameraGeneration,nowMilliseconds:1000,trial:trial,
                payload:payload,intentionalContact:localContact,contactStepIndex:substep)
        }
        let hold=try holdReview()
        precondition(hold.context.registrationID == nil && hold.intentionalContact?.terminalGraspHold == true)
        let holdDecoded=try JSONDecoder().decode(ROBWorkspaceCollisionPlan.self,from:JSONEncoder().encode(hold))
        precondition(holdDecoded == hold && holdDecoded.intentionalContact?.releaseStepIndex == nil)
        _=try holdReview([holdSteps[2]],substep:2)
        rejected("registration") {try holdDecoded.validate(map:localMap,model:model,generation:42,sceneID:localMap.sceneID,
            cameraGeneration:localMap.cameraGeneration,nowMilliseconds:1000)}
        rejected("without a carry or release") {_=try holdReview(steps)}
        rejected("verification lift") {_=try holdReview([steps[0],steps[1],.init(positions:q,seconds:0.7,stage:"Carry")])}
        rejected("cannot release") {_=try holdReview([steps[2]],substep:2)}
        precondition(!proof(localMap,release:nil).valid && !proof(localMap,terminal:true).valid)
        precondition(!localContact.permits(label:model.toolLink,payload:nil,stepIndex:3))
        precondition(localContact.permits(label:"carried object",payload:payload,stepIndex:2))
        // Legacy complete-contact archives still encode numeric release and
        // omit the new optional flag, preserving their exact fingerprint.
        let legacyJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(contact)) as! [String:Any]
        precondition(legacyJSON["releaseStepIndex"] as? Int == 2 && legacyJSON["terminalGraspHold"] == nil)
        print("Terminal grasp hold: explicit local trial only, nil release, final verification lift, immutable roundtrip; ordinary/connector/imported authority and carry/release substitutions rejected")

        // An occupied return on another articulated link stays blocked even if
        // a malformed task chooses that location as its claimed can cylinder.
        var elbow=map;let other=SIMD3<Double>(0.18,0.24,0.96);elbow.points=[other]
        rejected("left_") {_=try review(elbow,contact:proof(elbow,center:other))}
        print("Intentional contact fixtures passed: exact target/map/observation/stage, raw surface bounds, shared-cell obstruction, unknown, other links, unchanged safety, immutable proof, serialization")
    }
}
