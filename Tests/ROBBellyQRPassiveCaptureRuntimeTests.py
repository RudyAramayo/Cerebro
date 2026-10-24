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
    let fx=120.0,fy=121.0,cx=16.0,cy=12.0
    var rgbOutputUndistorted:Bool?
    let cameraServiceSourceSHA256:String?=String(repeating:"a",count:64)
    let calibrationSource:String?="SYNTHETIC FIXTURE - NO PHYSICAL CAMERA"
    let depthAlignmentMethod:String?="synthetic_fixture_aligned"
    let sourceSize:[Int]?=[32,24],sourceIntrinsics:[Double]?=nil,imageTransform:[Double]?=nil
    let calibratedLensPosition:Int?=nil,frameLensPosition:Int?=nil
    func isValid(forWidth:Int,height:Int)->Bool {forWidth==32 && height==24}
}
final class ROBDepthCloudFrame:NSObject {
    let millimetersLittleEndian:NSData
    let width=32,height=24
    let rgbPixelBuffer:CVPixelBuffer?
    let isBelly:Bool
    let calibratedIntrinsics:CameraIntrinsics?
    let receivedUptime:TimeInterval,capturedUptime:TimeInterval
    let sourceSequence:UInt64?,sourceTimestampNanoseconds:UInt64?
    let sourceCapturedAtMilliseconds:Double?
    let sourceCaptureStreamID:String?
    init(belly:Bool,sequence:UInt64,stream:String="fixture-stream",undistorted:Bool?=true,stale:Bool=false) {
        isBelly=belly;sourceSequence=sequence;sourceTimestampNanoseconds=sequence*17
        sourceCaptureStreamID=stream
        receivedUptime=ProcessInfo.processInfo.systemUptime
        capturedUptime=receivedUptime-(stale ? 10:0)
        sourceCapturedAtMilliseconds=1792000000000+Double(sequence%100000)
        calibratedIntrinsics=CameraIntrinsics(rgbOutputUndistorted:undistorted)
        var buffer:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,32,24,kCVPixelFormatType_32BGRA,nil,&buffer)==kCVReturnSuccess)
        rgbPixelBuffer=buffer
        CVPixelBufferLockBaseAddress(buffer!,[])
        memset(CVPixelBufferGetBaseAddress(buffer!),255,CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!,[])
        var depth=Data()
        for _ in 0..<(32*24) {depth.append(88);depth.append(2)}
        millimetersLittleEndian=depth as NSData
    }
}
'''
    fixture = r'''
import AppKit
@main struct CaptureTest {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller=ROBBellyQRCalibrationWindowController.shared
        controller.captureCurrentView()
        try await Task.sleep(nanoseconds:100_000_000)
        let first=UInt64(9_007_199_254_740_999)
        // HEAD and stale BELLY updates must never become a saved target frame.
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:false,sequence:first-2))
        try await Task.sleep(nanoseconds:150_000_000)
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:true,sequence:first-1,stale:true))
        try await Task.sleep(nanoseconds:150_000_000)
        for index in 0..<5 {
            let flag:Bool?=index==0 ? nil : (index==1 ? false:true)
            NotificationCenter.default.post(name:.ROBDepthCloudFrame,
                object:ROBDepthCloudFrame(belly:true,sequence:first+UInt64(index),undistorted:flag))
            try await Task.sleep(nanoseconds:350_000_000)
        }
        for _ in 0..<30 {
            if !controller.isRunning {break}
            try await Task.sleep(nanoseconds:100_000_000)
        }
        precondition(!controller.isRunning)
        let folder=URL(fileURLWithPath:controller.lastCapturePath)
        let data=try Data(contentsOf:folder.appendingPathComponent("capture-input.json"))
        let input=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        precondition(input["cameraRole"] as? String=="belly")
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
            precondition(frame["intrinsics"] as? [Double]==[120,121,16,12])
            let depth=try Data(contentsOf:folder.appendingPathComponent(frame["depthPath"] as! String))
            precondition(depth.count==32*24*2 && depth[0]==88 && depth[1]==2)
            precondition((frame["imageSHA256"] as? String)?.count==64)
            precondition((frame["depthSHA256"] as? String)?.count==64)
        }
        precondition(input["registrationVerified"] as? Bool==false)
        precondition(input["armMotionAuthorized"] as? Bool==false)
        precondition((input["missingSourceEvidence"] as? [String])?.contains("RGB undistortion metadata")==true)

        // A source restart aborts; it cannot combine two physical camera streams.
        controller.captureCurrentView();try await Task.sleep(nanoseconds:100_000_000)
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:true,sequence:1,stream:"A"))
        try await Task.sleep(nanoseconds:350_000_000)
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:true,sequence:2,stream:"B"))
        try await Task.sleep(nanoseconds:350_000_000)
        precondition(!controller.isRunning && controller.status.contains("stream restarted"))

        // Cancellation remains immediate even when no valid BELLY frames arrive.
        controller.captureCurrentView();try await Task.sleep(nanoseconds:100_000_000)
        NotificationCenter.default.post(name:.ROBDepthCloudFrame,object:ROBDepthCloudFrame(belly:false,sequence:100))
        try await Task.sleep(nanoseconds:150_000_000)
        precondition(controller.isRunning)
        controller.stop()
        precondition(!controller.isRunning && controller.status.contains("cancelled"))
        print("PASS passive belly capture: HEAD/stale filtering, five native RGB-D frames, exact 64-bit source provenance, missing/false pixel metadata preserved, stream-restart rejection, immediate cancellation; no robot services linked")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="rob-belly-capture-", dir="/private/tmp") as temporary:
        path = Path(temporary)
        (path / "controller.swift").write_text(source)
        (path / "stubs.swift").write_text(stubs)
        (path / "main.swift").write_text(fixture)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-framework", "AppKit", "-framework", "CoreImage", "-framework", "CoreVideo",
                        str(path / "stubs.swift"), str(path / "controller.swift"), str(path / "main.swift"),
                        "-o", str(path / "capture")], check=True)
        environment = dict(os.environ, ROB_BELLY_FIXTURE_ROOT=str(path / "captures"))
        result = subprocess.run([str(path / "capture")], env=environment, capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise AssertionError((result.stdout + result.stderr)[-8000:])
        print(result.stdout.strip())


if __name__ == "__main__":
    main()
