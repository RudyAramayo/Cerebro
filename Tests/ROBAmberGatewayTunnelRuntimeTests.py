#!/usr/bin/env python3
"""Exercise production tunnel lifecycle with fake SSH, Keychain and gateway.

No sockets, robot commands, real credentials or user preferences are accessed.
Only process execution and the tunnel's external dependencies are substituted.
"""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Foundation

enum ROBAmberGatewayState: Int { case disconnected, connecting, authenticating, ready, failed }
extension Notification.Name {
    static let ROBAmberGatewayTunnelDidChange = Notification.Name("FixtureTunnelChanged")
}
final class ROBAmberGatewayConfiguration {
    static let shared = ROBAmberGatewayConfiguration()
    var sshHost = "configured-robot.invalid"
    var password: String? = "fixture password"
    var hasGatewayToken = true
    var hasSSHPassword: Bool { password != nil }
    func gatewayToken() -> String? { String(repeating: "t", count: 64) }
    func sshPassword() -> String? { password }
}
final class ROBAmberGatewayClient {
    static let shared = ROBAmberGatewayClient()
    var state = ROBAmberGatewayState.disconnected
    var connects = 0, disconnects = 0
    func connect(token: String) { connects += 1; state = .connecting }
    func disconnect() { disconnects += 1; state = .disconnected }
    func isReady() -> Bool { state == .ready }
    func connectionSnapshot() -> NSDictionary {
        ["state": NSNumber(value: state.rawValue), "detail": "Fixture gateway token rejected"]
    }
}
final class FixtureProcess: NSObject {
    static var launched: [FixtureProcess] = []
    var executableURL: URL?
    var arguments: [String]?
    var environment: [String: String]?
    var standardInput: Any?, standardOutput: Any?, standardError: Any?
    var terminationHandler: ((FixtureProcess) -> Void)?
    var isRunning = false, terminated = false
    var terminationStatus: Int32 = 0
    func run() throws { isRunning = true; Self.launched.append(self) }
    func terminate() { isRunning = false; terminated = true }
    func exit(_ status: Int32, error: String) {
        terminationStatus = status; isRunning = false
        let pipe = standardError as! Pipe
        pipe.fileHandleForWriting.write(Data(error.utf8))
        pipe.fileHandleForWriting.closeFile()
        terminationHandler?(self)
    }
}
'''

TESTS = r'''
@main struct TunnelFixture {
    static func wait(_ predicate: () -> Bool, seconds: Double = 2) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Tunnel fixture timed out")
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
    static func main() {
        let tunnel = ROBAmberGatewayTunnel()
        let gateway = ROBAmberGatewayClient.shared
        let config = ROBAmberGatewayConfiguration.shared
        tunnel.connect()
        let first = FixtureProcess.launched.last!
        let args = first.arguments!
        precondition(args.contains("amber@configured-robot.invalid"))
        precondition(Array(args.prefix(4)) == ["-d", "0", "/usr/bin/ssh", "-N"])
        for option in ["NumberOfPasswordPrompts=1", "ConnectionAttempts=1", "ConnectTimeout=5",
                       "StrictHostKeyChecking=accept-new", "GatewayPorts=no",
                       "127.0.0.1:7443:127.0.0.1:7443"] {
            precondition(args.contains(option), option)
        }
        precondition(!args.contains(config.password!) && first.environment?["SSHPASS"] == nil)
        precondition(first.environment?["SSH_ASKPASS_REQUIRE"] == "never")
        let password = (first.standardInput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        precondition(String(data: password, encoding: .utf8) == config.password! + "\n")
        precondition(!tunnel.detail.contains("active"), "Process launch was mistaken for authentication")
        let disconnects = gateway.disconnects
        tunnel.connect(); tunnel.connect(host: " configured-robot.invalid ")
        precondition(FixtureProcess.launched.count == 1 && gateway.disconnects == disconnects)
        wait({ gateway.connects == 1 })
        gateway.state = .ready
        wait({ tunnel.detail.contains("gateway authenticated") })
        tunnel.connect()
        precondition(FixtureProcess.launched.count == 1 && gateway.connects == 1 && !first.terminated)
        print("Tunnel: configured host, pipe credential, bounded SSH and in-flight/ready reuse passed")

        // A new explicit operation may reconnect the gateway over the existing
        // SSH transport. There is no autonomous reconnect or command replay.
        gateway.state = .failed
        tunnel.connect()
        wait({ gateway.connects == 2 })
        precondition(FixtureProcess.launched.count == 1)
        gateway.state = .failed
        wait({ tunnel.failureDetail != nil })
        precondition(tunnel.failureDetail == "Fixture gateway token rejected" && first.terminated)

        tunnel.connect(host: "manual-robot.invalid")
        precondition(config.sshHost == "manual-robot.invalid" && tunnel.failureDetail == nil)
        let rejected = FixtureProcess.launched.last!
        rejected.exit(255, error: "Permission denied, please try again.\nPermission denied (publickey,password).")
        wait({ tunnel.failureDetail != nil })
        precondition(!tunnel.isRunning && tunnel.failureDetail!.contains("SSH login rejected for amber@manual-robot.invalid"))
        precondition(tunnel.failureDetail!.contains("Controller approval"))
        print("Tunnel: gateway and SSH failures preserve actionable headless errors passed")

        tunnel.connect()
        let cancelled = FixtureProcess.launched.last!
        let staleCompletion = cancelled.terminationHandler!
        tunnel.disconnect()
        let connectsBeforeCancel = gateway.connects
        RunLoop.main.run(until: Date().addingTimeInterval(0.85))
        precondition(gateway.connects == connectsBeforeCancel && cancelled.terminated)
        tunnel.connect()
        let current = FixtureProcess.launched.last!
        // Deliver the old callback after replacement; it cannot close the new
        // transport or overwrite its status.
        (cancelled.standardError as! Pipe).fileHandleForWriting.closeFile()
        staleCompletion(cancelled)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(tunnel.isRunning && !current.terminated && tunnel.failureDetail == nil)
        tunnel.disconnect()
        config.password = nil
        let launches = FixtureProcess.launched.count
        tunnel.connect()
        precondition(FixtureProcess.launched.count == launches && tunnel.failureDetail!.contains("Keychain"))
        print("Tunnel: cancellation, stale callback isolation and missing-credential failure passed")

        config.password = "fixture password"
        tunnel.connect()
        let stalled = FixtureProcess.launched.last!
        wait({ tunnel.failureDetail?.contains("timed out") == true }, seconds: 12)
        precondition(stalled.terminated && !tunnel.isRunning)
        print("Tunnel: unresponsive gateway is terminated within the connection deadline passed")

        let startupLaunches = FixtureProcess.launched.count
        config.password = nil
        tunnel.connectIfConfigured()
        precondition(FixtureProcess.launched.count == startupLaunches)
        config.password = "fixture password"
        config.hasGatewayToken = false
        tunnel.connectIfConfigured()
        precondition(FixtureProcess.launched.count == startupLaunches)
        config.hasGatewayToken = true
        tunnel.connectIfConfigured()
        tunnel.connectIfConfigured()
        precondition(FixtureProcess.launched.count == startupLaunches + 1)
        let startupConnects = gateway.connects
        wait({ gateway.connects > startupConnects })
        gateway.state = .ready
        wait({ tunnel.detail.contains("gateway authenticated") })
        tunnel.connectIfConfigured()
        precondition(FixtureProcess.launched.count == startupLaunches + 1)
        tunnel.disconnect() // sleep closes the old session before wake
        tunnel.connectIfConfigured()
        precondition(FixtureProcess.launched.count == startupLaunches + 2)
        tunnel.disconnect()
        print("Tunnel: configured startup/wake, missing credentials and duplicate launch passed")
    }
}
'''


def main():
    source = (ROOT / "Cerebro/ROBAmberGatewayClient.swift").read_text()
    start = source.index("@objcMembers public final class ROBAmberGatewayTunnel")
    end = source.index("private struct ROBAmberGatewayMessage", start)
    tunnel = re.sub(r"\bProcess\b", "FixtureProcess", source[start:end])
    # Discovery alone is substituted; the executable is never launched.
    for path in ("/opt/homebrew/bin/sshpass", "/opt/local/bin/sshpass", "/usr/local/bin/sshpass"):
        tunnel = tunnel.replace(path, "/usr/bin/true")
    with tempfile.TemporaryDirectory(prefix="rob-amber-tunnel-") as temporary:
        directory = Path(temporary)
        swift = directory / "TunnelFixture.swift"
        swift.write_text(FIXTURE + tunnel + TESTS)
        binary = directory / "tunnel-fixture"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                        str(swift), "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=25)


if __name__ == "__main__":
    main()
