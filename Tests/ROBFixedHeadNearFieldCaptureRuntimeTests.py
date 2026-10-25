#!/usr/bin/env python3
"""Run actual mode override, source-settling and scope identity code without cameras."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT=Path(__file__).resolve().parents[1]
manager=(ROOT/'Cerebro/CameraManager.swift').read_text()
controller=(ROOT/'Cerebro/ROBFixedHeadCalibrationWindowController.swift').read_text()
view=(ROOT/'Cerebro/CameraViewController.swift').read_text()
# The protocol declarations have no body: select the real manager methods.
manager_body=manager[manager.index('final class CameraManager:'):]
manager_methods='\n'.join(braced_declaration(manager_body,s) for s in (
    '    func setCaptureResolutionOverride(', '    func setCalibrationCaptureOverride(',
    '    func clearCalibrationCaptureOverride(', '    private func applyCaptureConfiguration()',
    '    private static func normalizedResolution(', '    private static func capturePreset('))
harness=r'''
import AppKit
import AVFoundation
import CryptoKit
enum CameraRole {case face,belly}
enum CameraSource {case depthAIService}
struct CameraInertialObservation:Sendable {}
/* GEOMETRY */
/* INTRINSICS */
/* GATE */
final class Client {
    var calls:[(String?,String?)]=[]
    func updateCaptureConfiguration(resolution:String?,stereoMode:String?) {calls.append((resolution,stereoMode))}
}
final class Manager {
    let role:CameraRole
    let sessionQueue=DispatchQueue(label:"test.capture")
    var captureResolutionOverride:String?
    var calibrationCaptureOverride:(token:UUID,resolution:String,stereoMode:String)?
    var appliedCaptureResolutionOverride:String?,appliedStereoModeOverride:String?
    var wantsRunning=true,activeSource:CameraSource? = .depthAIService
    var generationChanges=0
    func advanceDeliveryGeneration(){generationChanges+=1}
    var depthClient:Client?=Client()
    var videoSession:AVCaptureSession?
    init(_ role:CameraRole = .face){self.role=role}
    func settle(){sessionQueue.sync{}}
    /* MANAGER_METHODS */
}
enum ROBGhostMotionError:Error {case blocked(String)}
enum ROBGhostRobotModel {
    static func hash(_ value:Data)->String {SHA256.hash(data:value).map{String(format:"%02x",$0)}.joined()}
}
enum ROBArmRoutineVision {
    struct Depth {var width=640,height=400}
    struct Frame {var depth:Depth?=Depth();var intrinsics:CameraIntrinsics?}
}
final class Identity {
    /* IDENTITY */
}
@MainActor final class Demand:NSObject {
    let cameraManager=Manager()
    var fixedHeadCalibrationCaptureID:UUID?
    var reconciliations=0,recordingRefreshes=0
    func applyRecordingDemand(){recordingRefreshes+=1}
    func reconcileCameraSession(){reconciliations+=1}
    /* DEMAND */
    func deliver(_ active:Bool,_ token:UUID,_ mode:String="near_field") {
        fixedHeadCalibrationDemandDidChange(Notification(name:Notification.Name("test"),userInfo:[
            "active":active,"captureID":token.uuidString,"resolution":"640x400","stereoMode":mode]))
        cameraManager.settle()
    }
}
@MainActor final class ROBAmberArmMotionArbiter {
    enum Side {case left,right}
    static let shared=ROBAmberArmMotionArbiter();var releases=0
    func release(_ side:Side,owner:UUID){releases+=1}
}
@MainActor final class Review:NSObject {
    enum State {case on,off}
    final class Switch {var state:State = .off}
    enum Failure:Error {case diagnostic}
    static let cameraDemandChanged=Notification.Name("test.review.demand")
    let holdCameraMode=Switch()
    var task:Task<Void,Never>?,process:Process?,armOwner:UUID?
    var activeCaptureID:UUID?,cameraDemandCaptureID:UUID?
    var captureBodyIdentity:String?,isRunning=false,status="ready",diagnosticFailure=false
    func display(_ value:String){status=value}
    func captureAndFit(token:UUID)async throws {
        cameraDemandCaptureID=token;armOwner=UUID();captureBodyIdentity="body";isRunning=true
        if diagnosticFailure {throw Failure.diagnostic}
        display("measured evidence saved")
    }
    /* REVIEW */
}
@main enum Fixtures {
    @MainActor static func main()async throws {
        let manager=Manager(),a=UUID(),b=UUID()
        manager.setCaptureResolutionOverride("1920x1080");manager.settle()
        manager.setCalibrationCaptureOverride(token:a,resolution:"640x400",stereoMode:"near_field");manager.settle()
        precondition(manager.depthClient!.calls.last!.0=="640x400" && manager.depthClient!.calls.last!.1=="near_field")
        let generation=manager.generationChanges
        manager.setCaptureResolutionOverride("1280x800");manager.settle()
        precondition(manager.depthClient!.calls.last!.0=="640x400","Ordinary demand displaced the calibration token")
        precondition(manager.generationChanges==generation,"Unchanged effective hardware demand invented a source restart")
        manager.setCalibrationCaptureOverride(token:b,resolution:"640x400",stereoMode:"standard");manager.settle()
        let count=manager.depthClient!.calls.count
        manager.clearCalibrationCaptureOverride(token:a);manager.settle()
        precondition(manager.depthClient!.calls.count==count && manager.calibrationCaptureOverride?.token==b)
        manager.clearCalibrationCaptureOverride(token:b);manager.settle()
        precondition(manager.depthClient!.calls.last!.0=="1280x800" && manager.depthClient!.calls.last!.1==nil,
            "Completion did not restore the latest ordinary demand")
        precondition(manager.generationChanges==generation+2,"Mode changes did not invalidate native camera provenance")
        let belly=Manager(.belly)
        belly.setCalibrationCaptureOverride(token:a,resolution:"640x400",stereoMode:"near_field");belly.settle()
        precondition(belly.depthClient!.calls.isEmpty,"Face calibration changed the belly camera")

        let demand=Demand();demand.deliver(true,a);demand.deliver(true,b)
        let refreshes=demand.recordingRefreshes
        demand.deliver(false,a)
        precondition(demand.fixedHeadCalibrationCaptureID==b && demand.recordingRefreshes==refreshes)
        demand.deliver(false,b)
        precondition(demand.fixedHeadCalibrationCaptureID==nil && demand.cameraManager.calibrationCaptureOverride==nil)

        var k=CameraIntrinsics(fx:400,fy:400,cx:320,cy:200)
        k.stereoMode="near_field";k.stereoModeSource="sdk_initial_config_readback"
        k.stereoExtendedDisparity=true;k.stereoSubpixel=false
        let old=UUID(),fresh=UUID(),restarted=UUID()
        var gate=ROBFixedHeadCaptureFrameGate(requestedAtMilliseconds:10_000,previousCameraGeneration:old,stereoMode:"near_field")
        func offer(_ generation:UUID,_ sequence:UInt64,_ at:Double,_ now:Double?=nil,_ value:CameraIntrinsics?=nil)->Bool {
            gate.accepts(cameraGeneration:generation,sequence:sequence,capturedAt:at,nowMilliseconds:now ?? at+100,
                width:640,height:400,intrinsics:value ?? k)
        }
        precondition(!offer(old,100,11_000))
        precondition(!offer(fresh,1,9_999))
        var unknown=k;unknown.stereoMode=nil
        precondition(!offer(fresh,1,11_000,nil,unknown))
        var intentOnly=k;intentOnly.stereoModeSource="cli_request"
        precondition(!offer(fresh,1,11_000,nil,intentOnly))
        precondition(!offer(fresh,1,11_000,11_501))
        precondition(!offer(fresh,1,11_000) && !offer(fresh,2,12_999))
        precondition(offer(fresh,3,13_000) && !offer(fresh,3,13_000))
        precondition(!offer(restarted,1,14_000),"New source skipped its own settling interval")
        precondition(offer(restarted,2,16_000))
        var standard=k;standard.stereoMode="standard";standard.stereoExtendedDisparity=false;standard.stereoSubpixel=true
        precondition(!offer(restarted,3,16_500,nil,standard))
        let nearIdentity=try Identity.intrinsicsIdentity(.init(intrinsics:k))
        let standardIdentity=try Identity.intrinsicsIdentity(.init(intrinsics:standard))
        precondition(nearIdentity != standardIdentity,"Mode change reused a body registration scope")

        let review=Review()
        review.captureCurrentView()
        while review.task != nil {await Task.yield()}
        precondition(review.cameraDemandCaptureID==nil && review.armOwner==nil && !review.isRunning,
            "Default capture did not restore the camera and release arm ownership")
        review.holdCameraMode.state = .on
        for failure in [false,true] {
            review.diagnosticFailure=failure;review.captureCurrentView()
            while review.task != nil {await Task.yield()}
            precondition(review.cameraDemandCaptureID != nil && review.armOwner==nil && !review.isRunning,
                "Held success/diagnostic failure lost its camera or retained an arm")
            precondition(review.status.contains("Camera mode held for review"))
            review.stop()
            precondition(review.cameraDemandCaptureID==nil)
        }
        review.diagnosticFailure=false;review.captureCurrentView()
        while review.task != nil {await Task.yield()}
        let older=review.cameraDemandCaptureID!
        review.captureCurrentView()
        while review.task != nil {await Task.yield()}
        let newer=review.cameraDemandCaptureID!
        precondition(older != newer)
        review.releaseCameraDemand(token:older)
        review.finishCapture(token:older,holdModeForReview:false)
        precondition(review.cameraDemandCaptureID==newer,"Stale completion released newer held camera demand")
        review.windowWillClose(Notification(name:Notification.Name("closed")))
        precondition(review.cameraDemandCaptureID==nil && ROBAmberArmMotionArbiter.shared.releases==10)
        print("PASS fixed-head near-field: token restoration/stale cleanup, face-only override, SDK readback, real-source settling/restarts and mode-bound registration identity")
    }
}
'''
harness=harness.replace('/* MANAGER_METHODS */',manager_methods)
harness=harness.replace('/* GEOMETRY */',braced_declaration(manager,'struct CameraDepthRGBGeometryCorrespondence:'))
harness=harness.replace('/* INTRINSICS */',braced_declaration(manager,'struct CameraIntrinsics:'))
harness=harness.replace('/* GATE */',braced_declaration(controller,'struct ROBFixedHeadCaptureFrameGate'))
harness=harness.replace('/* IDENTITY */',braced_declaration(controller,'    @nonobjc static func intrinsicsIdentity('))
harness=harness.replace('/* DEMAND */',braced_declaration(view,'    @objc private func fixedHeadCalibrationDemandDidChange(').replace('cameraManager?.','cameraManager.'))
harness=harness.replace('/* REVIEW */','\n'.join(braced_declaration(controller,s) for s in (
    '    @objc func captureCurrentView()', '    private func releaseCameraDemand(', '    private func finishCapture(',
    '    @objc func stop()', '    func windowWillClose(')).replace('private func ','func '))
with tempfile.TemporaryDirectory(prefix='rob-fixed-near-field-',dir='/private/tmp') as directory:
    folder=Path(directory);swift=folder/'Fixture.swift';swift.write_text(harness)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(folder/'fixture')],check=True)
    subprocess.run([str(folder/'fixture')],check=True)
