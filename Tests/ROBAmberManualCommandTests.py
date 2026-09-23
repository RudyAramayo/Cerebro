#!/usr/bin/env python3
"""Exercise manual scripts with the shipped SDK and an entirely fake UDP socket."""

import contextlib
import io
import os
from pathlib import Path
import runpy
import socket
import struct
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = Path(os.environ.get(
    "ROB_AMBER_TEST_RESOURCES", ROOT / "Cerebro/TaskControllers/Amber V2 API"
))
sys.path[:0] = [str(SCRIPTS), str(SCRIPTS / "amber_api.zip")]
sys.dont_write_bytecode = True


class FakeBus:
    def __init__(self, modes=None):
        self.modes = [2] * 7 if modes is None else modes
        self.requests = []
        self.mode_results = {}
        self.query_results = []
        self.acknowledgements = {}
        self.clock = 0.0

    def sleep(self, seconds):
        self.clock += seconds

    def socket(self, family, kind):
        assert (family, kind) == (socket.AF_INET, socket.SOCK_DGRAM)
        return FakeSocket(self)

    @property
    def commands(self):
        return [struct.unpack_from("<H", data)[0] for data, _ in self.requests]

    @property
    def mode_changes(self):
        return [struct.unpack_from("<H", data, 8)[0]
                for data, _ in self.requests if struct.unpack_from("<H", data)[0] == 10]


class FakeSocket:
    def __init__(self, bus):
        self.bus = bus

    def settimeout(self, seconds):
        pass

    def sendto(self, payload, address):
        assert address in (("198.51.100.4", 26001), ("198.51.100.4", 26002))
        self.request = bytes(payload)
        self.address = address
        self.bus.requests.append((self.request, address))

    def recvfrom(self, count):
        command, _, counter = struct.unpack_from("<HHI", self.request)
        response = self.bus.acknowledgements.get(command, 1)
        if response == "timeout":
            raise socket.timeout("fixture timeout")
        if command == 10:
            mode = struct.unpack_from("<H", self.request, 8)[0]
            if response == 1:
                self.bus.modes = self.bus.mode_results.get(mode, [mode] * 7)
        if command == 110:
            modes = self.bus.query_results.pop(0) if self.bus.query_results else self.bus.modes
            data = struct.pack("<HHI7H", command, 22, counter, *modes)
        elif command == 1:
            data = struct.pack("<HHI29f", command, 124, counter, *([0.0] * 29))
        elif command in (4, 10):
            data = struct.pack("<HHIB", command, 9, counter, response)
        else:
            raise AssertionError(f"Unexpected command {command}")
        return data, self.address


class ManualAmberCommandTests(unittest.TestCase):
    def run_script(self, filename, bus, *arguments, port=26001):
        output = io.StringIO()
        error = None
        with patch.object(sys, "argv", [str(SCRIPTS / filename), "--ip", "198.51.100.4",
                                      "--port", str(port), *arguments]), \
                patch("socket.socket", side_effect=bus.socket), \
                patch("time.monotonic", side_effect=lambda: bus.clock), \
                patch("time.sleep", side_effect=bus.sleep), \
                contextlib.redirect_stdout(output):
            try:
                runpy.run_path(str(SCRIPTS / filename), run_name="__main__")
            except SystemExit as exception:
                error = exception.code
        import amber_api.amber_robot
        self.assertIn("amber_api.zip", amber_api.amber_robot.__file__)
        return error, output.getvalue()

    def test_activate_and_deactivate_use_shipped_sdk(self):
        for filename, mode, port in [("cmd_activate_mode_v2.py", 1, 26001),
                                     ("cmd_deactivate_mode_v2.py", 0, 26002)]:
            with self.subTest(mode=mode):
                bus = FakeBus()
                error, output = self.run_script(filename, bus, port=port)
                self.assertIsNone(error)
                self.assertEqual(bus.commands, [10, 110])
                self.assertEqual(bus.mode_changes, [mode])
                self.assertIn("all seven joints", output)

    def test_position_and_current_verify_active_before_transition(self):
        for filename, mode in [("cmd_position_mode_v2.py", 2), ("cmd_current_mode_v2.py", 4)]:
            with self.subTest(mode=mode):
                bus = FakeBus([0] * 7)
                error, _ = self.run_script(filename, bus)
                self.assertIsNone(error)
                self.assertEqual(bus.commands, [10, 110, 10, 110])
                self.assertEqual(bus.mode_changes, [1, mode])

    def test_partial_activation_never_proceeds_to_position_or_current(self):
        for filename in ("cmd_position_mode_v2.py", "cmd_current_mode_v2.py"):
            with self.subTest(filename=filename):
                bus = FakeBus()
                bus.mode_results[1] = [1, 1, 1, 1, 0, 0, 0]
                error, _ = self.run_script(filename, bus)
                self.assertIn("not verified", error)
                self.assertEqual(bus.mode_changes, [1])
                self.assertNotIn(4, bus.commands)

    def test_partial_final_mode_is_a_failure(self):
        bus = FakeBus()
        bus.mode_results[2] = [2, 2, 2, 2, 0, 0, 0]
        error, output = self.run_script("cmd_position_mode_v2.py", bus)
        self.assertIn("[2, 2, 2, 2, 0, 0, 0]", error)
        self.assertNotIn("all seven joints in position", output)
        self.assertEqual(bus.mode_changes, [1, 2])

    def test_unacknowledged_mode_is_not_retried(self):
        for response in (0, "timeout"):
            with self.subTest(response=response):
                bus = FakeBus()
                bus.acknowledgements[10] = response
                error, _ = self.run_script("cmd_deactivate_mode_v2.py", bus)
                self.assertIn("not acknowledged", error)
                self.assertEqual(bus.commands, [10])

    def test_missing_readback_does_not_claim_deactivated(self):
        bus = FakeBus()
        bus.acknowledgements[110] = "timeout"
        error, output = self.run_script("cmd_deactivate_mode_v2.py", bus)
        self.assertIn("readback failed", error)
        self.assertNotIn("all seven joints", output)
        self.assertEqual(bus.commands, [10, 110])

    def test_position_requires_modes_and_reports_acknowledgement(self):
        bus = FakeBus()
        error, output = self.run_script("cmd_position_input_v2.py", bus, "--servo2", "-0.1")
        self.assertIsNone(error)
        self.assertEqual(bus.commands, [110, 1, 110, 4])
        self.assertEqual(bus.mode_changes, [])
        self.assertIn("does not verify physical motion", output)
        packet = bus.requests[-1][0]
        self.assertAlmostEqual(struct.unpack_from("<f", packet, 12)[0], -0.1)

    def test_position_with_partial_modes_is_blocked(self):
        bus = FakeBus([2, 2, 2, 2, 0, 0, 0])
        error, _ = self.run_script("cmd_position_input_v2.py", bus)
        self.assertIn("Position command blocked", error)
        self.assertEqual(bus.commands, [110])

    def test_mode_change_during_position_preflight_is_blocked(self):
        bus = FakeBus()
        bus.query_results = [[2] * 7, [2, 2, 2, 2, 0, 0, 0]]
        error, _ = self.run_script("cmd_position_input_v2.py", bus)
        self.assertIn("Position command blocked", error)
        self.assertNotIn(4, bus.commands)

    def test_rejected_position_is_a_failure_without_retry(self):
        bus = FakeBus()
        bus.acknowledgements[4] = 0
        error, output = self.run_script("cmd_position_input_v2.py", bus)
        self.assertIn("rejected or not acknowledged", error)
        self.assertNotIn("Position command acknowledged", output)
        self.assertEqual(bus.commands.count(4), 1)

    def test_nonfinite_targets_and_invalid_times_never_open_socket(self):
        for argument, value in [("--servo2", "nan"), ("--servo6", "inf"),
                                ("--cmd_time", "0"), ("--cmd_sleep", "-1")]:
            with self.subTest(argument=argument):
                bus = FakeBus()
                error, _ = self.run_script("cmd_position_input_v2.py", bus, argument, value)
                self.assertIn("Position command blocked", error)
                self.assertEqual(bus.requests, [])

    def test_sdk_target_limit_failure_is_reported(self):
        bus = FakeBus()
        error, _ = self.run_script("cmd_position_input_v2.py", bus, "--servo6", "3")
        self.assertIn("rejected or not acknowledged", error)
        self.assertNotIn(4, bus.commands)


if __name__ == "__main__":
    unittest.main()
