//
//  ROBAmberB1Kinematics.swift
//  Cerebro
//
//  Kinematic constants transcribed from Amber URDF/amber_b1.urdf. Distances
//  are meters and angles are radians. The URDF remains the source of truth.
//

import Foundation
import simd

struct ROBAmberJointDefinition: Sendable {
    let name: String
    let parentLink: String
    let childLink: String
    let originXYZ: SIMD3<Double>
    let originRPY: SIMD3<Double>
    let axis: SIMD3<Double>
    let lowerLimit: Double
    let upperLimit: Double
}

struct ROBAmberArmMount: Codable, Sendable {
    let translationMeters: [Double]
    let rotationRPYRadians: [Double]

    var isValid: Bool {
        translationMeters.count == 3 && rotationRPYRadians.count == 3
            && (translationMeters + rotationRPYRadians).allSatisfy(\.isFinite)
    }

    var transform: simd_double4x4 {
        let translation = SIMD3(translationMeters[0], translationMeters[1], translationMeters[2])
        let rpy = SIMD3(rotationRPYRadians[0], rotationRPYRadians[1], rotationRPYRadians[2])
        return ROBAmberB1Kinematics.transform(xyz: translation, rpy: rpy)
    }
}

enum ROBAmberB1Kinematics {
    struct FitResult {
        let angles: [Double]
        let residualRMSEMeters: Double
        let observableJointCount: Int
    }
    static let joints: [ROBAmberJointDefinition] = [
        .init(name: "joint1", parentLink: "base_link", childLink: "one_Link",
              originXYZ: SIMD3(0, 0, 0.0825), originRPY: .zero, axis: SIMD3(0, 0, 1),
              lowerLimit: -2.4435, upperLimit: 2.4435),
        .init(name: "joint2", parentLink: "one_Link", childLink: "two_Link",
              originXYZ: SIMD3(0, 0, 0.0853000000000001), originRPY: SIMD3(-Double.pi / 2, 0, 0), axis: SIMD3(0, 0, 1),
              lowerLimit: -2.3213, upperLimit: 2.3213),
        .init(name: "joint3", parentLink: "two_Link", childLink: "three_Link",
              originXYZ: SIMD3(0, -0.1289, 0), originRPY: SIMD3(1.5708, 0, 0), axis: SIMD3(0, 0, 1),
              lowerLimit: -2.2863, upperLimit: 2.2863),
        .init(name: "joint4", parentLink: "three_Link", childLink: "four_Link",
              originXYZ: SIMD3(0, 0, 0.0853), originRPY: SIMD3(1.5708, 0, 0), axis: SIMD3(0, 0, 1),
              lowerLimit: -2.2863, upperLimit: 2.2863),
        .init(name: "joint5", parentLink: "four_Link", childLink: "five_Link",
              originXYZ: SIMD3(0, 0.1251, 0), originRPY: SIMD3(-1.5708, 0, 0), axis: SIMD3(0, 0, 1),
              lowerLimit: -2.2863, upperLimit: 2.2863),
        .init(name: "joint6", parentLink: "five_Link", childLink: "six_Link",
              originXYZ: SIMD3(0, 0, 0.0891), originRPY: SIMD3(-1.5708, 0, 0), axis: SIMD3(0, 0, 1),
              lowerLimit: -2.2863, upperLimit: 2.2863),
        .init(name: "joint7", parentLink: "six_Link", childLink: "seven_Link",
              originXYZ: SIMD3(0, -0.1591, 0), originRPY: SIMD3(1.5708, 0, 0), axis: SIMD3(0, 0, 1),
              lowerLimit: -3.05, upperLimit: 3.05)
    ]

    static func jointOriginsInRobot(
        angles: [Double],
        mount: ROBAmberArmMount
    ) -> [SIMD3<Double>]? {
        guard angles.count == joints.count, mount.isValid else { return nil }
        var parent = mount.transform
        var result: [SIMD3<Double>] = []
        for (definition, requestedAngle) in zip(joints, angles) {
            let angle = min(definition.upperLimit, max(definition.lowerLimit, requestedAngle))
            let jointFrame = parent * transform(xyz: definition.originXYZ, rpy: definition.originRPY)
            result.append(SIMD3(jointFrame.columns.3.x, jointFrame.columns.3.y, jointFrame.columns.3.z))
            parent = jointFrame * axisAngle(axis: definition.axis, angle: angle)
        }
        return result
    }

    /// Fits joint values to observed joint-center positions. A joint-center
    /// marker constrains only joints before it in the chain, so the final
    /// wrist rotation is intentionally reported as unobservable.
    static func fitJointAngles(
        observedJointOrigins: [Int: SIMD3<Double>],
        mount: ROBAmberArmMount,
        initialAngles: [Double]? = nil
    ) -> FitResult? {
        let observations = observedJointOrigins.filter { joints.indices.contains($0.key) }
        guard observations.count >= 3 else { return nil }
        var angles = initialAngles?.count == joints.count
            ? initialAngles! : Array(repeating: 0, count: joints.count)
        for index in joints.indices {
            angles[index] = min(joints[index].upperLimit, max(joints[index].lowerLimit, angles[index]))
        }
        let highestObserved = observations.keys.max() ?? 0
        let observableCount = min(joints.count - 1, highestObserved)
        guard observableCount > 0 else { return nil }

        func cost(_ candidate: [Double]) -> Double {
            guard let predicted = jointOriginsInRobot(angles: candidate, mount: mount) else {
                return .infinity
            }
            return observations.reduce(0) { partial, observation in
                partial + simd_length_squared(predicted[observation.key] - observation.value)
            } / Double(observations.count)
        }

        var bestCost = cost(angles)
        var step = 0.4
        for _ in 0..<45 {
            var improved = false
            for jointIndex in 0..<observableCount {
                var bestAngle = angles[jointIndex]
                for direction in [-1.0, 1.0] {
                    var candidate = angles
                    candidate[jointIndex] = min(
                        joints[jointIndex].upperLimit,
                        max(joints[jointIndex].lowerLimit, candidate[jointIndex] + direction * step)
                    )
                    let candidateCost = cost(candidate)
                    if candidateCost < bestCost {
                        bestCost = candidateCost
                        bestAngle = candidate[jointIndex]
                        improved = true
                    }
                }
                angles[jointIndex] = bestAngle
            }
            if !improved { step *= 0.5 }
            if step < 0.0005 { break }
        }
        guard bestCost.isFinite else { return nil }
        return FitResult(
            angles: angles,
            residualRMSEMeters: sqrt(bestCost),
            observableJointCount: observableCount
        )
    }

    static func transform(xyz: SIMD3<Double>, rpy: SIMD3<Double>) -> simd_double4x4 {
        let rotation = simd_quatd(angle: rpy.z, axis: SIMD3(0, 0, 1))
            * simd_quatd(angle: rpy.y, axis: SIMD3(0, 1, 0))
            * simd_quatd(angle: rpy.x, axis: SIMD3(1, 0, 0))
        var matrix = simd_matrix4x4(rotation)
        matrix.columns.3 = SIMD4(xyz.x, xyz.y, xyz.z, 1)
        return matrix
    }

    private static func axisAngle(axis: SIMD3<Double>, angle: Double) -> simd_double4x4 {
        simd_matrix4x4(simd_quatd(angle: angle, axis: simd_normalize(axis)))
    }
}

/// Stores the measured placement of both physical Amber bases in ROB's body
/// coordinate frame. Supplying these measurements does not move either arm.
@objcMembers public final class ROBAmberMountConfiguration: NSObject {
    public static let shared = ROBAmberMountConfiguration()
    private static let leftKey = "ROBAmberB1LeftMount"
    private static let rightKey = "ROBAmberB1RightMount"

    public func setMount(
        forArm arm: String,
        x: Double, y: Double, z: Double,
        roll: Double, pitch: Double, yaw: Double
    ) -> Bool {
        guard [x, y, z, roll, pitch, yaw].allSatisfy(\.isFinite),
              abs(x) <= 5, abs(y) <= 5, abs(z) <= 5,
              let key = Self.key(for: arm) else { return false }
        let mount = ROBAmberArmMount(
            translationMeters: [x, y, z], rotationRPYRadians: [roll, pitch, yaw]
        )
        guard let data = try? JSONEncoder().encode(mount) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    func mount(for arm: String) -> ROBAmberArmMount? {
        guard let key = Self.key(for: arm) else { return nil }
        if let data = UserDefaults.standard.data(forKey: key),
           let mount = try? JSONDecoder().decode(ROBAmberArmMount.self, from: data),
           mount.isValid {
            return mount
        }
        let environmentKey = arm.lowercased() == "left"
            ? "ROB_AMBER_LEFT_MOUNT" : "ROB_AMBER_RIGHT_MOUNT"
        guard let text = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let values = text.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        let mount = ROBAmberArmMount(
            translationMeters: Array(values.prefix(3)),
            rotationRPYRadians: Array(values.dropFirst(3).prefix(3))
        )
        return values.count == 6 && mount.isValid ? mount : nil
    }

    private static func key(for arm: String) -> String? {
        switch arm.lowercased() {
        case "left": return leftKey
        case "right": return rightKey
        default: return nil
        }
    }
}
