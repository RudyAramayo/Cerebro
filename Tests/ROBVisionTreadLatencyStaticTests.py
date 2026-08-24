#!/usr/bin/env python3
"""Regression checks for immediate Vision-to-base command rendering."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SERIAL_BOX = ROOT / "Cerebro" / "ROBSerialBox.m"


def objective_c_method(source: str, signature: str) -> str:
    method_start = source.index(signature)
    body_start = source.index("{", method_start)
    depth = 0
    for index in range(body_start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[method_start : index + 1]
    raise AssertionError(f"Unterminated Objective-C method: {signature}")


class VisionTreadLatencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.method = objective_c_method(
            SERIAL_BOX.read_text(encoding="utf-8"),
            "- (void) controllerId:(NSString *)controllerId controllerModelData:",
        )

    def test_full_master_snapshot_renders_immediately(self) -> None:
        self.assertIn(
            "if ([self.masterControllerID isEqualToString:controllerId])",
            self.method,
        )
        self.assertIn("[self renderControllerPrioritized:urgent];", self.method)

    def test_start_and_stop_transitions_are_urgent(self) -> None:
        self.assertIn("previousLeftActive != leftActive", self.method)
        self.assertIn("previousRightActive != rightActive", self.method)
        self.assertIn(
            "previous.tredBrakeLock != controllerModelData.tredBrakeLock",
            self.method,
        )


if __name__ == "__main__":
    unittest.main()
