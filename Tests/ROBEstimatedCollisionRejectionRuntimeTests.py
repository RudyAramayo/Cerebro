#!/usr/bin/env python3
"""Run the actual post-export publication guard without UI or robot services."""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Cerebro/ROBLeftArmTrial.swift').read_text()
start=source.index('                    let mayPublish:Bool',source.index('catch let rejection as ROBEstimatedArmCollisionRejection'))
last='                    throw rejection'
end=source.index(last,start)+len(last)
block=source[start:end]
fixture=r'''
import Foundation
struct ROBGhostRobotModel {}
struct ROBWorkspaceCollisionSnapshot {var cameraGeneration:UUID;var bodyMotionIdentity:String}
@MainActor enum ROBFixedHeadBodyMotionIdentity {static var currentIdentity="body-A"}
@MainActor final class ROBWorkspaceSearch {
    static let shared=ROBWorkspaceSearch();var current=true
    func estimatedCameraProjectionIsCurrent(model:ROBGhostRobotModel,map:ROBWorkspaceCollisionSnapshot)->Bool {current}
}
@MainActor final class Vision {var cameraGeneration=UUID()}
enum Failure:LocalizedError {case original,export,cancelled;var errorDescription:String? {String(describing:self)}}
@MainActor final class ActualPostExport {
    var owner:UUID?=UUID(),activeCommand="left_estimated_preview",generation:UInt64=1
    let vision=Vision();var shouldStop=false,checks=0,published:[String]=[]
    var collisionReviewStatus:NSDictionary=[:]
    func check()throws {checks+=1;if shouldStop {throw Failure.cancelled}}
    func publishCollisionReview(map:ROBWorkspaceCollisionSnapshot,detail:String,blocked:Bool) {
        precondition(blocked);published.append(detail);collisionReviewStatus=["detail":detail]
    }
    func finish(rejectionOwner:UUID?,current:UInt64,map:ROBWorkspaceCollisionSnapshot,
        model:ROBGhostRobotModel,exportResult:Result<URL,Error>)throws {
        let rejection=Failure.original
/* ACTUAL_GUARD */
    }
}
@main enum Fixtures {
    @MainActor static func main() {
        let model=ROBGhostRobotModel(),path=URL(fileURLWithPath:"/private/tmp/diagnostic/rejection.json")
        func exercise(_ mutate:(ActualPostExport,inout ROBWorkspaceCollisionSnapshot)->Void,expectedPublications:Int,failedExport:Bool=false) {
            let target=ActualPostExport(),owner=target.owner
            ROBFixedHeadBodyMotionIdentity.currentIdentity="body-A";ROBWorkspaceSearch.shared.current=true
            var map=ROBWorkspaceCollisionSnapshot(cameraGeneration:target.vision.cameraGeneration,bodyMotionIdentity:"body-A")
            mutate(target,&map)
            do {
                try target.finish(rejectionOwner:owner,current:1,map:map,model:model,
                    exportResult:failedExport ? .failure(Failure.export):.success(path))
                preconditionFailure("Collision rejection became successful completion")
            }catch {precondition(error as? Failure == .original,"Diagnostic publication replaced the original rejection")}
            precondition(target.checks==1 && target.published.count==expectedPublications)
            if expectedPublications==1 && !failedExport {precondition(target.collisionReviewStatus["rejection_evidence_path"]as?String==path.path)}
        }
        exercise({_,_ in},expectedPublications:1)
        exercise({_,_ in},expectedPublications:1,failedExport:true)
        exercise({target,_ in target.shouldStop=true},expectedPublications:0)
        exercise({target,_ in target.shouldStop=true},expectedPublications:0,failedExport:true)
        exercise({target,_ in target.owner=UUID()},expectedPublications:0)
        exercise({target,_ in target.owner=nil},expectedPublications:0)
        exercise({target,_ in target.activeCommand="right_estimated_preview"},expectedPublications:0)
        exercise({target,_ in target.generation=2},expectedPublications:0)
        exercise({target,_ in target.vision.cameraGeneration=UUID()},expectedPublications:0)
        exercise({_,_ in ROBFixedHeadBodyMotionIdentity.currentIdentity="body-B"},expectedPublications:0)
        exercise({_,_ in ROBWorkspaceSearch.shared.current=false},expectedPublications:0)
        print("Collision rejection publication runtime passed: fresh success/failure publish; Stop, owner/command/session/camera/body/projection changes suppress both paths; original rejection preserved, no actuator/approval services linked")
    }
}
'''.replace('/* ACTUAL_GUARD */',block)
with tempfile.TemporaryDirectory(prefix='rob-collision-rejection-runtime-',dir='/private/tmp')as directory:
    root=Path(directory);swift=root/'Fixture.swift';binary=root/'fixture'
    swift.write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
