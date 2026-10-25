#!/usr/bin/env python3
"""Execute the production Trial pre-dispatch and moving-poll guards without hardware."""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Cerebro/ROBLeftArmTrial.swift").read_text()


def between(start, end):
    return source[source.index(start):source.index(end, source.index(start))]


methods = "\n".join([
    between("    private func check() throws {", "    private func captureActualCampaignInterruption()"),
    between("    @MainActor private func wait(_ seconds:", "    @MainActor private func execute(_ command:"),
    between("    private func monitor() {", "    private func writeVisualGraspEvidence("),
    between("    private func abort(_ message:", "    private func finish(_ result:"),
])

fixture = r'''
import Foundation

enum ROBArmRoutineError: LocalizedError {
    case blocked(String)
    var errorDescription:String? { if case .blocked(let text)=self { return text };return nil }
}
enum ROBWorkspaceCollisionPlan { static let sweptPointTravelMeters=0.003 }
enum ROBArmRoutinePlan { static func near(_ a:[Double],_ b:[Double])->Bool { a==b } }
enum ROBLeftArmInteractionPlan { static func stationaryFrontTarget(_ q:[Double])->Int? { 1 } }
final class ROBControllerArmApproval {
    static let shared=ROBControllerArmApproval()
    func authorizesLeftArmTrial(_ s:String)->Bool { true }
    func authorizesRightArmTrial(_ s:String)->Bool { true }
}
final class ROBArmRoutineCoordinator {
    static let shared=ROBArmRoutineCoordinator()
    var viewIsStationary:(()->Bool)? = { true }
}
struct Sample {
    let effectiveSampleAgeMilliseconds=0.0,effectiveGripperFeedbackAgeMilliseconds=0.0
    let positionsRadians=[NSNumber](repeating:0,count:7)
    let statuses=[NSNumber](repeating:2,count:7)
}
final class Gateway {
    var targets=0,holds=0,renewals=0
    func isReady()->Bool {true}
    func connectionSnapshot()->NSDictionary {["sessionGeneration":NSNumber(value:1)]}
    func telemetry(forArm:String)->Sample? { Sample() }
    func modes(forArm:String)->[NSNumber] {[NSNumber](repeating:2,count:7)}
    func priorityHold(forArm:String)->UInt64 {holds+=1;return 9}
    func renewLease(forArm:String,leaseMilliseconds:Int)->UInt64 {renewals+=1;return 7}
}
final class Vision {var fresh=true,handsClear=true}

@MainActor final class Trial {
    static let neckOnlyCommands=["left_search_workspace"]
    let gateway=Gateway(),vision=Vision()
    var failure:String?,localReceiptCommand:String?
    var sceneHold:[String:(modes:[Int],positions:[Double])]=[:]
    var arm="right",physicalSide="right",activeCommand="left_recycle_can",summary="exact approved can job"
    var deadline=Double.infinity,generation:UInt64=1
    var inactiveWorkspaceSearch=false,leased=false,positionReady=true,cameraReady=true
    var leaseRenewals:[UInt64:Double]=[:],interactionStage="",readinessConfirmed=false
    var taskJawTarget:[Double]?,waiting=Set<UInt64>(),acks:[UInt64:Bool]=[:],holdConfirmations:[UInt64:Bool]=[:]
    var phase="initial can entry",lastRenewal=0.0
    var isRunning=true,activeEstimated:Int?,reviewedDispatchStart:Int?
    var task:Task<Void,Never>?,records=0,collisionChecks=0,status=""
    func captureActualCampaignInterruption() {}
    func requireLocalReceipt() throws->Int {1}
    func measured() throws->Sample {Sample()}
    func checkCollisionContext() throws {collisionChecks+=1}
    func record(_ sample:Sample)throws {records+=1}
    func invalidateEstimatedPreview(reason:String) {}
    func update(_ message:String) {status=message}
__METHODS__
    func checkPasses()->Bool {do {try check();return true}catch{return false}}
    func sendTarget() async throws {
        try await accepted {self.gateway.targets+=1;self.acks[1]=true;return 1}
    }
    func poll() {monitor()}
}

@main struct Main {
    @MainActor static func main() async throws {
        var checks=0
        func verify(_ condition:Bool,_ message:String) {precondition(condition,message);checks+=1}
        let initial=Trial();initial.vision.handsClear=false
        verify(!initial.checkPasses(),"Fresh camera with a detected hand passed the actual Trial check")
        do {try await initial.sendTarget();preconditionFailure("Initial target was dispatched with a detected hand")}
        catch {verify(initial.gateway.targets==0,"accepted() sent a target before human-clearance admission")}
        verify(initial.waiting.isEmpty,"Rejected initial dispatch retained an acknowledgement wait")

        let clear=Trial()
        verify(clear.checkPasses(),"Clear fresh stationary view was rejected")
        try await clear.sendTarget()
        verify(clear.gateway.targets==1 && clear.waiting.isEmpty,"Clear initial entry did not retain accepted() behavior")

        let moving=Trial();moving.leased=true;moving.lastRenewal=ProcessInfo.processInfo.systemUptime-1
        moving.poll()
        verify(moving.failure==nil && moving.gateway.renewals==1,"Clear moving poll did not renew its existing lease")
        moving.vision.handsClear=false
        moving.poll()
        verify(moving.failure?.contains("Person or hand") == true,"Moving poll ignored newly detected human clearance loss")
        verify(moving.gateway.holds==1 && !moving.leased,"Human clearance loss did not use the existing abort/hold path")
        verify(moving.gateway.renewals==1,"Human clearance loss renewed a motion lease")
        moving.poll()
        verify(moving.gateway.holds==1 && moving.gateway.renewals==1,"Failed poll repeatedly dispatched commands")

        let stale=Trial();stale.vision.fresh=false
        verify(!stale.checkPasses(),"Existing stale-camera veto was weakened")
        let scanning=Trial();scanning.cameraReady=false;scanning.positionReady=false;scanning.vision.handsClear=false
        verify(scanning.checkPasses(),"The new veto was applied before the camera-ready motion phase")
        print("Trial human clearance: \(checks) runtime checks PASS; actual check/accepted/monitor/abort, no hardware")
    }
}
'''.replace("__METHODS__", methods)

with tempfile.TemporaryDirectory(prefix="rob-trial-human-clearance-", dir="/private/tmp") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                    str(path / "main.swift"), "-o", str(path / "fixture")], check=True)
    subprocess.run([str(path / "fixture")], check=True)
