#!/usr/bin/env python3
"""Run the production ready-stage orchestration with inert robot/map seams."""
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1]
source=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
method=braced_declaration(source,'    @MainActor private func prepareRecyclingBeforeTargetSearch(').replace('private func','func',1)
execute=braced_declaration(source,'    @MainActor private func executeSingle(')
branch=execute[execute.index('        if command == "left_recycle_can" {'):]
assert branch.index('prepareRecyclingBeforeTargetSearch') < branch.index('ROBWorkspaceSearch.shared.run(targets:')
assert 'ROBWorkspaceSearch.shared.run' not in method and 'ROBCanGrabPreview' not in method
fixture=r'''
import Foundation
enum ROBArmRoutineError:Error {case blocked(String)}
enum ROBArmRoutinePlan {static func near(_ a:[Double],_ b:[Double],tolerance:Double=0.08)->Bool {a.count==7 && b.count==7 && zip(a,b).allSatisfy{abs($0-$1)<=tolerance}}}
struct ROBGhostRobotModel {}
struct Map {}
struct Step {let positions:[Double];var jawAction:String?=nil}
struct Proposal {let baseline:[Double];let steps:[Step]}
struct Sample {let positionsRadians:[NSNumber]}
@MainActor final class Trial {
 var localReceiptCommand:String?="right_recycle_cans",physicalSide="right",recyclingReadyEstablished=false
 var activeCommand="left_recycle_can",armTravelDispatched=false,jawCommandDispatched=false,jawSetupDispatchUncertain=false,recyclingGripDispatched=false,servoPossiblePayloadUncertain=false
 var recyclingCan:Int?,generation:UInt64=1,referencedGeneration:UInt64=0
 var phase="",collisionMap:Map?,collisionModel:ROBGhostRobotModel?,collisionReviewProposal:Proposal?,proposal:Proposal?,proposalStep = -1
 var activeApproachCanThenHold=false,activeHoldAfterInitialEmptyLift=false,inactiveWorkspaceSearch=false,taskJawTarget:[Double]?,cameraReady=false,positionReady=false,sceneCapturedForThisTask=false,localReceiptHeldNeckIdentity:String?
 var q=Array(repeating:0.0,count:7),events:[String]=[],failureAt="",retreat=false,stopAfterMove=false
 func check()throws{if failureAt=="stop"{throw ROBArmRoutineError.blocked("Stop")}}
 func requireLocalReceipt()throws->Bool{if failureAt=="receipt"{throw ROBArmRoutineError.blocked("receipt")};return true}
 func measured()throws->Sample{if failureAt=="feedback"{throw ROBArmRoutineError.blocked("feedback")};return .init(positionsRadians:q.map{NSNumber(value:$0)})}
 func update(_ text:String){}
 func beginHeldSceneObservation()async throws{events.append("held observation");inactiveWorkspaceSearch=true}
 func ensureCollisionScene(model:ROBGhostRobotModel)async throws{events.append("workspace");if failureAt=="map"{throw ROBArmRoutineError.blocked("source/table map")};collisionMap=Map()}
 func performInitialLocalRetreatIfNeeded(map:Map,model:ROBGhostRobotModel)async throws->Bool{events.append("review retreat");if failureAt=="retreat"{throw ROBArmRoutineError.blocked("occupied retreat")};if retreat{q[1] -= 0.075;q[3] -= 0.06;armTravelDispatched=true;referencedGeneration=generation;collisionMap=nil;if stopAfterMove{failureAt="stop"}};if failureAt=="endpoint"{q[0]+=0.1};if failureAt=="possession"{servoPossiblePayloadUncertain=true};return retreat}
 func performStagedEmptyLiftIfNeeded(map:Map,model:ROBGhostRobotModel)async throws->Bool{events.append("staged path");return try await performInitialLocalRetreatIfNeeded(map:map,model:model)}
 func initialEmptyLiftHoldResult(performed:Bool)throws->NSDictionary{events.append("lift only hold");return ["performed":performed]}
 func workspaceConnector(to goal:[Double],name:String)async throws->Proposal{events.append("plan ready");if failureAt=="connector"{throw ROBArmRoutineError.blocked("table collision")};return .init(baseline:q,steps:[.init(positions:goal,jawAction:failureAt=="jaw in path" ? "close":nil)])}
 func bindApproachHumanPath(baseline:[Double],route:[[Double]],map:Map,model:ROBGhostRobotModel)async throws{events.append("bind corridor");if failureAt=="corridor"{throw ROBArmRoutineError.blocked("route obstruction")}}
 func prepareCameraAndMode(stationaryJaw:Bool)async throws{events.append("mode");if failureAt=="mode"{throw ROBArmRoutineError.blocked("feedback/mode")};cameraReady=true;positionReady=true}
 func move(_ p:Proposal)async throws{events.append("move");if failureAt=="dispatch"{throw ROBArmRoutineError.blocked("fresh proof expired")};q=p.steps.last!.positions;armTravelDispatched=true;if stopAfterMove{failureAt="stop"}}
 func holdTaskPosition(_ goal:[Double])async throws{events.append("hold");if failureAt=="endpoint"{q[0]+=0.1};if failureAt=="possession"{servoPossiblePayloadUncertain=true}}
 /* ACTUAL */
 func task()async throws {if try await prepareRecyclingBeforeTargetSearch(model:.init())==nil{events.append("target search")}}
}
@main enum Test {
 @MainActor static func main()async throws {
  let normal=Trial();try await normal.task()
  precondition(normal.events==["held observation","workspace","staged path","review retreat","target search"])
  precondition(normal.recyclingReadyEstablished && normal.collisionMap==nil && !normal.cameraReady && !normal.positionReady && normal.proposal==nil)
  try await normal.task();precondition(!normal.events.contains("move") && !normal.events.contains("plan ready"),"A historical ready endpoint was inserted")
  let outward=Trial();outward.retreat=true;try await outward.task()
  precondition(outward.events.filter{$0=="workspace"}.count==1 && outward.events.last=="target search" && outward.collisionMap==nil && outward.q[3] != 0,"Lift endpoint was replaced or old map survived")
  for failure in ["receipt","feedback","stop","map","retreat","endpoint","possession"] {
   let t=Trial();t.failureAt=failure
   do {try await t.task();preconditionFailure("Rejected preparation continued: \(failure)")}catch{}
   precondition(!t.events.contains("target search") && !t.recyclingReadyEstablished)
   if ["receipt","feedback","stop","map","retreat","connector","jaw in path","mode"].contains(failure){precondition(!t.armTravelDispatched)}
   precondition(t.proposal==nil && !t.jawCommandDispatched)
  }
  let stopped=Trial();stopped.retreat=true;stopped.stopAfterMove=true
  do {try await stopped.task();preconditionFailure()}catch{}
  precondition(!stopped.events.contains("target search") && !stopped.recyclingReadyEstablished)
  for payload in [0,1,2,3] {
   let t=Trial();if payload==0{t.armTravelDispatched=true};if payload==1{t.jawCommandDispatched=true};if payload==2{t.servoPossiblePayloadUncertain=true};if payload==3{t.q[0]=0.3}
   do {try await t.task();preconditionFailure()}catch{}
   precondition(t.events.isEmpty)
  }
  for retreat in [false,true] {let t=Trial();t.activeHoldAfterInitialEmptyLift=true;t.retreat=retreat;try await t.task();precondition(t.events.last=="lift only hold" && !t.events.contains("plan ready") && !t.events.contains("target search"))}
  let approach=Trial();approach.activeApproachCanThenHold=true;try await approach.task();precondition(approach.events==["target search"])
  let left=Trial();left.physicalSide="left";try await left.task();precondition(left.events==["target search"])
  let ordinary=Trial();ordinary.localReceiptCommand=nil;try await ordinary.task();precondition(ordinary.events==["target search"])
  let held=Trial();held.q[0]=0.3;held.referencedGeneration=held.generation;try await held.task()
  precondition(held.q[0]==0.3 && !held.events.contains("plan ready") && !held.events.contains("move"),"Referenced current pose was sent to a preset")
  print("Current-pose preparation passed: no historical ready endpoint; complete staged lift selected before targets; checked J2/J4 endpoint preserved; new target map required; receipt/feedback/Stop/pose/payload checks retained; no hardware")
 }
}
'''.replace('/* ACTUAL */',method)
with tempfile.TemporaryDirectory(prefix='rob-ready-stage-') as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(p/'main.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True)
