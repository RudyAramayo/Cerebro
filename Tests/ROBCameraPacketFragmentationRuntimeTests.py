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
methods = methods[:start] + """
            delivered.append(Delivered(header: header, rgb: rgbData, depth: depthData,
                                       left: leftData, right: rightData))
        }
    }
""" + methods[end:]
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
struct CameraInertialObservation:Decodable {}
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

        let(second,_)=packet(8), (third,_)=packet(9,rich:true)
        try stream.offer(second+third)
        precondition(DecoderMetrics.count==3 && stream.delivered.map{$0.header.sequence}==[7,8,9])
        precondition(stream.delivered[1].header.rgbOutputUndistorted==nil && stream.delivered[1].header.depthIntrinsics==nil,
            "A legacy/other-role packet inherited cached optional calibration evidence")
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
        print("Camera IPC runtime passed: one header decode per fragmented packet; coalesced packets, disconnect, invalid headers and optional metadata preserved")
    }
}
'''.replace("/* METHODS */", methods).replace("/* PENDING */", braced_declaration(source,"private struct PendingPacket"))
harness = harness.replace("/* HEADER */", braced_declaration(source,"private struct DepthCameraPacketHeader:"))
harness = harness.replace("/* ERROR */", braced_declaration(source,"private enum DepthCameraIPCError:"))
harness = harness.replace("/* GEOMETRY */", braced_declaration(source,"struct CameraDepthRGBGeometryCorrespondence:"))
with tempfile.TemporaryDirectory(prefix="cerebro-camera-packets-", dir="/private/tmp") as directory:
    folder=Path(directory)
    fixture=folder/"Fixture.swift"
    fixture.write_text(harness)
    subprocess.run(["xcrun","swiftc","-swift-version","5","-parse-as-library",str(fixture),"-o",str(folder/"fixture")],check=True)
    subprocess.run([str(folder/"fixture")],check=True)
