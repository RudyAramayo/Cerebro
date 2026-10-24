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
        precondition(pose.displayCameraToModel==pose.modelToDisplay*pose.cameraToModel)
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
        measured["cameraDistanceFromAssumedUpperCenterMeters"]=0.129;try measuredFit();try activate()
        a["modelID"]="wrong-model";try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)==nil)
        a["modelID"]=model.modelID;a["fitArtifactSHA256"]=String(repeating:"f",count:64);try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)==nil)
        a["fitArtifactSHA256"]=hash(try Data(contentsOf:fit))
        try Data("Changed source image".utf8).write(to:capture.appendingPathComponent("frame-0.jpg"));try activate()
        precondition(ROBNeckRGBPoseDisplay.pose(model:model,panTarget:6000,lowerTarget:6495,upperTarget:5900)==nil)
        print("PASS synthetic display: raw poses, torso gauge, rigid165/96.5/129 triangle, explicit azimuth/glass allowance, rejected41mm conflict, unchanged optical calibration and source/model/hash rejection")
    }
}
