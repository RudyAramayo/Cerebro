#!/usr/bin/env python3
"""Run the production passive estimate capture against saved-value sensor stubs.

Uses the real depth mapper and collision snapshot, no UI, USB, or gateway I/O.
The three WorkspaceSearch methods are extracted verbatim, not reimplemented.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()

def method(name):
    start = source.index('    @MainActor @nonobjc func '+name+'(')
    opening = source.index('{',start)
    depth,end = 1,opening+1
    while depth:
        depth += (source[end]=='{')-(source[end]=='}')
        end += 1
    return source[start:end]

actual = '\n'.join(method(name) for name in (
    'captureEstimatedOrRegisteredCurrentScene','estimatedContextIsCurrent','captureEstimatedCurrentScene'))
fixture = r'''
import Foundation
import simd
final class ROBGhostRobotModel {
    var modelID="model",geometryID="geometry",selectedMappingID="mapping",physicalSide="right",referenceID="reference"
}
struct CameraIntrinsics {
    var fx=30.0,fy=30.0,cx=16.0,cy=12.0
    var cameraServiceSourceSHA256:String?=String(repeating:"c",count:64)
    var rgbOutputUndistorted:Bool?=true
    func isValid(forWidth w:Int,height h:Int)->Bool {fx>0 && fy>0 && cx>=0 && cy>=0 && cx<Double(w) && cy<Double(h)}
}
final class ProjectionRace {
    private let lock=NSLock();private var pending=true
    func fire() {lock.lock();let should=pending;pending=false;lock.unlock();if should {ROBFixedHeadBodyMotionIdentity.invalidate()}}
}
struct CameraDepthFrame {
    var width=32,height=24;var raw:UInt16=1000;var race:ProjectionRace?
    func distanceMillimeters(x:Int,y:Int)->UInt16? {race?.fire();return raw}
}
@MainActor final class ROBArmRoutineVision {
    static let shared=ROBArmRoutineVision()
    struct Frame {var capturedAt:Double;var sequence:UInt64;var depth:CameraDepthFrame?;var intrinsics:CameraIntrinsics?;var cameraGeneration:UUID}
    var cameraGeneration=UUID();var current:Frame?;var requests=0
    var onSample:((Int)->Void)?;var alter:((inout Frame,Int)->Void)?
    func snapshot()->[String:Frame] {current.map{["face":$0]} ?? [:]}
    func settledDepthFrame() async throws->Frame {
        requests+=1;onSample?(requests)
        var frame=Frame(capturedAt:Date().timeIntervalSince1970*1000,sequence:UInt64(requests),depth:CameraDepthFrame(),intrinsics:CameraIntrinsics(),cameraGeneration:cameraGeneration)
        alter?(&frame,requests);current=frame
        return frame
    }
}
struct ROBEstimatedFixedHeadCapture {
    typealias Context=Self
    var scope:ROBFixedHeadRegistrationScope
    var depthHypothesisID=String(repeating:"a",count:64)
    var bodyMotionIdentity:String
    var cameraToModel=matrix_identity_double4x4
    var width=32,height=24,intrinsics=[30.0,30.0,16.0,12.0]
    var correctionAvailable=true
    var cameraServiceSourceSHA256=String(repeating:"c",count:64)
    var rgbOutputUndistorted=true
    var metadata:[String:Any] {["grasp_authorized":false,"measured_registration_verified":false,"id":depthHypothesisID]}
    func matches(currentScope:ROBFixedHeadRegistrationScope,model:ROBGhostRobotModel)->Bool {
        currentScope==scope && model.physicalSide=="right" && model.modelID==scope.modelID && model.geometryID==scope.geometryID &&
        model.selectedMappingID==scope.mappingID && model.referenceID=="reference"
    }
    func correctedMillimeters(raw:UInt16)->UInt16? {correctionAvailable && raw>0 ? 500:nil}
}
@MainActor final class ROBFixedHeadCalibrationWindowController {
    static let shared=ROBFixedHeadCalibrationWindowController()
    var selectedEstimatedContext:ROBEstimatedFixedHeadCapture.Context?
    var currentScope:ROBFixedHeadRegistrationScope!
    var readyAt=0.0;var resolutionFails=false
    var readNeck:(()->NSDictionary)? { { [unowned self] in ["ready_at":self.readyAt] } }
    enum Failure:Error {case missing}
    func scope(model:ROBGhostRobotModel,frame:ROBArmRoutineVision.Frame)throws->ROBFixedHeadRegistrationScope {
        guard !resolutionFails else {throw Failure.missing};return currentScope
    }
    func currentEstimatedContext(model:ROBGhostRobotModel,frame:ROBArmRoutineVision.Frame)throws->ROBEstimatedFixedHeadCapture.Context {
        guard !resolutionFails,let context=selectedEstimatedContext else {throw Failure.missing}
        return context // Actual WorkspaceSearch must independently validate it.
    }
}
@MainActor final class ActualSearch:NSObject {
    var collisionSnapshotValue:ROBWorkspaceCollisionSnapshot?
    var collisionSnapshotModel:ROBGhostRobotModel?
    var lastReport:NSDictionary=[:]
    var registeredCalls=0
    var registeredResult:ROBWorkspaceCollisionSnapshot!
    func captureRegisteredCurrentScene(model:ROBGhostRobotModel,generation:UInt64,check:()throws->Void,progress:(String)->Void)async throws->ROBWorkspaceCollisionSnapshot {
        registeredCalls+=1;try check();return registeredResult
    }
/* ACTUAL_METHODS */
}
@main enum Fixtures {
    @MainActor static func main() async throws {
        let vision=ROBArmRoutineVision.shared,controller=ROBFixedHeadCalibrationWindowController.shared
        var model=ROBGhostRobotModel(),context:ROBEstimatedFixedHeadCapture!,search=ActualSearch()
        func scope(_ old:ROBFixedHeadRegistrationScope,pan:Int?=nil,lower:Int?=nil,upper:Int?=nil,generation:UInt64?=nil)->ROBFixedHeadRegistrationScope {
            .init(modelID:old.modelID,geometryID:old.geometryID,mappingID:old.mappingID,cameraGeneration:old.cameraGeneration,
                gatewaySessionGeneration:generation ?? old.gatewaySessionGeneration,displayCorrectionIdentity:old.displayCorrectionIdentity,
                panTarget:pan ?? old.panTarget,lowerTarget:lower ?? old.lowerTarget,upperTarget:upper ?? old.upperTarget,intrinsicsIdentity:old.intrinsicsIdentity)
        }
        func reset() {
            model=ROBGhostRobotModel();search=ActualSearch();vision.cameraGeneration=UUID();vision.requests=0;vision.onSample=nil;vision.alter=nil
            controller.readyAt=ProcessInfo.processInfo.systemUptime-1;controller.resolutionFails=false
            let body=ROBFixedHeadBodyMotionIdentity.currentIdentity
            let held=ROBFixedHeadRegistrationScope(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                cameraGeneration:vision.cameraGeneration,gatewaySessionGeneration:7,displayCorrectionIdentity:"fixture:body:"+body,
                panTarget:6000,lowerTarget:6495,upperTarget:5900,intrinsicsIdentity:"native-K")
            controller.currentScope=held;context=ROBEstimatedFixedHeadCapture(scope:held,bodyMotionIdentity:body);controller.selectedEstimatedContext=context
            vision.current = .init(capturedAt:Date().timeIntervalSince1970*1000-1,sequence:0,depth:CameraDepthFrame(),intrinsics:CameraIntrinsics(),cameraGeneration:vision.cameraGeneration)
        }
        func capture(_ progress:@escaping(String)->Void={_ in})async throws->ROBWorkspaceCollisionSnapshot {
            try await search.captureEstimatedCurrentScene(model:model,generation:7,context:context,check:{},progress:progress)
        }
        var rejectedCount=0
        func rejects(_ reason:String,mutate:@escaping @MainActor()->Void)async {
            reset();vision.onSample={count in if count==2 {mutate()}}
            do {_=try await capture();fatalError("Admitted \(reason)")} catch {}
            precondition(search.collisionSnapshotValue==nil,"Published partial stale map: \(reason)")
            precondition(search.lastReport["registration_verified"]as?Bool==false,"Failure retained registration status")
            rejectedCount+=1
        }
        reset();var progressCount=0
        let valid=try await capture {_ in progressCount+=1}
        precondition(valid.observedFrameCount==3 && vision.requests==3 && progressCount==3)
        precondition(valid.registrationID==nil && valid.registrationUncertaintyMeters==nil)
        precondition(valid.observations.allSatisfy{$0.estimatedDepthHypothesisID==context.depthHypothesisID && !$0.measuredSelfMaskApplied && $0.fixedHeadScope==context.scope})
        precondition(valid.state(at:SIMD3(0.01,0.01,0.5)) == .occupied,"Corrected return missing")
        precondition(valid.state(at:SIMD3(0.01,0.01,1)) == .occupied,"Raw return missing")
        precondition(valid.state(at:SIMD3(0.01,0.01,0.35)) == .free)
        precondition(valid.state(at:SIMD3(0.01,0.01,0.7)) != .free,"One hypothesis carved behind the other")
        precondition(search.lastReport["grasp_authorized"]as?Bool==false && search.lastReport["registration_verified"]as?Bool==false)
        precondition(search.estimatedContextIsCurrent(model:model,map:valid))
        let validForGuard=valid
        let heldReadyAt=controller.readyAt;controller.readyAt=ProcessInfo.processInfo.systemUptime
        precondition(!search.estimatedContextIsCurrent(model:model,map:validForGuard),"Preview survived neck move-and-return after capture")
        controller.readyAt=heldReadyAt
        func altered(_ change:(inout[String:Any])->Void)throws->ROBWorkspaceCollisionSnapshot {
            var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(validForGuard))as![String:Any]
            change(&value)
            return try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:JSONSerialization.data(withJSONObject:value))
        }
        let registered=try altered{$0["capturedRegistrationID"]="not-an-estimate"}
        precondition(!search.estimatedContextIsCurrent(model:model,map:registered),"Registered map entered estimate lane")
        for field in ["selfmask","hypothesis","matrix","headscope","registered-observation"] {
            let changed=try altered {value in
                var observations=value["observations"]as![[String:Any]]
                switch field {
                case "selfmask":observations[0]["measuredSelfMaskApplied"]=true
                case "hypothesis":observations[0]["estimatedDepthHypothesisID"]=String(repeating:"b",count:64)
                case "matrix":var m=observations[0]["cameraToRobotColumnMajor"]as![Double];m[12]+=0.1;observations[0]["cameraToRobotColumnMajor"]=m
                case "headscope":var s=observations[0]["fixedHeadScope"]as![String:Any];s["upperTarget"]=5901;observations[0]["fixedHeadScope"]=s
                default:observations[0]["registrationID"]="not-an-estimate"
                }
                value["observations"]=observations
            }
            precondition(!search.estimatedContextIsCurrent(model:model,map:changed),"Admitted mixed estimate \(field)")
        }
        controller.currentScope=scope(controller.currentScope,pan:6001)
        precondition(!search.estimatedContextIsCurrent(model:model,map:validForGuard),"Preview survived neck change")
        controller.currentScope=context.scope;controller.selectedEstimatedContext=nil
        precondition(!search.estimatedContextIsCurrent(model:model,map:validForGuard),"Preview survived estimate removal")
        controller.selectedEstimatedContext=context;controller.selectedEstimatedContext!.depthHypothesisID=String(repeating:"b",count:64)
        precondition(!search.estimatedContextIsCurrent(model:model,map:validForGuard),"Preview survived hypothesis replacement")
        controller.selectedEstimatedContext=context;vision.current!.intrinsics!.fx+=1
        precondition(!search.estimatedContextIsCurrent(model:model,map:validForGuard),"Preview survived native-K change")
        vision.current!.intrinsics=CameraIntrinsics();model.referenceID="other"
        precondition(!search.estimatedContextIsCurrent(model:model,map:validForGuard),"Preview survived model-reference change")
        model.referenceID="reference";vision.current!.intrinsics!.cameraServiceSourceSHA256=nil
        precondition(!search.estimatedContextIsCurrent(model:model,map:validForGuard),"Legacy header acquired estimated authority")
        vision.current!.intrinsics=CameraIntrinsics();vision.current!.intrinsics!.rgbOutputUndistorted=false
        precondition(!search.estimatedContextIsCurrent(model:model,map:validForGuard),"Preview accepted distorted pixels")
        reset();context.correctionAvailable=false;controller.selectedEstimatedContext=context
        let rawOnly=try await capture()
        precondition(rawOnly.state(at:SIMD3(0.01,0.01,1)) == .occupied,"Missing correction erased raw")
        precondition(rawOnly.state(at:SIMD3(0.01,0.01,0.35)) == .unknown,"Missing correction carved free")
        reset();vision.alter={frame,count in if count==2 {frame=vision.current!}}
        let duplicates=try await capture()
        precondition(vision.requests==4 && duplicates.observations.map(\.sequence)==[1,3,4],"Duplicate frame counted")
        reset();let retainedStartup=vision.current!
        vision.alter={frame,count in if count<=2 {frame=retainedStartup}}
        let afterRetained=try await capture()
        precondition(vision.requests==5 && afterRetained.observations.map(\.sequence)==[3,4,5],"Retained pre-start pixels failed startup or entered the new map")
        reset();let retainedForStop=vision.current!
        vision.alter={frame,_ in frame=retainedForStop}
        let stopped=Task { @MainActor in try await capture() }
        try await Task.sleep(nanoseconds:120_000_000);stopped.cancel()
        do {_=try await stopped.value;fatalError("Stop published a retained-frame map")}
        catch is CancellationError {} catch {fatalError("Stop did not cancel the retained-frame wait: \(error)")}
        precondition(search.collisionSnapshotValue==nil && vision.requests<20,"Retained-frame Stop spun or retained a map")
        reset();vision.alter={frame,_ in frame.sequence=1}
        let waitingSince=ProcessInfo.processInfo.systemUptime
        do {_=try await capture();fatalError("Nonadvancing stream completed three frames")}catch{}
        let waitingSeconds=ProcessInfo.processInfo.systemUptime-waitingSince
        precondition(waitingSeconds<18 && vision.requests>=3 && vision.requests<400,"Nonadvancing capture lost its bounded/yielding wait")
        precondition(search.collisionSnapshotValue==nil,"Nonadvancing capture published a partial map")
        await rejects("pan drift") {controller.currentScope=scope(controller.currentScope,pan:6001)}
        await rejects("lower drift") {controller.currentScope=scope(controller.currentScope,lower:6496)}
        await rejects("upper drift") {controller.currentScope=scope(controller.currentScope,upper:5901)}
        await rejects("gateway restart") {controller.currentScope=scope(controller.currentScope,generation:8)}
        await rejects("model geometry change") {model.geometryID="other"}
        await rejects("arm mapping change") {model.selectedMappingID="left"}
        await rejects("wrong physical side") {model.physicalSide="left"}
        await rejects("camera restart") {vision.cameraGeneration=UUID()}
        await rejects("body movement") {ROBFixedHeadBodyMotionIdentity.invalidate()}
        await rejects("neck moved and returned to identical raw targets") {controller.readyAt+=1}
        for reason in ["stale frame","native K drift","depth geometry drift","sequence reversal","timestamp reversal","legacy worker header","worker source swap","distorted output","missing output contract"] {
            reset();vision.alter={frame,count in guard count==2 else{return}
                switch reason {
                case "stale frame":frame.capturedAt-=801
                case "native K drift":frame.intrinsics!.fx+=1
                case "depth geometry drift":frame.depth!.width+=2
                case "sequence reversal":frame.sequence=0
                case "legacy worker header":frame.intrinsics!.cameraServiceSourceSHA256=nil
                case "worker source swap":frame.intrinsics!.cameraServiceSourceSHA256=String(repeating:"d",count:64)
                case "distorted output":frame.intrinsics!.rgbOutputUndistorted=false
                case "missing output contract":frame.intrinsics!.rgbOutputUndistorted=nil
                default:frame.capturedAt=vision.current!.capturedAt-1
                }
            }
            do {_=try await capture();fatalError("Admitted \(reason)")}catch{}
            precondition(search.collisionSnapshotValue==nil);rejectedCount+=1
        }
        reset();let race=ProjectionRace();vision.alter={frame,_ in frame.depth!.race=race}
        do {_=try await capture();fatalError("Body changed during projection")}catch{}
        precondition(search.collisionSnapshotValue==nil);rejectedCount+=1
        reset()
        do {_=try await capture {_ in ROBFixedHeadBodyMotionIdentity.invalidate()};fatalError("Progress invalidated body")}catch{}
        precondition(search.collisionSnapshotValue==nil);rejectedCount+=1
        reset();context.depthHypothesisID="prefixed-"+String(repeating:"a",count:64)
        do {_=try await capture();fatalError("Non64hex identity admitted")}catch{}
        precondition(vision.requests==0);rejectedCount+=1
        reset();controller.selectedEstimatedContext=nil;search.registeredResult=valid
        _=try await search.captureEstimatedOrRegisteredCurrentScene(model:model,generation:7,check:{},progress:{_ in})
        precondition(search.registeredCalls==1 && vision.requests==0,"No selected estimate changed ordinary registered path")
        reset();let wrapped=try await search.captureEstimatedOrRegisteredCurrentScene(model:model,generation:7,check:{},progress:{_ in})
        precondition(search.registeredCalls==0 && vision.requests==4 && wrapped.observedFrameCount==3)
        reset();vision.onSample={_ in controller.selectedEstimatedContext!.depthHypothesisID=String(repeating:"b",count:64)}
        do {_=try await search.captureEstimatedOrRegisteredCurrentScene(model:model,generation:7,check:{},progress:{_ in});fatalError("Rebound selected estimate")}catch{}
        precondition(search.registeredCalls==0 && search.collisionSnapshotValue==nil);rejectedCount+=1
        reset();controller.resolutionFails=true
        do {_=try await search.captureEstimatedOrRegisteredCurrentScene(model:model,generation:7,check:{},progress:{_ in});fatalError("Invalid selection fell back")}catch{}
        precondition(search.registeredCalls==0 && search.collisionSnapshotValue==nil);rejectedCount+=1
        print("Estimated current-scene runtime passed: real raw/corrected occupancy union,3 distinct native frames,no selfmask/registration,\(rejectedCount) invalidations,preview guard and no selected-estimate fallback")
    }
}
'''.replace('/* ACTUAL_METHODS */',actual)
# Same compilation unit retains the mapper's fileprivate snapshot initializer;
# production implementation remains verbatim and uses the real ray semantics.
depth_map=(ROOT/'Cerebro/ROBWorkspaceDepthMap.swift').read_text()
protocol=(ROOT/'Cerebro/ROBWorkspaceCollisionPlan.swift').read_text().split('/// A measured object envelope')[0]
with tempfile.TemporaryDirectory(prefix='rob-estimated-current-scene-',dir='/private/tmp') as temp:
    directory=Path(temp)
    (directory/'Protocol.swift').write_text(protocol)
    (directory/'Runtime.swift').write_text(depth_map+'\n'+fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',
                    str(ROOT/'Cerebro/ROBArmJointLimits.swift'),str(directory/'Protocol.swift'),str(ROOT/'Cerebro/ROBFixedHeadRegistration.swift'),
                    str(directory/'Runtime.swift'),'-o',str(directory/'runtime')],check=True)
    subprocess.run([str(directory/'runtime')],check=True)
