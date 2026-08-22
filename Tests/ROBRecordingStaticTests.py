#!/usr/bin/env python3
"""Static wiring checks for explicit training and footage recording."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Cerebro"


def text(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8")


def require(source: str, needle: str, detail: str) -> None:
    assert needle in source, detail


coordinator = text("ROBRecordingCoordinator.swift")
require(coordinator, "com.orbitusrobotics.cerebro.training-session", "training schema is missing")
require(coordinator, '"aligned_depth_encoding"', "lossless aligned-depth metadata is missing")
require(coordinator, '"camera_to_robot_extrinsics"', "camera extrinsics snapshot is missing")
require(coordinator, 'type: "lidar_pose_odometry"', "lidar/pose/odometry event is missing")
require(coordinator, 'type: "tread_command"', "tread-command event is missing")
require(coordinator, '"autonomous_motion_trains_model": false', "autonomy must remain excluded from training")
require(coordinator, 'controllerID.caseInsensitiveCompare("Autonomous")', "autonomous commands are not identified")
require(coordinator, 'if activeMaster { manualMotionEpisode = nil }', "autonomy handoff must close a manual label window")
require(coordinator, '"successfully_traversed"', "measured traversal label is missing")
require(coordinator, '"stall_or_slip"', "measured stall/slip label is missing")
require(coordinator, "AVAssetWriter", "video writer is missing")
require(coordinator, '"observed_source_resolutions"', "video manifest must disclose actual source resolution")

face = text("CameraViewController.swift")
belly = text("ROBBellyCameraWindowController.swift")
serial = text("ROBSerialBox.m")
lidar = text("ROBAutonomyCoordinator.swift")
insta = text("ROBInsta360CameraService.swift")
app = text("AppDelegate.m")

require(face, "offerCameraFrame(role: .face", "face frames are not recorded")
require(belly, "offerCameraFrame(role: .belly", "belly frames are not recorded")
require(serial, "recordTreadCommandWithControllerID", "controller ingress is not recorded")
require(lidar, "recordLidarPayload", "valid lidar scans are not recorded")
require(insta, "recordingFrameConsumer", "Insta360 recorder consumer is missing")
require(insta, 'recordingPreviewResolution == "3840x1920"', "Insta360 4K preview selection is missing")
require(app, 'initWithTitle:@"Open Recording Control…"', "recording control menu is missing")
require(app, "stopAllForApplicationTermination", "recordings are not finalized at termination")

project = (ROOT / "Cerebro.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
require(project, "ROBRecordingCoordinator.swift in Sources", "coordinator is not in the app target")
require(project, "ROBRecordingWindowController.swift in Sources", "control panel is not in the app target")

print("ROB recording static fixtures passed")
