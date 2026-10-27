#!/usr/bin/env python3
"""Run actual local-only depth-coverage tail without camera or robot interfaces."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]

def block(s,marker):
 start=s.index(marker);i=s.index('{',start)+1;depth=1
 while depth:
  depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[start:i]

FIXTURE=r'''
import Foundation
struct ProcessInfo {static let processInfo=Clock()}
final class Clock {var systemUptime=100.0}
struct ROBWorkspaceView:Equatable {let panDegrees:Double;let upperTarget:Int}
struct Model {let physicalSide:String}
struct Map {var sceneID:UUID;let estimatedCameraProjectionIdentity:String?;let bodyMotionIdentity:String}
struct Frame {let sequence:UInt64;let capturedAt:Double}
struct Anchor {let generation:UUID;func permitsCurrent(_ current:UUID)->Bool {generation==current}}
struct Enrollment {var sequence:UInt64=1;var capturedAtMilliseconds:Double?=1000}
enum Target {case can,orangeBucket}
enum ROBWorkspaceDepthMapError:Error {case invalidFrame;case acquisition}
enum ROBFixedHeadBodyMotionIdentity {static var currentIdentity="body"}
final class ROBAmberGatewayClient {
 static let shared=ROBAmberGatewayClient()
 func connectionSnapshot()->[String:Any] {["sessionGeneration":NSNumber(value:1)]}
}
final class Vision {
 var cameraGeneration=UUID(),next:UInt64=2
 var mode="normal"
 func settledPassiveMappingFrame(deadlineUptime:Double?,check:()throws->Void)async throws->Frame {
  try check()
  precondition(deadlineUptime==120.0)
  if mode=="frame_unavailable" {throw ROBWorkspaceDepthMapError.acquisition}
  if mode=="deadline" {ProcessInfo.processInfo.systemUptime=121}
  if mode=="source_changed" {cameraGeneration=UUID()}
  let frame=Frame(sequence:next,capturedAt:1000+Double(next)*100);next+=1
  return frame
 }
 func healthSnapshot()->[String:Any] {[: ]}
}
struct Result {let evidence:[[String:Any]];let views:[ROBWorkspaceView];let captured:[Frame];let map:Map?}
@MainActor func exercise(side:String="right",permit:Bool=true,fixed:Bool=false,objects:Bool=true,canOnly:Bool=false,ready:Bool=false,mode:String="normal")async throws->Result {
 ProcessInfo.processInfo.systemUptime=100;ROBFixedHeadBodyMotionIdentity.currentIdentity="body"
 let requireDepth=true,collectCollisionDepth=true,fixedRegisteredView:ROBWorkspaceView?=fixed ? .init(panDegrees:0,upperTarget:6306):nil
 let armAlreadyAtGraspReady=ready
 let found:[Target:Int]=objects ? [.can:1,.orangeBucket:2]:[.can:1]
 let targets:[Target]=canOnly ? [.can]:[.can,.orangeBucket]
 let model=Model(physicalSide:side),vision=Vision();vision.mode=mode
 let sceneCaptureAnchor=Anchor(generation:vision.cameraGeneration),sceneGatewayGeneration:UInt64=1
 var collisionMap:Map? = .init(sceneID:UUID(),estimatedCameraProjectionIdentity:"projection",bodyMotionIdentity:"body")
 let initialScene=collisionMap!.sceneID
 var collisionEnrollment=Enrollment(),evidence:[[String:Any]]=[],views:[ROBWorkspaceView]=[],captured:[Frame]=[]
 let boundedPan:((Double)->Double)?={max(-60,min(60,$0))}
 func permitsLocalCanShapePrior()throws->Bool {permit}
 func check()throws {}
 func searchCheckpoint()async throws {try check()}
 func requireSceneProjectionIdentity()throws {}
 func progress(_ value:String) {}
 func moveView(_ view:ROBWorkspaceView,deadlineUptime:Double?)async throws->Bool {
  precondition(deadlineUptime==120.0);views.append(view)
  return mode != "view_unavailable"
 }
 func accumulateCollisionDepth(_ view:ROBWorkspaceView,capturedFrame:Frame?,preservingSceneID:UUID?)async throws {
  precondition(preservingSceneID==initialScene && preservingSceneID==collisionMap!.sceneID)
  let f=capturedFrame!;captured.append(f)
  collisionEnrollment.sequence=f.sequence;collisionEnrollment.capturedAtMilliseconds=f.capturedAt
  if mode=="map_replaced" {collisionMap!.sceneID=UUID()}
  if mode=="body_moved" {ROBFixedHeadBodyMotionIdentity.currentIdentity="moved"}
 }
 __ACTUAL_COVERAGE__
 return .init(evidence:evidence,views:views,captured:captured,map:collisionMap)
}
@main struct CoverageFixtures {
 @MainActor static func main()async throws {
  let right=try await exercise()
  precondition(right.views==[.init(panDegrees:-35,upperTarget:5650),.init(panDegrees:-55,upperTarget:5650),.init(panDegrees:-45,upperTarget:5300)])
  precondition(right.captured.map(\.sequence)==[2,3,4] && right.captured.map(\.capturedAt)==[1200,1300,1400])
  precondition(right.evidence.filter{$0["depth_only_arm_coverage"] as? Bool==true}.count==3)
  precondition(right.evidence.allSatisfy{$0["detector_invoked"] as? Bool != true && $0["free_space_inferred"] as? Bool != true})
  let summary=right.evidence.last!;precondition(summary["captured_views"] as! Int==3 && summary["maximum_views"] as! Int==3 && summary["budget_seconds"] as! Double==20.0)
  precondition(summary["scene_id"] as! String==right.map!.sceneID.uuidString)
  let left=try await exercise(side:"left");precondition(left.views==[.init(panDegrees:35,upperTarget:5650),.init(panDegrees:55,upperTarget:5650),.init(panDegrees:45,upperTarget:5300)])
  let firstGrasp=try await exercise(objects:false,canOnly:true)
  precondition(firstGrasp.views.count==3 && firstGrasp.captured.count==3,"Can-only grasp must retain whole-arm coverage without finding a bucket first")
  let ready=try await exercise(ready:true)
  precondition(ready.views.isEmpty && ready.captured.isEmpty && ready.map != nil)
  precondition(ready.evidence.count==1 && ready.evidence[0]["skipped_reason"] as? String=="already_at_measured_grasp_ready_pose")
  precondition(ready.evidence[0]["table_depth_retained"] as? Bool==true && ready.evidence[0]["motion_authority"] as? Bool==false)
  for mode in 0..<3 {
   let x=try await exercise(permit:mode != 0,fixed:mode==1,objects:mode != 2)
   precondition(x.views.isEmpty && x.captured.isEmpty && x.evidence.isEmpty)
  }
  let unavailable=try await exercise(mode:"frame_unavailable")
  precondition(unavailable.views.count==3 && unavailable.captured.isEmpty)
  precondition(unavailable.evidence.filter{$0["status"] as? String=="unavailable"}.count==3)
  let expired=try await exercise(mode:"deadline")
  precondition(expired.views.count==1 && expired.captured.isEmpty,"A budget-expired frame enrolled or extra view started")
  for mode in ["source_changed","map_replaced","body_moved"] {
   do {_=try await exercise(mode:mode);preconditionFailure("Changed context published coverage")}
   catch ROBWorkspaceDepthMapError.invalidFrame {}
  }
  print("PASS actual selected-arm depth-only coverage: local-only/defaultclosed/fixed-head untouched, three distinct mirrored views/shared20sdeadline, exact original timestamps/same scene enrollment, no detector or free-space invention, source/body/map changes reject")
 }
}
'''

def main():
 source=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
 marker='        if !armAlreadyAtGraspReady,requireDepth,collectCollisionDepth,fixedRegisteredView==nil,'
 tail=block(source,marker)+'\n'+block(source,'        if armAlreadyAtGraspReady {')
 assert source.index(marker)<source.index('        let missing = targets.filter { found[$0] == nil }')
 assert source.index(marker)<source.index('let frozen = await Task.detached(priority:.userInitiated) { collisionMap.snapshot() }')
 assert 'observeWorkspace' not in tail and 'accumulateCollisionDepth(view,capturedFrame:frame,preservingSceneID:sceneID)' in tail
 assert 'guard preservingSceneID.map({$0==currentMap.sceneID}) ?? true' in source
 assert 'guard preservingSceneID==nil else' in source
 assert 'min(ProcessInfo.processInfo.systemUptime + 12,deadlineUptime ?? .infinity)' in source
 with tempfile.TemporaryDirectory(prefix='rob-arm-side-depth-coverage-') as folder:
  p=Path(folder);swift=p/'Fixture.swift';binary=p/'fixture';swift.write_text(FIXTURE.replace('__ACTUAL_COVERAGE__',tail))
  subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True,timeout=45)
  subprocess.run([str(binary)],check=True,timeout=15)
if __name__=='__main__':main()
