#!/usr/bin/env python3
"""Exercise the production post-search focus return with inert neck callbacks."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Cerebro/ROBArmRoutineVision.swift').read_text()
marker = '        if fixedRegisteredView==nil,let focus=found[.can] ?? found[.orangeBucket] {'
start = source.index(marker)
end = source.index('{', start) + 1
depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
actual = source[start:end]
assert source.index('if localReachSelectionRequired {found[.can]=localReachSelection?.object}') < start
assert start < source.index('        let missing = targets.filter { found[$0] == nil }')

fixture = r'''
import Foundation
enum Target:String {case can,orangeBucket;var spokenName:String {rawValue}}
struct View:Equatable {let panDegrees:Double;let upperTarget:Int}
struct Object {let target:Target;let view:View;let sequence:UInt64;let capturedAt:Double}
enum ROBArmRoutineError:Error {case blocked(String)}
enum Failure:Error {case cancelled,projectionChanged}
@MainActor func exercise(objects:[Target:Object],fixed:Bool=false,mode:String="normal")async throws->([View],[[String:Any]]) {
 let fixedRegisteredView:View?=fixed ? View(panDegrees:0,upperTarget:6306):nil
 let found=objects
 var moves:[View]=[],evidence:[[String:Any]]=[]
 func searchCheckpoint()async throws {if mode=="cancelled" {throw Failure.cancelled}}
 func requireSceneProjectionIdentity()throws {if mode=="projectionChanged" {throw Failure.projectionChanged}}
 func progress(_ message:String) {}
 func moveView(_ view:View)async throws->Bool {moves.append(view);return mode != "unavailable"}
 __ACTUAL__
 return (moves,evidence)
}
@main struct Fixtures {
 @MainActor static func main()async throws {
  let can=Object(target:.can,view:.init(panDegrees:-15,upperTarget:6000),sequence:123,capturedAt:1000)
  let bucket=Object(target:.orangeBucket,view:.init(panDegrees:30,upperTarget:6306),sequence:456,capturedAt:2000)
  let result=try await exercise(objects:[.can:can,.orangeBucket:bucket])
  precondition(result.0==[can.view] && result.1.count==1)
  precondition(result.1[0]["source_sequence"] as? UInt64==123 && result.1[0]["source_captured_at_ms"] as? Double==1000)
  precondition(result.1[0]["object_observation_refreshed"] as? Bool==false)
  let bucketOnly=try await exercise(objects:[.orangeBucket:bucket]);precondition(bucketOnly.0==[bucket.view])
  let fixed=try await exercise(objects:[.can:can],fixed:true);precondition(fixed.0.isEmpty && fixed.1.isEmpty)
  let absent=try await exercise(objects:[:]);precondition(absent.0.isEmpty && absent.1.isEmpty)
  do {_=try await exercise(objects:[.can:can],mode:"unavailable");preconditionFailure("Unavailable focus reported success")}
  catch ROBArmRoutineError.blocked {}
  for mode in ["cancelled","projectionChanged"] {
   do {_=try await exercise(objects:[.can:can],mode:mode);preconditionFailure("Changed context reported focus success")}
   catch is Failure {}
  }
  print("PASS native object-focus return: selected can before bucket, original source timestamps retained, fixed views untouched, missing target sends no neck command, cancelled/unavailable/changed context rejects")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='rob-object-focus-') as folder:
    path = Path(folder)
    swift, binary = path / 'Fixture.swift', path / 'fixture'
    swift.write_text(fixture.replace('__ACTUAL__', actual))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-module-cache-path', '/private/tmp/cerebro-swift-module-cache',
                    str(swift), '-o', str(binary)], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=15)
