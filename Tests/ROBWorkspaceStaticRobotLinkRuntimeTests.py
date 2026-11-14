#!/usr/bin/env python3
"""Actual model/checker regression; no UI, gateway, camera, or hardware."""
import pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
main=r'''
import Foundation
import simd
private struct Map:ROBWorkspaceCollisionMap {
 let sceneID=UUID(),cameraGeneration=UUID(),sessionGeneration:UInt64=42
 let modelID:String,geometryID:String,mappingID:String
 let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0,voxelSizeMeters=0.025
 var registrationID:String?="synthetic measured registration"
 var registrationUncertaintyMeters:Double?=0.035
 var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope?=nil
 var unknownQueryCenter:SIMD3<Double>
 var occupiedPoint:SIMD3<Double>?=nil
 var fingerprint:String {ROBGhostRobotModel.hash(Data("staticbasefixture:\(unknownQueryCenter):\(String(describing:occupiedPoint))".utf8))}
 func state(at p:SIMD3<Double>)->ROBWorkspaceVoxelState {
  if let occupiedPoint,simd_distance(p,occupiedPoint)<0.001 {return .occupied}
  return .unknown
 }
 func state(inBoundsLow low:SIMD3<Double>,high:SIMD3<Double>)->ROBWorkspaceVoxelState {
  // Intentionally reproduce generic first-unknown aggregate ordering, even
  // when a later voxel is occupied. The static branch must inspect all cells.
  simd_distance((low+high)/2,unknownQueryCenter)<1e-8 ? .unknown:.free
 }
}
@main enum Fixture {
 static func blocked(_ match:String,_ run:()throws->Void) {do {try run();fatalError("Unsafe static-body scope admitted")}
 catch {precondition(error.localizedDescription.contains(match),error.localizedDescription)}}
 static func main()throws {
  let directory=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner")
  for side in ["left","right"] {
   let model=try ROBGhostRobotModel(directory:directory,physicalSide:side),q=model.recyclingFrontTarget
   let first=ROBWorkspaceCollisionPlan.invariantSelectedArmBase(model:model,positions:model.positions(vendorLeft:q),link:side+"_base_link",bodyMotionIdentity:"stationary body")!
   for j in 0..<7 {var moved=q;moved[j]+=0.01
    let next=ROBWorkspaceCollisionPlan.invariantSelectedArmBase(model:model,positions:model.positions(vendorLeft:moved),link:side+"_base_link",bodyMotionIdentity:"stationary body")!
    precondition(next==first,"Actual static-base transform/bounds changed with armq")
   }
   precondition(ROBWorkspaceCollisionPlan.invariantSelectedArmBase(model:model,positions:model.positions(vendorLeft:q),link:side+"_one_Link",bodyMotionIdentity:"stationary body")==nil,"A moving arm link became a static exemption")
  }
  let model=try ROBGhostRobotModel(directory:directory),q=model.recyclingFrontTarget
  let boxes=model.worldCollisionBounds(positions:model.positions(vendorLeft:q)),base=boxes["left_base_link"]!
  var map=Map(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,unknownQueryCenter:(base.low+base.high)/2)
  func ordinary(_ m:Map)throws { _=try ROBWorkspaceCollisionPlan.make(from:q,to:q,map:m,model:model,generation:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,nowMilliseconds:1000)}
  blocked("left_base_link enters unobserved") {try ordinary(map)}
  let hash=ROBGhostRobotModel.hash(Data("isolated static-link scope".utf8))
  map.registrationID=nil;map.registrationUncertaintyMeters=nil
  map.visualCalibrationScope = .init(bodyMotionIdentity:"stationary body",bodyContextIsCurrent:true,estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
  func trial(_ m:Map)->ROBWorkspaceVisualCalibrationTrial {
   .init(receiptID:"isolated receipt",receiptSHA256:hash,appSessionID:"isolated app",command:"left_recycle_cans",canCount:4,
    summarySHA256:hash,authorizationContextIdentity:"isolated broker",sessionGeneration:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,
    modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:m.fingerprint,bodyMotionIdentity:"stationary body",
    estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,currentPoseIdentity:hash,baseline:q,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.035)
  }
  func make(_ m:Map)throws->ROBWorkspaceCollisionPlan {
   try .makeVisualCalibrationTrial(from:q,to:q,map:m,model:model,generation:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,nowMilliseconds:1000,trial:trial(m))
  }
  let plan=try make(map)
  let evidence=plan.context.skippedStaticRobotLinks!
  precondition(evidence.count==1 && evidence[0].kind=="skipped_static_robot_link" && evidence[0].link=="left_base_link" && evidence[0].frameColumnMajor.count==16)
  let decoded=try JSONDecoder().decode(ROBWorkspaceCollisionPlan.self,from:JSONEncoder().encode(plan))
  try decoded.validateVisualCalibrationTrial(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1001,trial:trial(map))
  var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded)) as! [String:Any]
  var context=json["context"] as! [String:Any];context["skippedStaticRobotLinks"]=[];json["context"]=context
  let tampered=try JSONDecoder().decode(ROBWorkspaceCollisionPlan.self,from:JSONSerialization.data(withJSONObject:json))
  blocked("static robot-link evidence changed") {try tampered.validateVisualCalibrationTrial(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1001,trial:trial(map))}
  var movingUnknown=map;let one=boxes["left_one_Link"]!;movingUnknown.unknownQueryCenter=(one.low+one.high)/2
  blocked("left_one_Link enters unobserved") {_=try make(movingUnknown)}
  var obstacle=map
  let margin=ROBWorkspaceCollisionPlan.mechanicalClearanceMeters+0.035+ROBWorkspaceCollisionPlan.sweptPointTravelMeters+sqrt(3)*map.voxelSizeMeters/2
  // This occupied cell is OUTSIDE the existing base body, later than the
  // first unknown cell in x/y/z order, but inside its unchanged margin.
  let low=base.low-SIMD3(repeating:margin),high=base.high+SIMD3(repeating:margin),size=map.voxelSizeMeters
  // Use an actual near-surface cell, rather than the old inflated AABB's
  // diagonal corner (which the exact convex narrow phase correctly clears).
  let hull=try ROBEstimatedConvexHull(text:String(contentsOf:model.directory.appendingPathComponent(model.hulls["left_base_link"]!),encoding:.utf8))
  let baseFrame=model.frames(model.positions(vendorLeft:q))["left_base_link"]!
  let vertices=hull.vertices.map{p->SIMD3<Double> in let v=baseFrame*SIMD4(p,1);return SIMD3(v.x,v.y,v.z)}
  let surface=vertices.max{$0.x<$1.x}!,outside=surface+SIMD3(0.025,0,0)
  obstacle.occupiedPoint=SIMD3((floor(outside.x/size)+0.5)*size,(floor(outside.y/size)+0.5)*size,(floor(outside.z/size)+0.5)*size)
  let local=simd_inverse(baseFrame)*SIMD4(obstacle.occupiedPoint!,1)
  let measuredHullDistance=try hull.distance(to:SIMD3(local.x,local.y,local.z));precondition(measuredHullDistance<0.060)
  precondition(obstacle.occupiedPoint!.x>low.x && obstacle.occupiedPoint!.x>base.high.x)
  precondition(obstacle.state(inBoundsLow:low,high:high) == .unknown)
  blocked("observed workspace obstacle") {_=try make(obstacle)}
  var bodyChanged=map;bodyChanged.visualCalibrationScope = .init(bodyMotionIdentity:"different body",bodyContextIsCurrent:true,estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
  blocked("scope") {_=try make(bodyChanged)}
  print("PASS actual LEFT/RIGHT invariant mounting FK+bounds; local-only static unknown omission; moving-link/body/ordinary negatives; unknown-first occupied-later veto; immutable evidence roundtrip; no voxel changes")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='rob-static-body-') as temp:
    directory=pathlib.Path(temp);swift=directory/'Fixture.swift';swift.write_text(main);binary=directory/'fixture'
    sources=['ROBArmRoutinePlan.swift','ROBArmJointLimits.swift','ROBArmControlProtocol.swift','ROBGhostMotionPlan.swift','ROBWorkspaceSearchPlan.swift','ROBWorkspaceCollisionPlan.swift']
    subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',*[str(repo/'Cerebro'/s)for s in sources],str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(repo)],check=True)
