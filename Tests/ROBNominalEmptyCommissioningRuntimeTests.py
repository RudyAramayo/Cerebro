#!/usr/bin/env python3
"""Actual nominal proof/kernel runtime. No camera, UI, gateway, or actuator."""
import pathlib,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
fixture=r'''
private struct NominalMap:ROBWorkspaceCollisionMap {
 let sceneID=UUID(),cameraGeneration=UUID(),sessionGeneration:UInt64=42
 let modelID:String,geometryID:String,mappingID:String
 let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0,voxelSizeMeters=0.025
 let registrationID:String?=nil,registrationUncertaintyMeters:Double?=nil
 var originalOccupiedReturnBounds:[ROBWorkspaceOccupiedReturnBounds]?=[.init(lowMeters:[-0.15,-0.24,0.35],highMeters:[-0.15,-0.24,0.35])]
 var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope?
 var fingerprint:String {ROBGhostRobotModel.hash(Data("nominal-map:\(String(describing:originalOccupiedReturnBounds))".utf8))}
 func state(at p:SIMD3<Double>)->ROBWorkspaceVoxelState {.unknown}
}
@main enum NominalFixtures {
 static func rejected(_ text:String,_ body:()throws->Void){do {try body();fatalError("Unsafe nominal commissioning scope admitted")}
 catch {precondition(error.localizedDescription.contains(text),error.localizedDescription)}}
 static func main()throws {
  let model=try ROBGhostRobotModel(directory:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
  let q=Array(repeating:0.0,count:7),hash=ROBGhostRobotModel.hash(Data("isolated explicit nominal empty permission".utf8))
  var map=NominalMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID)
  map.visualCalibrationScope = .init(bodyMotionIdentity:"isolated stationary body",bodyContextIsCurrent:true,
   estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
  func trial(_ m:NominalMap,_ baseline:[Double]=q,_ allowance:Double=0.035)->ROBWorkspaceVisualCalibrationTrial {
   .init(receiptID:"isolated exact receipt",receiptSHA256:hash,appSessionID:"isolated app session",command:"right_recycle_cans",canCount:4,
    summarySHA256:hash,authorizationContextIdentity:"isolated nominal checkbox scope",sessionGeneration:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,
    modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:m.fingerprint,
    bodyMotionIdentity:"isolated stationary body",estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,currentPoseIdentity:hash,
    baseline:baseline,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:allowance)
  }
  func review(_ m:NominalMap=map,_ baseline:[Double]=q,_ enabled:Bool=true,_ measured:Double=1000,_ allowance:Double=0.035)throws->ROBWorkspaceNominalEmptyCommissioningRetreat {
   try ROBWorkspaceCollisionPlan.reviewNominalEmptyCommissioningRetreat(from:baseline,map:m,model:model,generation:42,sceneID:m.sceneID,
    cameraGeneration:m.cameraGeneration,nowMilliseconds:1000,trial:trial(m,baseline,allowance),measuredAtMilliseconds:measured,
    nominalEmptyCommissioningEnabled:enabled,emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")
  }
  let proof=try review()
  precondition(proof.goal==[0,-0.075,0,0,0,0,0] && proof.step.seconds==4 && proof.step.jawAction==nil)
  precondition(proof.checkedPoseCount==129 && proof.maximumHullTravelMeters<=0.060 && proof.endpointSelfMinimumMeters>=0.030)
  precondition(proof.minimumSweptNominalClearanceMeters>0 && proof.assumedCalibrationUncertaintyMeters==0.035)
  precondition(!proof.calibrationUncertaintyCertified && !proof.occupiedVoxelsMutated && !proof.automaticChainingPermitted)
  precondition(Set(proof.staticRobotLinks.map(\.link))==["right_base_link","right_one_Link"])
  precondition(proof.unknownVoxelCount>0 && !proof.unknownLocalRegions.isEmpty && map.state(at:.zero)==.unknown)
  precondition(proof.originalOccupiedBoundsCount==1 && proof.deduplicatedOccupiedBoundsCount==1)
  let decoded=try JSONDecoder().decode(ROBWorkspaceNominalEmptyCommissioningRetreat.self,from:JSONEncoder().encode(proof))
  try decoded.validate(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1000,
   trial:trial(map),measuredAtMilliseconds:1000,measuredBaseline:q,nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)
  rejected("distinct local permission") {_=try review(map,q,false)}
  rejected("distinct local permission") {_=try review(map,q,true,849)}
  rejected("distinct local permission") {_=try review(map,q,true,1000,0.05)}
  var nonzero=q;nonzero[0]=0.005;rejected("fresh q0") {_=try review(map,nonzero)}
  var absent=map;absent.originalOccupiedReturnBounds=nil;rejected("every original") {_=try review(absent)}
  var contact=map;let f=model.frames(model.positions(vendorLeft:q))[model.toolLink]!.columns.3
  contact.originalOccupiedReturnBounds=[.init(lowMeters:[f.x,f.y,f.z],highMeters:[f.x,f.y,f.z])]
  rejected("would contact") {_=try review(contact)}
  var boxContact=contact;boxContact.originalOccupiedReturnBounds=[.init(lowMeters:[f.x-0.001,f.y-0.001,f.z-0.001],highMeters:[f.x+0.001,f.y+0.001,f.z+0.001])]
  rejected("would contact") {_=try review(boxContact)}
  var invalid=map;invalid.originalOccupiedReturnBounds=[.init(lowMeters:[Double.nan,0,0],highMeters:[1,1,1])]
  rejected("invalid") {_=try review(invalid)}
  var moved=map;moved.visualCalibrationScope = .init(bodyMotionIdentity:"different body",bodyContextIsCurrent:true,
   estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
  rejected("scope") {_=try review(moved)}
  rejected("registration") {_=try ROBWorkspaceCollisionPlan.make(from:q,to:proof.goal,map:map,model:model,generation:42,
   sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1000)}
  var drift=q;drift[0]=0.003
  rejected("fresh start") {try decoded.validateContext(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:trial(map),measuredAtMilliseconds:1000,measuredBaseline:drift,nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)}
  var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded)) as! [String:Any]
  json["originalOccupiedBoundsSHA256"]=String(repeating:"0",count:64)
  let tampered=try JSONDecoder().decode(ROBWorkspaceNominalEmptyCommissioningRetreat.self,from:JSONSerialization.data(withJSONObject:json))
  rejected("geometry, raw returns") {try tampered.validate(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:trial(map),measuredAtMilliseconds:1000,measuredBaseline:q,nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)}
  // Independent analytic convex/AABB cases cover point, face, diagonal,
  // degenerate and intersecting bounds in the EXACT production kernel.
  let cube="""
  v -1 -1 -1
  v -1 -1 1
  v -1 1 -1
  v -1 1 1
  v 1 -1 -1
  v 1 -1 1
  v 1 1 -1
  v 1 1 1
  f 1 3 2
  f 2 3 4
  f 5 6 7
  f 6 8 7
  f 1 2 5
  f 2 6 5
  f 3 7 4
  f 4 7 8
  f 1 5 3
  f 3 5 7
  f 2 4 6
  f 4 8 6
  """
  let shape=ROBNominalWorldShape(try ROBNominalShape(text:cube),matrix_identity_double4x4)
  for (low,high,expected) in [(SIMD3<Double>(2,2,2),SIMD3<Double>(3,3,3),sqrt(3.0)),
   (SIMD3<Double>(2,0,0),SIMD3<Double>(2,0,0),1.0),(SIMD3<Double>(0,0,0),SIMD3<Double>(0.2,0.2,0.2),0.0),
   (SIMD3<Double>(-2,-2,-2),SIMD3<Double>(-1.5,-1.5,-1.5),sqrt(0.75))] {
    let actual=try shape.distance(.init(low:low,high:high,key:"analytic"));precondition(abs(actual-expected)<1e-9)
  }
  print("PASS nominal-only exact4s RIGHT empty step: everyrawreturn/no masks,40mmjaws,closed-hull geometry,curvature/localunknown/static evidence,selfendpoint,flag/freshness/contact/drift/tamper/ordinary negatives;35mm uncertainty remains explicitly UNCERTIFIED")
 }
}
'''.replace(')==.unknown',') == .unknown')
with tempfile.TemporaryDirectory(prefix='rob-nominal-commissioning-') as temp:
    directory=pathlib.Path(temp);combined=directory/'ActualCollisionAndFixture.swift'
    combined.write_text((repo/'Cerebro/ROBWorkspaceCollisionPlan.swift').read_text()+'\n'+fixture)
    sources=['ROBArmRoutinePlan.swift','ROBArmJointLimits.swift','ROBArmControlProtocol.swift','ROBGhostMotionPlan.swift','ROBWorkspaceSearchPlan.swift']
    binary=directory/'fixture'
    subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',*[str(repo/'Cerebro'/s)for s in sources],str(combined),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(repo)],check=True)
