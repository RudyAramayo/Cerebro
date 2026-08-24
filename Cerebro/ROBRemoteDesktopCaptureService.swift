import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Demand-driven capture for the administrator-only remote desktop stream.
/// The newest frame wins: capture and JPEG encoding never wait behind network
/// delivery, preserving the independent robot-control connection.
@available(macOS 12.3, *)
final class ROBRemoteDesktopCaptureService {
    static let cameraID = "desktop"
    static let maximumWidth = 4_096
    static let maximumHeight = 2_160
    static let framesPerSecond = 8

    struct Configuration: Equatable {
        let maximumWidth: Int
        let maximumHeight: Int
        let framesPerSecond: Int
        let jpegQuality: Double

        init(
            maximumWidth: Int,
            maximumHeight: Int,
            framesPerSecond: Int,
            jpegQuality: Double
        ) {
            self.maximumWidth = min(max(160, maximumWidth), ROBRemoteDesktopCaptureService.maximumWidth)
            self.maximumHeight = min(max(90, maximumHeight), ROBRemoteDesktopCaptureService.maximumHeight)
            self.framesPerSecond = min(max(1, framesPerSecond), ROBRemoteDesktopCaptureService.framesPerSecond)
            self.jpegQuality = min(max(0.4, jpegQuality), 0.94)
        }
    }

    typealias FrameHandler = (
        _ sampleBuffer: CMSampleBuffer,
        _ jpeg: Data,
        _ width: Int,
        _ height: Int
    ) -> Void

    private let frameHandler: FrameHandler
    private let queue = DispatchQueue(
        label: "com.orbitusrobotics.cerebro.remote-desktop.capture",
        qos: .userInitiated
    )
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var wantsActive = false
    private var configuration: Configuration?
    private var generation: UInt64 = 0
    private var isEncoding = false
    private var latestSample: CMSampleBuffer?
    private lazy var outputDelegate = CaptureDelegate(owner: self)

    private final class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
        weak var owner: ROBRemoteDesktopCaptureService?

        init(owner: ROBRemoteDesktopCaptureService) {
            self.owner = owner
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of outputType: SCStreamOutputType
        ) {
            owner?.didOutput(stream: stream, sampleBuffer: sampleBuffer, outputType: outputType)
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            owner?.didStop(stream: stream, error: error)
        }
    }

    init(frameHandler: @escaping FrameHandler) {
        self.frameHandler = frameHandler
    }

    static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func setConfiguration(_ configuration: Configuration?) {
        queue.async { [weak self] in
            guard let self, self.configuration != configuration else { return }
            self.configuration = configuration
            self.wantsActive = configuration != nil
            self.generation &+= 1
            self.stopCapture()
            if configuration != nil {
                self.beginCapture(generation: self.generation)
            }
        }
    }

    private func beginCapture(generation requestedGeneration: UInt64) {
        guard wantsActive, stream == nil, let captureConfiguration = configuration else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { return }

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { [weak self] content, error in
            guard let self else { return }
            self.queue.async {
                guard self.wantsActive,
                      self.generation == requestedGeneration,
                      error == nil,
                      let content,
                      let display = content.displays.first(where: {
                          $0.displayID == CGMainDisplayID()
                      }) ?? content.displays.first else { return }

                let sourceWidth = max(1, display.width)
                let sourceHeight = max(1, display.height)
                let scale = min(
                    1,
                    min(
                        Double(captureConfiguration.maximumWidth) / Double(sourceWidth),
                        Double(captureConfiguration.maximumHeight) / Double(sourceHeight)
                    )
                )
                let width = max(2, Int(Double(sourceWidth) * scale)) & ~1
                let height = max(2, Int(Double(sourceHeight) * scale)) & ~1
                let streamConfiguration = SCStreamConfiguration()
                streamConfiguration.width = width
                streamConfiguration.height = height
                streamConfiguration.minimumFrameInterval = CMTime(
                    value: 1,
                    timescale: CMTimeScale(captureConfiguration.framesPerSecond)
                )
                streamConfiguration.queueDepth = 2
                streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
                streamConfiguration.showsCursor = true
                streamConfiguration.capturesAudio = false

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(
                    filter: filter,
                    configuration: streamConfiguration,
                    delegate: self.outputDelegate
                )
                do {
                    try stream.addStreamOutput(
                        self.outputDelegate,
                        type: .screen,
                        sampleHandlerQueue: self.queue
                    )
                } catch {
                    NSLog("Unable to install Cerebro desktop capture output: %@",
                          error.localizedDescription)
                    return
                }
                self.stream = stream
                stream.startCapture { [weak self, weak stream] error in
                    guard let self else { return }
                    self.queue.async {
                        guard self.generation == requestedGeneration,
                              self.stream === stream else { return }
                        if let error {
                            NSLog("Unable to start Cerebro desktop capture: %@",
                                  error.localizedDescription)
                            self.stream = nil
                        }
                    }
                }
            }
        }
    }

    private func stopCapture() {
        latestSample = nil
        isEncoding = false
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { error in
            if let error {
                NSLog("Cerebro desktop capture stopped with an error: %@",
                      error.localizedDescription)
            }
        }
    }

    private func didOutput(
        stream: SCStream,
        sampleBuffer: CMSampleBuffer,
        outputType: SCStreamOutputType
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard outputType == .screen,
              self.stream === stream,
              wantsActive,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        if isEncoding {
            latestSample = sampleBuffer
            return
        }
        encode(sampleBuffer)
    }

    private func didStop(stream: SCStream, error: Error) {
        queue.async { [weak self, weak stream] in
            guard let self, self.stream === stream else { return }
            NSLog("Cerebro desktop capture ended: %@", error.localizedDescription)
            self.stream = nil
            self.latestSample = nil
            self.isEncoding = false
            if self.wantsActive {
                let generation = self.generation
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.wantsActive, self.generation == generation else { return }
                    self.beginCapture(generation: generation)
                }
            }
        }
    }

    private func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let configuration else { return }
        isEncoding = true
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let jpeg = boundedJPEG(
            image,
            colorSpace: colorSpace,
            preferredQuality: configuration.jpegQuality
        ) {
            frameHandler(
                sampleBuffer,
                jpeg,
                CVPixelBufferGetWidth(pixelBuffer),
                CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        isEncoding = false
        if let latestSample {
            self.latestSample = nil
            encode(latestSample)
        }
    }

    private func boundedJPEG(
        _ image: CIImage,
        colorSpace: CGColorSpace,
        preferredQuality: Double
    ) -> Data? {
        let fallbackQualities = [preferredQuality, 0.88, 0.78, 0.65]
        var attempted = Set<Int>()
        for quality in fallbackQualities {
            let boundedQuality = min(preferredQuality, quality)
            let qualityKey = Int(boundedQuality * 100)
            guard attempted.insert(qualityKey).inserted else { continue }
            let jpeg = imageContext.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [
                    kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                        boundedQuality
                ]
            )
            if let jpeg, jpeg.count <= ROBVideoWireLimits.maximumAccessUnitBytes {
                return jpeg
            }
        }
        return nil
    }
}
