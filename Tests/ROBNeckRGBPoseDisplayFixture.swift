import Foundation
import CryptoKit
import simd

/// Pure saved-data/model checks. No camera, UI, gateway or actuator is linked.
@main enum ROBNeckRGBPoseDisplayFixture {
    static func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func write(_ value:[String:Any],to url:URL)throws {
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url)
    }
    static func close(_ a:SIMD4<Double>,_ b:SIMD4<Double>)->Bool {simd_length(a-b)<1e-10}
    static func check(_ pose:ROBNeckRGBPoseDisplay.Pose,torso:simd_double4x4) {
        precondition(!pose.hasDepthProjectionAuthority)
        precondition(pose.headFrames["oak_optical_frame"]==pose.cameraToModel)
        precondition(pose.displayCameraToModel==pose.modelToDisplay*pose.provisionalCameraToModel)
        precondition(close(pose.modelToDisplay*torso.columns.3,torso.columns.3),"Display gauge moved its torso pivot")
        let R=simd_double3x3(SIMD3(pose.modelToDisplay.columns.0.x,pose.modelToDisplay.columns.0.y,pose.modelToDisplay.columns.0.z),
            SIMD3(pose.modelToDisplay.columns.1.x,pose.modelToDisplay.columns.1.y,pose.modelToDisplay.columns.1.z),
            SIMD3(pose.modelToDisplay.columns.2.x,pose.modelToDisplay.columns.2.y,pose.modelToDisplay.columns.2.z))
        precondition(abs(simd_determinant(R)-1)<1e-10)
    }
    static func main() throws {
        let args=CommandLine.arguments
        let directory=URL(fileURLWithPath:args[1])
        let model=try ROBGhostRobotModel(directory:directory,physicalSide:"right")
        let torso=model.frames(model.reference)["torso_link"]!
        if let index=args.firstIndex(of:"--actual-belly-reference") {
            let source=ROBNeckRGBPoseDisplay.activationURL,evidenceURL=URL(fileURLWithPath:args[index+1])
            let referenceBytes=try Data(contentsOf:evidenceURL)
            let reference=try JSONSerialization.jsonObject(with:referenceBytes)as![String:Any]
            let n=reference["normalOptical"]as![Double]
            let before=ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)!["belly_oak_optical_frame"]!
            let beforePose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
            let beforePhysical=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)
            var activation=try JSONSerialization.jsonObject(with:Data(contentsOf:source))as![String:Any]
            activation["bellyFloorDisplayReference"]=["evidencePath":evidenceURL.path,"evidenceSHA256":hash(referenceBytes)]
            let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("belly-display-proof-\(UUID().uuidString).json")
            defer{try? FileManager.default.removeItem(at:temporary)}
            try write(activation,to:temporary);setenv("ROB_NECK_RGB_DISPLAY_PROFILE",temporary.path,1)
            guard let pose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160),
                  let frames=ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model),let optical=frames["belly_oak_optical_frame"] else {fatalError("Recorded belly reference failed display validation")}
            let up=pose.modelToDisplay*optical*SIMD4(n[0],n[1],n[2],0)
            precondition(close(up,SIMD4(0,0,1,0)) && close(optical.columns.3,before.columns.3))
            precondition(pose.cameraToModel==beforePose.cameraToModel && pose.provisionalCameraToModel==beforePose.provisionalCameraToModel &&
                ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==beforePhysical && !pose.hasDepthProjectionAuthority)
            let delta=optical*simd_inverse(before),trace=delta.columns.0.x+delta.columns.1.y+delta.columns.2.z
            print("PASS recorded belly display reference: floor-up \(up), minimum turn \(acos(min(1,max(-1,(trace-1)/2)))*180 / .pi) degrees; optical origin/head physical projection unchanged; no activation or depth authority")
            return
        }
        if let index=args.firstIndex(of:"--actual-profile") {
            setenv("ROB_NECK_RGB_DISPLAY_PROFILE",args[index+1],1)
            guard let pose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:4667,lowerTarget:6495,upperTarget:5990) else {fatalError("Actual pinned display profile failed")}
            check(pose,torso:torso)
            let degrees=pose.depressionRadians*180/Double.pi
            precondition(abs(degrees-73.81343268782285)<1e-8,"Actual Swift pose differs from independent D3-only prediction")
            print("PASS actual pinned profile: P4667/L6495/U5990 = \(degrees) degrees; no depth authority")
            return
        }
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("neck-rgb-display-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:temp)}
        let fit=temp.appendingPathComponent("synthetic-fit.json"),floor=temp.appendingPathComponent("synthetic-floor.json")
        let capture=temp.appendingPathComponent("synthetic-capture"),activation=temp.appendingPathComponent("activation.json")
        try FileManager.default.createDirectory(at:capture,withIntermediateDirectories:true)
        setenv("ROB_NECK_RGB_DISPLAY_PROFILE",activation.path,1)
        let p:[String:Double]=["panScale":1.9,"lowerScale":1.7,"upperScale":1.8,"lowerOffsetRadians":-0.2,
            "cameraDeltaRx":-0.08,"cameraDeltaRy":0.015,"cameraDeltaRz":-0.02,
            "cameraDistanceFromAssumedUpperCenterMeters":0.15,"cameraAzimuthRadians":0.1,"cameraElevationRadians":0.7]
        try write(["status":"conditional_torso_bundle_candidate_not_registered","modelID":model.modelID,
            "registrationVerified":false,"pixelModel":["fixedDistortionApplied":false],"parameters":p],to:fit)
        let metadata=Data("Synthetic fixture metadata, never physical evidence".utf8)
        try metadata.write(to:capture.appendingPathComponent("capture-input.json"))
        var observations:[[String:Any]]=[]
        for i in 0..<3 {
            let image=Data("Synthetic fixture image \(i), no actual camera".utf8)
            try image.write(to:capture.appendingPathComponent("frame-\(i).jpg"))
            observations.append(["targetID":"ROB:FLOOR:R01","floorNormalOptical":[0.0,0.0,-1.0],
                "frameIndex":i,"imageSHA256":hash(image),"reprojectionRMSPixels":0.1,"correlation":0.99,"ambiguous":false])
        }
        try write(["scope":["modelID":model.modelID,"panTarget":6000,"lowerTarget":6495,"upperTarget":5900],
            "sourceCapturePath":capture.path,"sourceCaptureSHA256":hash(metadata),"observations":observations],to:floor)
        var a:[String:Any]=["schemaVersion":1,"kind":"provisional_rgb_neck_display","modelID":model.modelID,
            "referenceID":model.referenceID,"geometryID":model.geometryID,
            "fitArtifactPath":fit.path,"fitArtifactSHA256":hash(try Data(contentsOf:fit)),
            "floorReferencePath":floor.path,"floorReferenceSHA256":hash(try Data(contentsOf:floor))]
        func activate()throws {a["syntheticTestRevision"]=UUID().uuidString;try write(a,to:activation)}
        try activate()
        var matrices:[simd_double4x4]=[]
        for target in [(6000,6495,5900),(5960,6495,5900),(6000,6495,5780),(6111,6011,6160)] {
            guard let pose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:target.0,lowerTarget:target.1,upperTarget:target.2) else {fatalError("Synthetic display hypothesis failed")}
            check(pose,torso:torso);matrices.append(pose.cameraToModel)
            if target.0==6000 && target.1==6495 && target.2==5900 {
                precondition(abs(pose.depressionRadians-Double.pi/2)<1e-10,"QR-up gauge failed")
            }
        }
        precondition(matrices.dropFirst().allSatisfy{$0 != matrices[0]},"Raw P/L/U did not change articulated pose")
        let beforeLift=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)!
        a["headDepthDisplayLiftMeters"]=0.0762;try activate()
        let lifted=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)!
        precondition(lifted.cameraToModel==beforeLift.cameraToModel && lifted.headFrames==beforeLift.headFrames,
            "Preview height adjustment changed physical camera or head geometry")
        precondition(abs(lifted.depthCloudCameraToModel.columns.3.z-beforeLift.depthCloudCameraToModel.columns.3.z-0.0762)<1e-10)
        for i in 0..<3 {precondition(close(lifted.depthCloudCameraToModel[i],beforeLift.depthCloudCameraToModel[i]),"Height adjustment tilted the cloud")}
        precondition(!lifted.hasDepthProjectionAuthority && lifted.profileID != beforeLift.profileID)
        a["headDepthDisplayLiftMeters"]=0.5;try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)==nil)
        a.removeValue(forKey:"headDepthDisplayLiftMeters");try activate()
        var measured=p;measured["cameraDistanceFromAssumedUpperCenterMeters"]=0.129
        func measuredFit()throws {
            try write(["status":"conditional_torso_bundle_candidate_not_registered","modelID":model.modelID,
                "registrationVerified":false,"pixelModel":["fixedDistortionApplied":false],"parameters":measured],to:fit)
            a["fitArtifactSHA256"]=hash(try Data(contentsOf:fit))
        }
        try measuredFit()
        a["headMount"]=["upperCenterToSphereMeters":0.165,"sphereToRGBGlassMeters":0.0965,
            "upperCenterToRGBGlassMeters":0.129,"opticalCenterAllowanceMeters":0.015,
            "sphereAzimuthAssumption":"closest_to_nominal"]
        try activate()
        var rigidAssembly:simd_double4x4?
        func point(_ T:simd_double4x4)->SIMD3<Double> {SIMD3(T.columns.3.x,T.columns.3.y,T.columns.3.z)}
        for target in [(6000,6495,5900),(4667,6495,5990),(6111,6011,6160)] {
            let pose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:target.0,lowerTarget:target.1,upperTarget:target.2)!
            check(pose,torso:torso)
            let U=pose.headFrames["upper_neck_link"]!,S=pose.headFrames["insta360_link"]!,G=pose.headFrames["rgb_glass_frame"]!
            precondition(abs(simd_distance(point(U),point(S))-0.165)<1e-10)
            precondition(abs(simd_distance(point(S),point(G))-0.0965)<1e-10)
            precondition(abs(simd_distance(point(U),point(G))-0.129)<1e-10)
            precondition(pose.headMount!.azimuthAssumption=="closest_to_nominal")
            precondition(pose.headMount!.glassToOpticalDistanceMeters<=0.015+1e-10)
            let assembly=simd_inverse(S)*G
            if let rigidAssembly {for i in 0..<4 {precondition(close(assembly[i],rigidAssembly[i]),"Glued head triangle changed across neck poses")}}
            else {rigidAssembly=assembly}
        }
        let withTriangle=ROBNeckRGBPoseDisplay.cameraToModel(model:model,panTarget:4667,lowerTarget:6495,upperTarget:5990)!
        let mount=a.removeValue(forKey:"headMount");try activate()
        precondition(ROBNeckRGBPoseDisplay.cameraToModel(model:model,panTarget:4667,lowerTarget:6495,upperTarget:5990)==withTriangle,"Measured render triangle changed optical calibration")
        a["headMount"]=mount;measured["cameraDistanceFromAssumedUpperCenterMeters"]=0.04098;try measuredFit();try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:4667,lowerTarget:6495,upperTarget:5990)==nil,"Disproved41mm optical center was silently stretched to129mm")
        // A photo drawing is distinct from the radius-constrained optical
        // headMount above. It must not stretch or replace the rejected fit.
        a.removeValue(forKey:"headMount");try activate()
        let hardwareTargets=[(6015,6011,6160),(4667,6495,5990),(6111,6200,6350)]
        let opticalBeforeHardware=hardwareTargets.map {ROBNeckRGBPoseDisplay.pose(model:model,panTarget:$0.0,lowerTarget:$0.1,upperTarget:$0.2)!}
        var hardware:[String:Any]=["kind":"operator_photo_hardware_pose","lowerUprightTarget":6011,"upperReferenceTarget":6160,
            "panForwardTarget":6015,"lowerToUpperPivotMeters":0.15579,"upperCenterToSphereMeters":0.165,
            "sphereToRGBGlassMeters":0.0965,"upperCenterToRGBGlassMeters":0.129,"sphereForwardLeanDegrees":8.3,
            "cameraDepressionAtReferenceDegrees":38.4,"sourcePhotoSHA256":String(repeating:"a",count:64)]
        a["hardwarePose"]=hardware;try activate()
        var hardwareAssembly:simd_double4x4?,hardwareHousing:simd_double4x4?
        for (index,target) in hardwareTargets.enumerated() {
            let pose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:target.0,lowerTarget:target.1,upperTarget:target.2)!
            let before=opticalBeforeHardware[index]
            check(pose,torso:torso)
            precondition(pose.cameraToModel==before.cameraToModel && pose.headFrames==before.headFrames &&
                pose.modelToDisplay==before.modelToDisplay && pose.depthCloudCameraToModel==before.depthCloudCameraToModel,
                "Photo hardware drawing changed QR optical calibration or cloud")
            precondition(pose.profileID != before.profileID && pose.headMount==nil)
            precondition(pose.hardwareSphereRingTiltDegrees==0,"Omitted photo ring tilt did not default to horizontal")
            let H=pose.hardwareFrames!,L=H["lower_neck_link"]!,U=H["upper_neck_link"]!,S=H["insta360_link"]!,G=H["rgb_glass_frame"]!,O=H["oak_link"]!
            precondition(H["oak_optical_frame"]==nil,"Photo drawing overrode the fitted optical frame")
            precondition(abs(simd_distance(point(L),point(U))-0.15579)<1e-10)
            precondition(abs(simd_distance(point(U),point(S))-0.165)<1e-10)
            precondition(abs(simd_distance(point(S),point(G))-0.0965)<1e-10)
            precondition(abs(simd_distance(point(U),point(G))-0.129)<1e-10)
            let assembly=simd_inverse(S)*G,housing=simd_inverse(G)*O
            if let hardwareAssembly,let hardwareHousing {
                for i in 0..<4 {precondition(close(assembly[i],hardwareAssembly[i]) && close(housing[i],hardwareHousing[i]),"Photo hardware mounts did not remain glued")}
            } else {hardwareAssembly=assembly;hardwareHousing=housing}
            if index==0 {
                let lower=simd_inverse(torso)*L,delta=simd_inverse(L)*U
                precondition(close(lower.columns.2,SIMD4(0,0,1,0)),"Lower neck is not upright at6011")
                precondition(close(lower.columns.3,SIMD4(-0.0207044288303,0,0.355408962871,1)),"Photo override moved canonical rearward neck pivot")
                precondition(close(delta.columns.3,SIMD4(0,0,0.15579,1)))
                let sphere=simd_inverse(U)*S,glass=simd_inverse(U)*G
                precondition(abs(sphere.columns.3.x-0.165*sin(8.3 * .pi/180))<1e-10)
                precondition(glass.columns.3.x>sphere.columns.3.x && glass.columns.3.z<sphere.columns.3.z)
                let ray=simd_inverse(U)*G
                precondition(abs(-atan2(ray.columns.2.z,hypot(ray.columns.2.x,ray.columns.2.y))*180 / .pi-38.4)<1e-10)
            }
        }
        let opticalOriginBefore=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
        precondition(!opticalOriginBefore.usesPhotoHardwareOpticalOrigin && opticalOriginBefore.provisionalCameraToModel==opticalOriginBefore.cameraToModel)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==nil &&
            ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)==nil)
        a["usePhotoHardwareOpticalOrigin"]=false;try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!.provisionalCameraToModel==opticalOriginBefore.cameraToModel)
        a["usePhotoHardwareOpticalOrigin"]=true;try activate()
        let opticalOriginAfter=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
        let projectionID=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)!
        precondition(projectionID.count==64 && opticalOriginAfter.usesPhotoHardwareOpticalOrigin && !opticalOriginAfter.hasDepthProjectionAuthority)
        precondition(opticalOriginAfter.cameraToModel==opticalOriginBefore.cameraToModel && opticalOriginAfter.headFrames==opticalOriginBefore.headFrames)
        for i in 0..<3 {precondition(opticalOriginAfter.provisionalCameraToModel[i]==opticalOriginBefore.cameraToModel[i],"Photo origin changed optical rotation")}
        precondition(opticalOriginAfter.provisionalCameraToModel.columns.3==opticalOriginAfter.hardwareFrames!["rgb_glass_frame"]!.columns.3)
        let shift=opticalOriginAfter.provisionalCameraToModel.columns.3-opticalOriginBefore.cameraToModel.columns.3
        for v in [SIMD4<Double>(0,0,0.6,1),SIMD4<Double>(0.2,-0.1,1.2,1)] {
            precondition(close(opticalOriginAfter.provisionalCameraToModel*v-opticalOriginBefore.cameraToModel*v,shift),"Estimated mapping introduced scale/rotation instead of a pure origin change")
        }
        precondition(ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)==opticalOriginAfter.provisionalCameraToModel)
        _=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:4667,lowerTarget:6495,upperTarget:5990)!
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==projectionID,"Physical projection identity depended on current raw head pose")
        let savedFloor=try Data(contentsOf:floor)
        var changedFloor=try JSONSerialization.jsonObject(with:savedFloor)as![String:Any]
        var changedObservations=changedFloor["observations"]as![[String:Any]]
        for i in changedObservations.indices {changedObservations[i]["floorNormalOptical"]=[0.0,0.1,-sqrt(0.99)]}
        changedFloor["observations"]=changedObservations;try write(changedFloor,to:floor)
        a["floorReferenceSHA256"]=hash(try Data(contentsOf:floor))
        a["headDepthDisplayLiftMeters"]=0.127;a["bellyCameraDownwardPitchDegrees"]=25.0
        hardware["sphereRingTiltAtReferenceDegrees"]=12.0;hardware["cameraDepressionAtReferenceDegrees"]=40.0;a["hardwarePose"]=hardware;try activate()
        let cosmetic=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
        precondition(cosmetic.modelToDisplay != opticalOriginAfter.modelToDisplay && cosmetic.profileID != opticalOriginAfter.profileID)
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==projectionID && cosmetic.provisionalCameraToModel==opticalOriginAfter.provisionalCameraToModel,
            "Display lift/gauge/belly/ring/housing orientation changed the physical projection identity or transform")
        hardware["sphereForwardLeanDegrees"]=9.3;a["hardwarePose"]=hardware;try activate()
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model) != projectionID,"A changed physical photo mount retained its projection identity")
        hardware["sphereForwardLeanDegrees"]=8.3;hardware["sourcePhotoSHA256"]=String(repeating:"b",count:64);a["hardwarePose"]=hardware;try activate()
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model) != projectionID,"Changed physical photo provenance retained its identity")
        hardware["sourcePhotoSHA256"]=String(repeating:"a",count:64);hardware.removeValue(forKey:"sphereRingTiltAtReferenceDegrees");hardware["cameraDepressionAtReferenceDegrees"]=38.4
        a["hardwarePose"]=hardware;a.removeValue(forKey:"headDepthDisplayLiftMeters");a.removeValue(forKey:"bellyCameraDownwardPitchDegrees")
        try savedFloor.write(to:floor);a["floorReferenceSHA256"]=hash(savedFloor);try activate()
        precondition(ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==projectionID)
        a.removeValue(forKey:"hardwarePose");try activate()
        precondition(ROBNeckRGBPoseDisplay.photoHardwareOpticalOriginRequested && ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==nil &&
            ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)==nil,"Invalid requested photo projection silently became available")
        a["hardwarePose"]=hardware;a.removeValue(forKey:"usePhotoHardwareOpticalOrigin");try activate()
        let beforeRing=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
        for ring in [12.0,-45.0,45.0] {
            hardware["sphereRingTiltAtReferenceDegrees"]=ring;a["hardwarePose"]=hardware;try activate()
            let changed=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
            precondition(changed.hardwareSphereRingTiltDegrees==ring && changed.profileID != beforeRing.profileID)
            precondition(changed.cameraToModel==beforeRing.cameraToModel && changed.headFrames==beforeRing.headFrames &&
                changed.modelToDisplay==beforeRing.modelToDisplay && changed.depthCloudCameraToModel==beforeRing.depthCloudCameraToModel &&
                changed.hardwareFrames==beforeRing.hardwareFrames,"Sphere-ring appearance changed optical projection or mount positions")
        }
        for ring in [-45.001,45.001] {
            hardware["sphereRingTiltAtReferenceDegrees"]=ring;a["hardwarePose"]=hardware;try activate()
            precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)==nil,"Unbounded sphere-ring tilt accepted")
        }
        hardware["sphereRingTiltAtReferenceDegrees"]=0;a["hardwarePose"]=hardware;try activate()
        let finiteRingJSON=try String(contentsOf:activation,encoding:.utf8)
        let nonfiniteRingJSON=finiteRingJSON.replacingOccurrences(of:"\"sphereRingTiltAtReferenceDegrees\":0",with:"\"sphereRingTiltAtReferenceDegrees\":1e309")
        precondition(nonfiniteRingJSON != finiteRingJSON)
        try nonfiniteRingJSON.write(to:activation,atomically:true,encoding:.utf8)
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)==nil,"Nonfinite sphere-ring tilt accepted")
        hardware.removeValue(forKey:"sphereRingTiltAtReferenceDegrees");a["hardwarePose"]=hardware;try activate()
        precondition(ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)==nil)
        let beforeBelly=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
        let beforeIdentity=ROBNeckRGBPoseDisplay.configurationIdentity(model:model)!
        a["bellyCameraDownwardPitchDegrees"]=25.0;try activate()
        let withBelly=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
        precondition(withBelly.bellyPreviewDownwardPitchDegrees==25)
        precondition(withBelly.cameraToModel==beforeBelly.cameraToModel && withBelly.hardwareFrames==beforeBelly.hardwareFrames &&
            withBelly.headFrames==beforeBelly.headFrames && withBelly.depthCloudCameraToModel==beforeBelly.depthCloudCameraToModel,
            "Belly sensor adjustment changed head hardware or RGB/depth pose")
        precondition(ROBNeckRGBPoseDisplay.configurationIdentity(model:model) != beforeIdentity)
        let belly=ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)!,canonical=model.frames(model.reference)
        let originalBelly=canonical["belly_oak_optical_frame"]!,correctedBelly=belly["belly_oak_optical_frame"]!
        precondition(close(correctedBelly.columns.3,originalBelly.columns.3),"Belly pitch changed optical origin")
        let bellyRay=simd_inverse(torso)*correctedBelly
        precondition(abs(bellyRay.columns.2.x-cos(25 * .pi/180))<1e-10 && abs(bellyRay.columns.2.z+sin(25 * .pi/180))<1e-10)
        let originalMount=simd_inverse(originalBelly)*canonical["belly_oak_link"]!,correctedMount=simd_inverse(correctedBelly)*belly["belly_oak_link"]!
        for i in 0..<4 {precondition(close(originalMount[i],correctedMount[i]),"Belly housing detached from optical mount")}
        let bellyCapture=temp.appendingPathComponent("belly-capture"),bellyEvidenceURL=temp.appendingPathComponent("belly-floor-reference.json")
        try FileManager.default.createDirectory(at:bellyCapture,withIntermediateDirectories:true)
        let normal=simd_normalize(SIMD3<Double>(-0.00683,-0.94259,-0.33389))
        var bellyFrames:[[String:Any]]=[],captureFrames:[[String:Any]]=[]
        for index in 0..<5 {
            let image=Data("Synthetic belly RGB \(index), never physical evidence".utf8),depth=Data("Synthetic belly raw depth \(index)".utf8)
            let imageName="frame-\(index).jpg",depthName="frame-\(index).depth-u16le"
            try image.write(to:bellyCapture.appendingPathComponent(imageName));try depth.write(to:bellyCapture.appendingPathComponent(depthName))
            let frame:[String:Any]=["role":index<3 ? "fit":"validation","frameIndex":index,"sequence":index+10,
                "capturedAtMilliseconds":1000.0+Double(index),"imagePath":imageName,"imageSHA256":hash(image),
                "depthPath":depthName,"depthSHA256":hash(depth),"pixelCorrespondenceSupported":true,"pointCount":200]
            bellyFrames.append(frame);captureFrames.append(["sequence":index+10,"capturedAtMilliseconds":1000.0+Double(index),"imagePath":imageName,"depthPath":depthName])
        }
        let bellyInput=bellyCapture.appendingPathComponent("capture-input.json")
        try write(["schemaVersion":1,"kind":"belly_qr_capture","cameraRole":"belly","frames":captureFrames],to:bellyInput)
        let validBellyEvidence:[String:Any]=["schemaVersion":1,"kind":"belly_local_raw_floor_display_reference","cameraRole":"belly",
            "normalOptical":[normal.x,normal.y,normal.z],"offsetMeters":0.68,"fitFrameCount":3,"validationFrameCount":2,
            "fitPointCount":600,"validationPointCount":400,"fitRMSEMeters":0.002,"validationRMSEMeters":0.002,
            "validationP95AbsMeters":0.0042,"validationMaxAbsMeters":0.009,
            "rawDepthCorrected":false,"registrationVerified":false,"armMotionAuthority":false,"calibrationApplied":false,"physicalDepthMapAuthority":false,
            "sourceCaptureInputPath":bellyInput.path,"sourceCaptureInputSHA256":hash(try Data(contentsOf:bellyInput)),"sourceCapturePath":bellyCapture.path,
            "assumptions":["operatorConfirmedFloorFlat":true,"outlierDeletion":false],"frames":bellyFrames]
        func activateBellyEvidence(_ evidence:[String:Any])throws {
            try write(evidence,to:bellyEvidenceURL)
            a["bellyFloorDisplayReference"]=["evidencePath":bellyEvidenceURL.path,"evidenceSHA256":hash(try Data(contentsOf:bellyEvidenceURL))]
            try activate()
        }
        a["usePhotoHardwareOpticalOrigin"]=true;try activate()
        let beforeFloor=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
        let physicalBeforeFloor=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)!
        let bellyBeforeFloor=ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)!
        try activateBellyEvidence(validBellyEvidence)
        let floorPose=ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)!
        let floorFrames=ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)!,floorOptical=floorFrames["belly_oak_optical_frame"]!
        let floorUp=floorPose.modelToDisplay*floorOptical*SIMD4(normal,0)
        precondition(close(floorUp,SIMD4(0,0,1,0)),"Belly floor correction ignored the common QR-up gauge")
        precondition(floorPose.modelToDisplay != matrix_identity_double4x4,"Fixture did not exercise a nonidentity shared gauge")
        precondition(close(floorOptical.columns.3,originalBelly.columns.3),"Local floor correction moved the optical origin")
        for i in 0..<4 {precondition(close((simd_inverse(floorOptical)*floorFrames["belly_oak_link"]!)[i],originalMount[i]),"Floor correction detached housing from cloud")}
        let uncorrectedRotation=bellyBeforeFloor["belly_oak_optical_frame"]!
        let oldUp4=beforeFloor.modelToDisplay*uncorrectedRotation*SIMD4(normal,0)
        let displayDelta=beforeFloor.modelToDisplay*floorOptical*simd_inverse(uncorrectedRotation)*simd_inverse(beforeFloor.modelToDisplay)
        let trace=displayDelta.columns.0.x+displayDelta.columns.1.y+displayDelta.columns.2.z
        let turn=acos(min(1,max(-1,(trace-1)/2)))
        precondition(abs(turn-acos(min(1,max(-1,oldUp4.z))))<1e-8,"Floor normal alignment introduced an additional yaw/twist")
        precondition(floorOptical != uncorrectedRotation && floorPose.profileID != beforeFloor.profileID && floorPose.bellyFloorDisplayReferenceID != nil)
        precondition(floorPose.cameraToModel==beforeFloor.cameraToModel && floorPose.headFrames==beforeFloor.headFrames &&
            floorPose.modelToDisplay==beforeFloor.modelToDisplay && floorPose.provisionalCameraToModel==beforeFloor.provisionalCameraToModel &&
            floorPose.depthCloudCameraToModel==beforeFloor.depthCloudCameraToModel && !floorPose.hasDepthProjectionAuthority &&
            ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==physicalBeforeFloor,
            "Belly display evidence changed head/raw rotation, physical projection identity or depth authority")
        // A bare normal, edited source, rejected report or insufficient held-out
        // evidence cannot become a cosmetic pose merely by changing its hash.
        for field in ["kind","normalOptical","validationRMSEMeters","validationP95AbsMeters","validationMaxAbsMeters",
                      "fitFrameCount","registrationVerified","armMotionAuthority","rawDepthCorrected","physicalDepthMapAuthority",
                      "sourceCaptureInputSHA256","frames"] {
            var bad=validBellyEvidence
            switch field {
            case "kind":bad[field]="rejected"
            case "normalOptical":bad[field]=[0.0,-2.0,-1.0]
            case "validationRMSEMeters":bad[field]=0.005
            case "validationP95AbsMeters":bad[field]=0.010
            case "validationMaxAbsMeters":bad[field]=0.020
            case "fitFrameCount":bad[field]=2
            case "sourceCaptureInputSHA256":bad[field]=String(repeating:"f",count:64)
            case "frames":var badFrames=bellyFrames;badFrames[4]["pixelCorrespondenceSupported"]=false;bad[field]=badFrames
            default:bad[field]=true
            }
            try activateBellyEvidence(bad)
            precondition(ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)==nil,"Invalid belly evidence accepted: \(field)")
        }
        try activateBellyEvidence(validBellyEvidence)
        a["bellyFloorDisplayReference"]=["evidencePath":bellyEvidenceURL.path,"evidenceSHA256":String(repeating:"f",count:64)];try activate()
        precondition(ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)==nil,"Belly evidence SHA mismatch accepted")
        try activateBellyEvidence(validBellyEvidence)
        try Data("Changed held-out raw source".utf8).write(to:bellyCapture.appendingPathComponent("frame-4.depth-u16le"));try activate()
        precondition(ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)==nil,"Changed held-out raw depth accepted")
        a.removeValue(forKey:"bellyFloorDisplayReference");a.removeValue(forKey:"usePhotoHardwareOpticalOrigin")
        a["bellyCameraDownwardPitchDegrees"]=0.0;try activate()
        precondition(ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)!["belly_oak_optical_frame"]==originalBelly)
        a["bellyCameraDownwardPitchDegrees"]=61.0;try activate()
        precondition(ROBNeckRGBPoseDisplay.bellyPreviewFrames(model:model)==nil)
        a.removeValue(forKey:"bellyCameraDownwardPitchDegrees")
        for (key,value) in [("sourcePhotoSHA256","bad" as Any),("kind","wrong_kind" as Any),("lowerToUpperPivotMeters",0.4 as Any),
            ("sphereToRGBGlassMeters",0.49 as Any),("sphereForwardLeanDegrees",90.0 as Any),("cameraDepressionAtReferenceDegrees",91.0 as Any)] {
            let prior=hardware[key];hardware[key]=value;a["hardwarePose"]=hardware;try activate()
            precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6015,lowerTarget:6011,upperTarget:6160)==nil,"Invalid photo hardware option accepted: \(key)")
            hardware[key]=prior
        }
        a.removeValue(forKey:"hardwarePose")
        measured["cameraDistanceFromAssumedUpperCenterMeters"]=0.129;try measuredFit();try activate()
        a["modelID"]="wrong-model";try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)==nil)
        a["modelID"]=model.modelID;a["fitArtifactSHA256"]=String(repeating:"f",count:64);try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)==nil)
        a["fitArtifactSHA256"]=hash(try Data(contentsOf:fit))
        try Data("Changed source image".utf8).write(to:capture.appendingPathComponent("frame-0.jpg"));try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)==nil)
        print("PASS synthetic display: raw poses, torso gauge, rigid165/96.5/129 triangle, independent upright photo hardware with unchanged41mm optical fit, horizontal-default/bounded finite sphere ring, glued articulated mounts, belly floor minimum rotation after common gauge with fixed origin/physical identity and hashed3-fit/2-held-out evidence rejection")
    }
}
