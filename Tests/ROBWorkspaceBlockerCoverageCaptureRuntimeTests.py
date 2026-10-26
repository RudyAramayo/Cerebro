#!/usr/bin/env python3
"""Run the production targeted-capture method with inert source/neck services.

No camera, actuator, serial socket, robot app or authorization service is opened.
Core selection/ray-map fixtures separately exercise their production algorithms.
"""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]

def method(source, marker):
    start = source.index(marker)
    i = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[i] == '{') - (source[i] == '}')
        i += 1
    return source[start:i]

FIXTURE = r'''
import Foundation
import simd
struct ProcessInfo {static let processInfo=Clock()}
final class Clock {var systemUptime=100.0}
final class Modes {static var mode="normal";static var appended:[(UInt64,Double)]=[];static var selected=0}
struct ROBWorkspaceView:Equatable {let panDegrees:Double;let upperTarget:Int}
struct ROBWorkspaceVoxel {let x:Int,y:Int,z:Int}
struct ROBWorkspaceUnknownCellBlocker {let link="right_five_Link";let voxel=ROBWorkspaceVoxel(x:-4,y:-8,z:21);let center=SIMD3<Double>(-0.0875,-0.1875,0.5375);let voxelSizeMeters=0.025}
enum VoxelState:UInt8 {case unknown,free,occupied}
struct Observation {let sequence:UInt64}
struct ROBWorkspaceCollisionSnapshot {
 var sceneID=UUID();let modelID="model",geometryID="geometry",mappingID="mapping";let sessionGeneration:UInt64=1
 var cameraGeneration:UUID;let estimatedCameraProjectionIdentity:String?="projection";var bodyMotionIdentity="body"
 let oldestCapturedAtMilliseconds=Date().timeIntervalSince1970*1000-500
 var lastCapturedAtMilliseconds=Date().timeIntervalSince1970*1000-400
 var observedFrameCount=5;var isTruncated=false;var occupiedVoxelCount=20;var fingerprint="before"
 var observations=[Observation(sequence:1)];var registrationID:String?=nil;var visualCalibrationScope:Int?=1
 var stateValue=VoxelState.unknown
 func state(at:SIMD3<Double>)->VoxelState {stateValue}
}
struct ROBGhostRobotModel {let modelID="model",geometryID="geometry",selectedMappingID="mapping"}
struct Pixels {let width=640,height=480;func distanceMillimeters(x:Int,y:Int)->UInt16? {Modes.mode=="hole" ? 0:1000}}
typealias CameraDepthFrame=Pixels
typealias CameraIntrinsics=K
struct Correspondence {var status="matched"}
struct K {
 var fx=500.0,fy=500.0,cx=320.0,cy=240.0;var rgbOutputUndistorted:Bool?=true
 var depthRGBGeometryCorrespondence:Correspondence?=Correspondence();let cameraServiceSourceSHA256:String?="source"
 func isValid(forWidth:Int,height:Int)->Bool {forWidth==640 && height==480}
}
struct ROBFixedHeadRegistrationScope:Equatable {
 let panTarget:Int,lowerTarget:Int,upperTarget:Int;let gatewaySessionGeneration:UInt64=1;let cameraGeneration:UUID
}
struct ROBWorkspaceCaptureAnchor {
 var generation:UUID?
 mutating func accept(frameGeneration:UUID,currentGeneration:UUID)->Bool {
  guard frameGeneration==currentGeneration,generation.map({$0==currentGeneration}) ?? true else {return false}
  generation=currentGeneration;return true
 }
 func permitsCurrent(_ current:UUID)->Bool {generation.map({$0==current}) ?? true}
}
final class ROBArmRoutineVision {
 static let shared=ROBArmRoutineVision();var cameraGeneration=UUID();var next:UInt64=2
 struct Frame {let capturedAt:Double;let sequence:UInt64;let cameraGeneration:UUID;var depth:Pixels?=Pixels();var intrinsics:K?=K()}
 func snapshot()->[String:Frame] {["face":Frame(capturedAt:Date().timeIntervalSince1970*1000,sequence:next,cameraGeneration:cameraGeneration)]}
 func settledDepthFrame(deadlineUptime:Double?)async throws->Frame {
  precondition(deadlineUptime==112)
  next+=1
  if Modes.mode=="source_changed" {cameraGeneration=UUID()}
  if Modes.mode=="body_changed" {ROBFixedHeadBodyMotionIdentity.currentIdentity="moved"}
  if Modes.mode=="cancel" {throw CancellationError()}
  if Modes.mode=="deadline" {ProcessInfo.processInfo.systemUptime=113}
  var frame=Frame(capturedAt:Date().timeIntervalSince1970*1000,sequence:next,cameraGeneration:cameraGeneration)
  if Modes.mode=="changed_k" {frame.intrinsics!.fx=501}
  if Modes.mode=="unnormalized" {frame.intrinsics!.rgbOutputUndistorted=false}
  if Modes.mode=="unsynchronized" {frame.intrinsics!.depthRGBGeometryCorrespondence!.status="bad"}
  if Modes.mode=="raw_pose_changed" {ROBFixedHeadCalibrationWindowController.shared.neck["pan"]=6001}
  return frame
 }
}
final class ROBFixedHeadCalibrationWindowController {
 static let shared=ROBFixedHeadCalibrationWindowController()
 var neck:[String:Any]=[:]
 var readNeck:(()->[String:Any])? {{self.neck}}
 func scope(model:ROBGhostRobotModel,frame:ROBArmRoutineVision.Frame)throws->ROBFixedHeadRegistrationScope {
  .init(panTarget:neck["pan"]as!Int,lowerTarget:neck["lower"]as!Int,upperTarget:neck["upper"]as!Int,cameraGeneration:frame.cameraGeneration)
 }
}
enum ROBFixedHeadBodyMotionIdentity {static var currentIdentity="body"}
final class ROBAmberGatewayClient {static let shared=ROBAmberGatewayClient();func connectionSnapshot()->[String:Any] {["sessionGeneration":NSNumber(value:1)]}}
enum ROBNeckRGBPoseDisplay {
 static func provisionalCameraToModel(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->simd_double4x4? {matrix_identity_double4x4}
}
struct ROBWorkspaceBlockerCoverageCandidate {let view:ROBWorkspaceView;let cameraToRobotColumnMajor:[Double]}
enum ROBWorkspaceBlockerCoveragePlan {
 static func nextView(blocker:ROBWorkspaceUnknownCellBlocker,candidates:[ROBWorkspaceBlockerCoverageCandidate],observations:[Observation],attempted:[ROBWorkspaceView],width:Int,height:Int,fx:Double,fy:Double,cx:Double,cy:Double)->ROBWorkspaceView? {
  Modes.selected+=1;precondition(candidates.count==52)
  return Modes.mode=="no_view" ? nil:candidates.first!.view
 }
}
struct ROBWorkspaceDepthMap {
 var current:ROBWorkspaceCollisionSnapshot
 init(continuing snapshot:ROBWorkspaceCollisionSnapshot,modelID:String,geometryID:String,mappingID:String,sessionGeneration:UInt64,cameraGeneration:UUID,estimatedCameraProjectionIdentity:String)throws {current=snapshot}
 mutating func append(width:Int,height:Int,fx:Double,fy:Double,cx:Double,cy:Double,depth:(Int,Int)->UInt16?,cameraToRobot:simd_double4x4,capturedAtMilliseconds:Double,sequence:UInt64,cameraGeneration:UUID,measuredSelfBounds:[Int],cameraRegistrationVerified:Bool,recordedPanDegrees:Double,recordedUpperTarget:Int,recordedLowerTarget:Int,estimatedCameraProjectionIdentity:String)throws {
  precondition(!cameraRegistrationVerified && measuredSelfBounds.isEmpty && recordedLowerTarget==6011)
  Modes.appended.append((sequence,capturedAtMilliseconds));current.observedFrameCount+=1;current.lastCapturedAtMilliseconds=capturedAtMilliseconds
  current.observations.append(.init(sequence:sequence));current.fingerprint="after\(Modes.appended.count)"
  if Modes.mode != "hole" {current.stateValue = .free}
 }
 func snapshot()->ROBWorkspaceCollisionSnapshot? {current}
}
enum ROBWorkspaceDepthMapError:Error {case invalidFrame;case acquisition(String);case expiredAtProjection}
@MainActor final class Harness:NSObject {
 var boundedPan:((Double)->Double)? = {max(-60,min(60,$0))}
 var canUseView:((Double,Int)->Bool)? = {_,_ in true}
 var panTargetForView:((Double)->NSNumber?)? = {NSNumber(value:Int((6000+$0*100/3).rounded()))}
 var prepareView:((Double,Int)->Bool)?,viewReady:((Double,Int)->Bool)?
 var collisionSnapshotValue:ROBWorkspaceCollisionSnapshot?,collisionSnapshotModel:ROBGhostRobotModel?
 var lastReport:NSDictionary=[:]
 func requireEstimatedProjectionIdentity(_ value:String?,model:ROBGhostRobotModel)throws {precondition(value=="projection")}
 func registeredCameraContext(frame:ROBArmRoutineVision.Frame,model:ROBGhostRobotModel)->Int? {Modes.mode=="registered" ? 1:nil}
 func unregisteredCameraProjection(frame:ROBArmRoutineVision.Frame,view:ROBWorkspaceView,model:ROBGhostRobotModel)throws->(matrix:simd_double4x4,identity:String?,lowerTarget:Int?) {(matrix_identity_double4x4,"projection",6011)}
 __ACTUAL_METHOD__
}
@main struct Fixtures {
 @MainActor static func exercise(_ mode:String="normal",attempted:[ROBWorkspaceView]=[])async throws->(Harness,ROBWorkspaceCollisionSnapshot?,ROBWorkspaceCollisionSnapshot) {
  Modes.mode=mode;Modes.appended=[];Modes.selected=0;ProcessInfo.processInfo.systemUptime=100
  ROBFixedHeadBodyMotionIdentity.currentIdentity="body";ROBArmRoutineVision.shared.cameraGeneration=UUID();ROBArmRoutineVision.shared.next=2
  let c=ROBFixedHeadCalibrationWindowController.shared
  c.neck=["known":true,"stationary":true,"lower":6011,"upper":6306,"pan":6000,"pan_degrees":0.0,"ready_at":99.0]
  let h=Harness(),s=ROBWorkspaceCollisionSnapshot(cameraGeneration:ROBArmRoutineVision.shared.cameraGeneration)
  h.collisionSnapshotValue=s
  var preparePolls=0
  h.prepareView={pan,upper in
   preparePolls+=1;ProcessInfo.processInfo.systemUptime+=0.8
   if mode=="in_flight",preparePolls<3 {c.neck["stationary"]=false;return false}
   c.neck["stationary"]=true
   c.neck["pan"]=Int((6000+pan*100/3).rounded());c.neck["pan_degrees"]=pan;c.neck["upper"]=upper
   return mode != "view_unavailable"
  }
  h.viewReady={_,_ in mode != "view_unavailable"}
  let result=try await h.captureBlockerCoverage(blocker:.init(),continuing:s,model:.init(),generation:1,attempted:attempted,deadlineUptime:130,check:{},progress:{_ in})
  return (h,result?.snapshot,s)
 }
 @MainActor static func main()async throws {
  let (h,r,s)=try await exercise();let x=r!
  precondition(x.sceneID==s.sceneID && x.observedFrameCount==7 && x.occupiedVoxelCount==20 && x.stateValue == .free)
  precondition(Modes.appended.count==2 && Modes.appended[0].0<Modes.appended[1].0 && Modes.appended[0].1<Modes.appended[1].1)
  precondition(h.collisionSnapshotValue!.fingerprint==x.fingerprint)
  let diag=(h.lastReport["blocker_coverage_attempts"]as![[String:Any]]).last!
  precondition(diag["free_space_inferred"]as!Bool==false && diag["arm_command_sent"]as!Bool==false)
  precondition(diag["detector_invoked"]as!Bool==false && diag["source_rasters_retained"]as!Bool==false)
  let (holeHarness,hole,_)=try await exercise("hole");precondition(hole!.stateValue == .unknown && hole!.observedFrameCount==7,"A missing region was invented free")
  let holeAttempt=(holeHarness.lastReport["blocker_coverage_attempts"]as![[String:Any]]).last!
  let roi=((holeAttempt["frames"]as![[String:Any]])[0]["blocker_depth_roi"]as![String:Any])
  precondition(roi["valid_depth_pixels"]as!Int==0 && roi["missing_or_zero_depth_pixels"]as!Int>0 && roi["free_space_proof"]as!Bool==false)
  let (_,transit,_)=try await exercise("in_flight");precondition(transit!.observedFrameCount==7 && Modes.appended.count==2,"Normal neck transit rejected before settling")
  let (_,none,_)=try await exercise("no_view");precondition(none==nil && Modes.appended.isEmpty)
  let (_,registered,_)=try await exercise("registered");precondition(registered==nil && Modes.selected==0 && Modes.appended.isEmpty)
  let (_,budget,_)=try await exercise(attempted:[.init(panDegrees:0,upperTarget:5300),.init(panDegrees:10,upperTarget:5300)])
  precondition(budget==nil && Modes.selected==0 && Modes.appended.isEmpty)
  let (_,unavailable,_)=try await exercise("view_unavailable");precondition(unavailable==nil && Modes.appended.isEmpty)
  for mode in ["source_changed","body_changed","changed_k","unnormalized","unsynchronized","raw_pose_changed","deadline","cancel"] {
   do {_=try await exercise(mode);preconditionFailure("Accepted changed context: \(mode)")}catch {}
   precondition(Modes.appended.isEmpty,"Changed input enrolled actual map rays: \(mode)")
  }
  print("PASS production targeted blocker capture: bounded novel view, actual raw pan/lower6011/settle checks, same-scene2advancing exposures, original times, persistent hole stays unknown, no view/budget stop, source/body/K/normalization/synchronization/raw hold/deadline/Stop rejection; no actuator or camera IO")
 }
}
'''

def main():
    source = (ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
    actual = method(source, '    @MainActor @nonobjc func captureBlockerCoverage(')
    forbidden = ['observeWorkspace', 'sendApproved', 'setGripper', 'measuredSelfBounds(model:', 'finishView?()']
    assert not any(token in actual for token in forbidden)
    assert 'capturedAtMilliseconds:frame.capturedAt,sequence:frame.sequence' in actual
    assert 'measuredSelfBounds:[],cameraRegistrationVerified:false' in actual
    with tempfile.TemporaryDirectory(prefix='rob-blocker-capture-') as folder:
        p=Path(folder);swift=p/'Fixture.swift';binary=p/'fixture'
        swift.write_text(FIXTURE.replace('__ACTUAL_METHOD__',actual))
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True,timeout=60)
        subprocess.run([str(binary)],check=True,timeout=20)
if __name__=='__main__': main()
