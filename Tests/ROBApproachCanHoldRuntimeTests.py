#!/usr/bin/env python3
"""Execute actual terminal hold helper; inspect its actual call ordering and default scope."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1]
s=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
helper=braced_declaration(s,'    @MainActor private func approachCanThenHoldResult(').replace('private func','func',1)
servo=braced_declaration(s,'    @MainActor private func performIncrementalCanGrasp(')
assert servo.index('guard observation.decision.readyToGrip') < servo.index('approachCanThenHoldResult(') < servo.index('let closeAndLift:') < servo.index('taskJaw(.grip')
assert 'approachCanThenHoldEnabled = false' in s
assert '(activeHoldAfterInitialEmptyLift || activeApproachCanThenHold) ? [.can]' in s
assert '!activeApproachCanThenHold' in s[s.index('let canAutoRecover='):s.index('let canAutoRecover=')+600]
assert 'movingTargetReplansRemaining=activeApproachCanThenHold ? 0:1' in s
fixture=r'''
import Foundation
enum ROBGhostMotionError:Error{case blocked(String)}
final class Sample{var positionsRadians=Array(repeating:NSNumber(value:0.02),count:7)}
@MainActor final class Trial{
 var activeApproachCanThenHold=false,approachCanThenHoldEnabled=false,recyclingGripDispatched=false
 var localReceiptCommand:String?="right_recycle_cans",checks=0,collisionChecks=0,holds=0,failCheck=false,drift=false
 let sample=Sample()
 func check()throws{checks+=1;if failCheck{throw ROBGhostMotionError.blocked("Stop")}}
 func checkCollisionContext()throws{collisionChecks+=1}
 func measured()throws->Sample{sample}
 func holdTaskPosition(_ q:[Double])async throws{holds+=1;if drift{sample.positionsRadians[0]=0.04}}
 /* HELPER */
}
@main enum Test{
 @MainActor static func main()async throws{
  let off=Trial();let untouched=try await off.approachCanThenHoldResult(readyToGrip:true,hasObservation:true)
  precondition(untouched==nil && off.holds==0 && off.checks==0)
  let on=Trial();on.activeApproachCanThenHold=true;on.approachCanThenHoldEnabled=true
  let result=try await on.approachCanThenHoldResult(readyToGrip:true,hasObservation:true)
  precondition(result?["status"]as?String=="partial_open_jaw_approach_held" && on.holds==1 && on.checks==2 && on.collisionChecks==1)
  precondition(result?["grip_sent"]as?Bool==false && result?["transfer_completed"]as?Bool==false && result?["automatic_recovery_eligible"]as?Bool==false)
  for mode in 0..<6{
   let bad=Trial();bad.activeApproachCanThenHold=true;bad.approachCanThenHoldEnabled=true
   if mode==0{bad.approachCanThenHoldEnabled=false};if mode==1{bad.recyclingGripDispatched=true};if mode==2{bad.localReceiptCommand=nil};if mode==3{bad.failCheck=true};if mode==4{bad.drift=true}
   do{_ = try await bad.approachCanThenHoldResult(readyToGrip:mode != 5,hasObservation:mode != 5);preconditionFailure("Invalid terminal hold accepted")}catch{}
   if mode != 4{precondition(bad.holds==0)}
  }
  print("PASS actual approach terminal: OFF unchanged; actual ready+source required; fresh scope/Stop/collision checks; measured hold/drift; no grip/lift/carry; zero transfers/no continuation")
 }
}
'''.replace('/* HELPER */',helper)
with tempfile.TemporaryDirectory(prefix='rob-approach-hold-',dir='/private/tmp')as folder:
 p=Path(folder);(p/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True,timeout=10)
