#!/usr/bin/env python3
"""Static regression checks for role-specific AVFoundation camera selection."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Cerebro"


def text(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8")


def require(condition: bool, detail: str) -> None:
    assert condition, detail


manager = text("CameraManager.swift")
main = text("CameraViewController.swift")
belly = text("ROBBellyCameraWindowController.swift")
storyboard = text("Base.lproj/Main.storyboard")

for legacy_control in ("ToggleCam", "BindCam", "BindCamRebootSession"):
    require(legacy_control not in storyboard, f"Legacy camera control remains: {legacy_control}")

for key in ("ROBAVFoundationCameraUniqueIDFace", "ROBAVFoundationCameraUniqueIDBelly"):
    require(key in manager, f"Role-specific selection is not persisted: {key}")

require(
    "func selectAVFoundationCamera(uniqueID: String?)" in manager,
    "The camera manager no longer exposes AVFoundation selection",
)
require(
    ".builtInWideAngleCamera" in manager
    and ".continuityCamera" in manager
    and ".external" in manager,
    "AVFoundation discovery no longer covers built-in, Continuity, and external cameras",
)
require(
    "eligibleDevices.first { $0.uniqueID == selectedID }" in manager,
    "The persisted camera unique ID no longer controls fallback binding",
)
require(
    "The selected AVFoundation camera is not currently connected." in manager,
    "A missing selected camera can silently switch physical roles",
)

for source, role in ((main, "Main"), (belly, "Belly")):
    require(
        "private let avFoundationCameraSelector = NSPopUpButton()" in source,
        f"{role} camera selector is missing",
    )
    require(
        "selectAVFoundationCamera(" in source and 'addItem(withTitle: "Automatic")' in source,
        f"{role} camera selector is not wired to the manager",
    )
    require(
        "AVCaptureDevice.wasConnectedNotification" in source
        and "AVCaptureDevice.wasDisconnectedNotification" in source,
        f"{role} camera selector does not refresh after hot-plug changes",
    )

print("AVFoundation camera-selection regression checks passed")
