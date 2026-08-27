#!/usr/bin/env python3
"""Structural regressions for fused pose, attention, and posture tracking."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Cerebro"


def text(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


observation = text("CameraOverlayManager.swift")
camera = text("CameraViewController.swift")
detectors = text("ROBDynamicDetectorRegistry.swift")
main = text("ROBMainViewController.mm")
serial_header = text("ROBSerialBox.h")
serial = text("ROBSerialBox.m")
insta_reacquisition = main.rsplit(
    "- (void)insta360HumanPoseDidUpdate:", 1
)[1].split("- (void)updatePersonTrackingPostureForDistance:", 1)[0]

require(
    "class ROBPersonTrackingObservation" in observation
    and "VNHumanBodyPoseObservation" in observation
    and ".nose, .leftEye, .rightEye, .leftEar, .rightEar" in observation
    and "recognized[.leftShoulder]" in observation,
    "Human pose observations no longer derive a resilient head anchor.",
)
require(
    "didTrackHumanPoses(trackingObservations)" in camera
    and 'source: "main-camera-pose"' in camera
    and "onBodyPoseDetected" in camera,
    "The low-latency main-camera pose path no longer reaches person tracking.",
)
require(
    "ROBInsta360HumanPoseDidUpdate" in detectors
    and "detectedPoses.append(tracking)" in detectors
    and 'userInfo: ["observations": currentPoses]' in detectors
    and "source == .insta360, poseOn" in detectors,
    "Insta360 body pose no longer publishes source-scoped reacquisition observations.",
)
require(
    "kROBPersonTrackingFaceFreshnessSeconds = 0.75" in main
    and "lastFaceTrackingSpatialChangeUptime" in main
    and "faceSpatiallyStalled" in main
    and "faceWeight = faceSpatiallyStalled ? 0.0 : 0.68" in main
    and 'source = @"main-camera-face-pose"' in main
    and 'source = @"main-camera-pose"' in main,
    "Face and main-camera pose results are no longer fused with a stalled-face fallback.",
)
require(
    "kROBPersonTrackingHighPoseDwellSeconds = 0.5" in main
    and "kROBPersonTrackingHighPoseEntryY = 0.72" in main
    and "kROBPersonTrackingHighPoseResetY = 0.62" in main
    and "updatePersonTrackingHighPoseAtUptime" in main
    and '[source isEqualToString:@"main-camera-pose"]' in main
    and '[source isEqualToString:@"main-camera-face-pose"]' in main
    and "pose.headY <= kROBPersonTrackingHighPoseResetY" in main
    and "pose.headY < kROBPersonTrackingHighPoseEntryY" in main
    and "personTrackingHighPoseLastObservationUptime" in main
    and "highPosePanTarget < uprightRight.panTarget" in main
    and "highPosePanTarget > uprightLeft.panTarget" in main
    and "requestPersonTrackingUprightPanTarget:highPosePanTarget" in main
    and "self.personTrackingUpperBaselineTarget =\n                        ROBNeckSafetyUprightUpperTarget" in main
    and "then resuming face centering" in main,
    "A persistently high main-camera human pose no longer lifts safely at the current pan before resuming face centering.",
)
require(
    "insta360OrientationCalibrated" not in insta_reacquisition
    and "insta360ForwardMarkerDegrees" not in insta_reacquisition
    and "(candidate.headX - 0.5) * 360.0" in insta_reacquisition
    and "0.5 + selectedDelta / 120.0" in insta_reacquisition
    and "mainTargetIsFresh" in main
    and "if (mainTargetIsFresh) return" in main
    and 'trackingPerson:@"insta360-pose"' in main
    and "Main-camera\n    // face/body pose must reacquire" in main,
    "Panoramic pose no longer uses face-relative frame-center bearing with main-camera priority.",
)
require(
    "kROBPersonTrackingAttentionReturnSeconds = 8.0" in main
    and "updatePersonTrackingAttentionAtUptime" in main
    and '@[@"upright", @"lean_forward"]' in main
    and "if (!self.personTrackingHasAcquiredSubject) return" in main
    and "self.personTrackingHasAcquiredSubject = NO" in main
    and "mainFaceIsFresh || mainPoseIsFresh || panoramicPoseIsFresh" in main,
    "Lost attention no longer returns to a centered forward search pose.",
)
require(
    'nextBand > 0\n        ? @[@"lean_back", @"upright", @"lean_forward"]' in main
    and ': @[@"lean_forward", @"upright", @"lean_back"]' in main
    and "kROBPersonTrackingDistanceDwellSeconds = 0.75" in main
    and "personTrackingDistanceMetersInNormalizedRect" in main,
    "Depth-driven near/far posture orders or their debounce were lost.",
)
require(
    "requestPersonTrackingPostureSequence" in serial_header
    and "personTrackingPostureSequenceActive" in serial_header
    and 'kROBPersonTrackingPostureSource =' in serial
    and "exactConfiguration.cameraLevelingEnabled = false" in serial
    and "exactConfiguration.panCenterTarget" in serial
    and "sendMaestro" not in serial.split(
        "- (ROBNeckCommandDisposition)requestPersonTrackingPostureSequence:", 1
    )[1].split("- (ROBNeckCommandDisposition)applySafeNeckPanTarget:", 1)[0]
    and "personTrackingPostureOwnsNeck" in serial
    and "coupledExactPoseCommand" in serial,
    "Automatic postures no longer stay inside the shared coupled neck safety gateway.",
)
require(
    "personTrackingPostureDeadline = now + 30.0" in serial
    and "schedulePersonTrackingPostureAdvance" in serial
    and "neckCommandReadyAtUptime" in serial
    and "cancelPersonTrackingPostureSequence" in serial,
    "A posture sequence can run without bounded conservative settling.",
)

print("ROB fused person attention static checks passed")
