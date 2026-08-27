#!/usr/bin/env python3
"""Regression checks for the asynchronous Pololu ticcmd task lifecycle."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "Cerebro" / "ROBSerialBox.m"
METHOD_SIGNATURE = "- (void)runTiccmdArguments:"


def objective_c_method(source: str, signature: str) -> str:
    method_start = source.index(signature, source.index("@implementation ROBSerialBox"))
    body_start = source.index("{", method_start)
    depth = 0
    for index in range(body_start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[method_start : index + 1]
    raise AssertionError(f"Unterminated Objective-C method: {signature}")


def main() -> None:
    source = SOURCE_PATH.read_text(encoding="utf-8")
    method = objective_c_method(source, METHOD_SIGNATURE)
    initialization = objective_c_method(source, "- (void)initialize_connection")
    discovery = objective_c_method(source, "- (void)refreshTicControllerSelection")
    read_only = objective_c_method(source, "- (BOOL)runReadOnlyTiccmdAtPath:")

    drain = method.index("readDataToEndOfFile")
    termination_barrier = method.index("[ticcmd waitUntilExit]")
    status_read = method.index("ticcmd.terminationStatus")

    assert drain < termination_barrier < status_read, (
        "ticcmd output must be drained before waiting, and terminationStatus "
        "must not be read until waitUntilExit has completed"
    )
    assert "ROBLaunchTaskSafely(ticcmd" in method
    assert 'ROB.Hardware.LastVerifiedTicSerialNumber' in source
    assert "[self refreshTicControllerSelection]" in initialization
    assert '@[@"-d", savedSerial, @"--status"]' in discovery
    assert '@[@"--list"]' in discovery
    assert "ROBTicSerialNumbersFromListOutput" in discovery
    assert "setObject:verifiedSerial" in discovery
    assert "ROBTicSerialNumberIsValid(savedSerial)" in method
    assert '[routedArguments addObjectsFromArray:@[@"-d", savedSerial]]' in method

    read_only_drain = read_only.index("readDataToEndOfFile")
    read_only_wait = read_only.index("[ticcmd waitUntilExit]")
    read_only_status = read_only.index("ticcmd.terminationStatus")
    assert read_only_drain < read_only_wait < read_only_status
    print("ticcmd output/status lifecycle is ordered safely")


if __name__ == "__main__":
    main()
