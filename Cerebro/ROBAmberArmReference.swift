//
//  ROBAmberArmReference.swift
//  Cerebro
//
//  Fail-closed, session-local mapping between Amber's boot-relative encoder
//  coordinates and the physical B1 URDF coordinates used by Cerebro.
//

import Foundation

struct ROBAmberArmReferenceReadiness {
    let isReady: Bool
    let detail: String
    let maximumVisualErrorRadians: Double?
    let observedJointCount: Int
}

struct ROBAmberVendorTargetSnapshot {
    let positionsRadians: [Double]
    let gatewaySessionGeneration: UInt64
}

private struct ROBAmberArmParkCalibration: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let arm: String
    let parkModelRadians: [Double]
    let direction: [Int]
    let maximumVisualErrorRadians: Double
    let commissionedAt: Date

    var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && ["left", "right"].contains(arm)
            && parkModelRadians.count == ROBAmberB1Kinematics.joints.count
            && direction.count == ROBAmberB1Kinematics.joints.count
            && direction.allSatisfy { $0 == -1 || $0 == 1 }
            && zip(parkModelRadians, ROBAmberB1Kinematics.joints).allSatisfy {
                $0.0.isFinite && ($0.1.lowerLimit ... $0.1.upperLimit).contains($0.0)
            }
            && maximumVisualErrorRadians.isFinite
            && (0.035 ... 0.35).contains(maximumVisualErrorRadians)
    }
}

private struct ROBAmberArmReferenceSession {
    let calibrationID: UUID
    let gatewaySessionGeneration: UInt64
    let vendorAtModelZeroRadians: [Double]
    let capturedTelemetrySequence: UInt64
    let establishedAt: Date
}

enum ROBAmberArmReferenceError: LocalizedError {
    case invalidArm
    case invalidCalibration
    case missingCalibration
    case gatewayUnavailable
    case telemetryUnavailable
    case armMoving
    case modeUnavailable
    case operatorConfirmationRequired
    case visualReferenceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidArm:
            return "Choose the left or right Amber arm."
        case .invalidCalibration:
            return "Enter seven finite park angles inside the B1 URDF limits, seven direction signs (+1 or -1), and a visual limit from 0.035 to 0.35 radians."
        case .missingCalibration:
            return "Commission this arm's physical park pose before establishing a session reference."
        case .gatewayUnavailable:
            return "The authenticated exclusive Amber gateway session is not ready."
        case .telemetryUnavailable:
            return "A fresh, finite seven-joint Amber telemetry sample is required."
        case .armMoving:
            return "The arm is moving. Seat and support it in the commissioned park fixture and wait for all joints to stop."
        case .modeUnavailable:
            return "The seven actuator modes must be verified and uniformly inactive or position-controlled."
        case .operatorConfirmationRequired:
            return "The local operator must explicitly confirm that the arm is seated in its commissioned park fixture."
        case .visualReferenceUnavailable(let detail):
            return detail
        }
    }
}

/// Park geometry is persistent, but the derived encoder offset is deliberately
/// memory-only and bound to one authenticated gateway session. Reconnect,
/// relaunch, missing camera evidence, stale telemetry, or a calibration edit
/// therefore closes the gate.
final class ROBAmberArmReferenceStore {
    static let shared = ROBAmberArmReferenceStore()

    static let visualSource = "amber-b1-urdf-oak-d-reverse-pose"
    static let maximumTelemetryAgeMilliseconds = 250.0
    static let maximumReferenceVelocityRadiansPerSecond = 0.05
    static let defaultMaximumVisualErrorRadians = 0.20

    private static let defaultsPrefix = "ROBAmberArmParkCalibration.v1."
    private let lock = NSLock()
    private var sessions: [String: ROBAmberArmReferenceSession] = [:]

    private init() {}

    func calibrationSnapshot(forArm arm: String) -> (
        parkModelRadians: [Double], direction: [Int], maximumVisualErrorRadians: Double
    )? {
        guard let calibration = calibration(forArm: arm) else { return nil }
        return (
            calibration.parkModelRadians,
            calibration.direction,
            calibration.maximumVisualErrorRadians
        )
    }

    func commission(
        arm proposedArm: String,
        parkModelRadians: [Double],
        direction: [Int],
        maximumVisualErrorRadians: Double = defaultMaximumVisualErrorRadians
    ) throws {
        let arm = proposedArm.lowercased()
        guard ["left", "right"].contains(arm) else {
            throw ROBAmberArmReferenceError.invalidArm
        }
        let calibration = ROBAmberArmParkCalibration(
            schemaVersion: ROBAmberArmParkCalibration.schemaVersion,
            id: UUID(),
            arm: arm,
            parkModelRadians: parkModelRadians,
            direction: direction,
            maximumVisualErrorRadians: maximumVisualErrorRadians,
            commissionedAt: Date()
        )
        guard calibration.isValid,
              let data = try? JSONEncoder().encode(calibration) else {
            throw ROBAmberArmReferenceError.invalidCalibration
        }
        UserDefaults.standard.set(data, forKey: Self.defaultsPrefix + arm)
        lock.lock()
        sessions.removeValue(forKey: arm)
        lock.unlock()
        notifyChanged()
    }

    /// Reads telemetry and vision only. The caller owns the critical local
    /// confirmation UI; this method never commands, activates, or holds an arm.
    func establishSessionReference(
        forArm proposedArm: String,
        operatorConfirmedPark: Bool
    ) throws {
        let arm = proposedArm.lowercased()
        guard ["left", "right"].contains(arm) else {
            throw ROBAmberArmReferenceError.invalidArm
        }
        guard operatorConfirmedPark else {
            throw ROBAmberArmReferenceError.operatorConfirmationRequired
        }
        guard let calibration = calibration(forArm: arm) else {
            throw ROBAmberArmReferenceError.missingCalibration
        }
        let gateway = ROBAmberGatewayClient.shared
        guard let generation = readyGatewayGeneration(gateway) else {
            throw ROBAmberArmReferenceError.gatewayUnavailable
        }
        guard let telemetry = validTelemetry(forArm: arm, gateway: gateway) else {
            throw ROBAmberArmReferenceError.telemetryUnavailable
        }
        let velocities = telemetry.velocitiesRadiansPerSecond.map { abs($0.doubleValue) }
        guard velocities.allSatisfy({ $0 <= Self.maximumReferenceVelocityRadiansPerSecond }) else {
            throw ROBAmberArmReferenceError.armMoving
        }
        let modes = gateway.modes(forArm: arm).map(\.intValue)
        guard modes.count == ROBAmberB1Kinematics.joints.count,
              Set(modes).count == 1,
              modes.allSatisfy({ $0 == 0 || $0 == 2 }) else {
            throw ROBAmberArmReferenceError.modeUnavailable
        }
        let visual = try visualAgreement(
            forArm: arm,
            expectedModelRadians: calibration.parkModelRadians,
            maximumErrorRadians: calibration.maximumVisualErrorRadians
        )
        guard visual.observedJointCount >= 3 else {
            throw ROBAmberArmReferenceError.visualReferenceUnavailable(
                "At least three deterministic camera-observed joint angles are required for the \(arm) arm."
            )
        }

        let vendor = telemetry.positionsRadians.map(\.doubleValue)
        guard let vendorAtModelZero = ROBAmberArmReferenceTransform.vendorAtModelZero(
            vendorAtPark: vendor,
            modelAtPark: calibration.parkModelRadians,
            directions: calibration.direction
        ), vendorAtModelZero.count == ROBAmberB1Kinematics.joints.count else {
            throw ROBAmberArmReferenceError.telemetryUnavailable
        }
        let session = ROBAmberArmReferenceSession(
            calibrationID: calibration.id,
            gatewaySessionGeneration: generation,
            vendorAtModelZeroRadians: vendorAtModelZero,
            capturedTelemetrySequence: telemetry.sequence,
            establishedAt: Date()
        )
        lock.lock()
        sessions[arm] = session
        lock.unlock()
        notifyChanged()
    }

    func readiness(forArm proposedArm: String) -> ROBAmberArmReferenceReadiness {
        let arm = proposedArm.lowercased()
        guard ["left", "right"].contains(arm) else {
            return blocked("Invalid Amber arm.")
        }
        guard let calibration = calibration(forArm: arm) else {
            return blocked("The \(arm) physical park pose has not been commissioned.")
        }
        guard let session = session(forArm: arm) else {
            return blocked("The \(arm) arm has no reference for this controller session.")
        }
        guard session.calibrationID == calibration.id else {
            return blocked("The \(arm) park calibration changed after the session reference was recorded.")
        }
        let gateway = ROBAmberGatewayClient.shared
        guard let generation = readyGatewayGeneration(gateway),
              generation == session.gatewaySessionGeneration else {
            return blocked("The \(arm) reference belongs to an earlier Amber gateway session.")
        }
        guard let telemetry = validTelemetry(forArm: arm, gateway: gateway),
              telemetry.sequence >= session.capturedTelemetrySequence else {
            return blocked("The \(arm) arm does not have fresh telemetry from the referenced session.")
        }
        guard let model = modelPositions(
            fromVendor: telemetry.positionsRadians.map(\.doubleValue),
            calibration: calibration,
            session: session
        ), modelPositionsAreInsideLimits(model) else {
            return blocked("The mapped \(arm) pose is outside the commissioned B1 model limits.")
        }
        do {
            let visual = try visualAgreement(
                forArm: arm,
                expectedModelRadians: model,
                maximumErrorRadians: calibration.maximumVisualErrorRadians
            )
            return ROBAmberArmReferenceReadiness(
                isReady: true,
                detail: String(
                    format: "%@ session reference verified with %d camera-observed joints (maximum error %.3f rad).",
                    arm.capitalized,
                    visual.observedJointCount,
                    visual.maximumErrorRadians
                ),
                maximumVisualErrorRadians: visual.maximumErrorRadians,
                observedJointCount: visual.observedJointCount
            )
        } catch {
            return blocked(error.localizedDescription)
        }
    }

    /// Converts only when the calibration and memory-only session still match
    /// the active authenticated connection. Camera agreement is checked by the
    /// caller's reference gate before dispatch and during supervision.
    func modelPositions(fromVendor vendor: [Double], forArm arm: String) -> [Double]? {
        guard let calibration = calibration(forArm: arm),
              let session = activeSession(forArm: arm, calibration: calibration) else {
            return nil
        }
        return modelPositions(fromVendor: vendor, calibration: calibration, session: session)
    }

    func vendorTargetSnapshot(
        fromModel model: [Double],
        forArm arm: String
    ) -> ROBAmberVendorTargetSnapshot? {
        guard modelPositionsAreInsideLimits(model),
              let calibration = calibration(forArm: arm),
              let session = activeSession(forArm: arm, calibration: calibration),
              model.count == calibration.direction.count,
              session.vendorAtModelZeroRadians.count == model.count else {
            return nil
        }
        guard let positions = ROBAmberArmReferenceTransform.vendorPositions(
            fromModel: model,
            vendorAtModelZero: session.vendorAtModelZeroRadians,
            directions: calibration.direction
        ) else { return nil }
        return ROBAmberVendorTargetSnapshot(
            positionsRadians: positions,
            gatewaySessionGeneration: session.gatewaySessionGeneration
        )
    }

    func modelVelocities(fromVendor vendor: [Double], forArm arm: String) -> [Double]? {
        guard let calibration = calibration(forArm: arm),
              activeSession(forArm: arm, calibration: calibration) != nil,
              vendor.count == calibration.direction.count,
              vendor.allSatisfy(\.isFinite) else { return nil }
        return zip(vendor, calibration.direction).map {
            Double($0.1) * $0.0
        }
    }

    private func calibration(forArm proposedArm: String) -> ROBAmberArmParkCalibration? {
        let arm = proposedArm.lowercased()
        guard ["left", "right"].contains(arm),
              let data = UserDefaults.standard.data(forKey: Self.defaultsPrefix + arm),
              let value = try? JSONDecoder().decode(ROBAmberArmParkCalibration.self, from: data),
              value.isValid,
              value.arm == arm else { return nil }
        return value
    }

    private func session(forArm arm: String) -> ROBAmberArmReferenceSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[arm.lowercased()]
    }

    private func activeSession(
        forArm arm: String,
        calibration: ROBAmberArmParkCalibration
    ) -> ROBAmberArmReferenceSession? {
        guard let session = session(forArm: arm),
              session.calibrationID == calibration.id,
              let generation = readyGatewayGeneration(ROBAmberGatewayClient.shared),
              session.gatewaySessionGeneration == generation else { return nil }
        return session
    }

    private func readyGatewayGeneration(_ gateway: ROBAmberGatewayClient) -> UInt64? {
        let snapshot = gateway.connectionSnapshot()
        let state = (snapshot["state"] as? NSNumber)?.intValue
            ?? (snapshot["state"] as? Int)
        let exclusive = (snapshot["exclusiveControllerSession"] as? NSNumber)?.boolValue
            ?? (snapshot["exclusiveControllerSession"] as? Bool)
            ?? false
        let generation = (snapshot["sessionGeneration"] as? NSNumber)?.uint64Value
            ?? (snapshot["sessionGeneration"] as? UInt64)
            ?? 0
        guard state == ROBAmberGatewayState.ready.rawValue,
              exclusive,
              generation > 0 else { return nil }
        return generation
    }

    private func validTelemetry(
        forArm arm: String,
        gateway: ROBAmberGatewayClient
    ) -> ROBAmberGatewayTelemetry? {
        guard let telemetry = gateway.telemetry(forArm: arm),
              telemetry.sequence > 0,
              telemetry.effectiveSampleAgeMilliseconds.isFinite,
              (0 ... Self.maximumTelemetryAgeMilliseconds).contains(
                telemetry.effectiveSampleAgeMilliseconds
              ),
              telemetry.positionsRadians.count == ROBAmberB1Kinematics.joints.count,
              telemetry.velocitiesRadiansPerSecond.count == ROBAmberB1Kinematics.joints.count,
              telemetry.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
              telemetry.velocitiesRadiansPerSecond.allSatisfy({ $0.doubleValue.isFinite }) else {
            return nil
        }
        return telemetry
    }

    private func modelPositions(
        fromVendor vendor: [Double],
        calibration: ROBAmberArmParkCalibration,
        session: ROBAmberArmReferenceSession
    ) -> [Double]? {
        guard vendor.count == calibration.direction.count,
              vendor.count == session.vendorAtModelZeroRadians.count,
              vendor.allSatisfy(\.isFinite) else { return nil }
        return ROBAmberArmReferenceTransform.modelPositions(
            fromVendor: vendor,
            vendorAtModelZero: session.vendorAtModelZeroRadians,
            directions: calibration.direction
        )
    }

    private func modelPositionsAreInsideLimits(_ positions: [Double]) -> Bool {
        positions.count == ROBAmberB1Kinematics.joints.count
            && zip(positions, ROBAmberB1Kinematics.joints).allSatisfy {
                $0.0.isFinite && ($0.1.lowerLimit ... $0.1.upperLimit).contains($0.0)
            }
    }

    private func visualAgreement(
        forArm arm: String,
        expectedModelRadians: [Double],
        maximumErrorRadians: Double
    ) throws -> (observedJointCount: Int, maximumErrorRadians: Double) {
        let calibration = ROBSceneSnapshotStore.shared.visualCalibrationSnapshot()
        guard calibration.producerFreshness.allRequiredProducersAreFresh() else {
            throw ROBAmberArmReferenceError.visualReferenceUnavailable(
                "The deterministic camera/reference producers are stale."
            )
        }
        let scene = calibration.scene
        guard scene.cameraQuality.state == "streamingRGBD",
              scene.cameraQuality.hasAlignedDepth,
              scene.cameraQuality.confidence.isFinite,
              scene.cameraQuality.confidence >= 0.5,
              let cameraPose = scene.cameraPose,
              cameraPose.anchorCount >= 4,
              cameraPose.confidence.isFinite,
              cameraPose.confidence >= 0.5,
              cameraPose.residualRMSEMeters.isFinite,
              cameraPose.residualRMSEMeters <= 0.05,
              cameraPose.translationMeters.count == 3,
              cameraPose.rotationQuaternion.count == 4,
              (cameraPose.translationMeters + cameraPose.rotationQuaternion)
                .allSatisfy(\.isFinite) else {
            throw ROBAmberArmReferenceError.visualReferenceUnavailable(
                "Aligned OAK-D depth and a deterministic four-anchor camera pose are required."
            )
        }
        let indexByJoint = Dictionary(
            uniqueKeysWithValues: ROBAmberB1Kinematics.joints.enumerated().map {
                ($0.element.name, $0.offset)
            }
        )
        var errorsByJoint: [Int: Double] = [:]
        for observation in scene.armPose {
            guard observation.arm.lowercased() == arm,
                  observation.source == Self.visualSource,
                  observation.confidence.isFinite,
                  observation.confidence >= 0.5,
                  let angle = observation.angleRadians,
                  angle.isFinite,
                  let index = indexByJoint[observation.joint],
                  expectedModelRadians.indices.contains(index) else { continue }
            let error = Self.angularDistance(angle, expectedModelRadians[index])
            errorsByJoint[index] = max(errorsByJoint[index] ?? 0, error)
        }
        let errors = Array(errorsByJoint.values)
        guard errors.count >= 3 else {
            throw ROBAmberArmReferenceError.visualReferenceUnavailable(
                "At least three deterministic camera-observed joint angles are required for the \(arm) arm."
            )
        }
        let largest = errors.max() ?? .infinity
        guard largest <= maximumErrorRadians else {
            throw ROBAmberArmReferenceError.visualReferenceUnavailable(String(
                format: "The %@ arm camera/model disagreement is %.3f rad; the commissioned limit is %.3f rad.",
                arm,
                largest,
                maximumErrorRadians
            ))
        }
        return (errors.count, largest)
    }

    private static func angularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(atan2(sin(lhs - rhs), cos(lhs - rhs)))
    }

    private func blocked(_ detail: String) -> ROBAmberArmReferenceReadiness {
        ROBAmberArmReferenceReadiness(
            isReady: false,
            detail: detail,
            maximumVisualErrorRadians: nil,
            observedJointCount: 0
        )
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ROBAmberArmReferenceDidChange,
                object: self
            )
        }
    }
}

extension Notification.Name {
    static let ROBAmberArmReferenceDidChange = Notification.Name(
        "ROBAmberArmReferenceDidChange"
    )
}
