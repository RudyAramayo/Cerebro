import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

private enum EncoderSmokeFailure: Error {
    case pixelBuffer(CVReturn)
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
    case noOutput
    case unexpectedOutput(String)
}

@main
private enum ROBCameraH264EncoderSmokeRunner {
    static func main() throws {
        var sourceBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            640,
            480,
            kCVPixelFormatType_32BGRA,
            nil,
            &sourceBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let sourceBuffer else {
            throw EncoderSmokeFailure.pixelBuffer(pixelStatus)
        }
        CVPixelBufferLockBaseAddress(sourceBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(sourceBuffer) {
            memset(baseAddress, 0x20, CVPixelBufferGetDataSize(sourceBuffer))
        }
        CVPixelBufferUnlockBaseAddress(sourceBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: sourceBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw EncoderSmokeFailure.formatDescription(formatStatus)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 20),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: sourceBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw EncoderSmokeFailure.sampleBuffer(sampleStatus)
        }

        let outputSemaphore = DispatchSemaphore(value: 0)
        let outputLock = NSLock()
        var receivedOutput: ROBCameraH264EncoderOutput?
        let encoder = try ROBCameraH264Encoder(
            width: 320,
            height: 240,
            framesPerSecond: 20,
            averageBitrate: 500_000
        ) { output in
            outputLock.lock()
            receivedOutput = output
            outputLock.unlock()
            outputSemaphore.signal()
        }
        guard try encoder.encode(sampleBuffer) else {
            throw EncoderSmokeFailure.unexpectedOutput("the first frame was throttled")
        }
        guard outputSemaphore.wait(timeout: .now() + 5) == .success else {
            encoder.finish()
            throw EncoderSmokeFailure.noOutput
        }
        encoder.finish()

        outputLock.lock()
        let output = receivedOutput
        outputLock.unlock()
        switch output {
        case .frame(let frame):
            guard frame.isKeyFrame,
                  frame.parameterSets?.count ?? 0 >= 2,
                  [1, 2, 4].contains(frame.nalUnitHeaderLength),
                  !frame.payload.isEmpty else {
                throw EncoderSmokeFailure.unexpectedOutput("the first output was not a complete IDR")
            }
            _ = try ROBVideoEncodedAccessUnit(
                sessionID: UUID(),
                id: UUID(),
                codec: .h264,
                sequence: frame.sequence,
                captureTimestampUnixMilliseconds: frame.captureTimestampUnixMilliseconds,
                presentationTimestamp: frame.presentationTimeMicroseconds,
                duration: Int64(frame.durationMicroseconds),
                timescale: 1_000_000,
                isKeyFrame: frame.isKeyFrame,
                codecConfigurationGeneration: 1,
                nalLengthFieldBytes: frame.nalUnitHeaderLength,
                payload: frame.payload
            )
        case .frameDropped:
            throw EncoderSmokeFailure.unexpectedOutput("VideoToolbox dropped the first frame")
        case .failed(let error):
            throw EncoderSmokeFailure.unexpectedOutput(error.localizedDescription)
        case nil:
            throw EncoderSmokeFailure.noOutput
        }
        print("ROBCameraH264Encoder synthetic-frame smoke test passed")
    }
}
