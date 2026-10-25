import Foundation
import simd

/// Connects fixed-view raw pixels to measured feedback. It contains no motion,
/// approval, jaw command, target correction or camera-pose setter.
@MainActor enum ROBRecyclingVisualInspection {
    enum TargetMoved:LocalizedError {
        case displacement(Double)
        var errorDescription:String? {
            if case .displacement(let distance)=self {return "The can moved \(Int((distance*1000).rounded())) mm from the reviewed grasp. Holding before closure; reacquire and review a new reach."}
            return nil
        }
    }
    struct Context {
        var verifier:ROBVisualGraspVerifier
        let projection:Projection
        let scope:ROBFixedHeadRegistrationScope
        let targetIdentity:String
        let viewIdentity:String
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
              can.registrationID==registration.id else {
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
    /// four-can receipt. This inspection never creates registration or motion.
    static func beginVisualCalibrationTrial(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,
        map:ROBWorkspaceCollisionSnapshot,trial:ROBWorkspaceVisualCalibrationTrial,gatewayArm:String,
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
            identity:"can-\(can.sequence)-unmeasured-\(trial.receiptID)",viewIdentity:viewIdentity,check:check)
    }

    private static func beginContext(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,gatewayArm:String,
        observation:ROBWorkspaceObservation,frame:ROBArmRoutineVision.Frame,projection:Projection,
        scope:ROBFixedHeadRegistrationScope,cameraToModel:simd_double4x4,identity:String,viewIdentity:String,
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
            scope:scope,identity:identity,viewIdentity:viewIdentity,allowReferenceImage:true)
        let sample=try projectionSample(frame:currentFrame,model:model,gatewayArm:gatewayArm,projection:projection,
            scope:scope,identity:identity,viewIdentity:viewIdentity)
        guard let currentBox=ROBVisualGraspVerifier.confirmTargetContinuity(reference:reference,targetBox:box,current:sample,
            nowMilliseconds:Date().timeIntervalSince1970*1000),let currentDepth=currentFrame.depth,let currentK=currentFrame.intrinsics else {
            throw ROBGhostMotionError.blocked("The can moved or was occluded between detection and the current grasp image. Holding before closure.")
        }
        let currentDetection=ROBWorkspaceDetection(visible:true,confidence:detection.confidence,
            box:[currentBox.left,currentBox.top,currentBox.right,currentBox.bottom],
            aim:[currentBox.center.x,currentBox.center.y],depthPoint:[currentBox.center.x,currentBox.center.y],
            confidenceThreshold:detection.confidenceThreshold)
        guard let measuredCan=ROBWorkspaceCanSections.measure(detection:currentDetection,width:currentDepth.width,height:currentDepth.height,
            fx:currentK.fx,fy:currentK.fy,cx:currentK.cx,cy:currentK.cy,
            depth:{currentDepth.distanceMillimeters(x:$0,y:$1)},view:can.view,model:model,cameraToRobot:cameraToModel) else {
            throw ROBGhostMotionError.blocked("Current can geometry is occluded or depth is ambiguous. Holding before closure.")
        }
        let displacement=simd_distance(SIMD3(measuredCan.middle[0],measuredCan.middle[1],measuredCan.middle[2]),can.point)
        guard displacement<=0.012 else {throw TargetMoved.displacement(displacement)}
        let verifier=try ROBVisualGraspVerifier(baseline:sample,targetBox:currentBox,nowMilliseconds:Date().timeIntervalSince1970*1000)
        try check()
        return Context(verifier:verifier,projection:projection,scope:scope,targetIdentity:identity,viewIdentity:viewIdentity)
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
                if result.verdict != .collecting {try check();return labelled(result,projection:context.projection)}
            }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        try check();return labelled(verifier.finish(),projection:context.projection)
    }
    private static func labelled(_ value:ROBVisualGraspVerifier.Evidence,projection:Projection) ->ROBVisualGraspVerifier.Evidence {
        guard case .visualTrial = projection else {return value}
        var result=value
        result.reason += " Tool comparison uses estimated-camera projection of measured joint feedback; camera alignment and possession are not measured."
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
        guard let receipt=broker.activeLocalRecyclingApprovalEvidence,
              let summary=receipt["summary"] as? String,
              broker.authorizesLocalRecyclingVisualCalibrationTrial(summary:summary,arm:model.physicalSide),
              receipt["receiptID"] as? String==trial.receiptID,receipt["receiptSHA256"] as? String==trial.receiptSHA256,
              receipt["appSessionID"] as? String==trial.appSessionID,receipt["command"] as? String==trial.command,
              receipt["pendingID"] as? String==value.pendingID,
              receipt["summarySHA256"] as? String==trial.summarySHA256,
              receipt["contextIdentity"] as? String==trial.authorizationContextIdentity,
              (receipt["canCount"] as? NSNumber)?.intValue==4,
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
        allowReferenceImage:Bool=false) throws ->ROBVisualGraspVerifier.Sample {
        switch projection {
        case .registered(let registration):
            return try measuredSample(frame:frame,model:model,gatewayArm:gatewayArm,registration:registration,
                scope:scope,identity:identity,viewIdentity:viewIdentity,allowReferenceImage:allowReferenceImage)
        case .visualTrial(let value):
            try validateVisualProjection(value,scope:scope,frame:frame,model:model)
            guard gatewayArm == (model.physicalSide == "right" ? "left" : "right"),
                  let feedback=ROBAmberGatewayClient.shared.telemetry(forArm:gatewayArm),feedback.effectiveSampleAgeMilliseconds<=150,
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
