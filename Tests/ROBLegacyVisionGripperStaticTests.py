#!/usr/bin/env python3
"""Static regression fixture for the legacy Vision gripper compatibility route."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "Cerebro" / "ROBSerialBox.m"
METHOD_SIGNATURE = "- (void)applyVisionGrippersActive:"


def objective_c_method(source, signature):
    method_start = source.index(signature)
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


def main():
    source = SOURCE_PATH.read_text(encoding="utf-8")
    method = objective_c_method(source, METHOD_SIGNATURE)

    # The compatibility method must continue recording the controller state so
    # existing rendering remains stable.
    required_state_updates = (
        "self.visionGripperStateIsKnown = YES;",
        "self.lastVisionLeftGripperClosed = leftClosed;",
        "self.lastVisionRightGripperClosed = rightClosed;",
    )
    for update in required_state_updates:
        assert update in method, f"Legacy render state update disappeared: {update}"

    # No legacy route may submit a command, invoke a script, or touch a servo.
    forbidden_actuation_tokens = (
        "ROBAmberGatewayClient",
        "controlGripperForArm:",
        "calibrateGripperForArm:",
        "openGripper_",
        "closeGripper_",
        "runPythonArguments:",
        "sendMaestroTarget:",
        "runTiccmdArguments:",
    )
    for token in forbidden_actuation_tokens:
        assert token not in method, f"Legacy gripper route can actuate via {token}"

    assert "no actuator command was sent" in method
    assert "[self applyVisionGrippersActive:" in source
    print("Legacy Vision gripper compatibility route is render-only")


if __name__ == "__main__":
    main()
