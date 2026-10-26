import Foundation
import simd

/// Synthetic inert provenance and geometry tests; never loads real robot data.
extension ROBNeckRGBPoseDisplayFixture {
    static func gravityPitchFixture(model:ROBGhostRobotModel,base:[String:Any],temporary:URL,restore:URL)throws {
        let activation=temporary.appendingPathComponent("gravity-activation.json"),proof=temporary.appendingPathComponent("gravity-proof.json")
        var a=base;a.removeValue(forKey:"estimatedGravityPitchRefinement");a.removeValue(forKey:"operatorPanCalibration")
        a.removeValue(forKey:"bellyFloorDisplayReference");a["usePhotoHardwareOpticalOrigin"]=true
        try write(a,to:activation);setenv("ROB_NECK_RGB_DISPLAY_PROFILE",activation.path,1)
        defer{setenv("ROB_NECK_RGB_DISPLAY_PROFILE",restore.path,1)}
        let targets=[(6000,6011,5300),(6000,6411,5650),(6000,6411,5800),(6167,6411,5800)]
        let baseline=targets.map{ROBNeckRGBPoseDisplay.pose(model:model,panTarget:$0.0,lowerTarget:$0.1,upperTarget:$0.2)!}
        let oldPID=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)!,body=ROBFixedHeadBodyMotionIdentity.currentIdentity
        let generations=targets.map{_ in UUID()},service=String(repeating:"c",count:64),factory=String(repeating:"a",count:64)
        let effective=String(repeating:"b",count:64),policy=String(repeating:"d",count:64),device="synthetic-mxid",sdk="fixture-1"
        let runtime:[String:Any]=["schemaVersion":1,"cameraRole":"face","actualDeviceMXID":device,"sdkVersion":sdk,
            "factoryEEPROMSHA256":factory,"effectiveRuntimeCalibrationSHA256":effective,"stereoPolicySHA256":policy,
            "candidateSHA256":NSNull(),"profileSHA256":NSNull()]
        let runtimeID=hash(Data(["runtime-camera-calibration-v1",device,"face",sdk,factory,effective,policy,"-","-"].joined(separator:"\n").utf8))
        let delta = -0.11,rotation=simd_double4x4(simd_quatd(angle:delta,axis:SIMD3(1,0,0)))
        var captures:[[String:Any]]=[],documents:[[String:Any]]=[],paths:[URL]=[]
        for (index,target) in targets.enumerated() {
            let dir=temporary.appendingPathComponent("synthetic-gravity-\(index)")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let input=dir.appendingPathComponent("capture-input.json")
            let scope=ROBFixedHeadRegistrationScope(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                cameraGeneration:generations[index],gatewaySessionGeneration:1,displayCorrectionIdentity:"fixture:body:"+body,
                panTarget:target.0,lowerTarget:target.1,upperTarget:target.2,intrinsicsIdentity:String(repeating:"e",count:64))
            let projected=baseline[index].provisionalCameraToModel*rotation
            let g4=simd_inverse(projected)*SIMD4<Double>(0,0,9.81,0),g=[g4.x,g4.y,g4.z]
            var frames:[[String:Any]]=[]
            for frame in 0..<3 {
                let depth=Data(repeating:UInt8(1+index*3+frame),count:16*16*2),name="frame-\(frame).depth-u16le"
                try depth.write(to:dir.appendingPathComponent(name))
                let latest=UInt64(1_000_000_000+index*100_000_000+frame*10_000_000)
                let imu:[String:Any]=["sensor":"synthetic-inertial-fixture","stationary":true,"axes":"sensor_native",
                    "gravity_source":"stationary_accelerometer_mean","gravity_mps2":g,"gravity_std_mps2":[0.01,0.01,0.01],
                    "gyro_rad_s":[0.0,0.0,0.0],"imu_to_rgb_rotation":[1.0,0,0,0,1,0,0,0,1],"sample_count":30,
                    "window_milliseconds":300.0,"age_milliseconds":1.0,"latest_timestamp_ns":latest,"reference_timestamp_ns":latest+1_000_000]
                frames.append(["sequence":frame+1,"capturedAtMilliseconds":1000.0+Double(frame),"cameraGeneration":generations[index].uuidString,
                    "width":16,"height":16,"depthPath":name,"captureSHA256":hash(depth),"rgbOutputUndistorted":true,
                    "depthRGBGeometryCorrespondence":["status":"matched"],"runtimeCalibration":runtime,
                    "runtimeCalibrationIdentity":runtimeID,"cameraServiceSourceSHA256":service,"imu":imu])
            }
            let document:[String:Any]=["schemaVersion":1,"cameraRole":"face","scope":try JSONSerialization.jsonObject(with:JSONEncoder().encode(scope)),"frames":frames]
            try write(document,to:input);documents.append(document);paths.append(input)
            captures.append(["role":index<3 ? "training":"held_out","captureInputPath":input.path,"captureInputSHA256":hash(try Data(contentsOf:input))])
        }
        let evidence:[String:Any]=["schemaVersion":1,"kind":"estimated_stationary_imu_optical_x_pitch_refinement",
            "method":"mean_training_post_optical_x_preserve_origin_image_right_v1","modelID":model.modelID,"referenceID":model.referenceID,
            "geometryID":model.geometryID,"mappingID":model.selectedMappingID,"oldEstimatedCameraProjectionIdentity":oldPID,
            "bodyMotionIdentity":body,"activeCameraGeneration":generations.last!.uuidString,"cameraRole":"face","actualDeviceMXID":device,
            "runtimeCalibrationIdentity":runtimeID,"cameraServiceSourceSHA256":service,"deltaRadians":delta,
            "registrationVerified":false,"armMotionAuthority":false,"rawDepthCorrected":false,"modelBaseUpAssumed":true,
            "opticalOriginPriorUnchanged":true,"imageRightHeadingPriorUnchanged":true,"captures":captures]
        func install(_ value:[String:Any])throws {
            try write(value,to:proof);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:proof.path)
            a["estimatedGravityPitchRefinement"]=["evidencePath":proof.path,"evidenceSHA256":hash(try Data(contentsOf:proof))]
            try write(a,to:activation)
        }
        func current()->ROBNeckRGBPoseDisplay.Pose? {ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6167,lowerTarget:6411,upperTarget:5800)}
        func rejects(_ label:String) {
            precondition(current()==nil && ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==nil,label)
            precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations.last!,
                runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service),"Invalid refinement retained its source contract: "+label)
        }
        try install(evidence)
        let refinedID=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)!
        precondition(refinedID != oldPID)
        let otherSide=try ROBGhostRobotModel(directory:model.directory,physicalSide:"left")
        precondition(otherSide.selectedMappingID != model.selectedMappingID)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:otherSide)==refinedID,"Shared head refinement rejected the other arm's model")
        precondition(ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:otherSide,cameraGeneration:generations.last!,
            runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service))
        for target in targets {
            let left=ROBNeckRGBPoseDisplay.pose(model:otherSide,panTarget:target.0,lowerTarget:target.1,upperTarget:target.2)!
            let right=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:target.0,lowerTarget:target.1,upperTarget:target.2)!
            precondition(left.provisionalCameraToModel==right.provisionalCameraToModel && left.headFrames==right.headFrames &&
                left.hardwareFrames==right.hardwareFrames,"Arm choice changed the shared head transform")
        }
        precondition(model.selectedMappingID != otherSide.selectedMappingID,"Head refinement changed arm mapping identities")
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==refinedID)
        // A legal alternate mapping must still agree with every recorded
        // source scope. Recognition is not permission to relabel captures.
        var mismatchedMapping=evidence;mismatchedMapping["mappingID"]=otherSide.selectedMappingID
        try install(mismatchedMapping);rejects("Legal but uncaptured mapping accepted")
        try install(evidence)
        // Reverse direction: genuinely LEFT-labelled synthetic captures also
        // serve the same shared head, without manufacturing RIGHT arm FK.
        var leftCaptures=captures
        for i in documents.indices {
            var document=documents[i],scope=document["scope"]as![String:Any]
            scope["mappingID"]=otherSide.selectedMappingID;document["scope"]=scope
            try write(document,to:paths[i]);leftCaptures[i]["captureInputSHA256"]=hash(try Data(contentsOf:paths[i]))
        }
        var leftEvidence=evidence;leftEvidence["mappingID"]=otherSide.selectedMappingID;leftEvidence["captures"]=leftCaptures
        try install(leftEvidence)
        let leftSourceID=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:otherSide)!
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==leftSourceID)
        for i in documents.indices {try write(documents[i],to:paths[i])}
        try install(evidence)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==refinedID)
        for (i,target) in targets.enumerated() {
            let pose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:target.0,lowerTarget:target.1,upperTarget:target.2)!,before=baseline[i]
            precondition(pose.provisionalCameraToModel.columns.0==before.provisionalCameraToModel.columns.0 &&
                pose.provisionalCameraToModel.columns.3==before.provisionalCameraToModel.columns.3,"Gravity changed image-right/yaw heading or origin")
            let expected=before.provisionalCameraToModel*rotation
            for column in 0..<4 {precondition(close(pose.provisionalCameraToModel[column],expected[column]))}
            precondition(pose.cameraToModel==before.cameraToModel && pose.headFrames==before.headFrames && pose.hardwareFrames==before.hardwareFrames &&
                pose.modelToDisplay==before.modelToDisplay && pose.headDepthDisplayLiftMeters==before.headDepthDisplayLiftMeters &&
                pose.robotModelDisplayLiftMeters==before.robotModelDisplayLiftMeters && !pose.hasDepthProjectionAuthority)
        }
        precondition(ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations.last!,runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service))
        precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations[0],runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service))
        precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations.last!,runtimeCalibrationIdentity:nil,cameraServiceSourceSHA256:service))
        precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations.last!,runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:nil))
        for key in ["kind","method","modelID","referenceID","geometryID","mappingID","oldEstimatedCameraProjectionIdentity","bodyMotionIdentity",
                    "activeCameraGeneration","cameraRole","actualDeviceMXID","runtimeCalibrationIdentity","cameraServiceSourceSHA256","deltaRadians",
                    "registrationVerified","armMotionAuthority","rawDepthCorrected","modelBaseUpAssumed","opticalOriginPriorUnchanged","imageRightHeadingPriorUnchanged"] {
            var bad=evidence
            if key=="deltaRadians" {bad[key]=delta+0.001}
            else if ["registrationVerified","armMotionAuthority","rawDepthCorrected"].contains(key){bad[key]=true}
            else if ["modelBaseUpAssumed","opticalOriginPriorUnchanged","imageRightHeadingPriorUnchanged"].contains(key){bad[key]=false}
            else{bad[key]="wrong"}
            try install(bad);rejects("Changed proof field: "+key)
        }
        try install(evidence)
        let validProof=try Data(contentsOf:proof)
        let validActivation=try Data(contentsOf:activation)
        try Data("malformed requested activation".utf8).write(to:activation)
        rejects("Malformed requested activation accepted source provenance")
        try validActivation.write(to:activation);precondition(current() != nil)
        for missing in [false,true] {
            if missing {try FileManager.default.removeItem(at:proof)}else{try Data("changed synthetic proof".utf8).write(to:proof,options:.atomic)}
            rejects("Cached changed/missing proof accepted");try validProof.write(to:proof);precondition(current() != nil)
        }
        let depth=paths[0].deletingLastPathComponent().appendingPathComponent("frame-0.depth-u16le"),validDepth=try Data(contentsOf:depth)
        try Data(repeating:42,count:validDepth.count).write(to:depth,options:.atomic);rejects("Changed cached raw depth accepted")
        try validDepth.write(to:depth);precondition(current() != nil)
        for key in ["stationary","imu_to_rgb_rotation","gravity_std_mps2","age_milliseconds","latest_timestamp_ns"] {
            var bad=documents[0],frames=bad["frames"]as![[String:Any]],imu=frames[0]["imu"]as![String:Any]
            switch key {
            case "stationary":imu[key]=false
            case "imu_to_rgb_rotation":imu[key]=[1.0,0,0,0,1,0,0,0,-1]
            case "gravity_std_mps2":imu[key]=[0.11,0.01,0.01]
            case "age_milliseconds":imu[key]=101.0
            default:imu[key]=0
            }
            frames[0]["imu"]=imu;bad["frames"]=frames;try write(bad,to:paths[0])
            var changed=captures;changed[0]["captureInputSHA256"]=hash(try Data(contentsOf:paths[0]));var proof=evidence;proof["captures"]=changed
            try install(proof);rejects("Rejected stationary/factory-rotation policy: "+key)
            try write(documents[0],to:paths[0]);try install(evidence)
        }
        // Consistent but wrong held-out tilt cannot be fit away by training.
        var heldDocument=documents[3],heldFrames=documents[3]["frames"]as![[String:Any]]
        let heldTurn=simd_double3x3(simd_quatd(angle:0.05,axis:SIMD3(1,0,0)))
        for i in heldFrames.indices {
            var imu=heldFrames[i]["imu"]as![String:Any];let old=imu["gravity_mps2"]as![Double]
            let moved=heldTurn*SIMD3(old[0],old[1],old[2]);imu["gravity_mps2"]=[moved.x,moved.y,moved.z];heldFrames[i]["imu"]=imu
        }
        heldDocument["frames"]=heldFrames;try write(heldDocument,to:paths[3])
        var changedHeld=captures;changedHeld[3]["captureInputSHA256"]=hash(try Data(contentsOf:paths[3]))
        var unsupported=evidence;unsupported["captures"]=changedHeld;try install(unsupported)
        rejects("Independent held-out gravity disagreement accepted")
        try write(documents[3],to:paths[3]);try install(evidence)
        var repeated=evidence;var duplicated=captures;duplicated[3]=duplicated[0];repeated["captures"]=duplicated
        try install(repeated);rejects("Repeated training source accepted as held-out")
        try install(evidence);precondition(current() != nil)
        _=ROBFixedHeadBodyMotionIdentity.invalidate();rejects("Body change silently rebound old capture evidence")
        a.removeValue(forKey:"estimatedGravityPitchRefinement");try write(a,to:activation)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==oldPID)
        precondition(current()!.provisionalCameraToModel==baseline.last!.provisionalCameraToModel,"Absent optional refinement changed legacy matrix")
        precondition(ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:UUID(),runtimeCalibrationIdentity:nil,cameraServiceSourceSHA256:nil))
        print("PASS synthetic frozen gravity pitch: central estimated post-X only, exact origin/image-right, immutable source/body/runtime/generation bindings, independent held-out pose, either legal capture mapping with identical shared head and separate arm identities, cached evidence/raw tamper rejection, stationary/factory-rotation checks, legacy identity unchanged; no registration or motion authority")
    }
}
