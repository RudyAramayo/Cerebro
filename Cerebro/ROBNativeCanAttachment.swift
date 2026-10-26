import Foundation

/// Memory-only provenance for one native, visually supported attached can.
/// No actuator/grant API and no Codable conformance. The serialized record is
/// compiler evidence ONLY; decoding it cannot reconstruct this native object.
@MainActor final class ROBNativeCanAttachment {
    struct Context:Equatable {
        let appSessionID:UUID,taskID:UUID,ownershipID:UUID
        let physicalArm:String,bodyMotionIdentity:String
        let gatewayGeneration:UInt64,sceneID:UUID,cameraGeneration:UUID
        let modelID:String,referenceID:String,geometryID:String,mappingID:String
        let fixedViewIdentity:String,targetIdentity:String,sourceIdentity:String
    }
    struct HeldFeedback {
        let physicalArm:String,gatewayGeneration:UInt64,sequence:UInt64
        let capturedAtMilliseconds:Double,positions:[Double]
        let motorAgeMilliseconds:Double,gripperAgeMilliseconds:Double
        let jointModes:[Int],gatewayModes:[Int]
        let stationary:Bool
        fileprivate func valid(_ context:Context,now:Double)->Bool {
            physicalArm==context.physicalArm && gatewayGeneration==context.gatewayGeneration && sequence>0 &&
            positions.count==7 && positions.allSatisfy(\.isFinite) && stationary &&
            capturedAtMilliseconds.isFinite && (0...150).contains(now-capturedAtMilliseconds) &&
            motorAgeMilliseconds.isFinite && (0...150).contains(motorAgeMilliseconds) &&
            gripperAgeMilliseconds.isFinite && (0...250).contains(gripperAgeMilliseconds) &&
            jointModes.count==7 && jointModes.allSatisfy{$0==2} && gatewayModes==jointModes
        }
    }
    final class DispatchTicket {
        fileprivate enum Kind {case waypoint,releaseCommand}
        fileprivate let kind:Kind
        fileprivate let index:Int,proposalID:UUID,proposalSHA256:String,seconds:Double
        fileprivate let positions:[Double],sequence:UInt64,preparedAtUptime:Double
        fileprivate init(index:Int,proposal:ROBLeftGestureProposal,feedback:HeldFeedback,uptime:Double,kind:Kind = .waypoint) {
            self.kind=kind;self.index=index;proposalID=proposal.id;proposalSHA256=proposal.fingerprint;seconds=proposal.steps[index].seconds
            positions=feedback.positions;sequence=feedback.sequence;preparedAtUptime=uptime
        }
    }
    let record:ROBWorkspaceVerifiedAttachedCan
    let visualEvidence:ROBVisualGraspVerifier.Evidence
    let sourceContact:ROBWorkspaceIntentionalContact
    let payload:ROBWorkspaceCarriedObject
    let context:Context
    private(set) var invalidatedReason:String?
    private(set) var awaitingReleaseCommand=false
    private var proposal:ROBLeftGestureProposal?
    private var nextIndex=0
    private var lastConsumedSequence:UInt64
    private var pendingTicket:DispatchTicket?

    private init(record:ROBWorkspaceVerifiedAttachedCan,evidence:ROBVisualGraspVerifier.Evidence,
        contact:ROBWorkspaceIntentionalContact,payload:ROBWorkspaceCarriedObject,context:Context) {
        self.record=record;visualEvidence=evidence;sourceContact=contact;self.payload=payload;self.context=context
        lastConsumedSequence=record.baselineTelemetrySequence
    }
    static func create(support:ROBVisualGraspVerifier.ObservedSupport,sourceContact:ROBWorkspaceIntentionalContact,
        payload:ROBWorkspaceCarriedObject,context:Context,map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,
        baseline:HeldFeedback,nowMilliseconds:Double)throws->ROBNativeCanAttachment {
        let evidence=support.evidence
        guard nowMilliseconds.isFinite,evidence.verdict == .supported,evidence.samples>=3,
              evidence.toolEvidenceSource=="independent_observed_fingers",support.sourceIdentity==context.sourceIdentity,
              context.sourceIdentity.utf8.count==64,context.sourceIdentity.allSatisfy({$0.isHexDigit && !$0.isUppercase}),!context.bodyMotionIdentity.isEmpty,
              let appearance=evidence.appearanceReferenceSequence,appearance>0,appearance<evidence.firstSequence,
              let appearanceTime=evidence.appearanceReferenceCapturedAtMilliseconds,appearanceTime.isFinite,
              appearanceTime<evidence.baselineCapturedAtMilliseconds,
              (0...30_000).contains(evidence.baselineCapturedAtMilliseconds-appearanceTime),
              evidence.firstSequence>0,evidence.lastSequence>evidence.firstSequence,
              evidence.lastCapturedAtMilliseconds>evidence.baselineCapturedAtMilliseconds,
              (0...800).contains(nowMilliseconds-evidence.lastCapturedAtMilliseconds),
              evidence.cameraGeneration==context.cameraGeneration,evidence.fixedViewIdentity==context.fixedViewIdentity,
              evidence.targetIdentity==context.targetIdentity,baseline.valid(context,now:nowMilliseconds),
              baseline.capturedAtMilliseconds>=evidence.lastCapturedAtMilliseconds-150,
              baseline.positions.count==7,zip(baseline.positions,ROBWorkspaceCollisionPlan.jointBounds(model:model)).allSatisfy({$1.contains($0)}),
              payload.valid,sourceContact.verifiedAttachment==nil,sourceContact.gripStepIndex != nil,
              sourceContact.measurementID==payload.measurementID,sourceContact.valid,
              sourceContact.observationSequence<=appearance,sourceContact.capturedAtMilliseconds<=appearanceTime,
              context.targetIdentity.hasPrefix("can-\(sourceContact.observationSequence)-"),
              sourceContact.capturedAtMilliseconds<=evidence.baselineCapturedAtMilliseconds,
              sourceContact.mapFingerprint==map.fingerprint,sourceContact.sceneID==context.sceneID,
              sourceContact.cameraGeneration==context.cameraGeneration,
              sourceContact.modelID==context.modelID,sourceContact.geometryID==context.geometryID,sourceContact.mappingID==context.mappingID,
              context.physicalArm==model.physicalSide,context.modelID==model.modelID,context.referenceID==model.referenceID,
              context.geometryID==model.geometryID,context.mappingID==model.selectedMappingID,
              context.gatewayGeneration==map.sessionGeneration,context.sceneID==map.sceneID,context.cameraGeneration==map.cameraGeneration,
              let scope=map.visualCalibrationScope,scope.bodyContextIsCurrent,scope.bodyMotionIdentity==context.bodyMotionIdentity else {
            throw ROBGhostMotionError.blocked("Native attachment requires actual independent supported can/finger evidence, original source contact and fresh held feedback in the exact live task/body/map/model context.")
        }
        let radius=sourceContact.diameterMeters/2
        let height=sqrt(zip(sourceContact.topCenterMeters,sourceContact.bottomCenterMeters).reduce(0.0){$0+pow($1.0-$1.1,2)})
        guard payload.halfExtentsMeters.allSatisfy({$0+1e-9>=radius}),
              sqrt(payload.halfExtentsMeters.reduce(0.0){$0+$1*$1})+1e-9>=height/2 else {
            throw ROBGhostMotionError.blocked("The frozen native payload envelope is too small for the original can cylinder.")
        }
        try sourceContact.validate(map:map,model:model,nowMilliseconds:nowMilliseconds)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let record=ROBWorkspaceVerifiedAttachedCan(nativePhaseID:UUID(),nativeVisualEvidenceSHA256:ROBGhostRobotModel.hash(try encoder.encode(evidence)),
            sourceContactFingerprint:sourceContact.fingerprint,sourceCylinderFingerprint:sourceContact.sourceCylinderFingerprint,
            sourceMapFingerprint:sourceContact.mapFingerprint,payloadFingerprint:payload.fingerprint,
            bodyMotionIdentity:context.bodyMotionIdentity,sessionGeneration:context.gatewayGeneration,
            verificationFirstSequence:evidence.firstSequence,verificationLastSequence:evidence.lastSequence,
            verificationCapturedAtMilliseconds:evidence.lastCapturedAtMilliseconds,fixedViewIdentity:context.fixedViewIdentity,
            targetIdentity:context.targetIdentity,baseline:baseline.positions,baselineTelemetrySequence:baseline.sequence,
            baselineCapturedAtMilliseconds:baseline.capturedAtMilliseconds)
        guard record.valid,support.claimForNativeAttachment() else {
            throw ROBGhostMotionError.blocked("This observed support was already consumed or its native attachment record is invalid.")
        }
        return .init(record:record,evidence:evidence,contact:sourceContact,payload:payload,context:context)
    }
    func invalidate(reason:String) {invalidatedReason=reason;pendingTicket=nil;awaitingReleaseCommand=false}

    /// Bind an already compiled, complete protected carrying-at-start route.
    /// Nothing here compiles a pickup, prepares jaws or grants movement.
    func bind(proposal:ROBLeftGestureProposal,currentContext:Context,map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,feedback:HeldFeedback,nowMilliseconds:Double)throws {
        try requireLive(currentContext,map:map,model:model,feedback:feedback,now:nowMilliseconds)
        guard self.proposal==nil,proposal.kind=="recycling_carry_release",proposal.sessionGeneration==context.gatewayGeneration,
              proposal.baseline==record.baseline,drift(feedback.positions,record.baseline)<=0.002,
              let path=proposal.workspaceCollisionPlan,path.carryingAtStart==true,path.contactStepIndex==nil,
              path.payload==payload,let contact=path.intentionalContact,contact.verifiedAttachment==record,
              contact.matchesSourceContact(sourceContact),proposal.steps==path.steps else {
            throw ROBGhostMotionError.blocked("The native attachment can bind only its exact original-source, immutable carry proposal once.")
        }
        try ROBLeftGestureCompiler.validate(proposal,model:model,collisionMap:map,collisionSceneID:context.sceneID,
            collisionCameraGeneration:context.cameraGeneration,visualCalibrationTrial:path.context.visualTrial,
            verifiedAttachment:record,nowMilliseconds:nowMilliseconds)
        self.proposal=proposal
    }
    /// A fresh, full protected segment proof is required for each actual held
    /// start. The ticket itself is ephemeral and is not serializable/replayable.
    func prepareDispatch(index:Int,segmentProof:ROBWorkspaceCollisionPlan,currentContext:Context,
        map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,feedback:HeldFeedback,
        nowMilliseconds:Double,nowUptime:Double)throws->DispatchTicket {
        try requireLive(currentContext,map:map,model:model,feedback:feedback,now:nowMilliseconds)
        guard let proposal,!awaitingReleaseCommand,pendingTicket==nil,index==nextIndex,proposal.steps.indices.contains(index),
              nowUptime.isFinite,nowUptime>=0,feedback.sequence>=record.baselineTelemetrySequence,
              index==0 || feedback.sequence>lastConsumedSequence,
              drift(feedback.positions,index==0 ? record.baseline:proposal.steps[index-1].positions)<=0.002,
              segmentProof.baseline==feedback.positions,segmentProof.steps==[proposal.steps[index]],
              segmentProof.payload==payload,segmentProof.contactStepIndex==index,
              segmentProof.intentionalContact==proposal.workspaceCollisionPlan?.intentionalContact,
              segmentProof.carryingAtStart==true,
              (0...250).contains(nowMilliseconds-segmentProof.context.checkedAtMilliseconds) else {
            throw ROBGhostMotionError.blocked("Attachment dispatch requires the next frozen step, advancing held telemetry and its fresh unchanged full collision proof.")
        }
        if let trial=segmentProof.context.visualTrial {
            try segmentProof.validateVisualCalibrationTrial(map:map,model:model,generation:context.gatewayGeneration,
                sceneID:context.sceneID,cameraGeneration:context.cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        } else {
            try segmentProof.validate(map:map,model:model,generation:context.gatewayGeneration,sceneID:context.sceneID,
                cameraGeneration:context.cameraGeneration,nowMilliseconds:nowMilliseconds)
        }
        let ticket=DispatchTicket(index:index,proposal:proposal,feedback:feedback,uptime:nowUptime)
        pendingTicket=ticket;return ticket
    }
    func matchesAndConsumeDispatch(_ ticket:DispatchTicket,proposalID:UUID,proposalSHA256:String,index:Int,seconds:Double,
        currentContext:Context,map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,feedback:HeldFeedback,
        nowMilliseconds:Double,nowUptime:Double)->Bool {
        do {try requireLive(currentContext,map:map,model:model,feedback:feedback,now:nowMilliseconds)}catch{return false}
        guard !awaitingReleaseCommand,pendingTicket === ticket,ticket.kind == .waypoint,let proposal,proposal.id==proposalID,proposal.fingerprint==proposalSHA256,
              ticket.proposalID==proposalID,ticket.proposalSHA256==proposalSHA256,ticket.index==index,index==nextIndex,
              seconds.isFinite,abs(ticket.seconds-seconds)<=1e-9,feedback.sequence>=ticket.sequence,
              nowUptime.isFinite,(0...0.250).contains(nowUptime-ticket.preparedAtUptime),
              drift(feedback.positions,ticket.positions)<=0.002 else{return false}
        pendingTicket=nil;lastConsumedSequence=feedback.sequence;nextIndex+=1
        if proposal.steps[index].jawAction == .release {
            // Reaching/holding a release waypoint does NOT mean the jaws
            // opened. Block further travel until a separate fresh jaw ticket.
            awaitingReleaseCommand=true
        }
        return true
    }
    /// The waypoint has settled; independently admit the actual jaw command
    /// from fresh stationary telemetry and a fresh unchanged contact proof.
    func prepareReleaseCommand(segmentProof:ROBWorkspaceCollisionPlan,currentContext:Context,
        map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,feedback:HeldFeedback,
        nowMilliseconds:Double,nowUptime:Double)throws->DispatchTicket {
        try requireLive(currentContext,map:map,model:model,feedback:feedback,now:nowMilliseconds)
        guard awaitingReleaseCommand,pendingTicket==nil,let proposal,
              let release=proposal.workspaceCollisionPlan?.intentionalContact?.releaseStepIndex,
              proposal.steps.indices.contains(release),proposal.steps[release].jawAction == .release,
              feedback.sequence>lastConsumedSequence,drift(feedback.positions,proposal.steps[release].positions)<=0.002,
              nowUptime.isFinite,nowUptime>=0,segmentProof.baseline==feedback.positions,
              segmentProof.steps==[proposal.steps[release]],segmentProof.payload==payload,
              segmentProof.contactStepIndex==release,segmentProof.carryingAtStart==true,
              segmentProof.intentionalContact==proposal.workspaceCollisionPlan?.intentionalContact,
              (0...250).contains(nowMilliseconds-segmentProof.context.checkedAtMilliseconds) else {
            throw ROBGhostMotionError.blocked("Actual release needs its settled frozen waypoint, fresh stationary feedback and a fresh exact release proof; no empty retreat is admitted.")
        }
        if let trial=segmentProof.context.visualTrial {
            try segmentProof.validateVisualCalibrationTrial(map:map,model:model,generation:context.gatewayGeneration,
                sceneID:context.sceneID,cameraGeneration:context.cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        } else {
            try segmentProof.validate(map:map,model:model,generation:context.gatewayGeneration,sceneID:context.sceneID,
                cameraGeneration:context.cameraGeneration,nowMilliseconds:nowMilliseconds)
        }
        let ticket=DispatchTicket(index:release,proposal:proposal,feedback:feedback,uptime:nowUptime,kind:.releaseCommand)
        pendingTicket=ticket;return ticket
    }
    /// Consume BEFORE actual jaw dispatch. A failed/unknown acknowledgment
    /// leaves payload uncertainty with the owning executor; never infer EMPTY.
    func matchesAndConsumeReleaseCommand(_ ticket:DispatchTicket,proposalID:UUID,proposalSHA256:String,
        currentContext:Context,map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,feedback:HeldFeedback,
        nowMilliseconds:Double,nowUptime:Double)->Bool {
        do {try requireLive(currentContext,map:map,model:model,feedback:feedback,now:nowMilliseconds)}catch{return false}
        guard awaitingReleaseCommand,pendingTicket === ticket,ticket.kind == .releaseCommand,let proposal,
              proposal.id==proposalID,proposal.fingerprint==proposalSHA256,ticket.proposalID==proposalID,
              ticket.proposalSHA256==proposalSHA256,feedback.sequence>=ticket.sequence,feedback.sequence>lastConsumedSequence,
              drift(feedback.positions,ticket.positions)<=0.002,
              drift(feedback.positions,proposal.steps[ticket.index].positions)<=0.002,
              nowUptime.isFinite,(0...0.250).contains(nowUptime-ticket.preparedAtUptime) else{return false}
        invalidate(reason:"Actual release command admission consumed the attachment; release/empty-state verification is still required.")
        return true
    }
    private func drift(_ a:[Double],_ b:[Double])->Double {
        guard a.count==7,b.count==7,(a+b).allSatisfy(\.isFinite) else{return .infinity}
        return 1.5*zip(a,b).reduce(0.0){$0+abs($1.0-$1.1)}
    }
    private func requireLive(_ current:Context,map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,
        feedback:HeldFeedback,now:Double)throws {
        guard invalidatedReason==nil,current==context,feedback.valid(context,now:now),feedback.sequence>=record.baselineTelemetrySequence,
              map.fingerprint==record.sourceMapFingerprint,map.sceneID==context.sceneID,map.cameraGeneration==context.cameraGeneration,
              map.sessionGeneration==context.gatewayGeneration,model.physicalSide==context.physicalArm,
              model.modelID==context.modelID,model.referenceID==context.referenceID,model.geometryID==context.geometryID,
              model.selectedMappingID==context.mappingID,
              (0...ROBWorkspaceCollisionPlan.maximumMapAgeMilliseconds).contains(now-record.verificationCapturedAtMilliseconds),
              let scope=map.visualCalibrationScope,scope.bodyContextIsCurrent,scope.bodyMotionIdentity==context.bodyMotionIdentity else {
            invalidate(reason:"Native attachment lost its live ownership/task/body/source/map/feedback context.")
            throw ROBGhostMotionError.blocked(invalidatedReason!)
        }
        do {try sourceContact.validate(map:map,model:model,nowMilliseconds:now)}
        catch {invalidate(reason:error.localizedDescription);throw error}
    }
}
