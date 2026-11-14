import Foundation
import simd

private struct AttachmentMap:ROBWorkspaceCollisionMap {
    let sceneID=UUID(),cameraGeneration=UUID(),sessionGeneration:UInt64=42
    let modelID:String,geometryID:String,mappingID:String
    let createdAtMilliseconds=950.0,oldestCapturedAtMilliseconds=900.0,lastCapturedAtMilliseconds=950.0,voxelSizeMeters=0.025
    let registrationID:String?=nil,registrationUncertaintyMeters:Double?=nil
    var body="stationary actual fixture body",changed=false
    var fingerprint:String {ROBGhostRobotModel.hash(Data("source-map-\(changed)".utf8))}
    var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope? {
        .init(bodyMotionIdentity:body,bodyContextIsCurrent:!changed,estimatedCameraProjectionIdentity:String(repeating:"a",count:64),
            observationPoseIdentity:String(repeating:"b",count:64),observedFrameCount:2)
    }
    func state(at point:SIMD3<Double>)->ROBWorkspaceVoxelState {.free}
    func containsTargetObservation(sequence:UInt64,capturedAtMilliseconds:Double)->Bool {sequence==1 && capturedAtMilliseconds==900}
}

@main @MainActor enum NativeAttachmentFixtures {
    static func rejected(_ operation:()throws->Void) {
        do {try operation();preconditionFailure("Invalid native attachment admitted")}catch{}
    }
    static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"left")
        let map=AttachmentMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID)
        let payload=ROBWorkspaceCarriedObject(measurementID:"source-can1",centerInToolMeters:[0.015,0,0.01],halfExtentsMeters:[0.063,0.036,0.036])
        let initial=model.positions(vendorLeft:model.recyclingFrontTarget),point=model.toolPosition(initial)!
        var can=ROBWorkspaceLocatedObject(target:.can,position:[point.x,point.y,point.z],confidence:0.95,capturedAt:900,sequence:1,view:.init(panDegrees:0,upperTarget:6306))
        can.sections = .init(top:[point.x,point.y,point.z+0.06],middle:[point.x,point.y,point.z],bottom:[point.x,point.y,point.z-0.06],heightMeters:0.12,diameterMeters:0.066)
        let grab=try ROBCanGrabPreview.make(can:can,model:model,baseline:initial,side:"left",now:1300)
        precondition(grab.reachesCan)
        let held=grab.steps.last!.pose,q=model.vendorLeft(held)
        let context=ROBNativeCanAttachment.Context(appSessionID:UUID(),taskID:UUID(),ownershipID:UUID(),physicalArm:"left",bodyMotionIdentity:map.body,
            gatewayGeneration:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,modelID:model.modelID,referenceID:model.referenceID,
            geometryID:model.geometryID,mappingID:model.selectedMappingID,fixedViewIdentity:"native fixed source/body/neck",targetIdentity:"can-1-native-fixture",sourceIdentity:String(repeating:"c",count:64))
        func feedback(_ positions:[Double]=q,sequence:UInt64=900,time:Double=1300,age:Double=1,stationary:Bool=true)->ROBNativeCanAttachment.HeldFeedback {
            .init(physicalArm:"left",gatewayGeneration:42,sequence:sequence,capturedAtMilliseconds:time,positions:positions,
                motorAgeMilliseconds:age,gripperAgeMilliseconds:age,jointModes:Array(repeating:2,count:7),gatewayModes:Array(repeating:2,count:7),stationary:stationary)
        }
        let source=ROBWorkspaceIntentionalContact(measurementID:payload.measurementID,observationSequence:1,capturedAtMilliseconds:900,
            sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,mapFingerprint:map.fingerprint,modelID:model.modelID,geometryID:model.geometryID,
            mappingID:model.selectedMappingID,toolLink:model.toolLink,topCenterMeters:can.sections!.top,bottomCenterMeters:can.sections!.bottom,
            diameterMeters:0.066,firstContactStepIndex:0,gripStepIndex:1,releaseStepIndex:nil,stepCount:3,terminalGraspHold:true)
        var seed:UInt64=18397
        func noise(_ count:Int)->[UInt8] {(0..<count).map{_ in seed=seed &* 6364136223846793005 &+ 1442695040888963407;return UInt8(40+Int((seed>>32)%160))}}
        let background=noise(160*120),texture=noise(32*36)
        func pixels(sequence:UInt64,time:Double,moved:Bool)->ROBVisualGraspVerifier.ObservedJawInput {
            let dx=moved ? 12:0,dy=moved ? -8:0;var gray=background,depth=Array(repeating:Float(1.5),count:160*120)
            for y in 0..<36 {for x in 0..<32 {let i=(48+dy+y)*160+64+dx+x;gray[i]=texture[y*32+x];depth[i]=moved ? 0.725:0.75}}
            for x0 in [36,124] {for y in -2...2 {for x in -2...2 {depth[(70+dy+y)*160+x0+dx+x]=moved ? 0.675:0.7}}}
            return .init(sequence:sequence,capturedAtMilliseconds:time,cameraGeneration:map.cameraGeneration,fixedViewIdentity:context.fixedViewIdentity,
                targetIdentity:context.targetIdentity,sourceIdentity:context.sourceIdentity,width:160,height:120,gray:gray,depthMeters:depth,fx:500,fy:500,cx:80,cy:60,
                synchronizedRGBDepth:true,handsClear:true,jawCenterPixels:.init(x:80+Double(dx),y:72+Double(dy)),
                fingerTipsPixels:[.init(x:40+Double(dx),y:70+Double(dy)),.init(x:120+Double(dx),y:70+Double(dy))],
                jawSequence:sequence,jawCapturedAtMilliseconds:time,jawScopeIdentity:context.fixedViewIdentity,jawConfidence:0.9,
                jawEvidenceKind:"image_observed_opening_after_release_command_then_temporal_edges",
                canBox:.init(left:(64+Double(dx))/160,top:(48+Double(dy))/120,right:(96+Double(dx))/160,bottom:(84+Double(dy))/120))
        }
        func support()throws->ROBVisualGraspVerifier.ObservedSupport {
            let before=pixels(sequence:10,time:1000,moved:false)
            let appearance=ROBVisualGraspVerifier.AppearanceSeed(sequence:2,capturedAtMilliseconds:950,cameraGeneration:map.cameraGeneration,
                fixedViewIdentity:context.fixedViewIdentity,targetIdentity:context.targetIdentity,sourceIdentity:context.sourceIdentity,
                width:160,height:120,gray:before.gray,canBox:before.canBox,synchronizedRGBDepth:true,handsClear:true)
            var verifier=try ROBVisualGraspVerifier.ObservedJawVerifier(baseline:before,appearance:appearance,nowMilliseconds:1000)
            precondition(verifier.nativeSupportedObservation==nil)
            for i in 1...3 {
                let result=try verifier.observe(pixels(sequence:UInt64(10+i),time:1000+Double(i)*100,moved:true),nowMilliseconds:1000+Double(i)*100)
                precondition(result.verdict == (i==3 ? .supported:.collecting))
            }
            let actual=verifier.nativeSupportedObservation!
            precondition(actual === verifier.nativeSupportedObservation!)
            return actual
        }
        func create(_ actual:ROBVisualGraspVerifier.ObservedSupport?=nil,box:ROBWorkspaceCarriedObject?=nil,
                    sample:ROBNativeCanAttachment.HeldFeedback?=nil,sourceMap:AttachmentMap?=nil,time:Double=1300)throws->ROBNativeCanAttachment {
            try .create(support:actual ?? support(),sourceContact:source,payload:box ?? payload,context:context,map:sourceMap ?? map,
                model:model,baseline:sample ?? feedback(),nowMilliseconds:time)
        }
        rejected{_=try create(sample:feedback(age:251))}
        rejected{_=try create(sample:feedback(stationary:false))}
        rejected{_=try create(time:2201)}
        let tiny=ROBWorkspaceCarriedObject(measurementID:payload.measurementID,centerInToolMeters:[0,0,0],halfExtentsMeters:[0.005,0.005,0.005])
        rejected{_=try create(box:tiny)}
        var changed=map;changed.changed=true;rejected{_=try create(sourceMap:changed)}
        let actual=try support(),native=try create(actual)
        rejected{_=try create(actual)}
        precondition(native.record.sourceContactFingerprint==source.fingerprint && native.record.sourceCylinderFingerprint==source.sourceCylinderFingerprint &&
            native.record.payloadFingerprint==payload.fingerprint && native.record.baselineTelemetrySequence==900 && native.record.baselineCapturedAtMilliseconds==1300)
        precondition(native.sourceContact.capturedAtMilliseconds==900 && native.record.verificationCapturedAtMilliseconds==1300)
        let decoded=try JSONDecoder().decode(ROBWorkspaceVerifiedAttachedCan.self,from:JSONEncoder().encode(native.record))
        precondition(decoded==native.record) // Metadata roundtrip creates NO native token/support.
        let f=model.frames(held)[model.toolLink]!,c=f*SIMD4<Double>(0.015,0,0.01,1)
        let bucket=ROBWorkspaceLocatedObject(target:.orangeBucket,position:[c.x,c.y+0.04,c.z-0.2],confidence:0.95,capturedAt:1300,sequence:20,view:can.view,openingRadius:0.14)
        let carry=try ROBCanCarryPreview.make(from:held,can:can,attachedPayload:payload,destination:bucket,model:model,side:"left",now:1300,dropUncertaintyMeters:0.035)
        var steps:[ROBLeftGestureProposal.Step]=[],previous=q
        for step in carry.steps {
            let goal=model.vendorLeft(step.pose),duration=max(step.seconds,ROBLeftArmInteractionPlan.duration(from:previous,to:goal,padding:0.002)!)
            steps.append(.init(positions:goal,seconds:duration,jawAction:step.jawAction,stage:step.stage));previous=goal
        }
        let attached=ROBWorkspaceIntentionalContact(measurementID:source.measurementID,observationSequence:source.observationSequence,
            capturedAtMilliseconds:source.capturedAtMilliseconds,sceneID:source.sceneID,cameraGeneration:source.cameraGeneration,mapFingerprint:source.mapFingerprint,
            modelID:source.modelID,geometryID:source.geometryID,mappingID:source.mappingID,toolLink:source.toolLink,
            topCenterMeters:source.topCenterMeters,bottomCenterMeters:source.bottomCenterMeters,diameterMeters:source.diameterMeters,
            firstContactStepIndex:0,gripStepIndex:nil,releaseStepIndex:carry.releaseIndex,stepCount:steps.count,verifiedAttachment:native.record)
        func trial(_ baseline:[Double])->ROBWorkspaceVisualCalibrationTrial {
            .init(receiptID:"synthetic native receipt",receiptSHA256:String(repeating:"d",count:64),appSessionID:context.appSessionID.uuidString,
                command:"left_recycle_cans",canCount:1,summarySHA256:String(repeating:"e",count:64),authorizationContextIdentity:"synthetic current context",
                sessionGeneration:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                mapFingerprint:map.fingerprint,bodyMotionIdentity:map.body,estimatedCameraProjectionIdentity:String(repeating:"a",count:64),
                observationPoseIdentity:String(repeating:"b",count:64),currentPoseIdentity:String(repeating:"f",count:64),baseline:baseline,
                issuedAtMilliseconds:900,expiresAtMilliseconds:10000,assumedSpatialErrorMeters:0.035)
        }
        let route=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:steps,map:map,model:model,generation:42,sceneID:map.sceneID,
            cameraGeneration:map.cameraGeneration,nowMilliseconds:1300,trial:trial(q),payload:payload,intentionalContact:attached,carryingAtStart:true)
        let proposal=try ROBLeftGestureCompiler.compile(kind:"recycling_carry_release",name:"Actual immutable carry fixture",poses:[],model:model,baseline:q,generation:42,
            workspaceCollisionPlan:route,collisionMap:map,collisionSceneID:map.sceneID,collisionCameraGeneration:map.cameraGeneration,
            visualCalibrationTrial:trial(q),verifiedAttachment:native.record,nowMilliseconds:1300)
        try native.bind(proposal:proposal,currentContext:context,map:map,model:model,feedback:feedback(),nowMilliseconds:1300)
        rejected{try native.bind(proposal:proposal,currentContext:context,map:map,model:model,feedback:feedback(),nowMilliseconds:1300)}
        func segment(_ index:Int,_ position:[Double],now:Double,carrying:Bool=true)throws->ROBWorkspaceCollisionPlan {
            try .reviewVisualCalibrationTrial(baseline:position,steps:[steps[index]],map:map,model:model,generation:42,sceneID:map.sceneID,
                cameraGeneration:map.cameraGeneration,nowMilliseconds:now,trial:trial(position),payload:payload,intentionalContact:attached,contactStepIndex:index,carryingAtStart:carrying)
        }
        let one=try segment(0,q,now:1300)
        let ticket=try native.prepareDispatch(index:0,segmentProof:one,currentContext:context,map:map,model:model,feedback:feedback(),nowMilliseconds:1300,nowUptime:10)
        precondition(!native.matchesAndConsumeDispatch(ticket,proposalID:proposal.id,proposalSHA256:"wrong",index:0,seconds:steps[0].seconds,currentContext:context,
            map:map,model:model,feedback:feedback(),nowMilliseconds:1300,nowUptime:10))
        precondition(native.matchesAndConsumeDispatch(ticket,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,index:0,seconds:steps[0].seconds,currentContext:context,
            map:map,model:model,feedback:feedback(),nowMilliseconds:1300,nowUptime:10.1))
        precondition(!native.matchesAndConsumeDispatch(ticket,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,index:0,seconds:steps[0].seconds,currentContext:context,
            map:map,model:model,feedback:feedback(),nowMilliseconds:1300,nowUptime:10.1))
        rejected{_=try native.prepareDispatch(index:1,segmentProof:segment(1,q,now:1300),currentContext:context,map:map,model:model,feedback:feedback(),nowMilliseconds:1300,nowUptime:10.2)}
        let second=try native.prepareDispatch(index:1,segmentProof:segment(1,q,now:1300),currentContext:context,map:map,model:model,feedback:feedback(sequence:901),nowMilliseconds:1300,nowUptime:11)
        precondition(!native.matchesAndConsumeDispatch(second,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,index:1,seconds:steps[1].seconds,currentContext:context,
            map:map,model:model,feedback:feedback(sequence:901),nowMilliseconds:1300,nowUptime:11.3))
        var drifted=q;drifted[0]+=0.003
        precondition(!native.matchesAndConsumeDispatch(second,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,index:1,seconds:steps[1].seconds,currentContext:context,
            map:map,model:model,feedback:feedback(drifted,sequence:901),nowMilliseconds:1300,nowUptime:11.1))
        precondition(native.matchesAndConsumeDispatch(second,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,index:1,seconds:steps[1].seconds,currentContext:context,
            map:map,model:model,feedback:feedback(sequence:901),nowMilliseconds:1300,nowUptime:11.1))
        let release=carry.releaseIndex
        rejected{_=try native.prepareReleaseCommand(segmentProof:segment(release,steps[release].positions,now:1300),currentContext:context,
            map:map,model:model,feedback:feedback(steps[release].positions,sequence:999),nowMilliseconds:1300,nowUptime:12)}
        for i in 2...release {
            let start=steps[i-1].positions,sample=feedback(start,sequence:UInt64(900+i))
            let admitted=try native.prepareDispatch(index:i,segmentProof:segment(i,start,now:1300),currentContext:context,
                map:map,model:model,feedback:sample,nowMilliseconds:1300,nowUptime:Double(20+i))
            precondition(native.matchesAndConsumeDispatch(admitted,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,index:i,seconds:steps[i].seconds,
                currentContext:context,map:map,model:model,feedback:sample,nowMilliseconds:1300,nowUptime:Double(20+i)+0.1))
        }
        precondition(native.awaitingReleaseCommand && native.invalidatedReason==nil,"Waypoint arrival must not pretend the actual jaw command occurred")
        let releasePose=steps[release].positions,releaseFeedback=feedback(releasePose,sequence:UInt64(901+release))
        rejected{_=try native.prepareDispatch(index:release+1,segmentProof:segment(release+1,releasePose,now:1300,carrying:false),currentContext:context,
            map:map,model:model,feedback:releaseFeedback,nowMilliseconds:1300,nowUptime:100)}
        let jaw=try native.prepareReleaseCommand(segmentProof:segment(release,releasePose,now:1300),currentContext:context,
            map:map,model:model,feedback:releaseFeedback,nowMilliseconds:1300,nowUptime:100)
        precondition(!native.matchesAndConsumeDispatch(jaw,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,index:release,seconds:steps[release].seconds,
            currentContext:context,map:map,model:model,feedback:releaseFeedback,nowMilliseconds:1300,nowUptime:100.1))
        precondition(native.matchesAndConsumeReleaseCommand(jaw,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,currentContext:context,
            map:map,model:model,feedback:releaseFeedback,nowMilliseconds:1300,nowUptime:100.1))
        precondition(native.invalidatedReason != nil && !native.awaitingReleaseCommand,"Actual release admission consumes attachment before dispatch without inferring EMPTY")
        precondition(!native.matchesAndConsumeReleaseCommand(jaw,proposalID:proposal.id,proposalSHA256:proposal.fingerprint,currentContext:context,
            map:map,model:model,feedback:releaseFeedback,nowMilliseconds:1300,nowUptime:100.1))
        let stopped=try create();stopped.invalidate(reason:"Synthetic Stop")
        rejected{try stopped.bind(proposal:proposal,currentContext:context,map:map,model:model,feedback:feedback(),nowMilliseconds:1300)}
        let otherOwner=ROBNativeCanAttachment.Context(appSessionID:context.appSessionID,taskID:context.taskID,ownershipID:UUID(),physicalArm:context.physicalArm,
            bodyMotionIdentity:context.bodyMotionIdentity,gatewayGeneration:context.gatewayGeneration,sceneID:context.sceneID,cameraGeneration:context.cameraGeneration,
            modelID:context.modelID,referenceID:context.referenceID,geometryID:context.geometryID,mappingID:context.mappingID,
            fixedViewIdentity:context.fixedViewIdentity,targetIdentity:context.targetIdentity,sourceIdentity:context.sourceIdentity)
        let changedOwner=try create()
        rejected{try changedOwner.bind(proposal:proposal,currentContext:otherOwner,map:map,model:model,feedback:feedback(),nowMilliseconds:1300)}
        precondition(changedOwner.invalidatedReason != nil)
        print("PASS memory-only native attachment: actual observed-support mint/oneclaim, source/time/payload/body/map/feedback lineage, compiled protected route, fresh sequential one-shot dispatch, separate settled release-waypoint/jaw consumption, no empty-retreat assumption, drift/expiry/replay/Stop/owner rejection; no hardware/grant/restore API")
    }
}
