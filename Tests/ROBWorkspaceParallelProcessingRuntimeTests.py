#!/usr/bin/env python3
"""Compile the native depth/inference handoff with inert concurrent workers."""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
source=(root/'Cerebro/ROBArmRoutineVision.swift').read_text()
start=source.index('            async let detection = ROBWorkspaceObjectDetector.shared.detect(jpeg: jpeg)')
end=source.index('            if result.candidates',start)
actual=source[start:end]
fixture=r'''
import Foundation
actor Events {
 var entries=[String]()
 func add(_ value:String) { entries.append(value) }
 func has(_ value:String)->Bool { entries.contains(value) }
 func reset() { entries.removeAll() }
}
let events=Events()
final class ROBWorkspaceObjectDetector: @unchecked Sendable {
 static let shared=ROBWorkspaceObjectDetector()
 func detect(jpeg:Data) async throws->Int {
  await events.add("detector-start")
  do {try await Task.sleep(nanoseconds:200_000_000)}
  catch {await events.add("detector-cancel");throw error}
  await events.add("detector-end");return 42
 }
}
enum Failure:Error {case depth}
@MainActor func exercise(fail:Bool) async throws->Int {
 let jpeg=Data(),frame=42
 func onCaptured(_ value:Int) async throws {
  let deadline=Date().addingTimeInterval(1)
  while !(await events.has("detector-start")) && Date()<deadline {await Task.yield()}
  precondition(await events.has("detector-start"),"Inference did not overlap depth")
  if fail {throw Failure.depth}
  await events.add("depth-complete")
 }
 __ACTUAL__
 precondition(await events.has("depth-complete"))
 return result
}
@main enum Test {
 static func main() async throws {
  let result=try await exercise(fail:false);precondition(result==42)
  await events.reset()
  do {_=try await exercise(fail:true);preconditionFailure("Depth failure accepted detection")}
  catch Failure.depth {}
  let cancelled=await events.has("detector-cancel");precondition(cancelled)
  print("PASS native frame handoff: inference overlaps depth; both must succeed; no camera or robot interfaces")
 }
}
'''.replace('__ACTUAL__',actual)
# Await cannot occur inside precondition's synchronous autoclosure.
fixture=fixture.replace('precondition(await events.has("detector-start"),', 'let started=await events.has("detector-start");precondition(started,')
fixture=fixture.replace('precondition(await events.has("depth-complete"))', 'let depthDone=await events.has("depth-complete");precondition(depthDone)')
with tempfile.TemporaryDirectory(prefix='rob-parallel-vision-') as folder:
 p=Path(folder);(p/'fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(p/'fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True,timeout=10)
