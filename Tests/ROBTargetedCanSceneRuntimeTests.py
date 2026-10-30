#!/usr/bin/env python3
"""Run native target-context/ranking gates across a perception map rollover."""
from pathlib import Path
import subprocess
import tempfile
from ROBWorkspaceCanCandidatesRuntimeTests import STUBS, block
ROOT=Path(__file__).resolve().parents[1]
vision=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
plan=(ROOT/'Cerebro/ROBWorkspaceSearchPlan.swift').read_text()
actual='\n'.join(block(vision,m) for m in ['struct ROBWorkspaceCanSceneIdentity:', 'struct ROBWorkspaceCanCandidateSet {', 'struct ROBWorkspaceCanSelection {'])
actual+='\n'+'\n'.join(block(plan,m) for m in ['enum ROBWorkspaceTarget:', 'struct ROBWorkspaceLocatedObject:', 'struct ROBWorkspaceLocationConfirmation {'])
context=block(vision,'            func requireTargetedContext()')
rank=block(vision,'            func rankCurrentCans(')
select=block(vision,'    @MainActor private func selectReachableCan(').replace('@MainActor private func','@MainActor func')
fixture=r'''
extension ROBWorkspaceCollisionSnapshot {func snapshot()->Self? {self}}
enum ROBWorkspaceDepthMapError:Error {case invalidFrame,acquisition(String)}
struct Anchor {let camera:UUID;func permitsCurrent(_ value:UUID)->Bool {value==camera}}
@main struct Test {
 @MainActor static func main()async throws {
  let model=ROBGhostRobotModel(),vision=ROBArmRoutineVision.shared
  let camera=vision.cameraGeneration,body="body",sceneGatewayGeneration:UInt64=1
  let estimatedProjectionIdentity:String?="projection",sceneCaptureAnchor=Anchor(camera:camera)
  let reachBaseline:[String:Double]=[:],now=Date().timeIntervalSince1970*1000
  var collisionMap:ROBWorkspaceCollisionSnapshot? = .init(sceneID:UUID(),cameraGeneration:camera,observations:[])
  var confirmedCanCandidates=ROBWorkspaceCanCandidateSet(),reachSelections:[[String:Any]]=[]
  func check()throws {}
  func requireSceneProjectionIdentity()throws {}
  func permitsLocalCanShapePrior()throws->Bool {true}
  func searchCheckpoint()async throws {}
  __CONTEXT__
  __SELECT__
  __RANK__
  func observe(_ seq:UInt64) {
   let map=collisionMap!,time=now-1000+Double(seq)*10
   let object=ROBWorkspaceLocatedObject(target:.can,position:[0.45,-0.2,0.9],confidence:0.9,capturedAt:time,
    sequence:seq,view:.init(panDegrees:0,upperTarget:6400),sections:.init(valid:true,heightMeters:0.12,diameterMeters:0.065))
   collisionMap!.observations.append(.init(sequence:seq,capturedAtMilliseconds:time))
   confirmedCanCandidates.observe([object],context:.init(sceneID:map.sceneID,cameraGeneration:camera,
    sessionGeneration:1,bodyMotionIdentity:body,modelID:model.modelID,geometryID:model.geometryID,
    mappingID:model.selectedMappingID,estimatedCameraProjectionIdentity:estimatedProjectionIdentity),nowMilliseconds:now)
  }
  observe(1);observe(2)
  let first=try await rankCurrentCans("original")
  precondition(first.object?.sequence==2)
  collisionMap = .init(sceneID:UUID(),cameraGeneration:camera,observations:[])
  let stale=try await rankCurrentCans("rolled_without_new_observation")
  precondition(stale.object==nil,"Old-scene can cannot enter a new map")
  observe(3)
  let single=try await rankCurrentCans("one_new_exposure")
  precondition(single.object==nil,"Scene rollover resets two-image confirmation")
  observe(4)
  let fresh=try await rankCurrentCans("fresh_scene")
  precondition(fresh.object?.sequence==4)
  let valid=collisionMap!
  for change in 0..<8 {
   collisionMap=valid
   switch change {
    case 0:collisionMap!.cameraGeneration=UUID()
    case 1:collisionMap!.sessionGeneration=2
    case 2:collisionMap!.bodyMotionIdentity="changed"
    case 3:collisionMap!.modelID="changed"
    case 4:collisionMap!.geometryID="changed"
    case 5:collisionMap!.mappingID="changed"
    case 6:collisionMap!.estimatedCameraProjectionIdentity="changed"
    default:vision.cameraGeneration=UUID()
   }
   do {_=try await rankCurrentCans("changed_context");preconditionFailure("Changed source accepted")}
   catch ROBWorkspaceDepthMapError.acquisition {}
   vision.cameraGeneration=camera
  }
  collisionMap=valid
  ROBCanGrabPreview.hook={collisionMap!.sceneID=UUID()}
  do {_=try await rankCurrentCans("scene_changed_during_rank");preconditionFailure("Ranking did not freeze scene")}
  catch ROBWorkspaceDepthMapError.acquisition {}
  ROBCanGrabPreview.hook=nil
  print("PASS native targeted search: fresh perception map accepted only with new two-exposure candidates; stale scene candidates, changed robot/source context and scene changes during ranking rejected. No hardware.")
 }
}
'''.replace('__CONTEXT__',context).replace('__SELECT__',select).replace('__RANK__',rank)
with tempfile.TemporaryDirectory(prefix='rob-targeted-scene-') as folder:
 p=Path(folder);src=p/'Fixture.swift';binary=p/'fixture';src.write_text(STUBS+'\n'+actual+'\n'+fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(src),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],check=True,timeout=20)
