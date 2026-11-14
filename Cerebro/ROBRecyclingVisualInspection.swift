import Foundation
import simd
import Vision
import CoreImage

/// Connects fixed-view raw pixels to measured feedback. It contains no motion,
/// approval, jaw command, target correction or camera-pose setter.
@MainActor enum ROBRecyclingVisualInspection {
    enum TargetMoved:LocalizedError {
        case displacement(Double)
        case imageDisplacement(Double)
        var errorDescription:String? {
            if case .displacement(let distance)=self {return "The can moved \(Int((distance*1000).rounded())) mm from the reviewed grasp. Holding before closure; reacquire and review a new reach."}
            if case .imageDisplacement(let pixels)=self {return "The selected can moved \(Int(pixels.rounded())) image pixels during the approach. Hold and freshly replan before closing."}
            return nil
        }
    }
    struct Context {
        var verifier:ROBVisualGraspVerifier
        let projection:Projection
        let scope:ROBFixedHeadRegistrationScope
        let targetIdentity:String
        let viewIdentity:String
        let assumedCanGeometry:Bool
    }
    enum Projection {
        case registered(ROBFixedHeadRegistration)
        case visualTrial(VisualProjection)
    }
    struct VisualProjection {
        let trial:ROBWorkspaceVisualCalibrationTrial
        let map:ROBWorkspaceCollisionSnapshot
        let cameraToModel:simd_double4x4
        let frameContractIdentity:String
        let pendingID:String
    }
    /// Cached fixed-head previews must expire after any real head/calibration,
    /// camera, gateway or body-frame change, even without a camera restart.
    static func fixedHeadContextIsCurrent(model:ROBGhostRobotModel,map:ROBWorkspaceCollisionSnapshot)->Bool {
        do {
            guard let frame=ROBArmRoutineVision.shared.snapshot()["face"],
                  (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
                  frame.cameraGeneration==map.cameraGeneration,
                  map.modelID==model.modelID,map.geometryID==model.geometryID,map.mappingID==model.selectedMappingID,
                  let lastScope=map.observations.last?.fixedHeadScope,
                  let registration=try ROBFixedHeadCalibrationWindowController.shared.registration(model:model,frame:frame) else {return false}
            let scope=try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame)
            // A map's registration identity hashes its contributing profiles;
            // it is deliberately different from an individual profile's ID.
            let expectedMapID="fixed-head-map-"+ROBGhostRobotModel.hash(Data(registration.id.utf8))
            return registration.matches(scope) && scope==lastScope &&
                scope.gatewaySessionGeneration==map.sessionGeneration && map.registrationID==expectedMapID &&
                map.observations.allSatisfy{$0.fixedHeadScope==scope && $0.registrationID==registration.id}
        } catch {return false}
    }
    static func begin(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,gatewayArm:String,
        check:() throws ->Void) async throws ->Context {
        try check()
        let (observation,frame)=try await ROBArmRoutineVision.shared.observeWorkspace()
        try check()
        guard let registration=try ROBFixedHeadCalibrationWindowController.shared.registration(model:model,frame:frame),
              can.registrationID==registration.id,can.sections?.shapePriorEvidence==nil else {
            throw ROBGhostMotionError.blocked("The grasp view needs the same measured fixed-head registration as the can observation.")
        }
        let scope=try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let viewIdentity=registration.id+":"+ROBGhostRobotModel.hash(try encoder.encode(scope))
        return try beginContext(model:model,can:can,gatewayArm:gatewayArm,observation:observation,frame:frame,
            projection:.registered(registration),scope:scope,cameraToModel:registration.cameraToRobot,
            identity:"can-\(can.sequence)-\(registration.id)",viewIdentity:viewIdentity,check:check)
    }

    /// Explicitly unmeasured camera geometry, scoped to the caller's active
    /// exact bounded can-job receipt. This never creates registration or motion.
    static func beginVisualCalibrationTrial(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,
        map:ROBWorkspaceCollisionSnapshot,trial:ROBWorkspaceVisualCalibrationTrial,gatewayArm:String,
        feedbackForFrame:((ROBArmRoutineVision.Frame)->ROBAmberGatewayTelemetry?)?=nil,
        check:() throws ->Void) async throws ->Context {
        try check()
        let (observation,frame)=try await ROBArmRoutineVision.shared.observeWorkspace()
        try check()
        let scope=try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame)
        let neck=ROBFixedHeadCalibrationWindowController.shared.readNeck?() ?? [:]
        guard gatewayArm == (model.physicalSide == "right" ? "left" : "right"),can.registrationID == nil,
              scope.upperTarget==can.view.upperTarget,
              (neck["pan_degrees"] as? Double).map({$0.isFinite && abs($0-can.view.panDegrees)<=0.05}) == true,
              let source=map.observations.first(where:{$0.sequence==can.sequence && abs($0.capturedAtMilliseconds-can.capturedAt)<=1}),
              source.recordedUpperTarget==can.view.upperTarget,source.recordedLowerTarget==scope.lowerTarget,
              source.recordedPanDegrees.map({abs($0-can.view.panDegrees)<=0.05}) == true,
              let matrix=ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:scope.panTarget,
                lowerTarget:scope.lowerTarget,upperTarget:scope.upperTarget),
              source.cameraToRobotColumnMajor == (0..<4).flatMap({column in (0..<4).map{matrix[column][$0]}}),
              let pendingID=ROBControllerArmApproval.shared.activeLocalRecyclingApprovalEvidence?["pendingID"] as? String else {
            throw ROBGhostMotionError.blocked("The unmeasured grasp inspection needs the selected can's exact original raw neck view and projection; settle that view and replan first.")
        }
        let projection=VisualProjection(trial:trial,map:map,cameraToModel:matrix,
            frameContractIdentity:try visualFrameContract(frame),pendingID:pendingID)
        try validateVisualProjection(projection,scope:scope,frame:frame,model:model)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let viewIdentity="unmeasured-visual-trial:"+trial.receiptID+":"+ROBGhostRobotModel.hash(try encoder.encode(scope))+":"+projection.frameContractIdentity
        return try beginContext(model:model,can:can,gatewayArm:gatewayArm,observation:observation,frame:frame,
            projection:.visualTrial(projection),scope:scope,cameraToModel:matrix,
            identity:"can-\(can.sequence)-unmeasured-\(trial.receiptID)",viewIdentity:viewIdentity,feedbackForFrame:feedbackForFrame,check:check)
    }

    private static func beginContext(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,gatewayArm:String,
        observation:ROBWorkspaceObservation,frame:ROBArmRoutineVision.Frame,projection:Projection,
        scope:ROBFixedHeadRegistrationScope,cameraToModel:simd_double4x4,identity:String,viewIdentity:String,
        feedbackForFrame:((ROBArmRoutineVision.Frame)->ROBAmberGatewayTelemetry?)?=nil,
        check:() throws ->Void) throws ->Context {
        let optical=simd_inverse(cameraToModel)*SIMD4(can.point.x,can.point.y,can.point.z,1)
        guard let k=frame.intrinsics,let depth=frame.depth,optical.z>0 else {
            let cameraKind:String
            switch projection {case .registered:cameraKind="registered";case .visualTrial:cameraKind="estimated"}
            throw ROBGhostMotionError.blocked("The selected can is outside the \(cameraKind) grasp camera view.")
        }
        let u=(k.fx*optical.x/optical.z+k.cx)/Double(depth.width-1)
        let v=(k.fy*optical.y/optical.z+k.cy)/Double(depth.height-1)
        let candidates=(observation.cans ?? [observation.can]).filter { detection in
            detection.visuallyUsable && detection.box[0]<=u && detection.box[2]>=u && detection.box[1]<=v && detection.box[3]>=v
        }
        guard candidates.count==1 else {
            throw ROBGhostMotionError.blocked("The grasp camera did not uniquely reacquire the selected can before closing.")
        }
        let detection=candidates[0]
        let box=ROBVisualGraspVerifier.Box(left:detection.box[0],top:detection.box[1],right:detection.box[2],bottom:detection.box[3])
        guard let currentFrame=ROBArmRoutineVision.shared.snapshot()["face"] else {
            throw ROBGhostMotionError.blocked("No advancing grasp camera image is available before closure.")
        }
        let reference=try projectionSample(frame:frame,model:model,gatewayArm:gatewayArm,projection:projection,
            scope:scope,identity:identity,viewIdentity:viewIdentity,allowReferenceImage:true,feedbackForFrame:feedbackForFrame)
        let sample=try projectionSample(frame:currentFrame,model:model,gatewayArm:gatewayArm,projection:projection,
            scope:scope,identity:identity,viewIdentity:viewIdentity,feedbackForFrame:feedbackForFrame)
        guard let currentBox=ROBVisualGraspVerifier.confirmTargetContinuity(reference:reference,targetBox:box,current:sample,
            nowMilliseconds:Date().timeIntervalSince1970*1000),let currentDepth=currentFrame.depth,let currentK=currentFrame.intrinsics else {
            throw ROBGhostMotionError.blocked("The can moved or was occluded between detection and the current grasp image. Holding before closure.")
        }
        let currentDetection=ROBWorkspaceDetection(visible:true,confidence:detection.confidence,
            box:[currentBox.left,currentBox.top,currentBox.right,currentBox.bottom],
            aim:[currentBox.center.x,currentBox.center.y],depthPoint:[currentBox.center.x,currentBox.center.y],
            confidenceThreshold:detection.confidenceThreshold)
        let currentCan:ROBWorkspaceCanSections
        let assumedCanGeometry=can.sections?.shapePriorEvidence != nil
        if assumedCanGeometry {
            guard case .visualTrial(let visual)=projection,can.sections?.shapePriorEvidence?.valid==true else {
                throw ROBGhostMotionError.blocked("An assumed can shape needs its exact active unmeasured visual-trial receipt before closure.")
            }
            try check();try validateVisualProjection(visual,scope:scope,frame:currentFrame,model:model)
            let prior=ROBWorkspaceSearch.shared.localCanShapePrior(detection:currentDetection,
                allCanDetections:(observation.cans ?? [observation.can])+[currentDetection],frame:currentFrame,
                view:can.view,model:model,cameraToRobot:cameraToModel)
            try check();try validateVisualProjection(visual,scope:scope,frame:currentFrame,model:model)
            guard (0...700).contains(Date().timeIntervalSince1970*1000-currentFrame.capturedAt),
                  let reacquired=prior.sections,reacquired.shapePriorEvidence?.valid==true else {
                throw ROBGhostMotionError.blocked("Fresh table/silhouette evidence did not reacquire the assumed can cylinder. Holding before closure.")
            }
            currentCan=reacquired
        } else {
            guard let measuredCan=ROBWorkspaceCanSections.measure(detection:currentDetection,width:currentDepth.width,height:currentDepth.height,
                fx:currentK.fx,fy:currentK.fy,cx:currentK.cx,cy:currentK.cy,
                depth:{currentDepth.distanceMillimeters(x:$0,y:$1)},view:can.view,model:model,cameraToRobot:cameraToModel) else {
                throw ROBGhostMotionError.blocked("Current can geometry is occluded or depth is ambiguous. Holding before closure.")
            }
            currentCan=measuredCan
        }
        let displacement=simd_distance(SIMD3(currentCan.middle[0],currentCan.middle[1],currentCan.middle[2]),can.point)
        guard displacement<=0.012 else {throw TargetMoved.displacement(displacement)}
        let verifier=try ROBVisualGraspVerifier(baseline:sample,targetBox:currentBox,nowMilliseconds:Date().timeIntervalSince1970*1000)
        try check()
        return Context(verifier:verifier,projection:projection,scope:scope,targetIdentity:identity,viewIdentity:viewIdentity,
            assumedCanGeometry:assumedCanGeometry)
    }
    struct ServoBaseline {
        let projection:Projection
        let scope:ROBFixedHeadRegistrationScope
        let targetIdentity:String
        let viewIdentity:String
    }
    final class ServoContext {
        let baseline:ServoBaseline
        let can:ROBWorkspaceLocatedObject
        var controller:ROBGripperVisualServo.Controller
        let tracker=VNSequenceRequestHandler()
        var request:VNTrackObjectRequest
        var targetBox:[Double]
        var lastSequence:UInt64=0
        var firstCanMiddlePixels:[Double]?
        var observations:[[String:Any]]=[]
        var retainedFrames:[ROBGripperVisualServo.Frame]=[]
        var provisionalCoMotion=false
        @MainActor init(baseline:ServoBaseline,can:ROBWorkspaceLocatedObject,model:ROBGhostRobotModel,box:[Double]) {
            self.baseline=baseline;self.can=can;targetBox=box
            request=VNTrackObjectRequest(detectedObjectObservation:VNDetectedObjectObservation(boundingBox:
                CGRect(x:box[0],y:1-box[3],width:box[2]-box[0],height:box[3]-box[1])))
            request.trackingLevel = .accurate
            controller=ROBGripperVisualServo.Controller(configuration:.init(jointBounds:ROBWorkspaceCollisionPlan.jointBounds(model:model),correctingJointIndices:Array(0..<7)))
        }
    }
    struct ServoObservation {
        let frame:ROBGripperVisualServo.Frame
        let decision:ROBGripperVisualServo.Decision
        let canBox:[Double]
    }
    private static let servoImageContext=CIContext(options:[.useSoftwareRenderer:true])

    static func beginIncrementalVisualServo(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,
        map:ROBWorkspaceCollisionSnapshot,trial:ROBWorkspaceVisualCalibrationTrial,gatewayArm:String,
        feedbackForFrame:@escaping(ROBArmRoutineVision.Frame)->ROBAmberGatewayTelemetry?,
        check:() throws->Void) async throws->ServoContext {
        try check()
        let(observation,reference)=try await ROBArmRoutineVision.shared.observeWorkspace()
        try check()
        let controller=ROBFixedHeadCalibrationWindowController.shared,scope=try controller.scope(model:model,frame:reference)
        let neck=controller.readNeck?() ?? [:]
        guard can.registrationID==nil,gatewayArm==(model.physicalSide=="right" ? "left":"right"),
              scope.upperTarget==can.view.upperTarget,
              (neck["pan_degrees"] as?Double).map({abs($0-can.view.panDegrees)<=0.05})==true,
              let source=map.observations.first(where:{$0.sequence==can.sequence && abs($0.capturedAtMilliseconds-can.capturedAt)<=1}),
              source.recordedLowerTarget==scope.lowerTarget,source.recordedUpperTarget==scope.upperTarget,
              let matrix=ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:scope.panTarget,lowerTarget:scope.lowerTarget,upperTarget:scope.upperTarget),
              source.cameraToRobotColumnMajor==(0..<4).flatMap({c in(0..<4).map{matrix[c][$0]}}),
              let pending=ROBControllerArmApproval.shared.activeLocalRecyclingApprovalEvidence?["pendingID"] as?String,
              let k=reference.intrinsics,let depth=reference.depth else {throw ROBGhostMotionError.blocked("The visual-servo can seed lost its original held-view/source/receipt scope.")}
        let p=simd_inverse(matrix)*SIMD4(can.point.x,can.point.y,can.point.z,1)
        guard p.z>0 else {throw ROBGhostMotionError.blocked("Selected can is outside the fixed visual-servo view.")}
        let u=(k.fx*p.x/p.z+k.cx)/Double(depth.width-1),v=(k.fy*p.y/p.z+k.cy)/Double(depth.height-1)
        let detections=(observation.cans ?? [observation.can]).filter{$0.visuallyUsable && $0.box[0]<=u && $0.box[2]>=u && $0.box[1]<=v && $0.box[3]>=v}
        guard detections.count==1 else {throw ROBGhostMotionError.blocked("The selected can was not uniquely reacquired for incremental servo.")}
        let projection=VisualProjection(trial:trial,map:map,cameraToModel:matrix,frameContractIdentity:try visualFrameContract(reference),pendingID:pending)
        try validateVisualProjection(projection,scope:scope,frame:reference,model:model)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let view="observed-jaw-servo:"+trial.receiptID+":"+ROBGhostRobotModel.hash(try encoder.encode(scope))+":"+projection.frameContractIdentity
        let baseline=ServoBaseline(projection:.visualTrial(projection),scope:scope,targetIdentity:"can-\(can.sequence)-\(trial.receiptID)",viewIdentity:view)
        let result=ServoContext(baseline:baseline,can:can,model:model,box:detections[0].box)
        guard let image=servoImageContext.createCGImage(reference.image,from:reference.image.extent) else {throw ROBGhostMotionError.blocked("The actual can seed pixels are unavailable.")}
        try result.tracker.perform([result.request],on:image)
        if let initial=result.request.results?.first as?VNDetectedObjectObservation {result.request.inputObservation=initial}
        try check()
        return result
    }

    static func observeIncrementalVisualServo(context:ServoContext,model:ROBGhostRobotModel,
        frame:ROBArmRoutineVision.Frame,feedback:ROBAmberGatewayTelemetry,currentFeedback:ROBAmberGatewayTelemetry,
        heldSinceMilliseconds:Double,openingCommandAtMilliseconds:Double?,requireTableSupport:Bool=true,
        check:() throws->Void) throws->ServoObservation {
        try check()
        guard case .visualTrial(let projection)=context.baseline.projection else {throw ROBGhostMotionError.blocked("Incremental servo requires its actual local visual-trial source.")}
        try validateVisualProjection(projection,scope:context.baseline.scope,frame:frame,model:model)
        let now=Date().timeIntervalSince1970*1000
        let historicalTime=now-feedback.effectiveSampleAgeMilliseconds
        guard frame.sequence>context.lastSequence,frame.capturedAt>=heldSinceMilliseconds,
              feedback.sampleAgeAtReceiptMilliseconds<=250,currentFeedback.effectiveSampleAgeMilliseconds<=250,
              currentFeedback.effectiveGripperFeedbackAgeMilliseconds<=250,
              1.5*zip(feedback.positionsRadians,currentFeedback.positionsRadians).reduce(0.0,{$0+abs($1.0.doubleValue-$1.1.doubleValue)})<=0.003,
              let image=servoImageContext.createCGImage(frame.image,from:frame.image.extent) else {
            throw ROBGhostMotionError.blocked("Servo needs an advancing held-pose image and actual exposure-matched CAN history, plus fresh current feedback.")
        }
        try context.tracker.perform([context.request],on:image)
        guard let tracked=context.request.results?.first as? VNDetectedObjectObservation,tracked.confidence>=0.7 else {
            throw ROBGhostMotionError.blocked("The selected can tracker is ambiguous or occluded; hold without closing.")
        }
        context.request.inputObservation=tracked
        let b=tracked.boundingBox,box=[Double(b.minX),Double(1-b.maxY),Double(b.maxX),Double(1-b.minY)]
        context.targetBox=box;context.lastSequence=frame.sequence
        var assumedDepth:Double?
        if requireTableSupport {
            let d=ROBWorkspaceDetection(visible:true,confidence:Double(tracked.confidence),box:box,
                aim:[(box[0]+box[2])/2,(box[1]+box[3])/2],depthPoint:[(box[0]+box[2])/2,(box[1]+box[3])/2],confidenceThreshold:0.35)
            let prior=ROBWorkspaceSearch.shared.localCanShapePrior(detection:d,allCanDetections:[d],frame:frame,
                view:context.can.view,model:model,cameraToRobot:projection.cameraToModel)
            guard let sections=prior.sections,sections.shapePriorEvidence?.valid==true else {
                throw ROBGhostMotionError.blocked("Current can/table silhouette no longer supports the assumed middle-grasp geometry.")
            }
            let middle=SIMD3(sections.middle[0],sections.middle[1],sections.middle[2])
            let displacement=simd_distance(middle,context.can.point)
            guard displacement<=0.012 else {throw TargetMoved.displacement(displacement)}
            let optical=simd_inverse(projection.cameraToModel)*SIMD4(middle.x,middle.y,middle.z,1)
            assumedDepth=optical.z>0 ? optical.z:nil
        }
        var pixels=try ROBArmRoutineVision.shared.makeGripperVisualServoFrame(frame:frame,scopeIdentity:context.baseline.viewIdentity,
            jointPositions:feedback.positionsRadians.map(\.doubleValue),jointCapturedAtMilliseconds:historicalTime,
            poseHeldDuringCapture:true,openingCommandAtMilliseconds:openingCommandAtMilliseconds,nowMilliseconds:now)
        let currentTool=model.toolPosition(model.positions(vendorLeft:currentFeedback.positionsRadians.map(\.doubleValue)))
        guard let currentTool,let k=frame.intrinsics,let depth=frame.depth else {throw ROBGhostMotionError.blocked("Missing nominal tool search region; no visual jaw location inferred.")}
        let optical=simd_inverse(projection.cameraToModel)*SIMD4(currentTool.x,currentTool.y,currentTool.z,1)
        guard optical.z>0 else {throw ROBGhostMotionError.blocked("Nominal tool search region is outside the camera.")}
        let u=(k.fx*optical.x/optical.z+k.cx)/Double(depth.width),v=(k.fy*optical.y/optical.z+k.cy)/Double(depth.height)
        let roi=ROBGripperVisualServo.ROI(xMin:max(0,u-0.22),yMin:max(0,v-0.22),xMax:min(1,u+0.22),yMax:min(1,v+0.22))
        let measuredQ=currentFeedback.positionsRadians.map(\.doubleValue)
        var estimated=Array(repeating:Array(repeating:0.0,count:7),count:2)
        let basePixel=SIMD2(pixels.fx*optical.x/optical.z+pixels.cx,pixels.fy*optical.y/optical.z+pixels.cy)
        for index in 0..<7 {
            var shifted=measuredQ;shifted[index]+=0.0001
            if let tip=model.toolPosition(model.positions(vendorLeft:shifted)) {
                let p=simd_inverse(projection.cameraToModel)*SIMD4(tip.x,tip.y,tip.z,1)
                if p.z>0 {estimated[0][index]=(pixels.fx*p.x/p.z+pixels.cx-basePixel.x)/0.0001;estimated[1][index]=(pixels.fy*p.y/p.z+pixels.cy-basePixel.y)/0.0001}
            }
        }
        pixels.estimatedImageJacobian=estimated // explicitly estimated FK direction, never observed jaw pixels

        let target=ROBGripperVisualServo.Target(id:context.baseline.targetIdentity,boxNormalized:box,geometryAssumed:true,
            assumedDepthMeters:assumedDepth,assumedDiameterMeters:context.can.sections?.diameterMeters)
        let decision=context.controller.update(frame:pixels,target:target,searchROI:roi,nowMilliseconds:now,observationOnly:!requireTableSupport)
        var evidence:[String:Any]=["sequence":NSNumber(value:frame.sequence),"captured_at_ms":frame.capturedAt,
            "can_box":box,"status":String(describing:decision.status),"reason":decision.reason,
            "joint_positions":feedback.positionsRadians.map(\.doubleValue),"joint_captured_at_ms":historicalTime,
            "diagnostics":decision.diagnostics.mapValues{value->Any in if value.isFinite{return value};return NSNull()},"jaw_location_source":"observed_pixels_only_FK_ROI_is_not_a_measurement",
            "geometry_assumed":true,"ready_to_grip_image_alignment_only":decision.readyToGrip]
        if let jaw=decision.observation {evidence["jaw_center_pixels"]=jaw.centerPixels;evidence["jaw_tips_pixels"]=jaw.tipsPixels;evidence["jaw_confidence"]=jaw.confidence;evidence["jaw_evidence_kind"]=jaw.evidenceKind}
        context.observations.append(evidence)
        if context.firstCanMiddlePixels==nil {context.firstCanMiddlePixels=decision.canMiddlePixels}
        context.retainedFrames.append(pixels)
        if context.retainedFrames.count>12 {context.retainedFrames.removeFirst()}
        if context.observations.count>80 {context.observations.removeFirst()}
        try check()
        if decision.status=="targetMoved",let initial=context.firstCanMiddlePixels,initial.count==2,decision.canMiddlePixels.count==2 {
            throw TargetMoved.imageDisplacement(hypot(decision.canMiddlePixels[0]-initial[0],decision.canMiddlePixels[1]-initial[1]))
        }
        return ServoObservation(frame:pixels,decision:decision,canBox:box)
    }

    static func verifyIncrementalServoLift(context:ServoContext,beforeLift:ServoObservation,model:ROBGhostRobotModel,
        heldSinceMilliseconds:Double,observe:() async throws->ServoObservation,check:()throws->Void) async throws->ROBVisualGraspVerifier.Evidence {
        let base=beforeLift.frame,box=beforeLift.canBox
        var result=ROBVisualGraspVerifier.Evidence(verdict:.collecting,reason:"Waiting for observed jaw/can lift co-motion.",samples:0,
            firstSequence:base.sequence,lastSequence:base.sequence,cameraGeneration:context.baseline.scope.cameraGeneration,
            fixedViewIdentity:context.baseline.viewIdentity,targetIdentity:context.baseline.targetIdentity,
            targetBox:.init(left:box[0],top:box[1],right:box[2],bottom:box[3]),
            baselineCapturedAtMilliseconds:base.capturedAtMilliseconds,lastCapturedAtMilliseconds:base.capturedAtMilliseconds)
        guard let originalJaw=beforeLift.decision.observation else {result.verdict = .unknown;result.reason="No observed jaw baseline; hold the possible payload.";return result}
        var coherent=0,stationary=0,divergent=0
        let end=ProcessInfo.processInfo.systemUptime+4
        while ProcessInfo.processInfo.systemUptime<end {
            try check();try Task.checkCancellation()
            let sample:ServoObservation
            do {sample=try await observe()}catch{
                try check();result.verdict = .unknown;result.reason="Live observed-jaw/can verification was inconclusive: "+error.localizedDescription;return result
            }
            guard sample.frame.sequence>result.lastSequence,sample.frame.capturedAtMilliseconds>=heldSinceMilliseconds,
                  sample.frame.scopeIdentity==base.scopeIdentity,let jaw=sample.decision.observation else {continue}
            result.samples+=1;result.lastSequence=sample.frame.sequence;result.lastCapturedAtMilliseconds=sample.frame.capturedAtMilliseconds
            guard servoBackgroundIsStatic(base,sample.frame,canBox:box,jaw:originalJaw) else {
                result.verdict = .unknown;result.reason="Static RGB background did not support a fixed camera/exposure; holding without a possession claim.";return result
            }
            let j=zip(jaw.centerPixels,originalJaw.centerPixels).map{$0-$1},c=zip(sample.decision.canMiddlePixels,beforeLift.decision.canMiddlePixels).map{$0-$1}
            guard j.count==2,c.count==2 else{continue}
            let jm=hypot(j[0],j[1]),cm=hypot(c[0],c[1]),error=hypot(j[0]-c[0],j[1]-c[1])
            result.toolMotionPixels=jm;result.targetMotionPixels=cm;result.targetToolMotionErrorPixels=error
            guard jm>=6 else{continue}
            if cm>=4,error<=max(3,jm*0.25) {coherent+=1;stationary=0;divergent=0}
            else if cm<=2 {stationary+=1;coherent=0;divergent=0}
            else {divergent+=1;coherent=0;stationary=0}
            if coherent>=3 {context.provisionalCoMotion=true;result.verdict = .unknown;result.reason="Provisional can-box/jaw co-motion in three advancing RGB views. Independent can-appearance identity and possession are NOT verified; the tracker may include occluding jaws. Holding for direct camera/operator observation, with no carry, release or grasp count.";return result}
            if stationary>=3 || divergent>=3 {result.verdict = .failed;result.reason=stationary>=3 ? "Observed jaws lifted but the selected can stayed on the table. Holding; no blind retry.":"The selected can did not move coherently with the observed jaws. Holding the possible payload.";return result}
        }
        result.verdict = .unknown;result.reason="The bounded RGB jaw/can observation did not establish repeated lift co-motion. Holding; no carry/release or automatic grasp retry."
        return result
    }

    private static func servoBackgroundIsStatic(_ a:ROBGripperVisualServo.Frame,_ b:ROBGripperVisualServo.Frame,
        canBox:[Double],jaw:ROBGripperVisualServo.JawObservation)->Bool {
        guard a.width==b.width,a.height==b.height,a.rgb.count==b.rgb.count else{return false}
        let w=a.width,h=a.height,aa=[UInt8](a.rgb),bb=[UInt8](b.rgb)
        func gray(_ p:[UInt8],_ x:Int,_ y:Int)->Double {let i=(y*w+x)*3;return 0.299*Double(p[i])+0.587*Double(p[i+1])+0.114*Double(p[i+2])}
        var still:[SIMD2<Double>]=[],shifted=0
        for fy in [0.15,0.38,0.62,0.85] {for fx in [0.15,0.38,0.62,0.85] {
            if fx>canBox[0]-0.10 && fx<canBox[2]+0.10 && fy>canBox[1]-0.10 && fy<canBox[3]+0.10 {continue}
            let x=Int(fx*Double(w-1)),y=Int(fy*Double(h-1))
            if hypot(Double(x)-jaw.centerPixels[0],Double(y)-jaw.centerPixels[1])<max(25,jaw.openingPixels+12){continue}
            guard x>=8,y>=8,x<w-8,y<h-8 else{continue}
            var av:[Double]=[];for yy in -5...5 {for xx in -5...5 {av.append(gray(aa,x+xx,y+yy))}}
            let am=av.reduce(0,+)/Double(av.count),an=sqrt(av.reduce(0){$0+pow($1-am,2)})
            guard an>80 else{continue}
            var best = -1.0,bestDx=0,bestDy=0
            for dy in -2...2 {for dx in -2...2 {
                var bv:[Double]=[];for yy in -5...5 {for xx in -5...5 {bv.append(gray(bb,x+dx+xx,y+dy+yy))}}
                let bm=bv.reduce(0,+)/Double(bv.count),bn=sqrt(bv.reduce(0){$0+pow($1-bm,2)})
                guard bn>80 else{continue}
                let corr=zip(av,bv).reduce(0.0){$0+($1.0-am)*($1.1-bm)}/(an*bn)
                if corr>best {best=corr;bestDx=dx;bestDy=dy}
            }}
            if best>=0.85 {if bestDx==0 && bestDy==0 {still.append(SIMD2(Double(x),Double(y)))}else{shifted+=1}}
        }}
        let spread=still.map{p in still.map{simd_distance(p,$0)}.max() ?? 0}.max() ?? 0
        return still.count>=3 && shifted<3 && spread>=0.3*Double(min(w,h))
    }

    static func verifyAfterLift(context:Context,model:ROBGhostRobotModel,gatewayArm:String,
        check:() throws ->Void) async throws ->ROBVisualGraspVerifier.Evidence {
        var verifier=context.verifier
        let deadline=ProcessInfo.processInfo.systemUptime+4
        while ProcessInfo.processInfo.systemUptime<deadline {
            try check();try Task.checkCancellation()
            if let frame=ROBArmRoutineVision.shared.snapshot()["face"],frame.sequence>verifier.evidence.lastSequence {
                let sample=try projectionSample(frame:frame,model:model,gatewayArm:gatewayArm,projection:context.projection,
                    scope:context.scope,identity:context.targetIdentity,viewIdentity:context.viewIdentity)
                let result=verifier.observe(sample,nowMilliseconds:Date().timeIntervalSince1970*1000)
                if result.verdict != .collecting {try check();return labelled(result,projection:context.projection,assumedCanGeometry:context.assumedCanGeometry)}
            }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        try check();return labelled(verifier.finish(),projection:context.projection,assumedCanGeometry:context.assumedCanGeometry)
    }
    private static func labelled(_ value:ROBVisualGraspVerifier.Evidence,projection:Projection,assumedCanGeometry:Bool) ->ROBVisualGraspVerifier.Evidence {
        guard case .visualTrial = projection else {return value}
        var result=value
        result.reason += " Tool comparison uses estimated-camera projection of measured joint feedback; camera alignment and possession are not measured."
        if assumedCanGeometry {result.reason += " Can dimensions/axis were an explicit local shape prior; verification uses original raw pixels/depth without fabricated cylinder depths."}
        return result
    }
    private static func visualFrameContract(_ frame:ROBArmRoutineVision.Frame) throws ->String {
        guard let k=frame.intrinsics,let depth=frame.depth,k.isValid(forWidth:depth.width,height:depth.height),
              k.rgbOutputUndistorted == true,k.depthRGBGeometryCorrespondence?.status == "matched",
              let runtime=k.runtimeCalibration?.identity,let source=k.cameraServiceSourceSHA256,
              runtime.count==64,source.count==64 else {
            throw ROBGhostMotionError.blocked("Visual-trial inspection needs the actual normalized, synchronized RGB-D source and runtime provenance.")
        }
        let value:[String:Any] = ["runtime":runtime,"source":source,"width":depth.width,"height":depth.height,
            "K":[k.fx,k.fy,k.cx,k.cy],"sourceSize":k.sourceSize as Any? ?? NSNull(),
            "sourceK":k.sourceIntrinsics as Any? ?? NSNull(),"A":k.imageTransform as Any? ?? NSNull(),
            "D":k.rgbSourceDistortionCoefficients as Any? ?? NSNull(),"DModel":k.rgbSourceDistortionModel as Any? ?? NSNull(),
            "depthK":k.depthIntrinsics as Any? ?? NSNull(),"depthA":k.depthImageTransform as Any? ?? NSNull(),
            "depthD":k.depthSourceDistortionCoefficients as Any? ?? NSNull(),
            "depthDModel":k.depthSourceDistortionModel as Any? ?? NSNull(),
            "lens":k.frameLensPosition as Any? ?? NSNull(),"calibratedLens":k.calibratedLensPosition as Any? ?? NSNull(),
            "stereoMode":k.stereoMode as Any? ?? NSNull(),"extended":k.stereoExtendedDisparity as Any? ?? NSNull(),
            "subpixel":k.stereoSubpixel as Any? ?? NSNull()]
        return ROBGhostRobotModel.hash(try JSONSerialization.data(withJSONObject:value,options:.sortedKeys))
    }
    private static func validateVisualProjection(_ value:VisualProjection,scope:ROBFixedHeadRegistrationScope,
        frame:ROBArmRoutineVision.Frame,model:ROBGhostRobotModel) throws {
        let trial=value.trial,broker=ROBControllerArmApproval.shared
        let controller=ROBFixedHeadCalibrationWindowController.shared
        let current=try controller.scope(model:model,frame:frame)
        let neck=controller.readNeck?() ?? [:],now=ProcessInfo.processInfo.systemUptime
        let captured=now-(Date().timeIntervalSince1970*1000-frame.capturedAt)/1000
        guard trial.valid,let receipt=broker.activeLocalRecyclingApprovalEvidence,
              let summary=receipt["summary"] as? String,
              broker.authorizesLocalRecyclingVisualCalibrationTrial(summary:summary,arm:model.physicalSide),
              receipt["receiptID"] as? String==trial.receiptID,receipt["receiptSHA256"] as? String==trial.receiptSHA256,
              receipt["appSessionID"] as? String==trial.appSessionID,receipt["command"] as? String==trial.command,
              receipt["pendingID"] as? String==value.pendingID,
              receipt["summarySHA256"] as? String==trial.summarySHA256,
              receipt["contextIdentity"] as? String==trial.authorizationContextIdentity,
              (receipt["canCount"] as? NSNumber)?.intValue==trial.canCount,
              ((receipt["executingUntilMilliseconds"] as? NSNumber)?.doubleValue ?? 0) >= trial.expiresAtMilliseconds,
              current==scope,scope.cameraGeneration==trial.cameraGeneration,
              scope.gatewaySessionGeneration==trial.sessionGeneration,frame.cameraGeneration==trial.cameraGeneration,
              neck["known"] as? Bool==true,neck["stationary"] as? Bool==true,
              neck["pan"] as? Int==scope.panTarget,neck["lower"] as? Int==scope.lowerTarget,
              neck["upper"] as? Int==scope.upperTarget,
              let ready=neck["ready_at"] as? Double,ready.isFinite,ready<=now,captured>=ready,
              ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==trial.estimatedCameraProjectionIdentity,
              let camera=ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:scope.panTarget,
                lowerTarget:scope.lowerTarget,upperTarget:scope.upperTarget),
              (0..<4).allSatisfy({column in (0..<4).allSatisfy{abs(camera[column][$0]-value.cameraToModel[column][$0])<=1e-10}}),
              try visualFrameContract(frame)==value.frameContractIdentity else {
            throw ROBGhostMotionError.blocked("The visual-trial grasp view lost its exact local receipt, held neck, profile, runtime/source or native pixel geometry.")
        }
        _ = try ROBWorkspaceCollisionPlan.validateVisualCalibrationTrialMap(value.map,model:model,generation:scope.gatewaySessionGeneration,
            sceneID:trial.sceneID,cameraGeneration:frame.cameraGeneration,nowMilliseconds:Date().timeIntervalSince1970*1000,trial:trial)
    }
    private static func projectionSample(frame:ROBArmRoutineVision.Frame,model:ROBGhostRobotModel,gatewayArm:String,
        projection:Projection,scope:ROBFixedHeadRegistrationScope,identity:String,viewIdentity:String,
        allowReferenceImage:Bool=false,feedbackForFrame:((ROBArmRoutineVision.Frame)->ROBAmberGatewayTelemetry?)?=nil) throws ->ROBVisualGraspVerifier.Sample {
        switch projection {
        case .registered(let registration):
            return try measuredSample(frame:frame,model:model,gatewayArm:gatewayArm,registration:registration,
                scope:scope,identity:identity,viewIdentity:viewIdentity,allowReferenceImage:allowReferenceImage)
        case .visualTrial(let value):
            try validateVisualProjection(value,scope:scope,frame:frame,model:model)
            guard gatewayArm == (model.physicalSide == "right" ? "left" : "right"),
                  let feedback=feedbackForFrame?(frame) ?? ROBAmberGatewayClient.shared.telemetry(forArm:gatewayArm),
                  feedback.effectiveSampleAgeMilliseconds <= (feedbackForFrame == nil ? 150:700),feedback.sampleAgeAtReceiptMilliseconds<=250,
                  feedback.positionsRadians.count==7,feedback.positionsRadians.allSatisfy({$0.doubleValue.isFinite}),
                  feedback.statuses.count==7,feedback.statuses.allSatisfy({$0.intValue==2}),
                  let k=frame.intrinsics,let depth=frame.depth,
                  let tool=model.toolPosition(model.positions(vendorLeft:feedback.positionsRadians.map(\.doubleValue))) else {
                throw ROBGhostMotionError.blocked("Unmeasured visual-trial inspection lost its fresh measured position-hold feedback.")
            }
            let optical=simd_inverse(value.cameraToModel)*SIMD4(tool.x,tool.y,tool.z,1)
            guard optical.z>0 else {throw ROBGhostMotionError.blocked("Measured tool is behind the estimated grasp camera.")}
            let point=ROBVisualGraspVerifier.Point(x:(k.fx*optical.x/optical.z+k.cx)/Double(depth.width-1),
                y:(k.fy*optical.y/optical.z+k.cy)/Double(depth.height-1))
            return try ROBArmRoutineVision.shared.makeVisualGraspSample(frame:frame,fixedViewIdentity:viewIdentity,targetIdentity:identity,
                measuredToolCenter:point,measuredToolDepthMeters:optical.z,
                toolFeedbackCapturedAtMilliseconds:Date().timeIntervalSince1970*1000-feedback.effectiveSampleAgeMilliseconds,
                allowReferenceImage:allowReferenceImage)
        }
    }
    private static func measuredSample(frame:ROBArmRoutineVision.Frame,model:ROBGhostRobotModel,gatewayArm:String,
        registration:ROBFixedHeadRegistration,scope:ROBFixedHeadRegistrationScope,identity:String,viewIdentity:String,
        allowReferenceImage:Bool=false) throws ->ROBVisualGraspVerifier.Sample {
        let current=try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame)
        guard registration.matches(current),current==scope,
              try ROBFixedHeadCalibrationWindowController.shared.registration(model:model,frame:frame)?.id==registration.id,
              let feedback=ROBAmberGatewayClient.shared.telemetry(forArm:gatewayArm),feedback.effectiveSampleAgeMilliseconds<=150,
              feedback.positionsRadians.count==7,feedback.positionsRadians.allSatisfy({$0.doubleValue.isFinite}),
              feedback.statuses.count==7,feedback.statuses.allSatisfy({$0.intValue==2}),
              let k=frame.intrinsics,let depth=frame.depth,
              let tool=model.toolPosition(model.positions(vendorLeft:feedback.positionsRadians.map(\.doubleValue))),
              registration.validRobotVolume.contains(tool) else {
            throw ROBGhostMotionError.blocked("Fixed-view grasp inspection lost its registration, measured position hold or live tool feedback.")
        }
        let optical=simd_inverse(registration.cameraToRobot)*SIMD4(tool.x,tool.y,tool.z,1)
        guard optical.z>0 else {throw ROBGhostMotionError.blocked("Measured tool is behind the grasp camera.")}
        let point=ROBVisualGraspVerifier.Point(x:(k.fx*optical.x/optical.z+k.cx)/Double(depth.width-1),
            y:(k.fy*optical.y/optical.z+k.cy)/Double(depth.height-1))
        let feedbackTime=Date().timeIntervalSince1970*1000-feedback.effectiveSampleAgeMilliseconds
        return try ROBArmRoutineVision.shared.makeVisualGraspSample(frame:frame,fixedViewIdentity:viewIdentity,targetIdentity:identity,
            measuredToolCenter:point,measuredToolDepthMeters:optical.z,toolFeedbackCapturedAtMilliseconds:feedbackTime,
            allowReferenceImage:allowReferenceImage)
    }
}
