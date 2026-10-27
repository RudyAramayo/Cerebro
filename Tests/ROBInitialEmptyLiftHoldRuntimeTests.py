#!/usr/bin/env python3
"""Run actual lift-only stop/result branches with inert proof and robot seams."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Cerebro/ROBLeftArmTrial.swift').read_text()
execute=braced_declaration(source,'    @MainActor private func execute(_ command: String)')
result=braced_declaration(source,'    @MainActor private func initialEmptyLiftHoldResult(performed:Bool)')
single=braced_declaration(source,'    @MainActor private func executeSingle(_ command: String)')
preparation=next(line.strip() for line in single.splitlines() if 'prepareRightRecyclingSceneHolds(' in line)
start=single.index('                if try await performInitialLocalRetreatIfNeeded(map:map,model:model)')
branch=single[start:single.index('                guard referencedGeneration',start)]
context=braced_declaration(source,'    private func currentLocalRecyclingContextIdentity()')
retreat=braced_declaration(source,'    @MainActor private func performInitialLocalRetreatIfNeeded(')
assert 'holdAfterInitialEmptyLiftEnabled = false' in source
assert 'activeHoldAfterInitialEmptyLift = localReceiptCommand != nil && holdAfterInitialEmptyLiftEnabled' in source
assert 'if holdAfterInitialEmptyLiftEnabled {value["holdAfterInitialEmptyLiftEnabled"]=true}' in context
assert '#if !DEBUG' in source and 'Initial empty lift-and-hold is available only in DEBUG' in source
assert 'No jaw commands or startup jaw calibration, grasp, payload, carry, release, return, rescan after lifting, next can or chained motion' in source
assert 'if !activeHoldAfterInitialEmptyLift,!ROBGripperStartupCalibration.shared.calibrationReady' in single
assert branch.index('initialEmptyLiftHoldResult(performed:true)')<branch.index('return try await executeSingle(command)')
assert 'initialEmptyLiftHoldResult(performed:false)' in branch
for guard in ['reviewInitialRetreatWithCoverage','reviewInitialLocalRetreat','requireLiveVisualTrial','checkCollisionContext','proof.maximumHullTravelMeters+admissionDrift<=0.060','!jawCommandDispatched','!jawSetupDispatchUncertain']:
    assert guard in retreat,guard
assert 'zip(initialProof.baseline,initialProof.goal)' in retreat
assert retreat.index('try await holdTaskPosition(dispatchGoal)')<retreat.index('actualMeasuredEndpoint')
assert '"proofFile"' in retreat and 'initial-empty-lift-held.json' in retreat and '.posixPermissions:0o600' in retreat
assert '&& !activeHoldAfterInitialEmptyLift' in source
ui=(ROOT/'Cerebro/ROBTestingSandboxWindowController.swift').read_text()
assert '#if DEBUG\n            if trial.id == "right-recycling"' in ui
assert 'Hold after initial empty lift' in ui and 'sandbox-hold-after-initial-empty-lift' in ui

fixture=r'''
import Foundation
enum ROBArmRoutineError:Error {case blocked(String)}
enum ROBRecyclingBatchRequest {static func executionCount(requestedCount:Int,standingRemainingTransfers:Int?)->Int? {requestedCount}}
struct Feedback {let positionsRadians=[NSNumber](repeating:0,count:7)}
@MainActor final class Harness {
 var activeHoldAfterInitialEmptyLift=false,holdAfterInitialEmptyLiftEnabled=false,activeApproachCanThenHold=false
 var localReceiptCommand:String?="right_recycle_cans",physicalSide="right"
 var jawCommandDispatched=false,jawSetupDispatchUncertain=false,recyclingGripDispatched=false,stopped=false
 var initialEmptyLiftHeldEvidence:NSDictionary?=["fixture_endpoint":true]
 var requestedCanCount=5,localReceiptEvidence:NSDictionary?=nil
 var oneDegreeEmptyCalibrationStepEnabled=false,nominalEmptyCommissioningStepEnabled=false
 var singleCalls=0,proofCalls=0,calibrationCalls=0,liftNeeded=true,proofRejects=false
 var holdPreparationCalls=0,deferredJawSetupCalls=0
 var localReceiptHeldNeckIdentity:String?,recyclingCan:Int?,lastVisualGraspEvidence:Int?,collisionMap:Int?,collisionModel:Int?,collisionReviewProposal:Int?
 var movingTargetReplansRemaining=1,sceneCapturedForThisTask=false
 func check()throws {if stopped {throw ROBArmRoutineError.blocked("Stop")}}
 func measured()throws->Feedback {try check();return .init()}
 func update(_ value:String){}
 func prepareRightRecyclingSceneHolds(allowDeferredJawSetup:Bool=true)async throws {
  holdPreparationCalls+=1;if allowDeferredJawSetup {deferredJawSetupCalls+=1}
 }
 func prepareEntry()async throws {__ACTUAL_PREPARATION__}
 func executeOneDegreeEmptyCalibration()async throws->NSDictionary {calibrationCalls+=1;return [:]}
 func executeNominalEmptyCommissioning()async throws->NSDictionary {calibrationCalls+=1;return [:]}
 func executeSingle(_ command:String)async throws->NSDictionary {
  singleCalls+=1
  if activeHoldAfterInitialEmptyLift {return try initialEmptyLiftHoldResult(performed:liftNeeded)}
  return ["status":"normal","motion_completed":true,"grasp_visually_supported":true]
 }
 func performInitialLocalRetreatIfNeeded(map:Int,model:Int)async throws->Bool {
  proofCalls+=1;try check();if proofRejects {throw ROBArmRoutineError.blocked("Original full proof rejected")};return liftNeeded
 }
 func entry(_ command:String)async throws->NSDictionary {
  let map=1,model=1
  __ACTUAL_BRANCH__
  return ["status":"normal_next_stage"]
 }
 __ACTUAL_RESULT__
 __ACTUAL_EXECUTE__
 func run()async throws->NSDictionary {try await execute("left_recycle_can")}
}
@main enum Test {
 @MainActor static func main()async throws {
  let normal=Harness();let result=try await normal.run()
  precondition(normal.singleCalls==5 && result["batch_completed"]as!Int==5,"OFFchanged ordinary batch behavior")
  for needed in [true,false] {
   let h=Harness();h.activeHoldAfterInitialEmptyLift=true;h.holdAfterInitialEmptyLiftEnabled=true;h.liftNeeded=needed
   try await h.prepareEntry()
   precondition(h.holdPreparationCalls==1 && h.deferredJawSetupCalls==0,"Lift-only preparation attempted startup jaw motion")
   let e=try await h.entry("left_recycle_can")
   precondition(h.proofCalls==1 && h.singleCalls==0,"Lift-only entry chained a rescan or can task")
   precondition(e["initial_empty_lift_performed"]as!Bool==needed && e["batch_completed"]as!Int==0)
   let b=try await h.run()
   precondition(h.singleCalls==1 && h.calibrationCalls==0 && b["motion_completed"]as!Bool==false && b["batch_completed"]as!Int==0)
   precondition(b["transfer_completed"]as!Bool==false && b["grasp_visually_supported"]as!Bool==false)
  }
  let ordinary=Harness();_=try await ordinary.entry("left_recycle_can")
  try await ordinary.prepareEntry();precondition(ordinary.deferredJawSetupCalls==1,"Ordinary recycling lost deferred jaw setup")
  let left=Harness();left.physicalSide="left";try await left.prepareEntry();precondition(left.holdPreparationCalls==0)
  precondition(ordinary.proofCalls==1 && ordinary.singleCalls==1,"OFFremoved ordinary fresh-rescan continuation")
  for mode in ["proof_reject","Stop","jaw","setup_uncertain","grip","wrong_arm","missing_endpoint"] {
   let h=Harness();h.activeHoldAfterInitialEmptyLift=true
   if mode=="proof_reject" {h.proofRejects=true}
   if mode=="Stop" {h.stopped=true}
   if mode=="jaw" {h.jawCommandDispatched=true}
   if mode=="setup_uncertain" {h.jawSetupDispatchUncertain=true}
   if mode=="grip" {h.recyclingGripDispatched=true}
   if mode=="wrong_arm" {h.physicalSide="left"}
   if mode=="missing_endpoint" {h.initialEmptyLiftHeldEvidence=nil}
   do {_=try await h.entry("left_recycle_can");preconditionFailure("Unsafe lift-only branch accepted: \(mode)")}catch{}
   precondition(h.singleCalls==0 && h.calibrationCalls==0,"Rejected branch chained hardware operation")
  }
  print("PASS actual DEBUG initial-empty-lift stop/result branches: defaultOFFbatch unchanged, one full-proof invocation then hold/no rescan, no-neededno-motion, zero transfers/jaws/grasp/carry, Stop/proof/jaw/scope/endpoint rejection; no actuator IO")
 }
}
'''.replace('__ACTUAL_PREPARATION__',preparation).replace('__ACTUAL_BRANCH__',branch).replace('__ACTUAL_RESULT__',result).replace('__ACTUAL_EXECUTE__',execute)
with tempfile.TemporaryDirectory(prefix='rob-initial-lift-hold-',dir='/private/tmp') as folder:
    p=Path(folder);(p/'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-O','-DDEBUG','-swift-version','5','-parse-as-library',str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True,timeout=45)
    subprocess.run([str(p/'fixture')],check=True,timeout=10)
