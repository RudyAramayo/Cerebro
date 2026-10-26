#!/usr/bin/env python3
"""Actual strict hold predicate/checkpoint/dispatch and camera-enrollment seams."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1];source=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
guard=braced_declaration(source,'private enum ROBHeldArmFeedbackGuard {').replace('private enum','enum',1)
pause=braced_declaration(source,'private struct ROBPassiveFeedbackPause:').replace('private struct','struct',1)
check=braced_declaration(source,'    private func check() throws {')
fullCheck=check.replace('private func','func',1)
methods='\n'.join(braced_declaration(source,m).replace('private func','func',1)for m in ['    @MainActor private func passiveFeedbackCheckpoint()','    @MainActor private func wait(_ seconds:','    @MainActor private func accepted('])
enroll=braced_declaration(source,'    @nonobjc func performUsingLocalRecyclingReceipt(').replace('@nonobjc func','func',1)
batch=braced_declaration((root/'Cerebro/ROBWorkspaceSearchPlan.swift').read_text(),'enum ROBRecyclingBatchRequest {')
search=(root/'Cerebro/ROBArmRoutineVision.swift').read_text().split('    @MainActor @nonobjc func run(targets:',1)[1]
assert 'try check() // Strict admission' in search and 'passiveExpiredProjectionRetries<2' in search
assert 'capture_time_refreshed":false' in search
monitor=braced_declaration(source,'    private func monitor() {')
assert 'catch is ROBPassiveFeedbackPause { return }' in monitor
fixture=r'''
import Foundation
enum ROBArmRoutineError:Error {case blocked(String)}
enum ROBGhostMotionError:Error {case blocked(String)}
/* GUARD */
/* PAUSE */
/* BATCH */
final class Sample {
 var positionsRadians=Array(repeating:NSNumber(value:0),count:7),statuses=Array(repeating:NSNumber(value:0),count:7)
 var effectiveSampleAgeMilliseconds=10.0,effectiveGripperFeedbackAgeMilliseconds=10.0
 let receivedAtUptime=ProcessInfo.processInfo.systemUptime,sequence:UInt64=1
}
final class Gateway {
 var samples:[String:Sample]=["left":Sample(),"right":Sample()],mode=["left":0,"right":0]
 func telemetry(forArm:String)->Sample?{samples[forArm]}
 func modes(forArm:String)->[NSNumber]{Array(repeating:NSNumber(value:mode[forArm]!),count:7)}
 func isReady()->Bool{true}
 func connectionSnapshot()->NSDictionary{["sessionGeneration":NSNumber(value:1)]}
}
@MainActor final class Hold {
 let gateway=Gateway(),arm="left";var localReceiptCommand:String?="right_recycle_cans"
 var inactiveWorkspaceSearch=true,leased=false,positionReady=false,armTravelDispatched=false,jawCommandDispatched=false,jawSetupDispatchUncertain=false,recyclingGripDispatched=false
 var sceneHold:[String:(positions:[Double],modes:[Int])]=["left":(Array(repeating:0,count:7),Array(repeating:0,count:7)),"right":(Array(repeating:0,count:7),Array(repeating:0,count:7))]
 var passiveFeedbackPauseStarted:Double?,lastHeldFeedbackDiagnostic:String?,lastRecordingPath="",phase="passive search"
 var waiting=Set<UInt64>(),acks:[UInt64:Bool]=[:],holdConfirmations:[UInt64:Bool]=[:],dispatches=0
 static let neckOnlyCommands=Set<String>()
 var activeApproachUnknownAdvisory=false,approachUnknownAdvisoryEnabled=false
 var activeApproachCanThenHold=false,approachCanThenHoldEnabled=false
 var failure:String?,activeHoldAfterInitialEmptyLift=false,holdAfterInitialEmptyLiftEnabled=false,sourcePixelSelfReviewEnabled=false
 struct PixelView {let physicalLeftBaseline=Array(repeating:0.0,count:7)}
 var sourcePixelCurrentView:PixelView?,physicalSide="right",summary="test",activeCommand="left_recycle_can"
 var deadline=ProcessInfo.processInfo.systemUptime+100,generation:UInt64=1,cameraReady=false,interactionStage=""
 var leaseRenewals:[UInt64:Bool]=[:],taskJawTarget:[Double]?
 let vision=Vision()
 func captureActualCampaignInterruption(){}
 func requireLocalReceipt()throws->Bool{true}
 func measured()throws->Sample{gateway.samples[arm]!}
 func checkCollisionContext()throws{}
 /* FULL CHECK */
 /* METHODS */
}
@MainActor final class Vision {
 var enrolled=false,available=false,sequence:UInt64=1,ensureCalls=0
 var fresh:Bool{enrolled && available}
 var handsClear:Bool{true}
 struct Depth {let width=640,height=480}
 struct Frame {let sequence:UInt64;var depth:Depth?=Depth()}
 func snapshot()->[String:Frame]{available ? ["face":.init(sequence:sequence)]:[:]}
 func ensureActiveForTaskObservation(){ensureCalls+=1;enrolled=true}
}
final class ROBControllerArmApproval {
 static let shared=ROBControllerArmApproval();var standingLocalCanCampaignActive=false,isPending=false
 var standingLocalCanCampaignState:NSDictionary?=nil
 var onAuthorize:(()->Void)?
 func authorizesLeftArmTrial(_ summary:String)->Bool{onAuthorize?();return true}
 func authorizesRightArmTrial(_ summary:String)->Bool{onAuthorize?();return true}
}
final class ROBArmRoutineCoordinator {static let shared=ROBArmRoutineCoordinator();var cameraDemand:((Bool)->Void)?;var viewIsStationary:(()->Bool)?={true}}
enum ROBWorkspaceCollisionPlan {static let sweptPointTravelMeters=0.003}
enum ROBLeftArmInteractionPlan {static func stationaryFrontTarget(_ q:[Double])->[Double]?{q}}
enum ROBArmRoutinePlan {static func near(_ a:[Double],_ b:[Double])->Bool{true}}
@MainActor final class CameraPrepare {
 let vision=Vision();var sourcePixelSelfReviewEnabled=false,nominalEmptyCommissioningStepEnabled=false,nominalModelAssumedSelfEnabled=false,oneDegreeEmptyCalibrationStepEnabled=false,isRunning=false
 var standingPreparationTask:Task<Void,Never>?,localCameraPreparationTask:Task<Void,Never>?,localReceiptCameraTimer:Timer?
 var prepared=0
 func prepareSourcePixelSelfReview(command:String,target:String,completion:@escaping(NSDictionary)->Void){preconditionFailure("Unexpected pixel path")}
 func update(_ text:String){}
 func performImpl(_ command:String,target:String,localReceiptOnly:Bool,completion:@escaping(NSDictionary)->Void){precondition(vision.fresh);prepared+=1;completion(["status":"prepared"])}
 /* ENROLL */
}
@main enum Test {
 @MainActor static func fatal(_ h:Hold,_ expected:String){do{try h.check();preconditionFailure("Unsafe hold admitted")}catch is ROBPassiveFeedbackPause {preconditionFailure("Unsafe mode/q/missing state incorrectly deferred")}catch{precondition(String(describing:error).contains(expected))}}
 @MainActor static func main()async throws {
  let changedPolicy=Hold();changedPolicy.approachUnknownAdvisoryEnabled=true;fatal(changedPolicy,"frozen UNKNOWN advisory")
  let h=Hold();h.gateway.samples["right"]!.effectiveGripperFeedbackAgeMilliseconds=300
  do{try h.check();preconditionFailure("Strict check soft-passed stale feedback")}catch is ROBPassiveFeedbackPause{}
  precondition(h.lastHeldFeedbackDiagnostic?.contains("gripper_age_ms")==true)
  let recover=Task{@MainActor in try await Task.sleep(nanoseconds:50_000_000);precondition(h.dispatches==0);h.gateway.samples["right"]!.effectiveGripperFeedbackAgeMilliseconds=10}
  try await h.accepted{h.dispatches+=1;h.acks[42]=true;return 42};try await recover.value
  precondition(h.dispatches==1 && h.passiveFeedbackPauseStarted==nil)
  let timeout=Hold();timeout.gateway.samples["right"]!.effectiveSampleAgeMilliseconds=300;timeout.passiveFeedbackPauseStarted=ProcessInfo.processInfo.systemUptime-2.01;fatal(timeout,"within2seconds")
  let changed=Hold();changed.gateway.samples["left"]!.effectiveSampleAgeMilliseconds=300;changed.gateway.mode["right"]=1;fatal(changed,"gateway_modes")
  let drift=Hold();drift.gateway.samples["right"]!.positionsRadians[0]=0.01;fatal(drift,"position_drift_m")
  let missing=Hold();missing.gateway.samples.removeValue(forKey:"right");fatal(missing,"telemetry_missing")
  let active=Hold();active.leased=true;active.gateway.samples["right"]!.effectiveSampleAgeMilliseconds=300;fatal(active,"motor_age_ms")
  do{try await active.accepted{active.dispatches+=1;return 1};preconditionFailure("Active stale state dispatched")}catch{}
  precondition(active.dispatches==0)
  // Exercise the COMPLETE actual check, including authorization/session and old scan tail.
  let agedDuringAuthorization=Hold()
  ROBControllerArmApproval.shared.onAuthorize={agedDuringAuthorization.gateway.samples["left"]!.effectiveSampleAgeMilliseconds=300}
  try agedDuringAuthorization.check() // No duplicate age read after authority work in local passive mode.
  ROBControllerArmApproval.shared.onAuthorize=nil
  do{try agedDuringAuthorization.check();preconditionFailure("Next checkpoint must detect stale feedback")}catch is ROBPassiveFeedbackPause{}
  let nonlocal=Hold();nonlocal.localReceiptCommand=nil
  ROBControllerArmApproval.shared.onAuthorize={nonlocal.gateway.samples["left"]!.effectiveSampleAgeMilliseconds=300}
  do{try nonlocal.check();preconditionFailure("Nonlocal scan lost legacy strict guard")}catch{precondition(String(describing:error).contains("stationary neck scan"))}
  ROBControllerArmApproval.shared.onAuthorize=nil
  let activeScan=Hold();activeScan.sceneHold=activeScan.sceneHold.mapValues{($0.positions,Array(repeating:2,count:7))}
  for side in ["left","right"]{activeScan.gateway.mode[side]=2;activeScan.gateway.samples[side]!.statuses=Array(repeating:2,count:7)}
  ROBControllerArmApproval.shared.onAuthorize={activeScan.gateway.samples["left"]!.effectiveSampleAgeMilliseconds=300}
  do{try activeScan.check();preconditionFailure("Active-mode scan lost legacy strict guard")}catch{precondition(String(describing:error).contains("stationary neck scan"))}
  ROBControllerArmApproval.shared.onAuthorize=nil
  let camera=CameraPrepare();var completed=false
  camera.performUsingLocalRecyclingReceipt("right_recycle_cans",target:"4"){r in completed=r["status"]as?String=="prepared"}
  precondition(camera.vision.enrolled && camera.prepared==0)
  try await Task.sleep(nanoseconds:50_000_000);camera.vision.available=true;camera.vision.sequence=2
  for _ in 0..<20 {if completed{break};try await Task.sleep(nanoseconds:20_000_000)}
  precondition(completed && camera.prepared==1 && camera.vision.ensureCalls==1)
  print("PASS COMPLETE actual check incl authorization-aged local/nonlocal/active scan tails; strict passive guard: age-only same-q/mode defers≤2s without softpass; activation/dispatch waits fresh; q/mode/missing/active/timeout fatal; direct local Prepare enrolls then waits fresh; source projection expiry capped2 and no timestamp rewrite; no hardware")
 }
}
'''.replace('/* GUARD */',guard).replace('/* PAUSE */',pause).replace('/* BATCH */',batch).replace('/* FULL CHECK */',fullCheck).replace('/* METHODS */',methods).replace('/* ENROLL */',enroll)
with tempfile.TemporaryDirectory(prefix='rob-passive-feedback-',dir='/private/tmp')as folder:
 p=Path(folder);(p/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True,timeout=10)
