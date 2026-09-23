"""Verified mode changes for the manual Amber controls and bundled SDK."""

import argparse
import time

from amber_api.amber_robot import Amber_Robot


MODE_NAMES = {0: "inactive", 1: "active", 2: "position", 4: "current"}


def read_modes(arm):
    try:
        modes = arm.get_mode()
    except Exception as error:
        raise RuntimeError(f"Controller mode readback failed: {error}") from error
    if not isinstance(modes, (list, tuple)) or len(modes) != 7:
        raise RuntimeError("Controller did not return seven joint modes")
    return list(modes)


def set_and_verify_mode(arm, mode, timeout=1.5):
    # The shipped amber_api.zip exposes set_mode, but has neither
    # set_active_mode nor set_inactive_mode on Amber_Robot. Send exactly once;
    # an unacknowledged mode change may still have reached the controller.
    try:
        acknowledged = arm.set_mode(mode)
    except Exception as error:
        raise RuntimeError(f"{MODE_NAMES[mode]} mode request failed: {error}") from error
    if not acknowledged:
        raise RuntimeError(
            f"{MODE_NAMES[mode]} mode request was not acknowledged; arm state is unknown"
        )
    deadline = time.monotonic() + timeout
    while True:
        modes = read_modes(arm)
        if modes == [mode] * 7:
            print(f"Controller reports all seven joints in {MODE_NAMES[mode]} mode: {modes}")
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"{MODE_NAMES[mode]} mode change not verified: controller reports {modes}; "
                f"expected {[mode] * 7}. No further mode or position command was sent."
            )
        time.sleep(0.05)


def require_position_mode(arm):
    modes = read_modes(arm)
    if modes != [2] * 7:
        raise RuntimeError(
            f"Position command blocked: controller reports joint modes {modes}; "
            "all seven must report position mode (2)"
        )
    return modes


def run_mode_command(mode):
    parser = argparse.ArgumentParser(description=f"Request and verify Amber {MODE_NAMES[mode]} mode")
    parser.add_argument("--ip", required=True, help="Amber controller address")
    parser.add_argument("--port", type=int, choices=(26001, 26002), default=26002)
    args = parser.parse_args()
    print(f"ip {args.ip}\nport {args.port}")
    arm = Amber_Robot(args.ip, args.port, joint_count=7)
    try:
        if mode in (2, 4):
            # Both transitions require active mode first. The vendor helper
            # ignores its wait_for_mode result and proceeds with partial modes.
            set_and_verify_mode(arm, 1)
        set_and_verify_mode(arm, mode)
    except RuntimeError as error:
        raise SystemExit(str(error)) from error
