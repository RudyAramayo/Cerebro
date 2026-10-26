import Foundation
import simd

private typealias Pixels=ROBWorkspaceSourcePixelSelf
private var pixelChecks=0
private func checkPixel(_ value:Bool,_ text:String) {
    pixelChecks+=1
    if !value {FileHandle.standardError.write(Data(("FAIL "+text+"\n").utf8));fatalError(text)}
}
private func pixelReject(_ text:String,_ operation:()throws->Void) {
    do {try operation();FileHandle.standardError.write(Data(("FAIL admitted "+text+"\n").utf8));fatalError(text)}catch {pixelChecks+=1}
}
private func jsonPixel(_ x:Any)throws->Data {try JSONSerialization.data(withJSONObject:x,options:[.sortedKeys])}
private func hashPixel(_ x:Data)->String {ROBGhostRobotModel.hash(x)}
private struct PixelPackage {
    let manifest:Data,sourceMap:Data,frames:[Pixels.ReplayFrame],review:Data,map:ROBWorkspaceCollisionSnapshot
}
private func pixelPackage(model:ROBGhostRobotModel,start:Double,modifyRGB:Bool=false,modifyDepth:Bool=false,projection:String?=nil,
    oneChangedContributor:Bool=false,proofScene:Bool=false,tableContact:Bool=false)throws->PixelPackage {
    let width=64,height=64,cam=UUID(),pid=projection ?? String(repeating:"a",count:64)
    var mapper=ROBWorkspaceDepthMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
        sessionGeneration:42,cameraGeneration:cam,nowMilliseconds:start,estimatedCameraProjectionIdentity:pid)
    var rgb=[UInt8](),seed:UInt64=938173
    for _ in 0..<width*height {seed=seed &* 6364136223846793005 &+ 1;let v=UInt8(40+(seed>>32)%170);rgb.append(contentsOf:[v,v,v])}
    if modifyRGB {for y in 4..<28 {for x in 4..<28 {rgb[(y*width+x)*3]=5;rgb[(y*width+x)*3+1]=5;rgb[(y*width+x)*3+2]=5}}}
    var depth=[UInt16](repeating:0,count:width*height)
    for y in 8...24 {for x in 8...24 {depth[y*width+x]=500}}
    for y in 8...24 {for x in 40...56 {depth[y*width+x]=500}}
    for y in 40...56 {for x in 8...24 {depth[y*width+x]=700}}
    if modifyDepth {for y in 8...24 {for x in 8...24 {depth[y*width+x]=540}}}
    var T=matrix_identity_double4x4;T.columns.3.z=0.5
    if proofScene {
        depth=Array(repeating:0,count:width*height)
        for y in 8...24 {for x in 8...24 {depth[y*width+x]=500}}
        let tool=model.toolPosition(model.positions(vendorLeft:Array(repeating:0,count:7)))!
        let table=SIMD3<Double>(-0.15,-0.24,0.35),ray=SIMD3<Double>(-0.004,-0.004,0.5),desired=table-tool
        func other(_ millimeters:Int)->SIMD3<Double> {let z=Double(millimeters)/1000;return SIMD3(-17*z/2000,15*z/2000,z)}
        let best=(100...3000).min{abs(simd_length(other($0)-ray)-simd_length(desired))<abs(simd_length(other($1)-ray)-simd_length(desired))}!
        T=simd_double4x4(simd_quatd(from:simd_normalize(other(best)-ray),to:simd_normalize(desired)))
        let transformed=T*SIMD4(ray,1);T.columns.3=SIMD4(tool-SIMD3(transformed.x,transformed.y,transformed.z),1)
        depth[47*width+15]=UInt16(tableContact ? 500:best)
    }
    var depthBytes=Data();for mm in depth {depthBytes.append(UInt8(mm&255));depthBytes.append(UInt8(mm>>8))}
    let columns=(0..<4).flatMap{c in (0..<4).map{T[c][$0]}}
    let runtime:[String:Any]=["schemaVersion":1,"actualDeviceMXID":"fixture-oak","cameraRole":"face","sdkVersion":"fixture1",
        "factoryEEPROMSHA256":String(repeating:"1",count:64),"effectiveRuntimeCalibrationSHA256":String(repeating:"2",count:64),
        "stereoPolicySHA256":String(repeating:"3",count:64),"candidateSHA256":NSNull(),"profileSHA256":NSNull()]
    let runtimeID=hashPixel(Data(["runtime-camera-calibration-v1","fixture-oak","face","fixture1",String(repeating:"1",count:64),String(repeating:"2",count:64),String(repeating:"3",count:64),"-","-"].joined(separator:"\n").utf8))
    let contracts=try jsonPixel(["rgbOutputUndistorted":true,"depthRGBGeometryCorrespondence":"matched","cameraServiceSourceSHA256":String(repeating:"4",count:64),"runtimeCalibrationIdentity":runtimeID])
    let sampling=try jsonPixel(["mapper":"ROBWorkspaceDepthMap.append_original_normalized_depth_v1","firstPixel":[1,1],"exclusivePixelUpperBound":[63,63],"stride":2,
        "acceptedDepthMillimeters":[100,3000],"depthUnits":"u16le_mm","sourceVoxelSizeMeters":0.025,"occupiedDilationOffsets":[-1,0,1],
        "workspaceLowMeters":[-2,-2,-0.3],"workspaceHighMeters":[2,2,2.4],"measuredSelfMaskApplied":false,"measuredSelfBounds":[],"registeredValidRobotVolume":NSNull()])
    let scope=try jsonPixel(["registrationID":NSNull(),"estimatedCameraProjectionIdentity":pid])
    func arm(_ side:String,_ now:Double)->[String:Any] {
        ["physicalSide":side,"gatewayArm":side=="left" ? "right":"left","telemetrySequence":100,"receivedAtHostMilliseconds":now,
         "effectiveSampleAgeMilliseconds":0,"effectiveGripperAgeMilliseconds":0,"positionsRadians":Array(repeating:0.0,count:7),
         "reportedModes":Array(repeating:0,count:7),"gatewayModes":Array(repeating:0,count:7),"modelID":model.modelID,"geometryID":model.geometryID,"mappingID":model.selectedMappingID]
    }
    var frames:[Pixels.ReplayFrame]=[],records:[[String:Any]]=[],reviews:[[String:Any]]=[],observations:[[String:Any]]=[]
    for n in 1...2 {
        let frameID=UUID(),time=start+Double(n)*10,sequence=UInt64(n)
        try mapper.append(width:width,height:height,fx:2000,fy:2000,cx:32,cy:32,depth:{x,y in depth[y*width+x]},cameraToRobot:T,
            capturedAtMilliseconds:time,sequence:sequence,cameraGeneration:cam,nowMilliseconds:time+1,recordedPanDegrees:0,
            recordedUpperTarget:5450,recordedLowerTarget:6011,estimatedCameraProjectionIdentity:pid)
        let neck:[String:Any]=["appliedPanTarget":6000,"appliedLowerTarget":6011,"appliedUpperTarget":5450,"observedAtHostMilliseconds":time,"stationary":true,"source":"synthetic actual-fixture source only"]
        let metadata:[String:Any]=["schemaVersion":1,"frameID":frameID.uuidString,"sequence":sequence,"capturedAtHostMilliseconds":time,"cameraGeneration":cam.uuidString,
            "width":width,"height":height,"rgbPath":"rgb888.raw","rgbSHA256":hashPixel(Data(rgb)),"depthPath":"depth-u16le.raw","depthSHA256":hashPixel(depthBytes),
            "intrinsics":[2000,2000,32,32],"sourceContractsJSON":contracts.base64EncodedString(),"runtimeCalibrationJSON":try jsonPixel(runtime).base64EncodedString(),
            "actualAppliedNeck":["value":neck],"physicalLeftFeedback":["value":arm("left",time)],"physicalRightFeedback":["value":arm("right",time)],
            "cameraToRobotColumnMajor":columns,"projectionMethod":"native_unregisteredCameraProjection_estimate_not_registration","projectionScopeJSON":scope.base64EncodedString(),
            "returnSamplingContractJSON":sampling.base64EncodedString(),"classificationAuthority":false,"motionAuthority":false]
        var actualMetadata=metadata,actualRGB=rgb
        if oneChangedContributor,n==2 {let i=(9*width+9)*3;actualRGB[i]=5;actualRGB[i+1]=5;actualRGB[i+2]=5}
        let rgbData=Data(actualRGB);actualMetadata["rgbSHA256"]=hashPixel(rgbData)
        let bytes=try jsonPixel(actualMetadata)
        frames.append(.init(metadataJSON:bytes,rgb888:rgbData,depthU16LittleEndian:depthBytes))
        let record:[String:Any]=["frameID":frameID.uuidString,"sequence":sequence,"capturedAtHostMilliseconds":time,"cameraGeneration":cam.uuidString,
            "relativeDirectory":frameID.uuidString,"rgbSHA256":hashPixel(rgbData),"depthSHA256":hashPixel(depthBytes),"metadataSHA256":hashPixel(bytes),"byteCount":bytes.count+rgbData.count+depthBytes.count]
        records.append(record)
        reviews.append(["frameID":frameID.uuidString,"sequence":sequence,"capturedAtHostMilliseconds":time,"cameraGeneration":cam.uuidString,"width":width,"height":height,
            "rgbSHA256":hashPixel(rgbData),"depthSHA256":hashPixel(depthBytes),"metadataSHA256":hashPixel(bytes),
            "robotPolygons":[[[4,4],[28,4],[28,28],[4,28]],[[36,4],[60,4],[60,28],[36,28]]],
            "protectedPolygons":[["label":"table","points":[[52,8],[58,8],[58,24],[52,24]]]]])
        observations.append(["sequence":sequence,"capturedAtHostMilliseconds":time,"cameraGeneration":cam.uuidString])
    }
    let map=mapper.snapshot(nowMilliseconds:start+30)!,e=JSONEncoder();e.outputFormatting=[.sortedKeys]
    let source=try e.encode(map),archiveID=UUID()
    let scene:[String:Any]=["archiveID":archiveID.uuidString,"workspaceSceneID":map.sceneID.uuidString,"bodyMotionIdentity":ROBFixedHeadBodyMotionIdentity.currentIdentity,
        "gatewayGeneration":42,"modelID":model.modelID,"referenceID":model.referenceID,"geometryID":model.geometryID,"mappingID":model.selectedMappingID]
    let manifest=try jsonPixel(["schemaVersion":1,"kind":"raw_workspace_pixel_provenance_only","scene":scene,"status":"complete","frames":records,
        "sourceMapBinding":["workspaceSceneID":map.sceneID.uuidString,"mapFingerprint":map.fingerprint,"relativePath":"source-map.json","serializedSHA256":hashPixel(source),"observations":observations],
        "classificationAuthority":false,"motionAuthority":false])
    let review=try jsonPixel(["schemaVersion":1,"kind":"experimental_robot_source_pixel_template","classificationBasis":"llm_visual_review_experimental",
        "reviewID":UUID().uuidString,"reviewedAtMilliseconds":start+40,"archiveDirectory":"/private/tmp/synthetic-pixel-fixture-never-live",
        "archiveManifestSHA256":hashPixel(manifest),"sourceMapSHA256":hashPixel(source),"mapFingerprint":map.fingerprint,"frames":reviews])
    return .init(manifest:manifest,sourceMap:source,frames:frames,review:review,map:map)
}
@main private enum PixelFixtures {
    static func main()throws {
        let model=try ROBGhostRobotModel(directory:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
        if CommandLine.arguments.count>2 {
            let reviewURL=URL(fileURLWithPath:CommandLine.arguments[2]),review=try Data(contentsOf:reviewURL),document=try JSONSerialization.jsonObject(with:review)as![String:Any]
            let root=URL(fileURLWithPath:document["archiveDirectory"]as!String),manifest=try Data(contentsOf:root.appendingPathComponent("manifest.json"))
            let object=try JSONSerialization.jsonObject(with:manifest)as![String:Any]
            let frames=try (object["frames"]as![[String:Any]]).map{record->Pixels.ReplayFrame in
                let directory=root.appendingPathComponent(record["relativeDirectory"]as!String)
                return .init(metadataJSON:try Data(contentsOf:directory.appendingPathComponent("frame.json")),rgb888:try Data(contentsOf:directory.appendingPathComponent("rgb888.raw")),depthU16LittleEndian:try Data(contentsOf:directory.appendingPathComponent("depth-u16le.raw")))
            }
            _=try Pixels.loadTemplate(reviewJSON:review,manifestJSON:manifest,sourceMapJSON:Data(contentsOf:root.appendingPathComponent("source-map.json")),frames:frames,model:model)
            print("PASS historical actual-source template load: native canonical fingerprint/all endpoints/groups/27unions verified; no current generation rebind or motion authority")
            return
        }
        let historical=try pixelPackage(model:model,start:1000)
        let template=try Pixels.loadTemplate(reviewJSON:historical.review,manifestJSON:historical.manifest,sourceMapJSON:historical.sourceMap,frames:historical.frames,model:model)
        ROBFixedHeadBodyMotionIdentity.invalidate()
        let current=try pixelPackage(model:model,start:2000,projection:String(repeating:"b",count:64))
        let originalEncoder=JSONEncoder();originalEncoder.outputFormatting=[.sortedKeys]
        let before=try originalEncoder.encode(current.map),beforeGroups=current.map.originalOccupiedSourceGroups,beforeFingerprint=current.map.fingerprint
        func classify(_ p:PixelPackage,now:Double=2040)throws->Pixels.View {
            try Pixels.classify(template:template,currentManifestJSON:p.manifest,currentSourceMapJSON:p.sourceMap,currentFrames:p.frames,map:p.map,model:model,nowMilliseconds:now)
        }
        let view=try classify(current)
        checkPixel(!view.audit.excludedGroups.isEmpty,"Fresh actual matching robot pixels did not classify any complete group")
        checkPixel(view.audit.excludedGroups.allSatisfy{$0.sourceVoxel[0]<0 && $0.sourceVoxel[1]<0},"Mixed table contributors were excluded")
        checkPixel(view.audit.retainedGroupCount>=2,"External/table groups were not retained")
        checkPixel(view.audit.historical.cameraGeneration != view.audit.current.cameraGeneration && view.audit.historical.bodyMotionIdentity != view.audit.current.bodyMotionIdentity,
            "Historical source IDs were restamped instead of independently matched")
        checkPixel(view.audit.historical.estimatedCameraProjectionIdentity != view.audit.current.estimatedCameraProjectionIdentity,"Pixel recognition falsely reused old projection identity")
        checkPixel(!view.audit.rawMapModified && !view.audit.unknownPromotedToFree && !view.audit.motionAuthority && !view.audit.measuredRegistration,"Perception record invented authority")
        checkPixel(try originalEncoder.encode(current.map)==before && current.map.originalOccupiedSourceGroups==beforeGroups &&
            current.map.fingerprint==beforeFingerprint,"Raw occupied/free map changed")
        checkPixel(current.map.state(at:SIMD3(1.5,1.5,1.5)) == .unknown,"Unknown space became free")
        let changedRGB=try pixelPackage(model:model,start:2000,modifyRGB:true)
        checkPixel(try classify(changedRGB).audit.excludedGroups.isEmpty,"Changed actual RGB was labelled robot from historical polygons")
        let changedDepth=try pixelPackage(model:model,start:2000,modifyDepth:true)
        checkPixel(try classify(changedDepth).audit.excludedGroups.isEmpty,"Changed actual depth was labelled robot from historical polygons")
        let partlyUnmatched=try pixelPackage(model:model,start:2000,oneChangedContributor:true)
        let partialView=try classify(partlyUnmatched)
        checkPixel(partialView.audit.excludedGroups.isEmpty,"One unmatched accepted return in another current frame did not retain the ENTIRE mixed group")
        checkPixel(partialView.audit.frames[0].classifiedAcceptedReturnCount>partialView.audit.frames[1].classifiedAcceptedReturnCount,
            "Across-frame negative did not exercise a single missing contributor")
        pixelReject("expired current evidence") {_=try classify(current,now:62_011)}
        var corrupt=historical.frames;let first=corrupt[0]
        var bad=first.rgb888;bad[0] ^= 1
        corrupt[0] = .init(metadataJSON:first.metadataJSON,rgb888:bad,depthU16LittleEndian:first.depthU16LittleEndian)
        pixelReject("tampered actual pixels") {_=try Pixels.loadTemplate(reviewJSON:historical.review,manifestJSON:historical.manifest,sourceMapJSON:historical.sourceMap,frames:corrupt,model:model)}
        pixelReject("missing source frame") {_=try Pixels.loadTemplate(reviewJSON:historical.review,manifestJSON:historical.manifest,sourceMapJSON:historical.sourceMap,frames:Array(historical.frames.dropLast()),model:model)}

        let proofReference=try pixelPackage(model:model,start:3000,proofScene:true)
        let proofTemplate=try Pixels.loadTemplate(reviewJSON:proofReference.review,manifestJSON:proofReference.manifest,sourceMapJSON:proofReference.sourceMap,frames:proofReference.frames,model:model)
        let proofCurrent=try pixelPackage(model:model,start:4000,proofScene:true)
        let proofView=try Pixels.classify(template:proofTemplate,currentManifestJSON:proofCurrent.manifest,currentSourceMapJSON:proofCurrent.sourceMap,
            currentFrames:proofCurrent.frames,map:proofCurrent.map,model:model,nowMilliseconds:4040)
        let m=proofCurrent.map,q=Array(repeating:0.0,count:7),h=String(repeating:"c",count:64)
        func pixelTrial(_ m:ROBWorkspaceCollisionSnapshot,_ now:Double)->ROBWorkspaceVisualCalibrationTrial {
            let scope=m.visualCalibrationScope!
            return ROBWorkspaceVisualCalibrationTrial(receiptID:"synthetic isolated one-shot receipt",receiptSHA256:h,appSessionID:"synthetic isolated app",
            command:"right_recycle_cans",canCount:4,summarySHA256:h,authorizationContextIdentity:"synthetic source-pixel fixture, NO native authority",
            sessionGeneration:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            mapFingerprint:m.fingerprint,bodyMotionIdentity:scope.bodyMotionIdentity,estimatedCameraProjectionIdentity:scope.estimatedCameraProjectionIdentity,
            observationPoseIdentity:scope.observationPoseIdentity,currentPoseIdentity:h,baseline:q,issuedAtMilliseconds:now,expiresAtMilliseconds:now+1000,assumedSpatialErrorMeters:0.035)
        }
        let trial=pixelTrial(m,4040)
        pixelReject("ordinary nominal lane still sees robot return") {_=try ROBWorkspaceCollisionPlan.reviewNominalEmptyCommissioningRetreat(from:q,map:m,model:model,
            generation:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,nowMilliseconds:4040,trial:trial,measuredAtMilliseconds:4040,
            nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:"operator_declared_empty")}
        let proof=try ROBWorkspaceCollisionPlan.reviewSourcePixelNominalEmptyCommissioningRetreat(from:q,map:m,model:model,generation:42,sceneID:m.sceneID,
            cameraGeneration:m.cameraGeneration,nowMilliseconds:4040,trial:trial,measuredAtMilliseconds:4040,nominalEmptyCommissioningEnabled:true,
            emptyStateEvidenceSource:"operator_declared_empty",sourcePixelSelfView:proofView)
        checkPixel(proof.goal==[0,-0.075,0,0,0,0,0] && proof.step.seconds==4 && proof.maximumHullTravelMeters<=0.06 && proof.endpointSelfMinimumMeters>=0.03,
            "Source-pixel proof changed the one-step/full-hull/self limits")
        checkPixel(proof.sourcePixelSelfAudit==proofView.audit && proof.modelAssumedSelfAudit==nil && !proof.occupiedVoxelsMutated,"Source proof lost its distinct perception source basis")
        try proof.validateSourcePixel(map:m,model:model,generation:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,nowMilliseconds:4040,trial:trial,
            measuredAtMilliseconds:4040,measuredBaseline:q,nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:"operator_declared_empty",sourcePixelSelfView:proofView)
        pixelReject("decoded-only source proof cannot enter ordinary validation") {try proof.validate(map:m,model:model,generation:42,sceneID:m.sceneID,
            cameraGeneration:m.cameraGeneration,nowMilliseconds:4040,trial:trial,measuredAtMilliseconds:4040,measuredBaseline:q,
            nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:"operator_declared_empty")}
        var drift=q;drift[0]=0.01
        pixelReject("actual q0 must match observed archive") {try proof.validateSourcePixelContext(map:m,model:model,generation:42,sceneID:m.sceneID,
            cameraGeneration:m.cameraGeneration,nowMilliseconds:4040,trial:trial,measuredAtMilliseconds:4040,measuredBaseline:drift,
            nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:"operator_declared_empty",sourcePixelSelfView:proofView)}
        pixelReject("OFF flag cannot admit source-pixel motion") {_=try ROBWorkspaceCollisionPlan.reviewSourcePixelNominalEmptyCommissioningRetreat(from:q,map:m,model:model,
            generation:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,nowMilliseconds:4040,trial:trial,measuredAtMilliseconds:4040,
            nominalEmptyCommissioningEnabled:false,emptyStateEvidenceSource:"operator_declared_empty",sourcePixelSelfView:proofView)}
        let contact=try pixelPackage(model:model,start:5000,proofScene:true,tableContact:true)
        let contactView=try Pixels.classify(template:proofTemplate,currentManifestJSON:contact.manifest,currentSourceMapJSON:contact.sourceMap,
            currentFrames:contact.frames,map:contact.map,model:model,nowMilliseconds:5040)
        checkPixel(!contactView.audit.excludedGroups.flatMap(\.contributors).contains{$0.x==15 && $0.y==47},"The actual table return was filtered as robot")
        checkPixel(contactView.audit.retainedGroupCount>0,"The table obstacle did not remain in the checked source groups")
        pixelReject("retained table contact still blocks full-hull motion") {_=try ROBWorkspaceCollisionPlan.reviewSourcePixelNominalEmptyCommissioningRetreat(from:q,map:contact.map,
            model:model,generation:42,sceneID:contact.map.sceneID,cameraGeneration:contact.map.cameraGeneration,nowMilliseconds:5040,trial:pixelTrial(contact.map,5040),
            measuredAtMilliseconds:5040,nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:"operator_declared_empty",sourcePixelSelfView:contactView)}
        print("PASS \(pixelChecks) actual-mapper source-pixel template/fresh replay/mixed table/all contributors/raw preservation/unknown/source tamper/freshness fixtures; no hardware or grants")
    }
}
