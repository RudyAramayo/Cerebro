//
//  ROBVisualCalibration.swift
//  Cerebro
//
//  Reverse camera-pose and arm-landmark estimation from QR fiducials and
//  synchronized OAK-D depth. No actuator commands are produced here.
//

import Foundation
import simd
import Vision

public struct ROBCameraPose: Codable, Sendable {
    public let translationMeters: [Double]
    /// Quaternion ordered x, y, z, w; transforms camera coordinates to ROB coordinates.
    public let rotationQuaternion: [Double]
    public let residualRMSEMeters: Double
    public let anchorCount: Int
    public let confidence: Double
}

private struct ROBRigidCorrespondence {
    let camera: SIMD3<Double>
    let robot: SIMD3<Double>
}

private struct ROBRigidTransform {
    let rotation: simd_quatd
    let translation: SIMD3<Double>
    let rms: Double

    func apply(_ point: SIMD3<Double>) -> SIMD3<Double> {
        rotation.act(point) + translation
    }
}

private enum ROBVisualMarker {
    case anchor(id: String, robotPosition: SIMD3<Double>)
    case armJoint(arm: String, joint: String, index: Int)

    init?(payload: String) {
        guard let components = URLComponents(string: payload),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        let identifier = components.path.split(separator: "/").first.map(String.init) ?? ""
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            item in item.value.map { (item.name.lowercased(), $0) }
        })
        switch (scheme, host) {
        case ("robcal", "anchor"):
            guard !identifier.isEmpty,
                  let xText = query["x"], let x = Double(xText), x.isFinite,
                  let yText = query["y"], let y = Double(yText), y.isFinite,
                  let zText = query["z"], let z = Double(zText), z.isFinite,
                  abs(x) <= 20, abs(y) <= 20, abs(z) <= 20 else { return nil }
            self = .anchor(id: identifier, robotPosition: SIMD3(x, y, z))
        case ("robarm", "left"), ("robarm", "right"):
            guard !identifier.isEmpty,
                  let indexText = query["index"], let index = Int(indexText),
                  (0...15).contains(index) else { return nil }
            self = .armJoint(arm: host, joint: identifier, index: index)
        default:
            return nil
        }
    }
}

private enum ROBRigidPoseSolver {
    /// Horn's absolute-orientation solution. At least three non-collinear
    /// camera/robot correspondences are required.
    static func solve(_ points: [ROBRigidCorrespondence]) -> ROBRigidTransform? {
        guard points.count >= 3 else { return nil }
        let count = Double(points.count)
        let cameraCenter = points.reduce(SIMD3<Double>.zero) { $0 + $1.camera } / count
        let robotCenter = points.reduce(SIMD3<Double>.zero) { $0 + $1.robot } / count
        let centered = points.map { ($0.camera - cameraCenter, $0.robot - robotCenter) }

        var noncollinear = false
        for first in centered.indices {
            for second in centered.indices where second > first {
                if simd_length(simd_cross(centered[first].0, centered[second].0)) > 1e-5 {
                    noncollinear = true
                    break
                }
            }
            if noncollinear { break }
        }
        guard noncollinear else { return nil }

        var s = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for (camera, robot) in centered {
            for row in 0..<3 {
                for column in 0..<3 {
                    s[row][column] += camera[row] * robot[column]
                }
            }
        }
        let trace = s[0][0] + s[1][1] + s[2][2]
        let n: [[Double]] = [
            [trace, s[1][2] - s[2][1], s[2][0] - s[0][2], s[0][1] - s[1][0]],
            [s[1][2] - s[2][1], s[0][0] - s[1][1] - s[2][2], s[0][1] + s[1][0], s[2][0] + s[0][2]],
            [s[2][0] - s[0][2], s[0][1] + s[1][0], -s[0][0] + s[1][1] - s[2][2], s[1][2] + s[2][1]],
            [s[0][1] - s[1][0], s[2][0] + s[0][2], s[1][2] + s[2][1], -s[0][0] - s[1][1] + s[2][2]]
        ]
        // Shift the symmetric matrix so power iteration selects its largest
        // algebraic eigenvalue instead of a negative eigenvalue by magnitude.
        let shift = sqrt(n.flatMap { $0 }.reduce(0) { $0 + $1 * $1 }) + 1e-12
        var q = [1.0, 0.0, 0.0, 0.0]
        for _ in 0..<80 {
            var next = [Double](repeating: 0, count: 4)
            for row in 0..<4 {
                next[row] = (0..<4).reduce(0) { $0 + n[row][$1] * q[$1] } + shift * q[row]
            }
            let norm = sqrt(next.reduce(0) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 1e-12 else { return nil }
            q = next.map { $0 / norm }
        }
        let rotation = simd_normalize(simd_quatd(ix: q[1], iy: q[2], iz: q[3], r: q[0]))
        let translation = robotCenter - rotation.act(cameraCenter)
        let squaredError = points.reduce(0.0) {
            let error = rotation.act($1.camera) + translation - $1.robot
            return $0 + simd_length_squared(error)
        }
        let rms = sqrt(squaredError / count)
        guard rms.isFinite else { return nil }
        return ROBRigidTransform(rotation: rotation, translation: translation, rms: rms)
    }
}

/// Accepts printable QR fiducials:
///   robcal://anchor/base-left?x=-0.20&y=0.50&z=0.00
///   robarm://left/elbow?index=2
/// Anchor coordinates are measured in meters in ROB's body frame. Use at least
/// four widely separated anchors; three is the mathematical minimum.
final class ROBReverseCameraPoseEstimator {
    private struct JointPoint {
        let arm: String
        let name: String
        let index: Int
        let position: SIMD3<Double>
        let depthConfidence: Double
    }

    private var lastAcceptedTransform: ROBRigidTransform?
    private var lastAcceptedTransformUptime: TimeInterval?
    private var lastArmAngles: [String: [Double]] = [:]
    private var lastDiagnosticUptime: [String: TimeInterval] = [:]

    func process(
        barcodes: [VNBarcodeObservation],
        depth: CameraDepthFrame?,
        intrinsics: CameraIntrinsics?
    ) {
        guard let depth, let intrinsics,
              intrinsics.isValid(forWidth: depth.width, height: depth.height) else { return }
        var anchors: [ROBRigidCorrespondence] = []
        var rawJoints: [(ROBVisualMarker, SIMD3<Double>, Double)] = []
        var usedPayloads = Set<String>()
        for barcode in barcodes {
            guard barcode.symbology == .qr,
                  let payload = barcode.payloadStringValue,
                  usedPayloads.insert(payload).inserted,
                  let marker = ROBVisualMarker(payload: payload),
                  let sample = backProject(
                    normalizedPoint: CGPoint(x: barcode.boundingBox.midX, y: barcode.boundingBox.midY),
                    depth: depth, intrinsics: intrinsics
                  ) else { continue }
            switch marker {
            case .anchor(_, let robotPosition):
                anchors.append(ROBRigidCorrespondence(camera: sample.point, robot: robotPosition))
            case .armJoint:
                rawJoints.append((marker, sample.point, sample.confidence))
            }
        }

        if let candidate = ROBRigidPoseSolver.solve(anchors), candidate.rms <= 0.05 {
            lastAcceptedTransform = candidate
            lastAcceptedTransformUptime = ProcessInfo.processInfo.systemUptime
            let confidence = min(1, Double(anchors.count) / 6) * max(0, 1 - candidate.rms / 0.05)
            let vector = candidate.rotation.vector
            ROBSceneSnapshotStore.shared.updateCameraPose(ROBCameraPose(
                translationMeters: [candidate.translation.x, candidate.translation.y, candidate.translation.z],
                rotationQuaternion: [vector.x, vector.y, vector.z, vector.w],
                residualRMSEMeters: candidate.rms, anchorCount: anchors.count,
                confidence: confidence
            ))
            diagnose("camera", String(
                format: "camera anchors=%d rms=%.4fm confidence=%.2f",
                anchors.count, candidate.rms, confidence
            ))
        }
        let transformIsFresh = lastAcceptedTransformUptime.map {
            ProcessInfo.processInfo.systemUptime - $0 <= 0.5
        } ?? false
        guard transformIsFresh, let transform = lastAcceptedTransform else {
            ROBSceneSnapshotStore.shared.updateCameraPose(nil)
            ROBSceneSnapshotStore.shared.updateArmPose([])
            return
        }
        let joints: [JointPoint] = rawJoints.compactMap { marker, cameraPoint, confidence in
            guard case .armJoint(let arm, let joint, let index) = marker else { return nil }
            return JointPoint(
                arm: arm, name: joint, index: index,
                position: transform.apply(cameraPoint), depthConfidence: confidence
            )
        }
        ROBSceneSnapshotStore.shared.updateArmPose(
            modelBasedJointAngles(joints, calibrationRMS: transform.rms)
        )
    }

    private func backProject(
        normalizedPoint: CGPoint,
        depth: CameraDepthFrame,
        intrinsics: CameraIntrinsics
    ) -> (point: SIMD3<Double>, confidence: Double)? {
        let pixelX = min(depth.width - 1, max(0, Int(normalizedPoint.x * CGFloat(depth.width))))
        let pixelY = min(depth.height - 1, max(0, Int((1 - normalizedPoint.y) * CGFloat(depth.height))))
        var samples: [UInt16] = []
        for y in max(0, pixelY - 3)...min(depth.height - 1, pixelY + 3) {
            for x in max(0, pixelX - 3)...min(depth.width - 1, pixelX + 3) {
                if let value = depth.distanceMillimeters(x: x, y: y), (150...10_000).contains(value) {
                    samples.append(value)
                }
            }
        }
        guard samples.count >= 8 else { return nil }
        samples.sort()
        let z = Double(samples[samples.count / 2]) / 1_000
        return (
            SIMD3(
                (Double(pixelX) - intrinsics.cx) * z / intrinsics.fx,
                (Double(pixelY) - intrinsics.cy) * z / intrinsics.fy,
                z
            ),
            min(1, Double(samples.count) / 49)
        )
    }

    private func modelBasedJointAngles(
        _ points: [JointPoint],
        calibrationRMS: Double
    ) -> [ROBArmJointPose] {
        Dictionary(grouping: points, by: \.arm).values.flatMap { armPoints -> [ROBArmJointPose] in
            guard let arm = armPoints.first?.arm,
                  let mount = ROBAmberMountConfiguration.shared.mount(for: arm) else { return [] }
            let observations = armPoints.reduce(into: [Int: SIMD3<Double>]()) {
                $0[$1.index] = $1.position
            }
            guard let fit = ROBAmberB1Kinematics.fitJointAngles(
                observedJointOrigins: observations,
                mount: mount,
                initialAngles: lastArmAngles[arm]
            ), fit.residualRMSEMeters <= 0.06 else { return [] }
            lastArmAngles[arm] = fit.angles
            let depthConfidence = armPoints.map(\.depthConfidence).min() ?? 0
            let confidence = depthConfidence
                * max(0, 1 - calibrationRMS / 0.05)
                * max(0, 1 - fit.residualRMSEMeters / 0.06)
            diagnose(arm, String(
                format: "%@ arm markers=%d fittedJoints=%d rms=%.4fm confidence=%.2f angles=%@",
                arm, observations.count, fit.observableJointCount,
                fit.residualRMSEMeters, confidence,
                fit.angles.prefix(fit.observableJointCount).map { String(format: "%.3f", $0) }.joined(separator: ",")
            ))
            return ROBAmberB1Kinematics.joints.enumerated().map { index, definition in
                ROBArmJointPose(
                    arm: arm,
                    joint: definition.name,
                    angleRadians: index < fit.observableJointCount ? fit.angles[index] : nil,
                    confidence: index < fit.observableJointCount ? confidence : 0,
                    source: "amber-b1-urdf-oak-d-reverse-pose"
                )
            }
        }
    }

    private func diagnose(_ category: String, _ message: String) {
        let value = ProcessInfo.processInfo.environment["ROB_VISUAL_CALIBRATION_DIAGNOSTICS"]?.lowercased()
        guard value == "1" || value == "true" || value == "yes" else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastDiagnosticUptime[category] ?? 0) >= 1 else { return }
        lastDiagnosticUptime[category] = now
        NSLog("ROB visual calibration: %@", message)
    }
}
