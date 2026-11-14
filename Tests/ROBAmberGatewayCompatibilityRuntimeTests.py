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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        expect(client.fixtureSentTypes.filter { $0 == "mode_query" }.count == 2,
               "Reconnect must refresh both mode caches with read-only queries")
        expect(!client.fixtureSentTypes.contains("position_mode") && !client.fixtureSentTypes.contains("activate"),
               "Reconnect must never initialize torque or modes")
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
        expect(client.modes(forArm: "left").isEmpty, "Fixture must reproduce the empty post-relaunch mode cache")
        expect(client.enterPositionMode(forArm: "left") > 0 && client.fixtureSentTypes.last == "mode_query",
               "Fresh measured position hold must query mode instead of cycling ACTIVE/POSITION")
        let capturedMotorSample = client.telemetry(forArm: "left")!
        expect(capturedMotorSample.sampleAgeAtReceiptMilliseconds == 1,
               "Historical recording quality must retain the controller and individual-joint ages")
        Thread.sleep(forTimeInterval: 0.27)
        expect(capturedMotorSample.sampleAgeAtReceiptMilliseconds == 1
               && capturedMotorSample.effectiveSampleAgeMilliseconds > 250,
               "Reading historical packet quality must never freshen live motor feedback")
        expect(client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: 0)["allowed"] as? Bool == false,
               "Historical receipt age bypassed the live 250 ms motion limit")
        try client.fixtureReceive(motorSample)
        let admitted = client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: 0)
        expect(admitted["allowed"] as? Bool == true, "Fresh physical-right feedback was not admitted on L10")
        let admittedGeneration = (admitted["sessionGeneration"] as! NSNumber).uint64Value
        let owner = UUID()
        expect(ROBAmberArmMotionArbiter.shared.reserve(.right, owner: owner), "Fixture could not reserve the physical right arm")
        let manualHandoff = client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: admittedGeneration)
        expect(manualHandoff["allowed"] as? Bool == false && manualHandoff["waitingForOwner"] as? Bool == true,
               "Fresh local takeover did not distinguish an ownership handoff")
        var staleOwned = motorSample
        staleOwned["joint_feedback_age_ms"] = [Double](repeating: 1000, count: 7)
        try client.fixtureReceive(staleOwned)
        expect(client.manualArmControlReadiness(forUDPPort: 26001, expectedSessionGeneration: admittedGeneration)["waitingForOwner"] as? Bool == false,
               "Stale feedback was queued as an ownership handoff")
        ROBAmberArmMotionArbiter.shared.release(.right, owner: owner)
        try client.fixtureReceive(motorSample)
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

        // Explicit manual attempts are separately advertised, remain bounded,
        // and must not invent calibration acceptance from a successful grip.
        let existing = ROBAmberGatewayClient()
        defer { existing.fixtureDisconnect() }
        try existing.fixtureReceive(modernReady)
        expect(existing.controlGripperUsingExistingDeviceState(forArm: "left", action: "hold") == 0,
               "Old gateway gained an unadvertised device-state command")
        existing.fixtureDisconnect()
        var existingReady = modernReady
        existingReady["supported_commands"] = ["gripper_state", "gripper_calibrate", "gripper_control", "gripper_control_existing"]
        try existing.fixtureReceive(existingReady)
        expect(existing.controlGripperUsingExistingDeviceState(forArm: "left", action: "hold") == 0,
               "Unknown calibration attempt bypassed fresh position hold")
        func existingFeedback(mode: Double = 2, age: Double = 1) throws {
            try existing.fixtureReceive([
                "type": "telemetry", "arm": "left", "sequence": 1,
                "sample_age_ms": age, "controller_sample_age_ms": age,
                "joint_feedback_age_ms": [Double](repeating: age, count: 7),
                "gripper_feedback_age_ms": age,
                "positions_rad": [Double](repeating: 0.3, count: 7),
                "currents": [Double](repeating: 0, count: 7),
                "statuses": [Double](repeating: mode, count: 7),
                "velocities_available": false,
            ])
        }
        try existingFeedback(mode: 0)
        expect(existing.controlGripperUsingExistingDeviceState(forArm: "left", action: "hold") == 0,
               "Inactive arm admitted an existing-device attempt")
        try existingFeedback(age: 1500)
        expect(existing.controlGripperUsingExistingDeviceState(forArm: "left", action: "hold") == 0,
               "Stale feedback admitted an existing-device attempt")
        try existingFeedback()
        expect(existing.controlGripperUsingExistingDeviceState(forArm: "left", action: "hold", holdIntensity: 0) == 0,
               "Zero-intensity attempt was admitted")
        expect(existing.controlGripperUsingExistingDeviceState(forArm: "left", action: "hold", holdIntensity: 3) == 0,
               "Existing-device intensity escalated")
        for (action, force) in [("hold", 1), ("hold", 2), ("release", 10)] {
            let id = existing.controlGripperUsingExistingDeviceState(forArm: "left", action: action, holdIntensity: action == "hold" ? force : 1)
            expect(id > 0, "Explicit bounded attempt was rejected")
            try existing.fixtureReceive([
                "type": "gripper_control_existing_ack", "command_id": id, "arm": "left",
                "accepted": true, "amber_response": 1, "action": action, "force": force,
                "calibration_state": "required", "calibration_verified": false,
                "completion_verified": false, "feedback_available": false, "command_in_flight": false,
                "force_min": 1, "force_max": 300, "force_unit": "vendor_intensity",
                "supported_actions": ["release", "hold"], "gateway_latency_ms": 1.0,
            ])
            expect(existing.state == .ready, "Truthful unknown-calibration acknowledgement was rejected")
            expect(existing.gripperSnapshot(forArm: "left")["calibrationState"] as? String == "required",
                   "A grip attempt manufactured calibration acceptance")
        }
        expect(existing.controlGripper(forArm: "left", action: "hold", force: 20) == 0,
               "Explicit bounded attempt enabled ordinary uncalibrated force control")

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
        // Exercise the real taught-waypoint admission method. The older
        // coordinator is idle: an approved left-only executor must still reach
        // the gateway, without lending authority to the physical right arm.
        let taught = ROBAmberGatewayClient()
        defer { taught.fixtureDisconnect() }
        try taught.fixtureReceive(modernReady)
        let generation = (taught.connectionSnapshot()["sessionGeneration"] as! NSNumber).uint64Value
        func motorFeedback(age: Double = 1, positions: [Double] = [Double](repeating: 0, count: 7)) throws {
            for arm in ["left", "right"] {
                try taught.fixtureReceive([
                    "type": "telemetry", "arm": arm, "sequence": 100,
                    "sample_age_ms": age, "controller_sample_age_ms": age,
                    "joint_feedback_age_ms": [Double](repeating: age, count: 7),
                    "gripper_feedback_age_ms": age,
                    "positions_rad": positions,
                    "velocities_rad_s": NSNull(), "velocities_available": false,
                    "currents": [Double](repeating: 0.2, count: 7),
                    "statuses": [Double](repeating: 2, count: 7),
                ])
                try taught.fixtureReceive([
                    "type": "mode_query_ack", "arm": arm, "command_id": 500,
                    "accepted": true, "modes": [Int](repeating: 2, count: 7),
                ])
            }
        }
        func waypoint(_ arm: String = "right", _ index: Int = 1, _ duration: Double = 4,
                      _ expectedGeneration: UInt64? = nil) -> UInt64 {
            taught.sendRoutineWaypoint(arm: arm, index: index, duration: duration,
                expectedSessionGeneration: expectedGeneration ?? generation)
        }
        try motorFeedback()
        let trial = ROBLeftArmTrial.shared
        trial.generation = generation
        expect(waypoint() == 0, "Idle or unapproved left trial admitted a waypoint")
        trial.approved = true
        expect(waypoint() > 0, "Approved left trial was rejected because the paired coordinator is idle")
        expect(waypoint("left") == 0, "Left-only approval authorized the physical right arm")
        expect(waypoint("right", 2) == 0, "Left trial bypassed adjacent-waypoint bounds")
        expect(waypoint("right", 1, 0.5) == 0, "Left trial bypassed the approach timing bound")
        expect(waypoint("right", 1, 4, generation + 1) == 0, "Left trial replayed across sessions")
        expect(waypoint("right", 7) == 0, "Front extension admitted directly from hanging")
        try motorFeedback(positions: ROBLeftArmInteractionPlan.target(index: 6)!)
        expect(waypoint("right", 7) > 0, "Approved front-only J3 step refused")
        expect(waypoint("right", 9) > 0, "Straight J3 increments could not be joined")
        let plan = ROBLeftArmInteractionPlan.self
        let zero = [Double](repeating: 0, count: 7)
        let smoothHandoff = plan.executionRoute(from: zero, hanging: false)!
        expect(smoothHandoff == [1, 4, 6, 18, 28], "Coordinated handoff did not retain its five fixed legs")
        expect(plan.compactRoute(from: zero, indices: smoothHandoff) == smoothHandoff,
               "Coordinated handoff lost a registered corner")
        let smoothWave = plan.executionRoute(from: zero, hanging: false, waving: true)! + [43, 42, 43, 42]
        expect(smoothWave == [1, 4, 6, 18, 28, 34, 42, 43, 42, 43, 42],
               "Coordinated wave did not retain all eleven legs and reversals")
        expect(plan.compactRoute(from: zero, indices: smoothWave) == smoothWave,
               "Coordinated wave compaction removed a corner or reversal")
        expect(plan.executionRoute(from: plan.target(index: 28)!, hanging: true) == [18, 6, 4, 1, 0],
               "Coordinated return did not reverse the same fixed corridor")
        let handoff = Array(1 ... plan.frontIndex)
        expect(plan.compactRoute(from: zero, indices: handoff) == [1, 4, 6, 9, 12, 15, 18, 24, 28],
               "Handoff compaction removed a corner or retained artificial stops")
        let fullWave = Array(1 ... plan.waveRestIndex) + [plan.waveIndex, plan.waveRestIndex, plan.waveIndex, plan.waveRestIndex]
        expect(plan.compactRoute(from: zero, indices: fullWave) == [1, 4, 6, 9, 12, 15, 18, 24, 28, 34, 42, 43, 42, 43, 42],
               "Wave compaction removed a corner or reversal")
        let oldStart = plan.target(index: 9)!
        expect(plan.executionRoute(from: oldStart, hanging: false) == plan.route(from: oldStart, hanging: false),
               "A stopped legacy pose did not fall back to its original corridor")
        expect(plan.compactRoute(from: oldStart, indices: plan.executionRoute(from: oldStart, hanging: false)!) == [12, 15, 18, 24, 28],
               "Legacy fallback lost one of its original path corners")
        expect(plan.compactRoute(from: plan.target(index: 6)!, indices: [12]) == nil,
               "Compaction accepted a route that skipped a canonical corner")
        var one = zero; one[0] = 1
        var two = zero; two[0] = 2
        expect(ROBArmRoutinePlan.compactTargetIndices(baseline: zero, targets: [zero, one, one, two, one, zero]) == [3, 5],
               "Shared compaction mishandled duplicates or discarded a reversal")
        // Long segments follow exactly the same forward or reverse canonical
        // leg: approach, J3, J5, J6, J2 and the coordinated J2/J4 raise.
        for (a, b) in [(1, 4), (4, 6), (6, 9), (9, 12), (12, 15), (15, 18), (18, 24), (24, 28), (28, 34), (34, 42), (6, 18), (18, 28)] {
            for (start, end) in [(a, b), (b, a)] {
                let q = plan.target(index: start)!
                try motorFeedback(positions: q)
                expect(waypoint("right", end) > 0, "Known straight leg \(start)->\(end) was refused")
                expect(waypoint("left", end) == 0, "Joined leg borrowed authority for the physical right arm")
                expect(waypoint("right", end, 4, generation + 1) == 0, "Joined leg replayed across gateway sessions")
            }
        }
        var noisyStart = zip(plan.target(index: 7)!, plan.target(index: 8)!).map { ($0 + $1) / 2 }
        noisyStart[6] = 0.005
        try motorFeedback(positions: noisyStart)
        expect(waypoint("right", 9) > 0, "Existing corridor tolerance no longer permits normal feedback noise")
        expect(waypoint("right", 6) > 0, "Reverse straight leg from measured mid-segment was refused")
        noisyStart[6] = ROBArmRoutinePlan.tolerance + 0.001
        try motorFeedback(positions: noisyStart)
        expect(waypoint("right", 9) == 0, "Joined leg widened the known corridor tolerance")
        for (a, b, after, before) in [(6, 18, [18, 28], [6, 4, 1, 0]), (18, 28, [28], [18, 6, 4, 1, 0])] {
            var middle = zip(plan.target(index: a)!, plan.target(index: b)!).map { $0 + 0.4 * ($1 - $0) }
            middle[6] = 0.005
            expect(plan.progress(middle) == nil, "Smooth midpoint unexpectedly changed legacy progress semantics")
            expect(plan.executionRoute(from: middle, hanging: false) == after,
                   "Measured smooth midpoint did not continue through its next registered corner")
            expect(plan.executionRoute(from: middle, hanging: true) == before,
                   "Measured smooth midpoint did not reverse through its previous registered corner")
            expect(plan.compactRoute(from: middle, indices: after) == after,
                   "Compaction rejected a measured smooth midpoint")
            try motorFeedback(positions: middle)
            expect(waypoint("right", a) > 0 && waypoint("right", b) > 0,
                   "Same-leg forward/reverse move from a smooth midpoint was refused")
            expect(waypoint("right", a == 6 ? 28 : 6) == 0,
                   "Smooth midpoint skipped its adjacent registered corner")
            middle[6] = ROBArmRoutinePlan.tolerance + 0.001
            expect(plan.executionRoute(from: middle, hanging: false) == nil,
                   "Smooth execution route widened its corridor tolerance")
            try motorFeedback(positions: middle)
            expect(waypoint("right", b) == 0, "Smooth midpoint bypassed the original corridor tolerance")
        }
        // A chord through a corner would alter the taught swept path, even
        // when its endpoints are individually valid canonical waypoints.
        for (start, end) in [(0, 6), (6, 12), (9, 15), (6, 28), (28, 6), (18, 34), (34, 18), (28, 42), (42, 28), (34, 43), (43, 34), (24, 5)] {
            try motorFeedback(positions: plan.target(index: start)!)
            expect(waypoint("right", end) == 0, "Joined leg crossed a corner or skipped unwind: \(start)->\(end)")
        }
        trial.approved = false
        ROBArmRoutineCoordinator.shared.isRunning = true
        try motorFeedback(positions: plan.target(index: 1)!)
        expect(waypoint("right", 3) == 0, "Paired routine lost its original adjacent-waypoint bound")
        ROBArmRoutineCoordinator.shared.isRunning = false
        trial.approved = true
        expect(waypoint("right", 3) > 0, "Left trial did not admit the same straight approach leg")
        // The planner's shortest segment must survive the real transport's
        // duration floor, including a small raised J5 step.
        let j5From = ROBLeftArmInteractionPlan.target(index: 34)!
        let j5To = ROBLeftArmInteractionPlan.target(index: 35)!
        try motorFeedback(positions: j5From)
        let shortSegment = ROBLeftArmInteractionPlan.duration(from: j5From, to: j5To)!
        expect(waypoint("right", 35, shortSegment) > 0, "Planner generated a duration refused by its transport")
        try motorFeedback(positions: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveRestIndex)!)
        expect(waypoint("right", ROBLeftArmInteractionPlan.waveIndex) > 0, "Approved wave refused at new front pose")
        expect(waypoint("right", ROBLeftArmInteractionPlan.waveIndex, 0.7) > 0, "Approved front wave refused its reviewed faster timing")
        expect(waypoint("right", ROBLeftArmInteractionPlan.waveIndex, 0.3) == 0, "Faster wave bypassed its new timing bound")
        expect(waypoint("right", 5) == 0, "Lowering admitted before J3/J5 unwind")
        expect(waypoint("left", ROBLeftArmInteractionPlan.waveIndex) == 0, "New front pose sent to physical right arm")
        trial.approved = false
        expect(waypoint("right", ROBLeftArmInteractionPlan.waveIndex) == 0, "Revoked approval retained new-pose authority")
        ROBArmRoutineCoordinator.shared.isRunning = true
        expect(waypoint("right", ROBLeftArmInteractionPlan.waveIndex) == 0, "Paired legacy routine acquired new extension angles")
        ROBArmRoutineCoordinator.shared.isRunning = false
        trial.approved = true
        try motorFeedback()
        let ghostID = UUID()
        trial.ghostID = ghostID; trial.ghostTarget = [0, 0.10, 0, 0, 0, 0, 0]
        func ghost(_ id: UUID? = nil, _ index: Int = 0, _ seconds: Double = 3.2, _ session: UInt64? = nil) -> UInt64 {
            taught.sendApprovedLeftGestureStep(proposalID: id ?? ghostID, index: index, duration: seconds,
                expectedSessionGeneration: session ?? generation)
        }
        expect(ghost() > 0, "Frozen left gesture step was refused")
        expect(ghost(UUID()) == 0, "Wrong proposal ID admitted a ghost step")
        expect(ghost(ghostID, 1) == 0, "A future ghost step was admitted")
        expect(ghost(ghostID, 0, 3.3) == 0, "Changed ghost timing was admitted")
        expect(ghost(ghostID, 0, 3.2, generation + 1) == 0, "Ghost replayed across gateway sessions")
        trial.approved = false
        expect(ghost() == 0, "Unapproved ghost path retained authority")
        trial.approved = true
        try motorFeedback(age: 500)
        expect(ghost() == 0, "Ghost step bypassed stale feedback")
        expect(waypoint() == 0, "Left trial bypassed fresh motor feedback")
        try motorFeedback(age: 500, positions: plan.target(index: 18)!)
        expect(waypoint("right", 24) == 0, "Joined leg bypassed fresh motor feedback")
        expect(waypoint("right", 28) == 0, "Smooth leg bypassed fresh motor feedback")
        try motorFeedback()
        trial.approved = false
        expect(waypoint() == 0, "Revoked trial could still dispatch")
        // The selected physical-right proposal reaches gateway left, but
        // cannot borrow the legacy physical-left taught waypoint adapter.
        trial.physicalSide = "right"; trial.approved = true
        trial.ghostTarget = [0,-0.039,0,0,0,0,0]
        try motorFeedback()
        expect(ghost() > 0, "A physical-right immutable proposal did not reach its selected gateway arm")
        expect(waypoint("left") == 0, "A right task borrowed the legacy left-only taught corridor")
        expect(waypoint("right") == 0, "A right task admitted a waypoint on the other physical arm")
        UserDefaults.standard.setVolatileDomain(["ROBDevelopmentMode":true],forName:UserDefaults.argumentDomain)
        #if DEBUG
        expect(ROBArmFeedbackTiming.maximumAgeMilliseconds == 1200, "Development Mode did not select1200ms")
        for age in [262.0,398.0,500.0,512.0,900.0,1190.0] {
            try motorFeedback(age: age)
            expect(ghost() > 0, "Native ghost dispatch retained an old250ms feedback blocker")
        }
        try motorFeedback(age: 1201)
        expect(ghost() == 0, "Debug dispatch accepted feedback older than1200ms")
        try motorFeedback(age: 398)
        trial.approved = false
        expect(ghost() == 0, "Debug feedback timing bypassed task authorization")
        trial.approved = true
        #else
        expect(ROBArmFeedbackTiming.maximumAgeMilliseconds == 250, "Release adopted debug timing")
        try motorFeedback(age: 398)
        expect(ghost() == 0, "Release ghost dispatch exceeded250ms")
        #endif
        UserDefaults.standard.setVolatileDomain(["ROBDevelopmentMode":false],forName:UserDefaults.argumentDomain)
        try motorFeedback(age: 398)
        expect(ghost() == 0, "Disabling Development Mode retained1200ms dispatch")
        UserDefaults.standard.removeVolatileDomain(forName:UserDefaults.argumentDomain)
        print("Shared feedback policy: actual native ghost dispatch accepts262/398/500/512/900/1190ms only in DEBUG Development Mode;1201ms and revoked authority reject; mode-off and Release unchanged")
        trial.approved = false
        expect(ghost() == 0, "A revoked physical-right proposal retained transport authority")
        trial.physicalSide = "left"
        print("Taught-waypoint admission: fixed five-leg handoff/eleven-leg wave, smooth midpoint recovery and legacy fallback retain corners, reversals, tolerance, timing, side, session and freshness bounds; paired adjacency unchanged")
        let animation = ROBAnimationPlayback.shared
        animation.expectedGeneration = generation; animation.expectedArm = "left"
        try motorFeedback()
        expect(taught.sendLocalAnimationStep(arm: "left", expectedSessionGeneration: generation) == 0,
            "Animation target without a local run was admitted")
        animation.step = ([0,0.05,0,0,0,0,0], 1)
        expect(taught.localAnimationStepRejection(arm: "left", expectedSessionGeneration: generation) == nil,
            "Paired read-only preflight rejected a valid local segment")
        expect(taught.sendLocalAnimationStep(arm: "left", expectedSessionGeneration: generation) > 0,
            "Valid frozen local animation segment was rejected")
        expect(taught.sendLocalAnimationStep(arm: "right", expectedSessionGeneration: generation) == 0,
            "Animation admitted the wrong physical arm")
        expect(taught.sendLocalAnimationStep(arm: "left", expectedSessionGeneration: generation+1) == 0,
            "Animation target replayed after reconnect")
        animation.step = ([0,1,0,0,0,0,0], 1)
        expect(taught.sendLocalAnimationStep(arm: "left", expectedSessionGeneration: generation) == 0,
            "Animation exceeded existing transport rate")
        expect(taught.animationStepRejection?.contains("Right arm J2") == true && taught.animationStepRejection?.contains("scheduled") == true,
            "Animation rate rejection must identify the physical arm, joint and required timing")
        animation.step = ([0,0.05,0,0,0,0,0], 0.4)
        expect(taught.sendLocalAnimationStep(arm: "left", expectedSessionGeneration: generation) == 0 && taught.animationStepRejection?.contains("duration bounds") == true,
            "Short animation segment needs a specific duration rejection")
        animation.step = ([0,3,0,0,0,0,0], 10)
        expect(taught.sendLocalAnimationStep(arm: "left", expectedSessionGeneration: generation) == 0 && taught.animationStepRejection?.contains("joint or duration bounds") == true,
            "Joint bounds must reject before any paired animation dispatch")
        animation.step = ([0,0.05,0,0,0,0,0], 1)
        try motorFeedback(age: 501)
        expect(taught.sendLocalAnimationStep(arm: "left", expectedSessionGeneration: generation) == 0,
            "Animation admitted expired telemetry")
        expect(taught.animationStepRejection?.contains("feedback expired") == true && taught.animationStepRejection?.contains("motors") == true,
            "Feedback rejection must report its real cause and measured ages, not suggest transition edits")
        try motorFeedback()
        expect(taught.sendLocalAnimationStep(arm: "left", expectedSessionGeneration: generation) > 0 && taught.animationStepRejection == nil,
            "A previous rejection must not latch or contaminate the next valid local dispatch")
        animation.step = nil
        print("Animation gateway: frozen owner segment, physical arm, reconnect, rate and freshness checks passed")
        print("Amber gateway compatibility fixtures passed")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="rob-amber-compatibility-") as folder:
        source = Path(folder) / "GatewayFixtures.swift"
        binary = Path(folder) / "gateway-fixtures"
        source.write_text(
            (ROOT / "Cerebro/ROBArmJointLimits.swift").read_text()
            + (ROOT / "Cerebro/ROBAmberGatewayClient.swift").read_text().replace(
                "    private func send(_ message: ROBAmberGatewayMessage) {",
                "    fileprivate var fixtureSentTypes: [String] = []\n"
                "    private func send(_ message: ROBAmberGatewayMessage) {\n"
                "        fixtureSentTypes.append(message.type)")
            + (ROOT / "Cerebro/ROBArmRoutinePlan.swift").read_text()
            + (ROOT / "Tests/ROBArmRoutineGatewayFixtureSupport.swift").read_text() + FIXTURES
        )
        for flags in [[], ["-D", "DEBUG"]]:
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *flags,
                "-module-cache-path", str(Path(folder) / "module-cache"),
                str(source), "-o", str(binary),
            ], check=True)
            subprocess.run([str(binary)], check=True, timeout=15)



if __name__ == "__main__":
    main()
