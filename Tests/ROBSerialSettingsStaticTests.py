#!/usr/bin/env python3
"""Static regressions for Settings-owned serial controls and the optional Base console."""

from pathlib import Path
import re
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
STORYBOARD_PATH = ROOT / "Cerebro" / "Base.lproj" / "Main.storyboard"
MAIN_SOURCE_PATH = ROOT / "Cerebro" / "ROBMainViewController.mm"
SERIAL_HEADER_PATH = ROOT / "Cerebro" / "ROBSerialBox.h"
SERIAL_SOURCE_PATH = ROOT / "Cerebro" / "ROBSerialBox.m"
SETTINGS_SOURCE_PATH = ROOT / "Cerebro" / "ROBPythonSettingsWindowController.m"
CONSOLE_HEADER_PATH = ROOT / "Cerebro" / "ROBBaseSerialConsoleWindowController.h"
CONSOLE_SOURCE_PATH = ROOT / "Cerebro" / "ROBBaseSerialConsoleWindowController.m"
PROJECT_PATH = ROOT / "Cerebro.xcodeproj" / "project.pbxproj"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def braced_declaration(source: str, signature: str, start: int = 0) -> str:
    declaration_start = source.index(signature, start)
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


def main() -> None:
    for path in (CONSOLE_HEADER_PATH, CONSOLE_SOURCE_PATH):
        require(path.exists(), f"Missing separate Base serial console: {path.name}")

    storyboard = ET.parse(STORYBOARD_PATH).getroot()
    main_source = MAIN_SOURCE_PATH.read_text(encoding="utf-8")
    serial_header = SERIAL_HEADER_PATH.read_text(encoding="utf-8")
    serial_source = SERIAL_SOURCE_PATH.read_text(encoding="utf-8")
    settings_source = SETTINGS_SOURCE_PATH.read_text(encoding="utf-8")
    console_header = CONSOLE_HEADER_PATH.read_text(encoding="utf-8")
    console_source = CONSOLE_SOURCE_PATH.read_text(encoding="utf-8")
    project = PROJECT_PATH.read_text(encoding="utf-8")
    serial_implementation = serial_source.index("@implementation ROBSerialBox")

    # The old main-window widgets must actually be removed, rather than hidden
    # or left connected behind the new programmatic Settings UI.
    main_controllers = [
        element
        for element in storyboard.iter("viewController")
        if element.get("customClass") == "ROBMainViewController"
    ]
    require(len(main_controllers) == 1, "Expected exactly one ROBMainViewController scene")
    main_controller = main_controllers[0]
    descendant_ids = {
        element.get("id") for element in main_controller.iter() if element.get("id")
    }
    legacy_widget_ids = {
        "ERg-aB-nag",  # Base label
        "qKj-zk-AqT",  # Base command field
        "2lH-iP-ZyS",  # Base Send button
        "k5y-vm-Fsf",  # Base USB popup
        "VaJ-5E-roI",  # Maestro label
        "sFr-Bm-3sM",  # Maestro USB popup
        "onI-cy-slo",  # Base output scroll view
        "8u8-Ha-acr",  # Base output text view
    }
    require(
        descendant_ids.isdisjoint(legacy_widget_ids),
        "The main window still contains legacy Base/Maestro serial widgets",
    )
    main_outlets = {
        outlet.get("property") for outlet in main_controller.findall(".//outlet")
    }
    require(
        main_outlets.isdisjoint(
            {
                "serialInputField_base",
                "serialListPullDown_base",
                "serialListPullDown_maestro",
                "serialOutputArea_base",
            }
        ),
        "The main-window controller still owns serial UI outlets",
    )
    main_actions = {
        action.get("selector") for action in main_controller.findall(".//action")
    }
    require(
        main_actions.isdisjoint(
            {"sendText_base:", "serialPortSelected_base:", "serialPortSelected_maestro:"}
        ),
        "The main window still exposes legacy serial actions",
    )
    for token in (
        "serialOutputArea_base",
        "serialInputField_base",
        "serialListPullDown_base",
        "serialListPullDown_maestro",
        "sendText_base:",
        "serialPortSelected_base:",
        "serialPortSelected_maestro:",
    ):
        require(token not in main_source, f"ROBMainViewController still owns serial UI: {token}")

    # Moving diagnostics must not make the automatic hardware connection rely
    # on Settings or on opening the optional console.
    view_did_load = braced_declaration(main_source, "- (void)viewDidLoad")
    require(
        "self.serialBox = [ROBSerialBox new];" in view_did_load
        and "self.serialBox.delegate = self;" in view_did_load
        and "[self.serialBox initialize_connection];" in view_did_load,
        "The main controller no longer starts the headless ROBSerialBox",
    )
    require(
        "ROBMaestroDidConnectNotification" in serial_header
        and "ROBMaestroDidConnectNotification" in serial_source
        and "@selector(maestroDidConnect:)" in view_did_load
        and view_did_load.index("@selector(maestroDidConnect:)")
            < view_did_load.index("self.serialBox = [ROBSerialBox new];"),
        "The Maestro-ready observer must exist before automatic discovery starts",
    )
    for forbidden in (
        "ROBBaseSerialConsoleWindowController",
        "openBaseSerialConsole:",
        "showWindow:",
    ):
        require(
            forbidden not in view_did_load,
            f"Automatic serial startup unexpectedly opens or depends on UI: {forbidden}",
        )
    initialize_connection = braced_declaration(
        serial_source, "- (void)initialize_connection", serial_implementation
    )
    require(
        "connectToDetectedBase" in initialize_connection
        and "[self connectMaestro];" in initialize_connection,
        "Base and Maestro are no longer connected automatically at startup",
    )

    # Both USB choices now live together in Settings. Base retains a supervised
    # override. Maestro is automatic and deliberately read-only, with an
    # explicit retry action instead of exposing its legacy commented-out no-op.
    require(
        re.search(r"\.label\s*=\s*@\"Hardware\"\s*;", settings_source) is not None,
        "Settings is missing its Hardware tab",
    )
    require(
        "NSScrollView *hardwareScrollView" in settings_source
        and "hardwareScrollView.hasVerticalScroller = YES;" in settings_source
        and "hardwareScrollView.autohidesScrollers = YES;" in settings_source
        and "hardwareScrollView.documentView = hardwareView;" in settings_source
        and re.search(
            r"hardwareView\s*=.*NSMakeRect\(0,\s*0,\s*680,\s*880\)",
            settings_source,
        ) is not None,
        "Hardware Settings must remain vertically scrollable as controls grow",
    )
    for token in (
        "baseSerialPopup",
        "maestroSerialPopup",
        "@selector(baseSerialSelectionChanged:)",
        "@selector(reconnectMaestro:)",
        '@"Open Base Console…"',
        "@selector(openBaseSerialConsole:)",
    ):
        require(token in settings_source, f"Hardware Settings lost control/route: {token}")
    for role in ("Base", "Maestro"):
        require(
            re.search(rf'labelWithString:\s*@"{role} USB', settings_source) is not None,
            f"Hardware Settings lost its {role} USB label",
        )
    require(
        re.search(
            r"serialListPullDown_base\s*=\s*self\.baseSerialPopup\s*;",
            settings_source,
        )
        is not None
        and re.search(
            r"serialListPullDown_maestro\s*=\s*self\.maestroSerialPopup\s*;",
            settings_source,
        )
        is not None
        and "refreshSerialPortControls" in settings_source,
        "Hardware Settings is not bound to the live automatic serial service",
    )
    base_selection = braced_declaration(
        settings_source, "- (void)baseSerialSelectionChanged:"
    )
    reconnect_maestro = braced_declaration(settings_source, "- (void)reconnectMaestro:")
    require(
        "[self.boundSerialBox selectBaseSerialPort:sender.titleOfSelectedItem];"
        in base_selection,
        "Settings no longer passes its selected Base path directly to the serial service",
    )
    require(
        re.search(r"maestroSerialPopup\.enabled\s*=\s*NO\s*;", settings_source)
        is not None
        and "@selector(maestroSerialSelectionChanged:)" not in settings_source
        and "[self.boundSerialBox connectMaestro];" in reconnect_maestro,
        "Maestro must be read-only automatic status with a live retry action",
    )
    legacy_base_selection = braced_declaration(
        serial_source, "- (void) serialPortSelected_base", serial_implementation
    )
    select_base = braced_declaration(
        serial_source, "- (void)selectBaseSerialPort:", serial_implementation
    )
    require(
        "- (void)selectBaseSerialPort:(NSString *)path;" in serial_header
        and 'hasPrefix:@"/dev/cu.usb"' in select_base
        and "usbSerialPortPaths" in select_base
        and "containsObject:selectedPath" in select_base
        and "openSerialPort:" in select_base
        and "kBaseSerialContext" in select_base,
        "The direct Base USB API is not validating the current path and connecting it",
    )
    require(
        "[self selectBaseSerialPort:self.serialListPullDown_base.titleOfSelectedItem];"
        in legacy_base_selection,
        "The compatibility Base-selection wrapper no longer delegates to the safe API",
    )
    maestro_reconnect = braced_declaration(
        serial_source, "- (void)attemptMaestroReconnect", serial_implementation
    )
    require(
        "maestroCommandPortPath" in maestro_reconnect
        and "openSerialPort:" in maestro_reconnect
        and "kMaestroSerialContext" in maestro_reconnect,
        "Retry Maestro no longer performs identity-based automatic discovery",
    )

    # Servo smoothing is a persisted Mini Maestro controller profile, not a
    # UI-only animation. Applying it to every channel before target writes
    # keeps all manual, gesture, and tracking routes on the same ramp.
    for token in (
        "ROB.Hardware.MaestroServoSmoothing",
        "ROB.Hardware.MaestroServoSpeed",
        "ROB.Hardware.MaestroServoAcceleration",
        "ROB.Hardware.ApplyMaestroServoSmoothing",
        "@selector(maestroServoSmoothingToggled:)",
        "@selector(applyMaestroServoSmoothing:)",
    ):
        require(token in settings_source, f"Hardware lost servo motion control: {token}")
    require(
        "maestroServoSmoothingEnabled" in serial_header
        and "maestroServoSpeedLimit" in serial_header
        and "maestroServoAccelerationLimit" in serial_header
        and "applyMaestroServoSmoothingEnabled:" in serial_header,
        "The serial service no longer exposes its persisted Maestro motion profile",
    )
    maestro_motion_sender = braced_declaration(
        serial_source,
        "- (BOOL)sendMaestroServoMotionSettingsEnabled:",
        serial_implementation,
    )
    require(
        "kROBMiniMaestroChannelCount = 24" in serial_source
        and "channel < kROBMiniMaestroChannelCount" in maestro_motion_sender
        and "commands[offset++] = 0x87;" in maestro_motion_sender
        and "commands[offset++] = 0x89;" in maestro_motion_sender
        and "enabled" in maestro_motion_sender
        and "? (unsigned short)speedLimit" in maestro_motion_sender
        and "? (unsigned short)accelerationLimit" in maestro_motion_sender,
        "Maestro speed and acceleration limits must cover all 24 channels and support OFF",
    )
    require(
        "kROBMaestroServoSmoothingEnabledDefaultsKey" in serial_source
        and "kROBMaestroServoSpeedLimitDefaultsKey" in serial_source
        and "kROBMaestroServoAccelerationLimitDefaultsKey" in serial_source
        and "kROBMaestroServoMotionProfileDefaultsVersion = 2" in serial_source
        and "kROBLegacyMaestroDefaultServoSpeedLimit = 40" in serial_source
        and "kROBLegacyMaestroDefaultServoAccelerationLimit = 4" in serial_source
        and "ROBMaestroDefaultServoSpeedLimit = 35" in serial_source
        and "ROBMaestroDefaultServoAccelerationLimit = 3" in serial_source,
        "The gentle Maestro defaults are no longer registered and persisted",
    )
    serial_init = braced_declaration(
        serial_source, "- (instancetype)init", serial_implementation
    )
    serial_init_compact = " ".join(serial_init.split())
    require(
        "kROBMaestroServoMotionProfileVersionDefaultsKey" in serial_init
        and "kROBMaestroServoMotionProfileDefaultsVersion" in serial_init
        and "motionProfileVersion < "
            "kROBMaestroServoMotionProfileDefaultsVersion" in serial_init_compact
        and "kROBLegacyMaestroDefaultServoSpeedLimit" in serial_init
        and "kROBLegacyMaestroDefaultServoAccelerationLimit" in serial_init
        and "savedSpeedLimit.integerValue" in serial_init
        and "savedAccelerationLimit.integerValue" in serial_init
        and "setInteger:ROBMaestroDefaultServoSpeedLimit" in serial_init
        and "setInteger:ROBMaestroDefaultServoAccelerationLimit" in serial_init,
        "Existing installations no longer migrate only the former shipped "
        "Maestro values to the gentler profile",
    )
    reconnect_compact = " ".join(maestro_reconnect.split())
    require(
        reconnect_compact.find("sendMaestroServoMotionSettingsEnabled:")
        < reconnect_compact.find('NSLog(@"Maestro connected')
        and "markMaestroDisconnectedForErrno:EIO" in maestro_reconnect,
        "A Maestro connection may accept target writes before its motion profile is applied",
    )
    maestro_ready_handler = braced_declaration(
        main_source,
        "- (void)maestroDidConnect:",
        main_source.index("@implementation ROBMainViewController"),
    )
    require(
        "postNotificationName:ROBMaestroDidConnectNotification"
            in maestro_reconnect
        and reconnect_compact.find("sendMaestroServoMotionSettingsEnabled:")
            < reconnect_compact.find(
                "postNotificationName:ROBMaestroDidConnectNotification"
            )
        and "connectedSerialBox != self.serialBox" in maestro_ready_handler
        and "ROBNeckSafetyDefaultForwardPanTarget" in maestro_ready_handler
        and "ROBNeckSafetyDefaultLowerTarget" in maestro_ready_handler
        and "ROBNeckSafetyDefaultUpperTarget" in maestro_ready_handler
        and "[self startSafeNeckStartup]" in maestro_reconnect
        and reconnect_compact.find("[self startSafeNeckStartup]")
            < reconnect_compact.find(
                "postNotificationName:ROBMaestroDidConnectNotification"
            )
        and "[connectedSerialBox startSafeNeckStartup]"
            not in maestro_ready_handler,
        "A confirmed Maestro connection must launch startup in the hardware "
        "service before notifying UI observers",
    )
    apply_motion = braced_declaration(
        settings_source, "- (void)applyMaestroServoSmoothing:"
    )
    require(
        "applyMaestroServoSmoothingEnabled:enabled" in apply_motion
        and "speedLimit:speedLimit" in apply_motion
        and "accelerationLimit:accelerationLimit" in apply_motion,
        "Hardware Settings no longer applies the validated motion profile centrally",
    )

    # The console is explicitly and lazily opened from Settings. It alone owns
    # the Base output, command field, and Send action.
    open_console = braced_declaration(settings_source, "- (void)openBaseSerialConsole:")
    settings_owns_console = (
        "[[ROBBaseSerialConsoleWindowController alloc]" in open_console
        and "showWindow:" in open_console
    )
    main_owns_console = "showBaseSerialConsole:" in open_console
    require(
        settings_owns_console or main_owns_console,
        "Open Base Console no longer routes to the separate console window",
    )
    build_interface = braced_declaration(settings_source, "- (void)buildInterface")
    settings_show_window = braced_declaration(settings_source, "- (void)showWindow:")
    for lifecycle in (build_interface, settings_show_window):
        require(
            "[[ROBBaseSerialConsoleWindowController alloc]" not in lifecycle
            and "baseConsoleWindowController showWindow:" not in lifecycle,
            "Opening Settings eagerly creates or opens the optional Base console",
        )
    if main_owns_console:
        show_console = braced_declaration(main_source, "showBaseSerialConsole:")
        require(
            "[[ROBBaseSerialConsoleWindowController alloc]" in show_console
            and "showWindow:" in show_console,
            "The main controller's lazy Base-console route no longer presents it",
        )

    require(
        "@interface ROBBaseSerialConsoleWindowController : NSWindowController"
        in console_header,
        "The Base console is not a separate window controller",
    )
    for token in (
        "baseOutputTextView",
        "baseCommandField",
        'buttonWithTitle:@"Send"',
        "@selector(sendBaseCommand:)",
    ):
        require(token in console_source, f"Base console lost required UI: {token}")
    require(
        re.search(r"baseOutputTextView\.editable\s*=\s*NO\s*;", console_source)
        is not None,
        "Base serial output must remain read-only",
    )
    require(
        re.search(
            r"baseOutputTextView\.textColor\s*=\s*(?:NSColor\.labelColor|\[NSColor\s+labelColor\])\s*;",
            console_source,
        )
        is not None
        and re.search(
            r"baseOutputTextView\.backgroundColor\s*=\s*(?:NSColor\.textBackgroundColor|\[NSColor\s+textBackgroundColor\])\s*;",
            console_source,
        )
        is not None,
        "Base console output no longer uses adaptive system text colors",
    )
    send_command = braced_declaration(console_source, "- (void)sendBaseCommand:")
    require(
        "sendBaseCommand:" in send_command and "baseCommandField.stringValue" in send_command,
        "The console Send action no longer forwards its field to ROBSerialBox",
    )
    console_show = braced_declaration(console_source, "- (void)showWindow:")
    console_close = braced_declaration(console_source, "- (void)windowWillClose:")
    attach_console = braced_declaration(console_source, "- (void)attachConsole")
    detach_console = braced_declaration(console_source, "- (void)detachConsole")
    require(
        "[self attachConsole];" in console_show
        and "serialOutputArea_base = self.baseOutputTextView" in attach_console,
        "Opening the console no longer enables Base output display",
    )
    require(
        "[self detachConsole];" in console_close
        and "serialOutputArea_base = nil" in detach_console,
        "Closing the console no longer detaches the optional Base output view",
    )

    append_output = braced_declaration(
        serial_source, "- (void)appendToIncomingText_base:", serial_implementation
    )
    require(
        re.search(
            r"kROBBaseConsoleMaximumCharacters\s*=\s*256\s*\*\s*1024\s*;",
            serial_source,
        )
        is not None
        and "textStorage.length > kROBBaseConsoleMaximumCharacters" in append_output
        and "deleteCharactersInRange:" in append_output,
        "Visible Base console output is no longer capped at 256 KiB",
    )

    require(
        project.count("ROBBaseSerialConsoleWindowController.m") >= 2
        and "ROBBaseSerialConsoleWindowController.m in Sources" in project,
        "The Base console implementation is not in the Cerebro app target",
    )

    print("Serial hardware Settings and optional Base console static checks passed")


if __name__ == "__main__":
    main()
