#!/usr/bin/env python3
"""Run the real passive capture controller with synthetic camera frames only."""
from pathlib import Path
import os
import subprocess
import tempfile

from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / "Cerebro/ROBBellyQRCalibrationWindowController.swift").read_text()
    # Only redirect the evidence directory; the production capture, filtering,
    # source identity, metadata, cancellation and JPEG/depth code runs unchanged.
    storage = 'FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/BellyQRCalibration/Captures", isDirectory: true)'
    assert source.count(storage) == 1
    source = source.replace(storage, 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["ROB_BELLY_FIXTURE_ROOT"]!, isDirectory: true)')
    manager_source = (ROOT / "Cerebro/CameraManager.swift").read_text()
    contracts = "\n".join(braced_declaration(manager_source, signature) for signature in (
        "struct CameraRuntimeCalibration:", "struct CameraDepthRGBGeometryCorrespondence:", "struct CameraIntrinsics:",
        "struct CameraStereoSourceExtrinsics:", "struct CameraStereoPairExtrinsics:",
        "struct CameraStereoGeometry:", "struct CameraStereoFrame:"))
    stubs = r'''
import CryptoKit
import AppKit
import CoreImage
import CoreVideo
extension Notification.Name { static let ROBDepthCloudFrame = Notification.Name("ROBDepthCloudFrame") }
struct CameraInertialObservation:Sendable {}
/* CAMERA_CONTRACTS */
private let leftFixturePixels=Data((0..<(640*400)).map { (index:Int)->UInt8 in UInt8(index % 251) })
private let rightFixturePixels=Data((0..<(640*400)).map { (index:Int)->UInt8 in
    let value=(index*3+17) % 251
    return UInt8(value)
})
func syntheticGray(right:Bool,sequence:UInt64)->Data {
    var value=right ? rightFixturePixels:leftFixturePixels
    value[0]=UInt8(sequence%251);value[value.count-1]=UInt8((sequence%251+(right ? 97:53))%251)
    return value
}
func syntheticStereoGeometry(right:Bool,sequence:UInt64,missingMatrix:Bool=false)->CameraStereoGeometry {
    let side=right ? "right":"left",offset:UInt64=right ? 29:11
    let fx=right ? 426.0:420.0,fy=right ? 427.0:421.0,cx=right ? 320.5:319.2,cy=right ? 198.5:199.3
    let errors=missingMatrix ? ["synthetic unavailable source calibration API"]:[]
    return CameraStereoGeometry(source:"actual_sdk_"+side+"_fixture",sequence:sequence+offset,
        timestampNanoseconds:sequence*17+offset,timestampDeviceNanoseconds:sequence*19+offset,
        width:640,height:400,intrinsics:[fx,0,cx,0,fy,cy,0,0,1],sourceSize:[1280,800],
        sourceIntrinsics:[fx*2,0,cx*2,0,fy*2,cy*2,0,0,1],imageTransform:[0.5,0,0,0,0.5,0,0,0,1],
        transformationSize:[640,400],transformationValid:true,
        sourceDistortionCoefficients:[0.1,-0.2,0.003,0.004],sourceDistortionModel:"perspective",
        extrinsicsToCommon:CameraStereoSourceExtrinsics(source:"SDK_SOURCE_COORDINATES_ONLY",toCameraSocket:"CAM_A",
            sourceLengthUnit:"centimeter",lengthUnit:"meter",useSpecTranslation:false,
            matrix:missingMatrix ? nil:[1,0,0,right ? -0.063:0.012,0,1,0,0,0,0,1,0,0,0,0,1],evidenceErrors:errors),
        evidenceErrors:errors)
}
final class ROBDepthCloudFrame:NSObject {
    let millimetersLittleEndian:NSData
    let width:Int,height:Int
    let rgbPixelBuffer:CVPixelBuffer?
    let isBelly:Bool
    let calibratedIntrinsics:CameraIntrinsics?
    let rectifiedLeft:CameraStereoFrame?,rectifiedRight:CameraStereoFrame?
    let stereoSourceExtrinsics:CameraStereoPairExtrinsics?
    var hasCalibratedIntrinsics:Bool {calibratedIntrinsics?.isValid(forWidth:width,height:height)==true}
    let receivedUptime:TimeInterval,capturedUptime:TimeInterval
    let sourceSequence:UInt64?,sourceTimestampNanoseconds:UInt64?
    let sourceCapturedAtMilliseconds:Double?
    let sourceCaptureStreamID:String?
    init(belly:Bool,sequence:UInt64,stream:String="fixture-stream",undistorted:Bool?=true,stale:Bool=false,
         lowResolution:Bool=false,stereoEvidenceMode:Int=2) {
        width=lowResolution ? 640:1280;height=lowResolution ? 400:800
        isBelly=belly;sourceSequence=sequence;sourceTimestampNanoseconds=sequence*17
        sourceCaptureStreamID=stream
        receivedUptime=ProcessInfo.processInfo.systemUptime
        capturedUptime=receivedUptime-(stale ? 10:0)
        sourceCapturedAtMilliseconds=1792000000000+Double(sequence%100000)
        var k=CameraIntrinsics(fx:980,fy:981,cx:640,cy:400)
        k.rgbOutputUndistorted=undistorted;k.cameraServiceSourceSHA256=String(repeating:"a",count:64)
        k.calibrationSource="SYNTHETIC FIXTURE - NO PHYSICAL CAMERA"
        k.depthAlignmentMethod="synthetic_fixture_aligned";k.sourceSize=[1280,800]
        k.rgbTransformationSize=[1280,800];k.depthTransformationSize=[1280,800]
        k.rgbSourceDistortionCoefficients=[0.1,-0.2,0.003,0.004];k.depthSourceDistortionCoefficients=[0.05,-0.1,0.001,0.002]
        k.rgbSourceDistortionModel="perspective";k.depthSourceDistortionModel="perspective"
        if undistorted != nil {
            k.depthIntrinsics=[980,0,640,0,981,400,0,0,1];k.depthIntrinsicsSource="synthetic actual SDK depth transformation"
            k.depthSourceSize=[1280,800];k.depthSourceIntrinsics=k.depthIntrinsics;k.depthImageTransform=[1,0,0,0,1,0,0,0,1]
            let aligned=undistorted != false
            k.depthRGBGeometryCorrespondence=CameraDepthRGBGeometryCorrespondence(status:aligned ? "matched":"mismatched",
                dimensionsMatch:true,intrinsicsMatch:true,maximumIntrinsicDifferencePixels:0,sdkAlignedToRGB:aligned,
                sdkEqualTransformationToRGB:aligned,depthTransformationValid:true,rgbTransformationValid:true,detail:"synthetic fixture only")
        }
        if stereoEvidenceMode != 0 {
            k.frameExposureMicroseconds=8000.5+Double(stereoEvidenceMode);k.frameISO=320+stereoEvidenceMode
            k.frameColorTemperatureKelvin=4600+stereoEvidenceMode
            k.frameObservationErrors=stereoEvidenceMode==4 ? ["synthetic partial sensor readback"]:[]
        }
        calibratedIntrinsics=k
        if stereoEvidenceMode==0 {rectifiedLeft=nil;rectifiedRight=nil;stereoSourceExtrinsics=nil}
        else {
            var left=syntheticGray(right:false,sequence:sequence)
            if stereoEvidenceMode==3 {left.removeLast()}
            rectifiedLeft=CameraStereoFrame(width:640,height:400,pixels:left,
                geometry:stereoEvidenceMode==1 ? nil:syntheticStereoGeometry(right:false,sequence:sequence,missingMatrix:stereoEvidenceMode==4))
            rectifiedRight=CameraStereoFrame(width:640,height:400,pixels:syntheticGray(right:true,sequence:sequence),
                geometry:stereoEvidenceMode==1 ? nil:syntheticStereoGeometry(right:true,sequence:sequence,missingMatrix:stereoEvidenceMode==4))
            stereoSourceExtrinsics=stereoEvidenceMode==1 ? nil:CameraStereoPairExtrinsics(source:"SDK_SOURCE_PAIR_ONLY",
                from:"CAM_B",to:"CAM_C",translationUnit:"meter",useSpecTranslation:false,
                matrix:stereoEvidenceMode==4 ? nil:[1,0,0,-0.075,0,1,0,0.001,0,0,1,0,0,0,0,1],
                evidenceErrors:stereoEvidenceMode==4 ? ["synthetic pair matrix unavailable"]:[])
        }
        var buffer:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,nil,&buffer)==kCVReturnSuccess)
        rgbPixelBuffer=buffer
        CVPixelBufferLockBaseAddress(buffer!,[])
        memset(CVPixelBufferGetBaseAddress(buffer!),255,CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!,[])
        var depth=Data(count:width*height*2)
        depth.withUnsafeMutableBytes { raw in raw.bindMemory(to:UInt16.self).initialize(repeating:600) }
        millimetersLittleEndian=depth as NSData
    }
}
'''
    stubs = stubs.replace("/* CAMERA_CONTRACTS */", contracts)
    fixture = r'''
import AppKit
import CoreImage
import CryptoKit
@main struct CaptureTest {
    @MainActor static func warmUp(_ controller:ROBBellyQRCalibrationWindowController,sequence:UInt64,stream:String="fixture-stream") async throws {
        for _ in 0..<30 {
            NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:true,sequence:sequence,stream:stream))
            try await Task.sleep(nanoseconds:200_000_000)
            if controller.status.contains("five seconds") {
                try await Task.sleep(nanoseconds:5_250_000_000)
                return
            }
        }
        preconditionFailure("No fresh HD warmup frame reached controller: \(controller.status)")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller=ROBBellyQRCalibrationWindowController.shared
        let summary=ROBBellyQRCalibrationWindowController.diagnosticSummary(report:["acceptedFrameCount":5,"consistentPairFrameCount":0,
            "rawDepthAgreementAcrossConsistentFrames":false,"rejectedFrames":[],"frames":[
                ["pairTranslationErrorMeters":0.0172,"pairRotationErrorDegrees":6.7],
                ["pairTranslationErrorMeters":0.0174,"pairRotationErrorDegrees":6.8]]],exitStatus:0,logText:"",evidencePath:"/private/tmp/synthetic-evidence",missing:[])
        precondition(summary.contains("5/5") && summary.contains("0/5") && summary.contains("17.2-17.4 mm"))
        precondition(summary.count<1000 && !summary.contains("\"frames\"") && summary.contains("/private/tmp/synthetic-evidence"),"Diagnostic UI emitted implementation JSON instead of concise findings")
        // Detector seeds use the native y-down pixels, not normalized or
        // resized dimensions. Both independent payloads must remain distinct.
        let canvas=CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:CGRect(x:0,y:0,width:1280,height:800))
        var chart=canvas
        var expected:[String:CGPoint]=[:]
        for (index,payload) in ["ROB:BELLY:B01","ROB:BELLY:B02"].enumerated() {
            let qr=CIFilter(name:"CIQRCodeGenerator",parameters:["inputMessage":payload.data(using:.utf8)!,"inputCorrectionLevel":"M"])!.outputImage!.transformed(by:CGAffineTransform(scaleX:6,y:6))
            let x=CGFloat(200+index*500),y:CGFloat=100
            expected[payload]=CGPoint(x:x+qr.extent.width/2,y:800-y-qr.extent.height/2)
            chart=qr.transformed(by:CGAffineTransform(translationX:x,y:y)).composited(over:chart)
        }
        let cg=CIContext().createCGImage(chart,from:canvas.extent)!
        let seeds=ROBBellyQRCalibrationWindowController.nativeQRSeeds(in:cg)
        precondition(Set(seeds.compactMap{$0["payload"] as? String})==Set(expected.keys))
        for seed in seeds {
            let corners=seed["cornersPixels"] as! [[Double]]
            precondition(corners.count==4 && corners.allSatisfy{$0.count==2 && (0...1280).contains($0[0]) && (0...800).contains($0[1])})
            let center=CGPoint(x:corners.map{$0[0]}.reduce(0,+)/4,y:corners.map{$0[1]}.reduce(0,+)/4)
            let target=expected[seed["payload"] as! String]!
            precondition(abs(center.x-target.x)<5 && abs(center.y-target.y)<5,"Native QR corner origin was flipped or resized")
        }
        var demandEvents:[[String:Any]]=[]
        let demandObserver=NotificationCenter.default.addObserver(forName:ROBBellyQRCalibrationWindowController.cameraDemandChanged,object:nil,queue:.main) { note in
            demandEvents.append(note.userInfo as! [String:Any])
        }
        defer {NotificationCenter.default.removeObserver(demandObserver)}
        controller.captureCurrentView()
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(demandEvents.last?["active"] as? Bool==true)
        precondition(demandEvents.last?["resolution"] as? String=="1280x800")
        let first=UInt64(9_007_199_254_740_999)
        // HEAD and stale BELLY updates must never become a saved target frame.
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:false,sequence:first-2))
        try await Task.sleep(nanoseconds:150_000_000)
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:true,sequence:first-1,stale:true))
        try await Task.sleep(nanoseconds:150_000_000)
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:true,sequence:first-3,lowResolution:true))
        try await Task.sleep(nanoseconds:150_000_000)
        precondition(!FileManager.default.fileExists(atPath:controller.lastCapturePath+"/frame-0.jpg"),"Low-resolution RGB-D was accepted as HD")
        try await warmUp(controller,sequence:first-100)
        precondition(!FileManager.default.fileExists(atPath:controller.lastCapturePath+"/frame-0.jpg"),"Warmup frame was saved")
        for index in 0..<5 {
            let flag:Bool?=index==0 ? nil : (index==1 ? false:true)
            NotificationCenter.default.post(name:.ROBDepthCloudFrame,
                object:ROBDepthCloudFrame(belly:true,sequence:first+UInt64(index),undistorted:flag,stereoEvidenceMode:index))
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds:100_000_000)
                if controller.status.contains("Saved \(index+1)/5") || !controller.isRunning {break}
            }
            if index<4 {
                precondition(controller.status.contains("Saved \(index+1)/5"),"Fixture frame \(index) was not captured: \(controller.status)")
            }
            // Match the production >=200ms source-capture spacing even when
            // a synthetic blank frame's detector finishes in under100ms.
            try await Task.sleep(nanoseconds:250_000_000)
        }
        for _ in 0..<30 {
            if !controller.isRunning {break}
            try await Task.sleep(nanoseconds:100_000_000)
        }
        precondition(!controller.isRunning,"Capture did not finish: \(controller.status)")
        precondition(demandEvents.last?["active"] as? Bool==false,"HD demand survived completed capture")
        let folder=URL(fileURLWithPath:controller.lastCapturePath)
        let data=try Data(contentsOf:folder.appendingPathComponent("capture-input.json"))
        let input=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let observations=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("capture-observations.json"))) as! [String:Any]
        precondition((observations["observedFrameCount"] as! Int)>=7)
        let recent=observations["recentFrames"] as! [[String:Any]]
        precondition(!recent.isEmpty && recent.count<=12)
        precondition(recent.last?["depthWidth"] as? Int==1280)
        precondition(observations["acceptanceRulesChanged"] as? Bool==false)
        precondition(input["cameraRole"] as? String=="belly")
        precondition(input["requestedCaptureResolution"] as? String=="1280x800")
        precondition(input["cameraWarmupSeconds"] as? Double==5.0)
        precondition(input["captureStreamID"] as? String=="fixture-stream")
        precondition(input["captureSessionID"] as? String != "fixture-stream")
        let frames=input["frames"] as! [[String:Any]]
        precondition(frames.count==5)
        precondition((frames[0]["sequence"] as! NSNumber).uint64Value==first)
        precondition(frames[0]["rgbOutputUndistorted"]==nil,"Missing source flag was fabricated")
        precondition(frames[0]["rectifiedLeft"]==nil && frames[0]["rectifiedRight"]==nil && frames[0]["stereoSourceExtrinsics"]==nil,
            "Legacy frames gained invented mono artifacts or extrinsics")
        precondition(frames[0]["rgbFrameExposureMicroseconds"]==nil && frames[0]["rgbFrameISO"]==nil &&
            frames[0]["rgbFrameColorTemperatureKelvin"]==nil && frames[0]["rgbFrameObservationErrors"]==nil,
            "Missing exposure was replaced by camera defaults")
        precondition((frames[1]["rectifiedLeft"] as? [String:Any])?["geometry"]==nil &&
            (frames[1]["rectifiedRight"] as? [String:Any])?["geometry"]==nil && frames[1]["stereoSourceExtrinsics"]==nil,
            "Legacy mono pixels inherited calibration evidence")
        precondition(frames[3]["rectifiedLeft"]==nil && frames[3]["rectifiedRight"] != nil,
            "Invalid GRAY8 byte count was saved or dropped the independent valid side")
        precondition(frames[1]["rgbOutputUndistorted"] as? Bool==false,"False source flag was overwritten")
        precondition(frames[2]["rgbOutputUndistorted"] as? Bool==true)
        precondition(frames[0]["depthIntrinsics"]==nil && frames[0]["depthRGBGeometryCorrespondence"]==nil,"Missing depth pixel evidence was fabricated")
        precondition((frames[1]["depthRGBGeometryCorrespondence"] as? [String:Any])?["sdkAlignedToRGB"] as? Bool==false,"SDK mismatch was overwritten")
        precondition(frames[2]["depthIntrinsics"] as? [Double]==[980,0,640,0,981,400,0,0,1])
        precondition(frames[2]["depthSourceSize"] as? [Int]==[1280,800])
        precondition(frames[2]["depthSourceIntrinsics"] as? [Double]==frames[2]["depthIntrinsics"] as? [Double])
        precondition(frames[2]["depthImageTransform"] as? [Double]==[1,0,0,0,1,0,0,0,1])
        precondition(frames[2]["rgbDepthDimensionsMatch"] as? Bool==true)
        precondition(frames[2]["rgbTransformationSize"] as? [Int]==[1280,800])
        precondition(frames[2]["depthTransformationSize"] as? [Int]==[1280,800])
        precondition(frames[2]["rgbSourceDistortionCoefficients"] as? [Double]==[0.1,-0.2,0.003,0.004],"Actual source distortion was replaced by fabricated output zeros")
        precondition(frames[2]["rgbGeometryMatchesNativeDepth"]==nil,"Dimensions alone were labelled pixel correspondence")
        for (index,frame) in frames.enumerated() {
            precondition(frame["sourceCameraRole"] as? String=="belly")
            precondition(frame["sequenceSource"] as? String=="camera_frame_set")
            precondition((frame["sequence"] as! NSNumber).uint64Value==first+UInt64(index))
            precondition((frame["sourceTimestampNanoseconds"] as! NSNumber).uint64Value==(first+UInt64(index))*17)
            precondition(frame["capturedAtMilliseconds"] as? Double==1792000000000+Double((first+UInt64(index))%100000))
            precondition(frame["captureStreamID"] as? String=="fixture-stream")
            precondition(frame["intrinsics"] as? [Double]==[980,981,640,400])
            let depth=try Data(contentsOf:folder.appendingPathComponent(frame["depthPath"] as! String))
            precondition(depth.count==1280*800*2 && depth[0]==88 && depth[1]==2)
            let jpeg=try Data(contentsOf:folder.appendingPathComponent(frame["imagePath"] as! String))
            func hash(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
            precondition(frame["imageSHA256"] as? String==hash(jpeg) && frame["depthSHA256"] as? String==hash(depth))
            if index>0 {
                precondition(frame["rgbFrameExposureMicroseconds"] as? Double==8000.5+Double(index))
                precondition(frame["rgbFrameISO"] as? Int==320+index && frame["rgbFrameColorTemperatureKelvin"] as? Int==4600+index)
                precondition(frame["rgbFrameObservationErrors"] as? [String]==(index==4 ? ["synthetic partial sensor readback"]:[]))
                for side in ["left","right"] where !(index==3 && side=="left") {
                    let saved=frame[side=="left" ? "rectifiedLeft":"rectifiedRight"] as! [String:Any]
                    let bytes=try Data(contentsOf:folder.appendingPathComponent(saved["imagePath"] as! String))
                    let right=side=="right",sourceSequence=first+UInt64(index)
                    precondition(bytes.count==640*400 && bytes==syntheticGray(right:right,sequence:sourceSequence),
                        "Stereo pixels were resized, recolored or associated with another frame")
                    precondition(saved["width"] as? Int==640 && saved["height"] as? Int==400 && saved["pixelFormat"] as? String=="GRAY8")
                    precondition(saved["imageSHA256"] as? String==hash(bytes) && saved["source"] as? String=="same_synchronized_camera_packet")
                    precondition(saved["triangulationVerified"] as? Bool==false && saved["registrationVerified"]==nil)
                    if index>=2 {
                        let g=saved["geometry"] as! [String:Any],offset:UInt64=right ? 29:11
                        let expectedK=right ? [426.0,0,320.5,0,427,198.5,0,0,1]:[420.0,0,319.2,0,421,199.3,0,0,1]
                        precondition(g["intrinsics"] as? [Double]==expectedK && g["intrinsics"] as? [Double] != frame["depthIntrinsics"] as? [Double],
                            "Mono SDK K was aliased to RGB/depth K")
                        precondition((g["sequence"] as! NSNumber).uint64Value==sourceSequence+offset)
                        precondition((g["timestampNanoseconds"] as! NSNumber).uint64Value==sourceSequence*17+offset)
                        precondition((g["timestampDeviceNanoseconds"] as! NSNumber).uint64Value==sourceSequence*19+offset)
                        precondition(g["width"] as? Int==640 && g["height"] as? Int==400 && g["sourceSize"] as? [Int]==[1280,800])
                        precondition(g["sourceDistortionCoefficients"] as? [Double]==[0.1,-0.2,0.003,0.004])
                        let ext=g["extrinsicsToCommon"] as! [String:Any]
                        precondition(ext["lengthUnit"] as? String=="meter" && ext["sourceLengthUnit"] as? String=="centimeter" && ext["useSpecTranslation"] as? Bool==false)
                        precondition(ext["triangulationVerified"]==nil && ext["registrationVerified"]==nil)
                        if index==4 {precondition(ext["matrix"]==nil && !(ext["evidenceErrors"] as! [String]).isEmpty)}
                    }
                }
            }
            if index>=2 {
                let pair=frame["stereoSourceExtrinsics"] as! [String:Any]
                precondition(pair["from"] as? String=="CAM_B" && pair["to"] as? String=="CAM_C" &&
                    pair["translationUnit"] as? String=="meter" && pair["useSpecTranslation"] as? Bool==false)
                precondition(pair["registrationVerified"]==nil && pair["triangulationVerified"]==nil,
                    "Source-coordinate extrinsics became a triangulation or robot registration")
                if index==4 {precondition(pair["matrix"]==nil && !(pair["evidenceErrors"] as! [String]).isEmpty)}
                else {precondition((pair["matrix"] as! [Double])[3] == -0.075)}
            }
        }
        precondition(input["registrationVerified"] as? Bool==false)
        precondition(input["armMotionAuthorized"] as? Bool==false)
        precondition((input["missingSourceEvidence"] as? [String])?.contains("RGB undistortion metadata")==true)

        // A source restart aborts; it cannot combine two physical camera streams.
        controller.captureCurrentView();try await Task.sleep(nanoseconds:100_000_000)
        try await warmUp(controller,sequence:0,stream:"A")
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:true,sequence:1,stream:"A"))
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds:100_000_000)
            if controller.status.contains("Saved 1/5") {break}
        }
        precondition(controller.status.contains("Saved 1/5"),"First source frame was not committed: \(controller.status)")
        try await Task.sleep(nanoseconds:250_000_000)
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:true,sequence:2,stream:"B"))
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds:100_000_000)
            if !controller.isRunning {break}
        }
        precondition(!controller.isRunning && controller.status.contains("stream restarted"),"Source restart was not rejected: \(controller.status)")
        precondition(demandEvents.last?["active"] as? Bool==false,"HD demand survived stream failure")

        // Cancellation remains immediate even when no valid BELLY frames arrive.
        controller.captureCurrentView();try await Task.sleep(nanoseconds:100_000_000)
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:false,sequence:100))
        try await Task.sleep(nanoseconds:150_000_000)
        precondition(controller.isRunning)
        controller.stop()
        precondition(!controller.isRunning && controller.status.contains("cancelled"))
        precondition(demandEvents.last?["active"] as? Bool==false,"HD demand survived cancellation")
        print("PASS native QR seed pixels, HD demand lifecycle/low-resolution rejection/five-second warmup, passive belly HEAD/stale filtering, five native RGB-D/unchanged GRAY8 artifacts with exact hashes, distinct mono K and 64-bit timing, exposure readbacks/missing metadata, source-only extrinsics, stream restart and cancellation; no robot services linked")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="rob-belly-capture-", dir="/private/tmp") as temporary:
        path = Path(temporary)
        (path / "controller.swift").write_text(source)
        (path / "stubs.swift").write_text(stubs)
        (path / "main.swift").write_text(fixture)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-framework", "AppKit", "-framework", "CoreImage", "-framework", "CoreVideo", "-framework", "Vision",
                        str(path / "stubs.swift"), str(path / "controller.swift"), str(path / "main.swift"),
                        "-o", str(path / "capture")], check=True)
        environment = dict(os.environ, PYTHONNOUSERSITE="1", ROB_BELLY_FIXTURE_ROOT=str(path / "captures"))
        result = subprocess.run([str(path / "capture")], env=environment, capture_output=True, text=True, timeout=90)
        if result.returncode:
            traces=[]
            for report in (path / "captures").glob("*/capture-observations.json"):
                traces.append(report.read_text()[-6000:])
            raise AssertionError((result.stdout + result.stderr)[-8000:]+"\n"+"\n".join(traces))
        print(result.stdout.strip())


if __name__ == "__main__":
    main()
