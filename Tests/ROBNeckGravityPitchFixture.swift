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
                let depth=Data(repeating:UInt8(1+index*3+frame),count:640*480*2),name="frame-\(frame).depth-u16le"
                try depth.write(to:dir.appendingPathComponent(name))
                let latest=UInt64(1_000_000_000+index*100_000_000+frame*10_000_000)
                let imu:[String:Any]=["sensor":"synthetic-inertial-fixture","stationary":true,"axes":"sensor_native",
                    "gravity_source":"stationary_accelerometer_mean","gravity_mps2":g,"gravity_std_mps2":[0.01,0.01,0.01],
                    "gyro_rad_s":[0.0,0.0,0.0],"imu_to_rgb_rotation":[1.0,0,0,0,1,0,0,0,1],"sample_count":30,
                    "window_milliseconds":300.0,"age_milliseconds":1.0,"latest_timestamp_ns":latest,"reference_timestamp_ns":latest+1_000_000]
                frames.append(["sequence":frame+1,"capturedAtMilliseconds":1000.0+Double(frame),"cameraGeneration":generations[index].uuidString,
                    "width":640,"height":480,"stereoMode":"near_field","stereoModeSource":"sdk_initial_config_readback","depthPath":name,"captureSHA256":hash(depth),"rgbOutputUndistorted":true,
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
        precondition(ROBNeckRGBPoseDisplay.preferredFullHeightTaskStereoMode(model:model)=="near_field","Task camera must request the actual pinned acquisition mode")
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
            precondition(pose.unrefinedProvisionalCameraToModel==before.provisionalCameraToModel,
                "Capture initializer already contains the active constant gravity correction")
            precondition(pose.cameraToModel==before.cameraToModel && pose.headFrames==before.headFrames && pose.hardwareFrames==before.hardwareFrames &&
                pose.modelToDisplay==before.modelToDisplay && pose.headDepthDisplayLiftMeters==before.headDepthDisplayLiftMeters &&
                pose.robotModelDisplayLiftMeters==before.robotModelDisplayLiftMeters && !pose.hasDepthProjectionAuthority)
        }
        precondition(ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations.last!,runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service))
        precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations[0],runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service))
        precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations.last!,runtimeCalibrationIdentity:nil,cameraServiceSourceSHA256:service))
        precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations.last!,runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:nil))
        // A new stream must supply a fresh actual IMU/source/held-scope check;
        // historical calibration identities and the strict scalar API stay intact.
        let liveGeneration=UUID(),referenceFrames=documents[3]["frames"]as![[String:Any]]
        let actualIMU=referenceFrames[0]["imu"]as![String:Any]
        func acceptsLive(deviceID:String=device,runtimeValue:String=runtimeID,serviceValue:String=service,
            bodyValue:String=body,intrinsicsValue:String=String(repeating:"e",count:64),
            imuValue:[String:Any]?=nil,scopeGeneration:UUID?=nil,frameGeneration:UUID?=nil,
            expectedFailure:String?=nil,expectedRetry:Bool=false)throws->Bool {
            let scope=ROBFixedHeadRegistrationScope(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                cameraGeneration:scopeGeneration ?? frameGeneration ?? liveGeneration,gatewaySessionGeneration:1,displayCorrectionIdentity:"fixture:body:"+bodyValue,
                panTarget:6167,lowerTarget:6411,upperTarget:5800,intrinsicsIdentity:intrinsicsValue)
            let source=ROBNeckRGBPoseDisplay.ActualFrameSource(cameraGeneration:frameGeneration ?? liveGeneration,
                actualDeviceMXID:deviceID,runtimeCalibrationIdentity:runtimeValue,cameraServiceSourceSHA256:serviceValue,scope:scope,
                inertialJSON:try JSONSerialization.data(withJSONObject:imuValue ?? actualIMU))
            let failure=ROBNeckRGBPoseDisplay.estimatedProjectionSourceFailure(model:model,actualFrame:source)
            if let expectedFailure {
                precondition(failure?.reason.contains(expectedFailure)==true,"Wrong source rejection: \(failure?.reason ?? "accepted")")
                precondition(failure?.retryAfterSettling==expectedRetry)
            }
            let accepted=ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,actualFrame:source)
            precondition(accepted==(failure==nil),"Diagnostic and admission disagreed")
            return accepted
        }
        precondition(try! acceptsLive(),"Same physical source with actual matching gravity must survive a stream restart")
        precondition(try! acceptsLive(frameGeneration:generations.last!),"Original-generation actual frame still requires and passes physical source/gravity validation")
        var originalMovingIMU=actualIMU;originalMovingIMU["stationary"]=false
        precondition(try! !acceptsLive(imuValue:originalMovingIMU,frameGeneration:generations.last!),"Original-generation actual frames must not bypass stationary IMU validation")
        precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:liveGeneration,
            runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service),"Frame-free scalar overload must remain generation-strict")
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==refinedID,"Actual-frame acceptance must not rebind calibration provenance")
        precondition(try! !acceptsLive(deviceID:"different-device",expectedFailure:"camera device"))
        precondition(try! !acceptsLive(runtimeValue:String(repeating:"f",count:64),expectedFailure:"runtime camera calibration"))
        precondition(try! !acceptsLive(serviceValue:String(repeating:"f",count:64),expectedFailure:"camera service source"))
        precondition(try! !acceptsLive(bodyValue:UUID().uuidString))
        precondition(try! !acceptsLive(intrinsicsValue:"different-K"))
        precondition(try! !acceptsLive(intrinsicsValue:String(repeating:"f",count:64),expectedFailure:"RGB-D intrinsics"))
        precondition(try! !acceptsLive(scopeGeneration:UUID()))
        for (key,bad) in [("stationary",false as Any),("sample_count",19),("window_milliseconds",299.0),
            ("age_milliseconds",101.0),("sensor","different-sensor"),("gravity_std_mps2",[0.11,0,0]),
            ("gyro_rad_s",[0.04,0,0]),("imu_to_rgb_rotation",[1.0,0,0,0,0,1,0,-1,0])] {
            var badIMU=actualIMU;badIMU[key]=bad
            precondition(try! !acceptsLive(imuValue:badIMU),"Invalid actual IMU accepted: \(key)")
        }
        var tiltedIMU=actualIMU
        let tilted=simd_inverse(current()!.provisionalCameraToModel)*SIMD4<Double>(sin(0.05)*9.81,0,cos(0.05)*9.81,0)
        tiltedIMU["gravity_mps2"]=[tilted.x,tilted.y,tilted.z]
        precondition(try! !acceptsLive(imuValue:tiltedIMU,expectedFailure:"gravity direction disagrees"),"Actual 3D gravity mismatch above one degree accepted")
        precondition(try! !acceptsLive(imuValue:originalMovingIMU,expectedFailure:"IMU is not fresh and settled",expectedRetry:true))
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
        // Independent optional two-parameter upper-angle refinement. It does
        // not fit held-out data or change either arm's mapping or image-right.
        let affineReference=5650,affineIntercept = -0.11,affineSlope=0.00007
        var affineDocuments=documents,affineCaptures=captures
        for i in targets.indices {
            let pitch=affineIntercept+affineSlope*Double(targets[i].2-affineReference)
            let turn=simd_double4x4(simd_quatd(angle:pitch,axis:SIMD3(1,0,0)))
            let g=simd_inverse(baseline[i].provisionalCameraToModel*turn)*SIMD4<Double>(0,0,9.81,0)
            var frames=affineDocuments[i]["frames"]as![[String:Any]]
            for j in frames.indices {var imu=frames[j]["imu"]as![String:Any];imu["gravity_mps2"]=[g.x,g.y,g.z];frames[j]["imu"]=imu}
            affineDocuments[i]["frames"]=frames;try write(affineDocuments[i],to:paths[i])
            affineCaptures[i]["captureInputSHA256"]=hash(try Data(contentsOf:paths[i]))
        }
        var affine=evidence;affine["method"]="affine_training_upper_post_optical_x_preserve_origin_image_right_v1"
        affine.removeValue(forKey:"deltaRadians");affine["referenceUpperTarget"]=affineReference
        affine["interceptRadians"]=affineIntercept;affine["slopeRadiansPerRawUnit"]=affineSlope;affine["captures"]=affineCaptures
        try install(affine)
        let affineID=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)!
        precondition(affineID != refinedID && ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:otherSide)==affineID)
        for (i,target) in targets.enumerated() {
            let pose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:target.0,lowerTarget:target.1,upperTarget:target.2)!
            let pitch=affineIntercept+affineSlope*Double(target.2-affineReference)
            let expected=baseline[i].provisionalCameraToModel*simd_double4x4(simd_quatd(angle:pitch,axis:SIMD3(1,0,0)))
            precondition(pose.provisionalCameraToModel.columns.0==baseline[i].provisionalCameraToModel.columns.0 &&
                pose.provisionalCameraToModel.columns.3==baseline[i].provisionalCameraToModel.columns.3)
            for k in 0..<4 {precondition(close(pose.provisionalCameraToModel[k],expected[k]))}
            precondition(pose.unrefinedProvisionalCameraToModel==baseline[i].provisionalCameraToModel,
                "Capture initializer already contains the active affine gravity correction")
            precondition(pose.frozenOpticalPitchRefinementRadians==pitch && !pose.hasDepthProjectionAuthority)
        }
        for (key,value) in [("referenceUpperTarget",2000 as Any),("referenceUpperTarget",6000 as Any),
            ("interceptRadians",affineIntercept+0.001 as Any),("slopeRadiansPerRawUnit",affineSlope+0.000001 as Any),
            ("slopeRadiansPerRawUnit",0.001 as Any),("deltaRadians",affineIntercept as Any)] {
            var bad=affine;bad[key]=value;try install(bad);rejects("Invalid affine coefficient/range/mixed method: "+key)
        }
        var wrongMethod=affine;wrongMethod["method"]="mean_training_post_optical_x_preserve_origin_image_right_v1"
        try install(wrongMethod);rejects("Affine parameters silently interpreted as legacy constant")
        // Keep all other source data intact while making the upper design too
        // narrow; even a numerical fit must reject a 499-unit training span.
        var narrow=affineDocuments[0],narrowScope=narrow["scope"]as![String:Any]
        narrowScope["upperTarget"]=5301;narrow["scope"]=narrowScope;try write(narrow,to:paths[0])
        var narrowCaptures=affineCaptures;narrowCaptures[0]["captureInputSHA256"]=hash(try Data(contentsOf:paths[0]))
        var narrowProof=affine;narrowProof["captures"]=narrowCaptures;try install(narrowProof);rejects("Affine training span below500 accepted")
        try write(affineDocuments[0],to:paths[0]);try install(affine)
        // A held-out correction cannot be absorbed by changing the training
        // intercept/slope. Its source is still original and internally stable.
        var affineHeld=affineDocuments[3],affineHeldFrames=affineHeld["frames"]as![[String:Any]]
        for i in affineHeldFrames.indices {
            var imu=affineHeldFrames[i]["imu"]as![String:Any];let g=imu["gravity_mps2"]as![Double]
            let moved=heldTurn*SIMD3(g[0],g[1],g[2]);imu["gravity_mps2"]=[moved.x,moved.y,moved.z];affineHeldFrames[i]["imu"]=imu
        }
        affineHeld["frames"]=affineHeldFrames;try write(affineHeld,to:paths[3])
        var affineHeldSources=affineCaptures;affineHeldSources[3]["captureInputSHA256"]=hash(try Data(contentsOf:paths[3]))
        var affineHeldProof=affine;affineHeldProof["captures"]=affineHeldSources;try install(affineHeldProof)
        rejects("Affine method fit or ignored failed held-out gravity")
        for i in documents.indices {try write(documents[i],to:paths[i])}
        try install(evidence)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==refinedID,"Legacy constant method changed after affine refinement")
        print("PASS synthetic affine upper pitch: training-only centered rank2 fit,500-unit span, independently held-out full3Dgravity, coefficient and globalangle bounds, exact optical origin/image-right, shared both-arm head, constant method retained; no registration or motion authority")
        let originalProofBytes=try Data(contentsOf:proof)
        let originalCaptureBytes=try paths.map{try Data(contentsOf:$0)}
        let currentBody=ROBFixedHeadBodyMotionIdentity.invalidate()
        rejects("Body change silently rebound old capture evidence")
        a["demoPortableGravityPitchPrior"]=false;try write(a,to:activation)
        rejects("Explicit OFF portable policy accepted an old body")
        a["demoPortableGravityPitchPrior"]=true;try write(a,to:activation)
        #if DEBUG
        let portableID=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)!
        precondition(portableID != refinedID,"Portable policy was omitted from projection identity")
        precondition(try! acceptsLive(bodyValue:currentBody),"Fresh actual source/gravity did not validate immutable prior across app body identity")
        precondition(try! !acceptsLive(),"Portable prior accepted the original body's scope as current")
        precondition(try! !acceptsLive(deviceID:"different-device",bodyValue:currentBody))
        precondition(try! !acceptsLive(runtimeValue:String(repeating:"f",count:64),bodyValue:currentBody))
        precondition(try! !acceptsLive(serviceValue:String(repeating:"f",count:64),bodyValue:currentBody))
        precondition(try! !acceptsLive(bodyValue:currentBody,intrinsicsValue:"different-K"))
        precondition(try! !acceptsLive(bodyValue:currentBody,scopeGeneration:UUID()))
        precondition(try! !acceptsLive(bodyValue:currentBody,imuValue:tiltedIMU),"Portable prior accepted >1 degree actual gravity error")
        precondition(try! !acceptsLive(bodyValue:currentBody,imuValue:originalMovingIMU))
        for milliseconds in [300.0,479.0,495.0,1000.0] {
            var held=actualIMU;held["window_milliseconds"]=milliseconds
            precondition(try! acceptsLive(bodyValue:currentBody,imuValue:held),"Portable policy tightened existing stationary window")
        }
        precondition(!ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:generations.last!,
            runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service),"Frame-free API accepted an old body under portable policy")
        let auditScope=ROBFixedHeadRegistrationScope(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            cameraGeneration:liveGeneration,gatewaySessionGeneration:1,displayCorrectionIdentity:"fixture:body:"+currentBody,
            panTarget:6167,lowerTarget:6411,upperTarget:5800,intrinsicsIdentity:String(repeating:"e",count:64))
        let auditedFrame=ROBNeckRGBPoseDisplay.ActualFrameSource(cameraGeneration:liveGeneration,actualDeviceMXID:device,
            runtimeCalibrationIdentity:runtimeID,cameraServiceSourceSHA256:service,scope:auditScope,
            inertialJSON:try JSONSerialization.data(withJSONObject:actualIMU))
        let audit=ROBNeckRGBPoseDisplay.gravityPitchUseSessionAudit(model:model,actualFrame:auditedFrame)!
        precondition(audit.sourceOriginalBodyIdentity==body && audit.currentBodyIdentity==currentBody &&
            audit.sourceOriginalCameraGeneration==generations.last! && audit.currentCameraGeneration==liveGeneration &&
            audit.sourceEvidenceSHA256==hash(originalProofBytes) && audit.demoPortableGravityPitchPrior &&
            !audit.registrationVerified && !audit.armMotionAuthority && !audit.originalEvidenceRebound)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==portableID,"Actual use rebound original evidence identity")
        var reboundEvidence=evidence;reboundEvidence["bodyMotionIdentity"]=currentBody
        try install(reboundEvidence);rejects("Portable policy accepted relabelled source body instead of original capture lineage")
        try install(evidence);precondition(try! acceptsLive(bodyValue:currentBody))
        try Data(repeating:42,count:validDepth.count).write(to:depth,options:.atomic)
        rejects("Portable cache accepted changed original raw depth")
        try validDepth.write(to:depth);precondition(try! acceptsLive(bodyValue:currentBody))
        #else
        rejects("Release build accepted DEBUG portable policy")
        #endif
        let retainedProofBytes=try Data(contentsOf:proof),retainedCaptureBytes=try paths.map{try Data(contentsOf:$0)}
        precondition(retainedProofBytes==originalProofBytes,"Portable policy rewrote original evidence")
        precondition(retainedCaptureBytes==originalCaptureBytes,"Portable policy rewrote original captures")
        a.removeValue(forKey:"demoPortableGravityPitchPrior")
        a.removeValue(forKey:"estimatedGravityPitchRefinement");try write(a,to:activation)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==oldPID)
        precondition(current()!.provisionalCameraToModel==baseline.last!.provisionalCameraToModel,"Absent optional refinement changed legacy matrix")
        precondition(ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,cameraGeneration:UUID(),runtimeCalibrationIdentity:nil,cameraServiceSourceSHA256:nil))
        // A stationary body need not have model +Z aligned with gravity. Fit
        // optical pitch separately from a shared training-only gravity vector,
        // then check two independent views without changing arm coordinates.
        let bodyTargets=[(4500,5300),(6000,6500),(6000,5650),(5000,5900),(5600,6200)]
        let bodyBaseline=bodyTargets.map { ROBNeckRGBPoseDisplay.pose(model:model,panTarget:$0.0,lowerTarget:6411,upperTarget:$0.1)! }
        let bodyUp=simd_normalize(SIMD3<Double>(-0.04,0.01,1)),bodyGeneration=UUID()
        var bodyCaptures:[[String:Any]]=[],bodyDocuments:[[String:Any]]=[],bodyPaths:[URL]=[]
        for (index,target) in bodyTargets.enumerated() {
            let dir=temporary.appendingPathComponent("synthetic-body-gravity-\(index)")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let input=dir.appendingPathComponent("capture-input.json")
            let scope=ROBFixedHeadRegistrationScope(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                cameraGeneration:bodyGeneration,gatewaySessionGeneration:1,displayCorrectionIdentity:"fixture:body:"+currentBody,
                panTarget:target.0,lowerTarget:6411,upperTarget:target.1,intrinsicsIdentity:String(repeating:"e",count:64))
            let pitch=affineIntercept+affineSlope*Double(target.1-affineReference)
            let camera=bodyBaseline[index].provisionalCameraToModel*simd_double4x4(simd_quatd(angle:pitch,axis:SIMD3(1,0,0)))
            let g=simd_inverse(camera)*SIMD4(bodyUp*9.81,0)
            var frames=documents[0]["frames"]as![[String:Any]]
            for j in frames.indices {
                let data=Data(repeating:UInt8(index*3+j+40),count:640*480*2),name="frame-\(j).depth-u16le"
                try data.write(to:dir.appendingPathComponent(name))
                frames[j]["depthPath"]=name;frames[j]["captureSHA256"]=hash(data);frames[j]["cameraGeneration"]=bodyGeneration.uuidString
                var imu=frames[j]["imu"]as![String:Any];imu["gravity_mps2"]=[g.x,g.y,g.z];frames[j]["imu"]=imu
            }
            let document:[String:Any]=["schemaVersion":1,"cameraRole":"face","scope":try JSONSerialization.jsonObject(with:JSONEncoder().encode(scope)),"frames":frames]
            try write(document,to:input);bodyDocuments.append(document);bodyPaths.append(input)
            bodyCaptures.append(["role":index<3 ? "training":"held_out","captureInputPath":input.path,"captureInputSHA256":hash(try Data(contentsOf:input))])
        }
        var bodyEvidence=affine
        bodyEvidence["method"]="affine_training_upper_with_body_gravity_reference_v1"
        bodyEvidence["bodyMotionIdentity"]=currentBody;bodyEvidence["activeCameraGeneration"]=bodyGeneration.uuidString
        bodyEvidence["modelBaseUpAssumed"]=false;bodyEvidence["bodyGravityReferenceModel"]=[bodyUp.x,bodyUp.y,bodyUp.z]
        bodyEvidence["referenceLowerTarget"]=6411;bodyEvidence["captures"]=bodyCaptures
        try install(bodyEvidence)
        let bodyProjectionID=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)!
        precondition(bodyProjectionID != affineID)
        func bodySource(lower:Int=6411,imuOverride:[String:Any]?=nil)->ROBNeckRGBPoseDisplay.ActualFrameSource {
            let scope=ROBFixedHeadRegistrationScope(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                cameraGeneration:bodyGeneration,gatewaySessionGeneration:1,displayCorrectionIdentity:"fixture:body:"+currentBody,
                panTarget:bodyTargets[4].0,lowerTarget:lower,upperTarget:bodyTargets[4].1,intrinsicsIdentity:String(repeating:"e",count:64))
            let imu=imuOverride ?? (bodyDocuments[4]["frames"]as![[String:Any]])[0]["imu"]as![String:Any]
            return .init(cameraGeneration:bodyGeneration,actualDeviceMXID:device,runtimeCalibrationIdentity:runtimeID,
                cameraServiceSourceSHA256:service,scope:scope,inertialJSON:try! JSONSerialization.data(withJSONObject:imu))
        }
        precondition(ROBNeckRGBPoseDisplay.estimatedProjectionSourceFailure(model:model,actualFrame:bodySource())==nil)
        precondition(ROBNeckRGBPoseDisplay.estimatedProjectionSourceFailure(model:model,actualFrame:bodySource(lower:6011)) != nil)
        var movedIMU=(bodyDocuments[4]["frames"]as![[String:Any]])[0]["imu"]as![String:Any]
        let actual=movedIMU["gravity_mps2"]as![Double],changed=heldTurn*SIMD3(actual[0],actual[1],actual[2])
        movedIMU["gravity_mps2"]=[changed.x,changed.y,changed.z]
        precondition(ROBNeckRGBPoseDisplay.estimatedProjectionSourceFailure(model:model,actualFrame:bodySource(imuOverride:movedIMU)) != nil)
        for (i,target) in bodyTargets.enumerated() {
            let pose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:target.0,lowerTarget:6411,upperTarget:target.1)!
            precondition(pose.provisionalCameraToModel.columns.0==bodyBaseline[i].provisionalCameraToModel.columns.0 &&
                pose.provisionalCameraToModel.columns.3==bodyBaseline[i].provisionalCameraToModel.columns.3 && !pose.hasDepthProjectionAuthority)
        }
        for (key,value) in [("modelBaseUpAssumed",true as Any),("referenceLowerTarget",6011 as Any),
            ("bodyGravityReferenceModel",[0.0,0.0,1.0]as Any),("captures",Array(bodyCaptures.dropLast())as Any)] {
            var bad=bodyEvidence;bad[key]=value;try install(bad);rejects("Invalid body-gravity evidence: "+key)
        }
        // Corrupt only an independent view while retaining authentic hashes.
        var badHeld=bodyDocuments[4],badFrames=badHeld["frames"]as![[String:Any]]
        for i in badFrames.indices {badFrames[i]["imu"]=movedIMU}
        badHeld["frames"]=badFrames;try write(badHeld,to:bodyPaths[4])
        var badSources=bodyCaptures;badSources[4]["captureInputSHA256"]=hash(try Data(contentsOf:bodyPaths[4]))
        var badProof=bodyEvidence;badProof["captures"]=badSources;try install(badProof)
        rejects("Body reference absorbed independent held-out gravity disagreement")
        try write(bodyDocuments[4],to:bodyPaths[4]);try install(bodyEvidence)
        a["demoPortableGravityPitchPrior"]=true;try write(a,to:activation)
        rejects("Body reference became a portable prior across physical posture changes")
        a.removeValue(forKey:"demoPortableGravityPitchPrior");try write(a,to:activation)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==bodyProjectionID)
        ROBFixedHeadBodyMotionIdentity.invalidate()
        rejects("LACT/torso/tread motion retained a stationary body-gravity reference")
        a.removeValue(forKey:"estimatedGravityPitchRefinement");try write(a,to:activation)
        print("PASS stationary body gravity: training-only common direction, independent held-out poses, unchanged optical origin/image-right/arm mapping, strict current residual/lower/body checks, no portable rebinding or motion authority")
        print("PASS synthetic frozen gravity pitch: central estimated post-X only, exact origin/image-right, immutable source/body/runtime/generation bindings, independent held-out pose, either legal capture mapping with identical shared head and separate arm identities, cached evidence/raw tamper rejection, stationary/factory-rotation checks, legacy identity unchanged; no registration or motion authority")
    }
}
