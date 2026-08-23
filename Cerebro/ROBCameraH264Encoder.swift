import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum ROBCameraH264EncoderError: LocalizedError {
    case invalidConfiguration
    case compressionSession(OSStatus)
    case compressionProperty(String, OSStatus)
    case pixelTransferSession(OSStatus)
    case pixelBufferPoolUnavailable
    case pixelBufferAllocation(CVReturn)
    case pixelTransfer(OSStatus)
    case missingImageBuffer
    case missingEncodedSample
    case missingDataBuffer
    case blockBufferCopy(OSStatus)
    case missingFormatDescription
    case parameterSetExtraction(OSStatus)
    case invalidParameterSets
    case stopped

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The requested H.264 encoder profile is invalid."
        case .compressionSession(let status):
            return "VideoToolbox could not create or use the H.264 encoder (OSStatus \(status))."
        case .compressionProperty(let name, let status):
            return "VideoToolbox rejected H.264 property \(name) (OSStatus \(status))."
        case .pixelTransferSession(let status):
            return "VideoToolbox could not create the camera scaling session (OSStatus \(status))."
        case .pixelBufferPoolUnavailable:
            return "The H.264 encoder did not provide a destination pixel-buffer pool."
        case .pixelBufferAllocation(let status):
            return "The camera scaler could not allocate a destination pixel buffer (CVReturn \(status))."
        case .pixelTransfer(let status):
            return "The camera frame could not be scaled for H.264 encoding (OSStatus \(status))."
        case .missingImageBuffer:
            return "The camera sample did not contain a pixel buffer."
        case .missingEncodedSample:
            return "VideoToolbox completed without an encoded sample."
        case .missingDataBuffer:
            return "The encoded H.264 sample did not contain a data buffer."
        case .blockBufferCopy(let status):
            return "The encoded H.264 bytes could not be copied (OSStatus \(status))."
        case .missingFormatDescription:
            return "The encoded H.264 sample did not include a format description."
        case .parameterSetExtraction(let status):
            return "H.264 SPS/PPS extraction failed (OSStatus \(status))."
        case .invalidParameterSets:
            return "The H.264 encoder returned invalid SPS/PPS metadata."
        case .stopped:
            return "The H.264 encoder is stopped."
        }
    }
}

struct ROBCameraH264EncodedFrame {
    let sequence: UInt64
    let captureTimestampUnixMilliseconds: Int64
    let presentationTimeMicroseconds: Int64
    let durationMicroseconds: UInt32
    let isKeyFrame: Bool
    let parameterSets: [Data]?
    let nalUnitHeaderLength: UInt8
    let payload: Data
}

enum ROBCameraH264EncoderOutput {
    case frame(ROBCameraH264EncodedFrame)
    case frameDropped
    case failed(ROBCameraH264EncoderError)
}

/// `infoFlagsOut` and the VideoToolbox callback can both report a synchronous
/// drop. Claiming a frame's completion prevents duplicate output delivery.
private final class ROBCameraH264FrameCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

/// Makes the callback's cross-thread boundary explicit without tightening the
/// existing output-handler API. Recovery is safe because `requestKeyFrame()`
/// synchronizes its shared state; callers already receive outputs on the queue
/// selected by VideoToolbox.
private final class ROBCameraH264CallbackContext: @unchecked Sendable {
    private weak var encoder: ROBCameraH264Encoder?
    private let outputHandler: (ROBCameraH264EncoderOutput) -> Void

    init(
        encoder: ROBCameraH264Encoder,
        outputHandler: @escaping (ROBCameraH264EncoderOutput) -> Void
    ) {
        self.encoder = encoder
        self.outputHandler = outputHandler
    }

    func requestRecoveryKeyFrame() {
        encoder?.requestKeyFrame()
    }

    func emit(_ output: ROBCameraH264EncoderOutput) {
        outputHandler(output)
    }
}

/// Real-time, low-latency H.264 encoder for camera sample buffers.
///
/// One serial owner must call this class. VideoToolbox may invoke the output
/// closure on an internal queue; every value delivered there owns copied bytes.
final class ROBCameraH264Encoder {
    typealias OutputHandler = (ROBCameraH264EncoderOutput) -> Void

    private static let maximumDimension = 4_096
    private static let maximumPixels = 4_096 * 2_160
    private static let maximumFramesPerSecond = 240
    private static let maximumBitrate: UInt32 = 1_000_000_000
    private static let maximumAccessUnitBytes = 2 * 1_024 * 1_024
    private static let maximumCodecConfigurationBytes = 64 * 1_024
    private static let maximumParameterSetCount = 16
    private static let pixelBufferAllocationThreshold = 6

    private let framesPerSecond: Int
    private let durationMicroseconds: UInt32
    private let outputHandler: OutputHandler
    private var compressionSession: VTCompressionSession?
    private var pixelTransferSession: VTPixelTransferSession?
    private var nextSequence: UInt64 = 1
    private var lastAcceptedUptime: TimeInterval?
    private let keyFrameLock = NSLock()
    private var forceNextKeyFrame = true

    init(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        averageBitrate: UInt32,
        outputHandler: @escaping OutputHandler
    ) throws {
        guard width > 0,
              height > 0,
              width <= Self.maximumDimension,
              height <= Self.maximumDimension,
              width * height <= Self.maximumPixels,
              framesPerSecond > 0,
              framesPerSecond <= Self.maximumFramesPerSecond,
              averageBitrate > 0,
              averageBitrate <= Self.maximumBitrate else {
            throw ROBCameraH264EncoderError.invalidConfiguration
        }

        self.framesPerSecond = framesPerSecond
        self.durationMicroseconds = UInt32(max(1, 1_000_000 / framesPerSecond))
        self.outputHandler = outputHandler

        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:
                NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var createdSession: VTCompressionSession?
        let creationStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: imageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &createdSession
        )
        guard creationStatus == noErr, let createdSession else {
            throw ROBCameraH264EncoderError.compressionSession(creationStatus)
        }
        compressionSession = createdSession

        do {
            try setCompressionProperty(
                kVTCompressionPropertyKey_RealTime,
                value: kCFBooleanTrue,
                name: "RealTime"
            )
            try setCompressionProperty(
                kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse,
                name: "AllowFrameReordering"
            )
            try setCompressionProperty(
                kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
                name: "ProfileLevel",
                allowedFailureStatuses: [kVTPropertyNotSupportedErr, kVTParameterErr]
            )
            try setCompressionProperty(
                kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: framesPerSecond),
                name: "ExpectedFrameRate"
            )
            try setCompressionProperty(
                kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: averageBitrate),
                name: "AverageBitRate"
            )
            try setCompressionProperty(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: max(1, framesPerSecond)),
                name: "MaxKeyFrameInterval"
            )

            let preparationStatus = VTCompressionSessionPrepareToEncodeFrames(createdSession)
            guard preparationStatus == noErr else {
                throw ROBCameraH264EncoderError.compressionSession(preparationStatus)
            }

            var createdTransferSession: VTPixelTransferSession?
            let transferStatus = VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault,
                pixelTransferSessionOut: &createdTransferSession
            )
            guard transferStatus == noErr, let createdTransferSession else {
                throw ROBCameraH264EncoderError.pixelTransferSession(transferStatus)
            }
            pixelTransferSession = createdTransferSession
            let scalingStatus = VTSessionSetProperty(
                createdTransferSession,
                key: kVTPixelTransferPropertyKey_ScalingMode,
                value: kVTScalingMode_Letterbox
            )
            guard scalingStatus == noErr else {
                throw ROBCameraH264EncoderError.pixelTransferSession(scalingStatus)
            }
            let realtimeStatus = VTSessionSetProperty(
                createdTransferSession,
                key: kVTPixelTransferPropertyKey_RealTime,
                value: kCFBooleanTrue
            )
            guard realtimeStatus == noErr else {
                throw ROBCameraH264EncoderError.pixelTransferSession(realtimeStatus)
            }
        } catch {
            finish()
            throw error
        }
    }

    deinit {
        finish()
    }

    /// Returns false when the sample was intentionally skipped to enforce the
    /// negotiated capture rate.
    @discardableResult
    func encode(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        guard let compressionSession, let pixelTransferSession else {
            throw ROBCameraH264EncoderError.stopped
        }
        guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ROBCameraH264EncoderError.missingImageBuffer
        }

        let now = ProcessInfo.processInfo.systemUptime
        let minimumInterval = 1.0 / Double(framesPerSecond)
        if let lastAcceptedUptime, now - lastAcceptedUptime < minimumInterval {
            return false
        }

        guard let pixelBufferPool = VTCompressionSessionGetPixelBufferPool(compressionSession) else {
            throw ROBCameraH264EncoderError.pixelBufferPoolUnavailable
        }
        var destinationPixelBuffer: CVPixelBuffer?
        let allocationAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey:
                NSNumber(value: Self.pixelBufferAllocationThreshold)
        ] as CFDictionary
        let allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pixelBufferPool,
            allocationAttributes,
            &destinationPixelBuffer
        )
        if allocationStatus == kCVReturnWouldExceedAllocationThreshold {
            requestKeyFrame()
            outputHandler(.frameDropped)
            lastAcceptedUptime = now
            return true
        }
        guard allocationStatus == kCVReturnSuccess, let destinationPixelBuffer else {
            throw ROBCameraH264EncoderError.pixelBufferAllocation(allocationStatus)
        }
        let transferStatus = VTPixelTransferSessionTransferImage(
            pixelTransferSession,
            from: sourcePixelBuffer,
            to: destinationPixelBuffer
        )
        guard transferStatus == noErr else {
            throw ROBCameraH264EncoderError.pixelTransfer(transferStatus)
        }
        lastAcceptedUptime = now

        let sequence = nextSequence
        nextSequence &+= 1
        let presentationTimeMicroseconds = Int64(sequence - 1) * Int64(durationMicroseconds)
        let captureTimestampUnixMilliseconds = Int64(
            (Date().timeIntervalSince1970 * 1_000).rounded()
        )
        let shouldForceKeyFrame = consumeKeyFrameRequest()
        let presentationTime = CMTime(
            value: presentationTimeMicroseconds,
            timescale: 1_000_000
        )
        let duration = CMTime(value: Int64(durationMicroseconds), timescale: 1_000_000)
        let frameProperties: CFDictionary? = shouldForceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        var infoFlags = VTEncodeInfoFlags()
        let completion = ROBCameraH264FrameCompletion()
        let callbackContext = ROBCameraH264CallbackContext(
            encoder: self,
            outputHandler: outputHandler
        )
        let encodedDurationMicroseconds = durationMicroseconds
        let encodeStatus = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: destinationPixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: &infoFlags
        ) { status, flags, encodedSampleBuffer in
            guard completion.claim() else { return }
            guard status == noErr else {
                callbackContext.requestRecoveryKeyFrame()
                callbackContext.emit(.failed(.compressionSession(status)))
                return
            }
            if flags.contains(.frameDropped) {
                callbackContext.requestRecoveryKeyFrame()
                callbackContext.emit(.frameDropped)
                return
            }
            guard let encodedSampleBuffer else {
                callbackContext.requestRecoveryKeyFrame()
                callbackContext.emit(.failed(.missingEncodedSample))
                return
            }
            do {
                callbackContext.emit(
                    .frame(
                        try Self.copyEncodedFrame(
                            from: encodedSampleBuffer,
                            sequence: sequence,
                            captureTimestampUnixMilliseconds: captureTimestampUnixMilliseconds,
                            presentationTimeMicroseconds: presentationTimeMicroseconds,
                            durationMicroseconds: encodedDurationMicroseconds
                        )
                    )
                )
            } catch let error as ROBCameraH264EncoderError {
                callbackContext.requestRecoveryKeyFrame()
                callbackContext.emit(.failed(error))
            } catch {
                callbackContext.requestRecoveryKeyFrame()
                callbackContext.emit(.failed(.missingEncodedSample))
            }
        }
        guard encodeStatus == noErr else {
            _ = completion.claim()
            requestKeyFrame()
            throw ROBCameraH264EncoderError.compressionSession(encodeStatus)
        }
        if infoFlags.contains(.frameDropped), completion.claim() {
            requestKeyFrame()
            outputHandler(.frameDropped)
        }
        return true
    }

    func requestKeyFrame() {
        keyFrameLock.lock()
        forceNextKeyFrame = true
        keyFrameLock.unlock()
    }

    func updateAverageBitrate(_ bitrate: UInt32) throws {
        guard bitrate > 0, bitrate <= Self.maximumBitrate else {
            throw ROBCameraH264EncoderError.invalidConfiguration
        }
        try setCompressionProperty(
            kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate),
            name: "AverageBitRate"
        )
        requestKeyFrame()
    }

    func finish() {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(
                compressionSession,
                untilPresentationTimeStamp: .invalid
            )
            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }
        if let pixelTransferSession {
            VTPixelTransferSessionInvalidate(pixelTransferSession)
            self.pixelTransferSession = nil
        }
    }

    private func setCompressionProperty(
        _ key: CFString,
        value: CFTypeRef,
        name: String,
        allowedFailureStatuses: Set<OSStatus> = []
    ) throws {
        guard let compressionSession else {
            throw ROBCameraH264EncoderError.stopped
        }
        let status = VTSessionSetProperty(compressionSession, key: key, value: value)
        if allowedFailureStatuses.contains(status) {
            return
        }
        guard status == noErr else {
            throw ROBCameraH264EncoderError.compressionProperty(name, status)
        }
    }

    private func consumeKeyFrameRequest() -> Bool {
        keyFrameLock.lock()
        defer { keyFrameLock.unlock() }
        let result = forceNextKeyFrame
        forceNextKeyFrame = false
        return result
    }

    private static func copyEncodedFrame(
        from sampleBuffer: CMSampleBuffer,
        sequence: UInt64,
        captureTimestampUnixMilliseconds: Int64,
        presentationTimeMicroseconds: Int64,
        durationMicroseconds: UInt32
    ) throws -> ROBCameraH264EncodedFrame {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw ROBCameraH264EncoderError.missingDataBuffer
        }
        let payloadLength = CMBlockBufferGetDataLength(dataBuffer)
        guard payloadLength > 0, payloadLength <= Self.maximumAccessUnitBytes else {
            throw ROBCameraH264EncoderError.missingEncodedSample
        }
        var payload = Data(count: payloadLength)
        let copyStatus = payload.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: payloadLength,
                destination: baseAddress
            )
        }
        guard copyStatus == noErr else {
            throw ROBCameraH264EncoderError.blockBufferCopy(copyStatus)
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw ROBCameraH264EncoderError.missingFormatDescription
        }
        let nalUnitHeaderLength = try copyNALUnitHeaderLength(from: formatDescription)
        try validateLengthPrefixedAccessUnit(
            payload,
            nalUnitHeaderLength: nalUnitHeaderLength,
            requiresIDR: isKeyFrame
        )

        var parameterSets: [Data]?
        if isKeyFrame {
            let configuration = try copyParameterSets(from: formatDescription)
            parameterSets = configuration.parameterSets
            guard configuration.nalUnitHeaderLength == nalUnitHeaderLength else {
                throw ROBCameraH264EncoderError.invalidParameterSets
            }
        }

        return ROBCameraH264EncodedFrame(
            sequence: sequence,
            captureTimestampUnixMilliseconds: captureTimestampUnixMilliseconds,
            presentationTimeMicroseconds: presentationTimeMicroseconds,
            durationMicroseconds: durationMicroseconds,
            isKeyFrame: isKeyFrame,
            parameterSets: parameterSets,
            nalUnitHeaderLength: nalUnitHeaderLength,
            payload: payload
        )
    }

    private static func copyParameterSets(
        from formatDescription: CMFormatDescription
    ) throws -> (parameterSets: [Data], nalUnitHeaderLength: UInt8) {
        var parameterSetCount = 0
        var headerLength: Int32 = 0
        var firstPointer: UnsafePointer<UInt8>?
        var firstSize = 0
        let firstStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &firstPointer,
            parameterSetSizeOut: &firstSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard firstStatus == noErr else {
            throw ROBCameraH264EncoderError.parameterSetExtraction(firstStatus)
        }
        guard (2...Self.maximumParameterSetCount).contains(parameterSetCount),
              [1, 2, 4].contains(Int(headerLength)) else {
            throw ROBCameraH264EncoderError.invalidParameterSets
        }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(parameterSetCount)
        var totalBytes = 0
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr else {
                throw ROBCameraH264EncoderError.parameterSetExtraction(status)
            }
            guard let pointer, size > 0,
                  size <= Self.maximumCodecConfigurationBytes else {
                throw ROBCameraH264EncoderError.invalidParameterSets
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow, newTotal <= Self.maximumCodecConfigurationBytes else {
                throw ROBCameraH264EncoderError.invalidParameterSets
            }
            totalBytes = newTotal
            parameterSets.append(Data(bytes: pointer, count: size))
        }
        let nalUnitTypes = Set(parameterSets.compactMap { parameterSet in
            parameterSet.first.map { $0 & 0x1F }
        })
        guard nalUnitTypes.contains(7), nalUnitTypes.contains(8) else {
            throw ROBCameraH264EncoderError.invalidParameterSets
        }
        return (parameterSets, UInt8(headerLength))
    }

    private static func copyNALUnitHeaderLength(
        from formatDescription: CMFormatDescription
    ) throws -> UInt8 {
        var parameterSetCount = 0
        var headerLength: Int32 = 0
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard status == noErr else {
            throw ROBCameraH264EncoderError.parameterSetExtraction(status)
        }
        guard pointer != nil,
              size > 0,
              (2...Self.maximumParameterSetCount).contains(parameterSetCount),
              [1, 2, 4].contains(Int(headerLength)) else {
            throw ROBCameraH264EncoderError.invalidParameterSets
        }
        return UInt8(headerLength)
    }

    private static func validateLengthPrefixedAccessUnit(
        _ payload: Data,
        nalUnitHeaderLength: UInt8,
        requiresIDR: Bool
    ) throws {
        let lengthByteCount = Int(nalUnitHeaderLength)
        var offset = payload.startIndex
        var nalUnitCount = 0
        var containsIDR = false
        var containsVideoCodingLayer = false

        while offset < payload.endIndex {
            guard payload.distance(from: offset, to: payload.endIndex) >= lengthByteCount else {
                throw ROBCameraH264EncoderError.missingEncodedSample
            }
            var nalUnitLength = 0
            for _ in 0..<lengthByteCount {
                nalUnitLength = (nalUnitLength << 8) | Int(payload[offset])
                offset = payload.index(after: offset)
            }
            guard nalUnitLength > 0,
                  payload.distance(from: offset, to: payload.endIndex) >= nalUnitLength else {
                throw ROBCameraH264EncoderError.missingEncodedSample
            }
            let nalUnitType = payload[offset] & 0x1F
            if (1...5).contains(nalUnitType) {
                containsVideoCodingLayer = true
            }
            if nalUnitType == 5 {
                containsIDR = true
            }
            offset = payload.index(offset, offsetBy: nalUnitLength)
            nalUnitCount += 1
        }

        guard nalUnitCount > 0,
              containsVideoCodingLayer,
              requiresIDR == containsIDR else {
            throw ROBCameraH264EncoderError.missingEncodedSample
        }
    }
}
