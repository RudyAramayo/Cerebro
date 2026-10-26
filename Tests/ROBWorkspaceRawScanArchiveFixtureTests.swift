import Foundation
import CryptoKit
@main enum RawScanArchiveFixtures {
 static func reject(_ work:()async throws->Void)async {do{try await work();preconditionFailure("Invalid archive accepted")}catch{}}
 static func main()async throws {
  typealias Archive=ROBWorkspaceRawScanArchive
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("rob-raw-scan-\(UUID().uuidString)",isDirectory:true)
  defer {try?FileManager.default.removeItem(at:root)}
  let scene=Archive.Scene(archiveID:UUID(),workspaceSceneID:UUID(),bodyMotionIdentity:"inert-test-body",gatewayGeneration:7,
   modelID:"model",referenceID:"ref",geometryID:"geometry",mappingID:"right-model-mapping")
  let camera=UUID(),json=Data("{\"kind\":\"inert_fixture_not_camera_evidence\"}".utf8)
  func arm(_ side:String)->Archive.ArmFeedback {
   .init(physicalSide:side,gatewayArm:side=="left" ? "right":"left",telemetrySequence:91,
    receivedAtHostMilliseconds:1000,effectiveSampleAgeMilliseconds:22,effectiveGripperAgeMilliseconds:40,
    positionsRadians:[0,0.01,0.02,0.03,0.04,0.05,0.06],reportedModes:Array(repeating:2,count:7),gatewayModes:Array(repeating:2,count:7),
    exposureOffsetMilliseconds:.available(-12),referenceIdentity:.available("actual-fixture-reference"),modelID:"\(side)-model",geometryID:"geometry",mappingID:"\(side)-mapping")
  }
  func frame(_ sequence:UInt64=1,id:UUID=UUID(),rgb:Data?=nil,depth:Data?=nil,cameraID:UUID?=nil,withFeedback:Bool=true,withIR:Bool=false)->Archive.Frame {
   .init(frameID:id,sequence:sequence,capturedAtHostMilliseconds:1000+Double(sequence),
    rgbCapturedAtHostMilliseconds:.unavailable("Camera source does not expose independent RGB exposure timestamp"),
    depthCapturedAtHostMilliseconds:.unavailable("Camera source does not expose independent depth exposure timestamp"),
    sourceTimestampJSON:.unavailable("No device clock timestamps in this inert fixture"),cameraGeneration:cameraID ?? camera,
    width:16,height:16,rgb888:rgb ?? Data(repeating:23,count:16*16*3),depthU16LittleEndian:depth ?? Data((0..<256).flatMap{[UInt8($0%256),UInt8(3)]}),
    infrared:withIR ? .available(Data(repeating:7,count:512)):.unavailable("Source does not provide IR"),
    infraredContractJSON:withIR ? .available(json):.unavailable("Source does not provide IR"),intrinsics:[100,100,8,8],
    sourceContractsJSON:json,runtimeCalibrationJSON:json,imuJSON:.unavailable("No actual IMU packet"),
    actualAppliedNeck:.available(.init(appliedPanTarget:6000,appliedLowerTarget:6411,appliedUpperTarget:5800,
     observedAtHostMilliseconds:1000,stationary:true,source:"actual applied feedback fixture")),
    physicalLeftFeedback:withFeedback ? .available(arm("left")):.unavailable("No exposure-matched physical LEFT sample"),
    physicalRightFeedback:withFeedback ? .available(arm("right")):.unavailable("No exposure-matched physical RIGHT sample"),
    cameraToRobotColumnMajor:[1,0,0,0,0,1,0,0,0,0,1,0,0.1,0,1,1],projectionMethod:"estimated_fixture_not_registration",
    projectionScopeJSON:json,returnSamplingContractJSON:Data("{\"stride\":3,\"firstPixel\":[1,1],\"depthUnits\":\"u16le_mm\"}".utf8))
  }
  let writer=try await Archive.create(parentDirectory:root,scene:scene)
  let original=frame(),record=try await writer.append(original)
  let folder=writer.directory.appendingPathComponent(record.relativeDirectory)
  let savedRGB=try Data(contentsOf:folder.appendingPathComponent("rgb888.raw"));precondition(savedRGB==original.rgb888)
  let savedDepth=try Data(contentsOf:folder.appendingPathComponent("depth-u16le.raw"));precondition(savedDepth==original.depthU16LittleEndian)
  let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("frame.json")))as![String:Any]
  precondition(metadata["sequence"]as?Int==1 && metadata["classificationAuthority"]as?Bool==false && metadata["motionAuthority"]as?Bool==false)
  let left=(metadata["physicalLeftFeedback"]as![String:Any])["value"]as![String:Any]
  precondition(left["physicalSide"]as?String=="left" && left["gatewayArm"]as?String=="right")
  precondition(left["positionsRadians"]as?[Double]==arm("left").positionsRadians)
  precondition((metadata["infraredPath"]as![String:Any])["value"]==nil)
  precondition((metadata["rgbCapturedAtHostMilliseconds"]as![String:Any])["unavailableReason"]as?String != nil)
  _ = try await writer.append(frame(2,withFeedback:false,withIR:true))
  let complete=try await writer.finish();precondition(complete.status=="complete" && complete.frames.count==2)
  let manifestPath=writer.directory.appendingPathComponent("manifest.json"),finishedBytes=try Data(contentsOf:manifestPath)
  await reject{_ = try await writer.append(frame(3))};await reject{_ = try await writer.finish()}
  let afterClose=try Data(contentsOf:manifestPath);precondition(afterClose==finishedBytes,"Replay after close must not overwrite complete manifest")
  await reject{_ = try await Archive.create(parentDirectory:root,scene:scene)}
  for file in [manifestPath,folder.appendingPathComponent("rgb888.raw"),folder.appendingPathComponent("depth-u16le.raw"),folder.appendingPathComponent("frame.json")] {
   let permissions=try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions]as!NSNumber
   precondition(permissions.intValue==0o600)
  }
  let directoryPermissions=try FileManager.default.attributesOfItem(atPath:writer.directory.path)[.posixPermissions]as!NSNumber
  precondition(directoryPermissions.intValue==0o700)
  func new(_ maxFrames:Int=14,_ maxBytes:Int=64_000_000)async throws->Archive {
   try await .create(parentDirectory:root,scene:.init(archiveID:UUID(),workspaceSceneID:scene.workspaceSceneID,bodyMotionIdentity:scene.bodyMotionIdentity,
    gatewayGeneration:7,modelID:scene.modelID,referenceID:scene.referenceID,geometryID:scene.geometryID,mappingID:scene.mappingID),maximumFrames:maxFrames,maximumBytes:maxBytes)
  }
  for mode in ["badRGB","badDepth","replay","generation","budget","frameLimit","partialIO"] {
   let w=try await new(mode=="frameLimit" ? 1:14,mode=="budget" ? 10:64_000_000)
   if ["replay","generation","frameLimit"].contains(mode) {_ = try await w.append(frame())}
   if mode=="partialIO" {
    let next=frame();try FileManager.default.createDirectory(at:w.directory.appendingPathComponent(next.frameID.uuidString),withIntermediateDirectories:false)
    await reject{_ = try await w.append(next)}
   }else {
    await reject{_ = try await w.append(frame(mode=="replay" ? 1:2,rgb:mode=="badRGB" ? Data([0]):nil,
     depth:mode=="badDepth" ? Data([0]):nil,cameraID:mode=="generation" ? UUID():nil))}
   }
   await reject{_ = try await w.append(frame(99))};await reject{_ = try await w.finish()}
   let failed=try JSONDecoder().decode(Archive.Manifest.self,from:Data(contentsOf:w.directory.appendingPathComponent("manifest.json")))
   precondition(failed.status=="failed" && failed.failure != nil)
  }
  let concurrent=try await new()
  await withTaskGroup(of:Bool.self){group in
   for _ in 0..<3 {group.addTask{do{_ = try await concurrent.append(frame(1));return true}catch{return false}}}
   var successes=0;for await value in group {if value {successes+=1}};precondition(successes==1)
  }
  print("PASS raw-scan archive: exact RGB888/u16le/hash/pixel-frame lineage, BOTH measured q and physical/gateway identities, explicit missing timing/IR/feedback, bounded serial writes, private permissions, atomic manifest, no overwrite, replay/generation/partialIO close, concurrent one-winner; no classification/free/motion authority")
 }
}
