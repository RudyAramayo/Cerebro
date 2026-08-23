#!/usr/bin/env python3
"""Static regressions for consent-based, headless face identity wiring."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Cerebro"


def text(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8")


gallery = text("ROBFaceIdentityGallery.swift")
service = text("ROBFaceRecognitionService.swift")
window = text("ROBFaceIdentityWindowController.swift")
camera = text("CameraViewController.swift")
scene = text("ROBSceneSnapshot.swift")
app = text("AppDelegate.m")
project = (ROOT / "Cerebro.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")

assert "AES.GCM.seal" in gallery and "AES.GCM.open" in gallery
assert "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in gallery
assert 'appendingPathComponent("People"' in gallery
assert "displayName" in gallery and "profileDirectory(profile.id)" in gallery
assert "administratorAlreadyExists" in gallery

assert "VNDetectFaceRectanglesRequest" in service
assert "VNDetectFaceCaptureQualityRequest" in service
assert "VNDetectFaceLandmarksRequest" in service
assert "VNGenerateImageFeaturePrintRequest" in service
assert "pendingCandidateFrames >= 3" in service
assert "best.second - best.distance >= margin" in service
assert "consentConfirmed" in service
assert "trustedEnrollmentReference" in service
assert "ROBControlPairing.pairedDevices()" in service
assert '$0.roleName == "operatorController"' in service
assert "Administrator is a personalization role" in service
assert "updateIdentifiedPeople" in service and "short-lived sensor context" in scene

assert "ROBFaceRecognitionService.shared.offer(sampleBuffer)" in camera
assert "People & Face Enrollment" in app
assert "explicitly consents" in window
assert "will not authorize robot motion" in window
assert "Delete Selected Person" in window

for source in (
    "ROBFaceIdentityGallery.swift",
    "ROBFaceRecognitionService.swift",
    "ROBFaceIdentityWindowController.swift",
):
    assert f"{source} in Sources" in project

print("ROB face identity static fixtures passed")
