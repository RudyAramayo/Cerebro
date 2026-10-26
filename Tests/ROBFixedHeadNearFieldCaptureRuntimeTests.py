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
capture=braced_declaration(controller,'    private func captureAndFit(')
assert 'let preservedSource=try preservedCaptureSource(' in capture
assert 'preservedSource:preservedSource)' in capture
assert 'initial = fitted.unrefinedProvisionalCameraToModel' in capture
assert 'initial = fitted.provisionalCameraToModel' not in capture
assert 'photo_mount_origin_unrefined_rgb_orientation_initializer_only' in capture
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
    struct Frame {
        var depth:Depth?=Depth();var intrinsics:CameraIntrinsics?
        var cameraGeneration=UUID(),sequence:UInt64=100,capturedAt:Double=10_000
    }
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
    func deliver(_ active:Bool,_ token:UUID,_ mode:String="near_field",_ resolution:String="640x400") {
        fixedHeadCalibrationDemandDidChange(Notification(name:Notification.Name("test"),userInfo:[
            "active":active,"captureID":token.uuidString,"resolution":resolution,"stereoMode":mode]))
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
    var cameraDemandResolution:String?,cameraDemandStereoMode:String?
    var nextResolution="640x400",nextStereoMode="near_field"
    var captureBodyIdentity:String?,isRunning=false,status="ready",diagnosticFailure=false,beginFailure=false
    func display(_ value:String){status=value}
    func captureAndFit(token:UUID)async throws {
        if beginFailure {throw Failure.diagnostic}
        cameraDemandCaptureID=token;armOwner=UUID();captureBodyIdentity="body";isRunning=true
        cameraDemandResolution=nextResolution;cameraDemandStereoMode=nextStereoMode
        NotificationCenter.default.post(name:Self.cameraDemandChanged,object:self,userInfo:[
            "active":true,"captureID":token.uuidString,"resolution":nextResolution,"stereoMode":nextStereoMode])
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
        let fullManager=Manager()
        fullManager.setCalibrationCaptureOverride(token:a,resolution:"640x480",stereoMode:"standard");fullManager.settle()
        precondition(fullManager.depthClient!.calls.last!.0=="640x480" && fullManager.generationChanges==1)
        let fullCalls=fullManager.depthClient!.calls.count
        fullManager.setCalibrationCaptureOverride(token:b,resolution:"640x512",stereoMode:"standard");fullManager.settle()
        precondition(fullManager.depthClient!.calls.count==fullCalls,"Unreviewed calibration dimensions were accepted")
        fullManager.clearCalibrationCaptureOverride(token:b);fullManager.settle()
        precondition(fullManager.calibrationCaptureOverride?.token==a,"A stale token cleared the full-height demand")
        fullManager.clearCalibrationCaptureOverride(token:a);fullManager.settle()
        precondition(fullManager.depthClient!.calls.last!.0==nil && fullManager.generationChanges==2)

        let demand=Demand();demand.deliver(true,a);demand.deliver(true,b)
        let refreshes=demand.recordingRefreshes
        demand.deliver(false,a)
        precondition(demand.fixedHeadCalibrationCaptureID==b && demand.recordingRefreshes==refreshes)
        demand.deliver(false,b)
        precondition(demand.fixedHeadCalibrationCaptureID==nil && demand.cameraManager.calibrationCaptureOverride==nil)
        demand.deliver(true,a,"standard","640x480")
        precondition(demand.cameraManager.calibrationCaptureOverride?.resolution=="640x480",
            "Full-height notification was dropped or rewritten before reaching the camera")
        demand.deliver(true,b,"standard","640x512")
        precondition(demand.fixedHeadCalibrationCaptureID==a,"Unsupported dimensions displaced the valid capture")
        demand.deliver(false,a)

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
        var fullGate=ROBFixedHeadCaptureFrameGate(requestedAtMilliseconds:10_000,
            previousCameraGeneration:old,stereoMode:"near_field",fullHeight:true)
        precondition(!fullGate.accepts(cameraGeneration:fresh,sequence:1,capturedAt:11_000,
            nowMilliseconds:11_100,width:640,height:400,intrinsics:k),"An old crop satisfied full-height capture")
        precondition(!fullGate.accepts(cameraGeneration:fresh,sequence:1,capturedAt:11_000,
            nowMilliseconds:11_100,width:640,height:480,intrinsics:k))
        precondition(fullGate.accepts(cameraGeneration:fresh,sequence:2,capturedAt:13_000,
            nowMilliseconds:13_100,width:640,height:480,intrinsics:k),"Full-height source skipped or never completed settling")
        let fullIdentity=try Identity.intrinsicsIdentity(.init(depth:.init(width:640,height:480),intrinsics:k))
        precondition(fullIdentity != nearIdentity,"Different image dimensions reused a registration scope")

        let runtimeJSON:[String:Any]=["schemaVersion":1,"actualDeviceMXID":"fixture-device","cameraRole":"face","sdkVersion":"fixture-1",
            "factoryEEPROMSHA256":String(repeating:"1",count:64),"effectiveRuntimeCalibrationSHA256":String(repeating:"2",count:64),
            "stereoPolicySHA256":String(repeating:"3",count:64),"candidateSHA256":NSNull(),"profileSHA256":NSNull()]
        var native=k
        native.runtimeCalibration=try JSONDecoder().decode(CameraRuntimeCalibration.self,from:JSONSerialization.data(withJSONObject:runtimeJSON))
        native.cameraServiceSourceSHA256=String(repeating:"4",count:64)
        let pinned=ROBFixedHeadCaptureFrameGate.PreservedSource(cameraGeneration:old,afterSequence:100,afterCapturedAtMilliseconds:9_900,
            runtimeCalibrationIdentity:native.runtimeCalibration!.identity,cameraServiceSourceSHA256:native.cameraServiceSourceSHA256!)
        var heldGate=ROBFixedHeadCaptureFrameGate(requestedAtMilliseconds:10_000,previousCameraGeneration:old,
            stereoMode:"near_field",preservedSource:pinned)
        func heldOffer(_ gen:UUID,_ seq:UInt64,_ at:Double,_ intrinsics:CameraIntrinsics?=nil,_ now:Double?=nil)->Bool {
            heldGate.accepts(cameraGeneration:gen,sequence:seq,capturedAt:at,nowMilliseconds:now ?? at+100,
                width:640,height:400,intrinsics:intrinsics ?? native)
        }
        precondition(!heldOffer(old,100,10_100),"A cached held frame satisfied a new request")
        precondition(!heldOffer(old,101,9_999),"A pre-request capture satisfied a held-mode recapture")
        precondition(!heldOffer(fresh,101,10_100),"Preserved source silently enrolled a restarted camera")
        precondition(!heldOffer(old,101,10_100,k),"Missing runtime/source provenance satisfied held-mode capture")
        var wrongRuntime=native
        var otherRuntime=runtimeJSON;otherRuntime["effectiveRuntimeCalibrationSHA256"]=String(repeating:"5",count:64)
        wrongRuntime.runtimeCalibration=try JSONDecoder().decode(CameraRuntimeCalibration.self,from:JSONSerialization.data(withJSONObject:otherRuntime))
        precondition(!heldOffer(old,101,10_100,wrongRuntime),"A changed runtime reused the held source")
        var wrongService=native;wrongService.cameraServiceSourceSHA256=String(repeating:"6",count:64)
        precondition(!heldOffer(old,101,10_100,wrongService),"A changed service reused the held source")
        precondition(!heldOffer(old,101,10_100,nil,10_601),"A stale held frame was accepted")
        precondition(!heldOffer(old,101,10_100) && !heldOffer(old,102,12_099),"Same-source recapture skipped its new settling interval")
        precondition(heldOffer(old,103,12_100),"Fresh advancing same-source frames never completed settling")
        precondition(!heldOffer(old,103,12_100),"A repeated held capture was accepted")

        let review=Review()
        let reviewDemand=Demand()
        var reviewEvents:[Bool]=[]
        let observer=NotificationCenter.default.addObserver(forName:Review.cameraDemandChanged,object:review,queue:nil) { note in
            MainActor.assumeIsolated {
                let values=note.userInfo!,active=values["active"]as!Bool,token=UUID(uuidString:values["captureID"]as!String)!
                reviewEvents.append(active)
                reviewDemand.deliver(active,token,values["stereoMode"]as?String ?? "near_field",values["resolution"]as?String ?? "640x400")
            }
        }
        defer {NotificationCenter.default.removeObserver(observer)}
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
        let beforeSameMode=reviewDemand.cameraManager.generationChanges,beforeEvents=reviewEvents.count
        review.captureCurrentView()
        while review.task != nil {await Task.yield()}
        let newer=review.cameraDemandCaptureID!
        precondition(older != newer)
        precondition(reviewDemand.cameraManager.generationChanges==beforeSameMode,
            "Hold-for-review recapture restarted the identical native pipeline")
        precondition(Array(reviewEvents.dropFirst(beforeEvents))==[true],"Same-mode token handoff emitted an intermediate OFF")
        let beforeFailedBegin=reviewEvents.count,releasesBeforeFailedBegin=ROBAmberArmMotionArbiter.shared.releases
        review.beginFailure=true;review.captureCurrentView()
        while review.task != nil {await Task.yield()}
        precondition(review.cameraDemandCaptureID==newer && reviewEvents.count==beforeFailedBegin &&
            ROBAmberArmMotionArbiter.shared.releases==releasesBeforeFailedBegin && review.status.contains("Camera mode held for review"),
            "A rejected begin lost the prior held source or claimed a new one")
        review.beginFailure=false
        let source=try review.preservedCaptureSource(frame:.init(intrinsics:native,cameraGeneration:old,sequence:100,capturedAt:9_900),
            resolution:"640x400",stereoMode:"near_field")
        precondition(source?.cameraGeneration==old && source?.afterSequence==100 && source?.runtimeCalibrationIdentity==native.runtimeCalibration!.identity,
            "Held native source was not pinned from actual readback")
        let changedResolutionSource=try review.preservedCaptureSource(frame:nil,resolution:"640x480",stereoMode:"near_field")
        precondition(changedResolutionSource==nil,
            "A changed resolution claimed the old held source")
        do {_ = try review.preservedCaptureSource(frame:.init(intrinsics:k),resolution:"640x400",stereoMode:"near_field");preconditionFailure("Anonymous held source accepted")}
        catch {}
        review.releaseCameraDemand(token:older)
        review.finishCapture(token:older,holdModeForReview:false)
        precondition(review.cameraDemandCaptureID==newer,"Stale completion released newer held camera demand")
        let beforeModeChange=reviewDemand.cameraManager.generationChanges
        review.nextStereoMode="standard";review.captureCurrentView()
        while review.task != nil {await Task.yield()}
        precondition(reviewDemand.cameraManager.generationChanges==beforeModeChange+1,"A real mode change did not create exactly one new native source")
        review.windowWillClose(Notification(name:Notification.Name("closed")))
        precondition(review.cameraDemandCaptureID==nil && review.cameraDemandResolution==nil && review.cameraDemandStereoMode==nil && ROBAmberArmMotionArbiter.shared.releases==12)
        print("PASS fixed-head capture: held identical pipeline preserved, new genuine advancing settled source frames/runtime/service pinning, real mode changes restart, crop/full-height dimensions, token restoration/stale cleanup and registration identity")
    }
}
'''
harness=harness.replace('/* MANAGER_METHODS */',manager_methods)
harness=harness.replace('/* GEOMETRY */',braced_declaration(manager,'struct CameraDepthRGBGeometryCorrespondence:'))
harness=harness.replace('/* INTRINSICS */',braced_declaration(manager,'struct CameraRuntimeCalibration:')+'\n'+braced_declaration(manager,'struct CameraIntrinsics:'))
harness=harness.replace('/* GATE */',braced_declaration(controller,'struct ROBFixedHeadCaptureFrameGate'))
scope_helper=braced_declaration((ROOT/'Cerebro/ROBFixedHeadRegistration.swift').read_text(),'    static func cameraIntrinsicsIdentity(')
harness='import Foundation\nimport CryptoKit\nenum ROBFixedHeadRegistrationScope {\n'+scope_helper+'\n}\n'+harness
harness=harness.replace('/* IDENTITY */',braced_declaration(controller,'    @nonobjc static func intrinsicsIdentity('))
harness=harness.replace('/* DEMAND */',braced_declaration(view,'    @objc private func fixedHeadCalibrationDemandDidChange(').replace('cameraManager?.','cameraManager.'))
harness=harness.replace('/* REVIEW */','\n'.join(braced_declaration(controller,s) for s in (
    '    @objc func captureCurrentView()', '    private func releaseCameraDemand(', '    private func finishCapture(',
    '    private func preservedCaptureSource(',
    '    @objc func stop()', '    func windowWillClose(')).replace('private func ','func '))
with tempfile.TemporaryDirectory(prefix='rob-fixed-near-field-',dir='/private/tmp') as directory:
    folder=Path(directory);swift=folder/'Fixture.swift';swift.write_text(harness)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(folder/'fixture')],check=True)
    subprocess.run([str(folder/'fixture')],check=True)
