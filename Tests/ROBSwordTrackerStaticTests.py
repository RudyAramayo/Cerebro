#!/usr/bin/env python3
"""Structural regressions for saturated training-sword tracking."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CAMERA = (ROOT / "Cerebro" / "CameraViewController.swift").read_text(
    encoding="utf-8"
)
SETTINGS = (
    ROOT / "Cerebro" / "ROBInsta360ProcessingSettingsViewController.swift"
).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def braced_declaration(source: str, signature: str) -> str:
    start = source.index(signature)
    body_start = source.index("{", start)
    depth = 0
    for index in range(body_start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"Unterminated declaration: {signature}")


def main() -> None:
    tracker = braced_declaration(CAMERA, "private final class ROBSwordTracker")
    require(
        'case anyBright = "any"' in CAMERA
        and all(f"case {color}" in CAMERA for color in ("blue", "green", "red", "purple"))
        and 'swordTrackerColorKey = "ROBCameraSwordTrackerColor"' in CAMERA
        and "?? ROBSwordTrackerColor.anyBright.rawValue" in CAMERA,
        "Training-sword color choices or their sensitive default were removed",
    )
    require(
        'applyingFilter("CIColorCube"' in tracker
        and 'applyingFilter("CIMorphologyMaximum"' in tracker
        and 'applyingFilter("CIMorphologyMinimum"' in tracker
        and "let whiteCore = smoothStep" in tracker
        and "let coloredHalo = smoothStep" in tracker
        and "max(whiteCore, coloredHalo)" in tracker,
        "The bright white-core and selected-color halo mask is incomplete",
    )
    require(
        "request.detectsDarkOnLight = false" in tracker
        and "request.maximumImageDimension = 640" in tracker
        and "VNImageRequestHandler(ciImage: mask" in tracker,
        "Vision contours no longer consume the high-resolution bright-on-dark mask",
    )
    require(
        "private static func principalGeometry(" in tracker
        and "let perpendicular = CGPoint" in tracker
        and "perpendicularProjections" in tracker
        and "min(bounds.width, bounds.height)" not in tracker,
        "Blade thickness must remain rotation independent for diagonal swords",
    )
    require(
        "private var consecutiveMisses = 0" in tracker
        and "if self.consecutiveMisses >= 4" in tracker
        and "let stableTrack = track ?? self.previous" in tracker
        and "let continuity" in tracker
        and "wristDistance" in tracker,
        "Sword selection lost its short dropout tolerance, temporal lock, or wrist anchor",
    )
    require(
        "color: ROBSwordTrackerColor" in tracker
        and "color: color" in CAMERA
        and "swordTrackerColorIdentifier" in SETTINGS
        and "swordTrackerColorPopup" in SETTINGS
        and 'setAccessibilityIdentifier("ROB.MainCamera.SwordTracker.Color")' in SETTINGS,
        "The Perception blade-color choice is not connected to the live tracker",
    )
    for actuator in ("ROBSerialBox", "setTarget", "drive", "evade"):
        require(
            actuator not in tracker,
            f"Detection-only sword tracker unexpectedly controls an actuator: {actuator}",
        )

    print("Training-sword tracker static checks passed")


if __name__ == "__main__":
    main()
