#!/usr/bin/env python3
"""Exercise Cerebro's actual Gemini multi-camera JPEG encoder headlessly.

The encoder is intentionally private to ROBAI.swift.  This test extracts that
exact declaration into a temporary Swift executable rather than maintaining a
second rendering implementation or linking the Cerebro app (which could start
hardware services).
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AI_SOURCE = ROOT / "Cerebro" / "ROBAI.swift"
ENCODER_SIGNATURE = "private final class GeminiMultiCameraJPEGEncoder"
ENCODER_END_MARKER = "\nprivate enum ROBLocalConversationProvider"


def actual_encoder_source() -> str:
    source = AI_SOURCE.read_text(encoding="utf-8")
    start = source.index(ENCODER_SIGNATURE)
    end = source.index(ENCODER_END_MARKER, start)
    return source[start:end]


SWIFT_HARNESS = r'''
import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class EncodedOutputCollector {
    private let condition = NSCondition()
    private var values: [(data: Data, generation: UInt64, encodedAtUptime: TimeInterval)] = []

    func append(_ data: Data, generation: UInt64) {
        condition.lock()
        values.append((data, generation, ProcessInfo.processInfo.systemUptime))
        condition.broadcast()
        condition.unlock()
    }

    func waitForCount(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while values.count < count {
            if !condition.wait(until: deadline) {
                return values.count >= count
            }
        }
        return true
    }

    func output(
        at index: Int
    ) -> (data: Data, generation: UInt64, encodedAtUptime: TimeInterval)? {
        condition.lock()
        defer { condition.unlock() }
        guard values.indices.contains(index) else { return nil }
        return values[index]
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return values.count
    }
}

private struct DecodedJPEG {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureFailure.failed("Encoder output was not a decodable one-image JPEG")
        }
        let decodedWidth = image.width
        let decodedHeight = image.height
        var pixels = [UInt8](repeating: 0, count: decodedWidth * decodedHeight * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: decodedWidth,
                    height: decodedHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: decodedWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: decodedWidth, height: decodedHeight)
            )
            return true
        }
        guard rendered else {
            throw FixtureFailure.failed("Could not rasterize the encoder JPEG for inspection")
        }
        width = decodedWidth
        height = decodedHeight
        rgba = pixels
    }

    func countPixels(_ predicate: (_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool) -> Int {
        var matches = 0
        var index = 0
        while index + 3 < rgba.count {
            if predicate(rgba[index], rgba[index + 1], rgba[index + 2]) {
                matches += 1
            }
            index += 4
        }
        return matches
    }
}

private func makeSampleBuffer(red: UInt8, green: UInt8, blue: UInt8) throws -> CMSampleBuffer {
    let width = 640
    let height = 360
    var optionalPixelBuffer: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary
    let pixelStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes,
        &optionalPixelBuffer
    )
    guard pixelStatus == kCVReturnSuccess, let pixelBuffer = optionalPixelBuffer else {
        throw FixtureFailure.failed("Could not create the synthetic main-camera pixel buffer")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw FixtureFailure.failed("Synthetic main-camera pixel buffer has no storage")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for row in 0..<height {
        let rowBytes = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let offset = column * 4
            rowBytes[offset] = blue
            rowBytes[offset + 1] = green
            rowBytes[offset + 2] = red
            rowBytes[offset + 3] = 255
        }
    }

    var optionalFormat: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &optionalFormat
    )
    guard formatStatus == noErr, let format = optionalFormat else {
        throw FixtureFailure.failed("Could not describe the synthetic main-camera frame")
    }
    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var optionalSampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &optionalSampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer = optionalSampleBuffer else {
        throw FixtureFailure.failed("Could not wrap the synthetic main-camera frame")
    }
    return sampleBuffer
}

private func makeJPEG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
    let extent = CGRect(x: 0, y: 0, width: 768, height: 384)
    let image = CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: extent)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let qualityKey = CIImageRepresentationOption(
        rawValue: kCGImageDestinationLossyCompressionQuality as String
    )
    guard let data = CIContext(options: [.cacheIntermediates: false]).jpegRepresentation(
        of: image,
        colorSpace: colorSpace,
        options: [qualityKey: 0.95]
    ) else {
        throw FixtureFailure.failed("Could not encode the synthetic Insta360 panorama")
    }
    return data
}

private func requireOutput(
    _ collector: EncodedOutputCollector,
    at index: Int,
    timeout: TimeInterval,
    _ message: String
) throws -> (data: Data, generation: UInt64, encodedAtUptime: TimeInterval) {
    guard collector.waitForCount(index + 1, timeout: timeout),
          let output = collector.output(at: index) else {
        throw FixtureFailure.failed(message)
    }
    return output
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure.failed(message) }
}

@main
private enum ROBGeminiMultiCameraJPEGEncoderRuntimeTests {
    static func main() throws {
        let collector = EncodedOutputCollector()
        let encoder = GeminiMultiCameraJPEGEncoder(
            mainCameraEnabled: true,
            insta360Enabled: true,
            insta360OrientationCalibrated: true,
            insta360ForwardMarkerDegrees: 180,
            generation: 7
        ) { data, generation in
            collector.append(data, generation: generation)
        }

        // Offer superseded frames before the initial 150 ms coalescing window
        // closes.  Only the newest red main view and green panorama may render.
        encoder.enqueueMainCamera(
            try makeSampleBuffer(red: 0, green: 0, blue: 255),
            generation: 7
        )
        encoder.enqueueInsta360(
            try makeJPEG(red: 1, green: 0, blue: 0),
            capturedAt: Date(),
            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
            generation: 7
        )
        encoder.enqueueMainCamera(
            try makeSampleBuffer(red: 255, green: 0, blue: 0),
            generation: 7
        )
        encoder.enqueueInsta360(
            try makeJPEG(red: 0, green: 1, blue: 0),
            capturedAt: Date(),
            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
            generation: 7
        )

        let first = try requireOutput(
            collector,
            at: 0,
            timeout: 2.0,
            "Two fresh sources did not produce the first composite"
        )
        try expect(first.generation == 7, "The rendered composite changed video generation")
        let firstJPEG = try DecodedJPEG(first.data)
        try expect(
            firstJPEG.width == 1_024 && firstJPEG.height == 1_024,
            "Gemini's composite is not the fixed 1024x1024 JPEG"
        )
        try expect(
            firstJPEG.countPixels { $0 > 180 && $1 < 80 && $2 < 80 } > 50_000,
            "The newest red main-camera pixels are missing from the top panel"
        )
        try expect(
            firstJPEG.countPixels { $1 > 150 && $0 < 100 && $2 < 100 } > 50_000,
            "The newest green Insta360 pixels are missing from the panorama panel"
        )
        try expect(
            firstJPEG.countPixels { $2 > 105 && $1 > 40 && $1 < 125 && $0 < 75 } > 10_000,
            "The main-camera blue source header did not render"
        )
        try expect(
            firstJPEG.countPixels { $2 > 90 && $0 > 55 && $0 < 135 && $1 < 85 } > 10_000,
            "The Insta360 purple source header did not render"
        )
        try expect(
            firstJPEG.countPixels { $0 > 225 && $1 > 225 && $2 > 225 } > 150,
            "The camera labels/statuses produced no visible white header glyphs"
        )
        try expect(
            firstJPEG.countPixels {
                $0 > 20 && $0 < 120 && $1 > 175 && $2 > 25 && $2 < 150
            } > 100,
            "The calibrated FRONT marker did not render over the panorama"
        )
        try expect(
            firstJPEG.countPixels {
                $0 > 190 && $1 > 20 && $1 < 130 && $2 > 20 && $2 < 130
            } > 100,
            "The calibrated REAR marker did not render over the panorama"
        )

        // A new burst cannot create a second aggregate frame before one second,
        // and its final yellow main-camera frame must replace the earlier one.
        encoder.enqueueMainCamera(
            try makeSampleBuffer(red: 255, green: 0, blue: 255),
            generation: 7
        )
        encoder.enqueueMainCamera(
            try makeSampleBuffer(red: 255, green: 255, blue: 0),
            generation: 7
        )
        let second = try requireOutput(
            collector,
            at: 1,
            timeout: 1.25,
            "The pending latest frame did not render at the one-second boundary"
        )
        try expect(
            second.encodedAtUptime - first.encodedAtUptime >= 0.95,
            "The two camera producers exceeded the encoder's aggregate 1 FPS limit"
        )
        let secondJPEG = try DecodedJPEG(second.data)
        try expect(
            secondJPEG.countPixels { $0 > 170 && $1 > 170 && $2 < 90 } > 50_000,
            "The latest-only slot rendered a superseded main-camera frame"
        )

        // A panorama that was already old when it crossed a busy delivery
        // boundary must stay old. The encoder must use the capture service's
        // monotonic timestamp instead of re-stamping it at receipt.
        let oldCollector = EncodedOutputCollector()
        let oldEncoder = GeminiMultiCameraJPEGEncoder(
            mainCameraEnabled: false,
            insta360Enabled: true,
            insta360OrientationCalibrated: false,
            insta360ForwardMarkerDegrees: 180,
            generation: 11
        ) { data, generation in
            oldCollector.append(data, generation: generation)
        }
        oldEncoder.enqueueInsta360(
            try makeJPEG(red: 0, green: 0, blue: 1),
            capturedAt: Date(),
            capturedAtUptime: ProcessInfo.processInfo.systemUptime - 3.0,
            generation: 11
        )
        try expect(
            !oldCollector.waitForCount(1, timeout: 0.5),
            "A stale panorama was revived by replacing its monotonic capture time"
        )

        // With no later producer wake-up, the final live source must cause one
        // terminal all-placeholder STALE observation when it expires. A
        // corrupt replacement JPEG is not a fresh observation: it must not
        // cancel that transition, extend LIVE, or turn STALE into a heartbeat.
        let staleCollector = EncodedOutputCollector()
        let staleEncoder = GeminiMultiCameraJPEGEncoder(
            mainCameraEnabled: false,
            insta360Enabled: true,
            insta360OrientationCalibrated: false,
            insta360ForwardMarkerDegrees: 180,
            generation: 13
        ) { data, generation in
            staleCollector.append(data, generation: generation)
        }
        staleEncoder.enqueueInsta360(
            try makeJPEG(red: 0, green: 1, blue: 1),
            capturedAt: Date(),
            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
            generation: 13
        )
        let staleLive = try requireOutput(
            staleCollector,
            at: 0,
            timeout: 2.0,
            "The terminal-stale fixture did not first emit its live frame"
        )
        try expect(
            staleLive.generation == 13,
            "The terminal-stale fixture changed video generation"
        )
        let staleLiveJPEG = try DecodedJPEG(staleLive.data)
        try expect(
            staleLiveJPEG.countPixels { $0 < 90 && $1 > 165 && $2 > 165 } > 50_000,
            "The terminal-stale fixture did not begin with live Insta360 pixels"
        )
        staleEncoder.enqueueInsta360(
            Data("this is not a JPEG".utf8),
            capturedAt: Date(),
            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
            generation: 13
        )
        let terminal = try requireOutput(
            staleCollector,
            at: 1,
            timeout: 4.0,
            "The encoder never emitted a terminal STALE transition after feeds stopped"
        )
        let terminalJPEG = try DecodedJPEG(terminal.data)
        try expect(
            terminalJPEG.countPixels { $0 < 90 && $1 > 165 && $2 > 165 } < 1_000,
            "Corrupt input kept the prior Insta360 pixels LIVE instead of reaching STALE"
        )
        try expect(
            !staleCollector.waitForCount(3, timeout: 1.25),
            "The one-time terminal STALE transition repeated as a heartbeat"
        )

        print("Gemini multi-camera JPEG encoder runtime fixtures passed")
    }
}
'''


def main() -> None:
    encoder = actual_encoder_source()
    for label in (
        "MAIN FORWARD CAMERA",
        "INSTA360 STITCHED 360 PANORAMA",
        "FRONT",
        "REAR",
    ):
        if label not in encoder:
            raise AssertionError(f"The actual encoder lost its burned-in label: {label}")

    # A single front-axis calibration establishes the antipodal FRONT/REAR
    # positions, but not whether increasing image x is robot-clockwise. Side
    # labels are allowed only when the implementation carries an explicit
    # panorama-handedness contract into the rendered observation.
    claims_side_directions = 'label: "RIGHT"' in encoder or 'label: "LEFT"' in encoder
    explicit_handedness_tokens = (
        "panoramaHandedness",
        "PanoramaHandedness",
        "degreesIncreaseClockwise",
        "degreesIncreaseCounterclockwise",
        "PANORAMA HANDEDNESS",
    )
    if claims_side_directions and not any(
        token in encoder for token in explicit_handedness_tokens
    ):
        raise AssertionError(
            "The actual encoder labels RIGHT/LEFT without an explicit panorama-handedness contract"
        )
    complete_source = f"{encoder}\n\n{SWIFT_HARNESS}"

    with tempfile.TemporaryDirectory(prefix="cerebro-gemini-video-test-") as temp:
        temp_path = Path(temp)
        source_path = temp_path / "RuntimeFixture.swift"
        executable_path = temp_path / "RuntimeFixture"
        source_path.write_text(complete_source, encoding="utf-8")
        compile_result = subprocess.run(
            [
                "xcrun",
                "swiftc",
                "-parse-as-library",
                "-swift-version",
                "5",
                "-warnings-as-errors",
                str(source_path),
                "-o",
                str(executable_path),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if compile_result.returncode != 0:
            raise RuntimeError(
                "Could not compile the actual Gemini encoder fixture:\n"
                + compile_result.stdout
                + compile_result.stderr
            )

        run_result = subprocess.run(
            [str(executable_path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if run_result.returncode != 0:
            raise RuntimeError(
                "Actual Gemini encoder fixture failed:\n"
                + run_result.stdout
                + run_result.stderr
            )
        print(run_result.stdout, end="")


if __name__ == "__main__":
    main()
