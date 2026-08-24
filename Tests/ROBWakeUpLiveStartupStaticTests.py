#!/usr/bin/env python3
"""Static safety/UI contracts for the operator-confirmed live startup lane."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WAKE = (ROOT / "Cerebro/ROBWakeUpCalibrationWindowController.swift").read_text()
WINDOW = (ROOT / "Cerebro/ROBStageShowWindowController.swift").read_text()
COORDINATOR = (ROOT / "Cerebro/ROBStageShowCoordinator.swift").read_text()
PROTOCOL = (ROOT / "Cerebro/ROBStageShowProtocol.swift").read_text()
EXECUTOR = (ROOT / "Cerebro/KeyframeAnimationManager.swift").read_text()
MAIN = (ROOT / "Cerebro/ROBMainViewController.mm").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    require(
        "Open Wake-Up Calibration…" in WINDOW
        and "openWakeUpCalibration" in WINDOW
        and "ROBWakeUpCalibrationWindowController.shared" in WINDOW,
        "Show Mode no longer exposes the wake-up calibration workflow",
    )
    require(
        "Run LIVE Startup Test…" in WINDOW
        and "STOP + HOLD" in WINDOW
        and "Arm Remote Start (one-shot)…" in WINDOW
        and "confirmationField" not in WINDOW,
        "The live startup action lost its click-only critical gates or stop lane",
    )
    require(
        "liveStartupReadinessSnapshot" in WINDOW
        and "preflightLocallyConfirmedGesture" in WINDOW
        and 'Set(preflight.arms) == Set(["left", "right"])' in WINDOW
        and "finalPreflight" in WINDOW,
        "Show Mode no longer performs and repeats its two-arm live preflight",
    )
    for step in (
        ".operatorSafety",
        ".amberGateway",
        ".leftAmberArm",
        ".rightAmberArm",
        ".visualArmRegistration",
    ):
        require(step in WAKE, f"Wake-up live readiness lost required gate {step}")
    require(
        'gateway.modes(forArm: arm)' in WAKE
        and "modes.allSatisfy({ $0 == 2 })" in WAKE,
        "Wake-up live readiness no longer requires verified Amber position mode",
    )

    require(
        "liveStartupTest(gestureName:" in PROTOCOL
        and "startup-final-checkpoint" in PROTOCOL
        and "controllerAuthorizedLiveStartupTest" in PROTOCOL
        and "startup-remote-measured-wake" in PROTOCOL
        and "startup-measured-wake" in PROTOCOL
        and "required: true" in PROTOCOL,
        "The fixed live startup sequence lost its final checkpoint or required gesture",
    )
    require(
        "startLiveStartupTest" in COORDINATOR
        and "liveStartupGestureName" in COORDINATOR
        and "startControllerAuthorizedLiveStartupTest" in COORDINATOR
        and "liveStartupIsControllerAuthorized" in COORDINATOR,
        "The coordinator no longer binds the fixed startup sequence to one-shot context",
    )
    require(
        "liveStartupGestureName = nil" in COORDINATOR,
        "The live startup authorization context is not cleared on terminal paths",
    )

    require(
        "localOperatorConfirmedOneShot" in EXECUTOR
        and "executeLocallyConfirmedGesture" in EXECUTOR
        and "sendReferencedLeasedTrajectory" in EXECUTOR
        and "samplePhysicalCompletion" in EXECUTOR
        and "requestPriorityHold" in EXECUTOR,
        "The local live lane is no longer routed through leased, measured Amber execution",
    )
    require(
        "maximumStepRadians" in EXECUTOR
        and "maximumAverageSpeedRadiansPerSecond" in EXECUTOR
        and "effectiveSampleAgeMilliseconds" in EXECUTOR
        and "modes.allSatisfy({ $0 == 2 })" in EXECUTOR,
        "The live gesture executor lost a bounds, freshness, or mode gate",
    )
    require(
        "coordinator.liveStartupGestureName" in MAIN
        and "executeLocallyConfirmedGesture" in MAIN
        and "executeControllerApprovedGesture" in MAIN
        and 'action:@"run_startup_test"' in MAIN
        and "consumeIfGestureNameMatches" in MAIN
        and "measuredBothArms" in MAIN,
        "Main runtime no longer restricts local/remote startup authority to a measured two-arm run",
    )
    require(
        "cancelCurrentGestureWithReason" in MAIN
        and "requestPriorityHold" in MAIN
        and "applyPrioritySoftwareStopWithReason" in MAIN,
        "Stage stop no longer cancels the gesture, holds the arms, and stops the base",
    )

    print("ROB wake-up live startup static tests passed")


if __name__ == "__main__":
    main()
