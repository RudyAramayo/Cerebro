#!/usr/bin/env python3
"""Run the production RGB buffer factory and preview recovery methods without cameras.

CoreMedia is real; a controllable renderer exercises backpressure and delayed
flush callbacks without needing to wedge the system video service or stop ROB.
"""

import os
from pathlib import Path
import subprocess
import tempfile

from ROBMainCameraHeadlessStaticTests import braced_declaration


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Cerebro/CameraManager.swift").read_text()

HARNESS = r'''
import AVFoundation
import Accelerate
import Cocoa

enum Failure: Error { case assertion(String) }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.assertion(message) }
}
func drain(for seconds: TimeInterval = 0.03) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.005)))
    }
}

// Only the AVFoundation renderer is substituted. The scheduling and recovery
// methods below are extracted verbatim from CameraManager.
final class AVSampleBufferVideoRenderer: @unchecked Sendable {
    var status: AVQueuedSampleBufferRenderingStatus = .rendering
    var requiresFlushToResumeDecoding = false
    var isReadyForMoreMediaData = true
    var error: NSError?
    var enqueued = 0
    var flushes = 0
    var completion: (@Sendable () -> Void)?
    func enqueue(_ sample: CMSampleBuffer) { enqueued += 1 }
    func flush(removingDisplayedImage: Bool, completionHandler: (@Sendable () -> Void)?) {
        flushes += 1
        completion = completionHandler
    }
    func finishFlush() {
        let callback = completion
        completion = nil
        status = .unknown
        requiresFlushToResumeDecoding = false
        callback?()
    }
}
final class PreviewLayer {
    let sampleBufferRenderer = AVSampleBufferVideoRenderer()
}
enum Role: String { case face }

final class PreviewHarness: @unchecked Sendable {
    let role = Role.face
    let previewLock = NSLock()
    var previewVisible = true
    var previewDeliveryInFlight = false
    var previewVisibilityGeneration: UInt64 = 1
    var deliveryGeneration: UInt64 = 1
    var depthPreviewLayer: PreviewLayer? = PreviewLayer()
    var depthPreviewRecoveryInFlight = false
    var depthPreviewRecoveryGeneration: UInt64 = 0
    var depthPreviewAwaitingFrameAfterRecovery = false
    var depthPreviewLastEnqueueTime = CACurrentMediaTime()
    static let depthPreviewStallTimeout: CFTimeInterval = 1
    var replacements = 0
    var renderer: AVSampleBufferVideoRenderer { depthPreviewLayer!.sampleBufferRenderer }
    func deliveryGenerationIsCurrent(_ generation: UInt64) -> Bool {
        generation == deliveryGeneration
    }
    func replaceDepthPreviewLayer() {
        replacements += 1
        depthPreviewLayer = PreviewLayer()
        depthPreviewRecoveryInFlight = false
        depthPreviewAwaitingFrameAfterRecovery = false
        depthPreviewLastEnqueueTime = CACurrentMediaTime()
    }
    // PRODUCTION_PREVIEW_METHODS
}
enum RGBSampleFactory {
    // PRODUCTION_SAMPLE_FACTORY
}

@main enum CameraPreviewTests {
    static func main() {
        do { try run() }
        catch {
            fputs("Camera preview regression failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    static func run() throws {
        let bytes: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255,
                             10, 20, 30, 40, 50, 60, 70, 80, 90]
        guard let sample = RGBSampleFactory.makeRGBSampleBuffer(
            rgbData: Data(bytes), width: 3, height: 2,
            timestampNanoseconds: UInt64.max
        ) else { throw Failure.assertion("RGB factory failed") }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        let dictionaries = attachments as? [[String: Any]]
        try require(dictionaries?.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true,
                    "DisplayImmediately must be a per-sample attachment read by AVFoundation")
        try require(CMGetAttachment(sample, key: kCMSampleAttachmentKey_DisplayImmediately,
                                    attachmentModeOut: nil) == nil,
                    "DisplayImmediately was incorrectly written as buffer metadata")
        let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()),
                                                CMSampleBufferGetPresentationTimeStamp(sample)))
        try require(age >= 0 && age < 1, "Presentation time must use the host clock, not the device clock")
        let buffer = CMSampleBufferGetImageBuffer(sample)!
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<2 {
            for column in 0..<3 {
                let input = (row * 3 + column) * 3
                let output = row * stride + column * 4
                try require(Array(UnsafeBufferPointer(start: base + output, count: 4)) ==
                            [bytes[input + 2], bytes[input + 1], bytes[input], 255],
                            "RGB conversion must preserve pixel colors and row padding")
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        print("PASS: live sample attachment, host timestamp, and RGB pixels")

        // Exercise vector tails, padded rows and a complete live-size image.
        // Compare every byte against independently generated RGB source data.
        for (width, height) in [(1, 1), (17, 3), (640, 400), (1280, 720)] {
            let rgb = Data((0..<(width * height * 3)).map { UInt8($0 % 251) })
            guard let converted = RGBSampleFactory.makeRGBSampleBuffer(
                rgbData: rgb, width: width, height: height, timestampNanoseconds: 0),
                  let pixels = CMSampleBufferGetImageBuffer(converted) else {
                throw Failure.assertion("RGB conversion failed at \(width)x\(height)")
            }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let output = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 3, o = y * rowBytes + x * 4
                    try require(output[o] == UInt8((i + 2) % 251) &&
                                output[o + 1] == UInt8((i + 1) % 251) &&
                                output[o + 2] == UInt8(i % 251) && output[o + 3] == 255,
                                "Vectorized conversion changed a pixel at \(x),\(y)")
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        print("PASS: vector tails, row padding and every pixel at both capture resolutions")

        let preview = PreviewHarness()
        preview.enqueueLatestPreview(sample, generation: 1)
        drain()
        try require(preview.renderer.enqueued == 1, "Healthy preview did not receive a frame")
        preview.renderer.isReadyForMoreMediaData = false
        preview.enqueueLatestPreview(sample, generation: 1)
        drain()
        try require(preview.renderer.flushes == 0, "Temporary backpressure must not reset the renderer")
        preview.depthPreviewLastEnqueueTime = CACurrentMediaTime() - 2
        preview.enqueueLatestPreview(sample, generation: 1)
        drain()
        try require(preview.renderer.flushes == 1 && preview.depthPreviewRecoveryInFlight,
                    "A silently blocked queue must recover even without a failed status")
        preview.renderer.isReadyForMoreMediaData = true
        preview.enqueueLatestPreview(sample, generation: 1)
        drain()
        try require(preview.renderer.enqueued == 1, "A frame was enqueued during an unfinished flush")
        preview.renderer.finishFlush()
        drain()
        preview.enqueueLatestPreview(sample, generation: 1)
        drain()
        try require(preview.renderer.enqueued == 2, "Preview did not resume after flushing")
        print("PASS: brief backpressure, silent stall recovery, and serialized flush")

        let stillBlocked = PreviewHarness()
        stillBlocked.renderer.isReadyForMoreMediaData = false
        stillBlocked.depthPreviewLastEnqueueTime = CACurrentMediaTime() - 2
        stillBlocked.enqueueLatestPreview(sample, generation: 1)
        drain()
        stillBlocked.renderer.finishFlush()
        drain()
        stillBlocked.depthPreviewLastEnqueueTime = CACurrentMediaTime() - 2
        stillBlocked.enqueueLatestPreview(sample, generation: 1)
        drain()
        try require(stillBlocked.replacements == 1,
                    "A completed flush that made no progress must replace the renderer")
        print("PASS: ineffective flush escalates to a fresh renderer")

        let hung = PreviewHarness()
        let oldRenderer = hung.renderer
        oldRenderer.status = .failed
        hung.enqueueLatestPreview(sample, generation: 1)
        drain(for: 1.1)
        try require(hung.replacements == 1, "A hung flush must replace the renderer")
        hung.renderer.requiresFlushToResumeDecoding = true
        hung.enqueueLatestPreview(sample, generation: 1)
        drain()
        oldRenderer.finishFlush()
        drain()
        try require(hung.depthPreviewRecoveryInFlight,
                    "A stale flush callback cleared the replacement renderer's recovery")
        hung.renderer.finishFlush()
        drain()
        try require(!hung.depthPreviewRecoveryInFlight, "Current flush callback was ignored")
        let abandoned = PreviewHarness()
        weak var abandonedRenderer = abandoned.renderer
        abandoned.renderer.status = .failed
        abandoned.enqueueLatestPreview(sample, generation: 1)
        drain()
        abandoned.replaceDepthPreviewLayer()
        try require(abandonedRenderer == nil,
                    "An unfinished flush retained its abandoned renderer")
        print("PASS: hung flush replacement and stale renderer callbacks")

        let repeated = PreviewHarness()
        repeated.renderer.status = .failed
        repeated.enqueueLatestPreview(sample, generation: 1)
        drain(for: 0.65)
        repeated.renderer.finishFlush()
        drain()
        repeated.enqueueLatestPreview(sample, generation: 1)
        drain()
        repeated.renderer.status = .failed
        repeated.enqueueLatestPreview(sample, generation: 1)
        drain(for: 0.45)
        try require(repeated.replacements == 0 && repeated.depthPreviewRecoveryInFlight,
                    "An earlier flush deadline interrupted a newer recovery")
        repeated.renderer.finishFlush()
        drain()
        print("PASS: recovery deadlines belong to their own flush generation")

        let hidden = PreviewHarness()
        hidden.previewVisible = false
        hidden.enqueueLatestPreview(sample, generation: 1)
        drain()
        try require(hidden.renderer.enqueued == 0, "A hidden preview received a frame")
        hidden.previewVisible = true
        hidden.enqueueLatestPreview(sample, generation: 0)
        drain()
        try require(hidden.renderer.enqueued == 0, "A frame from an old capture run was displayed")
        hidden.renderer.status = .failed
        hidden.enqueueLatestPreview(sample, generation: 1)
        drain()
        hidden.previewVisible = false
        hidden.previewVisibilityGeneration += 1
        let stopped = PreviewHarness()
        stopped.renderer.status = .failed
        stopped.enqueueLatestPreview(sample, generation: 1)
        drain()
        stopped.deliveryGeneration += 1
        drain(for: 1.1)
        try require(hidden.replacements == 0, "Recovery recreated a hidden preview")
        try require(stopped.replacements == 0, "Recovery replaced a renderer after capture stopped")
        print("PASS: hidden previews and obsolete capture generations stay inactive")
    }
}
'''


def main():
    methods = "\n".join(
        braced_declaration(SOURCE, signature).replace("private func", "func", 1)
        for signature in (
            "private func enqueueLatestPreview(",
            "private func recoverDepthPreviewRenderer(",
            "private func previewVisibilityIsCurrent(",
        )
    )
    factory = braced_declaration(SOURCE, "private static func makeRGBSampleBuffer(")
    source = HARNESS.replace("// PRODUCTION_PREVIEW_METHODS", methods).replace(
        "// PRODUCTION_SAMPLE_FACTORY", factory.replace("private static func", "static func", 1)
    )
    with tempfile.TemporaryDirectory(prefix="cerebro-preview-") as directory:
        path = Path(directory)
        (path / "PreviewTests.swift").write_text(source)
        subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
             str(path / "modules"), str(path / "PreviewTests.swift"), "-o", str(path / "tests")],
            check=True, env=os.environ.copy(),
        )
        subprocess.run([str(path / "tests")], check=True)


if __name__ == "__main__":
    main()
