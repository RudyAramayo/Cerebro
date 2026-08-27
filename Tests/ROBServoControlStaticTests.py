#!/usr/bin/env python3
"""Static regression checks for the editable neck-servo control catalog."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Cerebro"
PROJECT = ROOT / "Cerebro.xcodeproj" / "project.pbxproj"
SCHEME = (
    ROOT
    / "Cerebro.xcodeproj"
    / "xcuserdata"
    / "rob.xcuserdatad"
    / "xcschemes"
    / "Cerebro.xcscheme"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    configuration = (APP / "ROBServoControlConfiguration.swift").read_text()
    runtime = (APP / "ROBServoControlRuntime.swift").read_text()
    window = (APP / "ROBServoControlWindowController.swift").read_text()
    serial_header = (APP / "ROBSerialBox.h").read_text()
    serial_source = (APP / "ROBSerialBox.m").read_text()
    app_delegate = (APP / "AppDelegate.m").read_text()
    project = PROJECT.read_text()
    scheme = SCHEME.read_text()

    for filename in (
        "ROBServoControlConfiguration.swift",
        "ROBServoControlRuntime.swift",
        "ROBServoControlWindowController.swift",
    ):
        require(project.count(filename) >= 3, f"{filename} is not in the app target")

    require(
        'name: "lean_forward", lowerTarget: 7014, upperTarget: 7698'
        in configuration
        and 'name: "upright", lowerTarget: 6011, upperTarget: 6073'
        in configuration
        and 'name: "lean_back", lowerTarget: 4747, upperTarget: 5214'
        in configuration,
        "The shipped camera position catalog no longer matches the reviewed targets",
    )
    require(
        'sequenceName: "startup", phaseIndex: 1' in configuration
        and 'panTarget: 0, lowerTarget: 6011, upperTarget: 6073' in configuration
        and 'sequenceName: "startup", phaseIndex: 2' in configuration
        and 'panTarget: 5799, lowerTarget: 6011, upperTarget: 6073'
        in configuration
        and 'sequenceName: "startup", phaseIndex: 3' in configuration
        and 'panTarget: 5799, lowerTarget: 7014, upperTarget: 7698'
        in configuration,
        "The shipped three-phase startup sequence lost its safe reviewed order",
    )
    require(
        'name: "YES", servo: "upper", delta: 160' in configuration
        and 'name: "NO", servo: "pan", delta: 120' in configuration
        and "poses.append(offset(base, axis: gesture.servo, delta: gesture.delta))"
        in runtime
        and "poses.append(offset(base, axis: gesture.servo, delta: -gesture.delta))"
        in runtime
        and "poses.append(base)" not in runtime
        and "complete at its final -delta extreme" in runtime,
        "YES/NO no longer alternate exactly +delta then -delta per repetition",
    )
    require(
        "private static let maximumSafetyRetries = 8" in runtime
        and "safetyRetryCount < Self.maximumSafetyRetries" in runtime
        and "safetyRetryCount: safetyRetryCount + 1" in runtime,
        "A permanent safety hold can again resubmit forever on the main run loop",
    )
    require(
        'queueDebuggingEnabled = "NO"' in scheme
        and 'queueDebuggingEnableBacktraceRecording = "NO"' in scheme,
        "The Xcode Run scheme may inject the dispatch backtrace recorder that deadlocks Cerebro",
    )

    require(
        "startup.count == 3" in configuration
        and "startup.map(\\.phaseIndex) == [1, 2, 3]" in configuration
        and "startup[0].panTarget == 0" in configuration
        and "(5000 ... 6495).contains(startup[0].lowerTarget)" in configuration
        and "startup[2].panTarget == startup[1].panTarget" in configuration,
        "Editable startup validation no longer preserves the three reviewed safety phases",
    )
    require(
        "requestOperatorNeckPosePanTarget" in serial_header
        and "neckCommandReadyAtUptime" in serial_header
        and "requestOperatorNeckPosePanTarget(" in runtime
        and "sendMaestro" not in runtime
        and "applySafeNeckPanTarget:(int)panTarget" in serial_source,
        "Servo Control execution bypasses or no longer exposes the shared neck safety gateway",
    )
    require(
        'kROBServoControlSource = @"Torso servo control"' in serial_source
        and "safeStartupCommand || servoControlCommand" in serial_source
        and "effectiveConfiguration.cameraLevelingEnabled = false" in serial_source
        and "self.panRecenterSettleGate.readyAt" in serial_source
        and "RunLoop.main.add(retryTimer, forMode: .common)" in runtime
        and "sendMaestroLowerTarget" in serial_source,
        "A single Servo Control press no longer advances exact raw targets "
        "through the automatic pan-first/lower-upper handoff",
    )
    require(
        "safeStartupFinalCommand" in serial_source
        and "safeNeckStartupPhaseThree.panTarget" in serial_source
        and "safeNeckStartupPhaseThree.lowerTarget" in serial_source
        and "safeNeckStartupPhaseThree.upperTarget" in serial_source
        and "&& !safeStartupFinalCommand" in serial_source
        and "upperHeldWithCoupledLower" in serial_source
        and 'UPPER HELD WITH COUPLED LOWER' in serial_source,
        "Startup/Servo Control poses may again send upper before a held lower",
    )
    require(
        "ROBServoControlStore *store = [ROBServoControlStore shared];"
        in serial_source
        and "safeNeckStartupPhaseOne = phaseOne" in serial_source
        and "safeNeckStartupPhaseTwo = phaseTwo" in serial_source
        and "safeNeckStartupPhaseThree = phaseThree" in serial_source
        and "phaseThree.upperTarget" in serial_source,
        "Hardware startup no longer freezes and executes the configured phase snapshot",
    )

    require(
        "private let positionsTable = NSTableView()" in window
        and "private let sequencesTable = NSTableView()" in window
        and "private let gesturesTable = NSTableView()" in window
        and "positionBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)"
        in window
        and "sequenceBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 330)"
        in window
        and "gestureBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)"
        in window
        and 'button("Run Startup"' in window
        and 'button("Play Selected"' in window
        and "store.replaceConfiguration" in window,
        "The Servo Control window lost an editable table or its sequence-first layout",
    )
    require(
        "installServoControlMenu" in app_delegate
        and 'initWithTitle:@"Open Servo Control…"' in app_delegate
        and "controller.serialBox = mainViewController.serialBox" in app_delegate
        and "[controller showWindow:sender]" in app_delegate,
        "The app menu no longer opens Servo Control attached to the live serial service",
    )

    print("ROB servo control static tests passed")


if __name__ == "__main__":
    main()
