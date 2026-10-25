#!/usr/bin/env python3
"""Run the actual one-degree proof with synthetic retained contact predictions.
No UI, camera, gateway, or actuator is linked. Contact remains in diagnostics;
this test must not turn it into an ordinary collision certificate.
"""
import pathlib,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
fixture=r'''
private struct DegreeMap:ROBWorkspaceCollisionMap {
 let sceneID=UUID(),cameraGeneration=UUID(),sessionGeneration:UInt64=42
 let modelID:String,geometryID:String,mappingID:String
 let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0,voxelSizeMeters=0.025
 let registrationID:String?=nil,registrationUncertaintyMeters:Double?=nil
 var originalOccupiedReturnBounds:[ROBWorkspaceOccupiedReturnBounds]?
 var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope?
 var fingerprint:String {ROBGhostRobotModel.hash(Data("one-degree-map:\(String(describing:originalOccupiedReturnBounds))".utf8))}
 func state(at p:SIMD3<Double>)->ROBWorkspaceVoxelState {.unknown}
}
@main enum DegreeFixtures {
 static func rejected(_ expected:String,_ body:()throws->Void){do {try body();fatalError("Unscoped actuator command admitted")}
 catch {precondition(error.localizedDescription.contains(expected),error.localizedDescription)}}
 static func main()throws {
  let model=try ROBGhostRobotModel(directory:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
  let q=Array(repeating:0.0,count:7),hash=ROBGhostRobotModel.hash(Data("isolated separate one-degree receipt".utf8))
  let tool=model.frames(model.positions(vendorLeft:q))[model.toolLink]!.columns.3
  // Intentionally retain a contact prediction. The new exact actuator test
  // records it as a risk, while the ordinary/nominal paths must still reject.
  var map=DegreeMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
   originalOccupiedReturnBounds:[.init(lowMeters:[tool.x,tool.y,tool.z],highMeters:[tool.x,tool.y,tool.z])])
  map.visualCalibrationScope = .init(bodyMotionIdentity:"isolated stationary body",bodyContextIsCurrent:true,
   estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
  func trial(_ m:DegreeMap,_ baseline:[Double]=q)->ROBWorkspaceVisualCalibrationTrial {
   .init(receiptID:"isolated receipt",receiptSHA256:hash,appSessionID:"isolated session",command:"right_recycle_cans",canCount:4,
    summarySHA256:hash,authorizationContextIdentity:"isolated NEW one-degree flag",sessionGeneration:42,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,
    modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:m.fingerprint,
    bodyMotionIdentity:"isolated stationary body",estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,currentPoseIdentity:hash,
    baseline:baseline,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.035)
  }
  func review(_ m:DegreeMap=map,_ baseline:[Double]=q,_ enabled:Bool=true,_ measured:Double=1000)throws->ROBWorkspaceOneDegreeEmptyCalibrationStep {
   try .reviewImpossiblePlaceholder()
  }
  let proof=try ROBWorkspaceCollisionPlan.reviewOneDegreeEmptyCalibrationStep(from:q,map:map,model:model,generation:42,sceneID:map.sceneID,
   cameraGeneration:map.cameraGeneration,nowMilliseconds:1000,trial:trial(map),measuredAtMilliseconds:1000,
   oneDegreeEmptyCalibrationStepEnabled:true,emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")
  precondition(proof.goal==[0,-0.02,0,0,0,0,0] && proof.step.seconds==4 && proof.step.jawAction==nil)
  precondition(proof.maximumHullTravelMeters<=0.020 && proof.checkedPoseCount==65 && proof.completedTransferCount==0)
  precondition(proof.endpointSelfMinimumMeters>=proof.initialSelfMinimumMeters && proof.endpointSelfMinimumMeters<0.030)
  precondition(proof.environmentDiagnostics.predictedNominalContact && proof.environmentDiagnostics.minimumAfterJawEnvelopeMeters!<=0)
  precondition(proof.environmentPredictionIsDiagnosticOnly && proof.environmentDiagnostics.sourceBoundsAllRetained && !proof.collisionCertificate)
  precondition(!proof.occupiedVoxelsMutated && !proof.automaticChainingPermitted && proof.emptyStateAssumed)
  precondition(proof.environmentDiagnostics.originalOccupiedBoundsCount==1 && proof.environmentDiagnostics.deduplicatedOccupiedBoundsCount==1)
  precondition(proof.unknownVoxelCount>0 && !proof.unknownLocalRegions.isEmpty && map.state(at:.zero) == .unknown)
  let decoded=try JSONDecoder().decode(ROBWorkspaceOneDegreeEmptyCalibrationStep.self,from:JSONEncoder().encode(proof))
  try decoded.validate(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1000,
   trial:trial(map),measuredAtMilliseconds:1000,measuredBaseline:q,oneDegreeEmptyCalibrationStepEnabled:true,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)
  rejected("NEW distinct permission") {_=try review(map,q,false)}
  rejected("fresh EMPTY q0") {_=try review(map,q,true,849)}
  var changed=q;changed[0]=0.005;rejected("fresh EMPTY q0") {_=try review(map,changed)}
  var absent=map;absent.originalOccupiedReturnBounds=nil;rejected("retained raw") {_=try review(absent)}
  var bad=map;bad.originalOccupiedReturnBounds=[.init(lowMeters:[Double.nan,0,0],highMeters:[1,1,1])];rejected("invalid") {_=try review(bad)}
  var moved=map;moved.visualCalibrationScope = .init(bodyMotionIdentity:"different body",bodyContextIsCurrent:true,
   estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2);rejected("scope") {_=try review(moved)}
  rejected("registration") {_=try ROBWorkspaceCollisionPlan.make(from:q,to:proof.goal,map:map,model:model,generation:42,
   sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1000)}
  rejected("would contact") {_=try ROBWorkspaceCollisionPlan.reviewNominalEmptyCommissioningRetreat(from:q,map:map,model:model,generation:42,
   sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,nowMilliseconds:1000,trial:trial(map),measuredAtMilliseconds:1000,
   nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)}
  var drift=q;drift[0]=0.003
  rejected("fresh start") {try decoded.validateContext(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:trial(map),measuredAtMilliseconds:1000,measuredBaseline:drift,oneDegreeEmptyCalibrationStepEnabled:true,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)}
  rejected("distinct one-degree") {try decoded.validateContext(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:trial(map),measuredAtMilliseconds:1000,measuredBaseline:q,oneDegreeEmptyCalibrationStepEnabled:false,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)}
  var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded)) as! [String:Any]
  json["goal"]=[0.0,-0.03,0,0,0,0,0]
  let forged=try JSONDecoder().decode(ROBWorkspaceOneDegreeEmptyCalibrationStep.self,from:JSONSerialization.data(withJSONObject:json))
  rejected("distinct one-degree") {try forged.validateContext(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:trial(map),measuredAtMilliseconds:1000,measuredBaseline:q,oneDegreeEmptyCalibrationStepEnabled:true,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)}
  var diagnostic=json["environmentDiagnostics"] as! [String:Any];diagnostic["predictedNominalContact"]=false;json["environmentDiagnostics"]=diagnostic;json["goal"]=proof.goal
  let hiddenContact=try JSONDecoder().decode(ROBWorkspaceOneDegreeEmptyCalibrationStep.self,from:JSONSerialization.data(withJSONObject:json))
  rejected("retained environment diagnostics changed") {try hiddenContact.validate(map:map,model:model,generation:42,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   nowMilliseconds:1000,trial:trial(map),measuredAtMilliseconds:1000,measuredBaseline:q,oneDegreeEmptyCalibrationStepEnabled:true,emptyStateEvidenceSource:proof.emptyStateEvidenceSource)}
  print("PASS separate one-degree EMPTY actuator proof: retainedcontact explicitlyDIAGNOSTIC, exactdelta/4s/20mm/selfnonworsening, nojaw/payload/chaining/transfers; newflag/freshness/source/body/drift/tamper guards; ordinary+nominal stillreject")
 }
}
'''
fixture=fixture.replace('   try .reviewImpossiblePlaceholder()', '''   try ROBWorkspaceCollisionPlan.reviewOneDegreeEmptyCalibrationStep(from:baseline,map:m,model:model,generation:42,sceneID:m.sceneID,
    cameraGeneration:m.cameraGeneration,nowMilliseconds:1000,trial:trial(m,baseline),measuredAtMilliseconds:measured,
    oneDegreeEmptyCalibrationStepEnabled:enabled,emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")''')
with tempfile.TemporaryDirectory(prefix='rob-one-degree-') as temp:
    directory=pathlib.Path(temp);swift=directory/'Fixture.swift';swift.write_text('import Foundation\nimport simd\n'+fixture);binary=directory/'fixture'
    sources=['ROBArmRoutinePlan.swift','ROBArmJointLimits.swift','ROBArmControlProtocol.swift','ROBGhostMotionPlan.swift','ROBWorkspaceSearchPlan.swift','ROBWorkspaceCollisionPlan.swift']
    subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',*[str(repo/'Cerebro'/s)for s in sources],str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(repo)],check=True)
