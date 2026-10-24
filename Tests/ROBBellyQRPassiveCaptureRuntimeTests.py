#!/usr/bin/env python3
"""Run the real passive capture controller with synthetic camera frames only."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / "Cerebro/ROBBellyQRCalibrationWindowController.swift").read_text()
    # Only redirect the evidence directory; the production capture, filtering,
    # source identity, metadata, cancellation and JPEG/depth code runs unchanged.
    storage = 'FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/BellyQRCalibration/Captures", isDirectory: true)'
    assert source.count(storage) == 1
    source = source.replace(storage, 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["ROB_BELLY_FIXTURE_ROOT"]!, isDirectory: true)')
    stubs = r'''
import AppKit
import CoreImage
import CoreVideo
extension Notification.Name { static let ROBDepthCloudFrame = Notification.Name("ROBDepthCloudFrame") }
struct CameraIntrinsics {
    let fx=980.0,fy=981.0,cx=640.0,cy=400.0
    var rgbOutputUndistorted:Bool?
    let cameraServiceSourceSHA256:String?=String(repeating:"a",count:64)
    let calibrationSource:String?="SYNTHETIC FIXTURE - NO PHYSICAL CAMERA"
    let depthAlignmentMethod:String?="synthetic_fixture_aligned"
    let sourceSize:[Int]?=[1280,800],sourceIntrinsics:[Double]?=nil,imageTransform:[Double]?=nil
    let calibratedLensPosition:Int?=nil,frameLensPosition:Int?=nil
    func isValid(forWidth:Int,height:Int)->Bool {forWidth==1280 && height==800}
}
final class ROBDepthCloudFrame:NSObject {
    let millimetersLittleEndian:NSData
    let width:Int,height:Int
    let rgbPixelBuffer:CVPixelBuffer?
    let isBelly:Bool
    let calibratedIntrinsics:CameraIntrinsics?
    var hasCalibratedIntrinsics:Bool {calibratedIntrinsics?.isValid(forWidth:width,height:height)==true}
    let receivedUptime:TimeInterval,capturedUptime:TimeInterval
    let sourceSequence:UInt64?,sourceTimestampNanoseconds:UInt64?
    let sourceCapturedAtMilliseconds:Double?
    let sourceCaptureStreamID:String?
    init(belly:Bool,sequence:UInt64,stream:String="fixture-stream",undistorted:Bool?=true,stale:Bool=false,lowResolution:Bool=false) {
        width=lowResolution ? 640:1280;height=lowResolution ? 400:800
        isBelly=belly;sourceSequence=sequence;sourceTimestampNanoseconds=sequence*17
        sourceCaptureStreamID=stream
        receivedUptime=ProcessInfo.processInfo.systemUptime
        capturedUptime=receivedUptime-(stale ? 10:0)
        sourceCapturedAtMilliseconds=1792000000000+Double(sequence%100000)
        calibratedIntrinsics=CameraIntrinsics(rgbOutputUndistorted:undistorted)
        var buffer:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,nil,&buffer)==kCVReturnSuccess)
        rgbPixelBuffer=buffer
        CVPixelBufferLockBaseAddress(buffer!,[])
        memset(CVPixelBufferGetBaseAddress(buffer!),255,CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!,[])
        var depth=Data(count:width*height*2)
        depth.withUnsafeMutableBytes { raw in
            raw.bindMemory(to:UInt16.self).initialize(repeating:600)
        }
        millimetersLittleEndian=depth as NSData
    }
}
'''
    fixture = r'''
import AppKit
import CoreImage
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
                object:ROBDepthCloudFrame(belly:true,sequence:first+UInt64(index),undistorted:flag))
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
        precondition(frames[1]["rgbOutputUndistorted"] as? Bool==false,"False source flag was overwritten")
        precondition(frames[2]["rgbOutputUndistorted"] as? Bool==true)
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
            precondition((frame["imageSHA256"] as? String)?.count==64)
            precondition((frame["depthSHA256"] as? String)?.count==64)
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
        print("PASS native QR seed pixels, HD demand lifecycle/low-resolution rejection/five-second warmup, passive belly HEAD/stale filtering, five native RGB-D frames, exact 64-bit source provenance, missing/false pixel metadata, stream restart and cancellation; no robot services linked")
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
