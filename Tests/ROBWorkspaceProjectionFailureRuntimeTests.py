#!/usr/bin/env python3
"""Run the real search retry branch with inert camera/neck/arm substitutes."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
vision = (ROOT / "Cerebro/ROBArmRoutineVision.swift").read_text()
display = (ROOT / "Cerebro/ROBNeckRGBPoseDisplay.swift").read_text()
retry = braced_declaration(vision, "func inspectWithRetry(")
failure = braced_declaration(display, "struct EstimatedProjectionSourceFailure:")
fixture = r'''
import Foundation
struct ROBWorkspaceView {let panDegrees=0.0,upperTarget=6160}
enum ROBNeckRGBPoseDisplay {__FAILURE__}
struct Vision {func healthSnapshot()->[String:Any] {[:]}}
enum TemporaryCamera:LocalizedError {case unavailable;var errorDescription:String? {"Camera stream unavailable"}}
@MainActor final class Harness {
 let vision=Vision()
 var evidence:[[String:Any]]=[],finished=false,calls=0,checkpoints=0,messages:[String]=[],reports:[String]=[]
 var error:Error?,stop=false
 func inspect(_ view:ROBWorkspaceView)async throws {calls+=1;if let error {throw error}}
 func searchCheckpoint()async throws {checkpoints+=1;if stop {throw CancellationError()}}
 func progress(_ text:String) {messages.append(text)}
 func persist(_ status:String,_ detail:String) {reports.append(status)}
 __RETRY__
}
@main enum Fixtures {
 @MainActor static func main()async throws {
  let stable=Harness()
  stable.error=ROBNeckRGBPoseDisplay.EstimatedProjectionSourceFailure(reason:"RGB-D intrinsics mismatch",retryAfterSettling:false)
  do {try await stable.inspectWithRetry(.init());fatalError("Permanent mismatch swallowed")}
  catch is ROBNeckRGBPoseDisplay.EstimatedProjectionSourceFailure {}
  precondition(stable.calls==1 && stable.evidence.count==1 && stable.finished && stable.reports==["camera_projection_rejected"] && stable.messages.isEmpty)
  for error:Error in [TemporaryCamera.unavailable,ROBNeckRGBPoseDisplay.EstimatedProjectionSourceFailure(reason:"IMU unsettled",retryAfterSettling:true)] {
   let transient=Harness();transient.error=error
   try await transient.inspectWithRetry(.init())
   precondition(transient.calls==2 && transient.evidence.count==2 && transient.messages.count==1 && !transient.finished)
  }
  let success=Harness();try await success.inspectWithRetry(.init());precondition(success.calls==1 && success.evidence.isEmpty)
  let stopped=Harness();stopped.error=TemporaryCamera.unavailable;stopped.stop=true
  do {try await stopped.inspectWithRetry(.init());fatalError("Stop swallowed")}catch is CancellationError {}
  precondition(stopped.calls==1 && stopped.evidence.isEmpty)
  let cancelled=Harness();cancelled.error=CancellationError()
  do {try await cancelled.inspectWithRetry(.init());fatalError("Cancellation swallowed")}catch is CancellationError {}
  precondition(cancelled.calls==1 && cancelled.checkpoints==0)
  print("PASS real search retry: source mismatch stops on first attempt with retained report; transient camera/IMU retries once; success, Stop and cancellation preserved. No hardware linked.")
 }
}
'''
with tempfile.TemporaryDirectory(prefix="rob-projection-failure-") as folder:
    swift, binary = Path(folder) / "Fixture.swift", Path(folder) / "fixture"
    swift.write_text(fixture.replace("__FAILURE__", failure).replace("__RETRY__", retry))
    subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-module-cache-path", "/private/tmp/cerebro-swift-module-cache", str(swift), "-o", str(binary)], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=15)
