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
import sys,json,base64,struct,time
time.sleep(1.1) # Model startup exceeds the unchanged750ms pipe-write bound.
print(json.dumps(dict(schemaVersion=1,source='markerless_ready')),flush=True)
for line in sys.stdin:
    frame=json.loads(line)
    assert frame['camera']=='belly' and frame['streamID']=='fixture-stream'
    assert [frame['width'],frame['height']]==[240,160]
    assert frame['intrinsics']==[200,205,120,80]
    depth=base64.b64decode(frame['depth'])
    assert len(depth)==240*160*2
    assert struct.unpack_from('<H',depth,0)[0]==900
    assert struct.unpack_from('<H',depth,len(depth)-2)[0]==1696
    print(json.dumps(dict(schemaVersion=1,source='markerless_rgbd',capturedAtMilliseconds=frame['capturedAtMilliseconds'],sequence=frame['sequence'],camera=frame['camera'],streamID=frame['streamID'],status='unavailable',detail='Depth packing verified')),flush=True)
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
        var frame = CameraFrameSet(source: .depthAIService, sequence: 1, timestampNanoseconds: 100,
            rgbSampleBuffer: buffer!, alignedDepth: CameraDepthFrame(width: 480, height: 320, millimetersLittleEndian: bytes),
            intrinsics: CameraIntrinsics(fx: 400, fy: 410, cx: 240, cy: 160),
            capturedAtMilliseconds: Date().timeIntervalSince1970 * 1000 - 20)
        let service = ROBMarkerlessVisionService(resources: temporary, python: python)
        guard let path = service.start() else { throw CocoaError(.fileReadUnknown) }
        var failed=false;service.onFailure={failed=true}
        service.offer(frame,role:.belly,streamID:"fixture-stream")
        RunLoop.current.run(until:Date().addingTimeInterval(1.35))
        try expect(!failed && !FileManager.default.fileExists(atPath:path.path),
                   "Cold worker input timed out or startup pixels became an observation")
        var delayed = frame; delayed.capturedAtMilliseconds = Date().timeIntervalSince1970 * 1000 - 2000
        service.offer(delayed, role: .belly, streamID: "fixture-stream")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(!FileManager.default.fileExists(atPath: path.path), "Buffered old pixels were relabeled as fresh")
        var unknown = frame; unknown.capturedAtMilliseconds = nil
        service.offer(unknown, role: .belly, streamID: "fixture-stream")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(!FileManager.default.fileExists(atPath: path.path), "Unknown capture age was allowed")
        frame.capturedAtMilliseconds = Date().timeIntervalSince1970 * 1000 - 20
        service.offer(frame, role: .belly, streamID: "fixture-stream")
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: path.path) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        try expect(object["detail"] as? String == "Depth packing verified", "Worker did not validate depth coordinates")
        try expect(object["capturedAtMilliseconds"] as? Double == frame.capturedAtMilliseconds,
                   "Camera capture age changed during transport")
        service.stop()
        try expect(!FileManager.default.fileExists(atPath: path.path), "Stopping left a stale observation")

        // Changing calibration while inference is busy must invalidate the
        // exact prior stream immediately and discard its late worker result.
        let delayedScript = #"""
import sys,json,time
print(json.dumps(dict(schemaVersion=1,source='markerless_ready')),flush=True)
for line in sys.stdin:
    f=json.loads(line);time.sleep(.20)
    print(json.dumps(dict(schemaVersion=1,source='markerless_rgbd',camera=f['camera'],streamID=f['streamID'],capturedAtMilliseconds=f['capturedAtMilliseconds'],sequence=f['sequence'],status='unavailable')),flush=True)
"""#
        try delayedScript.write(to: temporary.appendingPathComponent("markerless.py"), atomically: true, encoding: .utf8)
        _ = service.start()
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        var invalidated = false
        service.onObservation = { value in
            if value["source"] as? String == "camera_context_invalidated",
               value["camera"] as? String == "belly", value["streamID"] as? String == "old-calibration" {
                invalidated = true
            }
        }
        frame.capturedAtMilliseconds = Date().timeIntervalSince1970 * 1000 - 10
        service.offer(frame, role: .belly, streamID: "old-calibration")
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        frame.capturedAtMilliseconds = Date().timeIntervalSince1970 * 1000 - 10
        service.offer(frame, role: .belly, streamID: "new-calibration")
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        try expect(invalidated, "Known calibration change retained prior camera authority")
        if FileManager.default.fileExists(atPath:path.path) {
            let current=try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
            try expect(current["streamID"] as? String=="new-calibration","Late old-calibration fit was published")
        }
        service.stop()

        // A stalled reader must never leave the camera or main thread waiting
        // indefinitely on a full stdin pipe. No hardware is opened in this test.
        try "import time\ntime.sleep(30)\n".write(to: temporary.appendingPathComponent("markerless.py"), atomically: true, encoding: .utf8)
        _ = service.start()
        let began = Date()
        frame.capturedAtMilliseconds = Date().timeIntervalSince1970 * 1000 - 20
        service.offer(frame, role: .belly, streamID: "fixture-stream")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        service.stop()
        try expect(Date().timeIntervalSince(began) < 2, "Stalled vision stdin blocked shutdown")
        print("Markerless camera service passed: cold startup handshake, no startup frame replay/authority, capture age preserved, delayed/unknown-age frames rejected, depth/intrinsics packing, atomic cleanup, bounded stalled-worker shutdown")
    }
}
