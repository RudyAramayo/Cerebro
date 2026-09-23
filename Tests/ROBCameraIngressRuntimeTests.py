#!/usr/bin/env python3
"""Exercise production newest-frame admission with a stalled session queue."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

root = Path(__file__).resolve().parents[1]
source = (root / "Cerebro/CameraManager.swift").read_text()
methods = "\n".join(braced_declaration(source, signature) for signature in (
    "private func receivedDepthFrameSet(", "private func deliverNewestDepthFrame()"))
harness = r'''
import Foundation
enum CameraSource { case depthAIService }
enum CameraState { case streamingRGBD }
enum Role: String { case face }
struct Depth { let width = 640; let height = 400 }
struct CameraFrameSet {
    let sequence: UInt64
    let rgbSampleBuffer = 0
    let alignedDepth: Depth? = Depth()
    let capturedAtMilliseconds: Double? = nil
}
final class Ingress {
    let sessionQueue = DispatchQueue(label: "fixture.session")
    let depthIngressLock = NSLock()
    var pendingDepthFrame: (CameraFrameSet, UInt64, UInt64)?
    var depthIngressScheduled = false
    var lastDepthTimingLog = 0.0
    let role = Role.face
    var wantsRunning = true, usesLegacyLuxonisUVCMode = false
    var expectedDepthRunGeneration: UInt64? = 1
    var activeSource: CameraSource? = .depthAIService
    var generation: UInt64 = 1
    var delivered: [UInt64] = []
    func currentDeliveryGeneration() -> UInt64 { generation }
    func deliveryGenerationIsCurrent(_ value: UInt64) -> Bool { value == generation }
    func advanceDeliveryGeneration() { generation += 1 }
    func stopFallbackCaptureAndDrainCallbacks() {}
    func installDepthPreviewLayer(generation: UInt64) {}
    func report(_ state: CameraState, detail: String) {}
    func enqueueLatestPreview(_ buffer: Int, generation: UInt64) {}
    func deliverLatest(_ frame: CameraFrameSet, generation: UInt64) { delivered.append(frame.sequence) }
    // METHODS
    func offer(_ sequence: UInt64, run: UInt64 = 1) {
        receivedDepthFrameSet(CameraFrameSet(sequence: sequence), sourceGeneration: run)
    }
}
@main struct Test {
    static func main() {
        let stream = Ingress()
        stream.sessionQueue.suspend()
        for n in 1...1000 { stream.offer(UInt64(n)) }
        precondition(stream.pendingDepthFrame?.0.sequence == 1000)
        stream.sessionQueue.resume(); stream.sessionQueue.sync {}
        precondition(stream.delivered == [1000], "Session backlog replayed old camera frames")
        stream.offer(1001); stream.sessionQueue.sync {}
        precondition(stream.delivered == [1000, 1001], "Newest-frame gate stopped after one delivery")
        stream.sessionQueue.suspend(); stream.offer(1002); stream.generation += 1
        stream.sessionQueue.resume(); stream.sessionQueue.sync {}
        stream.offer(1003, run: 0); stream.sessionQueue.sync {}
        precondition(stream.delivered == [1000, 1001], "Invalidated camera run delivered old pixels")
        stream.wantsRunning = false; stream.offer(1004); stream.sessionQueue.sync {}
        precondition(stream.delivered.count == 2 && !stream.depthIngressScheduled)
        print("Camera ingress: 1000 queued frames coalesced; generation, stopped-camera and re-entry gates passed")
    }
}
'''.replace("    // METHODS", methods)
with tempfile.TemporaryDirectory(prefix="cerebro-camera-ingress-") as folder:
    path = Path(folder)
    (path / "Test.swift").write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    str(path / "Test.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
