#!/usr/bin/env python3
"""Execute native scan staging/view planning with inert neck callbacks only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def method(source, marker):
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("@nonobjc private func", "func", 1)


FIXTURE = r'''
import Foundation
import simd
struct ProcessInfo {static let processInfo=Clock()}
final class Clock {var systemUptime=100.0}
enum Task {
 static func checkCancellation()throws {}
 static func sleep(nanoseconds:UInt64)async throws {ProcessInfo.processInfo.systemUptime+=Double(nanoseconds)/1e9}
}
struct ROBWorkspaceView:Equatable {let panDegrees:Double;let upperTarget:Int}
struct ROBGhostRobotModel {}
enum ROBWorkspaceDepthMapError:Error {case invalidFrame;case acquisition(String)}
final class ROBFixedHeadCalibrationWindowController {
 static let shared=ROBFixedHeadCalibrationWindowController()
 var neck:[String:Any]=[:]
 var readNeck:(()->[String:Any])? {{self.neck}}
}
enum ROBNeckRGBPoseDisplay {
 static func provisionalCameraToModel(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->simd_double4x4? {
  precondition(lowerTarget==ROBFixedHeadCalibrationWindowController.shared.neck["lower"]as?Int);return matrix_identity_double4x4
 }
}
struct ROBWorkspaceBlockerCoverageCandidate {let view:ROBWorkspaceView;let cameraToRobotColumnMajor:[Double]}
@MainActor final class Harness {
 var full=false,mode="normal",prepareCalls:[ROBWorkspaceView]=[]
 lazy var boundedPan:((Double)->Double)? = {[unowned self] in self.full ? max(-60,min(60,$0)):max(-15,min(2.1,$0))}
 lazy var canUseView:((Double,Int)->Bool)? = {[unowned self] p,_ in
  self.mode != "unavailable" && p >= (self.full ? -60:-15) && p <= (self.full ? 60:2.1)
 }
 let panTargetForView:((Double)->NSNumber?)? = {NSNumber(value:Int((6000+$0*100/3).rounded()))}
 lazy var prepareView:((Double,Int)->Bool)? = {[unowned self] p,u in
  precondition(self.canUseView!(p,u),"Issued an out-of-envelope neck request")
  self.prepareCalls.append(.init(panDegrees:p,upperTarget:u))
  if self.mode=="normal" {self.full=true}
  let lower=self.mode=="wrong_lower" ? 6411:self.mode=="lean" ? 6819:6011
  ROBFixedHeadCalibrationWindowController.shared.neck=["known":true,"stationary":true,"lower":lower]
  return self.mode != "never_settled"
 }
 lazy var viewReady:((Double,Int)->Bool)? = {[unowned self] _,_ in self.mode != "never_settled"}
 __SETTLE__
 __PREPARE__
 func targetCandidates()->[ROBWorkspaceBlockerCoverageCandidate] {
  let model=ROBGhostRobotModel()
  let heldLowerTarget=ROBFixedHeadCalibrationWindowController.shared.neck["lower"]as!Int
  __ACTUAL_CANDIDATES__
  return candidates
 }
}
@main enum Fixtures {
 @MainActor static func main()async throws {
  func reset(_ mode:String)->Harness {ProcessInfo.processInfo.systemUptime=100;let h=Harness();h.mode=mode;ROBFixedHeadCalibrationWindowController.shared.neck=["known":true,"stationary":true,"lower":mode=="lean" ? 6819:6011];return h}
  let recovered=reset("normal")
  var settleSamples=0
  let views=try await recovered.preparedCollisionScanViews(check:{},status:{_,_,_ in settleSamples+=1})
  precondition(views==[-45.0,-15,15,45].map{ROBWorkspaceView(panDegrees:$0,upperTarget:5650)} +
      [30.0,0,-30].map{ROBWorkspaceView(panDegrees:$0,upperTarget:6306)})
  precondition(recovered.prepareCalls.allSatisfy{$0.panDegrees==0 && $0.upperTarget==5650})
  precondition(settleSamples>=16 && ProcessInfo.processInfo.systemUptime>=101.5)
  let targets=recovered.targetCandidates()
  precondition(targets.count==52 && targets.contains{$0.view==ROBWorkspaceView(panDegrees:-50,upperTarget:5450)})
  precondition(recovered.panTargetForView?(-50)?.intValue==4333)
  let restricted=reset("restricted")
  let limited=try await restricted.preparedCollisionScanViews(check:{},status:{_,_,_ in})
  precondition(limited.count==5 && limited.allSatisfy{(-15...2.1).contains($0.panDegrees)})
  precondition(restricted.targetCandidates().allSatisfy{(-15...2.1).contains($0.view.panDegrees)})
  precondition(!restricted.targetCandidates().contains{$0.view.panDegrees == -50})
  precondition(restricted.prepareCalls.allSatisfy{$0.panDegrees==0},"Restricted staging dispatched a forbidden target")
  let leaned=reset("lean")
  let leanViews=try await leaned.preparedCollisionScanViews(check:{},status:{_,_,_ in})
  precondition(leanViews.count==5 && leanViews.allSatisfy{(-15...2.1).contains($0.panDegrees)})
  precondition(ROBFixedHeadCalibrationWindowController.shared.neck["lower"]as?Int==6819)
  precondition(!leaned.targetCandidates().isEmpty)
  for mode in ["unavailable","wrong_lower","never_settled","stop"] {
   let h=reset(mode);var checks=0
   do {_=try await h.preparedCollisionScanViews(check:{checks+=1;if mode=="stop" && checks==3 {throw ROBWorkspaceDepthMapError.invalidFrame}},status:{_,_,_ in});preconditionFailure("Accepted failed staging: \(mode)")}
   catch {}
   precondition(h.prepareCalls.allSatisfy{$0.panDegrees==0},"Failed staging sent a wider view")
   if mode=="unavailable" {precondition(h.prepareCalls.isEmpty)}
  }
  print("PASS actual scan staging: initial restricted bounds restore full seven-view sweep only AFTER native1.5s settle/unchanged selected lower; forward6819 retains its restricted views and actual-lower projection; persistent restriction/failed lower/timeout/Stop never dispatch a forbidden view. No camera, arm, actuator transport or authority exists in this fixture.")
 }
}
'''


def main():
    source = (ROOT / "Cerebro/ROBArmRoutineVision.swift").read_text()
    settle = method(source, "    @MainActor @nonobjc private func settleCollisionScanView(")
    prepare = method(source, "    @MainActor @nonobjc private func preparedCollisionScanViews(")
    scan = method(source, "    @MainActor @nonobjc func scanCollisionScene(")
    assert scan.index("return try await captureRegisteredCurrentScene") < scan.index("preparedCollisionScanViews(")
    assert "requestedViews.map" not in scan
    assert "try await settleCollisionScanView(view,check:stagingCheck,status:settleStatus)" in scan
    assert prepare.index("try await settleCollisionScanView") < prepare.index("boundedPan?(request.panDegrees)")
    start = source.index("        var candidates:[ROBWorkspaceBlockerCoverageCandidate]=[]", source.index("func captureBlockerCoverage("))
    end = source.index("        let selected=ROBWorkspaceBlockerCoveragePlan.nextView", start)
    candidates = source[start:end]
    assert "canUseView?(bounded,upper)==true" in candidates and "lowerTarget:heldLowerTarget" in candidates
    assert not any(x in settle + prepare for x in ["sendApproved", "setGripper", "Task.detached", "markFree", "approve"])
    with tempfile.TemporaryDirectory(prefix="rob-scan-staging-") as folder:
        p = Path(folder)
        swift, binary = p / "Fixture.swift", p / "fixture"
        swift.write_text(FIXTURE.replace("__SETTLE__", settle).replace("__PREPARE__", prepare).replace("__ACTUAL_CANDIDATES__", candidates))
        subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-module-cache-path", "/private/tmp/cerebro-swift-module-cache", str(swift), "-o", str(binary)], check=True, timeout=45)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
