#!/usr/bin/env python3
"""Execute actual native path binding/clearance gates with inert geometry/Vision seams.
Actual CAD and native Vision-token behavior are covered by their separate fixtures.
"""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1];source=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
path=braced_declaration(source,'    private struct ApproachHumanPath {').replace('private struct','struct',1)
policy=braced_declaration(source,'    private var usesApproachHumanCorridor:Bool {').replace('private var','var',1)
bind=braced_declaration(source,'    @MainActor private func bindApproachHumanPath(').replace('private func','func',1)
require=braced_declaration(source,'    private func requireApproachHumanClearance(').replace('private func','func',1)
fixture=r'''
import Foundation
import CryptoKit
import simd
enum ROBArmRoutineError:Error {case blocked(String)}
struct ROBGhostRobotModel {
 let modelID="model",geometryID="geometry",referenceID="reference",selectedMappingID="mapping",physicalSide="right"
 static func hash(_ d:Data)->String{SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}
}
struct ROBWorkspaceCollisionSnapshot{let fingerprint="map";var cameraGeneration:UUID}
enum ROBWorkspaceHumanProximity {
 struct PreparedCorridor {
  let modelID="model",geometryID="geometry",mappingID="mapping",physicalSide="right"
  let routeIdentity:String,cameraToRobotColumnMajor:[Double]
 }
 static func prepare(model:ROBGhostRobotModel,baseline:[Double],route:[[Double]],cameraToRobot:simd_double4x4,
  width:Int,height:Int,fx:Double,fy:Double,cx:Double,cy:Double,spatialErrorMeters:Double)throws->PreparedCorridor {
  precondition(!Thread.isMainThread,"CAD projection must run off the main actor")
  Thread.sleep(forTimeInterval:0.03)
  let bytes=try JSONEncoder().encode([baseline]+route)
  return .init(routeIdentity:ROBGhostRobotModel.hash(bytes),cameraToRobotColumnMajor:(0..<4).flatMap{c in (0..<4).map{cameraToRobot[c][$0]}})
 }
}
struct Scope {
 let modelID="model",geometryID="geometry",mappingID="mapping",panTarget=6000,lowerTarget=6011,upperTarget=5650
 let intrinsicsIdentity:String
}
@MainActor final class ROBFixedHeadCalibrationWindowController {
 static let shared=ROBFixedHeadCalibrationWindowController()
 var readNeck:(()->NSDictionary)?={["pan":6000,"lower":6011,"upper":5650]}
 static func intrinsicsIdentity(_ f:ROBArmRoutineVision.Frame)throws->String{f.intrinsics!.key}
 func scope(model:ROBGhostRobotModel,frame:ROBArmRoutineVision.Frame)throws->Scope{.init(intrinsicsIdentity:frame.intrinsics!.key)}
}
enum ROBFixedHeadBodyMotionIdentity{static var currentIdentity="body"}
enum ROBNeckRGBPoseDisplay {
 struct ActualFrameSource{let cameraGeneration:UUID,actualDeviceMXID:String?,runtimeCalibrationIdentity:String?,cameraServiceSourceSHA256:String?;let scope:Scope;let inertialJSON:Data?}
 static var projection="projection",sourceAccepts=true
 static func estimatedCameraProjectionIdentity(model:ROBGhostRobotModel)->String?{projection}
 static func provisionalCameraToModel(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->simd_double4x4?{matrix_identity_double4x4}
 static func estimatedProjectionAcceptsSource(model:ROBGhostRobotModel,actualFrame:ActualFrameSource)->Bool{sourceAccepts}
}
final class ROBArmRoutineVision {
 struct Runtime{let identity="runtime",actualDeviceMXID="device"}
 struct K{let fx=500.0,fy=500.0,cx=320.0,cy=240.0;var key="K",inertial:String?="imu",runtimeCalibration:Runtime?=Runtime(),cameraServiceSourceSHA256:String?="source";func isValid(forWidth:Int,height:Int)->Bool{forWidth==640 && height==480}}
 struct Depth{let width=640,height=480}
 struct Evidence{
  enum Kind{case hand,person};struct Rect{let xMin=0.8,yMin=0.1,xMax=0.9,yMax=0.2}
  struct Region{let kind=Kind.person,confidence=0.9,normalizedTopLeft=Rect(),upperBodyOnly=false}
  let sequence:UInt64,capturedAtMilliseconds:Double,cameraGeneration:UUID,width=640,height=480
  var localizationSucceeded=true,unavailableReason:String?=nil,regions=[Region()],blocked=false
 }
 struct Frame{var sequence:UInt64,capturedAt:Double,cameraGeneration:UUID;var depth:Depth?=Depth(),intrinsics:K?=K(),humanObservations:Evidence?;var handsClear=true}
 struct HumanClearance{
  let routeIdentity:String,sequence:UInt64,capturedAt:Double,generation:UUID,scope:String
  func matches(frame:Frame,scopeIdentity:String)->Bool{sequence==frame.sequence && capturedAt==frame.capturedAt && generation==frame.cameraGeneration && scope==scopeIdentity}
 }
 var cameraGeneration=UUID(),frame:Frame!,factoryCalls=0
 func snapshot()->[String:Frame]{["face":frame]}
 func makeHumanClearance(frame:Frame,scopeIdentity:String,preparedCorridor:ROBWorkspaceHumanProximity.PreparedCorridor)throws->HumanClearance{
  factoryCalls+=1
  guard frame.humanObservations?.localizationSucceeded==true else{throw ROBArmRoutineError.blocked("Vision analysis unavailable")}
  guard frame.humanObservations?.blocked==false else{throw ROBArmRoutineError.blocked("Observed human overlap")}
  return .init(routeIdentity:preparedCorridor.routeIdentity,sequence:frame.sequence,capturedAt:frame.capturedAt,generation:frame.cameraGeneration,scope:scopeIdentity)
 }
}
@MainActor final class Trial {
 static let approachHumanPolicyRevision="native_complete_padded_route_human_regions_v1"
 static let approachHumanGeometryQueue=DispatchQueue(label:"fixture.human-preparation")
 let vision=ROBArmRoutineVision();var activeApproachCanThenHold=true,localReceiptCommand:String?="right_recycle_cans"
 var recyclingGripDispatched=false,servoPossiblePayloadUncertain=false,physicalSide="right",generation:UInt64=1,summary="exact-open-empty-job",localVisualTrialAssumedSpatialErrorMeters=0.035
 var head="held",stopped=false,collisionReviewStatus:NSDictionary=[:]
 var collisionMap:ROBWorkspaceCollisionSnapshot?,collisionModel:ROBGhostRobotModel?=ROBGhostRobotModel()
 var approachHumanPath:ApproachHumanPath?,approachHumanClearanceCache:[String:ROBArmRoutineVision.HumanClearance]=[:]
 func requireLocalReceipt()throws->Bool{if stopped{throw ROBArmRoutineError.blocked("Stop")};return true}
 func localNeckIdentity()->String?{head}
 func check()throws{if stopped{throw ROBArmRoutineError.blocked("Stop")}}
 /* PATH */
 /* POLICY */
 /* BIND */
 /* REQUIRE */
}
@main enum Test {
 @MainActor static func make()->Trial {
  let t=Trial(),now=Date().timeIntervalSince1970*1000
  t.vision.frame = .init(sequence:1,capturedAt:now,cameraGeneration:t.vision.cameraGeneration,
    humanObservations:.init(sequence:1,capturedAtMilliseconds:now,cameraGeneration:t.vision.cameraGeneration))
  t.collisionMap = .init(cameraGeneration:t.vision.cameraGeneration)
  return t
 }
 @MainActor static func pin(_ t:Trial,_ goal:Double=0.02)async throws {
  try await t.bindApproachHumanPath(baseline:Array(repeating:0,count:7),route:[[goal,0,0,0,0,0,0]],map:t.collisionMap!,model:t.collisionModel!)
 }
 @MainActor static func main()async throws {
  let t=make();var mainActorAdvanced=false
  let tick=Task{@MainActor in try await Task.sleep(nanoseconds:5_000_000);mainActorAdvanced=true}
  try await pin(t);try await tick.value;precondition(mainActorAdvanced)
  t.vision.frame.handsClear=false
  let first=try t.requireApproachHumanClearance(frame:t.vision.frame)
  let again=try t.requireApproachHumanClearance(frame:t.vision.frame)
  precondition(t.vision.factoryCalls==1 && first.routeIdentity==again.routeIdentity,"Only identical actual frame/path may reuse its native token")
  _ = try t.requireApproachHumanClearance(frame:t.vision.frame,adapterScope:"actual-adapter-view")
  precondition(t.vision.factoryCalls==2)
  try await pin(t,0.04)
  let changed=try t.requireApproachHumanClearance(frame:t.vision.frame)
  precondition(first.routeIdentity != changed.routeIdentity && t.vision.factoryCalls==3,"Same frame cannot reuse a prior path token")
  for mode in 0..<8 {
   let x=make();try await pin(x)
   switch mode {
    case 0:x.vision.frame.humanObservations!.localizationSucceeded=false;x.vision.frame.humanObservations!.unavailableReason="request failed"
    case 1:x.vision.frame.humanObservations!.blocked=true
    case 2:x.head="changed"
    case 3:x.recyclingGripDispatched=true
    case 4:x.activeApproachCanThenHold=false
    case 5:x.vision.frame.capturedAt-=701
    case 6:x.vision.frame.intrinsics!.key="changed K"
    default:x.servoPossiblePayloadUncertain=true
   }
   // Legacy clear=true must NEVER suppress selected policy's own assessment.
   x.vision.frame.handsClear=true
   do{_ = try x.requireApproachHumanClearance(frame:x.vision.frame);preconditionFailure("Invalid selected-mode human evidence accepted")}catch{}
   if mode==0 || mode==1 || mode==6 {
    let facts=x.collisionReviewStatus["approach_human_clearance"]as!NSDictionary
    let expected=mode==0 ? "human_analysis_unavailable":mode==1 ? "human_corridor_not_clear":"human_source_scope_unavailable"
    precondition(facts["reason"]as?String==expected)
   }
  }
  print("PASS actual native human-policy path binding: CAD queued off-main; exact frame/path cache, route replacement, adapter scope, mandatory factory despite legacy bool; analysis/overlap/source distinctions; stale/changed/grip/payload/mode deny; no hardware")
 }
}
'''.replace('/* PATH */',path).replace('/* POLICY */',policy).replace('/* BIND */',bind).replace('/* REQUIRE */',require)
with tempfile.TemporaryDirectory(prefix='rob-approach-human-integration-',dir='/private/tmp')as folder:
 p=Path(folder);(p/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-D','DEBUG','-O','-swift-version','5','-parse-as-library',str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True,timeout=10)
