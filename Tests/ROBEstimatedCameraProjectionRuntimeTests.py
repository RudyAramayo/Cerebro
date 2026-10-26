#!/usr/bin/env python3
"""Exercise actual provisional projection guards without UI or arm transport."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
methods='\n'.join(braced_declaration(source,needle) for needle in [
    '@nonobjc func estimatedCameraProjectionIsCurrent(',
    '@nonobjc private func requireEstimatedProjectionIdentity(',
    '@MainActor @nonobjc private func unregisteredCameraProjection('])
fixture=r'''
import Foundation
import simd
final class ROBGhostRobotModel {}
struct ROBWorkspaceView {
    var panDegrees:Double;var upperTarget:Int
    func cameraFrame(model:ROBGhostRobotModel)->simd_double4x4? {matrix_identity_double4x4}
}
struct Observation {var estimatedDepthHypothesisID:String?}
struct ROBWorkspaceCollisionSnapshot {
    var registrationID:String?;var estimatedCameraProjectionIdentity:String?;var observations:[Observation]
}
enum ROBWorkspaceDepthMapError:Error {case acquisition(String),invalidFrame}
struct Runtime {var identity="fixture-runtime"}
struct FakeIntrinsics {var rgbOutputUndistorted:Bool?=true;var runtimeCalibration:Runtime?=Runtime();var cameraServiceSourceSHA256:String?="fixture-service"}
enum ROBArmRoutineVision {struct Frame {var capturedAt:Double;var intrinsics:FakeIntrinsics?=FakeIntrinsics();var cameraGeneration=UUID()}}
struct Scope {
    var panTarget=6015,lowerTarget=6011,upperTarget=6160
    var valid=true
    func validate()throws {if !valid {throw ROBWorkspaceDepthMapError.invalidFrame}}
}
@MainActor final class ROBFixedHeadCalibrationWindowController {
    static let shared=ROBFixedHeadCalibrationWindowController()
    var current=Scope(),neck:NSDictionary=[:],shouldThrow=false,scopeCalls=0
    var readNeck:(()->NSDictionary)?
    func scope(model:ROBGhostRobotModel,frame:ROBArmRoutineVision.Frame)throws->Scope {
        scopeCalls+=1;if shouldThrow {throw ROBWorkspaceDepthMapError.invalidFrame};return current
    }
}
@MainActor enum ROBNeckRGBPoseDisplay {
    static var identity:String?,photoHardwareOpticalOriginRequested=false,unavailable=false
    static var onResolve:(()->Void)?
    static var sourceAccepted=true,lastSource:(UUID,String?,String?)?
    static func estimatedProjectionAcceptsSource(model:ROBGhostRobotModel,cameraGeneration:UUID,runtimeCalibrationIdentity:String?,cameraServiceSourceSHA256:String?)->Bool {
        lastSource=(cameraGeneration,runtimeCalibrationIdentity,cameraServiceSourceSHA256);return sourceAccepted
    }
    static func estimatedCameraProjectionIdentity(model:ROBGhostRobotModel)->String? {identity}
    static func provisionalCameraToModel(model:ROBGhostRobotModel,panTarget:Int,lowerTarget:Int,upperTarget:Int)->simd_double4x4? {
        onResolve?();if unavailable {return nil};var value=matrix_identity_double4x4;value.columns.3=SIMD4(0.1,0.2,0.3,1);return value
    }
}
@MainActor final class ActualGuards:NSObject {
/* METHODS */
    func project(_ frame:ROBArmRoutineVision.Frame,_ view:ROBWorkspaceView,_ model:ROBGhostRobotModel)throws
        ->(matrix:simd_double4x4,identity:String?,lowerTarget:Int?) {try unregisteredCameraProjection(frame:frame,view:view,model:model)}
    func require(_ identity:String?,_ model:ROBGhostRobotModel)throws {try requireEstimatedProjectionIdentity(identity,model:model)}
}
@main enum Fixtures {
    @MainActor static func main()throws {
        let model=ROBGhostRobotModel(),guarder=ActualGuards(),controller=ROBFixedHeadCalibrationWindowController.shared
        let a=String(repeating:"a",count:64),b=String(repeating:"b",count:64)
        var frame=ROBArmRoutineVision.Frame(capturedAt:0),view=ROBWorkspaceView(panDegrees:0.45,upperTarget:6160)
        func reset() {
            frame.capturedAt=Date().timeIntervalSince1970*1000-100
            frame.intrinsics=FakeIntrinsics()
            view=ROBWorkspaceView(panDegrees:0.45,upperTarget:6160)
            controller.current=Scope();controller.shouldThrow=false;controller.scopeCalls=0
            controller.neck=["known":true,"stationary":true,"pan":6015,"lower":6011,"upper":6160,
                "pan_degrees":0.45,"ready_at":ProcessInfo.processInfo.systemUptime-1]
            controller.readNeck={controller.neck}
            ROBNeckRGBPoseDisplay.identity=a;ROBNeckRGBPoseDisplay.photoHardwareOpticalOriginRequested=true
            ROBNeckRGBPoseDisplay.unavailable=false;ROBNeckRGBPoseDisplay.onResolve=nil
            ROBNeckRGBPoseDisplay.sourceAccepted=true;ROBNeckRGBPoseDisplay.lastSource=nil
        }
        func rejects(_ reason:String,_ body:()throws->Void) {
            do {try body();fatalError("Admitted \(reason)")}catch{}
        }
        func rejectsProjection(_ reason:String) {rejects(reason){_ = try guarder.project(frame,view,model)}}
        reset();let estimated=try guarder.project(frame,view,model)
        precondition(estimated.identity==a && estimated.lowerTarget==6011 && estimated.matrix.columns.3==SIMD4(0.1,0.2,0.3,1))
        precondition(ROBNeckRGBPoseDisplay.lastSource?.0==frame.cameraGeneration && ROBNeckRGBPoseDisplay.lastSource?.1=="fixture-runtime" && ROBNeckRGBPoseDisplay.lastSource?.2=="fixture-service")
        reset();ROBNeckRGBPoseDisplay.sourceAccepted=false;rejectsProjection("gravity refinement source mismatch")
        reset();ROBNeckRGBPoseDisplay.identity=nil;ROBNeckRGBPoseDisplay.photoHardwareOpticalOriginRequested=false
        ROBNeckRGBPoseDisplay.sourceAccepted=false;rejectsProjection("invalid requested refinement cannot fall through to a legacy projection")
        reset();ROBNeckRGBPoseDisplay.identity=nil;ROBNeckRGBPoseDisplay.photoHardwareOpticalOriginRequested=false
        let legacy=try guarder.project(frame,view,model)
        precondition(legacy.identity==nil && legacy.lowerTarget==nil && legacy.matrix==matrix_identity_double4x4 && controller.scopeCalls==0)
        reset();controller.neck["known"]=false;rejectsProjection("unknown raw neck")
        reset();controller.neck["stationary"]=false;rejectsProjection("moving raw neck")
        reset();controller.neck["pan"]=6016;rejectsProjection("raw pan mismatch")
        reset();controller.neck["lower"]=6012;rejectsProjection("raw lower mismatch")
        reset();controller.neck["upper"]=6161;rejectsProjection("raw upper mismatch")
        reset();view.panDegrees+=0.1;rejectsProjection("requested pan differs from accepted view")
        reset();view.upperTarget+=1;rejectsProjection("requested upper differs from accepted view")
        reset();frame.capturedAt-=2000;rejectsProjection("source pixels captured before hold ready")
        reset();controller.neck["ready_at"]=ProcessInfo.processInfo.systemUptime+1;rejectsProjection("future hold-ready time")
        reset();controller.neck["ready_at"]=Double.nan;rejectsProjection("invalid hold-ready time")
        reset();controller.shouldThrow=true;rejectsProjection("unavailable strict camera/head scope")
        reset();controller.current.valid=false;rejectsProjection("invalid scope")
        reset();frame.intrinsics?.rgbOutputUndistorted=false;rejectsProjection("distorted RGB source")
        reset();frame.intrinsics?.rgbOutputUndistorted=nil;rejectsProjection("unknown RGB pixel contract")
        reset();ROBNeckRGBPoseDisplay.unavailable=true;rejectsProjection("missing photo transform")
        reset();ROBNeckRGBPoseDisplay.onResolve={ROBNeckRGBPoseDisplay.identity=b};rejectsProjection("profile changed during matrix resolution")
        reset();ROBNeckRGBPoseDisplay.identity=nil;rejectsProjection("invalid requested photo configuration")
        reset();rejects("nil-to-enabled projection during scene"){try guarder.require(nil,model)}
        reset();ROBNeckRGBPoseDisplay.identity=nil;ROBNeckRGBPoseDisplay.photoHardwareOpticalOriginRequested=false
        rejects("enabled-to-disabled projection during scene"){try guarder.require(a,model)}
        reset();ROBNeckRGBPoseDisplay.identity=b;rejects("changed physical projection during scene"){try guarder.require(a,model)}
        reset();var map=ROBWorkspaceCollisionSnapshot(registrationID:nil,estimatedCameraProjectionIdentity:a,observations:[Observation(estimatedDepthHypothesisID:nil)])
        precondition(guarder.estimatedCameraProjectionIsCurrent(model:model,map:map))
        controller.current.panTarget=5000;controller.neck["upper"]=6906
        precondition(guarder.estimatedCameraProjectionIsCurrent(model:model,map:map),"A later legitimate head hold invalidated a multiview map")
        ROBNeckRGBPoseDisplay.identity=b;precondition(!guarder.estimatedCameraProjectionIsCurrent(model:model,map:map))
        map.estimatedCameraProjectionIdentity=nil;precondition(!guarder.estimatedCameraProjectionIsCurrent(model:model,map:map))
        map.registrationID="independent-measured-profile";precondition(guarder.estimatedCameraProjectionIsCurrent(model:model,map:map))
        map.registrationID=nil;map.observations=[Observation(estimatedDepthHypothesisID:"frozen-right-depth")]
        precondition(guarder.estimatedCameraProjectionIsCurrent(model:model,map:map),"Separate frozen RIGHT context inherited photo-origin policy")
        print("Estimated camera projection runtime passed: accepted raw source hold, before-ready/mismatch/change rejection, scene identity transitions, later head poses and independent registered/frozen contexts")
    }
}
'''.replace('/* METHODS */',methods).replace('neck:NSDictionary','neck:NSMutableDictionary')
with tempfile.TemporaryDirectory(prefix='rob-estimated-camera-projection-',dir='/private/tmp')as directory:
    root=Path(directory);swift=root/'Fixture.swift';binary=root/'fixture'
    swift.write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
