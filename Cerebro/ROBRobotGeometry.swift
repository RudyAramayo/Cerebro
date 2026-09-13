import Foundation
import simd

/// Offline geometry, deliberately independent of robot transports and drivers.
/// All transforms use meters, radians, X forward, Y robot-left, Z up.
struct ROBGeometryOrigin: Codable, Equatable {
    var xyzMeters: [Double] = [0, 0, 0]
    var rpyRadians: [Double] = [0, 0, 0]
    var valid: Bool { xyzMeters.count == 3 && rpyRadians.count == 3 && xyzMeters.allSatisfy { $0.isFinite && abs($0) <= 100 } && rpyRadians.allSatisfy { $0.isFinite && abs($0) <= 100 } }
    var matrix: simd_double4x4 {
        ROBAmberB1Kinematics.transform(xyz: SIMD3(xyzMeters[0], xyzMeters[1], xyzMeters[2]),
                                      rpy: SIMD3(rpyRadians[0], rpyRadians[1], rpyRadians[2]))
    }
    static func from(_ matrix: simd_double4x4) -> Self {
        let horizontal = hypot(matrix.columns.0.x, matrix.columns.0.y)
        let pitch = atan2(-matrix.columns.0.z, horizontal)
        let roll: Double, yaw: Double
        if horizontal > 1e-8 {
            roll = atan2(matrix.columns.1.z, matrix.columns.2.z)
            yaw = atan2(matrix.columns.0.y, matrix.columns.0.x)
        } else {
            roll = 0
            yaw = atan2(-matrix.columns.1.x, matrix.columns.1.y)
        }
        return .init(xyzMeters: [matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z], rpyRadians: [roll, pitch, yaw])
    }
}

struct ROBGeometryEvidence: Codable, Equatable {
    /// These describe evidence, never permission to move hardware.
    var source = "unmeasured"
    var note = "Schematic estimate. Replace with measured landmarks."
    var uncertaintyMeters: Double? = nil
}

struct ROBGeometryJoint: Codable, Equatable {
    var name: String
    var parent: String
    var child: String
    var kind = "fixed"
    var origin = ROBGeometryOrigin()
    var axis: [Double] = [0, 0, 1]
    var lower: Double = 0
    var upper: Double = 0
    var evidence = ROBGeometryEvidence()
    var hardwareAnnotation = "Unverified mapping; no hardware output"
}

struct ROBGeometryLink: Codable, Equatable {
    var name: String
    var boxMeters: [Double]
    var boxOrigin = ROBGeometryOrigin()
    var vendorLink: String? = nil
    var evidence = ROBGeometryEvidence()
}

struct ROBGeometryLACT: Codable, Equatable {
    var fixedLink = "base_link"
    var movingLink = "lean_link"
    var fixedAnchorMeters: [Double] = [-0.16, 0, 0.25]
    var movingAnchorMeters: [Double] = [-0.12, 0, 0.22]
    var evidence = ROBGeometryEvidence(note: "Measure both LACT pin centers. Stroke-to-pitch is nonlinear; the URDF tree represents the driven lean pivot. The actuator closes a mechanical loop.")
}

struct ROBGeometryProfile: Codable {
    var schemaVersion = 1
    var simulationOnly = true
    var name = "ROB geometry draft"
    var joints: [ROBGeometryJoint]
    var links: [ROBGeometryLink]
    /// q is separate from joint origins and never baked into the exported URDF.
    var previewPositions: [String: Double] = [:]
    var scanToBase = ROBGeometryOrigin()
    var scanScale = 1.0
    var lact = ROBGeometryLACT()
    var landmarkFits: [String: ROBGeometryFitRecord]? = nil
    var startupReferenceNote = "Operator reports gravity-hanging startup: joints 2 and 4 differ from URDF zero; other joints appear at initialization. Numerical offsets and directions remain unverified. Capture a new vendor reference after every Amber boot; never reuse raw boot offsets as mount geometry."

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ROBGeometryError.invalid(message) }
        }
        func identifier(_ s: String) -> Bool { s.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil }
        try require(schemaVersion == 1 && simulationOnly, "Only version 1 simulation profiles are accepted.")
        try require(links.count <= 200 && joints.count <= 200 && !joints.isEmpty, "Model must have 1–200 joints.")
        let names = Set(links.map(\.name))
        try require(names.count == links.count && names.contains("base_link"), "Links must be unique and include base_link.")
        try require(Set(joints.map(\.name)).count == joints.count, "Joint names must be unique.")
        for link in links {
            try require(identifier(link.name) && link.boxOrigin.valid && link.boxMeters.count == 3 && link.boxMeters.allSatisfy { $0.isFinite && $0 > 0 && $0 < 10 }, "Invalid link geometry: \(link.name)")
        }
        for joint in joints {
            try require(identifier(joint.name) && names.contains(joint.parent) && names.contains(joint.child) && joint.child != "base_link", "Invalid joint frames: \(joint.name)")
            try require(["fixed", "revolute", "prismatic", "continuous"].contains(joint.kind) && joint.origin.valid, "Invalid joint type/origin: \(joint.name)")
            try require(joint.axis.count == 3 && joint.axis.allSatisfy(\.isFinite) && abs(joint.axis.reduce(0) { $0 + $1 * $1 } - 1) < 1e-6, "Joint axis must be a unit vector: \(joint.name)")
            try require(joint.lower.isFinite && joint.upper.isFinite && joint.lower <= joint.upper, "Invalid limits: \(joint.name)")
            let q = previewPositions[joint.name] ?? 0
            try require(q.isFinite && (joint.kind == "fixed" ? q == 0 : joint.kind == "continuous" || (joint.lower...joint.upper).contains(q)), "Preview position outside limits: \(joint.name)")
        }
        try require(Set(joints.map(\.child)).count == joints.count && joints.count == links.count - 1, "Every non-root link needs exactly one parent.")
        var visited: Set<String> = ["base_link"]
        for _ in 0..<links.count {
            for joint in joints where visited.contains(joint.parent) { visited.insert(joint.child) }
        }
        try require(visited == names, "Model contains a cycle or disconnected link.")
        try require(Set(previewPositions.keys).isSubset(of: Set(joints.map(\.name))), "Unknown preview joint.")
        try require(scanToBase.valid && scanScale.isFinite && scanScale >= 0.000001 && scanScale <= 1000, "Invalid scan transform or scale.")
        try require(names.contains(lact.fixedLink) && names.contains(lact.movingLink) && lact.fixedAnchorMeters.count == 3 && lact.movingAnchorMeters.count == 3 && (lact.fixedAnchorMeters + lact.movingAnchorMeters).allSatisfy(\.isFinite), "Invalid LACT anchors.")
        for evidence in joints.map(\.evidence) + links.map(\.evidence) + [lact.evidence] {
            try require(["unmeasured", "photo_estimate", "vendor", "landmark_fit", "measured"].contains(evidence.source), "Unknown evidence source.")
            if let uncertainty = evidence.uncertaintyMeters { try require(uncertainty.isFinite && uncertainty >= 0, "Invalid measurement uncertainty.") }
        }
        if let fits = landmarkFits {
            try require(fits.count <= 201, "Too many landmark fits.")
            for (key, fit) in fits {
                try require(key == "scanToBase" || joints.contains(where: { $0.name == key }), "Unknown fitted frame.")
                try require(fit.landmarks.count <= 1000 && fit.fitRMSEMeters.isFinite && fit.fitRMSEMeters >= 0, "Invalid landmark fit record.")
                if let error = fit.validationRMSEMeters { try require(error.isFinite && error >= 0, "Invalid validation residual.") }
                _ = try ROBGeometryMath.fit(fit.landmarks)
            }
        }
    }

    func transforms(positions: [String: Double]? = nil) -> [String: simd_double4x4] {
        let values = positions ?? previewPositions
        var result = ["base_link": matrix_identity_double4x4]
        for _ in 0..<links.count {
            for joint in joints where result[joint.child] == nil {
                guard let parent = result[joint.parent] else { continue }
                let q = values[joint.name] ?? 0
                let axis = SIMD3(joint.axis[0], joint.axis[1], joint.axis[2])
                var motion = matrix_identity_double4x4
                if joint.kind == "revolute" || joint.kind == "continuous" {
                    motion = simd_matrix4x4(simd_quatd(angle: q, axis: axis))
                } else if joint.kind == "prismatic" {
                    motion.columns.3 = SIMD4(axis * q, 1)
                }
                result[joint.child] = parent * joint.origin.matrix * motion
            }
        }
        return result
    }

    func lactEndpoints() -> (SIMD3<Double>, SIMD3<Double>)? {
        let frames = transforms()
        guard let a = frames[lact.fixedLink], let b = frames[lact.movingLink] else { return nil }
        return (ROBGeometryMath.point(a, lact.fixedAnchorMeters), ROBGeometryMath.point(b, lact.movingAnchorMeters))
    }

    /// Broad-phase warning only. AABB overlap is not proof of mesh collision,
    /// and absence of overlap is not a certified clearance result.
    func envelopeOverlaps() -> [(String, String)] {
        let frames = transforms()
        var bounds: [String: (SIMD3<Double>, SIMD3<Double>)] = [:]
        for link in links {
            guard let frame = frames[link.name] else { continue }
            var low = SIMD3<Double>(repeating: .infinity), high = SIMD3<Double>(repeating: -.infinity)
            for x in [-0.5, 0.5] { for y in [-0.5, 0.5] { for z in [-0.5, 0.5] {
                let p = ROBGeometryMath.point(frame * link.boxOrigin.matrix, [x * link.boxMeters[0], y * link.boxMeters[1], z * link.boxMeters[2]])
                low = simd_min(low, p); high = simd_max(high, p)
            } } }
            bounds[link.name] = (low, high)
        }
        var result: [(String, String)] = []
        for i in links.indices { for j in links.indices where j > i {
            let a = links[i].name, b = links[j].name
            if joints.contains(where: { ($0.parent == a && $0.child == b) || ($0.parent == b && $0.child == a) }) { continue }
            guard let aa = bounds[a], let bb = bounds[b] else { continue }
            if (0..<3).allSatisfy({ aa.0[$0] < bb.1[$0] && bb.0[$0] < aa.1[$0] }) { result.append((a, b)) }
        } }
        return result
    }

    /// Position-only IK in memory. No orientation, trajectory, or hardware approval.
    func previewIK(arm: String, target: SIMD3<Double>) -> (positions: [String: Double], errorMeters: Double)? {
        guard [target.x, target.y, target.z].allSatisfy(\.isFinite), ["left", "right"].contains(arm) else { return nil }
        let chain = (1...7).compactMap { n in joints.first { $0.name == "\(arm)_joint\(n)" } }
        guard chain.count == 7, chain.allSatisfy({ $0.kind == "revolute" }) else { return nil }
        var q = previewPositions
        let tip = "\(arm)_tool"
        func endpoint(_ state: [String: Double]) -> SIMD3<Double>? {
            transforms(positions: state)[tip].map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        }
        guard var current = endpoint(q) else { return nil }
        var best = q, bestError = simd_distance(current, target)
        for _ in 0..<160 {
            if bestError < 0.002 { break }
            let error = target - current
            var jacobian: [SIMD3<Double>] = []
            for joint in chain {
                var perturbed = q
                perturbed[joint.name] = (q[joint.name] ?? 0) + 0.0001
                guard let next = endpoint(perturbed) else { return nil }
                jacobian.append((next - current) / 0.0001)
            }
            var a = matrix_identity_double3x3 * 0.0025
            for column in jacobian {
                a += simd_double3x3(columns: (column * column.x, column * column.y, column * column.z))
            }
            let step = a.inverse * error
            for (joint, column) in zip(chain, jacobian) {
                q[joint.name] = min(joint.upper, max(joint.lower, (q[joint.name] ?? 0) + min(0.12, max(-0.12, simd_dot(column, step)))))
            }
            guard let next = endpoint(q) else { return nil }
            current = next
            let residual = simd_distance(current, target)
            if residual < bestError { best = q; bestError = residual }
        }
        return (best, bestError)
    }
}

enum ROBGeometryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

struct ROBGeometryLandmark: Codable {
    var name: String
    var localMeters: [Double]
    var parentMeters: [Double]
    var validationOnly = false
}

struct ROBGeometryFitRecord: Codable {
    var sourceFile: String
    var landmarks: [ROBGeometryLandmark]
    var fitRMSEMeters: Double
    var validationRMSEMeters: Double?
    var previewPositionsAtFit: [String: Double]
    var scanScaleAtFit: Double
}

struct ROBGeometryFit {
    var origin: ROBGeometryOrigin
    var fitRMSEMeters: Double
    var validationRMSEMeters: Double?
    var residualsMeters: [Double]
}

enum ROBGeometryMath {
    static func deproject(x: Double, y: Double, depthMeters: Double, fx: Double, fy: Double, cx: Double, cy: Double) -> SIMD3<Double>? {
        guard [x, y, depthMeters, fx, fy, cx, cy].allSatisfy(\.isFinite), fx > 0, fy > 0, depthMeters > 0 else { return nil }
        let p = SIMD3((x - cx) * depthMeters / fx, (y - cy) * depthMeters / fy, depthMeters)
        return [p.x, p.y, p.z].allSatisfy(\.isFinite) ? p : nil
    }
    static func point(_ matrix: simd_double4x4, _ xyz: [Double]) -> SIMD3<Double> {
        let p = matrix * SIMD4(xyz[0], xyz[1], xyz[2], 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// Horn absolute orientation, with Jacobi eigenvectors (including exact 180°).
    /// Holdout landmarks never participate in fitting. Scale is intentionally fixed.
    static func fit(_ landmarks: [ROBGeometryLandmark]) throws -> ROBGeometryFit {
        guard landmarks.count <= 1000, landmarks.allSatisfy({ $0.localMeters.count == 3 && $0.parentMeters.count == 3 && ($0.localMeters + $0.parentMeters).allSatisfy { $0.isFinite && abs($0) <= 100 } }) else { throw ROBGeometryError.invalid("Landmarks require finite XYZ triples in meters, within 100 m.") }
        let training = landmarks.filter { !$0.validationOnly }
        guard training.count >= 3 else { throw ROBGeometryError.invalid("Use at least three non-collinear fit landmarks, plus separate validation landmarks.") }
        let source = training.map { SIMD3($0.localMeters[0], $0.localMeters[1], $0.localMeters[2]) }
        let target = training.map { SIMD3($0.parentMeters[0], $0.parentMeters[1], $0.parentMeters[2]) }
        func center(_ p: [SIMD3<Double>]) -> SIMD3<Double> { p.reduce(.zero, +) / Double(p.count) }
        let sc = center(source), tc = center(target)
        let s = source.map { $0 - sc }, t = target.map { $0 - tc }
        func noncollinear(_ points: [SIMD3<Double>]) -> Bool {
            guard let longest = points.max(by: { simd_length_squared($0) < simd_length_squared($1) }), simd_length(longest) > 0.005 else { return false }
            return points.contains { simd_length(simd_cross(longest, $0)) > 0.00001 }
        }
        guard noncollinear(s), noncollinear(t) else { throw ROBGeometryError.invalid("Landmarks are collinear or too closely spaced; spread targets across the mount.") }
        var h = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for (a, b) in zip(s, t) { for row in 0..<3 { for col in 0..<3 { h[row][col] += a[row] * b[col] } } }
        let trace = h[0][0] + h[1][1] + h[2][2]
        var n = [
            [trace, h[1][2] - h[2][1], h[2][0] - h[0][2], h[0][1] - h[1][0]],
            [h[1][2] - h[2][1], h[0][0] - h[1][1] - h[2][2], h[0][1] + h[1][0], h[0][2] + h[2][0]],
            [h[2][0] - h[0][2], h[0][1] + h[1][0], -h[0][0] + h[1][1] - h[2][2], h[1][2] + h[2][1]],
            [h[0][1] - h[1][0], h[0][2] + h[2][0], h[1][2] + h[2][1], -h[0][0] - h[1][1] + h[2][2]]
        ]
        var v = (0..<4).map { row in (0..<4).map { col in row == col ? 1.0 : 0.0 } }
        for _ in 0..<100 {
            var p = 0, q = 1
            for i in 0..<4 { for j in (i + 1)..<4 where abs(n[i][j]) > abs(n[p][q]) { p = i; q = j } }
            if abs(n[p][q]) < 1e-14 { break }
            let angle = 0.5 * atan2(2 * n[p][q], n[q][q] - n[p][p]), c = cos(angle), ss = sin(angle)
            let pp = n[p][p], qq = n[q][q], pq = n[p][q]
            for k in 0..<4 where k != p && k != q {
                let kp = n[k][p], kq = n[k][q]
                n[k][p] = c * kp - ss * kq; n[p][k] = n[k][p]
                n[k][q] = ss * kp + c * kq; n[q][k] = n[k][q]
            }
            n[p][p] = c * c * pp - 2 * ss * c * pq + ss * ss * qq
            n[q][q] = ss * ss * pp + 2 * ss * c * pq + c * c * qq
            n[p][q] = 0; n[q][p] = 0
            for k in 0..<4 { let kp = v[k][p], kq = v[k][q]; v[k][p] = c * kp - ss * kq; v[k][q] = ss * kp + c * kq }
        }
        let index = (0..<4).max(by: { n[$0][$0] < n[$1][$1] })!
        let rotation = simd_normalize(simd_quatd(ix: v[1][index], iy: v[2][index], iz: v[3][index], r: v[0][index]))
        var matrix = simd_matrix4x4(rotation)
        matrix.columns.3 = SIMD4(tc - rotation.act(sc), 1)
        let residuals = landmarks.map { simd_distance(point(matrix, $0.localMeters), SIMD3($0.parentMeters[0], $0.parentMeters[1], $0.parentMeters[2])) }
        func rms(_ validation: Bool) -> Double? {
            let values = zip(landmarks, residuals).filter { $0.0.validationOnly == validation }.map { $0.1 }
            return values.isEmpty ? nil : sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
        }
        return .init(origin: .from(matrix), fitRMSEMeters: rms(false)!, validationRMSEMeters: rms(true), residualsMeters: residuals)
    }
}
