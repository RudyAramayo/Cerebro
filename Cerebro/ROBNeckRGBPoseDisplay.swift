import Foundation
import CryptoKit
import simd

/// Per-robot, display-only articulated RGB fit. Never a registration store or
/// a collision/grasp capability. Raw depth is not corrected by this type.
enum ROBNeckRGBPoseDisplay {
    struct Pose {
        let profileID: String
        let cameraToModel: simd_double4x4
        let modelToDisplay: simd_double4x4
        let headFrames: [String:simd_double4x4]
        let headMount: HeadMountDescription?
        var displayCameraToModel: simd_double4x4 { modelToDisplay * cameraToModel }
        var hasDepthProjectionAuthority: Bool { false }
        var depressionRadians: Double {
            let d=displayCameraToModel.columns.2
            return -atan2(d.z,hypot(d.x,d.y))
        }
    }
    struct HeadMountDescription {
        let upperToSphereMeters:Double,sphereToGlassMeters:Double,upperToGlassMeters:Double
        let glassToOpticalDistanceMeters:Double
        let azimuthAssumption:String
    }
    private struct HeadMount:Decodable {
        let upperCenterToSphereMeters:Double,sphereToRGBGlassMeters:Double,upperCenterToRGBGlassMeters:Double
        let opticalCenterAllowanceMeters:Double
        let sphereAzimuthAssumption:String
        var valid:Bool {
            let a=upperCenterToSphereMeters,b=sphereToRGBGlassMeters,c=upperCenterToRGBGlassMeters
            return [a,b,c,opticalCenterAllowanceMeters].allSatisfy(\.isFinite) &&
                [a,b,c].allSatisfy{(0.02...0.5).contains($0)} && abs(a-b)<c && c<a+b &&
                (0.001...0.03).contains(opticalCenterAllowanceMeters) && sphereAzimuthAssumption=="closest_to_nominal"
        }
    }
    private struct Activation:Decodable {
        let schemaVersion:Int,kind:String,modelID:String,referenceID:String,geometryID:String
        let fitArtifactPath:String,fitArtifactSHA256:String,floorReferencePath:String,floorReferenceSHA256:String
        let headMount:HeadMount?
    }
    private struct Profile {
        let id:String,parameters:[String:Double],upTorso:SIMD3<Double>
        let headMount:HeadMount?
    }
    private static let lock=NSLock()
    private static var cachedKey=""
    private static var cachedProfile:Profile?
    static var activationURL:URL {
        if let path=ProcessInfo.processInfo.environment["ROB_NECK_RGB_DISPLAY_PROFILE"] {return URL(fileURLWithPath:path)}
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/NeckQRCalibration/ActiveRGBDisplayProfile.json")
    }
    private static func sha(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    private static func read(_ path:String,sha expected:String)throws->Data {
        guard expected.count==64,expected.allSatisfy(\.isHexDigit) else {throw Failure.invalid}
        let url=URL(fileURLWithPath:path)
        let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard values.isRegularFile==true,(values.fileSize ?? Int.max)<=10_000_000 else {throw Failure.invalid}
        let data=try Data(contentsOf:url);guard sha(data)==expected else {throw Failure.invalid};return data
    }
    private enum Failure:Error {case invalid}
    private static func profile(model:ROBGhostRobotModel)->Profile? {
        lock.lock();defer{lock.unlock()}
        guard let bytes=try? Data(contentsOf:activationURL),bytes.count<100_000 else {cachedKey="";cachedProfile=nil;return nil}
        let key=sha(bytes)+model.modelID+model.referenceID+model.geometryID
        if key==cachedKey {return cachedProfile}
        cachedKey=key;cachedProfile=nil
        do {
            let a=try JSONDecoder().decode(Activation.self,from:bytes)
            guard a.schemaVersion==1,a.kind=="provisional_rgb_neck_display",a.modelID==model.modelID,
                  a.referenceID==model.referenceID,a.geometryID==model.geometryID else {throw Failure.invalid}
            guard a.headMount?.valid ?? true else {throw Failure.invalid}
            let fitData=try read(a.fitArtifactPath,sha:a.fitArtifactSHA256)
            guard let fit=try JSONSerialization.jsonObject(with:fitData)as?[String:Any],
                  fit["status"]as?String=="conditional_torso_bundle_candidate_not_registered",
                  fit["modelID"]as?String==model.modelID,fit["registrationVerified"]as?Bool==false,
                  let pixel=fit["pixelModel"]as?[String:Any],pixel["fixedDistortionApplied"]as?Bool==false,
                  let p=fit["parameters"]as?[String:Double] else {throw Failure.invalid}
            let needed=["panScale","lowerScale","upperScale","lowerOffsetRadians","cameraDeltaRx","cameraDeltaRy","cameraDeltaRz","cameraDistanceFromAssumedUpperCenterMeters","cameraAzimuthRadians","cameraElevationRadians"]
            guard needed.allSatisfy({p[$0]?.isFinite==true}),["panScale","lowerScale","upperScale"].allSatisfy({(0.4...2.6).contains(p[$0]!)}),
                  abs(p["lowerOffsetRadians"]!)<=Double.pi/2,(0.001...0.5).contains(p[needed[7]]!) else {throw Failure.invalid}
            if let mount=a.headMount {
                guard abs(p[needed[7]]!-mount.upperCenterToRGBGlassMeters)<=mount.opticalCenterAllowanceMeters+1e-9 else {
                    throw Failure.invalid // Never stretch a disproved optical fit to make the mesh look right.
                }
            }
            let referenceData=try read(a.floorReferencePath,sha:a.floorReferenceSHA256)
            guard let floor=try JSONSerialization.jsonObject(with:referenceData)as?[String:Any],
                  let scope=floor["scope"]as?[String:Any],scope["modelID"]as?String==model.modelID,
                  let pan=scope["panTarget"]as?Int,let lower=scope["lowerTarget"]as?Int,let upper=scope["upperTarget"]as?Int,
                  let observations=floor["observations"]as?[[String:Any]],(3...128).contains(observations.count),
                  let capture=floor["sourceCapturePath"]as?String,let captureSHA=floor["sourceCaptureSHA256"]as?String else {throw Failure.invalid}
            _=try read(URL(fileURLWithPath:capture).appendingPathComponent("capture-input.json").path,sha:captureSHA)
            let C=try chain(model:model,parameters:p,panTarget:pan,lowerTarget:lower,upperTarget:upper).camera
            var up=SIMD3<Double>.zero
            for observation in observations {
                guard observation["targetID"]as?String=="ROB:FLOOR:R01" || observation["targetID"]as?String=="ROB:FLOOR:L01",
                      let normal=observation["floorNormalOptical"]as?[Double],normal.count==3,normal.allSatisfy(\.isFinite),
                      let index=observation["frameIndex"]as?Int,(0...255).contains(index),
                      let imageSHA=observation["imageSHA256"]as?String,
                      let rms=observation["reprojectionRMSPixels"]as?Double,rms.isFinite,rms<1.5,
                      let correlation=observation["correlation"]as?Double,correlation>=0.94,
                      observation["ambiguous"]as?Bool==false else {throw Failure.invalid}
                _=try read(URL(fileURLWithPath:capture).appendingPathComponent("frame-\(index).jpg").path,sha:imageSHA)
                let n=SIMD3(normal[0],normal[1],normal[2]);guard abs(simd_length(n)-1)<0.001,n.z<0 else {throw Failure.invalid}
                up += SIMD3((C*SIMD4(n,0)).x,(C*SIMD4(n,0)).y,(C*SIMD4(n,0)).z)
            }
            guard simd_length(up)>Double(observations.count)*0.99 else {throw Failure.invalid}
            cachedProfile=Profile(id:sha(bytes+fitData+referenceData),parameters:p,upTorso:simd_normalize(up),headMount:a.headMount)
        } catch {cachedProfile=nil}
        return cachedProfile
    }
    private static func translated(_ t:SIMD3<Double>)->simd_double4x4 {var T=matrix_identity_double4x4;T.columns.3=SIMD4(t,1);return T}
    private static func rotated(_ v:SIMD3<Double>)->simd_double4x4 {
        let a=simd_length(v);return a<1e-14 ? matrix_identity_double4x4:simd_double4x4(simd_quatd(angle:a,axis:v/a))
    }
    private static func chain(model:ROBGhostRobotModel,parameters p:[String:Double],panTarget:Int,lowerTarget:Int,upperTarget:Int,headMount:HeadMount?=nil)throws
        ->(camera:simd_double4x4,frames:[String:simd_double4x4]) {
        guard [panTarget,lowerTarget,upperTarget].allSatisfy({(3000...10000).contains($0)}) else {throw Failure.invalid}
        let reference=model.frames(model.reference)
        guard let upperReference=reference["upper_neck_link"],let opticalReference=reference["oak_optical_frame"],
              let oakReference=reference["oak_link"],let sphereReference=reference["insta360_link"] else {throw Failure.invalid}
        let c=Double.pi/6000
        let pan=translated(SIMD3(-0.0207044288303,0,0.355408962871))*rotated(SIMD3(0,0,Double(panTarget-6000)*c*p["panScale"]!))
        let lower=pan*rotated(SIMD3(0,Double(lowerTarget-6011)*c*p["lowerScale"]!+p["lowerOffsetRadians"]!,0))
        let upper=lower*translated(SIMD3(0,0,0.15579))*rotated(SIMD3(0,-Double(upperTarget-6906)*c*p["upperScale"]!,0))
        var mount=simd_inverse(upperReference)*opticalReference
        let radius=p["cameraDistanceFromAssumedUpperCenterMeters"]!,azimuth=p["cameraAzimuthRadians"]!,elevation=p["cameraElevationRadians"]!
        mount.columns.3=SIMD4(radius*cos(elevation)*cos(azimuth),radius*cos(elevation)*sin(azimuth),radius*sin(elevation),1)
        mount=mount*rotated(SIMD3(p["cameraDeltaRx"]!,p["cameraDeltaRy"]!,p["cameraDeltaRz"]!))
        let camera=upper*mount
        var frames=["neck_pan_link":pan,"lower_neck_link":lower,"upper_neck_link":upper,
            "oak_optical_frame":camera,"oak_link":camera*simd_inverse(simd_inverse(oakReference)*opticalReference),
            "insta360_link":upper*(simd_inverse(upperReference)*sphereReference)]
        if let headMount {
            let optical=SIMD3(mount.columns.3.x,mount.columns.3.y,mount.columns.3.z)
            let direction=simd_normalize(optical)
            // Choose the closest radius-constrained glass point. Its <=15mm
            // relation to the optical center remains an explicit uncertainty,
            // not a measured signed optical-axis offset.
            let glass=direction*headMount.upperCenterToRGBGlassMeters
            let nominalSphere=simd_inverse(upperReference)*sphereReference
            let nominal=SIMD3(nominalSphere.columns.3.x,nominalSphere.columns.3.y,nominalSphere.columns.3.z)
            var side=nominal-direction*simd_dot(nominal,direction)
            if simd_length(side)<1e-10 {side=simd_cross(direction,abs(direction.y)<0.9 ? SIMD3(0,1,0):SIMD3(1,0,0))}
            side=simd_normalize(side)
            let a=headMount.upperCenterToSphereMeters,b=headMount.sphereToRGBGlassMeters,c=headMount.upperCenterToRGBGlassMeters
            let cosine=(a*a+c*c-b*b)/(2*a*c)
            let sphere=a*(cosine*direction+sqrt(max(0,1-cosine*cosine))*side)
            var sphereFrame=nominalSphere;sphereFrame.columns.3=SIMD4(sphere,1)
            var glassFrame=mount;glassFrame.columns.3=SIMD4(glass,1)
            frames["insta360_link"]=upper*sphereFrame
            frames["rgb_glass_frame"]=upper*glassFrame
            frames["oak_link"]=upper*glassFrame*simd_inverse(simd_inverse(oakReference)*opticalReference)
        }
        return(camera,frames)
    }
    static func pose(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->Pose? {
        guard let profile=profile(model:model),let torso=model.frames(model.reference)["torso_link"],
              let value=try? chain(model:model,parameters:profile.parameters,panTarget:panTarget,lowerTarget:lowerTarget,upperTarget:upperTarget,headMount:profile.headMount) else {return nil}
        let up4=torso*SIMD4(profile.upTorso,0),up=simd_normalize(SIMD3(up4.x,up4.y,up4.z))
        let target=SIMD3<Double>(0,0,1),axis=simd_cross(up,target),length=simd_length(axis)
        let R=length<1e-12 ? matrix_identity_double4x4:rotated(axis/length*acos(min(1,max(-1,simd_dot(up,target)))))
        let center=SIMD3(torso.columns.3.x,torso.columns.3.y,torso.columns.3.z)
        let gauge=translated(center)*R*translated(-center)
        let description:HeadMountDescription?
        if let mount=profile.headMount,let glass=value.frames["rgb_glass_frame"] {
            description=HeadMountDescription(upperToSphereMeters:mount.upperCenterToSphereMeters,sphereToGlassMeters:mount.sphereToRGBGlassMeters,
                upperToGlassMeters:mount.upperCenterToRGBGlassMeters,glassToOpticalDistanceMeters:simd_distance(SIMD3(glass.columns.3.x,glass.columns.3.y,glass.columns.3.z),SIMD3(value.camera.columns.3.x,value.camera.columns.3.y,value.camera.columns.3.z)),
                azimuthAssumption:mount.sphereAzimuthAssumption)
        } else {description=nil}
        return Pose(profileID:profile.id,cameraToModel:torso*value.camera,modelToDisplay:gauge,
            headFrames:value.frames.mapValues{torso*$0},headMount:description)
    }
    static func cameraToModel(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->simd_double4x4? {
        pose(model:model,panTarget:panTarget,lowerTarget:lowerTarget,upperTarget:upperTarget)?.cameraToModel
    }
}
