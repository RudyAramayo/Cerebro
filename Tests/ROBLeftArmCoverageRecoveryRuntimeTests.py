#!/usr/bin/env python3
"""Exercise the actual preflight coverage loop with inert reviewers and captures.

This tests orchestration and rejection paths, not geometric clearance. The
fixture has no actuator, camera, socket, receipt-store, or preferences API.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    index = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[start:index]


FIXTURE = r'''
import Foundation

enum ROBArmRoutineError:LocalizedError {
    case blocked(String)
    var errorDescription:String? {if case .blocked(let text)=self{return text};return nil}
}
struct ROBWorkspaceVoxel {
    let x:Int,y:Int,z:Int
    func center(voxelSizeMeters:Double)->SIMD3<Double> {
        SIMD3((Double(x)+0.5)*voxelSizeMeters,(Double(y)+0.5)*voxelSizeMeters,(Double(z)+0.5)*voxelSizeMeters)
    }
}
__ACTUAL_BLOCKER__
struct ROBWorkspaceView:Equatable {let panDegrees:Double;let upperTarget:Int}
enum VoxelState:Int {case unknown=0,free=1,occupied=2}
struct ROBWorkspaceCollisionSnapshot {
    var sceneID=UUID(),cameraGeneration=UUID(),sessionGeneration:UInt64=1
    var bodyMotionIdentity="body",estimatedCameraProjectionIdentity:String?="projection"
    var observedFrameCount=5,lastCapturedAtMilliseconds=1000.0,voxelSizeMeters=0.025
    var fingerprint="original",voxelState=VoxelState.unknown
    func state(at:SIMD3<Double>)->VoxelState {voxelState}
}
struct ROBGhostRobotModel {}
struct ROBWorkspaceVisualCalibrationTrial {let mapFingerprint:String;let baseline:[Double]}
struct ROBWorkspaceInitialEmptyRetreat {let mapFingerprint:String;let baseline:[Double]}
struct Sample {
    let positionsRadians:[NSNumber]
    let effectiveSampleAgeMilliseconds=1.0
    let sequence:UInt64=100
}
final class Vision {var cameraGeneration=UUID()}
let unknownDetail="right_five_Link enters unobserved space. Scan the whole arm route before moving. Convex distance upper bound 57.019 mm; retained envelope margin 60.000 mm; voxel [-4,-8,21]; representation whole_voxel."
let occupiedDetail="right_five_Link approaches an observed obstacle; no path was admitted."

@MainActor final class ROBWorkspaceSearch {
    static let shared=ROBWorkspaceSearch()
    struct Call {let map:ROBWorkspaceCollisionSnapshot;let attempted:[ROBWorkspaceView]}
    var calls:[Call]=[]
    var mode="normal"
    var duringCapture:(() -> Void)?
    let views=[ROBWorkspaceView(panDegrees:-60,upperTarget:5300),.init(panDegrees:-20,upperTarget:5450)]
    func reset() {calls=[];mode="normal";duringCapture=nil}
    func captureBlockerCoverage(blocker:ROBWorkspaceUnknownCellBlocker,
        continuing snapshot:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,generation:UInt64,
        attempted:[ROBWorkspaceView],deadlineUptime:Double,check:() throws ->Void,progress:(String)->Void)
        async throws ->(snapshot:ROBWorkspaceCollisionSnapshot,view:ROBWorkspaceView)? {
        precondition(blocker.link=="right_five_Link" && blocker.voxel.x == -4)
        precondition(generation==1 && deadlineUptime>ProcessInfo.processInfo.systemUptime)
        precondition(attempted==Array(views.prefix(calls.count)),"Recovery repeated a view or lost attempt history")
        try check();calls.append(.init(map:snapshot,attempted:attempted))
        if mode=="no_view" {return nil}
        progress("Inert capture of distinct view")
        await Task.yield()
        duringCapture?()
        if mode=="check_during_capture" {try check()}
        var next=snapshot
        next.observedFrameCount+=1;next.lastCapturedAtMilliseconds+=100
        next.fingerprint="captured-\(calls.count)"
        switch mode {
        case "scene":next.sceneID=UUID()
        case "camera":next.cameraGeneration=UUID()
        case "session":next.sessionGeneration+=1
        case "body":next.bodyMotionIdentity="other-body"
        case "projection":next.estimatedCameraProjectionIdentity="other-projection"
        case "no_frames":next.observedFrameCount=snapshot.observedFrameCount
        case "fewer_frames":next.observedFrameCount=snapshot.observedFrameCount-1
        case "same_time":next.lastCapturedAtMilliseconds=snapshot.lastCapturedAtMilliseconds
        case "old_time":next.lastCapturedAtMilliseconds=snapshot.lastCapturedAtMilliseconds-1
        default:break
        }
        return(next,views[calls.count-1])
    }
}

@MainActor final class Harness {
    var lastRecordingPath="",collisionReviewStatus:NSDictionary=[:]
    var localReceiptCommand:String?="right_recycle_cans",inactiveWorkspaceSearch=true,leased=false,positionReady=false
    var leaseRenewals:[Int]=[],armTravelDispatched=false,jawCommandDispatched=false,jawSetupDispatchUncertain=false
    var recyclingGripDispatched=false,servoPossiblePayloadUncertain=false,cameraReady=true
    var localReceiptHeldNeckIdentity:String?="previous-neck",phase="initial"
    var generation:UInt64=1,vision=Vision()
    var collisionMap:ROBWorkspaceCollisionSnapshot?,collisionModel:ROBGhostRobotModel?,collisionReviewProposal:String?="old-proof"
    var stopped=false,contextLost=false,trialAvailable=true,q=Array(repeating:0.0,count:7)
    var reviewResults=["unknown","pass"],reviewedMaps:[String]=[],reviewedBaselines:[[Double]]=[]
    var updates:[String]=[],publishedMaps:[String]=[],checks=0,measurements=0
    func check()throws {
        checks+=1
        if stopped {throw ROBArmRoutineError.blocked("Stop active")}
        if contextLost {throw ROBArmRoutineError.blocked("Context lost")}
    }
    func measured()throws->Sample {measurements+=1;return .init(positionsRadians:q.map{NSNumber(value:$0)})}
    func visualTrial(map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,baseline:[Double])throws->ROBWorkspaceVisualCalibrationTrial? {
        trialAvailable ? .init(mapFingerprint:map.fingerprint,baseline:baseline):nil
    }
    func reviewInitialLocalRetreat(map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,baseline:[Double],
        goal:[Double],trial:ROBWorkspaceVisualCalibrationTrial,generation:UInt64,camera:UUID,now:Double,
        measuredAt:Double,sequence:UInt64,emptySource:String,stage:String)
        async throws->ROBWorkspaceInitialEmptyRetreat {
        precondition(stage=="before_stationary_mode_preparation" && generation==1 && sequence==100)
        precondition(now-measuredAt==1 && emptySource=="local_first_attempt_no_arm_travel_or_task_grip")
        precondition(trial.mapFingerprint==map.fingerprint && trial.baseline==baseline)
        precondition(zip(baseline,goal).enumerated().allSatisfy {index,pair in
            abs((pair.1-pair.0)-(index==1 ? -0.075:0))<1e-12
        })
        reviewedMaps.append(map.fingerprint);reviewedBaselines.append(baseline)
        let result=reviewResults.count>1 ? reviewResults.removeFirst():reviewResults[0]
        if result=="unknown" {throw ROBArmRoutineError.blocked(unknownDetail)}
        if result=="occupied" {throw ROBArmRoutineError.blocked(occupiedDetail)}
        return .init(mapFingerprint:map.fingerprint,baseline:baseline)
    }
    func update(_ detail:String) {updates.append(detail)}
    func publishCollisionReview(map:ROBWorkspaceCollisionSnapshot,detail:String) {publishedMaps.append(map.fingerprint)}
    __ACTUAL_RECOVERY__
    func run(_ map:ROBWorkspaceCollisionSnapshot = .init())async throws
        ->(map:ROBWorkspaceCollisionSnapshot,trial:ROBWorkspaceVisualCalibrationTrial,proof:ROBWorkspaceInitialEmptyRetreat) {
        try await reviewInitialRetreatWithCoverage(map:map,model:.init(),initialBaseline:Array(repeating:0,count:7),
            offset:[0,-0.075,0,0,0,0,0],emptySource:"local_first_attempt_no_arm_travel_or_task_grip")
    }
}

@main enum CoverageRecoveryFixtures {
    @MainActor static func fresh()->Harness {ROBWorkspaceSearch.shared.reset();return Harness()}
    @MainActor static func rejected(_ harness:Harness,contains:String)async {
        do {_=try await harness.run();preconditionFailure("Rejected recovery returned a proof")}
        catch {precondition(error.localizedDescription.contains(contains),error.localizedDescription)}
    }
    @MainActor static func main()async throws {
        let service=ROBWorkspaceSearch.shared
        let initial=fresh();initial.reviewResults=["pass"]
        let original=try await initial.run()
        precondition(original.map.fingerprint=="original" && initial.reviewedMaps==["original"] && service.calls.isEmpty)

        let recovered=fresh();let result=try await recovered.run()
        precondition(recovered.reviewedMaps==["original","captured-1"] && service.calls.count==1)
        precondition(result.map.fingerprint=="captured-1" && result.trial.mapFingerprint=="captured-1" && result.proof.mapFingerprint=="captured-1")
        precondition(result.map.voxelState == .unknown,"Capture fixture invented free space")
        precondition(recovered.collisionMap?.fingerprint=="captured-1" && recovered.collisionReviewProposal==nil)
        precondition(recovered.publishedMaps==["captured-1"] && !recovered.cameraReady && recovered.localReceiptHeldNeckIdentity==nil)

        let persistent=fresh();persistent.reviewResults=["unknown"]
        await rejected(persistent,contains:"unobserved space")
        precondition(persistent.reviewedMaps==["original","captured-1","captured-2"] && service.calls.count==2)
        precondition(service.calls.map{$0.attempted.count}==[0,1] && persistent.publishedMaps.count==2)

        let occupied=fresh();occupied.reviewResults=["occupied"]
        await rejected(occupied,contains:"observed obstacle")
        precondition(service.calls.isEmpty && occupied.reviewedMaps==["original"])

        let unavailable=fresh();service.mode="no_view"
        await rejected(unavailable,contains:"unobserved space")
        precondition(service.calls.count==1 && unavailable.reviewedMaps==["original"] && unavailable.publishedMaps.isEmpty)

        for condition in ["stop_after_capture","context_after_capture","stop_callback","context_callback"] {
            let interrupted=fresh()
            if condition.hasSuffix("callback") {service.mode="check_during_capture"}
            service.duringCapture={
                if condition.hasPrefix("stop") {interrupted.stopped=true}else{interrupted.contextLost=true}
            }
            await rejected(interrupted,contains:condition.hasPrefix("stop") ? "Stop active":"Context lost")
            precondition(service.calls.count==1 && interrupted.reviewedMaps==["original"])
            precondition(interrupted.collisionMap==nil && interrupted.publishedMaps.isEmpty,"Interrupted capture reached another review")
        }

        for flag in ["receipt","workspace_active","leased","position_mode","renewal","arm","jaw","jaw_uncertain","grip","payload"] {
            let ineligible=fresh()
            switch flag {
            case "receipt":ineligible.localReceiptCommand=nil
            case "workspace_active":ineligible.inactiveWorkspaceSearch=false
            case "leased":ineligible.leased=true
            case "position_mode":ineligible.positionReady=true
            case "renewal":ineligible.leaseRenewals=[1]
            case "arm":ineligible.armTravelDispatched=true
            case "jaw":ineligible.jawCommandDispatched=true
            case "jaw_uncertain":ineligible.jawSetupDispatchUncertain=true
            case "grip":ineligible.recyclingGripDispatched=true
            case "payload":ineligible.servoPossiblePayloadUncertain=true
            default:preconditionFailure()
            }
            await rejected(ineligible,contains:"unobserved space")
            precondition(service.calls.isEmpty && ineligible.reviewedMaps==["original"],"Ineligible state started neck fallback: \(flag)")
        }

        let drift=fresh();drift.q[0]=0.003
        await rejected(drift,contains:"arm changed")
        precondition(drift.reviewedMaps.isEmpty && service.calls.isEmpty)
        let laterDrift=fresh();service.duringCapture={laterDrift.q[0]=0.003}
        await rejected(laterDrift,contains:"arm changed")
        precondition(laterDrift.reviewedMaps==["original"] && service.calls.count==1)

        for changed in ["scene","camera","session","body","projection","no_frames","fewer_frames","same_time","old_time"] {
            let changedCapture=fresh();service.mode=changed
            await rejected(changedCapture,contains:"changed its scene or failed to add original observations")
            precondition(changedCapture.reviewedMaps==["original"] && service.calls.count==1)
            precondition(changedCapture.collisionMap==nil && changedCapture.publishedMaps.isEmpty,"Changed/stale capture published: \(changed)")
        }

        let lostTrial=fresh();lostTrial.trialAvailable=false
        await rejected(lostTrial,contains:"lost the exact local visual-trial scope")
        precondition(lostTrial.reviewedMaps.isEmpty && service.calls.isEmpty)
        let stoppedInitially=fresh();stoppedInitially.stopped=true
        await rejected(stoppedInitially,contains:"Stop active")
        precondition(stoppedInitially.reviewedMaps.isEmpty && service.calls.isEmpty)
        print("PASS actual preflight coverage recovery: full fresh-map re-review; two distinct view cap; occupied/no-view/Stop/context/eligibility/drift/stale-frame failures; no actuator interfaces or fabricated free space")
    }
}
'''


def main():
    trial = (ROOT / "Cerebro/ROBLeftArmTrial.swift").read_text()
    depth = (ROOT / "Cerebro/ROBWorkspaceDepthMap.swift").read_text()
    recovery = block(trial, "@MainActor private func reviewInitialRetreatWithCoverage(")
    blocker = block(depth, "struct ROBWorkspaceUnknownCellBlocker {")
    for forbidden in ["prepareCameraAndMode(", "commandJaw(", "gateway.", "move(", "activateArm("]:
        assert forbidden not in recovery, f"Coverage recovery gained actuator dispatch: {forbidden}"
    source = FIXTURE.replace("__ACTUAL_RECOVERY__", recovery).replace("__ACTUAL_BLOCKER__", blocker)
    with tempfile.TemporaryDirectory(prefix="rob-coverage-recovery-") as folder:
        folder = Path(folder)
        swift = folder / "Fixture.swift"
        binary = folder / "fixture"
        swift.write_text(source)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                        str(swift), "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == "__main__":
    main()
