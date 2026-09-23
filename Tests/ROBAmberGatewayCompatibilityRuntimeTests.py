#!/usr/bin/env python3
"""Exercise the production gateway decoder without sockets or robot hardware."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

# The client references the arm calibration store only for trajectory requests.
# These fixtures never request a trajectory, and the stub always denies one.
FIXTURES = r'''
final class ROBAmberArmReferenceStore {
    static let shared = ROBAmberArmReferenceStore()
    func readiness(forArm arm: String) -> (isReady: Bool, detail: String) {
        (false, "Hardware-free fixture")
    }
    func vendorTargetSnapshot(fromModel: [Double], forArm: String)
        -> (positionsRadians: [Double], gatewaySessionGeneration: UInt64)? { nil }
}

extension ROBAmberGatewayClient {
    fileprivate func fixtureReceive(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try queue.sync {
            handle(try decoder.decode(ROBAmberGatewayMessage.self, from: data))
        }
    }
    fileprivate func fixtureDisconnect() {
        queue.sync { disconnectOnQueue(detail: "Fixture disconnect") }
    }
}

@main
struct GatewayCompatibilityFixtures {
    static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) {
        guard condition() else { fatalError(detail) }
    }

    static func main() throws {
        let client = ROBAmberGatewayClient()
        defer { client.fixtureDisconnect() }
        let legacyReady: [String: Any] = [
            "type": "ready", "protocol": "rob-amber-gateway/1",
            "exclusive_controller_session": true,
        ]

        // The older gateway permits telemetry but rejects gripper_state.
        // Automatic bridge refreshes must not enqueue those unsupported queries.
        try client.fixtureReceive(legacyReady)
        expect(client.state == .ready, "Legacy gateway lost arm diagnostics")
        expect(client.stateDetail.contains("gateway update required"), "Missing upgrade guidance")
        for arm in ["left", "right"] {
            expect(client.queryGripperState(forArm: arm) == 0, "Legacy gripper query was admitted")
            expect(client.calibrateGripper(forArm: arm) == 0, "Legacy calibration was admitted")
            expect(client.controlGripper(forArm: arm, action: "hold", force: 10) == 0,
                   "Legacy gripper movement was admitted")
            expect(client.gripperSnapshot(forArm: arm)["commandsAvailable"] as? Bool == false,
                   "Legacy snapshot advertised gripper support")
        }
        let beforeReceipt = Date()
        var delayedReceipt: Date?
        var notificationDeliveredAt: Date?
        let receiptObserver = NotificationCenter.default.addObserver(
            forName: .ROBAmberGatewayTelemetryDidUpdate, object: client, queue: nil
        ) { notification in
            if let telemetry = notification.userInfo?["telemetry"] as? ROBAmberGatewayTelemetry,
               telemetry.arm == "right", telemetry.sequence == 1 {
                delayedReceipt = telemetry.receivedAt
                notificationDeliveredAt = Date()
            }
        }
        try client.fixtureReceive([
            "type": "telemetry", "arm": "right", "sequence": 1, "sample_age_ms": 1.0,
            "positions_rad": [Double](repeating: 0.0, count: 7),
            "velocities_rad_s": [Double](repeating: 0.0, count: 7),
            "currents": [Double](repeating: 0.0, count: 7),
            "statuses": [Double](repeating: 0.0, count: 7),
        ])
        let afterReceipt = Date()
        // Simulate a busy UI while the gateway queue has already decoded the
        // packet. Delivery delay must not rewrite its receipt timestamp.
        Thread.sleep(forTimeInterval: 0.08)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        NotificationCenter.default.removeObserver(receiptObserver)
        expect(delayedReceipt.map { $0 >= beforeReceipt && $0 <= afterReceipt } == true,
               "UI delivery time replaced the telemetry receipt timestamp")
        expect(notificationDeliveredAt.map { $0.timeIntervalSince(delayedReceipt!) >= 0.07 } == true,
               "Fixture failed to exercise delayed UI delivery")
        expect(client.telemetry(forArm: "right")?.sequence == 1, "Legacy telemetry was dropped")
        expect(client.queryMode(forArm: "right") > 0, "Legacy mode query was blocked")
        try client.fixtureReceive([
            "type": "telemetry", "arm": "right", "sequence": 2, "sample_age_ms": 1.0,
            "positions_rad": [0.0, -2.079532531860431, 0.0, 0.6667703158009587, 0.0, 0.0, 0.0],
            "velocities_rad_s": NSNull(), "velocities_available": false,
            "currents": [Double](repeating: 0.0, count: 7),
            "statuses": [Double](repeating: 2.0, count: 7),
        ])
        let limited = client.telemetry(forArm: "right")
        expect(limited?.sequence == 2, "Unavailable velocity discarded position diagnostics")
        expect(limited?.positionsRadians.count == 7, "Position vector was lost")
        expect(limited?.velocitiesAvailable == false, "Unverified velocity was advertised")
        expect(limited?.velocitiesRadiansPerSecond.isEmpty == true,
               "Unavailable velocity became zero-speed evidence for reference/settling gates")
        expect(limited?.effectiveSampleAgeMilliseconds.isInfinite == true,
               "Legacy core packets became verified individual motor feedback")
        expect(client.manualArmControlReadiness(forUDPPort: 26002, expectedSessionGeneration: 0)["allowed"] as? Bool == false,
               "Manual SDK command bypassed missing per-motor feedback")

        var motorSample: [String: Any] = [
            "type": "telemetry", "arm": "left", "sequence": 3,
            "sample_age_ms": 1.0, "controller_sample_age_ms": 1.0,
            "joint_feedback_age_ms": [Double](repeating: 1.0, count: 7),
            "gripper_feedback_age_ms": 1.0,
            "positions_rad": [Double](repeating: 0.0, count: 7),
            "velocities_rad_s": NSNull(), "velocities_available": false,
            "currents": [Double](repeating: 0.0, count: 7),
            "statuses": [Double](repeating: 2.0, count: 7),
        ]
        try client.fixtureReceive(motorSample)
        let admitted = client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: 0)
        expect(admitted["allowed"] as? Bool == true, "Fresh physical-right feedback was not admitted on L10")
        let admittedGeneration = (admitted["sessionGeneration"] as! NSNumber).uint64Value
        expect(client.manualArmControlReadiness(forUDPPort: 26002, expectedSessionGeneration: 0)["allowed"] as? Bool == false,
               "Physical-left command borrowed physical-right feedback")
        motorSample["sequence"] = 4
        motorSample["sample_age_ms"] = NSNull()
        motorSample["joint_feedback_age_ms"] = [1.0, NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull()] as [Any]
        try client.fixtureReceive(motorSample)
        expect(client.telemetry(forArm: "left")?.sequence == 4, "Missing CAN replies discarded useful stale diagnostics")
        expect(client.telemetry(forArm: "left")?.effectiveSampleAgeMilliseconds.isInfinite == true,
               "Advancing controller messages freshened silent motors")
        expect(client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: 0)["allowed"] as? Bool == false,
               "Manual position request admitted cached joints")
        motorSample["sequence"] = 5
        motorSample["sample_age_ms"] = 1.0
        motorSample["joint_feedback_age_ms"] = [Double](repeating: 1.0, count: 7)
        motorSample["gripper_feedback_age_ms"] = NSNull()
        try client.fixtureReceive(motorSample)
        expect(client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: 0)["allowed"] as? Bool == false,
               "Missing gripper feedback was accepted by manual arm controls")
        motorSample["gripper_feedback_age_ms"] = 1.0
        motorSample["controller_sample_age_ms"] = 500.0
        try client.fixtureReceive(motorSample)
        expect(client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: 0)["allowed"] as? Bool == false,
               "Live CAN replies freshened a stale LCM sample")
        client.fixtureDisconnect()
        try client.fixtureReceive(legacyReady)
        motorSample["controller_sample_age_ms"] = 1.0
        try client.fixtureReceive(motorSample)
        expect(client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: admittedGeneration)["allowed"] as? Bool == false,
               "Delayed manual command replayed into a different gateway session")

        // All three operations must be advertised before admitting gripper work.
        client.fixtureDisconnect()
        var partial = legacyReady
        partial["supported_commands"] = ["gripper_state", "gripper_calibrate"]
        try client.fixtureReceive(partial)
        expect(client.queryGripperState(forArm: "left") == 0, "Partial support was accepted")

        client.fixtureDisconnect()
        var modernReady = legacyReady
        modernReady["supported_commands"] = [
            "gripper_state", "gripper_calibrate", "gripper_control", "mode_query",
        ]
        try client.fixtureReceive(modernReady)
        expect(client.state == .ready, "Current gateway did not become ready")
        expect(client.gripperSnapshot(forArm: "left")["commandsAvailable"] as? Bool == true,
               "Current gripper support was not exposed")
        expect(client.controlGripper(forArm: "left", action: "hold", force: 10) == 0,
               "Capability advertisement bypassed calibration")
        let query = client.queryGripperState(forArm: "left")
        expect(query > 0, "Advertised state query was blocked")
        try client.fixtureReceive([
            "type": "gripper_state_ack", "command_id": query, "arm": "left",
            "accepted": true, "calibration_state": "required",
            "calibration_verified": false, "feedback_available": false,
            "command_in_flight": false, "force_min": 1, "force_max": 300,
            "force_unit": "vendor_intensity", "supported_actions": ["release", "hold"],
            "gateway_latency_ms": 1.0,
        ])
        expect(client.state == .ready, "Valid state acknowledgement closed the connection")
        expect(client.gripperSnapshot(forArm: "left")["commandInFlight"] as? Bool == false,
               "State query did not complete")

        // Capability and calibration claims never survive a reconnect.
        client.fixtureDisconnect()
        try client.fixtureReceive(legacyReady)
        expect(client.queryGripperState(forArm: "left") == 0, "Reconnect retained stale support")

        // Uncorrelated rejections remain fatal, but preserve their actual cause.
        try client.fixtureReceive([
            "type": "command_error", "accepted": false,
            "command_type": "gripper_state", "error": "unsupported message type",
        ])
        expect(client.state == .failed, "Generic rejection did not invalidate the session")
        expect(client.stateDetail == "Gateway rejected gripper_state: unsupported message type",
               "Generic rejection lost its type or reason")
        expect(client.telemetry(forArm: "right") == nil, "Failure retained telemetry")
        try client.fixtureReceive(legacyReady)
        try client.fixtureReceive(["type": "command_error", "error": "unsupported message type"])
        expect(client.stateDetail == "Gateway rejected command: unsupported message type",
               "Legacy uncorrelated rejection lost its reason")
        try client.fixtureReceive(legacyReady)
        try client.fixtureReceive(["type": "future_event"])
        expect(client.state == .failed, "Unknown message was silently ignored")
        expect(client.stateDetail.contains("future_event"), "Unknown type was hidden")
        print("Amber gateway compatibility fixtures passed")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="rob-amber-compatibility-") as folder:
        source = Path(folder) / "GatewayFixtures.swift"
        binary = Path(folder) / "gateway-fixtures"
        source.write_text(
            (ROOT / "Cerebro/ROBAmberGatewayClient.swift").read_text() + FIXTURES
        )
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(Path(folder) / "module-cache"),
            str(source), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
