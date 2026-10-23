#!/usr/bin/env python3
"""Run the production startup coordinator and gateway decoder without sockets."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
enum ROBArmRoutineError: LocalizedError {
    case blocked(String)
    var errorDescription: String? { if case .blocked(let reason) = self { return reason }; return nil }
}
final class ROBAmberArmReferenceStore {
    static let shared = ROBAmberArmReferenceStore()
    func readiness(forArm: String) -> (isReady: Bool, detail: String) { (false, "Fixture") }
    func vendorTargetSnapshot(fromModel: [Double], forArm: String)
        -> (positionsRadians: [Double], gatewaySessionGeneration: UInt64)? { nil }
}
extension ROBAmberGatewayClient {
    fileprivate func fixtureReceive(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        queue.sync { handle(try! decoder.decode(ROBAmberGatewayMessage.self, from: data)) }
    }
    fileprivate func fixtureReady(supported: Bool = true) {
        fixtureReceive(["type": "ready", "exclusive_controller_session": true,
            "supported_commands": supported ? ["gripper_state", "gripper_calibrate", "gripper_control"] : []])
        for arm in ["left", "right"] {
            fixtureReceive(["type": "mode_query_ack", "arm": arm, "command_id": 800,
                "accepted": true, "modes": [Int](repeating: 0, count: 7)])
        }
    }
    fileprivate func fixtureFresh(sequence: UInt64, position: Double = 0, active: Bool = false) {
        for arm in ["left", "right"] {
            fixtureReceive(["type": "telemetry", "arm": arm, "sequence": sequence,
                "sample_age_ms": 1.0, "controller_sample_age_ms": 1.0,
                "joint_feedback_age_ms": [Double](repeating: 1, count: 7), "gripper_feedback_age_ms": 1.0,
                "positions_rad": [Double](repeating: position, count: 7),
                "velocities_rad_s": NSNull(), "velocities_available": false,
                "currents": [Double](repeating: 0, count: 7),
                "statuses": [Double](repeating: active ? 2 : 0, count: 7)])
        }
    }
    fileprivate func fixtureAcknowledge() {
        let pending = queue.sync { pendingGripperCommands }
        for (id, command) in pending {
            var value: [String: Any] = ["type": command.operation + "_ack", "command_id": id,
                "arm": command.arm, "accepted": true,
                "calibration_state": "command_accepted_unverified", "calibration_verified": false,
                "feedback_available": false, "command_in_flight": false,
                "force_min": 1, "force_max": 300, "force_unit": "vendor_intensity",
                "supported_actions": ["release", "hold"], "gateway_latency_ms": 1.0]
            if command.operation == "gripper_calibrate" {
                value["amber_response"] = 1; value["calibration_command_accepted"] = true
                value["completion_verified"] = false
            } else if command.operation == "gripper_control" {
                value["amber_response"] = 1; value["completion_verified"] = false
                value["action"] = command.action!; value["force"] = command.force!
            }
            fixtureReceive(value)
        }
    }
    fileprivate func fixtureRejectPending() {
        let pending = queue.sync { pendingGripperCommands }
        for (id, command) in pending {
            fixtureReceive(["type": command.operation + "_ack", "command_id": id,
                "arm": command.arm, "accepted": false, "error": "Fixture calibration rejected"])
        }
    }
    fileprivate var fixturePhysical: [ROBAmberGatewayMessage] {
        queue.sync { fixtureSent.filter { ["gripper_calibrate", "gripper_control"].contains($0.type) } }
    }
    fileprivate var fixtureArmMotion: [ROBAmberGatewayMessage] {
        queue.sync { fixtureSent.filter { ["activate", "position_mode", "trajectory", "leased_trajectory"].contains($0.type) } }
    }
    fileprivate func fixtureDisconnect() { queue.sync { disconnectOnQueue(detail: "Fixture disconnected") } }
}
extension ROBGripperStartupCalibration {
    fileprivate func fixtureLoseOwnership() {
        if let arbiterOwner { ROBAmberArmMotionArbiter.shared.release(.left, owner: arbiterOwner) }
    }
}

@main struct StartupFixtures {
    static var sequence: UInt64 = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func pump(_ client: ROBAmberGatewayClient, seconds: Double,
                     fresh: Bool = true, position: Double = 0, active: Bool = false, acknowledge: Bool = true) {
        let until = Date(timeIntervalSinceNow: seconds)
        repeat {
            if fresh { sequence += 1; client.fixtureFresh(sequence: sequence, position: position, active: active) }
            if acknowledge { client.fixtureAcknowledge() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
        } while Date() < until
    }
    static func main() {
        let original = UserDefaults.standard.object(forKey: ROBGripperStartupCalibration.preferenceKey)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: ROBGripperStartupCalibration.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: ROBGripperStartupCalibration.preferenceKey) }
        }
        UserDefaults.standard.set(true, forKey: ROBGripperStartupCalibration.preferenceKey)
        let client = ROBAmberGatewayClient()
        let startup = ROBGripperStartupCalibration(gateway: client)
        client.fixtureReady(); startup.gatewayBecameReady()
        pump(client, seconds: 0.9, acknowledge: false)
        expect(client.fixturePhysical.count == 1, "Startup did not serialize its first calibration")
        client.fixtureRejectPending(); pump(client, seconds: 0.15)
        expect(!startup.isRunning && !startup.calibrationReady(forArm: "left"), "Rejected startup claimed readiness")
        startup.gatewayBecameReady(); pump(client, seconds: 0.1)
        expect(client.fixturePhysical.count == 1, "Rejected startup retried automatically")
        var manualFailure: String?
        Task { @MainActor in
            do { try await startup.prepareStationaryEmptyGrippers() }
            catch { manualFailure = error.localizedDescription }
        }
        pump(client, seconds: 0.9)
        expect(client.fixturePhysical.count == 2, "Explicit supervised stationary retry was denied")
        expect(client.activateArm("left") == 0, "Startup permitted arm activation")
        expect(client.enterPositionMode(forArm: "right") == 0, "Startup permitted torque mode change")
        expect(client.calibrateGripper(forArm: "right") == 0, "Another calibration bypassed startup ownership")
        expect(client.controlGripper(forArm: "left", action: "hold", force: 20) == 0, "Another jaw action bypassed startup ownership")
        expect(client.priorityHold(forArm: "left") > 0, "Priority Stop lane was blocked")
        pump(client, seconds: 27)
        expect(!startup.isRunning, "Startup did not complete within its bounded sequence")
        expect(startup.calibrationReady(forArm: "left") && startup.calibrationReady(forArm: "right"), "Current-generation initialized readiness missing")
        expect(manualFailure == nil, "Explicit stationary retry failed")
        let commands = Array(client.fixturePhysical.dropFirst())
        expect(commands.map(\.type) == ["gripper_calibrate", "gripper_control", "gripper_control", "gripper_calibrate", "gripper_control", "gripper_control"], "Startup sequence changed")
        expect(commands.map(\.arm) == ["left", "left", "left", "right", "right", "right"], "Startup lost serial per-arm routing")
        expect(commands.compactMap(\.force) == [2, 10, 2, 10], "Startup escalated commissioned intensities")
        expect(commands.compactMap(\.action) == ["hold", "release", "hold", "release"], "Startup empty-jaw initialization mapping inverted")
        expect(client.fixtureArmMotion.isEmpty, "Gripper setup moved or activated an arm")
        expect(client.gripperSnapshot(forArm: "right")["calibrationVerified"] as? Bool == false, "Dispatch became a measured-calibration claim")
        startup.gatewayBecameReady(); pump(client, seconds: 0.1)
        expect(client.fixturePhysical.count == 7, "Duplicate ready repeated calibration")
        client.fixtureDisconnect(); pump(client, seconds: 0.05, fresh: false)
        expect(!startup.calibrationReady(forArm: "left"), "Disconnect retained initialized readiness")
        client.fixtureReady(); startup.gatewayBecameReady(); pump(client, seconds: 0.8)
        expect(client.fixturePhysical.count == 7, "Trivial reconnect replayed physical setup")
        client.fixtureDisconnect()

        for kind in ["stale", "held", "active", "stop", "disconnect", "ownership", "legacy"] {
            let next = ROBAmberGatewayClient()
            let policy = ROBGripperStartupCalibration(gateway: next)
            next.fixtureReady(supported: kind != "legacy"); policy.gatewayBecameReady()
            if kind == "stale" {
                next.fixtureFresh(sequence: 1000); pump(next, seconds: 0.8, fresh: false)
            } else if kind == "held" {
                pump(next, seconds: 0.8, position: 0.5)
                expect(!policy.isRunning && policy.status.contains("deferred"), "Known held pose blocked the Sandbox instead of deferring within two seconds")
            } else if kind == "active" {
                pump(next, seconds: 0.8, active: true)
                expect(!policy.isRunning && policy.status.contains("deferred"), "Known active pose did not promptly defer setup")
            } else {
                pump(next, seconds: 0.8)
                if kind == "stop" { policy.stop(reason: "Operator Stop") }
                if kind == "disconnect" { next.fixtureDisconnect() }
                if kind == "ownership" {
                    policy.fixtureLoseOwnership()
                }
                pump(next, seconds: 0.25, fresh: kind != "disconnect")
                if kind == "stop" {
                    Task { @MainActor in try? await policy.prepareStationaryEmptyGrippers() }
                    pump(next, seconds: 0.9)
                    expect(next.fixturePhysical.count == 1, "Manual retry overlapped an already dispatched calibration's settle interval")
                }
            }
            if ["stale", "held", "active", "legacy"].contains(kind) {
                expect(next.fixturePhysical.isEmpty, "\(kind) startup dispatched a calibration")
            } else {
                expect(next.fixturePhysical.count == 1, "\(kind) allowed a jaw initialization after cancellation")
            }
            policy.stop(reason: "Fixture cleanup"); pump(next, seconds: 0.1, fresh: kind != "disconnect")
            expect(!policy.isRunning, "Cancelled startup kept running")
            expect(!policy.calibrationReady(forArm: "left"), "Cancelled setup claimed readiness")
            expect(!ROBAmberArmMotionArbiter.shared.isReserved(.left), "Cancelled startup leaked arm ownership")
            expect(next.fixtureArmMotion.isEmpty, "\(kind) startup moved an arm")
            next.fixtureDisconnect(); pump(next, seconds: 0.03, fresh: false)
        }
        print("Startup gripper fixtures passed: hanging/inactive/fresh admission; serialized calibration and close2/open10; no arm activation, duplicate or reconnect replay; rejection needs explicit manual retry; Stop/disconnect/ownership cancellation, retry settle cooldown and unverified readiness")
    }
}
'''


def main():
    client = (ROOT / "Cerebro/ROBAmberGatewayClient.swift").read_text()
    client = client.replace("private let encoder = JSONEncoder()",
                            "private var fixtureSent: [ROBAmberGatewayMessage] = []\n    private let encoder = JSONEncoder()")
    client = client.replace("private func send(_ message: ROBAmberGatewayMessage) {",
                            "private func send(_ message: ROBAmberGatewayMessage) {\n        fixtureSent.append(message)")
    support = (ROOT / "Tests/ROBArmRoutineGatewayFixtureSupport.swift").read_text().split(
        "// Gateway-only fixtures never instantiate")[0]
    with tempfile.TemporaryDirectory(prefix="rob-startup-grippers-") as folder:
        directory = Path(folder)
        source = directory / "StartupFixture.swift"
        binary = directory / "startup-fixture"
        source.write_text(client + (ROOT / "Cerebro/ROBArmRoutinePlan.swift").read_text()
                          + support + (ROOT / "Cerebro/ROBGripperStartupCalibration.swift").read_text() + FIXTURE)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                        str(source), "-o", str(binary)], check=True, timeout=90)
        subprocess.run([str(binary)], check=True, timeout=45)


if __name__ == "__main__":
    main()
