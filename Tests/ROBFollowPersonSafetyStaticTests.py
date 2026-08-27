from pathlib import Path

root = Path(__file__).resolve().parents[1] / "Cerebro"
coordinator = (root / "ROBFollowPersonCoordinator.swift").read_text()
camera = (root / "CameraViewController.swift").read_text()
detectors = (root / "ROBDynamicDetectorRegistry.swift").read_text()
serial = (root / "ROBSerialBox.m").read_text()
server = (root / "AutoNet" / "AutoNetServer" / "AutoNetServer.swift").read_text()

assert "offerMainCameraFrame" in camera and "frameSet.alignedDepth" in camera
assert "lockAge <= 0.45" in coordinator
assert "Waiting for a fresh forward-facing belly RGB-D safety frame" in coordinator
assert "Waiting for fresh authenticated RPLidar clearance" in coordinator
assert "delayed Insta360" in coordinator and "requestBaseStop()" in coordinator
insta_extension = coordinator.split("extension ROBFollowPersonCoordinator: ROBInsta360VideoFrameConsumer", 1)[1]
assert "applyLeftTread" not in insta_extension
assert "insta360OrientationCalibrated" not in insta_extension
assert "insta360ForwardMarkerDegrees" not in insta_extension
assert "forwardCenterX = 0.52" in detectors
assert "ROBInsta360TrackingCalibration.forwardCenterX" in insta_extension
assert "Float(-deltaDegrees / 75)" in insta_extension
assert "ROBNeckSafetyReferenceLowerTarget" in serial
assert "allowSupervisedLowerRecovery:NO" in serial
assert "kROBFollowTrackingClearanceSource" in serial
assert "reviewedFollowClearanceCommand" in serial
assert "fullPanEnvelopeIsSettled" in serial
assert "message.controllerID == controllerID" in server
assert "message.sessionID == sessionID" in server
assert "sendFollowTargetMessage" in server

print("ROB follow-person safety static tests passed")
