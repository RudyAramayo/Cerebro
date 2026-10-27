#!/usr/bin/env python3
"""Exercise production held-gripper preparation with an inert transport."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


STUBS = r'''
import Foundation
enum ROBArmRoutineError: Error { case blocked(String) }
struct ROBGhostRobotModel {}
struct ROBWorkspaceCollisionSnapshot { let sceneID=UUID() }
struct Trial {}
struct Step { let positions:[Double];let seconds:Double;let stage:String }
enum ROBWorkspaceCollisionPlan {
 static var reviews=0
 static func reviewVisualCalibrationTrial(baseline:[Double],steps:[Step],map:ROBWorkspaceCollisionSnapshot,
    model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,
    nowMilliseconds:Double,trial:Trial)throws->Bool {
  precondition(steps.count==1 && steps[0].positions==baseline,"Preparation requested arm travel")
  reviews+=1;return true
 }
}
final class ROBControllerArmApproval {
 static let shared=ROBControllerArmApproval()
 var standingCanCampaignMayHoldPayload=false
}
final class ROBGripperStartupCalibration {
 static let shared=ROBGripperStartupCalibration()
 func calibrationReady(forArm:String)->Bool {false}
}
final class Gateway {
 var calibrated=false,failRelease=false
 var commands:[String]=[]
 func queryGripperState(forArm:String)->UInt64 {commands.append("query");return 1}
 func calibrateGripper(forArm:String)->UInt64 {commands.append("calibrate");calibrated=true;return 1}
 func gripperSnapshot(forArm:String)->[String:Any] {
  ["calibrationState":calibrated ? "command_accepted_unverified":"required"]
 }
 func controlGripper(forArm:String,action:String,force:Int)->UInt64 {
  commands.append("\(action):\(force)");return failRelease && action=="release" ? 0:1
 }
}
struct Vision {let cameraGeneration=UUID()}
struct Sample {let positionsRadians:[NSNumber]}
@MainActor final class Harness {
 let gateway=Gateway(),vision=Vision(),arm="left",physicalSide="right"
 var generation:UInt64=5,previewedGripperReadyGeneration:UInt64?
 var activePreviewedCanGrasp:Int?=1
 var recyclingGripDispatched=false,jawSetupDispatchUncertain=false,servoPossiblePayloadUncertain=false
 var authorized=true,held=false
 var phase="",taskJawTarget:[Double]?,taskOpeningCommandAtMilliseconds:Double?
 let q:[Double]=[-0.25,-1.66,0,-0.98,1.1,1.7,0.46]
 func requireLocalReceipt()throws->Bool {guard authorized else{throw ROBArmRoutineError.blocked("No receipt")};return true}
 func measured()throws->Sample {.init(positionsRadians:q.map(NSNumber.init(value:)))}
 func visualTrial(map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,baseline:[Double])throws->Trial? {Trial()}
 func requireLiveVisualTrial(_ trial:Trial,map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel)throws {}
 func check()throws {}
 func holdTaskPosition(_ target:[Double])async throws {precondition(target==q);held=true;taskJawTarget=target}
 func accepted(_ dispatch:()->UInt64)async throws {
  precondition(held,"Jaw command preceded measured hold")
  guard dispatch() != 0 else{throw ROBArmRoutineError.blocked("Rejected")}
 }
 func accountedJawCommand(_ dispatch:()->UInt64)->UInt64 {dispatch()}
 func update(_ value:String) {}
 // The inert fixture records dispatch order; wall-clock settling is covered
 // by the existing real executor fixture, not replaced in production.
 func wait(_ seconds:Double,_ condition:()->Bool)async throws {}
 func run()async throws {try await preparePreviewedCanGripper(model:.init(),map:.init())}
 var ready:Bool {taskGripperReady}
'''

FIXTURE = r'''
}
@main struct Fixtures {
 @MainActor static func main()async throws {
  let normal=Harness();try await normal.run()
  precondition(normal.gateway.commands==["query","calibrate","hold:2","release:10","query"])
  precondition(normal.ready && !normal.jawSetupDispatchUncertain && normal.taskJawTarget==nil)
  try await normal.run();precondition(normal.gateway.commands.count==5,"Prepared jaws repeated initialization")
  normal.generation+=1;precondition(!normal.ready,"Readiness survived a new connection generation")
  for kind in ["payload","unauthorized","release-rejected"] {
   let h=Harness()
   ROBControllerArmApproval.shared.standingCanCampaignMayHoldPayload=kind=="payload"
   h.authorized=kind != "unauthorized";h.gateway.failRelease=kind=="release-rejected"
   do {try await h.run();fatalError("Admitted \(kind)")} catch {}
   precondition(!h.ready && h.taskJawTarget==nil)
   if kind=="release-rejected" {
    precondition(h.jawSetupDispatchUncertain && h.gateway.commands==["query","calibrate","hold:2","release:10"])
   } else {precondition(h.gateway.commands.isEmpty)}
  }
  precondition(ROBWorkspaceCollisionPlan.reviews==2)
  print("PASS held empty-gripper preparation: stationary review/hold precede genuine calibration-close-open; no replay, no readiness on rejected opening, payload/authority/generation guards retained; no arm transport")
 }
}
'''

source = (ROOT / "Cerebro/ROBLeftArmTrial.swift").read_text()
methods = "\n".join(block(source, marker) for marker in [
    "@MainActor private func requireGripperCalibration(",
    "private var taskGripperReady:",
    "@MainActor private func preparePreviewedCanGripper(",
])
with tempfile.TemporaryDirectory(prefix="rob-previewed-gripper-") as folder:
    swift = Path(folder) / "fixture.swift"
    binary = Path(folder) / "fixture"
    swift.write_text(STUBS + methods + FIXTURE)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
