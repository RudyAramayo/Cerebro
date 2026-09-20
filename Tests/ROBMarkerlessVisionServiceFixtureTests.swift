import Foundation
import CoreMedia

// No chess observations are supplied in this camera-depth fixture.
struct ROBChessPieceDetection {}

@main struct ROBMarkerlessVisionServiceFixtureTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "MarkerlessFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let python = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("markerless-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = #"""
import sys,json,base64,struct
for line in sys.stdin:
    frame=json.loads(line)
    assert frame['camera']=='belly' and frame['streamID']=='fixture-stream'
    assert [frame['width'],frame['height']]==[240,160]
    assert frame['intrinsics']==[200,205,120,80]
    depth=base64.b64decode(frame['depth'])
    assert len(depth)==240*160*2
    assert struct.unpack_from('<H',depth,0)[0]==900
    assert struct.unpack_from('<H',depth,len(depth)-2)[0]==1696
    print(json.dumps(dict(schemaVersion=1,source='markerless_rgbd',capturedAtMilliseconds=frame['capturedAtMilliseconds'],sequence=frame['sequence'],status='unavailable',detail='Depth packing verified')),flush=True)
"""#
        try script.write(to: temporary.appendingPathComponent("markerless.py"), atomically: true, encoding: .utf8)
        var buffer: CMSampleBuffer?
        let code = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &buffer)
        try expect(code == noErr && buffer != nil, "Unable to create inert camera buffer")
        var bytes = Data()
        for y in 0..<320 { for x in 0..<480 {
            let value = UInt16(900 + x + y)
            bytes.append(UInt8(value & 255)); bytes.append(UInt8(value >> 8))
        } }
        let frame = CameraFrameSet(source: .depthAIService, sequence: 1, timestampNanoseconds: 100,
            rgbSampleBuffer: buffer!, alignedDepth: CameraDepthFrame(width: 480, height: 320, millimetersLittleEndian: bytes),
            intrinsics: CameraIntrinsics(fx: 400, fy: 410, cx: 240, cy: 160))
        let service = ROBMarkerlessVisionService(resources: temporary, python: python)
        guard let path = service.start() else { throw CocoaError(.fileReadUnknown) }
        service.offer(frame, role: .belly, streamID: "fixture-stream")
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: path.path) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        try expect(object["detail"] as? String == "Depth packing verified", "Worker did not validate depth coordinates")
        service.stop()
        try expect(!FileManager.default.fileExists(atPath: path.path), "Stopping left a stale observation")

        // A stalled reader must never leave the camera or main thread waiting
        // indefinitely on a full stdin pipe. No hardware is opened in this test.
        try "import time\ntime.sleep(30)\n".write(to: temporary.appendingPathComponent("markerless.py"), atomically: true, encoding: .utf8)
        _ = service.start()
        let began = Date()
        service.offer(frame, role: .belly, streamID: "fixture-stream")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        service.stop()
        try expect(Date().timeIntervalSince(began) < 2, "Stalled vision stdin blocked shutdown")
        print("Markerless camera service passed: real frame types, depth/intrinsics packing, atomic observation cleanup, bounded stalled-worker shutdown")
    }
}
