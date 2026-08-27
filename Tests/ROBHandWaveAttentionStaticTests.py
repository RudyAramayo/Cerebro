#!/usr/bin/env python3
"""Structural regressions for dual-camera wave detection and idle attention."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Cerebro"
registry = (SRC / "ROBDynamicDetectorRegistry.swift").read_text(encoding="utf-8")
settings = (SRC / "ROBInsta360ProcessingSettingsViewController.swift").read_text(
    encoding="utf-8"
)
camera = (SRC / "CameraViewController.swift").read_text(encoding="utf-8")
main = (SRC / "ROBMainViewController.mm").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require(
    'static let robHandWaveDidDetect = Notification.Name(' in registry
    and '"ROBHandWaveDidDetect"' in registry
    and "class ROBHandWaveObservation" in registry
    and "targetX: Double" in registry
    and "targetY: Double" in registry,
    "Wave observations no longer carry a source-owned person focus target.",
)
require(
    'return detector != "hand-wave"' in registry
    and 'enabled("hand-wave", source: source)' in registry
    and "usesBuiltInPose || usesHandWave" in registry
    and "let poseRequestOn = bodyPoseOn || handWaveOn" in registry
    and "offerMainCameraBodyPoses" in registry
    and "registry.offerMainCameraBodyPoses(observations)" in camera
    and "poseEnabled: poseEnabled || handWaveEnabled" in camera
    and "ROBDynamicDetectorRegistry.shared.offer(sampleBuffer, source: .mainCamera)" in camera,
    "Opt-in wave analysis no longer keeps either camera's body-joint path available.",
)
require(
    "wrist.y >= elbow.y - 0.02" in registry
    and "wrist.y >= shoulder.y + 0.01" in registry
    and "let shoulderWidth: Double" in registry
    and "relativeWristX:" in registry
    and "track.reversals >= 1" in registry
    and "track.travel >= minimumTravel" in registry
    and "focusUntilUptime = now + 4.0" in registry
    and "cooldownUntilUptime = now + 3.0" in registry,
    "Wave classification lost its raised-arm, relative travel, reversal, or debounce checks.",
)
require(
    "xOffset + Double(point.x) * xScale" in registry
    and "targetX: tracking.headX" in registry
    and "targetY: tracking.headY" in registry
    and 'self.enabled("hand-wave", source: source)' in registry
    and "self.resultIsCurrent(generation, for: source)" in registry
    and "name: .robHandWaveDidDetect" in registry,
    "Wave results may escape stale generations or aim at a wrist instead of the person.",
)
require(
    'checkboxWithTitle: "Main hand-wave gesture"' in settings
    and 'checkboxWithTitle: "360° hand-wave gesture"' in settings
    and 'checkboxWithTitle: "Focus on waves before conversation starts"' in settings
    and 'detector: "hand-wave", source: .mainCamera' in settings
    and 'detector: "hand-wave", source: .insta360' in settings
    and "registry.focusOnHandWaveWhenConversationIdle = enabled" in settings
    and "service.refreshDecoderDemand()" in settings,
    "Perception Settings no longer exposes both wave detectors and idle focus.",
)
require(
    "ROBHandWaveDidDetectNotification" in main
    and "@selector(handWaveDidDetect:)" in main
    and "focusOnHandWaveWhenConversationIdle" in main
    and "conversationHasStartedThisSession" in main
    and "self.speechBox.isSpeaking" in main
    and "scheduledTimerWithTimeInterval:0.1" in main
    and "handWaveFocusDeadlineUptime = now + 4.5" in main
    and 'trackingPerson:@"main-camera-wave"' in main
    and 'trackingPerson:@"insta360-wave"' in main
    and "forwardCenterX = 0.52" in registry
    and "[ROBInsta360TrackingCalibration forwardCenterX]" in main,
    "Idle wave focus no longer aims both camera sources at the tracking cadence.",
)
require(
    "handWaveFocusOwnsAttention && !handWaveFocusSource" in main
    and main.count("[self stopHandWaveFocus];") >= 4
    and "self.conversationHasStartedThisSession = YES" in main
    and "self.conversationHasStartedThisSession = NO" in main,
    "Conversation start/reset no longer owns and releases bounded wave attention.",
)

print("ROB hand-wave attention static checks passed")
