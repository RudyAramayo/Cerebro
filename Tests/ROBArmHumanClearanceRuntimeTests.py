#!/usr/bin/env python3
"""Actual frame-bound token/factory wiring; inert controlled geometry result."""
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration as block
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
method=block(source,'func makeGripperVisualServoFrame(')
guard=method[method.index('        guard nowMilliseconds'):method.index('        let width=min(320,source.width)')]
assert 'humanClearance:HumanClearance? = nil' in method
swift=r'''
import Foundation
import simd
import CryptoKit
/* EVIDENCE */
struct ROBGhostRobotModel {
 let modelID="actual-model-fixture",geometryID="geometry",selectedMappingID="right"
 static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}
enum ROBWorkspaceHumanProximity {
 struct Assessment {let clear:Bool,reason:String}
 static var clear=true,calls=0,lastRegions:[[Double]]=[],lastRoute:[[Double]]=[]
 static func assess(model:ROBGhostRobotModel,baseline:[Double],route:[[Double]],cameraToRobot:simd_double4x4,
  width:Int,height:Int,fx:Double,fy:Double,cx:Double,cy:Double,humanRegions:[[Double]],localizationSucceeded:Bool,
  spatialErrorMeters:Double)->Assessment {
  calls+=1;lastRegions=humanRegions;lastRoute=route
  return .init(clear:clear && localizationSucceeded,reason:"controlled inert core verdict")
 }
}
enum ROBVisualGraspVerifier {enum Unavailable:Error {case evidence(String)}}
struct Runtime {let identity:String}
struct Match {var status="matched"}
struct K {
 var fx=500.0,fy=500.0,cx=319.5,cy=239.5
 var rgbOutputUndistorted:Bool?=true,depthRGBGeometryCorrespondence:Match?=Match()
 var cameraServiceSourceSHA256:String?="source",runtimeCalibration:Runtime?=Runtime(identity:"runtime")
 func isValid(forWidth:Int,height:Int)->Bool {forWidth==640 && height==480}
}
struct Depth {var width=640,height=480}
struct Image {var extent=0}
struct CGImage {var width=640,height=480}
struct Context {func createCGImage(_ image:Image,from:Int)->CGImage? {CGImage()}}
final class Harness {
 struct Frame {
  var image=Image()
  var capturedAt:Double
  var sequence:UInt64=7
  var handsClear=false,depthCoverage=0.25
  var depth:Depth?=Depth(),intrinsics:K?=K()
  var cameraGeneration:UUID
  var humanObservations:ROBArmHumanObservationEvidence?=nil
 }
 var cameraGeneration=UUID(),context=Context()
 /* TOKEN */
 /* FACTORY */
 /* FRESH */
 func adapter(frame:Frame,scopeIdentity:String="frozen-route",jointPositions:[Double]=Array(repeating:0,count:7),
  jointCapturedAtMilliseconds:Double,poseHeldDuringCapture:Bool=true,openingCommandAtMilliseconds:Double?=nil,
  nowMilliseconds:Double,humanClearance:HumanClearance?=nil)throws->Bool {
  /* GUARD */
  return true
 }
}
func evidence(_ f:Harness.Frame,success:Bool=true,unlocalized:Bool=false,regions:[ROBArmHumanObservationEvidence.Region]=[])->ROBArmHumanObservationEvidence {
 .init(sequence:f.sequence,capturedAtMilliseconds:f.capturedAt,cameraGeneration:f.cameraGeneration,width:640,height:480,
  handRequestSucceeded:success,personRequestSucceeded:success,handObservationCount:0,personObservationCount:regions.count,
  hasUnlocalizedRelevantObservation:unlocalized,unavailableReason:success ? nil:"failed",regions:regions)
}
@main enum Fixture {
 static func main()throws {
  let h=Harness(),now=Date().timeIntervalSince1970*1000,model=ROBGhostRobotModel(),q=Array(repeating:0.0,count:7)
  let route=[[0.01,0,0,0,0,0,0]]
  var frame=Harness.Frame(capturedAt:now-20,cameraGeneration:h.cameraGeneration)
  frame.humanObservations=evidence(frame)
  func make(_ f:Harness.Frame,scope:String="frozen-route",path:[[Double]]?=nil)throws->Harness.HumanClearance {
   try h.makeHumanClearance(frame:f,scopeIdentity:scope,model:model,baseline:q,route:path ?? route,cameraToRobot:matrix_identity_double4x4)
  }
  func rejected(_ body:()throws->Void) {do {try body();preconditionFailure("Invalid human token/adapter accepted")}catch{}}
  let token=try make(frame)
  precondition(token.matches(frame:frame,scopeIdentity:"frozen-route") && token.assessment.clear)
  precondition(ROBWorkspaceHumanProximity.calls==1 && ROBWorkspaceHumanProximity.lastRoute==route)
  let accepted=try h.adapter(frame:frame,jointCapturedAtMilliseconds:now-10,nowMilliseconds:now,humanClearance:token)
  precondition(accepted)
  rejected{_ = try h.adapter(frame:frame,jointCapturedAtMilliseconds:now-10,nowMilliseconds:now)}
  var legacy=frame;legacy.handsClear=true
  let legacyAccepted=try h.adapter(frame:legacy,jointCapturedAtMilliseconds:now-10,nowMilliseconds:now)
  precondition(legacyAccepted)
  let changedRoute=try make(frame,path:[[0.02,0,0,0,0,0,0]])
  precondition(changedRoute.routeIdentity != token.routeIdentity)
  // Forward actual upper-body rectangle only after a conservative lower-body
  // envelope, and retain native hand/person relevance thresholds.
  let person=ROBArmHumanObservationEvidence.Region(kind:.person,confidence:0.8,
   normalizedTopLeft:.init(xMin:0.2,yMin:0.3,xMax:0.45,yMax:0.7),upperBodyOnly:true)
  let weak=ROBArmHumanObservationEvidence.Region(kind:.hand,confidence:0.2,
   normalizedTopLeft:.init(xMin:0.1,yMin:0.1,xMax:0.2,yMax:0.2),upperBodyOnly:false)
  var visible=frame;visible.humanObservations=evidence(visible,regions:[person,weak])
  _ = try make(visible)
  let box=ROBWorkspaceHumanProximity.lastRegions[0]
  precondition(ROBWorkspaceHumanProximity.lastRegions.count==1 && abs(box[0]-0.075)<1e-12 && box[3]==1)
  ROBWorkspaceHumanProximity.clear=false;rejected{_ = try make(visible)};ROBWorkspaceHumanProximity.clear=true
  for mode in 0..<10 {
   var bad=frame
   switch mode {
   case 0:bad.sequence+=1
   case 1:bad.capturedAt-=1
   case 2:bad.cameraGeneration=UUID()
   case 3:bad.intrinsics?.cameraServiceSourceSHA256="changed"
   case 4:bad.intrinsics?.runtimeCalibration=Runtime(identity:"changed")
   case 5:bad.intrinsics?.fx+=1
   case 6:bad.depth?.width=639
   case 7:bad.humanObservations=nil
   case 8:bad.humanObservations=evidence(bad,success:false)
   default:bad.humanObservations=evidence(bad,unlocalized:true)
   }
   precondition(!token.matches(frame:bad,scopeIdentity:"frozen-route"))
   rejected{_ = try h.adapter(frame:bad,jointCapturedAtMilliseconds:now-10,nowMilliseconds:now,humanClearance:token)}
  }
  precondition(!token.matches(frame:frame,scopeIdentity:"different-route"))
  rejected{_ = try h.adapter(frame:frame,scopeIdentity:"different-route",jointCapturedAtMilliseconds:now-10,nowMilliseconds:now,humanClearance:token)}
  var old=frame;old.capturedAt=now-701;old.humanObservations=evidence(old);rejected{_ = try make(old)}
  var future=frame;future.capturedAt=now+1000;future.humanObservations=evidence(future);rejected{_ = try make(future)}
  var sparse=frame;sparse.depthCoverage=0.249;rejected{_ = try make(sparse)}
  rejected{_ = try make(frame,scope:"")};rejected{_ = try make(frame,path:[])}
  rejected{_ = try h.adapter(frame:frame,jointCapturedAtMilliseconds:now-1000,nowMilliseconds:now,humanClearance:token)}
  rejected{_ = try h.adapter(frame:frame,jointCapturedAtMilliseconds:now-10,poseHeldDuringCapture:false,nowMilliseconds:now,humanClearance:token)}
  print("PASS actual native sameframe human-token factory/adapter: callscontrolledkernelwithfrozenroute+sameframeevidence; unknown/failure/overlap holds; upperbodyextension+thresholds; source/K/seq/time/gen/scope binding; final700/depth/feedback/held checks; legacydefaultunchanged. Geometry tested separately; no device/motionauthority.")
 }
}
'''.replace('/* EVIDENCE */',block(source,'struct ROBArmHumanObservationEvidence {'))
swift=swift.replace('/* TOKEN */',block(source,'struct HumanClearance {')).replace('/* FACTORY */',block(source,'func makeHumanClearance('))
swift=swift.replace('/* FRESH */',block(source,'private func isFresh(')).replace('/* GUARD */',guard)
with tempfile.TemporaryDirectory(prefix='rob-frame-human-token-',dir='/private/tmp') as folder:
 path=Path(folder);(path/'Fixture.swift').write_text(swift)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(path/'Fixture.swift'),'-o',str(path/'fixture')],check=True,timeout=35)
 subprocess.run([str(path/'fixture')],check=True,timeout=10)
