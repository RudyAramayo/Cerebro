#!/usr/bin/env python3
"""Regressions for safe dynamic-detector camera-frame ownership."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Cerebro" / "ROBDynamicDetectorRegistry.swift").read_text(
    encoding="utf-8"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def braced_declaration(signature: str) -> str:
    start = SOURCE.index(signature)
    body_start = SOURCE.index("{", start)
    depth = 0
    for index in range(body_start, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[start : index + 1]
    raise AssertionError(f"Unterminated declaration: {signature}")


frame = braced_declaration("private enum ROBDetectorFrame")
offer = braced_declaration("public func offer(_ sampleBuffer: CMSampleBuffer")

require(
    "CMSampleBufferIsValid(sampleBuffer)" in offer
    and "CMSampleBufferDataIsReady(sampleBuffer)" in offer
    and "let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)" in offer,
    "Dynamic detection no longer validates and captures the camera buffer at admission",
)
require(
    offer.index("let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)")
    < offer.index("queue.async"),
    "The camera pixel buffer must be retained before the capture callback returns",
)
require(
    "CIImage(cvPixelBuffer:" not in offer
    and "createCGImage" not in offer
    and ".pixelBuffer(pixelBuffer)" in offer,
    "Main-camera detection reintroduced the crashing deferred Core Image conversion",
)
require(
    "case pixelBuffer(CVPixelBuffer)" in frame
    and "VNImageRequestHandler(cvPixelBuffer: buffer)" in frame
    and "case cgImage(CGImage)" in frame,
    "Vision must consume retained camera buffers directly while preserving panorama images",
)

print("Dynamic-detector frame safety static checks passed")
