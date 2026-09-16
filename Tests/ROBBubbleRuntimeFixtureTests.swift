import AppKit
import AVFoundation

// Headless hardware substitutes: these tests cannot open a serial port.
@objcMembers final class ROBSerialBox: NSObject {
    var bubbleHardwareReady = true
    var isNeckCommandStateKnown = true
    var commandedNeckPanTarget = 6000
    var commandedLowerNeckTiltTarget = 6000
    var commandedUpperNeckTiltTarget = 6000
    var writes: [[Int]] = []
    func stopBubbleRelaysForWatchdog() { }
    func applyBubbleTarget(_ target: Int, channel: Int) -> Bool {
        writes.append([channel, target]); return bubbleHardwareReady
    }
}
extension Notification.Name {
    static let robControlLiveSessionDidEnd = Notification.Name("fixture-session-ended")
}
enum ROBControlLiveSessionNotification { static let sessionIDKey = "session" }
struct CameraDepthFrame {
    let width: Int; let height: Int; let millimetersLittleEndian: Data
    func distanceMillimeters(x: Int, y: Int) -> UInt16? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = 2 * (y * width + x)
        let mm = UInt16(millimetersLittleEndian[offset]) | UInt16(millimetersLittleEndian[offset + 1]) << 8
        return mm == 0 ? nil : mm
    }
}
struct CameraIntrinsics {
    let fx: Double; let fy: Double; let cx: Double; let cy: Double
    func isValid(forWidth: Int, height: Int) -> Bool { fx > 0 && fy > 0 }
}
struct CameraFrameSet {
    let rgbSampleBuffer: CMSampleBuffer
    let alignedDepth: CameraDepthFrame?
    let intrinsics: CameraIntrinsics?
}

@main struct BubbleRuntimeTests {
    static func main() throws {
        let runtime = ROBBubbleRuntime(context: CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false]))
        let box = ROBSerialBox(); runtime.serialBox = box
        let a = UUID(), b = UUID(), sessionA = UUID(), sessionB = UUID()
        func request(_ operation: ROBBubbleOperation, sequence: UInt64, controller: UUID = a, session: UUID = sessionA,
                     frame: UUID? = nil, u: Double? = nil, v: Double? = nil) {
            runtime.receive(.init(controllerID: controller, sessionID: session, sequence: sequence,
                command: .init(operation, frameID: frame, u: u, v: v)))
        }
        request(.spinOn, sequence: 1)
        precondition(!runtime.snapshot().spin)
        request(.authorize, sequence: 2)
        precondition(runtime.snapshot().armed)
        request(.spinOn, sequence: 1, controller: b, session: sessionB)
        precondition(!runtime.snapshot().spin, "A second controller cannot use another session's authorization")
        request(.spinOn, sequence: 3)
        precondition(runtime.snapshot().spin)
        request(.spinOff, sequence: 3)
        precondition(runtime.snapshot().spin, "Duplicate sequences cannot change motor outputs")
        request(.stop, sequence: 2, controller: b, session: sessionB)
        precondition(!runtime.snapshot().armed && !runtime.snapshot().spin)
        request(.authorize, sequence: 4)
        precondition(runtime.snapshot().armed)

        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 20, 20, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescription: format!,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let depth = CameraDepthFrame(width: 20, height: 20, millimetersLittleEndian: Data((0..<400).flatMap { _ in [UInt8(0xd0), 0x07] }))
        runtime.setLocalPreview(true)
        runtime.offer(.init(rgbSampleBuffer: sample!, alignedDepth: depth,
                            intrinsics: .init(fx: 10, fy: 10, cx: 9.5, cy: 9.5)))
        let deadline = Date().addingTimeInterval(1.5)
        while runtime.snapshot(includeFrame: true).frameID == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let frameID = runtime.snapshot(includeFrame: true).frameID else { fatalError("No preview frame") }
        request(.aim, sequence: 5, frame: UUID(), u: 0.5, v: 0.5)
        precondition(runtime.pan == 4000, "Unrecognized frame IDs must fail closed")
        request(.aim, sequence: 6, frame: frameID, u: 0.5, v: 0.5)
        precondition(runtime.pan == 6000 && runtime.tilt == 6000)
        precondition(runtime.snapshot().targetDescription.contains("UNCALIBRATED"))
        precondition(box.writes.isEmpty, "Dry-run aiming and motor commands must never write hardware")
        NotificationCenter.default.post(name: .robControlLiveSessionDidEnd, object: nil,
            userInfo: [ROBControlLiveSessionNotification.sessionIDKey: sessionA])
        precondition(!runtime.snapshot().armed)
        request(.authorize, sequence: 7)
        request(.releaseMount, sequence: 8)
        precondition(!runtime.snapshot().armed && !runtime.snapshot().spin && !runtime.snapshot().blower)
        precondition(box.writes == [[6, 0], [7, 0]], "Explicit OFF must still release servo pulses in dry run")
        let watchdog = ROBBubbleRelayWatchdog()
        let cutoff = DispatchSemaphore(value: 0)
        watchdog.update(deadline: ProcessInfo.processInfo.systemUptime + 0.05) { cutoff.signal() }
        // Deliberately do not run the main run loop: cutoff must be independent.
        precondition(cutoff.wait(timeout: .now() + 1) == .success)
        precondition(watchdog.didTrip && !watchdog.performIfUntripped { true })
        print("Bubble runtime fixtures passed: session ownership, replay, any-operator stop, RGB-D targeting, dry run, disconnect, release")
    }
}
