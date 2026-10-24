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
        let registration:ROBFixedHeadRegistration
        let scope:ROBFixedHeadRegistrationScope
        let targetIdentity:String
        let viewIdentity:String
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
        let optical=simd_inverse(registration.cameraToRobot)*SIMD4(can.point.x,can.point.y,can.point.z,1)
        guard let k=frame.intrinsics,let depth=frame.depth,optical.z>0 else {
            throw ROBGhostMotionError.blocked("The selected can is outside the registered grasp camera view.")
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
        let identity="can-\(can.sequence)-\(registration.id)"
        let box=ROBVisualGraspVerifier.Box(left:detection.box[0],top:detection.box[1],right:detection.box[2],bottom:detection.box[3])
        guard let currentFrame=ROBArmRoutineVision.shared.snapshot()["face"] else {
            throw ROBGhostMotionError.blocked("No advancing grasp camera image is available before closure.")
        }
        let reference=try measuredSample(frame:frame,model:model,gatewayArm:gatewayArm,registration:registration,
            scope:scope,identity:identity,viewIdentity:viewIdentity,allowReferenceImage:true)
        let sample=try measuredSample(frame:currentFrame,model:model,gatewayArm:gatewayArm,registration:registration,
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
            depth:{currentDepth.distanceMillimeters(x:$0,y:$1)},view:can.view,model:model,cameraToRobot:registration.cameraToRobot) else {
            throw ROBGhostMotionError.blocked("Current can geometry is occluded or depth is ambiguous. Holding before closure.")
        }
        let displacement=simd_distance(SIMD3(measuredCan.middle[0],measuredCan.middle[1],measuredCan.middle[2]),can.point)
        guard displacement<=0.012 else {throw TargetMoved.displacement(displacement)}
        let verifier=try ROBVisualGraspVerifier(baseline:sample,targetBox:currentBox,nowMilliseconds:Date().timeIntervalSince1970*1000)
        try check()
        return Context(verifier:verifier,registration:registration,scope:scope,targetIdentity:identity,viewIdentity:viewIdentity)
    }
    static func verifyAfterLift(context:Context,model:ROBGhostRobotModel,gatewayArm:String,
        check:() throws ->Void) async throws ->ROBVisualGraspVerifier.Evidence {
        var verifier=context.verifier
        let deadline=ProcessInfo.processInfo.systemUptime+4
        while ProcessInfo.processInfo.systemUptime<deadline {
            try check();try Task.checkCancellation()
            if let frame=ROBArmRoutineVision.shared.snapshot()["face"],frame.sequence>verifier.evidence.lastSequence {
                let sample=try measuredSample(frame:frame,model:model,gatewayArm:gatewayArm,registration:context.registration,
                    scope:context.scope,identity:context.targetIdentity,viewIdentity:context.viewIdentity)
                let result=verifier.observe(sample,nowMilliseconds:Date().timeIntervalSince1970*1000)
                if result.verdict != .collecting {try check();return result}
            }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        try check();return verifier.finish()
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
