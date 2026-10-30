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
              ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,actualFrame:.init(cameraGeneration:frame.cameraGeneration,
                actualDeviceMXID:frame.intrinsics?.runtimeCalibration?.actualDeviceMXID,
                runtimeCalibrationIdentity:frame.intrinsics?.runtimeCalibration?.identity,
                cameraServiceSourceSHA256:frame.intrinsics?.cameraServiceSourceSHA256,scope:scope,
                inertialJSON:(frame.intrinsics?.inertial).flatMap{try?JSONEncoder().encode($0)})),
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
        var canAppearanceSeed:ROBVisualGraspVerifier.AppearanceSeed?
        var cameraCollisionAdvisoryTrial:ROBWorkspaceVisualCalibrationTrial?
        var nativeObservedSupport:ROBVisualGraspVerifier.ObservedSupport?
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
        let handsClear:Bool
        let cameraGeneration:UUID
        let sourceIdentity:String
    }
    private static let servoImageContext=CIContext(options:[.useSoftwareRenderer:true])

    private static func servoGrayscale(_ bytes:[UInt8])->[UInt8] {
        var gray:[UInt8]=[]
        gray.reserveCapacity(bytes.count/3)
        var index:Int=0
        while index+2<bytes.count {
            let red:Int=Int(bytes[index])*299
            let green:Int=Int(bytes[index+1])*587
            let blue:Int=Int(bytes[index+2])*114
            let luminance:Int=(red+green+blue)/1000
            gray.append(UInt8(luminance))
            index+=3
        }
        return gray
    }


    private static func incrementalCanViewIdentity(scope:ROBFixedHeadRegistrationScope,
        trial:ROBWorkspaceVisualCalibrationTrial,frame:ROBArmRoutineVision.Frame)throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return "observed-jaw-servo:"+trial.receiptID+":"+ROBGhostRobotModel.hash(try encoder.encode(scope))+":"+(try visualFrameContract(frame))
    }

    /// Capture pixels and their real held feedback BEFORE detector inference.
    /// This retained appearance seed never serves as a live servo observation.
    private static func captureIncrementalCanAppearance(frame:ROBArmRoutineVision.Frame,model:ROBGhostRobotModel,
        trial:ROBWorkspaceVisualCalibrationTrial,
        feedbackForFrame:(ROBArmRoutineVision.Frame)->ROBAmberGatewayTelemetry?,check:()throws->Void)throws->ROBGripperVisualServo.Frame {
        try check()
        guard let feedback=feedbackForFrame(frame),feedback.sampleAgeAtReceiptMilliseconds<=ROBArmFeedbackTiming.maximumAgeMilliseconds else {
            throw ROBGhostMotionError.blocked("Pre-approach can appearance needs its actual exposure-matched held feedback.")
        }
        let scope=try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:frame)
        let view=try incrementalCanViewIdentity(scope:scope,trial:trial,frame:frame)
        let now=Date().timeIntervalSince1970*1000
        return try ROBArmRoutineVision.shared.makeGripperVisualServoFrame(frame:frame,scopeIdentity:view,
            jointPositions:feedback.positionsRadians.map(\.doubleValue),jointCapturedAtMilliseconds:now-feedback.effectiveSampleAgeMilliseconds,
            poseHeldDuringCapture:true,openingCommandAtMilliseconds:nil,nowMilliseconds:now,
            cameraCollisionAdvisoryTrial:trial.usesOperatorClearedCameraCollisionAdvisory ? trial:nil)
    }

    static func beginIncrementalVisualServo(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,
        map:ROBWorkspaceCollisionSnapshot,trial:ROBWorkspaceVisualCalibrationTrial,gatewayArm:String,
        feedbackForFrame:@escaping(ROBArmRoutineVision.Frame)->ROBAmberGatewayTelemetry?,
        check:() throws->Void) async throws->ServoContext {
        try check()
        var capturedAppearance:ROBGripperVisualServo.Frame?
        let(observation,reference)=try await ROBArmRoutineVision.shared.observeWorkspace(onCaptured:{frame in
            capturedAppearance=try captureIncrementalCanAppearance(frame:frame,model:model,trial:trial,
                feedbackForFrame:feedbackForFrame,check:check)
        })
        try check()
        let controller=ROBFixedHeadCalibrationWindowController.shared,scope=try controller.scope(model:model,frame:reference)
        let neck=controller.readNeck?() ?? [:]
        guard can.registrationID==nil,gatewayArm==(model.physicalSide=="right" ? "left":"right"),
              ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,actualFrame:.init(cameraGeneration:reference.cameraGeneration,
                actualDeviceMXID:reference.intrinsics?.runtimeCalibration?.actualDeviceMXID,
                runtimeCalibrationIdentity:reference.intrinsics?.runtimeCalibration?.identity,
                cameraServiceSourceSHA256:reference.intrinsics?.cameraServiceSourceSHA256,scope:scope,
                inertialJSON:(reference.intrinsics?.inertial).flatMap{try?JSONEncoder().encode($0)})),
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
        let view=try incrementalCanViewIdentity(scope:scope,trial:trial,frame:reference)
        let baseline=ServoBaseline(projection:.visualTrial(projection),scope:scope,targetIdentity:"can-\(can.sequence)-\(trial.receiptID)",viewIdentity:view)
        let result=ServoContext(baseline:baseline,can:can,model:model,box:detections[0].box)
        result.cameraCollisionAdvisoryTrial=trial.usesOperatorClearedCameraCollisionAdvisory ? trial:nil
        guard let seedPixels=capturedAppearance,seedPixels.sequence==reference.sequence,
              seedPixels.capturedAtMilliseconds==reference.capturedAt,seedPixels.scopeIdentity==view else {
            throw ROBGhostMotionError.blocked("The detector result lost its exact originally captured can appearance and held feedback.")
        }
        // The seed retains only actual RGB appearance; its exposure-matched
        // feedback never substitutes for current observed finger evidence.
        let seedRGB=Array(seedPixels.rgb)
        let seedGray=servoGrayscale(seedRGB)
        let seedBox=detections[0].box
        result.canAppearanceSeed = .init(sequence:reference.sequence,capturedAtMilliseconds:reference.capturedAt,
            cameraGeneration:reference.cameraGeneration,fixedViewIdentity:view,targetIdentity:baseline.targetIdentity,
            sourceIdentity:projection.frameContractIdentity,width:seedPixels.width,height:seedPixels.height,gray:seedGray,
            canBox:.init(left:seedBox[0],top:seedBox[1],right:seedBox[2],bottom:seedBox[3]),
            synchronizedRGBDepth:true,handsClear:reference.handsClear,cameraCollisionAdvisory:trial.usesOperatorClearedCameraCollisionAdvisory)

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
              feedback.sampleAgeAtReceiptMilliseconds<=ROBArmFeedbackTiming.maximumAgeMilliseconds,currentFeedback.effectiveSampleAgeMilliseconds<=ROBArmFeedbackTiming.maximumAgeMilliseconds,
              currentFeedback.effectiveGripperFeedbackAgeMilliseconds<=ROBArmFeedbackTiming.maximumAgeMilliseconds,
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
        let geometryAssumed=context.can.sections?.shapePriorEvidence != nil
        var targetDepth:Double?
        if requireTableSupport {
            let d=ROBWorkspaceDetection(visible:true,confidence:Double(tracked.confidence),box:box,
                aim:[(box[0]+box[2])/2,(box[1]+box[3])/2],depthPoint:[(box[0]+box[2])/2,(box[1]+box[3])/2],confidenceThreshold:0.35)
            guard let original=context.can.sections,let k=frame.intrinsics,let depth=frame.depth,
                  let sections=original.reacquireForVisualServo(measured:{
                      ROBWorkspaceCanSections.measure(detection:d,width:depth.width,height:depth.height,
                          fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,depth:{depth.distanceMillimeters(x:$0,y:$1)},
                          view:context.can.view,model:model,cameraToRobot:projection.cameraToModel)
                  },assumed:{
                      ROBWorkspaceSearch.shared.localCanShapePrior(detection:d,allCanDetections:[d],frame:frame,
                          view:context.can.view,model:model,cameraToRobot:projection.cameraToModel).sections
                  }) else {
                throw ROBGhostMotionError.blocked(geometryAssumed
                    ? "Current can/table silhouette no longer supports the assumed middle-grasp geometry."
                    : "Current can depth bands no longer support the measured middle-grasp cylinder; no assumed replacement or grip was sent.")
            }
            let middle=SIMD3(sections.middle[0],sections.middle[1],sections.middle[2])
            let displacement=simd_distance(middle,context.can.point)
            guard displacement<=0.012 else {throw TargetMoved.displacement(displacement)}
            let optical=simd_inverse(projection.cameraToModel)*SIMD4(middle.x,middle.y,middle.z,1)
            targetDepth=optical.z>0 ? optical.z:nil
        }
        var pixels=try ROBArmRoutineVision.shared.makeGripperVisualServoFrame(frame:frame,scopeIdentity:context.baseline.viewIdentity,
            jointPositions:feedback.positionsRadians.map(\.doubleValue),jointCapturedAtMilliseconds:historicalTime,
            poseHeldDuringCapture:true,openingCommandAtMilliseconds:openingCommandAtMilliseconds,nowMilliseconds:now,cameraCollisionAdvisoryTrial:context.cameraCollisionAdvisoryTrial)
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

        let target=ROBGripperVisualServo.Target(id:context.baseline.targetIdentity,boxNormalized:box,geometryAssumed:geometryAssumed,
            assumedDepthMeters:geometryAssumed ? targetDepth:nil,
            assumedDiameterMeters:geometryAssumed ? context.can.sections?.diameterMeters:nil,
            measuredDepthMeters:geometryAssumed ? nil:targetDepth)
        let decision=context.controller.update(frame:pixels,target:target,searchROI:roi,nowMilliseconds:now,observationOnly:!requireTableSupport)
        var evidence:[String:Any]=["sequence":NSNumber(value:frame.sequence),"captured_at_ms":frame.capturedAt,
            "can_box":box,"status":String(describing:decision.status),"reason":decision.reason,
            "joint_positions":feedback.positionsRadians.map(\.doubleValue),"joint_captured_at_ms":historicalTime,
            "diagnostics":decision.diagnostics.mapValues{value->Any in if value.isFinite{return value};return NSNull()},"jaw_location_source":"observed_pixels_only_FK_ROI_is_not_a_measurement",
            "geometry_assumed":geometryAssumed,"ready_to_grip_image_alignment_only":decision.readyToGrip]
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
        return ServoObservation(frame:pixels,decision:decision,canBox:box,handsClear:frame.handsClear,cameraGeneration:frame.cameraGeneration,sourceIdentity:try visualFrameContract(frame))
    }

    static func validateNativeObservedSupportContext(_ context:ServoContext,model:ROBGhostRobotModel)throws {
        guard context.nativeObservedSupport != nil,case .visualTrial(let projection)=context.baseline.projection,
              let frame=ROBArmRoutineVision.shared.snapshot()["face"] else {
            throw ROBGhostMotionError.blocked("No live native observed-finger support/source context.")
        }
        try validateVisualProjection(projection,scope:context.baseline.scope,frame:frame,model:model)
    }

    static func verifyIncrementalServoLift(context:ServoContext,beforeLift:ServoObservation,model:ROBGhostRobotModel,
        heldSinceMilliseconds:Double,observe:() async throws->ServoObservation,check:()throws->Void) async throws->ROBVisualGraspVerifier.Evidence {
        context.nativeObservedSupport=nil
        let base=beforeLift.frame,box=beforeLift.canBox
        var result=ROBVisualGraspVerifier.Evidence(verdict:.collecting,reason:"Waiting for observed jaw/can lift co-motion.",samples:0,
            firstSequence:base.sequence,lastSequence:base.sequence,cameraGeneration:context.baseline.scope.cameraGeneration,
            fixedViewIdentity:context.baseline.viewIdentity,targetIdentity:context.baseline.targetIdentity,
            targetBox:.init(left:box[0],top:box[1],right:box[2],bottom:box[3]),
            baselineCapturedAtMilliseconds:base.capturedAtMilliseconds,lastCapturedAtMilliseconds:base.capturedAtMilliseconds)
        result.toolEvidenceSource="independent_observed_fingers"
        func input(_ value:ServoObservation)throws->ROBVisualGraspVerifier.ObservedJawInput {
            let f=value.frame
            guard let jaw=value.decision.observation,jaw.centerPixels.count==2,jaw.tipsPixels.count==2,
                  jaw.tipsPixels.allSatisfy({$0.count==2}),value.canBox.count==4,
                  f.rgb.count==f.width*f.height*3,f.depthMillimeters.count==f.width*f.height,
                  f.poseHeldDuringCapture,abs(f.jointCapturedAtMilliseconds-f.capturedAtMilliseconds)<=150,
                  value.cameraGeneration==context.baseline.scope.cameraGeneration,
                  case .visualTrial(let projection)=context.baseline.projection,
                  value.sourceIdentity==projection.frameContractIdentity else {
                throw ROBVisualGraspVerifier.Unavailable.evidence("The actual observed-finger RGB-D capture/source is unavailable.")
            }
            let bytes=Array(f.rgb)
            let gray=servoGrayscale(bytes)
            return .init(sequence:f.sequence,capturedAtMilliseconds:f.capturedAtMilliseconds,cameraGeneration:value.cameraGeneration,
                fixedViewIdentity:f.scopeIdentity,targetIdentity:context.baseline.targetIdentity,sourceIdentity:value.sourceIdentity,
                width:f.width,height:f.height,gray:gray,depthMeters:f.depthMillimeters.map{Float($0)/1000},fx:f.fx,fy:f.fy,cx:f.cx,cy:f.cy,
                synchronizedRGBDepth:true,handsClear:value.handsClear,
                jawCenterPixels:.init(x:jaw.centerPixels[0],y:jaw.centerPixels[1]),
                fingerTipsPixels:jaw.tipsPixels.map{.init(x:$0[0],y:$0[1])},jawSequence:jaw.sequence,
                jawCapturedAtMilliseconds:jaw.capturedAtMilliseconds,jawScopeIdentity:jaw.scopeIdentity,
                jawConfidence:jaw.confidence,jawEvidenceKind:jaw.evidenceKind,
                canBox:.init(left:value.canBox[0],top:value.canBox[1],right:value.canBox[2],bottom:value.canBox[3]),
                cameraCollisionAdvisory:context.cameraCollisionAdvisoryTrial?.usesOperatorClearedCameraCollisionAdvisory==true)
        }
        var verifier:ROBVisualGraspVerifier.ObservedJawVerifier
        do {
            guard let appearance=context.canAppearanceSeed else{throw ROBVisualGraspVerifier.Unavailable.evidence("No independent pre-approach can appearance was retained.")}
            verifier=try .init(baseline:input(beforeLift),appearance:appearance,nowMilliseconds:Date().timeIntervalSince1970*1000)
        }
        catch {result.verdict = .unknown;result.reason=error.localizedDescription;return result}
        let end=ProcessInfo.processInfo.systemUptime+4
        while ProcessInfo.processInfo.systemUptime<end {
            try check();try Task.checkCancellation()
            do {
                let sample=try await observe()
                guard sample.frame.capturedAtMilliseconds>=heldSinceMilliseconds else {continue}
                result=try verifier.observe(input(sample),nowMilliseconds:Date().timeIntervalSince1970*1000)
            } catch {
                try check();result.verdict = .unknown;result.reason="Independent can/finger verification unavailable: "+error.localizedDescription;return result
            }
            if result.verdict != .collecting {
                if result.verdict == .supported {context.nativeObservedSupport=verifier.nativeSupportedObservation}
                return result
            }
        }
        return verifier.finish()
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
              ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,actualFrame:.init(cameraGeneration:frame.cameraGeneration,
                actualDeviceMXID:frame.intrinsics?.runtimeCalibration?.actualDeviceMXID,
                runtimeCalibrationIdentity:frame.intrinsics?.runtimeCalibration?.identity,
                cameraServiceSourceSHA256:frame.intrinsics?.cameraServiceSourceSHA256,scope:scope,
                inertialJSON:(frame.intrinsics?.inertial).flatMap{try?JSONEncoder().encode($0)})),
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
                  feedback.effectiveSampleAgeMilliseconds <= (feedbackForFrame == nil ? 150:700),feedback.sampleAgeAtReceiptMilliseconds<=ROBArmFeedbackTiming.maximumAgeMilliseconds,
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
