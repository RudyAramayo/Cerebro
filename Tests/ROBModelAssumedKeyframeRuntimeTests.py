#!/usr/bin/env python3
"""Exercise actual keyframe timing/count/cancellation loop with passive values."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1]
source=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
method=braced_declaration(source,'    @MainActor private func collectNominalKeyframes(').replace('@MainActor private func','func',1)
execute=braced_declaration(source,'    @MainActor private func executeNominalEmptyCommissioning()')
view=braced_declaration(source,'    @MainActor private func captureRightArmCalibrationView(')
assert 'executeSingle(' not in execute and 'search.run(' not in execute
assert execute.count('if usesFixedCommissioningKeyframes {ROBWorkspaceSearch.shared.announce?("Moving my right arm a little.")}')==1
assert execute.count('if usesFixedCommissioningKeyframes {ROBWorkspaceSearch.shared.announce?("Arm movement complete. Holding here.")}')==1
assert execute.index('Moving my right arm a little.')<execute.index('gateway.sendApprovedLeftGestureStep(')
assert execute.index('Arm movement complete. Holding here.')>execute.index('try await archive.finish()')
assert execute.index('Arm movement complete. Holding here.')>execute.index('guard 1.5*zip(endpoint,proof.goal)')

assert 'if !usesFixedCommissioningKeyframes {try await wait(12){search.prepareView?' in view
assert view.index('return prior')<view.index('var map=ROBWorkspaceDepthMap')
assert 'prior.originalOccupiedSourceGroups != nil' in view
fixture=r'''
import Foundation
enum ROBArmRoutineError:Error {case blocked(String)}
struct ROBWorkspaceCollisionSnapshot {}
struct ROBGhostRobotModel {}
struct ROBWorkspaceRawScanArchive {}
struct Frame {let sequence:UInt64;let capturedAt:Double}
final class PassiveVision {
 let started=ProcessInfo.processInfo.systemUptime
 var frozen=false
 func snapshot()->[String:Frame] {
  let elapsed=ProcessInfo.processInfo.systemUptime-started
  return ["face":Frame(sequence:frozen ? 1:UInt64(elapsed/0.04)+2,capturedAt:Date().timeIntervalSince1970*1000)]
 }
}
@MainActor final class Fixture {
 let vision=PassiveVision()
 var stopped=false,nominalArchiveLastSequence:UInt64=0
 var nominalArchiveTimes:[(stage:String,time:Double)]=[]
 var recorded:[(stage:String,sequence:UInt64,time:Double)]=[]
 func check()throws {if stopped {throw ROBArmRoutineError.blocked("fixture Stop")}}
 func archiveNominalKeyframe(_ frame:Frame,stage:String,map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,writer:ROBWorkspaceRawScanArchive)async throws->Int {
  try check();recorded.append((stage,frame.sequence,frame.capturedAt));return recorded.count
 }
 /* METHOD */
}
@main enum Test {
 @MainActor static func main()async throws {
  let f=Fixture(),map=ROBWorkspaceCollisionSnapshot(),model=ROBGhostRobotModel(),writer=ROBWorkspaceRawScanArchive()
  try await f.collectNominalKeyframes(count:3,stage:"before",map:map,model:model,writer:writer)
  let began=ProcessInfo.processInfo.systemUptime,host=Date().timeIntervalSince1970*1000
  try await f.collectNominalKeyframes(count:8,stage:"during",map:map,model:model,writer:writer,startUptime:began,startHostMilliseconds:host)
  try await f.collectNominalKeyframes(count:3,stage:"after",map:map,model:model,writer:writer,startHostMilliseconds:Date().timeIntervalSince1970*1000)
  precondition(f.recorded.count==14 && f.nominalArchiveTimes.count==14)
  precondition(["before","during","after"].map{stage in f.recorded.filter{$0.stage==stage}.count} == [3,8,3])
  precondition(zip(f.recorded.dropFirst(),f.recorded).allSatisfy{$0.sequence>$1.sequence && $0.time>$1.time})
  let during=f.recorded.filter{$0.stage=="during"};precondition(during.allSatisfy{(0...4000).contains($0.time-host)})
  let stopped=Fixture();stopped.stopped=true
  do {try await stopped.collectNominalKeyframes(count:3,stage:"before",map:map,model:model,writer:writer);preconditionFailure("Stop ignored")}catch{}
  precondition(stopped.recorded.isEmpty)
  let stale=Fixture();stale.vision.frozen=true;stale.nominalArchiveLastSequence=1
  do {try await stale.collectNominalKeyframes(count:3,stage:"after",map:map,model:model,writer:writer);preconditionFailure("Repeated source fabricated after frames")}catch{}
  precondition(stale.recorded.isEmpty)
  print("PASS actual14-keyframe scheduler:3before/8actual4seccommand-window/3after, advancing original timestamps/sequences, Stop and repeated-source fail without invented frames; direct nominal branch has no search/head prepare/raw map replacement")
 }
}
'''.replace('/* METHOD */',method)
with tempfile.TemporaryDirectory(prefix='rob-model-keyframes-',dir='/private/tmp')as folder:
 p=Path(folder);(p/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True,timeout=15)
