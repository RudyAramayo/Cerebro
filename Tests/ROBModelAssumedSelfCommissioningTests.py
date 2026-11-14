#!/usr/bin/env python3
"""Actual nominal model-assumed group audit; synthetic geometry only, no IO."""
import pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
fixture=r'''
import Foundation
import simd
struct GroupMap:ROBWorkspaceCollisionMap {
 let sceneID=UUID(),cameraGeneration=UUID(),sessionGeneration:UInt64=42
 let modelID:String,geometryID:String,mappingID:String
 let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0,voxelSizeMeters=0.025
 let registrationID:String?=nil,registrationUncertaintyMeters:Double?=nil
 let groups:[ROBWorkspaceOccupiedSourceGroup]
 var supplied:[ROBWorkspaceOccupiedSourceGroup]?=nil
 var incomplete=false
 var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope?
 var cells:[SIMD3<Int>:ROBWorkspaceOccupiedReturnBounds] {
  var result:[SIMD3<Int>:ROBWorkspaceOccupiedReturnBounds]=[:]
  for g in groups {for x in -1...1 {for y in -1...1 {for z in -1...1 {
   let c=SIMD3(g.sourceVoxel[0]+x,g.sourceVoxel[1]+y,g.sourceVoxel[2]+z)
   if let b=result[c] {result[c] = .init(lowMeters:zip(b.lowMeters,g.bounds.lowMeters).map{min($0,$1)},highMeters:zip(b.highMeters,g.bounds.highMeters).map{max($0,$1)})}
   else {result[c]=g.bounds}
  }}}};return result
 }
 var originalOccupiedSourceGroups:[ROBWorkspaceOccupiedSourceGroup]? {incomplete ? nil:supplied ?? groups}
 var originalOccupiedReturnBounds:[ROBWorkspaceOccupiedReturnBounds]? {Array(cells.values)}
 var fingerprint:String {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return ROBGhostRobotModel.hash(try!e.encode(groups))}
 func state(at p:SIMD3<Double>)->ROBWorkspaceVoxelState {cells[SIMD3(Int(floor(p.x/0.025)),Int(floor(p.y/0.025)),Int(floor(p.z/0.025)))] == nil ? .unknown:.occupied}
 func occupiedSampleBounds(at p:SIMD3<Double>)->(low:SIMD3<Double>,high:SIMD3<Double>)? {
  guard let b=cells[SIMD3(Int(floor(p.x/0.025)),Int(floor(p.y/0.025)),Int(floor(p.z/0.025)))] else{return nil}
  return (SIMD3(b.lowMeters[0],b.lowMeters[1],b.lowMeters[2]),SIMD3(b.highMeters[0],b.highMeters[1],b.highMeters[2]))
 }
}
@main struct Fixtures {
 static func reject(_ op:()throws->Void) {do {try op();preconditionFailure("Unsafe source hypothesis admitted")}catch{}}
 static func main()throws {
  let model=try ROBGhostRobotModel(directory:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
  let q=[0.0,0,0,0,0,0,0],frames=model.frames(model.positions(vendorLeft:q)),link="right_five_Link"
  let text=try String(contentsOf:model.directory.appendingPathComponent(model.hulls[link]!)),hull=try ROBEstimatedConvexHull(text:text)
  let local=hull.vertices.reduce(SIMD3<Double>.zero,+)/Double(hull.vertices.count),p=frames[link]!*SIMD4(local.x,local.y,local.z,1)
  func group(_ low:[Double],_ high:[Double]?=nil)->ROBWorkspaceOccupiedSourceGroup {
   .init(sourceVoxel:low.map{Int(floor($0/0.025))},bounds:.init(lowMeters:low,highMeters:high ?? low))
  }
  let own=group([p.x,p.y,p.z]),outside=group([-0.15,-0.24,0.35]),hash=String(repeating:"a",count:64)
  var map=GroupMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,groups:[own,outside])
  map.visualCalibrationScope = .init(bodyMotionIdentity:"inert-fixed-body",bodyContextIsCurrent:true,estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
  func review(_ m:GroupMap,_ enabled:Bool=true,_ baseline:[Double]=q)throws->ROBWorkspaceNominalEmptyCommissioningRetreat {
   let trial=ROBWorkspaceVisualCalibrationTrial(receiptID:"inert actual API fixture",receiptSHA256:hash,appSessionID:"inert",command:"right_recycle_cans",canCount:4,
    summarySHA256:hash,authorizationContextIdentity:"inert flag",sessionGeneration:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,
    modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:m.fingerprint,bodyMotionIdentity:"inert-fixed-body",
    estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,currentPoseIdentity:hash,baseline:baseline,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.035)
   return try ROBWorkspaceCollisionPlan.reviewNominalEmptyCommissioningRetreat(from:baseline,map:m,model:model,generation:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,
    nowMilliseconds:1000,trial:trial,measuredAtMilliseconds:1000,nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip",modelAssumedSelfEnabled:enabled)
  }
  reject{_ = try review(map,false)}
  let proof=try review(map),audit=proof.modelAssumedSelfAudit!
  precondition(audit.label=="assumed_alignment_not_observed_self" && audit.groups.count==1 && audit.groups[0].sourceGroupID==own.id && !audit.observedSelf && !audit.rawMapModified)
  precondition(proof.goal==[0,-0.075,0,0,0,0,0] && proof.step.seconds==4 && proof.step.jawAction==nil && proof.maximumHullTravelMeters<=0.060 && proof.endpointSelfMinimumMeters>=0.030)
  precondition(map.originalOccupiedReturnBounds!.count>2 && map.state(at:.zero) == .unknown)
  var incomplete=map;incomplete.incomplete=true;reject{_ = try review(incomplete)}
  incomplete=map;incomplete.supplied=[own];reject{_ = try review(incomplete)}
  incomplete=map;incomplete.supplied=[own,own,outside];reject{_ = try review(incomplete)}
  // Whole group containing an external corner cannot be excluded merely
  // because its center/intersection lies within an assumed robot hull.
  let first=hull.vertices[0],surface=frames[link]!*SIMD4(first.x,first.y,first.z,1)
  var mixed=map
  let delta=SIMD3(surface.x-p.x,surface.y-p.y,surface.z-p.z),beyond=SIMD3(p.x,p.y,p.z)+delta*1.25
  let low=simd_min(SIMD3(p.x,p.y,p.z),beyond),high=simd_max(SIMD3(p.x,p.y,p.z),beyond)
  let mixedGroup=group([low.x,low.y,low.z],[high.x,high.y,high.z])
  mixed=GroupMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,groups:[mixedGroup,outside],visualCalibrationScope:map.visualCalibrationScope)
  reject{_ = try review(mixed)}
  if let v=hull.vertices.first(where:{v in
   let w=frames[link]!*SIMD4(v.x,v.y,v.z,1),a=[w.x,w.y,w.z]
   return a.allSatisfy{let f=$0-floor($0/0.025)*0.025;return f>0.0002 && f<0.0248} && a.map{Int(floor($0/0.025))} != own.sourceVoxel
  }) {
   let w=frames[link]!*SIMD4(v.x,v.y,v.z,1),p=SIMD3(w.x,w.y,w.z),lo=p-SIMD3<Double>(repeating:0.0001),hi=p+SIMD3<Double>(repeating:0.0001)
   let partial=group([lo.x,lo.y,lo.z],[hi.x,hi.y,hi.z])
   precondition(partial.sourceVoxel==partial.bounds.highMeters.map{Int(floor($0/0.025))})
   let partialMap=GroupMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,groups:[own,partial,outside],visualCalibrationScope:map.visualCalibrationScope)
   reject{_ = try review(partialMap)}
  }else {preconditionFailure("Fixture needs actual same-voxel partial hull group")}
  var nonJ2=q;nonJ2[0]=0.02;reject{_ = try review(map,true,nonJ2)}
  var priorStep=q;priorStep[1] = -0.021
  // Same exact endpoint delta; any later self/geometry failure must not
  // become an automatic second step or a relaxation of the full proof.
  do {let continued=try review(map,true,priorStep);precondition(continued.goal[1]==priorStep[1]-0.075)}catch{}
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  reject{try proof.validateContext(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:proof.context.visualTrial!,measuredAtMilliseconds:1000,measuredBaseline:q,nominalEmptyCommissioningEnabled:true,
   emptyStateEvidenceSource:proof.emptyStateEvidenceSource)}
  try proof.validate(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:proof.context.visualTrial!,measuredAtMilliseconds:1000,measuredBaseline:q,nominalEmptyCommissioningEnabled:true,
   emptyStateEvidenceSource:proof.emptyStateEvidenceSource,modelAssumedSelfEnabled:true)
  var changed=try JSONSerialization.jsonObject(with:encoder.encode(proof))as![String:Any]
  var changedAudit=changed["modelAssumedSelfAudit"]as![String:Any];changedAudit["referenceID"]="different-reference";changed["modelAssumedSelfAudit"]=changedAudit
  let tampered=try JSONDecoder().decode(ROBWorkspaceNominalEmptyCommissioningRetreat.self,from:JSONSerialization.data(withJSONObject:changed))
  reject{try tampered.validateContext(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:proof.context.visualTrial!,measuredAtMilliseconds:1000,measuredBaseline:q,nominalEmptyCommissioningEnabled:true,
   emptyStateEvidenceSource:proof.emptyStateEvidenceSource,modelAssumedSelfEnabled:true)}
  let decoded=try JSONDecoder().decode(ROBWorkspaceNominalEmptyCommissioningRetreat.self,from:encoder.encode(proof))
  precondition(decoded==proof)
  print("PASS actual nominal MODEL-ASSUMED variant: defaultOFF contacts reject; complete exact original groups reconstructed, only whole noninflated baseline moving-hull group excluded/audited; outside retained, partial/mixed/missing/duplicate groups reject; exact J2-only4s/60mm,selfendpoint,rawmap+UNKNOWN unchanged,no observed-self/jaw/carry authority")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='rob-model-assumed-',dir='/private/tmp')as folder:
 p=pathlib.Path(folder);f=p/'Fixture.swift';f.write_text(fixture)
 sources=['ROBArmRoutinePlan.swift','ROBArmJointLimits.swift','ROBArmControlProtocol.swift','ROBGhostMotionPlan.swift','ROBWorkspaceSearchPlan.swift','ROBWorkspaceCollisionPlan.swift']
 subprocess.run(['xcrun','swiftc','-O','-whole-module-optimization','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',*[str(root/'Cerebro'/x)for x in sources],str(f),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture'),str(root)],check=True)
