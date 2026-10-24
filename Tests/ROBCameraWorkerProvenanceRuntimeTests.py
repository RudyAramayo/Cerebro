#!/usr/bin/env python3
"""Decode real producer headers through the actual Swift header/K mapping."""
from pathlib import Path
import json
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
from DepthCameraIPCFixtureTests import load_service, FakeRGBFrame, FakeDepthFrame, FakeMonoFrame

ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Cerebro/CameraManager.swift').read_text()
structure=braced_declaration(source,'struct CameraIntrinsics:')
header=braced_declaration(source,'private struct DepthCameraPacketHeader:')
camera_source=(ROOT/'Cerebro/CameraViewController.swift').read_text()
belly_source=(ROOT/'Cerebro/ROBBellyCameraWindowController.swift').read_text()
cloud=braced_declaration(camera_source,'@objcMembers public final class ROBDepthCloudFrame:')
depth_structure=braced_declaration(source,'struct CameraDepthFrame ')

def cloud_constructor(text):
    start=text.index('ROBDepthCloudFrame(',text.index('let hologramFrame ='))
    opening=text.index('(',start);level,end=1,opening+1
    while level:
        level+=(text[end]=='(')-(text[end]==')');end+=1
    return text[start:end]

face_constructor=cloud_constructor(camera_source)
belly_constructor=cloud_constructor(belly_source)
start=source.index('header.rgbIntrinsics.flatMap { values in')
opening=source.index('{',start);depth,end=1,opening+1
while depth:
    depth+=(source[end]=='{')-(source[end]=='}');end+=1
mapping=source[start:end]
service=load_service()
packet,*_=service.frame_payload(FakeRGBFrame(),FakeDepthFrame(),FakeMonoFrame((7,8)),FakeMonoFrame((9,10)),
                               [100.,0.,1.,0.,101.,0.5,0.,0.,1.])
actual=json.loads(packet)
legacy={k:v for k,v in actual.items()if k not in ('running_service_source_sha256','rgb_output_undistorted')}
replacement={**actual,'running_service_source_sha256':'d'*64,'rgb_output_undistorted':False}
fixture=r'''
import Foundation
import AVFoundation
struct CameraInertialObservation:Decodable,Sendable {var isValid:Bool {true}}
struct ROBChessPieceDetection:Decodable {}
/* INTRINSICS */
/* HEADER */
/* DEPTH */
/* CLOUD */
private struct CloudSource {
    let sequence:UInt64,timestampNanoseconds:UInt64
    let capturedAtMilliseconds:Double?
    let captureStreamID:String?
    let intrinsics:CameraIntrinsics?
    let rgbSampleBuffer:CMSampleBuffer
}
private func faceCloud(_ frameSet:CloudSource,depth:CameraDepthFrame)->ROBDepthCloudFrame {
    let sampleBuffer=frameSet.rgbSampleBuffer
    return /* FACE_CONSTRUCTOR */
}
private func bellyCloud(_ frameSet:CloudSource,depth:CameraDepthFrame)->ROBDepthCloudFrame {
    return /* BELLY_CONSTRUCTOR */
}
private func mapped(_ header:DepthCameraPacketHeader)->CameraIntrinsics? {return /* MAPPING */}
@main enum Fixtures {
    static func main()throws {
        let decoder=JSONDecoder()
        let packets=try CommandLine.arguments.dropFirst().map{try decoder.decode(DepthCameraPacketHeader.self,from:Data(contentsOf:URL(fileURLWithPath:$0)))}
        let current=mapped(packets[0])!,old=mapped(packets[1])!,replacement=mapped(packets[2])!
        precondition(current.cameraServiceSourceSHA256=="/* EXPECTED_SHA */" && current.rgbOutputUndistorted==true)
        precondition(current.fx==100 && current.fy==101 && current.cx==1 && current.cy==0.5)
        precondition(old.cameraServiceSourceSHA256==nil && old.rgbOutputUndistorted==nil && old.isValid(forWidth:2,height:1),"Legacy viewing invented provenance or lost valid K")
        precondition(replacement.cameraServiceSourceSHA256==String(repeating:"d",count:64) && replacement.rgbOutputUndistorted==false,"Frame provenance was replaced by an app/source assumption")
        var pixels:CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault,2,1,kCVPixelFormatType_32BGRA,nil,&pixels)==kCVReturnSuccess)
        var format:CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixels!,formatDescriptionOut:&format)==noErr)
        var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid)
        var sample:CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixels!,formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample)==noErr)
        let depth=CameraDepthFrame(width:2,height:1,millimetersLittleEndian:Data([0xe8,0x03,0xd0,0x07]))
        let captured=Date().timeIntervalSince1970*1000
        let inputs=[CloudSource(sequence:UInt64.max-5,timestampNanoseconds:UInt64.max-17,capturedAtMilliseconds:captured,
            captureStreamID:"real-manager-stream-17",intrinsics:current,rgbSampleBuffer:sample!),
            CloudSource(sequence:1,timestampNanoseconds:900,capturedAtMilliseconds:nil,captureStreamID:nil,intrinsics:old,rgbSampleBuffer:sample!),
            CloudSource(sequence:1,timestampNanoseconds:1000,capturedAtMilliseconds:captured,captureStreamID:"new-manager-stream-18",intrinsics:replacement,rgbSampleBuffer:sample!)]
        for input in inputs {
            let face=faceCloud(input,depth:depth),belly=bellyCloud(input,depth:depth)
            precondition(!face.isBelly && belly.isBelly)
            for cloud in [face,belly] {
                precondition(cloud.sourceSequence==input.sequence && cloud.sourceTimestampNanoseconds==input.timestampNanoseconds,
                    "Camera producer substituted a capture ordinal for actual source sequence/timestamp")
                precondition(cloud.sourceCapturedAtMilliseconds==input.capturedAtMilliseconds && cloud.sourceCaptureStreamID==input.captureStreamID,
                    "Camera producer invented capture time or camera-stream identity")
                precondition(cloud.calibratedIntrinsics?.cameraServiceSourceSHA256==input.intrinsics?.cameraServiceSourceSHA256 &&
                    cloud.calibratedIntrinsics?.rgbOutputUndistorted==input.intrinsics?.rgbOutputUndistorted,
                    "Cloud notification lost actual worker provenance")
                precondition(cloud.width==2 && cloud.height==1 && cloud.millimetersLittleEndian as Data==depth.millimetersLittleEndian)
            }
        }
        let legacyCloud=ROBDepthCloudFrame(depth:depth,rgbSampleBuffer:sample!)
        precondition(legacyCloud.sourceSequence==nil && legacyCloud.sourceTimestampNanoseconds==nil &&
            legacyCloud.sourceCapturedAtMilliseconds==nil && legacyCloud.sourceCaptureStreamID==nil,
            "Legacy cloud initializer invented source provenance")
        print("Camera worker provenance runtime passed: actual worker flags and face/belly source sequence, timestamps, stream identity preserve values, nil, false and restart")
    }
}
'''.replace('/* INTRINSICS */',structure).replace('/* HEADER */',header).replace('/* DEPTH */',depth_structure).replace('/* CLOUD */',cloud).replace('/* FACE_CONSTRUCTOR */',face_constructor).replace('/* BELLY_CONSTRUCTOR */',belly_constructor).replace('/* MAPPING */',mapping).replace('/* EXPECTED_SHA */',actual['running_service_source_sha256'])
with tempfile.TemporaryDirectory(prefix='rob-camera-worker-provenance-',dir='/private/tmp')as directory:
    root=Path(directory);paths=[]
    for name,value in [('current',actual),('legacy',legacy),('replacement',replacement)]:
        path=root/(name+'.json');path.write_text(json.dumps(value));paths.append(str(path))
    swift=root/'Fixture.swift';swift.write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(root/'fixture')],check=True)
    subprocess.run([str(root/'fixture'),*paths],check=True)
