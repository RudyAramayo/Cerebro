#!/usr/bin/env python3
"""Exercise actual grasp-view centering and fresh same-can reacquisition; no devices."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
vision = (ROOT / 'Cerebro/ROBArmRoutineVision.swift').read_text()
plan = (ROOT / 'Cerebro/ROBWorkspaceSearchPlan.swift').read_text()
trial = (ROOT / 'Cerebro/ROBLeftArmTrial.swift').read_text()
handoff_start = trial.index('            if let map = ROBWorkspaceSearch.shared.collisionSnapshot {', trial.index('            let searchBaseline = q'))
handoff = braced_declaration(trial[handoff_start:], '            if let map = ROBWorkspaceSearch.shared.collisionSnapshot {')
helper = braced_declaration(vision, '    static func graspFocusView(')
start = vision.index('            if armAlreadyAtGraspReady,let selected=localReachSelection?.object,')
brace = vision.index('}) {\n                try await searchCheckpoint', start) + 3
end, depth = brace + 1, 1
while depth:
    depth += (vision[end] == '{') - (vision[end] == '}')
    end += 1
integration = vision[start:end]
sighting = braced_declaration(plan, '    struct Sighting: Codable {')
fixture = r'''
import Foundation
import simd
enum ROBWorkspaceTarget:String,Codable {case can,orangeBucket}
struct ROBWorkspaceView:Codable,Equatable {let panDegrees:Double;let upperTarget:Int}
enum ROBWorkspaceRecall {__SIGHTING__}
enum ROBWorkspaceCanRecenterPlan {__HELPER__}
struct ROBWorkspaceLocatedObject {
 let position:[Double],capturedAt:Double,sequence:UInt64,view:ROBWorkspaceView
 var point:SIMD3<Double> {SIMD3(position[0],position[1],position[2])}
}
struct Selection {let object:ROBWorkspaceLocatedObject?;var diagnostics:[[String:Any]]=[]}
struct Map {let registrationID:String?=nil;let registrationDetail="unmeasured"}
struct Model {func positions(vendorLeft:[Double])->[String:Double] {[:]}}
@MainActor final class ROBWorkspaceSearch {
 static let shared=ROBWorkspaceSearch()
 var collisionSnapshot:Map?=Map(),calls=0,replacement:ROBWorkspaceLocatedObject?
 func nearestReachableCan(model:Model,baseline:[String:Double],map:Map,calibrationFile:URL?)async->Selection {
  calls+=1;return Selection(object:replacement)
 }
}
@MainActor func handoffToPickup(_ selected:ROBWorkspaceLocatedObject?,local:Bool=true)async->ROBWorkspaceLocatedObject? {
 var objects:[ROBWorkspaceTarget:ROBWorkspaceLocatedObject]=[:]
 objects[.can]=selected
 let model=Model(),q:[Double]=[],calibrationFile:URL?=nil
 let localReceiptCommand:String?=local ? "right_recycle_cans":nil
 var collisionMap:Map?,collisionModel:Model?,collisionReviewStatus:NSDictionary=[:]
 func publishCollisionReview(map:Map,detail:String,blocked:Bool) {}
 __HANDOFF__
 _=collisionMap;_=collisionModel
 return objects[.can]
}
struct Candidates {
 var values:[ROBWorkspaceLocatedObject]=[]
 func confirmed(nowMilliseconds:Double)->[ROBWorkspaceLocatedObject] {values}
}
struct Confirmation {mutating func invalidate(_ target:ROBWorkspaceTarget) {}}
enum ROBArmRoutineError:Error {case blocked(String)}
enum Failure:Error {case changed}
@MainActor func exercise(_ mode:String,raised:Bool=true)async throws->([ROBWorkspaceView],Selection?,[[String:Any]]) {
 let now=Date().timeIntervalSince1970*1000
 let original=ROBWorkspaceLocatedObject(position:[0.60,-0.15,0.836],capturedAt:now-100,sequence:10,
    view:.init(panDegrees:-15,upperTarget:6000))
 let source=ROBWorkspaceRecall.Sighting(target:.can,view:original.view,box:[0.258,0.051,0.346,0.274],confidence:0.9,capturedAt:original.capturedAt)
 let armAlreadyAtGraspReady=raised
 var localReachSelection:Selection?=Selection(object:original)
 let canSourceSightings:[UInt64:[(object:ROBWorkspaceLocatedObject,sighting:ROBWorkspaceRecall.Sighting)]]=[10:[(original,source)]]
 let boundedPan:((Double)->Double)?={max(-45,min(45,$0))}
 var found:[ROBWorkspaceTarget:ROBWorkspaceLocatedObject]=[.can:original]
 var locationConfirmation=Confirmation(),selectedCanMeasurement:ROBWorkspaceLocatedObject?=original
 var confirmedCanCandidates=Candidates(),moves:[ROBWorkspaceView]=[],evidence:[[String:Any]]=[]
 var moved=false
 func searchCheckpoint()async throws {if mode=="cancelled" {throw Failure.changed}}
 func requireTargetedContext()throws {if moved && mode=="body_changed" {throw Failure.changed}}
 func progress(_ text:String) {}
 func inspectWithRetry(_ view:ROBWorkspaceView)async throws {
  moves.append(view);moved=true
  let fresh=ROBWorkspaceLocatedObject(position:mode=="different_can" ? [0.72,-0.15,0.836]:original.position,
   capturedAt:mode=="old_time" ? original.capturedAt:Date().timeIntervalSince1970*1000,
   sequence:mode=="old_sequence" ? 10:11,view:mode=="old_view" ? original.view:view)
  confirmedCanCandidates.values=mode=="unconfirmed" ? []:[fresh]
 }
 func rankCurrentCans(_ stage:String,candidates:[ROBWorkspaceLocatedObject]?=nil)async throws->Selection {
  precondition(stage=="centered_grasp_view")
  return Selection(object:mode=="unreachable" ? nil:candidates?.first)
 }
 __INTEGRATION__
 precondition(source.capturedAt==original.capturedAt,"Old evidence was retimestamped")
 _=selectedCanMeasurement
 return (moves,localReachSelection,evidence)
}
@main enum Test {
 @MainActor static func main()async throws {
  let result=try await exercise("fresh")
  precondition(result.0.count==1 && abs(result.0[0].panDegrees+1.338)<0.01 && result.0[0].upperTarget>6400)
  precondition(result.1?.object?.sequence==11 && result.1?.object?.view==result.0[0])
  precondition(result.2.count==1 && result.2[0]["path_admitted"] as? Bool==false)
  let search=ROBWorkspaceSearch.shared
  // A nearer older can remains in the scan after the selected can's dedicated
  // centered remeasurement. The production pickup handoff must not switch.
  search.replacement=ROBWorkspaceLocatedObject(position:[0.55,0.03,0.84],capturedAt:1000,sequence:8,
    view:.init(panDegrees:0,upperTarget:6306))
  let retained=await handoffToPickup(result.1!.object)
  precondition(retained?.sequence==11 && retained?.view==result.0[0] && search.calls==0,
    "Pickup replaced the freshly centered can with another scan candidate")
  let fallback=await handoffToPickup(nil)
  precondition(fallback?.sequence==8 && search.calls==1,"Missing target lost ordinary reach selection")
  search.replacement=nil
  let missing=await handoffToPickup(nil)
  precondition(missing==nil && search.calls==2,"Unavailable target was invented")
  let nonlocal=await handoffToPickup(nil,local:false)
  precondition(nonlocal==nil && search.calls==2,"Nonlocal task acquired local fallback behavior")
  let hanging=try await exercise("fresh",raised:false)
  precondition(hanging.0.isEmpty && hanging.1?.object?.sequence==10)
  for mode in ["different_can","old_time","old_sequence","old_view","unconfirmed","unreachable"] {
   do {_=try await exercise(mode);preconditionFailure("Invalid reacquisition accepted: "+mode)}
   catch ROBArmRoutineError.blocked {}
  }
  for mode in ["cancelled","body_changed"] {
   do {_=try await exercise(mode);preconditionFailure("Changed context accepted")}
   catch Failure.changed {}
  }
  let view=ROBWorkspaceView(panDegrees:0,upperTarget:6400)
  let centered=ROBWorkspaceRecall.Sighting(target:.can,view:view,box:[0.4,0.35,0.6,0.65],confidence:0.9,capturedAt:1000)
  precondition(ROBWorkspaceCanRecenterPlan.graspFocusView(sighting:centered,nowMilliseconds:1100,boundedPan:{$0})==nil)
  let edge=ROBWorkspaceRecall.Sighting(target:.can,view:view,box:[0.2,0.05,0.3,0.25],confidence:0.9,capturedAt:1000)
  precondition(ROBWorkspaceCanRecenterPlan.graspFocusView(sighting:edge,nowMilliseconds:31001,boundedPan:{$0})==nil)
  print("PASS actual grasp focus: clipped finger workspace centered, fresh same-can/source remeasurement required; old view/time/sequence, changed can/body, missing confirmation/reach and cancellation rejected. No hardware or authority.")
 }
}
'''.replace('__HELPER__', helper).replace('__SIGHTING__', sighting).replace('__INTEGRATION__', integration).replace('__HANDOFF__',handoff)
with tempfile.TemporaryDirectory(prefix='rob-grasp-focus-') as folder:
    path = Path(folder)
    source, binary = path / 'Fixture.swift', path / 'fixture'
    source.write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-module-cache-path', '/private/tmp/cerebro-swift-module-cache',
                    str(source), '-o', str(binary)], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=15)
