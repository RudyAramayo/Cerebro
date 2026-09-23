#!/usr/bin/env python3
"""Exercise the production client's delayed-listener recovery on loopback only."""

import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
final class ROBAmberArmReferenceStore {
    static let shared = ROBAmberArmReferenceStore()
    func readiness(forArm: String) -> (isReady: Bool, detail: String) { (false, "Fixture") }
    func vendorTargetSnapshot(fromModel: [Double], forArm: String)
        -> (positionsRadians: [Double], gatewaySessionGeneration: UInt64)? { nil }
}

extension ROBAmberGatewayClient {
    fileprivate func fixtureDisconnect() {
        queue.sync { disconnectOnQueue(detail: "Fixture disconnect") }
    }
}

@main
struct InitialConnectionFixture {
    static func wait(_ predicate: () -> Bool, detail: () -> String, seconds: Double = 12) {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            guard Date() < deadline else { fatalError("Connection fixture timed out: \(detail())") }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    static func main() {
        let client = ROBAmberGatewayClient()
        defer { client.fixtureDisconnect() }
        let mode = CommandLine.arguments[1]
        client.connect(port: UInt16(CommandLine.arguments[2])!, token: String(repeating: "a", count: 64))
        func state() -> Int {
            (client.connectionSnapshot()["state"] as! NSNumber).intValue
        }
        func detail() -> String { client.connectionSnapshot()["detail"] as! String }
        // Prove an initial refused connection happened before the listener opened.
        wait({ detail().contains("connection retry") }, detail: detail)
        if mode == "cancel" {
            client.fixtureDisconnect()
            try! Data().write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            Thread.sleep(forTimeInterval: 2.5)
            precondition(state() == ROBAmberGatewayState.disconnected.rawValue,
                         "A cancelled initial connection restarted")
        } else if mode == "exhaust" {
            wait({ state() == ROBAmberGatewayState.failed.rawValue }, detail: detail)
            precondition(detail().contains("after 5 initial retries")
                         || detail().contains("timed out after 10 seconds"),
                         "Neither the retry budget nor the deadline failed visibly")
        } else {
            try! Data().write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            wait({ client.isReady() }, detail: detail)
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("Initial connection fixture passed: \(mode)")
    }
}
'''


def exercise(binary, mode):
    errors = []
    received_types = []
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        # A bound but non-listening socket reliably refuses the initial attempt.
        marker = binary.parent / (mode + "-waiting")
        process = subprocess.Popen(
            [str(binary), mode, str(listener.getsockname()[1]), str(marker)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

        def serve():
            try:
                deadline = time.monotonic() + 12
                while not marker.exists():
                    assert time.monotonic() < deadline, "Client did not observe the refused connection"
                    time.sleep(0.01)
                listener.listen(1)
                listener.settimeout(3)
                if mode == "cancel":
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        return
                    connection.close()
                    raise AssertionError("Cancelled client connected to the late listener")
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(3)
                    stream = connection.makefile("rwb")
                    challenge = {"type": "challenge", "protocol": "rob-amber-gateway/1"}
                    stream.write(json.dumps(challenge).encode() + b"\n")
                    stream.flush()
                    hello = json.loads(stream.readline())
                    assert hello["type"] == "hello" and hello["token"] == "a" * 64
                    received_types.append(hello["type"])
                    ready = {"type": "ready", "protocol": "rob-amber-gateway/1",
                             "exclusive_controller_session": True}
                    stream.write(json.dumps(ready).encode() + b"\n")
                    stream.flush()
                    while line := stream.readline():
                        received_types.append(json.loads(line)["type"])
                    stream.close()
            except Exception as error:
                errors.append(error)

        server = None
        if mode != "exhaust":
            server = threading.Thread(target=serve, daemon=True)
            server.start()
        try:
            stdout, stderr = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise
        if server:
            server.join(timeout=5)
            assert not server.is_alive(), "Fixture server did not finish"
        assert process.returncode == 0, stdout + stderr + repr(errors)
        assert not errors, errors
        assert set(received_types) <= {"hello", "heartbeat"}, received_types
        if mode == "recover":
            assert "hello" in received_types
        print(stdout.strip())


def main():
    with tempfile.TemporaryDirectory(prefix="rob-amber-connect-") as directory:
        folder = Path(directory)
        source = folder / "ConnectionFixture.swift"
        binary = folder / "connection-fixture"
        source.write_text((ROOT / "Cerebro/ROBAmberGatewayClient.swift").read_text() + FIXTURE)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(folder / "module-cache"), str(source), "-o", str(binary),
        ], check=True)
        for mode in ("recover", "cancel", "exhaust"):
            exercise(binary, mode)


if __name__ == "__main__":
    main()
