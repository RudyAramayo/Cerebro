#!/usr/bin/env python3
"""Run real planning-time statements, scene accessors and trial validation.

Proof creation deliberately takes time. Each production call site must capture
its validation time afterwards; future-issued and expired proofs still reject.
No transport, camera or actuator implementation exists in this fixture.
"""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

root = Path(__file__).resolve().parents[1]
source = (root / 'Cerebro/ROBLeftArmTrial.swift').read_text()
collision = (root / 'Cerebro/ROBWorkspaceCollisionPlan.swift').read_text()
vision = (root / 'Cerebro/ROBArmRoutineVision.swift').read_text()
trial = braced_declaration(collision, 'struct ROBWorkspaceVisualCalibrationTrial:')
validator = braced_declaration(collision, '    static func validateVisualCalibrationTrialMap(')
ordinary_scene = braced_declaration(vision, '    @nonobjc var collisionSnapshot:').replace('@nonobjc ', '')
trial_scene = braced_declaration(vision, '    @nonobjc func collisionSnapshot(validating').replace('@nonobjc ', '')
context_check = braced_declaration(source, '    private func checkCollisionContext(')
assert 'collisionSnapshot(validating:$0)' in context_check
assert context_check.index('visual=try visualTrial(') < context_check.index('collisionSnapshot(validating:$0)')

def statements(start, end, within=None):
    text = braced_declaration(source, within) if within else source
    first = text.index(start)
    return text[first:text.index(end, first)]

connector = statements('let baseline = try measured()', 'let result = try await',
    '    @MainActor private func workspaceConnector(')
grasp = statements('let planningStart = q, session = generation',
    'guard !activeApproachCanThenHold')
jaws = statements('let q=try measured().positionsRadians', '_ = try await Task.detached',
    '    @MainActor private func emptyJawIdentificationIsClear(')

fixture = r'''
import Foundation
enum ROBGhostMotionError:LocalizedError {
 case blocked(String)
 var errorDescription:String? {if case .blocked(let value)=self{return value};return nil}
}
struct ROBGhostRobotModel {
 let physicalSide="right",modelID="model",geometryID="geometry",selectedMappingID="mapping"
 func positions(vendorLeft:[Double])->[String:Double]{[:]}
}
struct ROBWorkspaceVisualCalibrationMapScope {
 let bodyMotionIdentity:String,bodyContextIsCurrent:Bool,observedFrameCount:Int
 let estimatedCameraProjectionIdentity:String,observationPoseIdentity:String
}
protocol ROBWorkspaceCollisionMap {
 var sessionGeneration:UInt64{get};var sceneID:UUID{get};var cameraGeneration:UUID{get}
 var modelID:String{get};var geometryID:String{get};var mappingID:String{get};var fingerprint:String{get}
 var registrationID:String?{get};var registrationUncertaintyMeters:Double?{get}
 var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope?{get}
 var createdAtMilliseconds:Double{get};var oldestCapturedAtMilliseconds:Double{get}
 var lastCapturedAtMilliseconds:Double{get};var voxelSizeMeters:Double{get}
}
struct Map:ROBWorkspaceCollisionMap {
 let sessionGeneration:UInt64=1,sceneID=UUID(),cameraGeneration=UUID()
 let modelID="model",geometryID="geometry",mappingID="mapping",fingerprint=String(repeating:"a",count:64)
 let registrationID:String?=nil,registrationUncertaintyMeters:Double?=nil
 var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope? = .init(
  bodyMotionIdentity:"body",bodyContextIsCurrent:true,observedFrameCount:2,
  estimatedCameraProjectionIdentity:String(repeating:"b",count:64),observationPoseIdentity:String(repeating:"c",count:64))
 var createdAtMilliseconds=Date().timeIntervalSince1970*1000
 var oldestCapturedAtMilliseconds:Double{createdAtMilliseconds}
 var lastCapturedAtMilliseconds:Double{createdAtMilliseconds}
 let voxelSizeMeters=0.025
}
struct ROBWorkspaceCollisionContext {
 let sceneID:UUID,cameraGeneration:UUID,sessionGeneration:UInt64
 let modelID:String,geometryID:String,mappingID:String,mapFingerprint:String
 let registrationID:String?,registrationUncertaintyMeters:Double?
 let oldestCapturedAtMilliseconds:Double,lastCapturedAtMilliseconds:Double,checkedAtMilliseconds:Double
 let visualTrial:ROBWorkspaceVisualCalibrationTrial
}
/* TRIAL */
enum ROBWorkspaceCollisionPlan {
 static let maximumMapAgeMilliseconds=60_000.0
 /* VALIDATOR */
}
struct Sample {let positionsRadians=Array(repeating:NSNumber(value:0),count:7)}
struct Vision {let cameraGeneration:UUID}
typealias ROBWorkspaceCollisionSnapshot=Map
final class ROBArmRoutineVision {static let shared=ROBArmRoutineVision();var cameraGeneration=UUID()}
final class ROBAmberGatewayClient {
 static let shared=ROBAmberGatewayClient();var generation:UInt64=1
 func connectionSnapshot()->NSDictionary{["sessionGeneration":NSNumber(value:generation)]}
}
final class Search {
 var collisionSnapshotValue:Map?,collisionSnapshotModel:ROBGhostRobotModel?
 var projectionCurrent=true
 func estimatedCameraProjectionIsCurrent(model:ROBGhostRobotModel,map:Map)->Bool{projectionCurrent}
 /* ORDINARY_SCENE */
 /* TRIAL_SCENE */
}
final class Planner {
 let map=Map(),model=ROBGhostRobotModel(),generation:UInt64=1
 var vision:Vision{Vision(cameraGeneration:map.cameraGeneration)}
 func measured()throws->Sample{Sample()}
 func visualTrial(map:Map,model:ROBGhostRobotModel,baseline:[Double],advisory:Bool=false)throws->ROBWorkspaceVisualCalibrationTrial? {
  Thread.sleep(forTimeInterval:0.005)
  let issued=Date().timeIntervalSince1970*1000
  return .init(receiptID:"isolated fixture",receiptSHA256:String(repeating:"d",count:64),appSessionID:"fixture",
   command:"right_recycle_cans",canCount:8,summarySHA256:String(repeating:"e",count:64),authorizationContextIdentity:"fixture",
   sessionGeneration:generation,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
   modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:map.fingerprint,
   bodyMotionIdentity:"body",estimatedCameraProjectionIdentity:String(repeating:"b",count:64),
   observationPoseIdentity:String(repeating:"c",count:64),currentPoseIdentity:String(repeating:"f",count:64),
   baseline:baseline,issuedAtMilliseconds:issued,expiresAtMilliseconds:issued+1_000,assumedSpatialErrorMeters:0.05,
   operatorClearedCameraCollisionAdvisory:advisory)
 }
 func validate(_ trial:ROBWorkspaceVisualCalibrationTrial,now:Double)throws {
  _ = try ROBWorkspaceCollisionPlan.validateVisualCalibrationTrialMap(map,model:model,generation:generation,
   sceneID:map.sceneID,cameraGeneration:vision.cameraGeneration,nowMilliseconds:now,trial:trial)
 }
 func connector()throws->Bool {
  /* CONNECTOR */
  _ = (session,camera)
  try validate(visual!,now:now);return true
 }
 func grasp()throws->Bool {
  let q=try measured().positionsRadians.map(\.doubleValue)
  /* GRASP */
  _ = (session,camera,baseline)
  try validate(visual!,now:now);return true
 }
 func jaws()throws->Bool {
  /* JAWS */
  _ = (session,camera)
  try validate(trial,now:now);return true
 }
}
@main enum Test {
 static func main()throws {
  let planner=Planner()
  let a=try planner.connector(),b=try planner.grasp(),c=try planner.jaws();precondition(a && b && c)
  let trial=try planner.visualTrial(map:planner.map,model:planner.model,baseline:Array(repeating:0,count:7))!
  for invalid in [trial.issuedAtMilliseconds-1,trial.expiresAtMilliseconds+1] {
   do {try planner.validate(trial,now:invalid);preconditionFailure("Invalid proof time admitted")}
   catch {precondition(error.localizedDescription.contains("scope"))}
  }
  let search=Search();search.collisionSnapshotValue=planner.map;search.collisionSnapshotModel=planner.model
  ROBArmRoutineVision.shared.cameraGeneration=planner.map.cameraGeneration
  precondition(search.collisionSnapshot != nil)
  var old=planner.map;old.createdAtMilliseconds-=70_000;search.collisionSnapshotValue=old
  precondition(search.collisionSnapshot == nil,"Ordinary cache age was widened")
  let normal=try planner.visualTrial(map:old,model:planner.model,baseline:Array(repeating:0,count:7))!
  precondition(search.collisionSnapshot(validating:normal)==nil,"Normal trial accepted expired geometry")
  let advisory=try planner.visualTrial(map:old,model:planner.model,baseline:Array(repeating:0,count:7),advisory:true)!
  #if DEBUG
  precondition(search.collisionSnapshot(validating:advisory)?.oldestCapturedAtMilliseconds==old.oldestCapturedAtMilliseconds,
   "Exact diagnostic campaign proof must retain its recorded map and timestamps after the ordinary60second cutoff")
  search.projectionCurrent=false;precondition(search.collisionSnapshot(validating:advisory)==nil);search.projectionCurrent=true
  ROBArmRoutineVision.shared.cameraGeneration=UUID();precondition(search.collisionSnapshot(validating:advisory)==nil)
  ROBArmRoutineVision.shared.cameraGeneration=old.cameraGeneration
  ROBAmberGatewayClient.shared.generation=2;precondition(search.collisionSnapshot(validating:advisory)==nil)
  ROBAmberGatewayClient.shared.generation=1
  search.collisionSnapshotModel=nil;precondition(search.collisionSnapshot(validating:advisory)==nil)
  search.collisionSnapshotModel=planner.model
  var moved=old;moved.visualCalibrationScope = .init(bodyMotionIdentity:"body",bodyContextIsCurrent:false,observedFrameCount:2,
   estimatedCameraProjectionIdentity:String(repeating:"b",count:64),observationPoseIdentity:String(repeating:"c",count:64))
  search.collisionSnapshotValue=moved;precondition(search.collisionSnapshot(validating:advisory)==nil)
  var expired=old;expired.createdAtMilliseconds-=600_000;search.collisionSnapshotValue=expired
  precondition(search.collisionSnapshot(validating:advisory)==nil,"Advisory map age became unbounded")
  #else
  precondition(search.collisionSnapshot(validating:advisory)==nil,"Release admitted DEBUG advisory evidence")
  #endif
  print("PASS real connector/grasp/jaw planning statements validate after proof issuance; future and expired proofs reject; no hardware")
  print("PASS real scene accessors preserve ordinary60s expiry; DEBUG exact advisory proof uses its bounded age; source/body/projection mismatches reject; timestamps unchanged")
 }
}
'''
for token, value in [('TRIAL',trial),('VALIDATOR',validator),('CONNECTOR',connector),('GRASP',grasp),('JAWS',jaws),
                     ('ORDINARY_SCENE',ordinary_scene),('TRIAL_SCENE',trial_scene)]:
    fixture = fixture.replace(f'/* {token} */', value)
with tempfile.TemporaryDirectory(prefix='rob-visual-trial-time-') as folder:
    path = Path(folder)
    swift = path / 'Fixture.swift'
    swift.write_text(fixture)
    binary = path / 'fixture'
    for flags in [[],['-D','DEBUG']]:
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',*flags,
            '-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
