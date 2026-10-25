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
depth_geometry=braced_declaration(source,'struct CameraDepthRGBGeometryCorrespondence:')
header=braced_declaration(source,'private struct DepthCameraPacketHeader:')
camera_source=(ROOT/'Cerebro/CameraViewController.swift').read_text()
belly_source=(ROOT/'Cerebro/ROBBellyCameraWindowController.swift').read_text()
cloud=braced_declaration(camera_source,'@objcMembers public final class ROBDepthCloudFrame:')
depth_structure=braced_declaration(source,'struct CameraDepthFrame ')
stereo_structures='\n'.join(braced_declaration(source,signature) for signature in (
    'struct CameraStereoSourceExtrinsics:', 'struct CameraStereoPairExtrinsics:',
    'struct CameraStereoGeometry:', 'struct CameraStereoFrame:'))

def stereo_constructor(label):
    start=source.index(label+': CameraStereoFrame(',source.index('private func drainBufferedPackets()'))
    opening=source.index('(',start);level,end=1,opening+1
    while level:
        level+=(source[end]=='(')-(source[end]==')');end+=1
    return source[start+len(label)+2:end]

pair_start=source.index('stereoSourceExtrinsics: header.',source.index('private func drainBufferedPackets()'))
pair_mapping=source[pair_start+len('stereoSourceExtrinsics: '):].split(',',1)[0]

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
depth_keys=('depth_intrinsics','depth_intrinsics_source','depth_source_size','depth_source_intrinsics','depth_image_transform','depth_rgb_geometry_correspondence',
    'rgb_transformation_size','depth_transformation_size','rgb_source_distortion_coefficients','depth_source_distortion_coefficients','rgb_source_distortion_model','depth_source_distortion_model')
additional_keys=('rgb_frame_exposure_microseconds','rgb_frame_iso','rgb_frame_color_temperature_kelvin','rgb_frame_observation_errors',
    'rectified_left_geometry','rectified_right_geometry','rectified_left_source_to_right_source')
legacy={k:v for k,v in actual.items()if k not in ('running_service_source_sha256','rgb_output_undistorted',*depth_keys,*additional_keys)}
replacement={**actual,'running_service_source_sha256':'d'*64,'rgb_output_undistorted':False,
    'stereo_mode':'near_field','stereo_mode_source':'sdk_initial_config_readback',
    'stereo_extended_disparity':True,'stereo_subpixel':False,
    'rgb_frame_exposure_microseconds':12500.,'rgb_frame_iso':640,'rgb_frame_color_temperature_kelvin':4500,
    'rgb_frame_observation_errors':['fixture: source readback error retained']}
with_depth={**actual,'depth_intrinsics':[100.,0.,1.,0.,101.,.5,0.,0.,1.],
    'depth_intrinsics_source':'actual_depth_transformation','depth_source_size':[2,1],
    'depth_source_intrinsics':[100.,0.,1.,0.,101.,.5,0.,0.,1.],
    'depth_image_transform':[1.,0.,0.,0.,1.,0.,0.,0.,1.],
    'rgb_transformation_size':[2,1],'depth_transformation_size':[2,1],
    'rgb_source_distortion_coefficients':[.1,-.2,.003,.004], 'depth_source_distortion_coefficients':[.05,-.1,.001,.002],
    'rgb_source_distortion_model':'perspective','depth_source_distortion_model':'perspective',
    'depth_rgb_geometry_correspondence':{'status':'mismatched','dimensionsMatch':True,'intrinsicsMatch':True,
        'maximumIntrinsicDifferencePixels':0.,'sdkAlignedToRGB':False,'sdkEqualTransformationToRGB':False,
        'depthTransformationValid':True,'rgbTransformationValid':True,'detail':'fixture: matching K alone cannot prove correspondence'}}
source_extrinsics={'source':'sdk_frame_transformation_getExtrinsics','toCameraSocket':'CameraBoardSocket.CAM_C',
    'sourceLengthUnit':'LengthUnit.CENTIMETER','lengthUnit':'meter','useSpecTranslation':False,
    'matrix':[1.,0,0,.075,0,1.,0,.001,0,0,1.,.002,0,0,0,1.],
    'evidenceErrors':['fixture: source axes are not verified rectified axes']}
left_geometry={'source':'sdk_frame_transformation','sequence':2**64-9,'timestampNanoseconds':2**64-17,
    'timestampDeviceNanoseconds':2**64-33,'width':2,'height':1,
    'intrinsics':[100.,0,1.,0,101.,.5,0,0,1.],'sourceSize':[4,2],
    'sourceIntrinsics':[200.,0,2.,0,202.,1.,0,0,1.],
    'imageTransform':[.5,0,0,0,.5,0,0,0,1.],'transformationSize':[2,1],
    'transformationValid':False,'sourceDistortionCoefficients':[.1,-.2,.001,.002,.003],
    'sourceDistortionModel':'CameraModel.Perspective','extrinsicsToCommon':source_extrinsics,
    'evidenceErrors':['fixture: SDK transformation was invalid']}
right_geometry={**left_geometry,'sequence':2**64-8,'transformationValid':True,
    'sourceDistortionCoefficients':[],'extrinsicsToCommon':None,'evidenceErrors':['fixture: source extrinsics unavailable']}
pair_extrinsics={'source':'sdk_frame_transformation_getExtrinsicsTransformationMatrixTo',
    'from':'left_source_optical','to':'right_source_optical','translationUnit':'meter','useSpecTranslation':False,
    'matrix':[1.,0,0,-.075,0,1.,0,.001,0,0,1.,.002,0,0,0,1.],
    'evidenceErrors':['fixture: source-frame matrix must not be relabeled as rectified triangulation']}
with_depth.update(rectified_left_geometry=left_geometry,rectified_right_geometry=right_geometry,
                  rectified_left_source_to_right_source=pair_extrinsics)
fixture=r'''
import Foundation
import AVFoundation
struct CameraInertialObservation:Decodable,Sendable {var isValid:Bool {true}}
struct ROBChessPieceDetection:Decodable {}
/* INTRINSICS */
/* HEADER */
/* DEPTH */
/* STEREO */
/* CLOUD */
private struct CloudSource {
    let sequence:UInt64,timestampNanoseconds:UInt64
    let capturedAtMilliseconds:Double?
    let captureStreamID:String?
    let intrinsics:CameraIntrinsics?
    let rgbSampleBuffer:CMSampleBuffer
    var rectifiedLeft:CameraStereoFrame?=nil
    var rectifiedRight:CameraStereoFrame?=nil
    var stereoSourceExtrinsics:CameraStereoPairExtrinsics?=nil
}
private func faceCloud(_ frameSet:CloudSource,depth:CameraDepthFrame)->ROBDepthCloudFrame {
    let sampleBuffer=frameSet.rgbSampleBuffer
    return /* FACE_CONSTRUCTOR */
}
private func bellyCloud(_ frameSet:CloudSource,depth:CameraDepthFrame)->ROBDepthCloudFrame {
    return /* BELLY_CONSTRUCTOR */
}
private func mapped(_ header:DepthCameraPacketHeader)->CameraIntrinsics? {return /* MAPPING */}
private func mappedStereo(_ header:DepthCameraPacketHeader,leftData:Data,rightData:Data)->(CameraStereoFrame,CameraStereoFrame,CameraStereoPairExtrinsics?) {
    return (/* LEFT_MAPPING */,/* RIGHT_MAPPING */,/* PAIR_MAPPING */)
}
private func encoded<T:Encodable>(_ value:T?)->Data? {
    guard let value else{return nil}
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    return try! encoder.encode(value)
}
@main enum Fixtures {
    static func main()throws {
        let decoder=JSONDecoder()
        let packets=try CommandLine.arguments.dropFirst().map{try decoder.decode(DepthCameraPacketHeader.self,from:Data(contentsOf:URL(fileURLWithPath:$0)))}
        let current=mapped(packets[0])!,old=mapped(packets[1])!,replacement=mapped(packets[2])!,depthEvidence=mapped(packets[3])!
        precondition(current.cameraServiceSourceSHA256=="/* EXPECTED_SHA */" && current.rgbOutputUndistorted==true)
        precondition(current.fx==100 && current.fy==101 && current.cx==1 && current.cy==0.5)
        precondition(old.cameraServiceSourceSHA256==nil && old.rgbOutputUndistorted==nil && old.isValid(forWidth:2,height:1),"Legacy viewing invented provenance or lost valid K")
        precondition(replacement.cameraServiceSourceSHA256==String(repeating:"d",count:64) && replacement.rgbOutputUndistorted==false,"Frame provenance was replaced by an app/source assumption")
        precondition(replacement.stereoMode=="near_field" && replacement.stereoModeSource=="sdk_initial_config_readback" && replacement.stereoExtendedDisparity==true && replacement.stereoSubpixel==false,
            "Native mapping lost or invented actual stereo-mode readback")
        precondition(old.frameExposureMicroseconds==nil && old.frameISO==nil && old.frameColorTemperatureKelvin==nil && old.frameObservationErrors==nil,
            "Legacy camera invented exposure defaults")
        precondition(replacement.frameExposureMicroseconds==12500 && replacement.frameISO==640 && replacement.frameColorTemperatureKelvin==4500 &&
            replacement.frameObservationErrors==["fixture: source readback error retained"],"Native mapping changed actual frame exposure/errors")
        precondition(old.depthIntrinsics==nil && old.depthRGBGeometryCorrespondence==nil,"Legacy viewing fabricated depth/RGB pixel correspondence")
        precondition(depthEvidence.depthIntrinsics==[100,0,1,0,101,0.5,0,0,1] && depthEvidence.depthSourceSize==[2,1])
        precondition(depthEvidence.depthSourceIntrinsics==depthEvidence.depthIntrinsics && depthEvidence.depthImageTransform==[1,0,0,0,1,0,0,0,1])
        precondition(depthEvidence.depthIntrinsicsSource=="actual_depth_transformation")
        precondition(depthEvidence.rgbTransformationSize==[2,1] && depthEvidence.depthTransformationSize==[2,1])
        precondition(depthEvidence.rgbSourceDistortionCoefficients==[0.1,-0.2,0.003,0.004] && depthEvidence.depthSourceDistortionCoefficients==[0.05,-0.1,0.001,0.002])
        precondition(depthEvidence.rgbSourceDistortionModel=="perspective" && depthEvidence.depthSourceDistortionModel=="perspective")
        precondition(depthEvidence.depthRGBGeometryCorrespondence?.status=="mismatched" && depthEvidence.depthRGBGeometryCorrespondence?.sdkAlignedToRGB==false,
            "Native mapping replaced an actual SDK mismatch with a dimension/K assumption")
        var pixels:CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault,2,1,kCVPixelFormatType_32BGRA,nil,&pixels)==kCVReturnSuccess)
        var format:CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixels!,formatDescriptionOut:&format)==noErr)
        var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid)
        var sample:CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixels!,formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample)==noErr)
        let depth=CameraDepthFrame(width:2,height:1,millimetersLittleEndian:Data([0xe8,0x03,0xd0,0x07]))
        let captured=Date().timeIntervalSince1970*1000
        let mono=mappedStereo(packets[3],leftData:Data([7,8]),rightData:Data([9,10]))
        let oldMono=mappedStereo(packets[1],leftData:Data([7,8]),rightData:Data([9,10]))
        precondition(oldMono.0.geometry==nil && oldMono.1.geometry==nil && oldMono.2==nil,
            "A legacy mono packet invented geometry/extrinsics")
        precondition(mono.0.geometry?.sequence==UInt64.max-8 && mono.0.geometry?.timestampNanoseconds==UInt64.max-16 &&
            mono.0.geometry?.timestampDeviceNanoseconds==UInt64.max-32,"Mono source clocks lost UInt64 precision")
        precondition(mono.0.geometry?.transformationValid==false && mono.1.geometry?.transformationValid==true)
        precondition(mono.0.geometry?.extrinsicsToCommon?.useSpecTranslation==false && mono.0.geometry?.extrinsicsToCommon?.lengthUnit=="meter")
        precondition(mono.1.geometry?.extrinsicsToCommon==nil && mono.2?.from=="left_source_optical" && mono.2?.to=="right_source_optical",
            "Source-frame axes were invented or promoted into rectified-frame authority")
        let inputs=[CloudSource(sequence:UInt64.max-5,timestampNanoseconds:UInt64.max-17,capturedAtMilliseconds:captured,
            captureStreamID:"real-manager-stream-17",intrinsics:current,rgbSampleBuffer:sample!),
            CloudSource(sequence:1,timestampNanoseconds:900,capturedAtMilliseconds:nil,captureStreamID:nil,intrinsics:old,rgbSampleBuffer:sample!),
            CloudSource(sequence:1,timestampNanoseconds:1000,capturedAtMilliseconds:captured,captureStreamID:"new-manager-stream-18",intrinsics:replacement,rgbSampleBuffer:sample!),
            CloudSource(sequence:2,timestampNanoseconds:1100,capturedAtMilliseconds:captured,captureStreamID:"depth-geometry-stream-19",intrinsics:depthEvidence,rgbSampleBuffer:sample!,
                rectifiedLeft:mono.0,rectifiedRight:mono.1,stereoSourceExtrinsics:mono.2)]
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
                precondition(cloud.calibratedIntrinsics?.depthIntrinsics==input.intrinsics?.depthIntrinsics &&
                    cloud.calibratedIntrinsics?.depthImageTransform==input.intrinsics?.depthImageTransform &&
                    cloud.calibratedIntrinsics?.depthRGBGeometryCorrespondence?.sdkAlignedToRGB==input.intrinsics?.depthRGBGeometryCorrespondence?.sdkAlignedToRGB,
                    "Cloud notification changed or lost actual depth projection evidence")
                precondition(cloud.calibratedIntrinsics?.stereoMode==input.intrinsics?.stereoMode &&
                    cloud.calibratedIntrinsics?.stereoSubpixel==input.intrinsics?.stereoSubpixel,
                    "Cloud notification changed actual stereo-mode provenance")
                precondition(cloud.calibratedIntrinsics?.frameExposureMicroseconds==input.intrinsics?.frameExposureMicroseconds &&
                    cloud.calibratedIntrinsics?.frameISO==input.intrinsics?.frameISO &&
                    cloud.calibratedIntrinsics?.frameColorTemperatureKelvin==input.intrinsics?.frameColorTemperatureKelvin &&
                    cloud.calibratedIntrinsics?.frameObservationErrors==input.intrinsics?.frameObservationErrors)
                precondition(cloud.rectifiedLeft?.pixels==input.rectifiedLeft?.pixels && cloud.rectifiedRight?.pixels==input.rectifiedRight?.pixels,
                    "Cloud forwarding changed or borrowed mono pixels")
                precondition(encoded(cloud.rectifiedLeft?.geometry)==encoded(input.rectifiedLeft?.geometry) &&
                    encoded(cloud.rectifiedRight?.geometry)==encoded(input.rectifiedRight?.geometry) &&
                    encoded(cloud.stereoSourceExtrinsics)==encoded(input.stereoSourceExtrinsics),
                    "Face/belly cloud lost exact source mono geometry, units, optional fields or evidence errors")
                precondition(cloud.width==2 && cloud.height==1 && cloud.millimetersLittleEndian as Data==depth.millimetersLittleEndian)
            }
        }
        let legacyCloud=ROBDepthCloudFrame(depth:depth,rgbSampleBuffer:sample!)
        precondition(legacyCloud.sourceSequence==nil && legacyCloud.sourceTimestampNanoseconds==nil &&
            legacyCloud.sourceCapturedAtMilliseconds==nil && legacyCloud.sourceCaptureStreamID==nil,
            "Legacy cloud initializer invented source provenance")
        precondition(legacyCloud.rectifiedLeft==nil && legacyCloud.rectifiedRight==nil && legacyCloud.stereoSourceExtrinsics==nil)
        print("Camera worker provenance runtime passed: actual worker/source clocks, stereo pixels/geometry/extrinsics, exposure, nil/false/errors and face/belly forwarding preserved")
    }
}
'''.replace('/* INTRINSICS */',depth_geometry+'\n'+structure).replace('/* HEADER */',header).replace('/* DEPTH */',depth_structure).replace('/* STEREO */',stereo_structures).replace('/* CLOUD */',cloud).replace('/* FACE_CONSTRUCTOR */',face_constructor).replace('/* BELLY_CONSTRUCTOR */',belly_constructor).replace('/* MAPPING */',mapping).replace('/* LEFT_MAPPING */',stereo_constructor('rectifiedLeft')).replace('/* RIGHT_MAPPING */',stereo_constructor('rectifiedRight')).replace('/* PAIR_MAPPING */',pair_mapping).replace('/* EXPECTED_SHA */',actual['running_service_source_sha256'])
with tempfile.TemporaryDirectory(prefix='rob-camera-worker-provenance-',dir='/private/tmp')as directory:
    root=Path(directory);paths=[]
    for name,value in [('current',actual),('legacy',legacy),('replacement',replacement),('depth-evidence',with_depth)]:
        path=root/(name+'.json');path.write_text(json.dumps(value));paths.append(str(path))
    swift=root/'Fixture.swift';swift.write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(root/'fixture')],check=True)
    subprocess.run([str(root/'fixture'),*paths],check=True)
