#!/usr/bin/env python3
"""Compile actual production multi-can tracking and reach selection without devices."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    index = brace + 1
    while depth:
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
    return source[start:index]


STUBS = r'''
import Foundation
import simd
struct ROBWorkspaceView: Codable { let panDegrees:Double; let upperTarget:Int }
struct ROBWorkspaceCanSections: Codable { let valid:Bool; let heightMeters:Double; let diameterMeters:Double }
final class ROBGhostRobotModel {
    var physicalSide="right", modelID="model", geometryID="geometry", selectedMappingID="mapping"
    var projection:String?="projection"
    func frames(_ baseline:[String:Double])->[String:simd_double4x4] {
        var left=matrix_identity_double4x4,right=matrix_identity_double4x4
        left.columns.3=SIMD4(0,0.3,1,1);right.columns.3=SIMD4(0,-0.3,1,1)
        return ["left_two_Link":left,"right_two_Link":right]
    }
}
struct ROBWorkspaceDepthObservation { let sequence:UInt64; let capturedAtMilliseconds:Double; var registrationID:String?=nil }
struct ROBWorkspaceCollisionSnapshot {
    var sceneID:UUID; var modelID="model",geometryID="geometry",mappingID="mapping"
    var sessionGeneration:UInt64=1; var cameraGeneration:UUID; var bodyMotionIdentity="body"
    var estimatedCameraProjectionIdentity:String?="projection";var registrationID:String?=nil
    var observations:[ROBWorkspaceDepthObservation]
}
enum ROBFixedHeadBodyMotionIdentity { static var currentIdentity="body" }
final class ROBArmRoutineVision { static let shared=ROBArmRoutineVision();var cameraGeneration=UUID() }
final class ROBAmberGatewayClient {
    static let shared=ROBAmberGatewayClient();var generation:UInt64=1
    func connectionSnapshot()->[String:Any] { ["sessionGeneration":NSNumber(value:generation)] }
}
struct ROBCanGrabPreview {
    let reachesCan:Bool;let graspError:Double;let gripperTiltDegrees:Double;let helpRequest:String?
    static var calls:[ROBWorkspaceLocatedObject]=[];static var hook:(()->Void)?
    static func make(can:ROBWorkspaceLocatedObject,model:ROBGhostRobotModel,baseline:[String:Double],side:String,
                     now:Double,reachOffset:SIMD3<Double>) throws -> Self {
        precondition(side==model.physicalSide)
        calls.append(can);hook?()
        if can.position[2]>1.2 {throw NSError(domain:"fixture preview unavailable",code:1)}
        let far=can.position[0]>0.8,orientation=can.position[2]>1.0
        return .init(reachesCan:!far && !orientation,graspError:far ? 0.04 : 0.001,
            gripperTiltDegrees:orientation ? 12 : 0,helpRequest:far ? "bring closer" : nil)
    }
}
enum ROBLeftCanReachCalibration {
    static func load(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,file:URL?,estimatedCameraProjectionIdentity:String?) throws->SIMD3<Double> { .zero }
}
'''

FIXTURE = r'''
@MainActor final class SearchFixture {
    var canCandidates=ROBWorkspaceCanCandidateSet()
    var collisionSnapshot:ROBWorkspaceCollisionSnapshot?
    func estimatedCameraProjectionIsCurrent(model:ROBGhostRobotModel,map:ROBWorkspaceCollisionSnapshot)->Bool {
        model.projection==map.estimatedCameraProjectionIdentity
    }
    __PRODUCTION_SELECTION__
}
@main struct CanCandidatesFixture {
    @MainActor static func main() async {
        let now=Date().timeIntervalSince1970*1000
        let camera=UUID(),scene=UUID()
        let context=ROBWorkspaceCanSceneIdentity(sceneID:scene,cameraGeneration:camera,sessionGeneration:1,
            bodyMotionIdentity:"body",modelID:"model",geometryID:"geometry",mappingID:"mapping",estimatedCameraProjectionIdentity:"projection")
        func object(_ x:Double,_ y:Double=0,_ z:Double=0.9,seq:UInt64=1,time:Double?=nil,confidence:Double=0.9,
                    valid:Bool=true,height:Double=0.12)->ROBWorkspaceLocatedObject {
            .init(target:.can,position:[x,y,z],confidence:confidence,capturedAt:time ?? now-2000+Double(seq)*100,
                sequence:seq,view:.init(panDegrees:0,upperTarget:6000),sections:.init(valid:valid,heightMeters:height,diameterMeters:0.065))
        }
        // Repeated detector boxes in one image never supply two confirmations.
        var candidates=ROBWorkspaceCanCandidateSet()
        candidates.observe([object(0.45),object(0.46,confidence:0.8),object(1.2,confidence:0.99)],context:context,nowMilliseconds:now)
        precondition(candidates.confirmed(nowMilliseconds:now).isEmpty)
        candidates.observe([object(0.451,seq:2,confidence:0.4),object(0.46,seq:2,confidence:0.35),object(1.201,seq:2,confidence:0.99)],context:context,nowMilliseconds:now)
        precondition(candidates.confirmed(nowMilliseconds:now).count==2)
        let originalTimes=candidates.confirmed(nowMilliseconds:now).map(\.capturedAt).sorted()
        candidates.observe([object(0.451,seq:2,time:now-1),object(1.201,seq:1,time:now-1)],context:context,nowMilliseconds:now)
        precondition(candidates.confirmed(nowMilliseconds:now).map(\.capturedAt).sorted()==originalTimes,"reordered/duplicate frames restamped candidates")
        // A frame that sees only the other object must not freshen occluded cans.
        candidates.observe([object(1.2,seq:3)],context:context,nowMilliseconds:now)
        precondition(candidates.confirmed(nowMilliseconds:now).first(where:{$0.position[0]<0.8})!.sequence==2)
        precondition(candidates.confirmed(nowMilliseconds:now+61_000).isEmpty)
        // Every scene/source/body/model/mapping/context replacement loses prior confirmations.
        for changed in 0..<9 {
            let next=ROBWorkspaceCanSceneIdentity(sceneID:changed==0 ? UUID():scene,cameraGeneration:changed==1 ? UUID():camera,
                sessionGeneration:changed==2 ? 2:1,bodyMotionIdentity:changed==3 ? "other":"body",modelID:changed==4 ? "other":"model",
                geometryID:changed==5 ? "other":"geometry",mappingID:changed==6 ? "other":"mapping",
                estimatedCameraProjectionIdentity:changed==7 ? "other":changed==8 ? nil:"projection")
            var copy=candidates;copy.observe([object(0.45,seq:4)],context:next,nowMilliseconds:now)
            precondition(copy.confirmed(nowMilliseconds:now).isEmpty)
        }
        // Sections and per-instance geometry confirmation remain mandatory.
        var shape=ROBWorkspaceCanCandidateSet()
        shape.observe([object(0.5),object(0.7,valid:false)],context:context,nowMilliseconds:now)
        shape.observe([object(0.501,seq:2,height:0.15)],context:context,nowMilliseconds:now)
        precondition(shape.confirmed(nowMilliseconds:now).isEmpty)
        shape.observe([object(0.501,seq:3,height:0.15)],context:context,nowMilliseconds:now)
        precondition(shape.confirmed(nowMilliseconds:now).count==1)
        let model=ROBGhostRobotModel(),search=SearchFixture()
        ROBArmRoutineVision.shared.cameraGeneration=camera
        func enroll(_ points:[ROBWorkspaceLocatedObject]) {
            var set=ROBWorkspaceCanCandidateSet()
            set.observe(points,context:context,nowMilliseconds:now)
            let second=points.map {p in object(p.position[0],p.position[1],p.position[2],seq:2,confidence:p.confidence)}
            set.observe(second,context:context,nowMilliseconds:now);search.canCandidates=set
            search.collisionSnapshot = .init(sceneID:scene,cameraGeneration:camera,
                observations:second.map{.init(sequence:$0.sequence,capturedAtMilliseconds:$0.capturedAt)})
            ROBCanGrabPreview.calls=[];ROBCanGrabPreview.hook=nil
        }

        // A measured map's aggregate hash differs from each exact source registration.
        // Bind all three fields to ONE observation, never unrelated map entries.
        var measuredFirst=object(0.45),measuredSecond=object(0.45,seq:2)
        measuredFirst.registrationID="individual-registration-A";measuredSecond.registrationID="individual-registration-A"
        var measuredCandidates=ROBWorkspaceCanCandidateSet()
        measuredCandidates.observe([measuredFirst],context:context,nowMilliseconds:now)
        measuredCandidates.observe([measuredSecond],context:context,nowMilliseconds:now)
        search.canCandidates=measuredCandidates
        var measuredMap=ROBWorkspaceCollisionSnapshot(sceneID:scene,cameraGeneration:camera,
            registrationID:"fixed-head-map-aggregate-SHA",observations:[
                .init(sequence:2,capturedAtMilliseconds:measuredSecond.capturedAt,registrationID:"individual-registration-A"),
                .init(sequence:9,capturedAtMilliseconds:now-100,registrationID:"individual-registration-B")])
        search.collisionSnapshot=measuredMap;ROBCanGrabPreview.calls=[]
        var measuredResult=await search.nearestReachableCan(model:model,baseline:[:],map:measuredMap,nowMilliseconds:now)
        precondition(measuredResult.object?.registrationID=="individual-registration-A" && ROBCanGrabPreview.calls.count==1,
                     "Aggregate map registration incorrectly discarded its exactly matched individual observation")
        measuredMap.observations=[
            .init(sequence:2,capturedAtMilliseconds:measuredSecond.capturedAt,registrationID:"individual-registration-B"),
            .init(sequence:9,capturedAtMilliseconds:now-100,registrationID:"individual-registration-A")]
        search.collisionSnapshot=measuredMap;ROBCanGrabPreview.calls=[]
        measuredResult=await search.nearestReachableCan(model:model,baseline:[:],map:measuredMap,nowMilliseconds:now)
        precondition(measuredResult.object==nil && ROBCanGrabPreview.calls.isEmpty,
                     "Registration from a different source observation admitted the can")
        measuredMap.registrationID="individual-registration-A"
        search.collisionSnapshot=measuredMap
        measuredResult=await search.nearestReachableCan(model:model,baseline:[:],map:measuredMap,nowMilliseconds:now)
        precondition(measuredResult.object==nil,"An equal aggregate ID substituted for the wrong exact source registration")
        for mismatch in ["registration","sequence","timestamp"] {
            let sequence:UInt64=mismatch=="sequence" ? 3:2
            let captured=measuredSecond.capturedAt+(mismatch=="timestamp" ? 1:0)
            measuredMap.observations=[.init(sequence:sequence,capturedAtMilliseconds:captured,
                registrationID:mismatch=="registration" ? nil:"individual-registration-A")]
            search.collisionSnapshot=measuredMap
            measuredResult=await search.nearestReachableCan(model:model,baseline:[:],map:measuredMap,nowMilliseconds:now)
            precondition(measuredResult.object==nil,"Measured registration mixed across an unmatched source field")
        }
        // The unregistered lane retains its exact nil/nil source contract.
        enroll([object(0.45)])
        var unregisteredResult=await search.nearestReachableCan(model:model,baseline:[:],map:search.collisionSnapshot!,nowMilliseconds:now)
        precondition(unregisteredResult.object?.registrationID==nil && unregisteredResult.object != nil)
        var wrongSourceMap=search.collisionSnapshot!
        wrongSourceMap.observations=wrongSourceMap.observations.map{.init(sequence:$0.sequence,
            capturedAtMilliseconds:$0.capturedAtMilliseconds,registrationID:"individual-registration-A")}
        search.collisionSnapshot=wrongSourceMap
        unregisteredResult=await search.nearestReachableCan(model:model,baseline:[:],map:wrongSourceMap,nowMilliseconds:now)
        precondition(unregisteredResult.object==nil,"Unregistered can inherited a measured source registration")

        // A lower-confidence nearby reachable can beats the distant high-confidence can.
        enroll([object(1.2,confidence:0.99),object(0.45,confidence:0.4)])
        var result=await search.nearestReachableCan(model:model,baseline:[:],map:search.collisionSnapshot!,nowMilliseconds:now)
        precondition(result.object!.position[0]==0.45 && ROBCanGrabPreview.calls.count==1)
        precondition(result.diagnostics.last!["path_admitted"] as? Bool==false)
        // Skip a nearer orientation-only failure, and an unavailable preview, rather than ask the human.
        enroll([object(0.2,0,1.1),object(0.3,0,1.3),object(0.55,confidence:0.4),object(1.1,confidence:0.99)])
        result=await search.nearestReachableCan(model:model,baseline:[:],map:search.collisionSnapshot!,nowMilliseconds:now)
        precondition(result.object!.position[0]==0.55 && ROBCanGrabPreview.calls.count==3)
        precondition(result.diagnostics.contains{$0["status"] as? String=="skipped_unreachable"})
        precondition(result.diagnostics.contains{$0["status"] as? String=="skipped_preview_unavailable"})
        // Physical-arm shoulder ranking, rather than one torso-wide confidence choice.
        enroll([object(0.5,0.3),object(0.5,-0.3)])
        model.physicalSide="left"
        result=await search.nearestReachableCan(model:model,baseline:[:],map:search.collisionSnapshot!,nowMilliseconds:now)
        precondition(result.object!.position[1]==0.3)
        model.physicalSide="right"
        result=await search.nearestReachableCan(model:model,baseline:[:],map:search.collisionSnapshot!,nowMilliseconds:now)
        precondition(result.object!.position[1]==(-0.3))
        // Source observations are mandatory; no map evidence is synthesized for a can.
        var wrongMap=search.collisionSnapshot!;wrongMap.observations=[]
        result=await search.nearestReachableCan(model:model,baseline:[:],map:wrongMap,nowMilliseconds:now)
        precondition(result.object==nil)
        wrongMap=search.collisionSnapshot!;wrongMap.sceneID=UUID()
        result=await search.nearestReachableCan(model:model,baseline:[:],map:wrongMap,nowMilliseconds:now)
        precondition(result.object==nil)
        // Body/source/gateway/projection invalidation before and DURING the asynchronous preview.
        for key in ["body","camera","gateway","projection"] {
            enroll([object(0.45)])
            if key=="body" {ROBFixedHeadBodyMotionIdentity.currentIdentity="changed"}
            if key=="camera" {ROBArmRoutineVision.shared.cameraGeneration=UUID()}
            if key=="gateway" {ROBAmberGatewayClient.shared.generation=2}
            if key=="projection" {model.projection="changed"}
            result=await search.nearestReachableCan(model:model,baseline:[:],map:search.collisionSnapshot!,nowMilliseconds:now)
            precondition(result.object==nil && ROBCanGrabPreview.calls.isEmpty)
            ROBFixedHeadBodyMotionIdentity.currentIdentity="body";ROBArmRoutineVision.shared.cameraGeneration=camera
            ROBAmberGatewayClient.shared.generation=1;model.projection="projection"
        }
        enroll([object(0.45)]);ROBCanGrabPreview.hook={ROBFixedHeadBodyMotionIdentity.currentIdentity="moved-during-solver"}
        result=await search.nearestReachableCan(model:model,baseline:[:],map:search.collisionSnapshot!,nowMilliseconds:now)
        precondition(result.object==nil && ROBCanGrabPreview.calls.count==1)
        print("PASS actual multi-can tracker/selector: independent two-exposure confirmation, duplicate/reordered/occluded timestamps, shape gates, nine scene contexts, nearest physical-arm ranking, unreachable/unavailable skipping, exact per-observation measured/aggregate registration and nil/nil source map evidence, and asynchronous context invalidation; no motion admission")
    }
}
'''


def main():
    vision = (ROOT / 'Cerebro/ROBArmRoutineVision.swift').read_text()
    plan = (ROOT / 'Cerebro/ROBWorkspaceSearchPlan.swift').read_text()
    selection = block(vision, '@MainActor @nonobjc func nearestReachableCan(').replace('@MainActor @nonobjc', '@MainActor')
    actual = '\n'.join(block(vision, marker) for marker in [
        'struct ROBWorkspaceCanSceneIdentity:', 'struct ROBWorkspaceCanCandidateSet {', 'struct ROBWorkspaceCanSelection {'])
    actual += '\n' + block(plan, 'enum ROBWorkspaceTarget:')
    actual += '\n' + block(plan, 'struct ROBWorkspaceLocatedObject:')
    actual += '\n' + block(plan, 'struct ROBWorkspaceLocationConfirmation {')
    run = vision[vision.index('@MainActor @nonobjc func run(targets:'):]
    assert run.index('try await accumulateCollisionDepth(view,capturedFrame:sourceFrame)') < run.index('confirmedCanCandidates.observe(')
    assert 'confirmedCanCandidates.observe(candidates.map(\\.object)' in run
    assert 'canCandidates = confirmedCanCandidates' in run
    assert 'canCandidates = ROBWorkspaceCanCandidateSet()' in run
    assert 'recordedPanDegrees:view.panDegrees,recordedUpperTarget:view.upperTarget' in run
    assert 'recordedLowerTarget:measured?.scope.lowerTarget ?? estimated?.lowerTarget' in run
    assert 'estimatedCameraProjectionIdentity:estimated?.identity' in run
    assert 'candidates.max(by:{ $0.object.confidence < $1.object.confidence })' in run, 'ordinary single-object compatibility changed'
    source = STUBS + '\n' + actual + '\n' + FIXTURE.replace('__PRODUCTION_SELECTION__', selection)
    with tempfile.TemporaryDirectory(prefix='rob-can-candidates-') as folder:
        path = Path(folder)
        swift = path / 'CanCandidates.swift'
        binary = path / 'fixture'
        swift.write_text(source)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                        '-module-cache-path', '/private/tmp/cerebro-swift-module-cache', str(swift), '-o', str(binary)],
                       check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    main()
