#!/usr/bin/env python3
"""Exercise the production cleanup on disposable ports and fake privileged tools."""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Cerebro/ROBAmberGatewayClient.swift").read_text()
SCRIPT = textwrap.dedent(SOURCE.split(
    '@nonobjc private static let portRecoveryScript = """\n', 1
)[1].split('\n    """', 1)[0])


class PortRecoveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rob-port-recovery-")
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        # Never run real sudo, including when testing a real fixture listener.
        self.sudo = self.executable("sudo", "exit 1\n")

    def executable(self, name, body):
        path = self.folder / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o700)
        return shlex.quote(str(path))

    def run_script(self, script=SCRIPT):
        return subprocess.run(
            ["/bin/sh", "-c", script.replace("/usr/bin/sudo", self.sudo)],
            text=True, capture_output=True, timeout=5,
        )

    def child(self, source, *arguments):
        process = subprocess.Popen(
            [sys.executable, "-u", "-c", source, *map(str, arguments)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
        )

        def close():
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)

        self.addCleanup(close)
        return process

    def test_kills_only_listener_and_preserves_connected_client_and_other_port(self):
        listener_source = (
            "import socket, sys\n"
            "listener = socket.socket()\n"
            "listener.bind(('127.0.0.1', 0))\n"
            "listener.listen(1)\n"
            "print(listener.getsockname()[1], flush=True)\n"
            "sys.stdin.read()\n"
        )
        listener = self.child(listener_source)
        port_line = listener.stdout.readline()
        if not port_line:
            self.fail("Listener could not start: " + listener.communicate(timeout=5)[1])
        port = int(port_line)
        unrelated = self.child(listener_source)
        other_port = int(unrelated.stdout.readline())
        self.assertNotEqual(port, other_port)
        client = self.child(
            "import socket, sys\n"
            "connection = socket.create_connection(('127.0.0.1', int(sys.argv[1])))\n"
            "print('connected', flush=True)\n"
            "sys.stdin.read()\n", port,
        )
        self.assertEqual(client.stdout.readline().strip(), "connected")
        result = self.run_script(SCRIPT.replace(":7443", ":" + str(port)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(listener.wait(timeout=3), -9)
        self.assertIsNone(client.poll(), "Cleanup killed a connected client")
        self.assertIsNone(unrelated.poll(), "Cleanup killed another port's listener")

    def test_port_already_free_retries_without_killing_anything(self):
        lsof = self.executable("lsof", "exit 1\n")
        kill = self.executable("kill", "echo 'unexpected kill' >&2; exit 42\n")
        result = self.run_script(SCRIPT.replace("/usr/sbin/lsof", lsof).replace("/bin/kill", kill))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_lookup_failure_stops_before_killing(self):
        lsof = self.executable("lsof", "echo 'fixture lookup failed' >&2; exit 2\n")
        kill = self.executable("kill", "echo 'unexpected kill' >&2; exit 42\n")
        result = self.run_script(SCRIPT.replace("/usr/sbin/lsof", lsof).replace("/bin/kill", kill))
        self.assertEqual(result.returncode, 2)
        self.assertIn("Could not identify the listener", result.stderr)
        self.assertNotIn("unexpected kill", result.stderr)

    def test_permission_failure_uses_noninteractive_sudo(self):
        log = self.folder / "sudo.log"
        lsof = self.executable("lsof", "echo 424242\n")
        kill = self.executable("kill", "exit 1\n")
        self.sudo = self.executable("sudo", (
            'case "$2" in */lsof) exit 1 ;; esac\n'
            'printf "%s\\n" "$*" >> ' + shlex.quote(str(log)) + "\n"
            "exit 0\n"
        ))
        result = self.run_script(SCRIPT.replace("/usr/sbin/lsof", lsof).replace("/bin/kill", kill))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().strip(), "-n " + str(self.folder / "kill") + " -9 424242")

    def test_privileged_discovery_does_not_require_unprivileged_lookup(self):
        lsof = self.executable("lsof", "echo 'unexpected lookup' >&2; exit 2\n")
        kill = self.executable("kill", "exit 0\n")
        self.sudo = self.executable("sudo", "echo 424242\n")
        result = self.run_script(SCRIPT.replace("/usr/sbin/lsof", lsof).replace("/bin/kill", kill))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_sudo_password_requirement_is_visible(self):
        lsof = self.executable("lsof", "echo 424242\n")
        kill = self.executable("kill", "exit 1\n")
        self.sudo = self.executable("sudo", "echo 'sudo: a password is required' >&2; exit 1\n")
        result = self.run_script(SCRIPT.replace("/usr/sbin/lsof", lsof).replace("/bin/kill", kill))
        self.assertEqual(result.returncode, 1)
        self.assertIn("sudo: a password is required", result.stderr)

    def test_cerebro_parent_and_invalid_pids_are_never_killed(self):
        for output in (str(os.getpid()), "invalid-pid"):
            with self.subTest(output=output):
                lsof = self.executable("lsof", "echo " + shlex.quote(output) + "\n")
                kill = self.executable("kill", "echo 'unexpected kill' >&2; exit 42\n")
                script = SCRIPT.replace("/usr/sbin/lsof", lsof).replace("/bin/kill", kill)
                result = self.run_script(script)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("unexpected kill", result.stderr)


if __name__ == "__main__":
    unittest.main()
