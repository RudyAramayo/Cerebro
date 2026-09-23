#!/usr/bin/env python3
"""Structural regressions for person selection, attention, and posture tracking."""

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
insta_diagnostics = text("ROBInsta360DiagnosticsWindowController.swift")
main = text("ROBMainViewController.mm")
serial_header = text("ROBSerialBox.h")
serial = text("ROBSerialBox.m")
settings = text("ROBPythonSettingsWindowController.m")


def method_body(source: str, signature: str) -> str:
    start = source.rindex(signature)
    opening = source.index("{", start)
    depth = 0
    for end in range(opening, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[opening : end + 1]
    raise AssertionError(signature)


posture_preference = "ROBPersonTrackingAutomaticPostureChangesEnabledFromDefaults"
for signature, first_motion in (
    ("- (ROBNeckCommandDisposition)requestPersonTrackingLeanForwardRest", "startSafeNeckStartup"),
    ("- (ROBNeckCommandDisposition)requestPersonTrackingPostureSequence:", "advancePersonTrackingPostureSequence"),
    ("- (ROBNeckCommandDisposition)advancePersonTrackingPostureSequence", "applySafeNeckPanTarget:"),
):
    body = method_body(serial, signature)
    gate = body[:body.index(first_motion)]
    require(
        f"if (!{posture_preference}" in gate
        and "return ROBNeckCommandDispositionRejected;" in gate,
        f"Upright lookaround must reject automatic lean commands before motion: {signature}",
    )
require(
    "cancelPersonTrackingPostureSequence" in method_body(
        serial, "- (ROBNeckCommandDisposition)advancePersonTrackingPostureSequence"
    ).split("NSTimeInterval now", 1)[0]
    and "cancelPersonTrackingPostureSequence" in method_body(
        settings, "- (void)automaticTrackingPosturesChanged:"
    ),
    "Turning scan mode off must cancel queued lean steps, including scheduled continuations.",
)
tracking = method_body(main, "- (void) trackingPerson:(NSString *)userID x:")
require(
    "if ((keepLowerNeckUpright || highMainPoseRequestsUpright)" in tracking
    and "currentLowerTarget != ROBNeckSafetyUprightLowerTarget" in tracking
    and "requestPersonTrackingUprightPanTarget:highPosePanTarget" in tracking
    and "headPan.integerValue = result.panTarget" in tracking
    and "headUpperNeckTilt.integerValue =\n            result.upperTarget" in tracking,
    "Upright mode must enter once through the safe gateway and retain pan/upper tracking.",
)
sword_tracking = method_body(main, "- (void)trainingSwordDidUpdate:")
require(
    posture_preference in sword_tracking.split('cameraPositionNamed:@"lean_back"', 1)[0],
    "Sword attention must not re-enable lean-back gestures in upright mode.",
)
preset = method_body(settings, "- (void)applyTrackingMotionPresetResponsive:")
require(
    "applyMaestroServoSmoothingEnabled:YES" in preset
    and "ROBPersonTrackingResponsivePanTargetsPerSecond" in preset
    and "ROBPersonTrackingResponsiveVerticalTargetsPerSecond" in preset
    and "AutomaticPostureChangesDefaultsKey" not in preset
    and "requestPersonTrackingPostureSequence" not in preset,
    "Changing reaction speed must retain servo ramps and never opt into automatic lean gestures.",
)
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
    and "source == .insta360, bodyPoseOn" in detectors,
    "Insta360 body pose no longer publishes source-scoped reacquisition observations.",
)
require(
    "kROBPersonTrackingFaceFreshnessSeconds = 0.75" in main
    and "if (faceIsFresh) return;" in method_body(main, "- (void)didTrackHumanPoses:")
    and "faceSpatiallyStalled" not in main
    and 'trackingPerson:@"main-camera-face-pose"' in main
    and 'source = @"main-camera-pose"' in main,
    "Fresh faces must own angular tracking; body pose is a fallback after face observations expire.",
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
    "class ROBInsta360TrackingCalibration" in detectors
    and "forwardCenterX = 0.52" in detectors
    and "forwardCenterDegrees = forwardCenterX * 360" in detectors
    and "insta360OrientationCalibrated" not in insta_reacquisition
    and "insta360ForwardMarkerDegrees" not in insta_reacquisition
    and "[ROBInsta360TrackingCalibration forwardCenterX]" in insta_reacquisition
    and "0.5 + selectedDelta / 120.0" in insta_reacquisition
    and "mainTargetIsFresh" in main
    and "if (mainTargetIsFresh) return" in main
    and 'trackingPerson:@"insta360-pose"' in main
    and "Main-camera\n    // face/body pose must reacquire" in main,
    "Panoramic pose no longer uses the shared face-relative optical center with main-camera priority.",
)
require(
    "gyroEstablishesForward = service.gyroStabilizationEnabled" in insta_diagnostics
    and "ROBInsta360TrackingCalibration.forwardCenterDegrees" in insta_diagnostics
    and "gyroEstablishesForward || insta360OrientationCalibrated" in insta_diagnostics
    and "ROB guide: GYRO FORWARD" in insta_diagnostics,
    "The gyro-stabilized Insta360 feed can still be mislabeled as orientation uncalibrated.",
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
    'nextBand > 0\n        ? @[@"upright", @"lean_forward"]' in main
    and ': @[@"upright", @"lean_back"]' in main
    and '@[@"lean_back", @"upright", @"lean_forward"]' not in main
    and '@[@"lean_forward", @"upright", @"lean_back"]' not in main
    and "kROBPersonTrackingDistanceDwellSeconds = 0.75" in main
    and "personTrackingDistanceMetersInNormalizedRect" in main,
    "Depth-driven near/far posture transitions can again visit the opposite extreme or lose their debounce.",
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
posture_request = serial.split(
    "- (ROBNeckCommandDisposition)requestPersonTrackingPostureSequence:", 1
)[1].split("- (ROBNeckCommandDisposition)applySafeNeckPanTarget:", 1)[0]
require(
    "neckSafetyCalibrationConfirmed" not in posture_request
    and "requires a known active neck" in posture_request
    and "exactConfiguration.cameraLevelingEnabled = false" in posture_request,
    "Reviewed exact distance postures can again be blocked by optional camera-leveling calibration.",
)
require(
    "&& !personTrackingUprightCommand\n        && !personTrackingPostureCommand" in serial
    and "publishAcceptedPersonTrackingNeckDemand" in serial
    and "@(self.commandedLowerNeckTiltTarget)" in serial
    and "@(self.commandedUpperNeckTiltTarget)" in serial,
    "Staged posture tracking can again publish an unaccepted hybrid neck pose or be calibration-held.",
)
require(
    "personTrackingPostureDeadline = now + 30.0" in serial
    and "schedulePersonTrackingPostureAdvance" in serial
    and "neckCommandReadyAtUptime" in serial
    and "cancelPersonTrackingPostureSequence" in serial,
    "A posture sequence can run without bounded conservative settling.",
)

print("ROB person attention static checks passed")
