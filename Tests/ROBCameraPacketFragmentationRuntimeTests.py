#!/usr/bin/env python3
"""Compile the production IPC drain loop and exercise fragmented packet lifetimes."""
from pathlib import Path
import subprocess
import tempfile

from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Cerebro/CameraManager.swift").read_text()
methods = "\n".join(braced_declaration(source, signature) for signature in (
    "private func drainPackets()", "private func drainBufferedPackets()",
    "private func integer32BigEndian(", "private static func expectedPayloadLength(",
    "private func resetPacketBuffer()", "private func cancelConnection()"))
# RGB sample construction/delivery follows packet consumption. Stub only that
# downstream work; framing, decoding, validation, copying and cache lifetime are real.
start = methods.index("            guard let sampleBuffer = autoreleasepool(invoking:")
end = methods.index("\nprivate func integer32BigEndian(", start)
intrinsics_mapping = braced_declaration(source, "intrinsics: header.rgbIntrinsics.flatMap")
intrinsics_mapping = intrinsics_mapping.removeprefix("intrinsics: ")
methods = methods[:start] + """
            let observedIntrinsics:CameraIntrinsics? = /* ACTUAL_INTRINSICS_MAPPING */
            let observedLeft = CameraStereoFrame(width: header.stereoWidth, height: header.stereoHeight,
                pixels: leftData, geometry: header.rectifiedLeftGeometry)
            let observedRight = CameraStereoFrame(width: header.stereoWidth, height: header.stereoHeight,
                pixels: rightData, geometry: header.rectifiedRightGeometry)
            delivered.append(Delivered(header: header, rgb: rgbData, depth: depthData,
                left: leftData, right: rightData, intrinsics: observedIntrinsics,
                rectifiedLeft: observedLeft, rectifiedRight: observedRight,
                sourceExtrinsics: header.rectifiedLeftSourceToRightSource))
        }
    }
""".replace("/* ACTUAL_INTRINSICS_MAPPING */", intrinsics_mapping) + methods[end:]
for signature in ("case .ready:", "case .failed(let error):", "case .cancelled:", "case .waiting(let error):"):
    block = source[source.index(signature, source.index("private func connectIfPossible()")):]
    block = block.split("\n            case ", 1)[0]
    assert "resetPacketBuffer()" in block, signature + " does not invalidate packet state"

harness = r'''
import Foundation
enum DecoderMetrics { static var count = 0 }
struct JSONDecoder {
    func decode<T:Decodable>(_ type:T.Type, from data:Data)throws->T {
        DecoderMetrics.count += 1
        return try Foundation.JSONDecoder().decode(type, from:data)
    }
}
struct CameraInertialObservation:Decodable,Sendable { var isValid:Bool {true} }
struct ROBChessPieceDetection:Decodable {}
/* GEOMETRY */
/* HEADER */
/* ERROR */
struct Connection {
    var stateUpdateHandler:((Int)->Void)?
    func cancel() {}
}
private struct Delivered {
    let header:DepthCameraPacketHeader
    let rgb:Data,depth:Data,left:Data,right:Data
    let intrinsics:CameraIntrinsics?
    let rectifiedLeft:CameraStereoFrame,rectifiedRight:CameraStereoFrame
    let sourceExtrinsics:CameraStereoPairExtrinsics?
}
private final class Stream {
    private static let protocolMagic=Data([0x43,0x44,0x50,0x31])
    private static let protocolVersion=2
    private static let maximumHeaderBytes=64*1024
    private static let maximumPayloadBytes=64*1024*1024
    private static let receiveBufferCompactionThresholdBytes=64*1024*1024
    private var receiveBuffer=Data()
    /* PENDING */
    private var pendingPacket:PendingPacket?
    private var connection:Connection?=Connection()
    private var reportedStreaming=false
    var delivered:[Delivered]=[]
    var cached:Bool {pendingPacket != nil}
    var cachedLength:Int? {pendingPacket?.packetLength}
    var buffered:Int {receiveBuffer.count}
    func offer(_ bytes:Data)throws {receiveBuffer.append(bytes);try drainPackets()}
    func disconnect() {cancelConnection()}
    /* METHODS */
}
func packet(_ sequence:UInt64, rich:Bool=false, invalidLength:Bool=false)->(Data,Int) {
    var header:[String:Any]=[
        "protocol_version":2,"sequence":sequence,"timestamp_ns":UInt64.max-sequence,
        "captured_at_milliseconds":1_000_000.0+Double(sequence),
        "rgb_width":4,"rgb_height":2,"rgb_format":"RGB888","rgb_length":invalidLength ? 25:24,
        "depth_width":4,"depth_height":2,"depth_format":"DEPTH16LE","depth_unit":"millimeter","depth_length":16,
        "stereo_width":2,"stereo_height":1,"stereo_format":"GRAY8","left_length":2,"right_length":2]
    if rich {
        header["running_service_source_sha256"]=String(repeating:"a",count:64)
        header["rgb_output_undistorted"]=false
        header["rgb_intrinsics"]=[100.0,0,2,0,101,1,0,0,1]
        header["depth_intrinsics"]=[100.0,0,2,0,101,1,0,0,1]
        header["depth_source_size"]=[4,2]
        header["depth_image_transform"]=[1.0,0,0,0,1,0,0,0,1]
        header["depth_rgb_geometry_correspondence"]=["status":"mismatched","dimensionsMatch":true,
            "sdkAlignedToRGB":false,"maximumIntrinsicDifferencePixels":0.0]
        header["rgb_frame_exposure_microseconds"]=8750.5
        header["rgb_frame_iso"]=320
        header["rgb_frame_color_temperature_kelvin"]=4600
        header["rgb_frame_observation_errors"]=["synthetic sensor observation; no authority"]
        for (side,fx,fy,cx,offset) in [("left",55.0,56.0,0.25,UInt64(31)),("right",65.0,66.0,0.75,UInt64(43))] {
            header["rectified_"+side+"_geometry"]=[
                "source":"actual_sdk_"+side+"_frame_fixture", "width":2,"height":1,
                "sequence":UInt64.max-sequence-offset,
                "timestampNanoseconds":UInt64.max-sequence-offset-1,
                "timestampDeviceNanoseconds":UInt64.max-sequence-offset-2,
                "intrinsics":[fx,0,cx,0,fy,0.5,0,0,1],"sourceSize":[1280,800],
                "sourceIntrinsics":[fx*2,0,cx*2,0,fy*2,1,0,0,1],
                "imageTransform":[0.5,0,0,0,0.5,0,0,0,1],"transformationSize":[2,1],
                "transformationValid":true,"sourceDistortionCoefficients":[0.1,-0.2,0.003,0.004],
                "sourceDistortionModel":"perspective","evidenceErrors":[],
                "extrinsicsToCommon":["source":"SDK_SOURCE_COORDINATES_ONLY","toCameraSocket":"CAM_A",
                    "sourceLengthUnit":"centimeter","lengthUnit":"meter","useSpecTranslation":false,
                    "matrix":[1.0,0,0,side=="left" ? 0.012:-0.063,0,1,0,0,0,0,1,0,0,0,0,1],
                    "evidenceErrors":["rectified convention not independently verified"]]]
        }
        header["rectified_left_source_to_right_source"]=["source":"SDK_SOURCE_PAIR_ONLY",
            "from":"CAM_B","to":"CAM_C","translationUnit":"meter","useSpecTranslation":false,
            "matrix":[1.0,0,0,-0.075,0,1,0,0.001,0,0,1,0,0,0,0,1],"evidenceErrors":[]]
    }
    let bytes=try! JSONSerialization.data(withJSONObject:header,options:[.sortedKeys])
    var result=Data([0x43,0x44,0x50,0x31])
    let length=UInt32(bytes.count)
    result.append(contentsOf:[UInt8((length>>24)&255),UInt8((length>>16)&255),UInt8((length>>8)&255),UInt8(length&255)])
    result.append(bytes)
    result.append(contentsOf:Array(repeating:UInt8(sequence),count:24))
    result.append(contentsOf:Array(repeating:UInt8(sequence+1),count:16))
    result.append(contentsOf:[3,4,5,6])
    return(result,8+bytes.count)
}
@main enum Test {
    static func main()throws {
        let stream=Stream(),(first,headerEnd)=packet(7,rich:true)
        for byte in first.prefix(headerEnd-1) {try stream.offer(Data([byte]))}
        precondition(DecoderMetrics.count==0 && !stream.cached)
        try stream.offer(Data([first[headerEnd-1]]))
        precondition(DecoderMetrics.count==1 && stream.cached && stream.cachedLength==first.count)
        for byte in first[headerEnd..<(first.count-1)] {try stream.offer(Data([byte]))}
        precondition(DecoderMetrics.count==1 && stream.cached && stream.delivered.isEmpty,
            "Fragmented payload repeatedly decoded its already validated header")
        try stream.offer(Data([first.last!]))
        precondition(DecoderMetrics.count==1 && !stream.cached && stream.buffered==0)
        let value=stream.delivered[0]
        precondition(value.header.sequence==7 && value.header.timestampNanoseconds==UInt64.max-7)
        precondition(value.header.capturedAtMilliseconds==1_000_007 && value.rgb==Data(repeating:7,count:24))
        precondition(value.depth==Data(repeating:8,count:16) && value.left==Data([3,4]) && value.right==Data([5,6]))
        precondition(value.header.rgbOutputUndistorted==false && value.header.runningServiceSourceSHA256==String(repeating:"a",count:64))
        precondition(value.header.depthIntrinsics==[100,0,2,0,101,1,0,0,1] && value.header.depthSourceSize==[4,2])
        precondition(value.header.depthRGBGeometryCorrespondence?.sdkAlignedToRGB==false)
        precondition(value.intrinsics?.frameExposureMicroseconds==8750.5 && value.intrinsics?.frameISO==320)
        precondition(value.intrinsics?.frameColorTemperatureKelvin==4600 &&
            value.intrinsics?.frameObservationErrors==["synthetic sensor observation; no authority"])
        let left=value.rectifiedLeft.geometry!,right=value.rectifiedRight.geometry!
        precondition(value.rectifiedLeft.pixels==Data([3,4]) && value.rectifiedRight.pixels==Data([5,6]))
        precondition(left.intrinsics==[55,0,0.25,0,56,0.5,0,0,1] && right.intrinsics==[65,0,0.75,0,66,0.5,0,0,1])
        precondition(left.intrinsics != value.header.rgbIntrinsics && right.intrinsics != value.header.rgbIntrinsics,
            "Mono observations borrowed RGB K")
        precondition(left.sequence==UInt64.max-7-31 && right.sequence==UInt64.max-7-43)
        precondition(left.timestampNanoseconds==UInt64.max-7-32 && right.timestampDeviceNanoseconds==UInt64.max-7-45)
        precondition(left.extrinsicsToCommon?.sourceLengthUnit=="centimeter" &&
            left.extrinsicsToCommon?.lengthUnit=="meter" && left.extrinsicsToCommon?.useSpecTranslation==false)
        precondition(value.sourceExtrinsics?.from=="CAM_B" && value.sourceExtrinsics?.to=="CAM_C" &&
            value.sourceExtrinsics?.matrix?[3] == -0.075 && value.sourceExtrinsics?.translationUnit=="meter")
        let extrinsicsJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value.sourceExtrinsics!)) as! [String:Any]
        precondition(extrinsicsJSON["registrationVerified"]==nil && extrinsicsJSON["triangulationVerified"]==nil,
            "Source extrinsics gained calibration authority")

        let(second,_)=packet(8), (third,_)=packet(9,rich:true)
        try stream.offer(second+third)
        precondition(DecoderMetrics.count==3 && stream.delivered.map{$0.header.sequence}==[7,8,9])
        precondition(stream.delivered[1].header.rgbOutputUndistorted==nil && stream.delivered[1].header.depthIntrinsics==nil,
            "A legacy/other-role packet inherited cached optional calibration evidence")
        precondition(stream.delivered[1].intrinsics==nil && stream.delivered[1].rectifiedLeft.geometry==nil &&
            stream.delivered[1].rectifiedRight.geometry==nil && stream.delivered[1].sourceExtrinsics==nil,
            "A missing legacy field inherited prior exposure/mono/extrinsics evidence")
        precondition(stream.delivered[1].rectifiedLeft.pixels==Data([3,4]))
        precondition(!stream.cached && stream.buffered==0)

        let(partial,partialHeader)=packet(10,rich:true)
        try stream.offer(partial.prefix(partialHeader+2))
        precondition(stream.cached && DecoderMetrics.count==4)
        stream.disconnect()
        precondition(!stream.cached && stream.buffered==0)
        let(fresh,_)=packet(11)
        try stream.offer(fresh)
        precondition(DecoderMetrics.count==5 && stream.delivered.last!.header.sequence==11)

        let(invalid,_)=packet(12,rich:true,invalidLength:true)
        do {try stream.offer(invalid);preconditionFailure("Invalid payload length accepted")}
        catch {precondition(!stream.cached && DecoderMetrics.count==6)}
        stream.disconnect()
        var malformed=Data([0x43,0x44,0x50,0x31,0,0,0,1]);malformed.append(123)
        do {try stream.offer(malformed);preconditionFailure("Malformed JSON accepted")}
        catch {precondition(!stream.cached && DecoderMetrics.count==7)}
        stream.disconnect()
        try stream.offer(fresh)
        precondition(DecoderMetrics.count==8 && !stream.cached && stream.buffered==0)
        print("Camera IPC runtime passed: one header decode per fragmented packet; coalesced packets, disconnect, invalid headers, distinct mono K/64-bit timing, exposure readbacks, legacy absence and source-only extrinsics preserved")
    }
}
'''.replace("/* METHODS */", methods).replace("/* PENDING */", braced_declaration(source,"private struct PendingPacket"))
harness = harness.replace("/* HEADER */", braced_declaration(source,"private struct DepthCameraPacketHeader:"))
harness = harness.replace("/* ERROR */", braced_declaration(source,"private enum DepthCameraIPCError:"))
harness = harness.replace("/* GEOMETRY */", "\n".join(braced_declaration(source, signature) for signature in (
    "struct CameraDepthRGBGeometryCorrespondence:", "struct CameraIntrinsics:",
    "struct CameraStereoSourceExtrinsics:", "struct CameraStereoPairExtrinsics:",
    "struct CameraStereoGeometry:", "struct CameraStereoFrame:")))
with tempfile.TemporaryDirectory(prefix="cerebro-camera-packets-", dir="/private/tmp") as directory:
    folder=Path(directory)
    fixture=folder/"Fixture.swift"
    fixture.write_text(harness)
    subprocess.run(["xcrun","swiftc","-swift-version","5","-parse-as-library",str(fixture),"-o",str(folder/"fixture")],check=True)
    subprocess.run([str(folder/"fixture")],check=True)
