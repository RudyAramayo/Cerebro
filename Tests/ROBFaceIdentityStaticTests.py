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
encoder = text("ROBFaceEmbeddingModel.swift")
conversation = text("ROBFaceConversationPolicy.swift")
camera = text("CameraViewController.swift")
scene = text("ROBSceneSnapshot.swift")
app = text("AppDelegate.m")
main = text("ROBMainViewController.mm")
gemini = text("GeminiRoboticsProtocol.swift")
project = (ROOT / "Cerebro.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")

assert "AES.GCM.seal" in gallery and "AES.GCM.open" in gallery
assert "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in gallery
assert 'appendingPathComponent("People"' in gallery
assert "displayName" in gallery and "profileDirectory(profile.id)" in gallery
assert "administratorAlreadyExists" in gallery
assert "appendAdaptiveSample" in gallery and "retainingAtMost" in gallery
assert "public let luminance: Float?" in gallery

assert "VNDetectFaceRectanglesRequest" in service
assert "VNDetectFaceCaptureQualityRequest" in service
assert "VNDetectFaceLandmarksRequest" in service
assert "cosineDistance" in service and "sample.embedding" in service
assert "ROBFaceIdentity.embeddingModel" in service
assert "AdaFace-R18-WebFace4M.mlmodelc" in encoder
assert "AdaFace-R18-VGGFace2.mlmodelc" in encoder
assert "MLModel(contentsOf:" in encoder
assert "pendingCandidateFrames >= 3" in service
assert "pendingAdaptiveCandidateFrames >= 3" in service
assert "best.second - best.distance >= margin" in service
assert "maximumAdaptiveCosineDistance" in service
assert "adaptiveContinuityLifetime" in service
assert "maybeAppendAdaptiveSample" in service
assert "existingCompletedProfile(named:" in service
assert "minimumRefinementCosineMargin" in service
assert "Refine Selected Identity" in service
assert 'key: "move-closer"' in service and 'key: "too-dark"' in service
assert "averageLuminance(of:" in service
assert "robFaceIdentityConversationCue" in service
assert "noteUnknownFace" in service and "pendingUnknownFrames >= 5" in service
assert "spoken-consent-maker-faire" in service and "role: .knownPerson" in service
assert "handsFreeEnrollmentReferenceEmbeddings" in service
assert "I can only enroll the person who gave permission" in service
assert "noteConversationTranscript" in service
assert "adult, or your grown-up says it's okay" in service
assert "cancelled enrollment and deleted those face samples" in service
assert "ROBFaceConversationPolicy.action" in service
assert "case enroll(String)" in conversation and "case cancelEnrollment" in conversation
assert "consentConfirmed" in service
assert "trustedEnrollmentReference" in service
assert "trustedControllerIDs" in gallery and "administratorControllerIDs" in gallery
assert "expandLegacyAdministratorControllerBindings" in gallery
assert "authorizeActiveOperatorControllers" in service
assert "ROBControlPairing.pairedDevices()" in service
assert '$0.roleName == "operatorController"' in service
assert "Administrator is a personalization role" in service
assert "updateIdentifiedPeople" in service and "short-lived sensor context" in scene

assert "ROBFaceRecognitionService.shared.offer(sampleBuffer)" in camera
assert "People & Face Enrollment" in app
assert "explicitly consents" in window
assert "will not authorize robot motion" in window
assert "Delete Selected Person" in window
assert "Refine Selected Identity" in window
assert "Authorize Active Controllers" in window
assert "Live face enrollment guidance" in window
assert 'case "lighting"' in window
assert "Face model" in window and "modelChanged" in window
assert "faceIdentityConversationCue:" in main
assert "noteConversationTranscript:text" in main
assert "noteConversationTranscript:textInput" in main
assert "faceIdentityConversationContract" in gemini
assert "naturally acknowledge or greet that person by name once" in gemini

for source in (
    "ROBFaceIdentityGallery.swift",
    "ROBFaceRecognitionService.swift",
    "ROBFaceIdentityWindowController.swift",
    "ROBFaceEmbeddingModel.swift",
    "ROBFaceConversationPolicy.swift",
):
    assert f"{source} in Sources" in project

print("ROB face identity static fixtures passed")
