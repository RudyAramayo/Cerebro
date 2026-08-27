#!/usr/bin/env python3
"""Static regression checks for Settings, Gemini, and Perception preferences."""

from pathlib import Path
import re
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
STORYBOARD_PATH = ROOT / "Cerebro" / "Base.lproj" / "Main.storyboard"
SETTINGS_WINDOW = (
    ROOT / "Cerebro" / "ROBPythonSettingsWindowController.m"
).read_text(encoding="utf-8")
TRACKING_PREFERENCES = (
    ROOT / "Cerebro" / "ROBPersonTrackingPreferences.h"
).read_text(encoding="utf-8")
PROCESSING_SETTINGS = (
    ROOT / "Cerebro" / "ROBInsta360ProcessingSettingsViewController.swift"
).read_text(encoding="utf-8")
DIAGNOSTICS = (
    ROOT / "Cerebro" / "ROBInsta360DiagnosticsWindowController.swift"
).read_text(encoding="utf-8")
GEMINI_SETTINGS = (
    ROOT / "Cerebro" / "ROBGeminiDiagnosticsWindowController.swift"
).read_text(encoding="utf-8")
MAIN_WINDOW = (ROOT / "Cerebro" / "ROBMainWindowController.m").read_text(
    encoding="utf-8"
)
MAIN_VIEW = (ROOT / "Cerebro" / "ROBMainViewController.mm").read_text(
    encoding="utf-8"
)


def braced_declaration(source: str, signature: str) -> str:
    declaration_start = source.index(signature)
    body_start = source.index("{", declaration_start)
    depth = 0
    for index in range(body_start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[declaration_start : index + 1]
    raise AssertionError(f"Unterminated declaration: {signature}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def direct_menu_items(menu: ET.Element) -> list[ET.Element]:
    return menu.findall("./items/menuItem")


def actions(item: ET.Element) -> list[ET.Element]:
    return item.findall("./connections/action")


def assert_settings_action(item: ET.Element, expected_target: str) -> None:
    item_actions = actions(item)
    require(len(item_actions) == 1, "Settings menu item must have exactly one action")
    require(
        item_actions[0].get("selector") == "showPythonSettings:"
        and item_actions[0].get("target") == expected_target,
        "Settings menu item no longer targets AppDelegate.showPythonSettings:",
    )


def main() -> None:
    document = ET.parse(STORYBOARD_PATH).getroot()
    file_menus = [
        menu
        for menu in document.iter("menu")
        if menu.get("key") == "submenu" and menu.get("title") == "File"
    ]
    app_menus = [
        menu
        for menu in document.iter("menu")
        if menu.get("key") == "submenu" and menu.get("systemMenu") == "apple"
    ]
    require(len(file_menus) == 1, "Storyboard must contain exactly one File menu")
    require(len(app_menus) == 1, "Storyboard must contain exactly one application menu")

    comma_items = [
        item for item in document.iter("menuItem") if item.get("keyEquivalent") == ","
    ]
    require(
        len(comma_items) == 1,
        "Storyboard must expose exactly one Command-comma key equivalent",
    )
    file_items = direct_menu_items(file_menus[0])
    file_settings = [item for item in file_items if item.get("title") == "Settings…"]
    require(
        file_settings == comma_items,
        "The sole Command-comma item must be File → Settings…",
    )
    command_comma = file_settings[0]
    # Interface Builder's omitted modifier mask is the standard Command mask;
    # an explicit option/control/shift modifier would change the shortcut.
    require(
        command_comma.find("./modifierMask") is None,
        "File → Settings… must use the standard unmodified Command-comma shortcut",
    )
    settings_actions = actions(command_comma)
    require(len(settings_actions) == 1, "File Settings must have one action")
    app_delegate_id = settings_actions[0].get("target")
    require(app_delegate_id is not None, "File Settings must target AppDelegate")
    assert_settings_action(command_comma, app_delegate_id)

    app_settings = [
        item
        for item in direct_menu_items(app_menus[0])
        if item.get("title") == "Settings…"
    ]
    require(
        len(app_settings) == 1,
        "Application menu must retain one callable Settings… item",
    )
    require(
        app_settings[0].get("keyEquivalent") is None,
        "Application-menu Settings must not duplicate the Command-comma shortcut",
    )
    modifier_mask = app_settings[0].find("./modifierMask")
    require(
        modifier_mask is not None
        and not any(
            modifier_mask.get(name) == "YES"
            for name in ("command", "option", "control", "shift")
        ),
        "Application-menu Settings unexpectedly declares a keyboard modifier",
    )
    assert_settings_action(app_settings[0], app_delegate_id)

    # Gemini provider preferences belong in the shared Settings window, not in
    # a one-off main-window title-bar panel.
    require(
        'buttonWithTitle:@"Gemini…"' not in MAIN_WINDOW
        and "geminiDiagnosticsButton" not in MAIN_WINDOW,
        "The main window regained a separate Gemini settings button",
    )
    require(
        '@objcMembers public final class ROBGeminiSettingsViewController: NSViewController'
        in GEMINI_SETTINGS
        and 'checkboxWithTitle: "Connect to Gemini"' in GEMINI_SETTINGS
        and 'checkboxWithTitle: "Send microphone audio to Gemini"'
        in GEMINI_SETTINGS
        and 'checkboxWithTitle: "Send sampled camera composite to Gemini"'
        in GEMINI_SETTINGS,
        "Gemini runtime controls are no longer hosted by a Settings view controller",
    )
    require(
        'self.geminiSettingsTab.label = @"Gemini";' in SETTINGS_WINDOW
        and "[mainViewController geminiProviderSettingsViewController]"
        in SETTINGS_WINDOW
        and "[self.settingsTabView selectTabViewItem:self.geminiSettingsTab];"
        in SETTINGS_WINDOW,
        "Cerebro Settings no longer owns and selects the Gemini provider tab",
    )
    show_legacy_gemini = braced_declaration(
        MAIN_VIEW, "- (IBAction)showGeminiDiagnostics:"
    )
    require(
        "showGeminiSettings:" in show_legacy_gemini,
        "The legacy Gemini action no longer routes into Settings",
    )

    # The Perception tab owns the processing controller, instead of cloning
    # controls into the diagnostics window.
    build_interface = braced_declaration(SETTINGS_WINDOW, "- (void)buildInterface")
    require(
        'trackingTab.label = @"Tracking";' in build_interface
        and "ROBPersonTrackingMinimumPanTargetsPerSecond" in build_interface
        and "ROBPersonTrackingMaximumPanTargetsPerSecond" in build_interface
        and "self.faceTrackingPanSpeedSlider.continuous = YES;" in build_interface
        and "@selector(faceTrackingPanSpeedChanged:)" in build_interface,
        "Settings lost the persistent face-tracking speed slider",
    )
    tracking_speed_action = braced_declaration(
        SETTINGS_WINDOW, "- (void)faceTrackingPanSpeedChanged:"
    )
    require(
        "ROBPersonTrackingClampPanTargetsPerSecond" in tracking_speed_action
        and "setDouble:speed" in tracking_speed_action
        and "ROBPersonTrackingPanSpeedDefaultsKey" in tracking_speed_action
        and 'ROB.PersonTracking.PanTargetsPerSecond' in TRACKING_PREFERENCES,
        "The face-tracking speed slider no longer saves its bounded value",
    )
    require(
        "ROBInsta360ProcessingSettingsViewController *insta360SettingsViewController"
        in SETTINGS_WINDOW,
        "Settings no longer owns the Insta360 processing controller",
    )
    require(
        "self.insta360SettingsViewController = [[ROBInsta360ProcessingSettingsViewController alloc] init];"
        in build_interface
        and "tabViewItemWithViewController:self.insta360SettingsViewController"
        in build_interface
        and 'self.insta360SettingsTab.label = @"Perception";' in build_interface
        and "[tabView addTabViewItem:self.insta360SettingsTab];" in build_interface,
        "The Perception tab is no longer backed by the processing settings controller",
    )
    show_perception = braced_declaration(
        SETTINGS_WINDOW, "- (void)showInsta360Settings:"
    )
    require(
        "[self.insta360SettingsViewController refreshSettings];" in show_perception
        and "[self.settingsTabView selectTabViewItem:self.insta360SettingsTab];"
        in show_perception,
        "The direct Perception-settings route no longer selects and refreshes its tab",
    )

    # Every processing algorithm/preference exposed by the implementation has
    # both a Settings control and a production setter route.
    required_controls = (
        'checkboxWithTitle: "Analyze main live-feed camera"',
        'checkboxWithTitle: "Analyze Insta360 preview"',
        'checkboxWithTitle: "Show MLX inference output"',
        "private let mainFPSPopup = NSPopUpButton",
        "private let instaFPSPopup = NSPopUpButton",
        "private let analysisGeometryPopup = NSPopUpButton",
        'checkboxWithTitle: "Main pose"',
        'checkboxWithTitle: "360° human detection and pose"',
        'checkboxWithTitle: "Main object labels"',
        'checkboxWithTitle: "360° object labels"',
        'title: "Add Core ML Model…"',
        'checkboxWithTitle: "Gyro stabilization"',
        'title: "Apply Preview Settings"',
    )
    for token in required_controls:
        require(token in PROCESSING_SETTINGS, f"Perception Settings lost control: {token}")

    required_writes = (
        "runtime.mainCameraDetectionEnabled = sender.state == .on",
        "runtime.insta360DetectionEnabled = sender.state == .on",
        "runtime.showInferenceOutput = sender.state == .on",
        "registry.setProcessingFramesPerSecond(",
        "registry.insta360AnalysisGeometry =",
        'registry.setEnabled(enabled, detector: "body-pose", source: .mainCamera)',
        'registry.setEnabled(enabled, detector: "body-pose", source: .insta360)',
        'registry.setEnabled(enabled, detector: "generic-objects", source: .mainCamera)',
        'registry.setEnabled(enabled, detector: "generic-objects", source: .insta360)',
        "service.gyroStabilizationEnabled = sender.state == .on",
        "try registry.registerCoreMLModel(at: url)",
        "service.restart()",
    )
    for token in required_writes:
        require(token in PROCESSING_SETTINGS, f"Perception Settings lost setter: {token}")

    # Diagnostics may summarize preferences and link to Settings, but it must
    # not expose editable algorithm controls or mutate those preferences.
    require(
        "inferenceOutput.isEditable = false" in DIAGNOSTICS
        and 'NSButton(title: "Open Processing Settings…"' in DIAGNOSTICS
        and "#selector(openProcessingSettings(_:))" in DIAGNOSTICS,
        "Diagnostics no longer provides a read-only output plus Settings link",
    )
    action_assignments = re.findall(
        r"\.action\s*=\s*#selector\(([^)]+\([^)]*\))\)", DIAGNOSTICS
    )
    require(
        action_assignments == ["openProcessingSettings(_:)"],
        "Diagnostics gained an editable action instead of routing to Settings",
    )
    for forbidden in (
        "checkboxWithTitle:",
        "NSPopUpButton",
        "NSSlider",
        ".isEditable = true",
        "runtime.mainCameraDetectionEnabled =",
        "runtime.insta360DetectionEnabled =",
        "runtime.showInferenceOutput =",
        "registry.setProcessingFramesPerSecond(",
        "registry.setEnabled(",
        "service.gyroStabilizationEnabled =",
        "registerCoreMLModel(",
        "service.restart()",
    ):
        require(forbidden not in DIAGNOSTICS, f"Diagnostics gained algorithm editing: {forbidden}")
    require(
        re.search(r"registry\.insta360AnalysisGeometry\s*=(?!=)", DIAGNOSTICS)
        is None,
        "Diagnostics gained an Insta360 analysis-geometry setter",
    )

    print("Settings, Gemini, and Perception preference static checks passed")


if __name__ == "__main__":
    main()
