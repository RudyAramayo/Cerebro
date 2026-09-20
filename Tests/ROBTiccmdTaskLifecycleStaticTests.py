#!/usr/bin/env python3
"""Regression checks for read-only Pololu discovery and stable identity.
Velocity lifecycle behavior is exercised by ROBTorsoControlFixtureTests.swift."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "Cerebro" / "ROBSerialBox.m"


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
    initialization = objective_c_method(source, "- (void)initialize_connection")
    discovery = objective_c_method(source, "- (void)refreshTicControllerSelection")
    read_only = objective_c_method(source, "- (BOOL)runReadOnlyTiccmdAtPath:")

    assert 'ROB.Hardware.LastVerifiedTicSerialNumber' in source
    assert "[self refreshTicControllerSelection]" in initialization
    assert '@[@"-d", savedSerial, @"--status"]' in discovery
    assert '@[@"--list"]' in discovery
    assert "ROBTicSerialNumbersFromListOutput" in discovery
    assert "setObject:verifiedSerial" in discovery

    read_only_drain = read_only.index("readDataToEndOfFile")
    read_only_wait = read_only.index("[ticcmd waitUntilExit]")
    read_only_status = read_only.index("ticcmd.terminationStatus")
    assert read_only_drain < read_only_wait < read_only_status
    print("Read-only Tic discovery retains stable identity and ordered task completion")


if __name__ == "__main__":
    main()
