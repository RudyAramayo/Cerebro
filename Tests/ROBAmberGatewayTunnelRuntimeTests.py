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
    static func wait(_ predicate: () -> Bool, seconds: Double = 2, line: UInt = #line) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Tunnel fixture timed out at line \(line)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
    static func main() {
        setbuf(stdout, nil)
        let tunnel = ROBAmberGatewayTunnel()
        tunnel.sshIdentityPath = { nil }
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

        config.password = nil
        tunnel.sshIdentityPath = { "/fixture/cerebro_amber_ed25519" }
        tunnel.connectIfConfigured()
        let keyed = FixtureProcess.launched.last!
        precondition(keyed.executableURL?.path == "/usr/bin/ssh")
        precondition(keyed.arguments!.contains("/fixture/cerebro_amber_ed25519"))
        precondition(keyed.arguments!.contains("BatchMode=yes") && keyed.arguments!.contains("IdentitiesOnly=yes"))
        precondition(!keyed.arguments!.contains("-d") && !(keyed.standardInput is Pipe))
        let keyConnects = gateway.connects
        wait({ gateway.connects > keyConnects })
        gateway.state = .ready
        wait({ tunnel.detail.contains("gateway authenticated") })
        keyed.exit(255, error: "Permission denied (publickey).")
        wait({ tunnel.failureDetail != nil })
        precondition(tunnel.failureDetail!.contains("installed Amber public key"))
        precondition(!tunnel.isRunning)
        print("Tunnel: key-only startup without password, direct noninteractive SSH and key-specific failure passed")

        let bindError = "bind [127.0.0.1]:7443: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: 7443\nCould not request local forwarding."
        func beginRecovery() -> FixtureProcess {
            tunnel.connect(host: "occupied-robot.invalid")
            let occupied = FixtureProcess.launched.last!
            occupied.exit(255, error: bindError)
            wait({ FixtureProcess.launched.last !== occupied })
            let recovery = FixtureProcess.launched.last!
            precondition(recovery.executableURL?.path == "/bin/sh")
            precondition(recovery.arguments![0] == "-c")
            precondition(recovery.arguments![1].contains("-iTCP:7443 -sTCP:LISTEN"))
            precondition(recovery.arguments![1].contains("/bin/kill -9"))
            precondition(recovery.arguments![1].contains("/usr/bin/sudo -n"))
            precondition(!(recovery.standardInput is Pipe))
            precondition(tunnel.detail.contains("clearing its listener"))
            return recovery
        }
        let recovery = beginRecovery()
        let duringRecovery = FixtureProcess.launched.count
        tunnel.connect(); tunnel.connect(host: " occupied-robot.invalid ")
        precondition(FixtureProcess.launched.count == duringRecovery)
        recovery.exit(0, error: "")
        wait({ FixtureProcess.launched.count == duringRecovery + 1 })
        let retried = FixtureProcess.launched.last!
        precondition(retried.executableURL?.path == "/usr/bin/ssh")
        precondition(retried.arguments!.contains("amber@occupied-robot.invalid"))
        retried.exit(255, error: bindError)
        wait({ tunnel.failureDetail != nil })
        precondition(FixtureProcess.launched.count == duringRecovery + 1,
                     "A persistent bind failure retried more than once")
        precondition(tunnel.failureDetail!.contains("Address already in use"))
        print("Tunnel: port conflict clears listener, coalesces duplicate requests and retries once passed")

        let successfulRecovery = beginRecovery()
        let beforeSuccessfulRetry = FixtureProcess.launched.count
        successfulRecovery.exit(0, error: "")
        wait({ FixtureProcess.launched.count == beforeSuccessfulRetry + 1 })
        let connectsBeforeRecovery = gateway.connects
        wait({ gateway.connects > connectsBeforeRecovery })
        gateway.state = .ready
        wait({ tunnel.detail.contains("gateway authenticated") })
        let authenticated = FixtureProcess.launched.last!
        let authenticatedLaunches = FixtureProcess.launched.count
        authenticated.exit(255, error: bindError)
        wait({ tunnel.failureDetail != nil })
        precondition(FixtureProcess.launched.count == authenticatedLaunches,
                     "Recovery restarted an authenticated session")
        print("Tunnel: recovered tunnel authenticates, established sessions never auto-reconnect passed")

        let deniedRecovery = beginRecovery()
        let beforeDeniedRecovery = FixtureProcess.launched.count
        deniedRecovery.exit(1, error: "sudo: a password is required")
        wait({ tunnel.failureDetail != nil })
        precondition(tunnel.failureDetail!.contains("Could not clear port 7443"))
        precondition(tunnel.failureDetail!.contains("password is required"))
        precondition(FixtureProcess.launched.count == beforeDeniedRecovery && !tunnel.isRunning)

        let cancelledRecovery = beginRecovery()
        let lateRecoveryCallback = cancelledRecovery.terminationHandler!
        tunnel.disconnect()
        tunnel.connect(host: "replacement-robot.invalid")
        let replacement = FixtureProcess.launched.last!
        cancelledRecovery.exit(0, error: "")
        lateRecoveryCallback(cancelledRecovery)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        precondition(FixtureProcess.launched.last === replacement && !replacement.terminated)
        precondition(tunnel.failureDetail == nil)
        tunnel.disconnect()

        let pendingRecovery = beginRecovery()
        let beforePendingCancel = FixtureProcess.launched.count
        pendingRecovery.exit(0, error: "")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        tunnel.disconnect()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        precondition(FixtureProcess.launched.count == beforePendingCancel)

        let hungRecovery = beginRecovery()
        let beforeHungRecovery = FixtureProcess.launched.count
        wait({ tunnel.failureDetail?.contains("Clearing port 7443 timed out") == true }, seconds: 6)
        precondition(hungRecovery.terminated && !tunnel.isRunning)
        precondition(FixtureProcess.launched.count == beforeHungRecovery)
        print("Tunnel: cleanup permissions, cancellation, stale completions and timeout passed")

        for error in ["bind [127.0.0.1]:7444: Address already in use",
                      "bind [127.0.0.1]:7443: Permission denied",
                      "ssh: connect to host robot port 22: Connection refused"] {
            tunnel.connect()
            let unrelated = FixtureProcess.launched.last!
            let beforeUnrelated = FixtureProcess.launched.count
            unrelated.exit(255, error: error)
            wait({ tunnel.failureDetail != nil })
            precondition(FixtureProcess.launched.count == beforeUnrelated)
        }
        print("Tunnel: other ports and non-bind failures never kill a listener passed")

        // Launch before the robot is online: retry telemetry with backoff,
        // without reopening a debugger or replaying a motor command.
        let automatic = ROBAmberGatewayTunnel()
        automatic.sshIdentityPath = { "/fixture/cerebro_amber_ed25519" }
        var clock = 1000.0
        automatic.automaticConnectionNow = { clock }
        automatic.connectIfConfigured()
        let offline = FixtureProcess.launched.last!
        offline.exit(255, error: "ssh: connect to host robot port 22: No route to host")
        wait({ automatic.failureDetail != nil })
        let afterOffline = FixtureProcess.launched.count
        clock += 1; automatic.maintainAutomaticConnection()
        precondition(FixtureProcess.launched.count == afterOffline)
        clock += 2; automatic.maintainAutomaticConnection()
        precondition(FixtureProcess.launched.count == afterOffline + 1)
        let automaticallyRetried = FixtureProcess.launched.last!
        wait({ gateway.state == .connecting })
        gateway.state = .ready
        wait({ automatic.detail.contains("gateway authenticated") })
        automatic.maintainAutomaticConnection()
        precondition(FixtureProcess.launched.last === automaticallyRetried)
        let connectsBeforeLoss = gateway.connects
        gateway.state = .failed
        automatic.maintainAutomaticConnection()
        wait({ gateway.connects > connectsBeforeLoss })
        gateway.state = .ready
        wait({ automatic.detail.contains("gateway authenticated") })
        precondition(FixtureProcess.launched.last === automaticallyRetried && !automaticallyRetried.terminated,
            "A lost gateway connection required manually restarting the healthy SSH tunnel")
        automatic.disconnect()
        clock += 100; automatic.maintainAutomaticConnection()
        precondition(FixtureProcess.launched.last === automaticallyRetried && automaticallyRetried.terminated)
        print("Tunnel: late startup retries and automatic reconnection after gateway loss; healthy SSH reused, explicit disconnect retained, no motor interface or replay")
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
        subprocess.run([str(binary)], check=True, timeout=40)


if __name__ == "__main__":
    main()
