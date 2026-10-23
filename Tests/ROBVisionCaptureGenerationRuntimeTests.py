#!/usr/bin/env python3
"""Verify production capture identity separately from analysis activation."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
@main struct CaptureIdentityFixtures {
    static func main() {
        var warmup = ROBWorkspaceObservationWarmup()
        precondition(warmup.permitsRetry(acceptedObservation:false,anchoredMap:false,taskCancelled:false,nowUptime:10))
        precondition(warmup.permitsRetry(acceptedObservation:false,anchoredMap:false,taskCancelled:false,nowUptime:17.9))
        precondition(!warmup.permitsRetry(acceptedObservation:false,anchoredMap:false,taskCancelled:false,nowUptime:18))
        var afterObservation = ROBWorkspaceObservationWarmup()
        precondition(!afterObservation.permitsRetry(acceptedObservation:true,anchoredMap:false,taskCancelled:false,nowUptime:10))
        var afterMap = ROBWorkspaceObservationWarmup()
        precondition(!afterMap.permitsRetry(acceptedObservation:false,anchoredMap:true,taskCancelled:false,nowUptime:10))
        var stopped = ROBWorkspaceObservationWarmup()
        precondition(!stopped.permitsRetry(acceptedObservation:false,anchoredMap:false,taskCancelled:true,nowUptime:10))
        // Reproduce native startup: a retained idle generation is replaced
        // before the first real settled sample. Neither collector may anchor
        // the idle generation, and an established scene must never re-enroll.
        let idleGeneration = UUID(), liveGeneration = UUID(), restartedGeneration = UUID()
        var standaloneAnchor = ROBWorkspaceCaptureAnchor()
        var searchAnchor = ROBWorkspaceCaptureAnchor()
        for current in [idleGeneration,liveGeneration] {
            precondition(standaloneAnchor.permitsCurrent(current) && searchAnchor.permitsCurrent(current))
        }
        precondition(!standaloneAnchor.accept(frameGeneration:idleGeneration,currentGeneration:liveGeneration))
        precondition(standaloneAnchor.cameraGeneration == nil)
        precondition(standaloneAnchor.accept(frameGeneration:liveGeneration,currentGeneration:liveGeneration))
        precondition(searchAnchor.accept(frameGeneration:liveGeneration,currentGeneration:liveGeneration))
        precondition(standaloneAnchor.cameraGeneration == liveGeneration && searchAnchor.cameraGeneration == liveGeneration)
        precondition(!standaloneAnchor.permitsCurrent(restartedGeneration) && !searchAnchor.permitsCurrent(restartedGeneration))
        precondition(!standaloneAnchor.accept(frameGeneration:restartedGeneration,currentGeneration:restartedGeneration))
        precondition(!searchAnchor.accept(frameGeneration:restartedGeneration,currentGeneration:restartedGeneration))
        precondition(standaloneAnchor.cameraGeneration == liveGeneration && searchAnchor.cameraGeneration == liveGeneration)
        var identity = ROBVisionCaptureIdentity()
        var sequence: UInt64 = 10
        var nanos: UInt64 = 100
        var captured = 1000.0
        func observe(_ stream: String = "face-manager-run-1", _ source: String = "depthAIService",
                     width: Int = 640, fx: Double = 400) -> ROBVisionCaptureIdentity.Update {
            identity.observe(streamID:stream,source:source,width:width,height:400,intrinsics:[fx,400,320,200],
                sequence:sequence,timestampNanoseconds:nanos,capturedAtMilliseconds:captured)
        }
        let awaitingFirstCapture = identity.generation
        precondition(observe() == .unchanged && identity.generation == awaitingFirstCapture,
                     "First camera enrollment cancelled a pending startup inspection")
        let initial = identity.generation
        sequence += 1; nanos += 1; captured += 1
        precondition(observe() == .unchanged && identity.generation == initial,
                     "Ordinary advancing capture invalidated a completed scene")
        sequence -= 1; nanos -= 1; captured -= 1
        precondition(observe() == .reordered && identity.generation == initial,
                     "Delayed packet replaced live camera identity")
        sequence += 2; nanos += 2; captured += 2
        precondition(observe() == .unchanged && identity.generation == initial)
        precondition(observe("face-manager-run-2") == .changed && identity.generation != initial,
                     "Real camera/source run retained prior scene coordinates")
        let run2 = identity.generation
        sequence = 1; nanos += 1; captured += 1
        precondition(observe("face-manager-run-2") == .changed && identity.generation != run2,
                     "Device sequence restart retained the old camera generation")
        let sequenceReset = identity.generation
        sequence += 1; nanos = 1; captured += 1
        precondition(observe("face-manager-run-2") == .changed && identity.generation != sequenceReset,
                     "Device clock reset retained the old camera generation")
        precondition(observe("face-manager-run-2",fx:401) == .changed,
                     "Changed intrinsics retained prior transformed geometry")
        precondition(observe("face-manager-run-2",width:1280,fx:401) == .changed,
                     "Changed depth dimensions retained prior transformed geometry")
        precondition(observe("face-manager-run-2","avFoundationRGB",width:1280,fx:401) == .changed,
                     "Source change retained RGB-D collision evidence")
        print("Capture-generation fixtures passed: bounded8s observation startup recovery; Stop/accepted observation/map prohibit retry; first fresh frame enrolls standalone/search scenes; every later source change rejected; stable consumer-independent identity; source/intrinsics/geometry/clock/sequence invalidation and reordered-frame rejection")
    }
}
'''


def main():
    vision = (ROOT / "Cerebro/ROBArmRoutineVision.swift").read_text()
    helper = vision[vision.index("struct ROBVisionCaptureIdentity {"):vision.index("/// A separate camera consumer")]
    activation = vision[vision.index("    func setActive("):vision.index("    func offer(")]
    assert "captureIdentity" not in activation, "Consumer activation must not change capture provenance"
    assert "return captureIdentity.generation" in vision
    assert "cameraGeneration: captureGeneration" in vision
    assert "var captureAnchor = ROBWorkspaceCaptureAnchor()" in vision
    assert "var sceneCaptureAnchor = ROBWorkspaceCaptureAnchor()" in vision
    assert "let sceneCameraGeneration = vision.cameraGeneration" not in vision
    workspace = vision[vision.index("    func observeWorkspace("):vision.index("/// Repeatable local search")]
    assert workspace.index("ROBWorkspaceObjectDetector.shared.warmUp()") < workspace.index("let token = try inspectionEpoch()")
    assert workspace.index("ROBMLXEngine.shared.observeWorkspaceSearch") < workspace.index("let token = try self.inspectionEpoch()")
    assert "var observationCaptureAnchor = ROBWorkspaceCaptureAnchor()" in vision
    assert "observationCaptureAnchor.permitsCurrent(vision.cameraGeneration)" in vision
    manager = (ROOT / "Cerebro/CameraManager.swift").read_text()
    assert 'identified.captureStreamID = "\\(markerlessStreamID.uuidString)-\\(generation)"' in manager
    assert "recordingFrameHandler?(identifiedFrame)" in manager
    assert "didOutput: identifiedFrame" in manager
    with tempfile.TemporaryDirectory(prefix="rob-capture-identity-") as folder:
        directory = Path(folder)
        source = directory / "CaptureIdentity.swift"
        binary = directory / "capture-identity-fixture"
        source.write_text("import Foundation\n" + helper + FIXTURE)
        subprocess.run(["xcrun","swiftc","-swift-version","5","-parse-as-library",
                        "-module-cache-path","/private/tmp/cerebro-swift-module-cache",str(source),"-o",str(binary)],check=True,timeout=30)
        subprocess.run([str(binary)],check=True,timeout=10)


if __name__ == "__main__":
    main()
