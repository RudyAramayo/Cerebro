#!/usr/bin/env python3
"""Static regressions for the camera-owned hologram capture workflow."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CAMERA = (ROOT / "Cerebro" / "CameraViewController.swift").read_text(encoding="utf-8")
MAIN = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(encoding="utf-8")
APP_DELEGATE = (ROOT / "Cerebro" / "AppDelegate.m").read_text(encoding="utf-8")
APP_DELEGATE_HEADER = (ROOT / "Cerebro" / "AppDelegate.h").read_text(encoding="utf-8")
EXPORTER = (ROOT / "Cerebro" / "ROBHologramExporter.swift").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def objc_method(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing Objective-C method: {signature}")
    next_method = source.find("\n- (", start + len(signature))
    return source[start : next_method if next_method >= 0 else len(source)]


def main() -> None:
    # Hologram commands belong to the camera capture surface, not the app-wide
    # Development menu.
    require("Hologram" not in APP_DELEGATE, "AppDelegate still owns hologram behavior")
    require(
        "Hologram" not in APP_DELEGATE_HEADER,
        "AppDelegate still publishes hologram actions",
    )

    for identifier in (
        "ROB.CameraCapture.HologramPanel",
        "ROB.CameraCapture.HologramStill",
        "ROB.CameraCapture.HologramRecord",
        "ROB.CameraCapture.HologramDetail",
        "ROB.CameraCapture.HologramAirDrop",
        "ROB.CameraCapture.HologramStatus",
    ):
        require(identifier in CAMERA, f"Camera capture is missing {identifier}")

    for behavior in (
        "exportInteractively()",
        "showCaptureSettings()",
        "startMovieRecording()",
        "stopMovieRecordingInteractively()",
        "shareLatestHologramViaAirDrop()",
        "stopAirDropSession()",
        "ROBHologramMovieRecordingStateDidChange",
        "ROBHologramExporter.shared.capture(hologramFrame)",
    ):
        require(behavior in CAMERA, f"Camera capture is missing hologram behavior: {behavior}")

    # The main workspace has a permanent link. Development-mode camera
    # diagnostics may reuse it, but the link itself must remain unrestricted.
    require(
        'initWithTitle:@"Camera Capture"' in MAIN
        and "action:@selector(showCameraCapture:)" in MAIN
        and 'setAccessibilityIdentifier:@"ROB.MainWorkspace.CameraCapture"' in MAIN,
        "Main workspace no longer links to Camera Capture",
    )
    show_capture = objc_method(MAIN, "- (IBAction)showCameraCapture:(id)sender")
    require(
        "ensureMainCameraRuntime" in show_capture
        and "showWindow:sender" in show_capture
        and "makeKeyAndOrderFront:sender" in show_capture,
        "Camera Capture link no longer prepares and presents the camera window",
    )
    require(
        "ROBDevelopmentModeDefaultsKey" not in show_capture,
        "Camera Capture link must be available outside Development mode",
    )

    require(
        "Development → Hologram" not in EXPORTER
        and "Open **Camera Capture** from Cerebro's main window" in EXPORTER,
        "Exported hologram guidance still points to the old Development menu",
    )


if __name__ == "__main__":
    main()
