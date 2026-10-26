import Foundation
import simd
private struct CellMap:ROBWorkspaceCollisionMap {
 let sceneID:UUID,cameraGeneration:UUID
 let sessionGeneration:UInt64=42
 let modelID:String,geometryID:String,mappingID:String
 let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0,voxelSizeMeters=0.025
 var registrationID:String?=nil,registrationUncertaintyMeters:Double?=nil
 var bodyID="isolated stationary body",bodyCurrent=true
 let cell:SIMD3<Int>,kind:ROBWorkspaceVoxelState,raw:(SIMD3<Double>,SIMD3<Double>)?
 var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope? {
  .init(bodyMotionIdentity:bodyID,bodyContextIsCurrent:bodyCurrent,estimatedCameraProjectionIdentity:String(repeating:"a",count:64),observationPoseIdentity:String(repeating:"b",count:64),observedFrameCount:2)
 }
 var fingerprint:String{ROBGhostRobotModel.hash(Data("\(cell)-\(kind)-\(String(describing:raw))".utf8))}
 func state(at p:SIMD3<Double>)->ROBWorkspaceVoxelState {
  let key=SIMD3(Int(floor(p.x/voxelSizeMeters)),Int(floor(p.y/voxelSizeMeters)),Int(floor(p.z/voxelSizeMeters)))
  return key==cell ? kind:.free
 }
 func state(inBoundsLow low:SIMD3<Double>,high:SIMD3<Double>)->ROBWorkspaceVoxelState {
  (0..<3).allSatisfy({Int(floor(low[$0]/voxelSizeMeters))<=cell[$0] && Int(floor(high[$0]/voxelSizeMeters))>=cell[$0]}) ? kind:.free
 }
 func occupiedSampleBounds(at p:SIMD3<Double>)->(low:SIMD3<Double>,high:SIMD3<Double>)?{state(at:p) == .occupied ? raw.map{(low:$0.0,high:$0.1)}:nil}
}
@main enum ConvexNarrowFixture {
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
  let q=model.recyclingFrontTarget,positions=model.positions(vendorLeft:q),frames=model.frames(positions),boxes=model.worldCollisionBounds(positions:positions)
  let links=boxes.keys.filter{$0.hasPrefix("right_") && ($0.hasSuffix("_Link") || $0==model.toolLink || $0=="right_base_link")}.sorted()
  let catalog=try JSONSerialization.jsonObject(with:Data(contentsOf:model.directory.appendingPathComponent("surfaces.json")))as![String:Any]
  var hulls:[String:ROBEstimatedConvexHull]=[:]
  for row in catalog["surfaces"]as![[String:Any]] {let link=row["link"]as!String;guard links.contains(link) else{continue};let data=try Data(contentsOf:model.directory.appendingPathComponent(row["hull"]as!String));precondition(ROBGhostRobotModel.hash(data)==row["hullSHA256"]as!String);hulls[link]=try ROBEstimatedConvexHull(text:String(data:data,encoding:.utf8)!)}
  let size=0.025,physicalMargin=0.060,broadMargin=physicalMargin+sqrt(3)*size/2
  var corner:SIMD3<Int>?
  for link in links where corner==nil {let box=boxes[link]!,extra=broadMargin+(link==model.toolLink ? 0.04:0)
   let lo=(0..<3).map{Int(floor((box.low[$0]-extra)/size))},hi=(0..<3).map{Int(floor((box.high[$0]+extra)/size))}
   for x in [lo[0],hi[0]] {for y in [lo[1],hi[1]] {for z in [lo[2],hi[2]] {
    let key=SIMD3(x,y,z),p=(SIMD3<Double>(Double(x),Double(y),Double(z))+SIMD3(repeating:0.5))*size
    let outside=try links.allSatisfy{l in let a=simd_inverse(frames[l]!)*SIMD4(p,1);return try hulls[l]!.distance(to:SIMD3(a.x,a.y,a.z))-sqrt(3)*size/2 > physicalMargin+(l==model.toolLink ? 0.04:0)+0.001}
    if outside {corner=key}
   }}}
  }
  guard let corner else {fatalError("Fixture needs a demonstrably external AABB corner")}
  let scene=UUID(),camera=UUID()
  func map(_ cell:SIMD3<Int>,_ kind:ROBWorkspaceVoxelState,_ raw:(SIMD3<Double>,SIMD3<Double>)?=nil)->CellMap {
   .init(sceneID:scene,cameraGeneration:camera,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,cell:cell,kind:kind,raw:raw)
  }
  func trial(_ map:CellMap)->ROBWorkspaceVisualCalibrationTrial {
   .init(receiptID:"isolated receipt",receiptSHA256:String(repeating:"c",count:64),appSessionID:"isolated",command:"right_recycle_cans",canCount:4,summarySHA256:String(repeating:"d",count:64),authorizationContextIdentity:"isolated only",sessionGeneration:42,sceneID:scene,cameraGeneration:camera,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:map.fingerprint,bodyMotionIdentity:"isolated stationary body",estimatedCameraProjectionIdentity:String(repeating:"a",count:64),observationPoseIdentity:String(repeating:"b",count:64),currentPoseIdentity:String(repeating:"e",count:64),baseline:q,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.035)
  }
  @discardableResult func review(_ map:CellMap)throws->ROBWorkspaceCollisionPlan {
   try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:[.init(positions:q,seconds:0.7)],map:map,model:model,generation:42,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map))
  }
  try review(map(corner,.unknown))
  try review(map(corner,.occupied))
  let localCenter=hulls[model.toolLink]!.vertices.reduce(SIMD3<Double>.zero,+)/Double(hulls[model.toolLink]!.vertices.count)
  let center4=frames[model.toolLink]!*SIMD4(localCenter,1),p=SIMD3(center4.x,center4.y,center4.z)
  let inside=SIMD3(Int(floor(p.x/size)),Int(floor(p.y/size)),Int(floor(p.z/size)))
  @discardableResult func blocked(_ map:CellMap,_ text:String)->String{do{try review(map);fatalError("Genuine \(text) admitted")}catch{precondition(error.localizedDescription.contains(text),error.localizedDescription);return error.localizedDescription}}
  blocked(map(inside,.unknown),"unobserved")
  blocked(map(inside,.occupied,(p,p)),"obstacle")
  // The union keeps every original contributor: an outside endpoint never
  // replaces or averages away another endpoint inside the protected tool.
  blocked(map(inside,.occupied,(p,p+SIMD3(repeating:0.10))),"obstacle")
  // A static-world pair creates no new sweep. Find one cell close to the
  // actual fixed base yet conservatively outside EVERY moving convex margin.
  // These synthetic cells remain occupied/unknown; neither is relabelled.
  let base="right_base_link",moving=links.filter{$0 != base},baseBox=boxes[base]!
  func localPoint(_ point:SIMD3<Double>,_ link:String)->SIMD3<Double> {
   let v=simd_inverse(frames[link]!)*SIMD4(point,1);return SIMD3(v.x,v.y,v.z)
  }
  var staticOnly:SIMD3<Int>?
  let lo=(0..<3).map{Int(floor((baseBox.low[$0]-0.04)/size))},hi=(0..<3).map{Int(floor((baseBox.high[$0]+0.04)/size))}
  for x in lo[0]...hi[0] where staticOnly==nil {for y in lo[1]...hi[1] where staticOnly==nil {for z in lo[2]...hi[2] where staticOnly==nil {
   let cell=SIMD3(x,y,z),point=(SIMD3<Double>(Double(x),Double(y),Double(z))+SIMD3(repeating:0.5))*size
   guard try hulls[base]!.distance(to:localPoint(point,base))<=0.04 else{continue}
   if try moving.allSatisfy({link in
       try hulls[link]!.distance(to:localPoint(point,link))-sqrt(3)*size/2 > physicalMargin+(link==model.toolLink ? 0.04:0)+0.001
   }) {staticOnly=cell}
  }}}
  guard let staticOnly else {fatalError("Fixture needs a base-only cell outside all moving-link margins")}
  let basePoint=(SIMD3<Double>(Double(staticOnly.x),Double(staticOnly.y),Double(staticOnly.z))+SIMD3(repeating:0.5))*size
  let baseMap=map(staticOnly,.occupied,(basePoint,basePoint)),deferred=try review(baseMap)
  let evidence=deferred.context.skippedStaticRobotLinks!.first!
  precondition(deferred.context.skippedStaticRobotLinks?.count==1 && evidence.link==base && evidence.kind=="deferred_static_world_pair")
  precondition(baseMap.state(at:basePoint) == .occupied && baseMap.occupiedSampleBounds(at:basePoint) != nil)
  let baseUnknown=map(staticOnly,.unknown);try review(baseUnknown)
  precondition(baseUnknown.state(at:basePoint) == .unknown)
  // A return also close to the base MUST still block its moving neighbor.
  let neighbor="right_one_Link",mean=hulls[neighbor]!.vertices.reduce(SIMD3<Double>.zero,+)/Double(hulls[neighbor]!.vertices.count)
  let near4=frames[neighbor]!*SIMD4(mean,1),near=SIMD3(near4.x,near4.y,near4.z)
  let nearBaseDistance=try hulls[base]!.distance(to:localPoint(near,base))
  precondition(nearBaseDistance<=physicalMargin)
  let nearCell=SIMD3(Int(floor(near.x/size)),Int(floor(near.y/size)),Int(floor(near.z/size)))
  precondition(!blocked(map(nearCell,.occupied,(near,near)),"obstacle").contains(base))
  precondition(!blocked(map(nearCell,.unknown),"unobserved").contains(base))
  var changedBody=baseMap;changedBody.bodyID="moved torso";blocked(changedBody,"scope")
  changedBody=baseMap;changedBody.bodyCurrent=false;blocked(changedBody,"scope")
  var changedPose=positions;changedPose["torso_yaw",default:0]+=0.01
  do {_=try ROBWorkspaceCollisionPlan.deferredStaticWorldPair(model:model,positions:changedPose,link:base,
       map:baseMap,context:deferred.context,prior:evidence);fatalError("Changed torso frame inherited a static-world deferral")}
  catch {precondition(error.localizedDescription.contains("changed transform"),error.localizedDescription)}
  let movingDeferral=try ROBWorkspaceCollisionPlan.deferredStaticWorldPair(model:model,positions:positions,link:neighbor,
       map:baseMap,context:deferred.context,prior:nil)
  precondition(movingDeferral==nil)
  let changedGeometry=CellMap(sceneID:scene,cameraGeneration:camera,modelID:model.modelID,geometryID:"different source geometry",
       mappingID:model.selectedMappingID,cell:staticOnly,kind:.occupied,raw:(basePoint,basePoint))
  blocked(changedGeometry,"scope")
  // The ordinary measured lane retains its existing complete static query.
  var measuredMap=baseMap;measuredMap.registrationID="isolated measured registration";measuredMap.registrationUncertaintyMeters=0
  do {_=try ROBWorkspaceCollisionPlan.review(baseline:q,steps:[.init(positions:q,seconds:0.7)],map:measuredMap,model:model,
       generation:42,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000);fatalError("Measured lane inherited visual-only static deferral")}
  catch {precondition(error.localizedDescription.contains("obstacle"),error.localizedDescription)}
  print("Static-world deferral PASS: one proven fixed selected mount only; base-only occupied/unknown cells stay unchanged, all moving links retain the same cells/margins, nearby moving occupied/unknown still veto; changed body/source/frame and measured-lane deferral rejected.")
  print("Convex cell integration PASS: AABB-only unknown/occupied corners clear, true unknown/raw obstacle and all original contributors veto; no voxel was relabelled or erased.")
 }
}
