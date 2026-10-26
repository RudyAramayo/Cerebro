#!/usr/bin/env python3
"""Run actual frame-eligibility/settling methods with inert frames and a virtual clock."""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]

def block(source, marker):
    start=source.index(marker);index=source.index('{',start)+1;depth=1
    while depth:
        depth+=(source[index]=='{')-(source[index]=='}');index+=1
    return source[start:index]

SUPPORT=r'''
import Foundation
final class Clock {
 static var milliseconds=1_000_000.0
 static var tick:(()->Void)?
 static var cancelled=false
}
struct Date {var timeIntervalSince1970:Double {Clock.milliseconds/1000}}
struct ProcessInfo {static let processInfo=ProcessInfo();var systemUptime:Double {Clock.milliseconds/1000}}
enum Task {
 static func checkCancellation()throws {if Clock.cancelled {throw CancellationError()}}
 static func sleep(nanoseconds:UInt64)async throws {try checkCancellation();Clock.milliseconds+=Double(nanoseconds)/1_000_000;Clock.tick?()}
}
enum ROBArmRoutineError:LocalizedError {case blocked(String);var errorDescription:String? {if case .blocked(let s)=self{return s};return nil}}
struct Depth {var width=640,height=480}
struct K {
 var fx=490.0,fy=490.0,cx=320.0,cy=240.0
 __ACTUAL_K_VALIDITY__
}
final class ROBArmRoutineVision {
 struct Frame {
  var capturedAt:Double;var sequence:UInt64;var handsClear:Bool;var depthCoverage:Double
  var thumbnail:[UInt8];var depth:Depth?;var intrinsics:K?;var cameraGeneration:UUID
 }
 let lock=NSLock();var active=true,epoch=UUID(),cameraGeneration=UUID()
 var frames:[String:Frame]=[:]
 __ACTUAL_METHODS__
 func ordinarySettled()async throws->Frame {try await settledInspectionFrame(epoch:inspectionEpoch())}
}
final class Feed {
 let vision:ROBArmRoutineVision,mode:String,coverage:Double
 var sleeps=0,emitted=0
 init(_ mode:String,_ coverage:Double) {
  self.mode=mode;self.coverage=coverage;vision=ROBArmRoutineVision()
  vision.frames["face"]=frame()
 }
 func frame()->ROBArmRoutineVision.Frame {
  var captured=Clock.milliseconds
  if mode=="stale" {captured-=701}
  if mode=="future" {captured+=10_000}
  if mode=="retained" && emitted==0 {captured-=50}
  if mode=="timestamp_reordered" && emitted==2 {captured-=250}
  let sequence:UInt64=mode=="sequence_reordered" && emitted==2 ? 19:UInt64(20+emitted)
  let gray:UInt8=mode=="changing" && emitted%2==1 ? 60:0
  var k=K();if mode=="invalid_k" {k.fx=0}
  return .init(capturedAt:captured,sequence:sequence,handsClear:mode != "human",
   depthCoverage:mode=="zero_depth" ? 0:coverage,thumbnail:[UInt8](repeating:gray,count:64*48*4),
   depth:mode=="missing_depth" ? nil:Depth(),intrinsics:mode=="missing_k" ? nil:k,
   cameraGeneration:mode=="wrong_source" ? UUID():vision.cameraGeneration)
 }
 func tick() {
  sleeps+=1
  if mode=="duplicate" {return}
  guard sleeps%3==0 else{return};emitted+=1
  if mode=="source_changed" {vision.cameraGeneration=UUID();vision.epoch=UUID()}
  if mode=="cancelled" {Clock.cancelled=true}
  vision.frames["face"]=frame()
 }
}
@main enum PartialDepthFixture {
 static func run(_ mode:String="normal",coverage:Double=0.18,mapping:Bool=true,deadlineSeconds:Double?=nil)async throws->(ROBArmRoutineVision.Frame,Feed,Double) {
  Clock.milliseconds=1_000_000;Clock.cancelled=false
  let feed=Feed(mode,coverage);Clock.tick={feed.tick()};defer{Clock.tick=nil}
  let start=Clock.milliseconds
  let result:ROBArmRoutineVision.Frame
  if mapping {result=try await feed.vision.settledDepthFrame(deadlineUptime:deadlineSeconds.map{ProcessInfo.processInfo.systemUptime+$0})}
  else {result=try await feed.vision.ordinarySettled()}
  return(result,feed,Clock.milliseconds-start)
 }
 static func rejected(_ mode:String,coverage:Double=0.18,mapping:Bool=true,contains:String?=nil)async {
  do {_=try await run(mode,coverage:coverage,mapping:mapping);preconditionFailure("Bad frame admitted: \(mode)")}
  catch {if let contains {precondition(error.localizedDescription.contains(contains),error.localizedDescription)}}
 }
 static func main()async throws {
  let partial=try await run()
  precondition(partial.0.sequence==22 && partial.2==300,"Mapping did not require three advancing exposures over300ms")
  precondition(!partial.1.vision.fresh && !partial.1.vision.handsClear,"Partial map frame changed general motion readiness")
  await rejected("normal",mapping:false,contains:"did not settle")
  let ordinary=try await run(coverage:0.25,mapping:false)
  precondition(ordinary.0.sequence==22 && ordinary.1.vision.fresh && ordinary.1.vision.handsClear)
  let human=try await run("human")
  precondition(!human.1.vision.handsClear,"Depth-map acquisition granted human clearance")
  let retained=try await run("retained")
  precondition(retained.0.sequence==23 && retained.2==450,"Retained pre-start frame counted toward settling")
  for mode in ["stale","future","wrong_source","zero_depth","missing_depth","missing_k","invalid_k","duplicate","changing"] {
   await rejected(mode,contains:"did not settle")
  }
  await rejected("normal",coverage:.nan,contains:"did not settle")
  await rejected("normal",coverage:1.01,contains:"did not settle")
  for mode in ["sequence_reordered","timestamp_reordered"] {await rejected(mode,contains:"restarted")}
  for mode in ["source_changed","cancelled"] {
   do {_=try await run(mode);preconditionFailure("Changed/cancelled source admitted")}
   catch {precondition(error is CancellationError)}
  }
  do {_=try await run(deadlineSeconds:0.2);preconditionFailure("Caller deadline extended")}
  catch {precondition(Clock.milliseconds==1_000_200)}
  print("PASS actual partial-depth settling: stable18% mapping accepted with3advancing/300ms; ordinary25%+700ms/human readiness unchanged; retained/stale/future/source/reordered/zero/missing-depth/invalid-K/static/cancel/deadline negatives; no mapping rays or motor output invented")
 }
}
'''

def main():
    vision=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
    camera=(ROOT/'Cerebro/CameraManager.swift').read_text()
    markers=['func snapshot() -> [String: Frame]', 'var fresh: Bool', 'var handsClear: Bool',
             'private func isFresh(', 'private func isDepthMappingEligible(', 'private func inspectionEpoch(',
             'func settledDepthFrame(', 'private func inspectionFrame(', 'static func sceneChangeFraction(',
             'private func settledInspectionFrame(']
    actual='\n'.join(block(vision,m) for m in markers)
    general=block(vision,'private func isFresh(')
    assert general=='''private func isFresh(_ frame: Frame) -> Bool {
        (0 ... 700).contains(Date().timeIntervalSince1970 * 1000 - frame.capturedAt)
            && frame.depthCoverage >= 0.25
    }'''
    assert vision.count('depthMappingOnly:true')==1
    assert 'depthMappingOnly:true' in block(vision,'func settledDepthFrame(')
    assert 'depthMappingOnly:Bool=false' in block(vision,'private func settledInspectionFrame(')
    assert 'settledInspectionFrame(epoch: token, requireStaticScene: false)' in vision
    source=SUPPORT.replace('__ACTUAL_METHODS__',actual).replace('__ACTUAL_K_VALIDITY__',block(camera,'func isValid(forWidth width: Int, height: Int)'))
    with tempfile.TemporaryDirectory(prefix='rob-partial-depth-settle-')as folder:
        p=Path(folder);swift=p/'fixture.swift';binary=p/'fixture';swift.write_text(source)
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True,timeout=60)
        subprocess.run([str(binary)],check=True,timeout=20)

if __name__=='__main__':main()
