import Foundation
import CryptoKit
import simd

/// One explicit, unregistered hypothesis for the reviewed EMPTY RIGHT probe.
/// This value cannot construct a measured registration, clear robot returns,
/// authorize travel, or enter the ordinary grasp lane.
struct ROBEstimatedFixedHeadCapture {
    typealias Context = ROBEstimatedFixedHeadCapture
    struct Package: Codable {
        let schemaVersion: Int
        let kind: String
        let purpose: String
        let rgbInputPath: String
        let rgbInputSHA256: String
        let depthReportPath: String
        let depthReportSHA256: String
        let parameterFitPath: String
        let parameterFitSHA256: String
        let pixelModelContractPath: String
        let pixelModelContractSHA256: String
        let captureDirectory: String
    }
    struct PixelHypotheses {
        let rawMillimeters: UInt16
        let correctedMillimeters: UInt16?
        let withinObservedPatch: Bool
        var unionMillimeters: [UInt16] {
            guard rawMillimeters>0 else {return []}
            if let correctedMillimeters,correctedMillimeters != rawMillimeters {return [rawMillimeters,correctedMillimeters]}
            return [rawMillimeters]
        }
    }
    let id: String
    let scope: ROBFixedHeadRegistrationScope
    let rgbEvidenceID: String
    let depthReportSHA256: String
    let packageSHA256: String
    let cameraServiceSourceSHA256: String
    let cameraToModel: simd_double4x4
    let rgbGeometryAllowanceMeters: Double
    let width: Int
    let height: Int
    let intrinsics: [Double]
    let inverseScale: Double
    let inverseBiasPerMeter: Double
    let rawDepthRangeMeters: ClosedRange<Double>
    let depthCandidateValidated: Bool
    let modelReferenceID: String
    var depthHypothesisID:String {id}
    var rgbOutputUndistorted:Bool {true}
    var bodyMotionIdentity:String {
        scope.displayCorrectionIdentity.components(separatedBy:":body:").last ?? ""
    }
    var measuredRegistrationVerified: Bool {false}
    var authorizesGrasp: Bool {false}
    private let torsoToModel: simd_double4x4
    private let patches: [Patch]

    private struct Patch {
        let polygon:[[Double]]
        let range:ClosedRange<Double>
    }
    private struct RGBWrapper:Decodable {let input:ROBNeckBundleRGBInput}
    private struct CaptureFrame:Decodable {
        let depthPath:String
        let width:Int
        let height:Int
        let intrinsics:[Double]
        let sequence:UInt64
        let capturedAtMilliseconds:Double
        let captureSHA256:String?
        let rgbOutputUndistorted:Bool?
        let cameraServiceSourceSHA256:String?
    }
    private struct CaptureDocument:Decodable {
        let scope:ROBFixedHeadRegistrationScope
        let frames:[CaptureFrame]
    }
    private struct SourceFrame {
        let scope:ROBFixedHeadRegistrationScope
        let frame:CaptureFrame
        let metadataSHA:String
        let metadataURL:URL
        let imageSHA:String
        let depthSHA:String
        let contractSHA:String
    }

    /// Import is read-only. All referenced artifacts and original captures must
    /// resolve inside the explicitly allowed Cerebro evidence directory.
    static func load(packageURL:URL,model:ROBGhostRobotModel,
                     expectedScope:ROBFixedHeadRegistrationScope,evidenceRoot:URL,
                     verifiedCameraServiceSourceSHA256:Set<String> = []) throws ->Self {
        func fail(_ text:String)throws->Never {throw ROBNeckBundleError.invalid(text)}
        let packageData=try read(packageURL,maximum:100_000)
        let package=try JSONDecoder().decode(Package.self,from:packageData)
        guard package.schemaVersion==1,package.kind=="estimated_fixed_head_raw_corrected_union",
              package.purpose=="empty_right_estimated_probe",model.physicalSide=="right",
              model.modelID==expectedScope.modelID,model.geometryID==expectedScope.geometryID,
              model.selectedMappingID==expectedScope.mappingID else {
            try fail("This package is only an estimated EMPTY physical RIGHT-arm probe in the current model.")
        }
        guard hex(package.pixelModelContractSHA256),verifiedCameraServiceSourceSHA256.contains(package.pixelModelContractSHA256) else {
            try fail("The camera-service source must match an independently verified current app-bundle hash.")
        }
        try expectedScope.validate()
        let root=evidenceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let base=packageURL.deletingLastPathComponent()
        func artifact(_ path:String,_ expected:String,_ maximum:Int)throws->(URL,Data) {
            let url=try allowed(path,relativeTo:base,root:root)
            let data=try read(url,maximum:maximum)
            guard hex(expected),digest(data)==expected else {try fail("An estimated-capture artifact hash changed: \(url.lastPathComponent)")}
            return(url,data)
        }
        let (_,rgbData)=try artifact(package.rgbInputPath,package.rgbInputSHA256,5_000_000)
        let (_,depthData)=try artifact(package.depthReportPath,package.depthReportSHA256,20_000_000)
        let (_,parameterData)=try artifact(package.parameterFitPath,package.parameterFitSHA256,5_000_000)
        _=try artifact(package.pixelModelContractPath,package.pixelModelContractSHA256,1_000_000)
        let input:ROBNeckBundleRGBInput
        if let direct=try? JSONDecoder().decode(ROBNeckBundleRGBInput.self,from:rgbData) {input=direct}
        else {input=try JSONDecoder().decode(RGBWrapper.self,from:rgbData).input}
        guard input.scope==expectedScope,input.parameterFitEvidenceSHA256==package.parameterFitSHA256,
              expectedScope.displayCorrectionIdentity.contains(":body:"),
              input.observations.allSatisfy({$0.outputPixelModel=="undistorted" && $0.distortion.allSatisfy({abs($0)<1e-15})}) else {
            try fail("Estimated capture must retain its exact live scope and zero-distortion output-pixel contract.")
        }
        // The package's own contract file is not a trust anchor. Its hash was
        // matched to the caller's independently read app bundle above; every
        // original frame must additionally record that same running service.
        try verifyParameters(parameterData,input.parameters,modelID:expectedScope.modelID)
        let frames=model.frames(model.reference)
        guard let upper=frames["upper_neck_link"],let optical=frames["oak_optical_frame"],
              let torso=frames["torso_link"],proper(upper),proper(optical),proper(torso) else {
            try fail("Pinned model reference frames are unavailable for the estimated camera gauge.")
        }
        let captureDirectory=try allowed(package.captureDirectory,relativeTo:base,root:root)
        let sources=try sourceFrames(directory:captureDirectory,root:root,
            wanted:Set(input.observations.map(\.metadataSHA256)),contractSHA:package.pixelModelContractSHA256)
        let rgb=try ROBNeckBundleRGBEvidence.validateRGB(input,expectedScope:expectedScope,
            nominalUpperToOptical:simd_inverse(upper)*optical,verifySource:{observation in
                sources.contains { source in
                    source.metadataSHA==observation.metadataSHA256 && source.imageSHA==observation.imageSHA256 &&
                    source.frame.sequence==observation.frameSequence && source.frame.capturedAtMilliseconds==observation.capturedAtMilliseconds &&
                    source.scope==observation.scope && source.frame.width==observation.width && source.frame.height==observation.height &&
                    source.frame.intrinsics==observation.intrinsics &&
                    (source.contractSHA==observation.pixelModelProvenanceSHA256 ||
                     source.frame.rgbOutputUndistorted==true && source.metadataSHA==observation.pixelModelProvenanceSHA256)
                }
            })
        let depth=try JSONSerialization.jsonObject(with:depthData) as? [String:Any] ?? [:]
        guard depth["schemaVersion"] as? Int==1,depth["kind"] as? String=="qr_native_depth_correction_diagnostic",
              depth["model"] as? String=="inverse_scale_bias",depth["registrationVerified"] as? Bool==false,
              depth["calibrationApplied"] as? Bool==false,
              let parameters=depth["parameters"] as? [Double],parameters.count==2,parameters.allSatisfy(\.isFinite),
              (0.5...1.5).contains(parameters[0]),abs(parameters[1])<=0.5,
              let physical=depth["physicalBounds"] as? [String:Any],physical["passed"] as? Bool==true,
              let domain=depth["domain"] as? [String:Any],
              let low=domain["rawDepthMinimumMeters"] as? Double,let high=domain["rawDepthMaximumMeters"] as? Double,
              low.isFinite,high.isFinite,0.05<=low,low<high,high<=4,
              let depthSources=depth["sources"] as? [[String:Any]],!depthSources.isEmpty else {
            try fail("Expected the frozen bounded near/far inverse-depth diagnostic; no measured depth authority is created.")
        }
        var scopesByID:[String:ROBFixedHeadRegistrationScope]=[:]
        let rangeGroups=Set(depthSources.compactMap{$0["rangeGroup"] as? String})
        let splits=Set(depthSources.compactMap{$0["split"] as? String})
        guard rangeGroups.count>=2,splits.contains("train"),splits.contains("heldout"),
              [low,high].allSatisfy({z in let d=parameters[0]/z+parameters[1];return d>0 && (0.65...1.35).contains(1/d/z)}) else {
            try fail("The depth hypothesis needs bounded near/far training and held-out sources.")
        }
        for source in depthSources {
            guard let identifier=source["id"] as? String,let scopeValue=source["scope"],
                  let scope=try? JSONDecoder().decode(ROBFixedHeadRegistrationScope.self,from:JSONSerialization.data(withJSONObject:scopeValue)),
                  sameEnvironment(scope,expectedScope),
                  let sequence=(source["frameSequence"] as? NSNumber)?.uint64Value,
                  let captured=source["capturedAtMilliseconds"] as? Double,
                  let imageSHA=source["sourceImageSHA256"] as? String,
                  let depthSHA=source["depthSHA256"] as? String,
                  let metadataSHA=source["captureInputSHA256"] as? String,
                  let k=source["cameraMatrix"] as? [Double],
                  let sourceWidth=source["width"] as? Int,let sourceHeight=source["height"] as? Int,
                  source["zeroDistortionAssumed"] as? Bool==true,
                  (source["distortionCoefficients"] as? [Double] ?? []).allSatisfy({abs($0)<1e-15}),
                  sources.contains(where:{$0.scope==scope && $0.frame.sequence==sequence &&
                      $0.frame.capturedAtMilliseconds==captured && $0.metadataSHA==metadataSHA &&
                      $0.imageSHA==imageSHA && $0.depthSHA==depthSHA && $0.frame.intrinsics==k &&
                      $0.frame.width==sourceWidth && $0.frame.height==sourceHeight}) else {
                try fail("Depth hypothesis sources do not match the original same-epoch RGB-D captures.")
            }
            scopesByID[identifier]=scope
        }
        let observations=input.observations
        guard let source=observations.first,observations.allSatisfy({$0.width==source.width && $0.height==source.height && $0.intrinsics==source.intrinsics}) else {
            try fail("Estimated capture uses one unchanged aligned optical pixel geometry.")
        }
        let patches=(domain["patches"] as? [[String:Any]] ?? []).compactMap {value->Patch? in
            guard let identifier=value["id"] as? String,let scope=scopesByID[identifier],
                  scope.panTarget==expectedScope.panTarget,scope.lowerTarget==expectedScope.lowerTarget,scope.upperTarget==expectedScope.upperTarget,
                  let polygon=value["interiorPolygonPixels"] as? [[Double]],polygon.count==4,
                  polygon.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}),
                  let a=value["rawDepthMinimumMeters"] as? Double,let b=value["rawDepthMaximumMeters"] as? Double,
                  a.isFinite,b.isFinite,a<=b else {return nil}
            return Patch(polygon:polygon,range:a...b)
        }
        let camera=torso*rgb.cameraToTorso
        guard proper(camera) else {try fail("Estimated camera composition is not a proper rigid model-frame transform.")}
        let packageSHA=digest(packageData)
        let identity=digest(Data((packageSHA+rgb.id+package.depthReportSHA256+model.referenceID).utf8))
        return Self(id:identity,scope:expectedScope,rgbEvidenceID:rgb.id,
            depthReportSHA256:package.depthReportSHA256,packageSHA256:packageSHA,
            cameraServiceSourceSHA256:package.pixelModelContractSHA256,cameraToModel:camera,
            rgbGeometryAllowanceMeters:rgb.rgbGeometryAllowanceMeters,width:source.width,height:source.height,
            intrinsics:source.intrinsics,inverseScale:parameters[0],inverseBiasPerMeter:parameters[1],
            rawDepthRangeMeters:low...high,depthCandidateValidated:depth["candidateValidated"] as? Bool ?? false,
            modelReferenceID:model.referenceID,torsoToModel:torso,patches:patches)
    }

    func matches(currentScope:ROBFixedHeadRegistrationScope,model:ROBGhostRobotModel)->Bool {
        guard currentScope==scope,model.physicalSide=="right",model.modelID==scope.modelID,
              model.geometryID==scope.geometryID,model.selectedMappingID==scope.mappingID,
              model.referenceID==modelReferenceID,let current=model.frames(model.reference)["torso_link"] else {return false}
        return (0..<4).allSatisfy{c in (0..<4).allSatisfy{abs(current[c][$0]-torsoToModel[c][$0])<1e-12}}
    }

    /// Raw is always retained. The second return is an estimated alternative,
    /// never a corrected measurement or permission to erase the first return.
    func hypotheses(x:Int,y:Int,rawMillimeters:UInt16)->PixelHypotheses {
        guard (0..<width).contains(x),(0..<height).contains(y),rawMillimeters>0 else {
            return .init(rawMillimeters:rawMillimeters,correctedMillimeters:nil,withinObservedPatch:false)
        }
        let raw=Double(rawMillimeters)/1000
        let observed=patches.contains{$0.range.contains(raw) && Self.inside(Double(x),Double(y),$0.polygon)}
        guard rawDepthRangeMeters.contains(raw) else {return .init(rawMillimeters:rawMillimeters,correctedMillimeters:nil,withinObservedPatch:observed)}
        return .init(rawMillimeters:rawMillimeters,correctedMillimeters:correctedMillimeters(raw:rawMillimeters),withinObservedPatch:observed)
    }

    func correctedMillimeters(raw:UInt16)->UInt16? {
        let z=Double(raw)/1000
        guard raw>0,rawDepthRangeMeters.contains(z) else {return nil}
        let denominator=inverseScale/z+inverseBiasPerMeter,corrected=1/denominator
        guard denominator>0,corrected.isFinite,(0.65...1.35).contains(corrected/z),
              (0.001...65.535).contains(corrected) else {return nil}
        return UInt16((corrected*1000).rounded())
    }

    func opticalPoints(x:Int,y:Int,rawMillimeters:UInt16)->[SIMD3<Double>] {
        guard (0..<width).contains(x),(0..<height).contains(y) else {return []}
        let ray=SIMD3((Double(x)-intrinsics[2])/intrinsics[0],(Double(y)-intrinsics[3])/intrinsics[1],1)
        return hypotheses(x:x,y:y,rawMillimeters:rawMillimeters).unionMillimeters.map{ray*(Double($0)/1000)}
    }

    var metadata:[String:Any] {[
        "kind":"estimated_fixed_head_raw_corrected_union","id":id,"physical_arm":"right",
        "measured_registration_verified":false,"grasp_authorized":false,"rgb_evidence_id":rgbEvidenceID,
        "depth_report_sha256":depthReportSHA256,"package_sha256":packageSHA256,
        "camera_service_source_sha256":cameraServiceSourceSHA256,"rgb_output_undistorted":rgbOutputUndistorted,
        "depth_candidate_validated":depthCandidateValidated,"rgb_geometry_allowance_m":rgbGeometryAllowanceMeters,
        "raw_depth_range_m":[rawDepthRangeMeters.lowerBound,rawDepthRangeMeters.upperBound],
        "inverse_depth_hypothesis":[inverseScale,inverseBiasPerMeter],"body_motion_identity":bodyMotionIdentity,
        "camera_generation":scope.cameraGeneration.uuidString,"gateway_session_generation":scope.gatewaySessionGeneration,
        "neck_targets":[scope.panTarget,scope.lowerTarget,scope.upperTarget],"intrinsics":intrinsics,
        "model_reference_id":modelReferenceID,
        "camera_gauge":"Pinned model.reference torso; CAD/body pose assumption, not measured world registration",
        "occupied_return_policy":"Retain ALL raw returns plus bounded corrected alternatives; no robot self mask",
        "scope":"Exact head/model/mapping/camera/intrinsics/gateway/body epoch; no rebinding",
        "correction_status":"Estimated hypothesis; outside observed QR UV patches is explicitly unvalidated"]}

    private static func sourceFrames(directory:URL,root:URL,wanted:Set<String>,contractSHA:String)throws->[SourceFrame] {
        guard let enumerator=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else {
            throw ROBNeckBundleError.invalid("Original capture directory is unavailable.")
        }
        var output:[SourceFrame]=[],found=Set<String>(),count=0
        for case let url as URL in enumerator where url.lastPathComponent=="capture-input.json" {
            count+=1;guard count<=2048 else {throw ROBNeckBundleError.invalid("Capture evidence index exceeded its bound.")}
            let safe=try allowed(url.path,relativeTo:directory,root:root),bytes=try read(safe,maximum:2_000_000),sha=digest(bytes)
            guard wanted.contains(sha) else {continue}
            let doc=try JSONDecoder().decode(CaptureDocument.self,from:bytes)
            guard doc.frames.count<=256 else {throw ROBNeckBundleError.invalid("Capture frame count exceeds the bounded evidence index.")}
            for frame in doc.frames {
                let depth=try allowed(frame.depthPath,relativeTo:safe.deletingLastPathComponent(),root:root)
                let jpg=try allowed(depth.deletingPathExtension().appendingPathExtension("jpg").path,relativeTo:safe.deletingLastPathComponent(),root:root)
                let depthData=try read(depth,maximum:10_000_000),image=try read(jpg,maximum:10_000_000)
                guard (16...1920).contains(frame.width),(16...1200).contains(frame.height),
                      frame.intrinsics.count==4,frame.intrinsics.allSatisfy(\.isFinite),
                      frame.sequence>0,frame.capturedAtMilliseconds.isFinite,frame.capturedAtMilliseconds>0,
                      depthData.count==frame.width*frame.height*2,
                      frame.captureSHA256.map({$0==digest(depthData)}) ?? true,
                      frame.rgbOutputUndistorted==true,
                      frame.cameraServiceSourceSHA256==contractSHA else {
                    throw ROBNeckBundleError.invalid("Original frame lacks the verified running camera-service hash and explicit undistorted output. Legacy captures are offline analysis only.")
                }
                output.append(.init(scope:doc.scope,frame:frame,metadataSHA:sha,metadataURL:safe,
                    imageSHA:digest(image),depthSHA:digest(depthData),contractSHA:frame.cameraServiceSourceSHA256!))
            }
            found.insert(sha)
        }
        guard found==wanted else {throw ROBNeckBundleError.invalid("Original metadata hashes could not all be resolved inside the allowed capture root.")}
        return output
    }

    private static func verifyParameters(_ data:Data,_ expected:ROBNeckBundleParameters,modelID:String)throws {
        let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
        guard json["status"] as? String=="conditional_torso_bundle_candidate_not_registered",
              json["modelID"] as? String==modelID,json["registrationVerified"] as? Bool==false,
              (json["pixelModel"] as? [String:Any])?["fixedDistortionApplied"] as? Bool==false,
              let p=json["parameters"] as? [String:Double],
              let pan=p["panScale"],let lower=p["lowerScale"],let upper=p["upperScale"],let offset=p["lowerOffsetRadians"],
              let rx=p["cameraDeltaRx"],let ry=p["cameraDeltaRy"],let rz=p["cameraDeltaRz"],
              let radius=p["cameraDistanceFromAssumedUpperCenterMeters"],let azimuth=p["cameraAzimuthRadians"],let elevation=p["cameraElevationRadians"] else {
            throw ROBNeckBundleError.invalid("Frozen parameter artifact is not the referenced neck-bundle candidate.")
        }
        let actual=[pan,lower,upper,offset,rx,ry,rz,radius*cos(elevation)*cos(azimuth),radius*cos(elevation)*sin(azimuth),radius*sin(elevation)]
        let values=[expected.panScale,expected.lowerScale,expected.upperScale,expected.lowerOffsetRadians]+expected.cameraDeltaRotationVector+expected.cameraTranslationMeters
        guard actual.count==values.count,zip(actual,values).allSatisfy({$0.isFinite && $1.isFinite && abs($0-$1)<1e-10}) else {
            throw ROBNeckBundleError.invalid("RGB input parameters differ from the immutable frozen fit artifact.")
        }
    }
    private static func allowed(_ path:String,relativeTo base:URL,root:URL)throws->URL {
        let url=(path.hasPrefix("/") ? URL(fileURLWithPath:path):base.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path+"/") else {throw ROBNeckBundleError.invalid("Package references must stay inside the allowed Cerebro evidence root.")}
        return url
    }
    private static func read(_ url:URL,maximum:Int)throws->Data {
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile==true,let size=values.fileSize,size>=0,size<=maximum else {throw ROBNeckBundleError.invalid("Evidence file is missing, nonregular or exceeds its size bound.")}
        return try Data(contentsOf:url)
    }
    private static func sameEnvironment(_ a:ROBFixedHeadRegistrationScope,_ b:ROBFixedHeadRegistrationScope)->Bool {
        a.modelID==b.modelID && a.geometryID==b.geometryID && a.mappingID==b.mappingID && a.cameraGeneration==b.cameraGeneration &&
        a.gatewaySessionGeneration==b.gatewaySessionGeneration && a.displayCorrectionIdentity==b.displayCorrectionIdentity && a.intrinsicsIdentity==b.intrinsicsIdentity
    }
    private static func inside(_ x:Double,_ y:Double,_ p:[[Double]])->Bool {
        var sign=0.0
        for i in p.indices {let a=p[i],b=p[(i+1)%p.count],cross=(b[0]-a[0])*(y-a[1])-(b[1]-a[1])*(x-a[0]);if abs(cross)<1e-9 {continue};if sign==0 {sign=cross};if cross*sign<0 {return false}}
        return true
    }
    private static func proper(_ T:simd_double4x4)->Bool {
        let R=simd_double3x3(SIMD3(T.columns.0.x,T.columns.0.y,T.columns.0.z),SIMD3(T.columns.1.x,T.columns.1.y,T.columns.1.z),SIMD3(T.columns.2.x,T.columns.2.y,T.columns.2.z))
        return (0..<4).allSatisfy{c in (0..<4).allSatisfy{T[c][$0].isFinite}} && abs(simd_determinant(R)-1)<1e-7 &&
            (0..<3).allSatisfy{abs(simd_length(R[$0])-1)<1e-7} && abs(simd_dot(R[0],R[1]))+abs(simd_dot(R[0],R[2]))+abs(simd_dot(R[1],R[2]))<1e-7 &&
            abs(T.columns.0.w)+abs(T.columns.1.w)+abs(T.columns.2.w)+abs(T.columns.3.w-1)<1e-9
    }
    private static func hex(_ text:String)->Bool {text.utf8.count==64 && text.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}
