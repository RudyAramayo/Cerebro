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
tracking_policy_header = text("ROBPersonTrackingPolicy.h")
tracking_policy_source = text("ROBPersonTrackingPolicy.c")
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
assert "VNTrackObjectRequest" in service and "VNSequenceRequestHandler" in service
assert "trackingFrameInterval: TimeInterval = 0.1" in service
assert "minimumTrackingConfidence: Float = 0.42" in service
assert "spatiallyAssociatedFace" in service
assert "robFaceIdentityTrackingDidUpdate" in service
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
assert "faceIdentityTrackingDidUpdate:" in main
assert "trackFaceBoundingBox:" in main
tracking = main.split("- (void)trackFaceBoundingBox:", 1)[1].split(
    "- (void)didCaptureCameraSampleBuffer:", 1
)[0]
assert "headTracking_enabled.state" in tracking
person_tracking = main.split(
    "- (void) trackingPerson:(NSString *)userID x:", 1
)[1].split("- (void) startHeartbeatNiTE_ResetTimer", 1)[0]
assert "prepareNeckForPersonTracking" in person_tracking
tracking_prepare = main.rsplit("- (BOOL)prepareNeckForPersonTracking", 1)[1].split(
    "- (void)trackFaceBoundingBox:", 1
)[0]
assert "prepareNeckForPersonFollow" in tracking_prepare
assert "commandedLowerNeckTiltTarget" in tracking_prepare
assert "ROBPersonTrackingNeutralUpperTarget" in tracking_prepare
assert "Person tracking waiting:" in tracking_prepare
human_tracking = main.split("- (void) didTrackHumans:", 1)[1].split(
    "#pragma mark - AudioInputMethods", 1
)[0]
assert '[self trackingPerson:@"person1"' in human_tracking
assert "liftNeckAnimationTimer" not in main
assert "6168.94" not in tracking and "6868.81" not in tracking
assert "ROBPersonTrackingApply" in main
assert "lastPersonTrackingUpdateUptime" in main
assert "faceIdentityTrackingActive" in main
assert "faceDetectionTrackingActive" in main
assert "kROBPersonTrackingApproachFilterAlpha = 0.65" in main
assert "kROBPersonTrackingRetreatFilterAlpha = 0.25" in main
assert "fabs(observedError) <= kROBPersonTrackingFilterStopBand" in main
assert "previousError * observedError <= 0.0" in main
assert "fabs(observedError) < fabs(previousError)" in main
assert "filteredPersonTrackingX" in person_tracking
assert "self.serialBox.commandedNeckPanTarget" in person_tracking
assert 'Person tracking %@ raw=(%.3f, %.3f)' in person_tracking
assert "!recognizedFace && self.faceIdentityTrackingActive" in person_tracking
assert "!detectedFace" in person_tracking
legacy_faces = main.split("- (void) didSeeNewPeople:", 1)[1].split(
    "- (BOOL)prepareNeckForPersonTracking", 1
)[0]
assert "updatePersonVisible" in legacy_faces
assert "trackFaceBoundingBox" not in legacy_faces
assert '[self trackingPerson:@"detected-face"' in legacy_faces
assert "!self.faceIdentityTrackingActive" in legacy_faces
assert "centerX = 0.5" in tracking_policy_source
assert "centerY = 0.5" in tracking_policy_source
assert "horizontalDeadBand = 0.06" in tracking_policy_source
assert "verticalDeadBand = 0.06" in tracking_policy_source
assert "mirrorHorizontalCoordinate = true" in tracking_policy_source
assert "responseExponent = 1.5" in tracking_policy_source
assert "pow(normalizedError, responseExponent)" in tracking_policy_source
assert "panTargetsPerSecond = 250.0" in tracking_policy_source
assert "currentPanTarget\n            - resultOut->horizontalError" in tracking_policy_source
assert "upperTargetsPerSecond = 80.0" in tracking_policy_source
assert "maximumElapsedSeconds = 0.1" in tracking_policy_source
assert "ROBPersonTrackingMinimumUpperTarget = 7350" in tracking_policy_header
assert "ROBPersonTrackingNeutralUpperTarget = 7375" in tracking_policy_header
assert "ROBPersonTrackingMaximumUpperTarget = 7400" in tracking_policy_header
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
    "ROBPersonTrackingPolicy.c",
):
    assert f"{source} in Sources" in project

assert "ROBPersonTrackingPolicy.h" in project

print("ROB face identity static fixtures passed")
