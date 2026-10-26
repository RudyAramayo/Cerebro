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
        let headDepthDisplayLiftMeters: Double
        let robotModelDisplayLiftMeters:Double
        /// Operator-photo hardware drawing only. It deliberately omits the
        /// optical frame: the fitted QR ray and depth projection stay intact.
        let hardwareFrames: [String:simd_double4x4]?
        let hardwareSphereRingTiltDegrees: Double?
        let bellyPreviewDownwardPitchDegrees: Double?
        /// Saved raw-plane evidence affects the belly drawing only.
        let bellyFloorDisplayReferenceID: String?
        let usesPhotoHardwareOpticalOrigin: Bool
        let operatorPanCalibrationDescription: String?
        let frozenOpticalPitchRefinementRadians:Double?
        /// An opt-in estimated origin, not registration. Keep the pinned RGB
        /// rotation while drawing/projecting from the measured hardware glass.
        var provisionalCameraToModel: simd_double4x4 {
            guard usesPhotoHardwareOpticalOrigin,let glass=hardwareFrames?["rgb_glass_frame"] else{return cameraToModel}
            var result=cameraToModel;result.columns.3=glass.columns.3
            if let angle=frozenOpticalPitchRefinementRadians {
                // Post-optical-X: image-right and the optical origin stay
                // exactly unchanged. This is an estimated mounting refinement.
                let y=result.columns.1,z=result.columns.2,c=cos(angle),s=sin(angle)
                result.columns.1=c*y+s*z;result.columns.2 = -s*y+c*z
            }
            return result
        }
        var displayCameraToModel: simd_double4x4 { modelToDisplay * provisionalCameraToModel }
        var depthCloudCameraToModel: simd_double4x4 {
            var lift=matrix_identity_double4x4
            lift.columns.3.z=headDepthDisplayLiftMeters
            return lift * displayCameraToModel
        }
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
    /// A separate visual assembly, not a revised optical fit. Distances are
    /// measured, while the held-pose angles come from the operator's photo.
    private struct HardwarePose:Decodable {
        let kind:String
        let lowerUprightTarget:Int,upperReferenceTarget:Int
        let panForwardTarget:Int?
        let lowerToUpperPivotMeters:Double
        let upperCenterToSphereMeters:Double,sphereToRGBGlassMeters:Double,upperCenterToRGBGlassMeters:Double
        let sphereForwardLeanDegrees:Double,cameraDepressionAtReferenceDegrees:Double
        let sphereRingTiltAtReferenceDegrees:Double?
        let sourcePhotoSHA256:String
        var valid:Bool {
            let a=upperCenterToSphereMeters,b=sphereToRGBGlassMeters,c=upperCenterToRGBGlassMeters
            return kind=="operator_photo_hardware_pose" &&
                [lowerUprightTarget,upperReferenceTarget,panForwardTarget ?? 6000].allSatisfy{(3000...10000).contains($0)} &&
                [lowerToUpperPivotMeters,a,b,c,sphereForwardLeanDegrees,cameraDepressionAtReferenceDegrees].allSatisfy(\.isFinite) &&
                (0.08...0.25).contains(lowerToUpperPivotMeters) && [a,b,c].allSatisfy{(0.02...0.5).contains($0)} &&
                abs(a-b)<c && c<a+b && abs(sphereForwardLeanDegrees)<=45 &&
                (0...90).contains(cameraDepressionAtReferenceDegrees) &&
                (sphereRingTiltAtReferenceDegrees ?? 0).isFinite && abs(sphereRingTiltAtReferenceDegrees ?? 0)<=45 &&
                sourcePhotoSHA256.count==64 && sourcePhotoSHA256.allSatisfy(\.isHexDigit)
        }
    }
    private struct Activation:Decodable {
        let schemaVersion:Int,kind:String,modelID:String,referenceID:String,geometryID:String
        let fitArtifactPath:String,fitArtifactSHA256:String,floorReferencePath:String,floorReferenceSHA256:String
        let headMount:HeadMount?
        let headDepthDisplayLiftMeters:Double?
        let robotModelDisplayLiftMeters:Double?
        let hardwarePose:HardwarePose?
        let bellyCameraDownwardPitchDegrees:Double?
        let bellyFloorDisplayReference:BellyFloorDisplayReference?
        let usePhotoHardwareOpticalOrigin:Bool?
        let operatorPanCalibration:OperatorPanCalibration?
        let estimatedGravityPitchRefinement:GravityPitchReference?
    }
    private struct GravityPitchReference:Decodable {
        let evidencePath:String,evidenceSHA256:String
    }
    private struct GravityPitchEvidence:Decodable {
        struct Capture:Decodable {let role:String,captureInputPath:String,captureInputSHA256:String}
        let schemaVersion:Int,kind:String,method:String
        let modelID:String,referenceID:String,geometryID:String,mappingID:String
        let oldEstimatedCameraProjectionIdentity:String,bodyMotionIdentity:String
        let activeCameraGeneration:String,cameraRole:String,actualDeviceMXID:String
        let runtimeCalibrationIdentity:String,cameraServiceSourceSHA256:String
        let deltaRadians:Double?
        let referenceUpperTarget:Int?,interceptRadians:Double?,slopeRadiansPerRawUnit:Double?
        let registrationVerified:Bool,armMotionAuthority:Bool,rawDepthCorrected:Bool
        let modelBaseUpAssumed:Bool,opticalOriginPriorUnchanged:Bool,imageRightHeadingPriorUnchanged:Bool
        let captures:[Capture]
    }
    private struct PinnedGravitySource {
        let path:String,size:Int,modified:Date,fileNumber:UInt64
        init(_ path:String)throws {
            let a=try FileManager.default.attributesOfItem(atPath:path)
            guard a[.type]as?FileAttributeType == .typeRegular,let size=a[.size]as?NSNumber,
                  let modified=a[.modificationDate]as?Date,let number=a[.systemFileNumber]as?NSNumber else {throw Failure.invalid}
            self.path=path;self.size=size.intValue;self.modified=modified;fileNumber=number.uint64Value
        }
        var unchanged:Bool {
            guard let a=try?PinnedGravitySource(path) else{return false}
            return size==a.size && modified==a.modified && fileNumber==a.fileNumber
        }
    }
    private struct GravityPitch {
        let reference:GravityPitchReference,deltaRadians:Double,bodyMotionIdentity:String
        let referenceUpperTarget:Int?,slopeRadiansPerRawUnit:Double
        let cameraGeneration:UUID,runtimeCalibrationIdentity:String,cameraServiceSourceSHA256:String
        let sources:[PinnedGravitySource]
        func angle(upperTarget:Int)->Double {
            guard let referenceUpperTarget else{return deltaRadians}
            return deltaRadians+slopeRadiansPerRawUnit*Double(upperTarget-referenceUpperTarget)
        }
    }
    /// A measured operator angle and a provisional forward reference refine
    /// the estimated pan mapping. They never authorize a servo command.
    private struct OperatorPanCalibration:Decodable {
        let kind:String
        let forwardTarget:Int,anchorTarget:Int
        let anchorAngleDegrees:Double
        let evidencePath:String,evidenceSHA256:String
        var scale:Double {anchorAngleDegrees/Double(anchorTarget-forwardTarget)/0.03}
        var valid:Bool {
            kind=="operator_confirmed_linear_pan" &&
                [forwardTarget,anchorTarget].allSatisfy{(3000...10000).contains($0)} &&
                forwardTarget != anchorTarget && anchorAngleDegrees.isFinite &&
                (5...180).contains(abs(anchorAngleDegrees)) && scale.isFinite && (0.4...2.6).contains(scale)
        }
        var shortDescription:String {
            String(format:"pan %d = %+.1f° · forward %d provisional",anchorTarget,anchorAngleDegrees,forwardTarget)
        }
    }
    private struct OperatorPanEvidence:Decodable {
        let schemaVersion:Int,kind:String,modelID:String,referenceID:String,geometryID:String
        let forwardTarget:Int,anchorTarget:Int
        let anchorAngleDegrees:Double,recordedAtMilliseconds:Double
        let forwardReferenceProvisional:Bool,registrationVerified:Bool,armMotionAuthority:Bool
        let observationSource:String
    }
    private struct BellyFloorDisplayReference:Decodable {
        let evidencePath:String,evidenceSHA256:String
    }
    private struct BellyFloorDisplayEvidence:Decodable {
        struct Frame:Decodable {
            let role:String,frameIndex:Int,sequence:UInt64,capturedAtMilliseconds:Double
            let imagePath:String,imageSHA256:String,depthPath:String,depthSHA256:String
            let pixelCorrespondenceSupported:Bool,pointCount:Int
        }
        struct Assumptions:Decodable {
            let operatorConfirmedFloorFlat:Bool,outlierDeletion:Bool
        }
        let schemaVersion:Int,kind:String,cameraRole:String
        let normalOptical:[Double],offsetMeters:Double
        let fitFrameCount:Int,validationFrameCount:Int,fitPointCount:Int,validationPointCount:Int
        let fitRMSEMeters:Double,validationRMSEMeters:Double,validationP95AbsMeters:Double,validationMaxAbsMeters:Double
        let rawDepthCorrected:Bool,registrationVerified:Bool,armMotionAuthority:Bool,calibrationApplied:Bool,physicalDepthMapAuthority:Bool
        let sourceCaptureInputPath:String,sourceCaptureInputSHA256:String,sourceCapturePath:String
        let assumptions:Assumptions,frames:[Frame]
    }
    private struct Profile {
        let id:String,parameters:[String:Double],upTorso:SIMD3<Double>
        let headMount:HeadMount?
        let headDepthDisplayLiftMeters:Double
        let robotModelDisplayLiftMeters:Double
        let hardwarePose:HardwarePose?
        let bellyCameraDownwardPitchDegrees:Double?
        let bellyFloorNormalOptical:SIMD3<Double>?
        let bellyFloorDisplayReferenceID:String?
        let usePhotoHardwareOpticalOrigin:Bool
        let estimatedCameraProjectionIdentity:String?
        let operatorPanCalibration:OperatorPanCalibration?
        let gravityPitch:GravityPitch?
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
    private static func operatorPanEvidence(_ configuration:OperatorPanCalibration,model:ROBGhostRobotModel)throws->Data {
        guard configuration.valid else {throw Failure.invalid}
        let bytes=try read(configuration.evidencePath,sha:configuration.evidenceSHA256)
        guard bytes.count<100_000 else {throw Failure.invalid}
        let e=try JSONDecoder().decode(OperatorPanEvidence.self,from:bytes)
        guard e.schemaVersion==1,e.kind=="operator_confirmed_linear_pan_evidence",
              e.modelID==model.modelID,e.referenceID==model.referenceID,e.geometryID==model.geometryID,
              e.forwardTarget==configuration.forwardTarget,e.anchorTarget==configuration.anchorTarget,
              e.anchorAngleDegrees.isFinite,e.anchorAngleDegrees==configuration.anchorAngleDegrees,
              e.recordedAtMilliseconds.isFinite,e.recordedAtMilliseconds>0,e.forwardReferenceProvisional,
              e.observationSource=="operator_observed_physical_pan_angle",
              !e.registrationVerified,!e.armMotionAuthority else {throw Failure.invalid}
        return bytes
    }
    private static func gravityPitchEvidence(_ reference:GravityPitchReference,model:ROBGhostRobotModel,
        parameters:[String:Double],operatorPan:OperatorPanCalibration?,oldProjectionIdentity:String)throws->GravityPitch {
        let bytes=try read(reference.evidencePath,sha:reference.evidenceSHA256)
        guard bytes.count<100_000 else{throw Failure.invalid}
        let e=try JSONDecoder().decode(GravityPitchEvidence.self,from:bytes)
        let affine=e.method=="affine_training_upper_post_optical_x_preserve_origin_image_right_v1"
        if affine {
            guard e.deltaRadians==nil,let upper=e.referenceUpperTarget,(3000...10000).contains(upper),
                  let a=e.interceptRadians,a.isFinite,let b=e.slopeRadiansPerRawUnit,b.isFinite,
                  [3000,10000].allSatisfy({abs(a+b*Double($0-upper))<=20 * .pi/180}) else{throw Failure.invalid}
        } else {
            guard e.method=="mean_training_post_optical_x_preserve_origin_image_right_v1",
                  let delta=e.deltaRadians,delta.isFinite,abs(delta)<=20 * .pi/180,
                  e.referenceUpperTarget==nil,e.interceptRadians==nil,e.slopeRadiansPerRawUnit==nil else{throw Failure.invalid}
        }
        func hash(_ x:String)->Bool{x.count==64 && x.allSatisfy(\.isHexDigit)}
        guard e.schemaVersion==1,e.kind=="estimated_stationary_imu_optical_x_pitch_refinement",
              e.modelID==model.modelID,e.referenceID==model.referenceID,e.geometryID==model.geometryID,
              e.oldEstimatedCameraProjectionIdentity==oldProjectionIdentity,
              e.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity,UUID(uuidString:e.bodyMotionIdentity) != nil,
              let activeGeneration=UUID(uuidString:e.activeCameraGeneration),e.cameraRole=="face",
              !e.actualDeviceMXID.isEmpty,e.actualDeviceMXID.count<=128,
              hash(e.runtimeCalibrationIdentity),hash(e.cameraServiceSourceSHA256),
              !e.registrationVerified,!e.armMotionAuthority,!e.rawDepthCorrected,
              e.modelBaseUpAssumed,e.opticalOriginPriorUnchanged,e.imageRightHeadingPriorUnchanged,
              (4...16).contains(e.captures.count),Set(e.captures.map(\.captureInputPath)).count==e.captures.count,
              let torso=model.frames(model.reference)["torso_link"] else{throw Failure.invalid}
        // The capture UI's selected arm mapping is source provenance, not a
        // camera mounting parameter. Resolve either actual legal arm model;
        // never reflect arm FK or rewrite the captured mapping to the caller.
        let sourceModel:ROBGhostRobotModel
        if e.mappingID==model.selectedMappingID {sourceModel=model}
        else {
            let other=try ROBGhostRobotModel(directory:model.directory,physicalSide:model.physicalSide=="left" ? "right":"left")
            guard e.mappingID==other.selectedMappingID,other.modelID==model.modelID,
                  other.referenceID==model.referenceID,other.geometryID==model.geometryID,
                  other.reference==model.reference else{throw Failure.invalid}
            let a=model.frames(model.reference),b=other.frames(other.reference)
            guard ["torso_link","neck_pan_link","lower_neck_link","upper_neck_link","oak_link","oak_optical_frame","insta360_link"].allSatisfy({
                a[$0] != nil && a[$0]==b[$0]
            }) else{throw Failure.invalid}
            sourceModel=other
        }
        struct Row {let role:String,pose:String,upperTarget:Int,requiredPitch:Double,gravity:SIMD3<Double>,camera:simd_double4x4}
        var rows:[Row]=[],sources:[PinnedGravitySource]=[],totalRawBytes=0,heldGenerationSeen=false
        var commonSensor:String?,commonIMURotation:[Double]?
        func numbers(_ x:Any?,count:Int)throws->[Double] {
            guard let v=x as?[Double],v.count==count,v.allSatisfy(\.isFinite) else{throw Failure.invalid};return v
        }
        func runtimeMatches(_ r:[String:Any])->Bool {
            guard r["schemaVersion"]as?Int==1,r["actualDeviceMXID"]as?String==e.actualDeviceMXID,r["cameraRole"]as?String=="face",
                  let sdk=r["sdkVersion"]as?String,!sdk.isEmpty,sdk.count<=128,
                  let factory=r["factoryEEPROMSHA256"]as?String,hash(factory),
                  let effective=r["effectiveRuntimeCalibrationSHA256"]as?String,hash(effective),
                  let policy=r["stereoPolicySHA256"]as?String,hash(policy),r.keys.contains("candidateSHA256"),r.keys.contains("profileSHA256") else{return false}
            let candidate=r["candidateSHA256"]as?String,profile=r["profileSHA256"]as?String
            guard (candidate==nil)==(profile==nil),candidate.map(hash) ?? true,profile.map(hash) ?? true else{return false}
            return sha(Data(["runtime-camera-calibration-v1",e.actualDeviceMXID,"face",sdk,factory,effective,policy,
                candidate ?? "-",profile ?? "-"].joined(separator:"\n").utf8))==e.runtimeCalibrationIdentity
        }
        for capture in e.captures {
            guard ["training","held_out"].contains(capture.role),capture.captureInputPath.hasPrefix("/") else{throw Failure.invalid}
            let input=try read(capture.captureInputPath,sha:capture.captureInputSHA256)
            guard input.count<=2_000_000,let document=try JSONSerialization.jsonObject(with:input)as?[String:Any],
                  document["schemaVersion"]as?Int==1,document["cameraRole"]as?String=="face",
                  let scopeJSON=document["scope"]as?[String:Any],let frames=document["frames"]as?[[String:Any]],(3...8).contains(frames.count) else{throw Failure.invalid}
            let scope=try JSONDecoder().decode(ROBFixedHeadRegistrationScope.self,from:JSONSerialization.data(withJSONObject:scopeJSON))
            try scope.validate()
            guard scope.modelID==model.modelID,scope.geometryID==model.geometryID,scope.mappingID==e.mappingID,
                  scope.displayCorrectionIdentity.hasSuffix(":body:"+e.bodyMotionIdentity) else{throw Failure.invalid}
            let sourceChain=try chain(model:sourceModel,parameters:parameters,panTarget:scope.panTarget,
                lowerTarget:scope.lowerTarget,upperTarget:scope.upperTarget)
            let currentChain=try chain(model:model,parameters:parameters,panTarget:scope.panTarget,
                lowerTarget:scope.lowerTarget,upperTarget:scope.upperTarget)
            guard sourceChain.camera==currentChain.camera,sourceChain.frames==currentChain.frames else{throw Failure.invalid}
            var camera=torso * sourceChain.camera
            if let pan=operatorPan,scope.panTarget != pan.forwardTarget {
                let angle=Double(scope.panTarget-pan.forwardTarget)*Double.pi/6000*(pan.scale-parameters["panScale"]!)
                let pivot=SIMD3<Double>(-0.0207044288303,0,0.355408962871)
                camera=torso*translated(pivot)*rotated(SIMD3(0,0,angle))*translated(-pivot)*simd_inverse(torso)*camera
            }
            let root=URL(fileURLWithPath:capture.captureInputPath).deletingLastPathComponent().standardizedFileURL
            sources.append(try PinnedGravitySource(capture.captureInputPath))
            var directions:[SIMD3<Double>]=[],priorSequence:UInt64=0,priorTime=0.0,seenDepth=Set<String>(),seenIMU=Set<UInt64>()
            for (index,frame) in frames.enumerated() {
                guard let seq=frame["sequence"]as?UInt64,seq>priorSequence,
                      let time=frame["capturedAtMilliseconds"]as?Double,time.isFinite,time>priorTime,
                      frame["cameraGeneration"]as?String==scope.cameraGeneration.uuidString,
                      frame["runtimeCalibrationIdentity"]as?String==e.runtimeCalibrationIdentity,
                      frame["cameraServiceSourceSHA256"]as?String==e.cameraServiceSourceSHA256,
                      let runtime=frame["runtimeCalibration"]as?[String:Any],runtimeMatches(runtime),
                      frame["rgbOutputUndistorted"]as?Bool==true,
                      let geometry=frame["depthRGBGeometryCorrespondence"]as?[String:Any],geometry["status"]as?String=="matched",
                      let w=frame["width"]as?Int,let h=frame["height"]as?Int,(16...1920).contains(w),(16...1080).contains(h),
                      let depthPath=frame["depthPath"]as?String,depthPath=="frame-\(index).depth-u16le",
                      let depthSHA=frame["captureSHA256"]as?String,seenDepth.insert(depthSHA).inserted,
                      let imu=frame["imu"]as?[String:Any],imu["stationary"]as?Bool==true,
                      imu["axes"]as?String=="sensor_native",imu["gravity_source"]as?String=="stationary_accelerometer_mean",
                      let sensor=imu["sensor"]as?String,!sensor.isEmpty,sensor.count<=128,
                      let count=imu["sample_count"]as?Int,(10...1000).contains(count),
                      let window=imu["window_milliseconds"]as?Double,window.isFinite,(100...1000).contains(window),
                      let age=imu["age_milliseconds"]as?Double,age.isFinite,(0...100).contains(age),
                      let latest=imu["latest_timestamp_ns"]as?UInt64,latest>0,seenIMU.insert(latest).inserted,
                      let timestamp=imu["reference_timestamp_ns"]as?UInt64,timestamp>=latest,
                      abs(Double(timestamp-latest)/1e6-age)<=0.02 else{throw Failure.invalid}
                let depthURL=root.appendingPathComponent(depthPath),depth=try read(depthURL.path,sha:depthSHA)
                totalRawBytes+=depth.count
                guard depth.count==w*h*2,totalRawBytes<=64_000_000 else{throw Failure.invalid}
                sources.append(try PinnedGravitySource(depthURL.path))
                let gravity=try numbers(imu["gravity_mps2"],count:3),std=try numbers(imu["gravity_std_mps2"],count:3)
                let gyro=try numbers(imu["gyro_rad_s"],count:3),r=try numbers(imu["imu_to_rgb_rotation"],count:9)
                let rotation=simd_double3x3(columns:(SIMD3(r[0],r[3],r[6]),SIMD3(r[1],r[4],r[7]),SIMD3(r[2],r[5],r[8])))
                let g=SIMD3(gravity[0],gravity[1],gravity[2]),omega=SIMD3(gyro[0],gyro[1],gyro[2])
                guard (7...12).contains(simd_length(g)),std.allSatisfy({(0...0.1).contains($0)}),simd_length(omega)<=0.03,
                      abs(simd_determinant(rotation)-1)<=1e-6,
                      (0..<3).allSatisfy({i in (0..<3).allSatisfy({j in abs(simd_dot(rotation[i],rotation[j])-(i==j ? 1:0))<=1e-6})}),
                      commonSensor.map({$0==sensor}) ?? true,commonIMURotation.map({$0==r}) ?? true else{throw Failure.invalid}
                commonSensor=sensor;commonIMURotation=r;directions.append(simd_normalize(rotation*g));priorSequence=seq;priorTime=time
            }
            let sum=directions.reduce(SIMD3<Double>.zero,+)
            guard simd_length(sum)>=Double(directions.count)*0.99 else{throw Failure.invalid}
            let g=simd_normalize(sum)
            guard directions.allSatisfy({acos(min(1,max(-1,simd_dot($0,g))))<=Double.pi/180}) else{throw Failure.invalid}
            let s=SIMD3(camera.columns.0.z,camera.columns.1.z,camera.columns.2.z)
            guard hypot(g.y,g.z)>0.1,hypot(s.y,s.z)>0.1 else{throw Failure.invalid}
            let angle=atan2(s.z*g.y-s.y*g.z,s.y*g.y+s.z*g.z)
            rows.append(Row(role:capture.role,pose:"\(scope.panTarget):\(scope.lowerTarget):\(scope.upperTarget)",upperTarget:scope.upperTarget,
                requiredPitch:angle,gravity:g,camera:camera))
            if capture.role=="held_out",scope.cameraGeneration==activeGeneration {heldGenerationSeen=true}
        }
        let training=rows.filter{$0.role=="training"},held=rows.filter{$0.role=="held_out"},poses=Set(training.map(\.pose))
        guard training.count>=3,poses.count==training.count,!held.isEmpty,Set(held.map(\.pose)).count==held.count,
              held.allSatisfy({!poses.contains($0.pose)}),heldGenerationSeen else{throw Failure.invalid}
        let intercept:Double,slope:Double
        if affine {
            let upper=e.referenceUpperTarget!,low=training.map(\.upperTarget).min()!,high=training.map(\.upperTarget).max()!
            guard high-low>=500,(low...high).contains(upper) else{throw Failure.invalid}
            let xs=training.map{Double($0.upperTarget-upper)},ys=training.map(\.requiredPitch)
            let meanX=xs.reduce(0,+)/Double(xs.count),meanY=ys.reduce(0,+)/Double(ys.count)
            let variance=xs.reduce(0){$0+($1-meanX)*($1-meanX)}
            guard variance.isFinite,variance>0 else{throw Failure.invalid}
            let fittedSlope=zip(xs,ys).reduce(0){$0+($1.0-meanX)*($1.1-meanY)}/variance
            let fittedIntercept=meanY-fittedSlope*meanX
            guard fittedSlope.isFinite,fittedIntercept.isFinite,abs(fittedSlope-e.slopeRadiansPerRawUnit!)<=1e-12,
                  abs(fittedIntercept-e.interceptRadians!)<=1e-9 else{throw Failure.invalid}
            intercept=e.interceptRadians!;slope=e.slopeRadiansPerRawUnit!
        } else {
            let mean=training.map(\.requiredPitch).reduce(0,+)/Double(training.count)
            guard abs(mean-e.deltaRadians!)<=1e-9 else{throw Failure.invalid}
            intercept=e.deltaRadians!;slope=0
        }
        guard rows.allSatisfy({row in
            let delta=intercept+slope*Double(row.upperTarget-(e.referenceUpperTarget ?? row.upperTarget))
            let correction=rotated(SIMD3(delta,0,0))
            let projected=row.camera*correction*SIMD4(row.gravity,0)
            return acos(min(1,max(-1,projected.z)))<=Double.pi/180
        }) else{throw Failure.invalid}
        return GravityPitch(reference:reference,deltaRadians:intercept,bodyMotionIdentity:e.bodyMotionIdentity,
            referenceUpperTarget:e.referenceUpperTarget,slopeRadiansPerRawUnit:slope,
            cameraGeneration:activeGeneration,runtimeCalibrationIdentity:e.runtimeCalibrationIdentity,
            cameraServiceSourceSHA256:e.cameraServiceSourceSHA256,sources:sources)
    }
    private static func bellyFloorEvidence(_ reference:BellyFloorDisplayReference)throws->(Data,SIMD3<Double>) {
        let bytes=try read(reference.evidencePath,sha:reference.evidenceSHA256)
        let e=try JSONDecoder().decode(BellyFloorDisplayEvidence.self,from:bytes)
        guard e.schemaVersion==1,e.kind=="belly_local_raw_floor_display_reference",e.cameraRole=="belly",
              !e.rawDepthCorrected,!e.registrationVerified,!e.armMotionAuthority,!e.calibrationApplied,!e.physicalDepthMapAuthority,
              e.assumptions.operatorConfirmedFloorFlat,!e.assumptions.outlierDeletion,
              e.normalOptical.count==3,e.normalOptical.allSatisfy(\.isFinite),
              e.offsetMeters.isFinite,(0.1...3).contains(e.offsetMeters),
              e.fitFrameCount==3,e.validationFrameCount==2,e.frames.count==5,
              e.fitPointCount>=300,e.validationPointCount>=200,
              [e.fitRMSEMeters,e.validationRMSEMeters,e.validationP95AbsMeters,e.validationMaxAbsMeters].allSatisfy({$0.isFinite && $0>=0}),
              e.fitRMSEMeters<0.005,e.validationRMSEMeters<0.005,e.validationP95AbsMeters<0.010,e.validationMaxAbsMeters<0.020 else {throw Failure.invalid}
        let n=SIMD3(e.normalOptical[0],e.normalOptical[1],e.normalOptical[2])
        guard abs(simd_length(n)-1)<0.001,n.y<0,n.z<0 else {throw Failure.invalid}
        let captureURL=URL(fileURLWithPath:e.sourceCapturePath).standardizedFileURL
        guard URL(fileURLWithPath:e.sourceCaptureInputPath).standardizedFileURL==captureURL.appendingPathComponent("capture-input.json") else {throw Failure.invalid}
        let captureBytes=try read(e.sourceCaptureInputPath,sha:e.sourceCaptureInputSHA256)
        guard let capture=try JSONSerialization.jsonObject(with:captureBytes)as?[String:Any],
              capture["schemaVersion"]as?Int==1,capture["kind"]as?String=="belly_qr_capture",
              capture["cameraRole"]as?String=="belly",let capturedFrames=capture["frames"]as?[[String:Any]],
              Set(e.frames.map(\.frameIndex)).count==5,Set(e.frames.map(\.sequence)).count==5 else {throw Failure.invalid}
        var fitPoints=0,validationPoints=0,previousTime=0.0,previousSequence:UInt64=0
        for (index,frame) in e.frames.enumerated() {
            guard frame.role==(index<3 ? "fit":"validation"),frame.frameIndex>=0,frame.frameIndex<capturedFrames.count,
                  frame.sequence>previousSequence,frame.capturedAtMilliseconds.isFinite,frame.capturedAtMilliseconds>previousTime,
                  frame.pixelCorrespondenceSupported,frame.pointCount>=100,
                  let sequence=capturedFrames[frame.frameIndex]["sequence"]as?NSNumber,sequence.uint64Value==frame.sequence,
                  let time=capturedFrames[frame.frameIndex]["capturedAtMilliseconds"]as?Double,time==frame.capturedAtMilliseconds else {throw Failure.invalid}
            func sourceURL(_ path:String)->URL {
                (path.hasPrefix("/") ? URL(fileURLWithPath:path):captureURL.appendingPathComponent(path)).standardizedFileURL
            }
            guard let capturedImage=capturedFrames[frame.frameIndex]["imagePath"]as?String,
                  let capturedDepth=capturedFrames[frame.frameIndex]["depthPath"]as?String,
                  sourceURL(capturedImage)==sourceURL(frame.imagePath),sourceURL(capturedDepth)==sourceURL(frame.depthPath) else {throw Failure.invalid}
            _=try read(sourceURL(frame.imagePath).path,sha:frame.imageSHA256)
            _=try read(sourceURL(frame.depthPath).path,sha:frame.depthSHA256)
            if index<3 {fitPoints+=frame.pointCount}else{validationPoints+=frame.pointCount}
            previousTime=frame.capturedAtMilliseconds;previousSequence=frame.sequence
        }
        guard fitPoints==e.fitPointCount,validationPoints==e.validationPointCount else {throw Failure.invalid}
        return (bytes,n)
    }
    private static func profile(model:ROBGhostRobotModel)->Profile? {
        lock.lock();defer{lock.unlock()}
        guard let bytes=try? Data(contentsOf:activationURL),bytes.count<100_000 else {cachedKey="";cachedProfile=nil;return nil}
        let key=sha(bytes)+model.modelID+model.referenceID+model.geometryID+model.selectedMappingID
        if key==cachedKey,cachedProfile != nil {
            // Unlike appearance settings, an operator anchor is physical
            // projection provenance. Do not retain it after its pinned file
            // disappears or changes while the activation file stays fixed.
            if let pan=cachedProfile?.operatorPanCalibration,
               (try? read(pan.evidencePath,sha:pan.evidenceSHA256)) == nil {
                cachedKey="";cachedProfile=nil;return nil
            }
            if let pitch=cachedProfile?.gravityPitch,
               (pitch.bodyMotionIdentity != ROBFixedHeadBodyMotionIdentity.currentIdentity ||
                (try?read(pitch.reference.evidencePath,sha:pitch.reference.evidenceSHA256)) == nil ||
                !pitch.sources.allSatisfy(\.unchanged)) {
                cachedKey="";cachedProfile=nil;return nil
            }
            return cachedProfile
        }
        cachedKey=key;cachedProfile=nil
        do {
            let a=try JSONDecoder().decode(Activation.self,from:bytes)
            guard a.schemaVersion==1,a.kind=="provisional_rgb_neck_display",a.modelID==model.modelID,
                  a.referenceID==model.referenceID,a.geometryID==model.geometryID else {throw Failure.invalid}
            guard a.headMount?.valid ?? true else {throw Failure.invalid}
            guard a.hardwarePose?.valid ?? true else {throw Failure.invalid}
            guard a.usePhotoHardwareOpticalOrigin != true || a.hardwarePose != nil else {throw Failure.invalid}
            let panEvidence:Data?
            if let pan=a.operatorPanCalibration {
                guard a.usePhotoHardwareOpticalOrigin==true,let hardware=a.hardwarePose,
                      pan.forwardTarget==(hardware.panForwardTarget ?? 6000) else {throw Failure.invalid}
                panEvidence=try operatorPanEvidence(pan,model:model)
            } else {panEvidence=nil}
            let lift=a.headDepthDisplayLiftMeters ?? 0
            guard lift.isFinite,abs(lift)<=0.3048 else {throw Failure.invalid}
            let modelLift=a.robotModelDisplayLiftMeters ?? 0
            guard modelLift.isFinite,abs(modelLift)<=0.1 else {throw Failure.invalid}
            if let belly=a.bellyCameraDownwardPitchDegrees {
                guard belly.isFinite,(0...60).contains(belly) else {throw Failure.invalid}
            }
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
            let bellyEvidence=try a.bellyFloorDisplayReference.map{try bellyFloorEvidence($0)}
            let estimatedIdentity:String?
            if a.usePhotoHardwareOpticalOrigin==true,let h=a.hardwarePose {
                // Include only inputs to physical old-R/photo-origin-T and
                // their model/photo provenance, not cosmetic or display data.
                let keys=["panScale","lowerScale","upperScale","lowerOffsetRadians","cameraDeltaRx","cameraDeltaRy","cameraDeltaRz"]
                var physical:[String:Any]=["kind":"photo_hardware_optical_origin_v1","modelID":model.modelID,
                    "referenceID":model.referenceID,"geometryID":model.geometryID,
                    "opticalRotationParameters":Dictionary(uniqueKeysWithValues:keys.map{($0,p[$0]!)}),
                    "lowerUprightTarget":h.lowerUprightTarget,"upperReferenceTarget":h.upperReferenceTarget,
                    "panForwardTarget":h.panForwardTarget ?? 6000,"lowerToUpperPivotMeters":h.lowerToUpperPivotMeters,
                    "upperCenterToSphereMeters":h.upperCenterToSphereMeters,"sphereToRGBGlassMeters":h.sphereToRGBGlassMeters,
                    "upperCenterToRGBGlassMeters":h.upperCenterToRGBGlassMeters,"sphereForwardLeanDegrees":h.sphereForwardLeanDegrees,
                    "sourcePhotoSHA256":h.sourcePhotoSHA256]
                if let pan=a.operatorPanCalibration {
                    physical["operatorPanCalibration"]=["kind":pan.kind,"forwardTarget":pan.forwardTarget,
                        "anchorTarget":pan.anchorTarget,"anchorAngleDegrees":pan.anchorAngleDegrees,
                        "evidenceSHA256":pan.evidenceSHA256]
                }
                estimatedIdentity=sha(try JSONSerialization.data(withJSONObject:physical,options:[.sortedKeys]))
            }else{estimatedIdentity=nil}
            let gravityPitch:GravityPitch?
            let finalEstimatedIdentity:String?
            if let reference=a.estimatedGravityPitchRefinement {
                guard a.usePhotoHardwareOpticalOrigin==true,let old=estimatedIdentity else{throw Failure.invalid}
                gravityPitch=try gravityPitchEvidence(reference,model:model,parameters:p,operatorPan:a.operatorPanCalibration,oldProjectionIdentity:old)
                var identity:[String:Any]=["kind":"estimated_post_optical_x_pitch_v1",
                    "oldEstimatedCameraProjectionIdentity":old,"evidenceSHA256":reference.evidenceSHA256,
                    "deltaRadians":gravityPitch!.deltaRadians,"bodyMotionIdentity":gravityPitch!.bodyMotionIdentity,
                    "activeCameraGeneration":gravityPitch!.cameraGeneration.uuidString,
                    "runtimeCalibrationIdentity":gravityPitch!.runtimeCalibrationIdentity,
                    "cameraServiceSourceSHA256":gravityPitch!.cameraServiceSourceSHA256]
                if let upper=gravityPitch!.referenceUpperTarget {
                    identity["kind"]="estimated_affine_upper_post_optical_x_pitch_v1"
                    identity["referenceUpperTarget"]=upper;identity["slopeRadiansPerRawUnit"]=gravityPitch!.slopeRadiansPerRawUnit
                }
                finalEstimatedIdentity=sha(try JSONSerialization.data(withJSONObject:identity,options:[.sortedKeys]))
            }else{gravityPitch=nil;finalEstimatedIdentity=estimatedIdentity}
            cachedProfile=Profile(id:sha(bytes+fitData+referenceData+(bellyEvidence?.0 ?? Data())+(panEvidence ?? Data())),parameters:p,upTorso:simd_normalize(up),headMount:a.headMount,headDepthDisplayLiftMeters:lift,
                robotModelDisplayLiftMeters:modelLift,
                hardwarePose:a.hardwarePose,bellyCameraDownwardPitchDegrees:a.bellyCameraDownwardPitchDegrees,
                bellyFloorNormalOptical:bellyEvidence?.1,bellyFloorDisplayReferenceID:a.bellyFloorDisplayReference?.evidenceSHA256,
                usePhotoHardwareOpticalOrigin:a.usePhotoHardwareOpticalOrigin ?? false,estimatedCameraProjectionIdentity:finalEstimatedIdentity,
                operatorPanCalibration:a.operatorPanCalibration,gravityPitch:gravityPitch)
        } catch {cachedProfile=nil}
        return cachedProfile
    }
    private static func translated(_ t:SIMD3<Double>)->simd_double4x4 {var T=matrix_identity_double4x4;T.columns.3=SIMD4(t,1);return T}
    private static func rotated(_ v:SIMD3<Double>)->simd_double4x4 {
        let a=simd_length(v);return a<1e-14 ? matrix_identity_double4x4:simd_double4x4(simd_quatd(angle:a,axis:v/a))
    }
    private static func floorGaugeRotation(torso:simd_double4x4,upTorso:SIMD3<Double>)->simd_double4x4 {
        let value=torso*SIMD4(upTorso,0),up=simd_normalize(SIMD3(value.x,value.y,value.z))
        let axis=simd_cross(up,SIMD3<Double>(0,0,1)),length=simd_length(axis)
        return length<1e-12 ? matrix_identity_double4x4:rotated(axis/length*acos(min(1,max(-1,up.z))))
    }
    /// Profile identity is available without a current head-command estimate,
    /// so changing an explicit belly mount also invalidates its cloud cache.
    static func configurationIdentity(model:ROBGhostRobotModel)->String? {profile(model:model)?.id}
    static func operatorPanCalibrationDescription(model:ROBGhostRobotModel)->String? {profile(model:model)?.operatorPanCalibration?.shortDescription}
    static func estimatedCameraProjectionIdentity(model:ROBGhostRobotModel)->String? {profile(model:model)?.estimatedCameraProjectionIdentity}
    /// A frame-free pose cannot attest to the live camera source. Actual-frame
    /// consumers call this in addition to their held-pose and source gates.
    static func estimatedProjectionAcceptsSource(model:ROBGhostRobotModel,cameraGeneration:UUID,
        runtimeCalibrationIdentity:String?,cameraServiceSourceSHA256:String?)->Bool {
        guard let value=profile(model:model) else{return !gravityPitchRefinementRequested}
        guard let pitch=value.gravityPitch else{return true}
        return pitch.cameraGeneration==cameraGeneration && pitch.runtimeCalibrationIdentity==runtimeCalibrationIdentity &&
            pitch.cameraServiceSourceSHA256==cameraServiceSourceSHA256 && pitch.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity
    }
    private static var gravityPitchRefinementRequested:Bool {
        guard FileManager.default.fileExists(atPath:activationURL.path) else{return false}
        guard let data=try?Data(contentsOf:activationURL),data.count<100_000,
              let value=try?JSONSerialization.jsonObject(with:data)as?[String:Any] else{return true}
        return value["estimatedGravityPitchRefinement"] != nil
    }
    static func robotModelDisplayLiftMeters(model:ROBGhostRobotModel)->Double {profile(model:model)?.robotModelDisplayLiftMeters ?? 0}
    /// Child-group presentation only. Conjugate display-up through the common
    /// gauge so mesh lift stays vertical without translating camera rays or
    /// measured world overlays. This matrix is never a camera/model transform.
    static func robotModelPresentationTransform(model:ROBGhostRobotModel,modelToDisplay:simd_double4x4)->simd_double4x4 {
        let lift=robotModelDisplayLiftMeters(model:model)
        let local=simd_inverse(modelToDisplay)*SIMD4<Double>(0,0,lift,0)
        return translated(SIMD3(local.x,local.y,local.z))
    }
    /// Lets callers reject an invalid requested configuration rather than
    /// silently falling back to a different legacy physical projection.
    static var photoHardwareOpticalOriginRequested:Bool {
        guard let data=try? Data(contentsOf:activationURL),data.count<100_000,
              let value=try? JSONSerialization.jsonObject(with:data)as?[String:Any] else{return false}
        return value["usePhotoHardwareOpticalOrigin"]as?Bool == true
    }

    /// Canonical model frames only; the renderer applies its existing common
    /// display gauge once to body, housing and cloud. Raw depth is unchanged.
    static func bellyPreviewFrames(model:ROBGhostRobotModel)->[String:simd_double4x4]? {
        guard let profile=profile(model:model),profile.bellyCameraDownwardPitchDegrees != nil || profile.bellyFloorNormalOptical != nil else{return nil}
        let pitch=profile.bellyCameraDownwardPitchDegrees ?? 0
        let frames=model.frames(model.reference)
        guard let torso=frames["torso_link"],let optical=frames["belly_oak_optical_frame"],
              let housing=frames["belly_oak_link"] else{return nil}
        var torsoRotation=torso;torsoRotation.columns.3=SIMD4(0,0,0,1)
        let rotation=torsoRotation*rotated(SIMD3(0,pitch * .pi/180,0))*simd_inverse(torsoRotation)
        let center=SIMD3(optical.columns.3.x,optical.columns.3.y,optical.columns.3.z)
        var delta=translated(center)*rotation*translated(-center)
        if let normal=profile.bellyFloorNormalOptical {
            let gauge=floorGaugeRotation(torso:torso,upTorso:profile.upTorso)
            let projected=gauge*delta*optical*SIMD4(normal,0)
            let up=simd_normalize(SIMD3(projected.x,projected.y,projected.z))
            let axis=simd_cross(up,SIMD3<Double>(0,0,1)),length=simd_length(axis)
            guard up.z > 0 else{return nil}
            let correction=length<1e-12 ? matrix_identity_double4x4:rotated(axis/length*acos(min(1,max(-1,up.z))))
            // Minimum rotation AFTER the shared QR-up gauge; preserve the
            // optical origin and rigid housing mount. No yaw or position fit.
            let localCorrection=simd_inverse(gauge)*correction*gauge
            delta=translated(center)*localCorrection*translated(-center)*delta
        }
        return ["belly_oak_optical_frame":delta*optical,"belly_oak_link":delta*housing]
    }

    private static func hardwareFrames(model:ROBGhostRobotModel,parameters p:[String:Double],configuration h:HardwarePose,
        panTarget:Int,lowerTarget:Int,upperTarget:Int)throws->[String:simd_double4x4] {
        guard h.valid,[panTarget,lowerTarget,upperTarget].allSatisfy({(3000...10000).contains($0)}) else{throw Failure.invalid}
        let frames=model.frames(model.reference)
        guard let torso=frames["torso_link"],let opticalReference=frames["oak_optical_frame"],let oakReference=frames["oak_link"] else{throw Failure.invalid}
        let radiansPerRaw=Double.pi/6000
        // Preserve the canonical rearward neck pivot. The photo supplies a
        // zero at upright; its old fitted lower offset is not a hardware angle.
        let pan=translated(SIMD3(-0.0207044288303,0,0.355408962871))*rotated(SIMD3(0,0,Double(panTarget-(h.panForwardTarget ?? 6000))*radiansPerRaw*p["panScale"]!))
        let lower=pan*rotated(SIMD3(0,Double(lowerTarget-h.lowerUprightTarget)*radiansPerRaw*p["lowerScale"]!,0))
        let upper=lower*translated(SIMD3(0,0,h.lowerToUpperPivotMeters))*rotated(SIMD3(0,-Double(upperTarget-h.upperReferenceTarget)*radiansPerRaw*p["upperScale"]!,0))
        let a=h.upperCenterToSphereMeters,b=h.sphereToRGBGlassMeters,c=h.upperCenterToRGBGlassMeters
        let sphereLean=h.sphereForwardLeanDegrees * .pi/180
        let included=acos(min(1,max(-1,(a*a+c*c-b*b)/(2*a*c))))
        let glassLean=sphereLean+included // photographed forward/lower branch
        let sphere=translated(SIMD3(a*sin(sphereLean),0,a*cos(sphereLean)))
        let depression=h.cameraDepressionAtReferenceDegrees * .pi/180
        // Optical +X points image-right, +Y image-down, +Z forward. This
        // orientation belongs only to the visible glass/housing assembly.
        var glass=simd_double4x4(columns:(SIMD4(0,-1,0,0),SIMD4(-sin(depression),0,-cos(depression),0),
            SIMD4(cos(depression),0,-sin(depression),0),SIMD4(c*sin(glassLean),0,c*cos(glassLean),1)))
        glass=upper*glass
        let oakToOptical=simd_inverse(oakReference)*opticalReference
        return ["neck_pan_link":torso*pan,"lower_neck_link":torso*lower,"upper_neck_link":torso*upper,
            "insta360_link":torso*upper*sphere,"rgb_glass_frame":torso*glass,"oak_link":torso*glass*simd_inverse(oakToOptical)]
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
        let R=floorGaugeRotation(torso:torso,upTorso:profile.upTorso)
        let center=SIMD3(torso.columns.3.x,torso.columns.3.y,torso.columns.3.z)
        let gauge=translated(center)*R*translated(-center)
        let description:HeadMountDescription?
        if let mount=profile.headMount,let glass=value.frames["rgb_glass_frame"] {
            description=HeadMountDescription(upperToSphereMeters:mount.upperCenterToSphereMeters,sphereToGlassMeters:mount.sphereToRGBGlassMeters,
                upperToGlassMeters:mount.upperCenterToRGBGlassMeters,glassToOpticalDistanceMeters:simd_distance(SIMD3(glass.columns.3.x,glass.columns.3.y,glass.columns.3.z),SIMD3(value.camera.columns.3.x,value.camera.columns.3.y,value.camera.columns.3.z)),
                azimuthAssumption:mount.sphereAzimuthAssumption)
        } else {description=nil}
        var hardware:[String:simd_double4x4]?
        if let configuration=profile.hardwarePose {
            guard let value=try? hardwareFrames(model:model,parameters:profile.parameters,configuration:configuration,
                panTarget:panTarget,lowerTarget:lowerTarget,upperTarget:upperTarget) else{return nil}
            hardware=value
        } else{hardware=nil}
        var camera=torso*value.camera,headFrames=value.frames.mapValues{torso*$0}
        if let pan=profile.operatorPanCalibration,panTarget != pan.forwardTarget {
            // Apply one proper rigid correction to the entire current head
            // assembly and its optical rays about the physical pan pivot.
            // The original QR chain still defines historical floor evidence;
            // at the forward anchor no extra matrix products change the pose.
            let angle=Double(panTarget-pan.forwardTarget)*Double.pi/6000*(pan.scale-profile.parameters["panScale"]!)
            let pivot=SIMD3<Double>(-0.0207044288303,0,0.355408962871)
            let correction=torso*translated(pivot)*rotated(SIMD3(0,0,angle))*translated(-pivot)*simd_inverse(torso)
            camera=correction*camera
            headFrames=headFrames.mapValues{correction*$0}
            hardware=hardware?.mapValues{correction*$0}
        }
        return Pose(profileID:profile.id,cameraToModel:camera,modelToDisplay:gauge,
            headFrames:headFrames,headMount:description,headDepthDisplayLiftMeters:profile.headDepthDisplayLiftMeters,
            robotModelDisplayLiftMeters:profile.robotModelDisplayLiftMeters,
            hardwareFrames:hardware,hardwareSphereRingTiltDegrees:profile.hardwarePose.map{$0.sphereRingTiltAtReferenceDegrees ?? 0},
            bellyPreviewDownwardPitchDegrees:profile.bellyCameraDownwardPitchDegrees,
            bellyFloorDisplayReferenceID:profile.bellyFloorDisplayReferenceID,
            usesPhotoHardwareOpticalOrigin:profile.usePhotoHardwareOpticalOrigin,
            operatorPanCalibrationDescription:profile.operatorPanCalibration?.shortDescription,
            frozenOpticalPitchRefinementRadians:profile.gravityPitch?.angle(upperTarget:upperTarget))
    }
    static func cameraToModel(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->simd_double4x4? {
        pose(model:model,panTarget:panTarget,lowerTarget:lowerTarget,upperTarget:upperTarget)?.cameraToModel
    }
    static func provisionalCameraToModel(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->simd_double4x4? {
        guard let value=pose(model:model,panTarget:panTarget,lowerTarget:lowerTarget,upperTarget:upperTarget),value.usesPhotoHardwareOpticalOrigin else{return nil}
        return value.provisionalCameraToModel
    }
}
