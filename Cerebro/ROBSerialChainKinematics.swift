import Foundation
import simd

enum ROBKinematicsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let detail) = self { return detail }; return nil }
}

/// Kinematics only: no driver directions, encoder-zero assumptions, network,
/// collision certification, or actuator authority. All transforms are T_parent_child.
struct ROBSerialChain {
    struct Joint {
        let name: String
        let parent: String
        let child: String
        let kind: String
        let origin: simd_double4x4
        let axis: SIMD3<Double>
        let lower: Double
        let upper: Double
        var movable: Bool { kind != "fixed" }
    }
    let base: String
    let tip: String
    let joints: [Joint]
    var movingJoints: [Joint] { joints.filter(\.movable) }

    init(urdf: Data, base: String, tip: String) throws {
        guard !urdf.isEmpty, urdf.count <= 5_000_000,
              let xml = String(data: urdf, encoding: .utf8),
              !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else {
            throw ROBKinematicsError.invalid("Use a plain URDF under 5 MB without DTDs or entities.")
        }
        let document = try XMLDocument(data: urdf, options: [])
        guard let root = document.rootElement(), root.name == "robot" else {
            throw ROBKinematicsError.invalid("URDF must have a robot root.")
        }
        let links = root.elements(forName: "link").compactMap { $0.attribute(forName: "name")?.stringValue }
        guard links.count <= 300, links.count == root.elements(forName: "link").count,
              Set(links).count == links.count, links.allSatisfy({ !$0.isEmpty }), links.contains(base), links.contains(tip), base != tip else {
            throw ROBKinematicsError.invalid("Base/tip must be distinct named links in a model with unique links.")
        }
        var byChild: [String: XMLElement] = [:]
        var names = Set<String>()
        let elements = root.elements(forName: "joint")
        guard elements.count <= 300 else { throw ROBKinematicsError.invalid("Too many joints.") }
        for element in elements {
            guard let name = element.attribute(forName: "name")?.stringValue, !name.isEmpty, names.insert(name).inserted,
                  element.elements(forName: "parent").count == 1, element.elements(forName: "child").count == 1,
                  let parent = element.elements(forName: "parent").first?.attribute(forName: "link")?.stringValue,
                  let child = element.elements(forName: "child").first?.attribute(forName: "link")?.stringValue,
                  links.contains(parent), links.contains(child), parent != child, byChild[child] == nil else {
                throw ROBKinematicsError.invalid("Duplicate joint, invalid parent/child, or more than one parent for a link.")
            }
            byChild[child] = element
        }
        // Validate the entire graph, so a malformed second arm cannot hide a cycle.
        for link in links {
            var seen = Set<String>(), cursor = link
            while let element = byChild[cursor] {
                guard seen.insert(cursor).inserted else { throw ROBKinematicsError.invalid("URDF contains a cycle.") }
                cursor = element.elements(forName: "parent")[0].attribute(forName: "link")!.stringValue!
            }
        }
        guard links.filter({ byChild[$0] == nil }).count == 1 else {
            throw ROBKinematicsError.invalid("URDF must be one connected tree.")
        }
        var reversed: [Joint] = [], cursor = tip
        while cursor != base {
            guard let element = byChild[cursor] else {
                throw ROBKinematicsError.invalid("The tip is not a descendant of the selected base.")
            }
            let name = element.attribute(forName: "name")!.stringValue!
            let parent = element.elements(forName: "parent")[0].attribute(forName: "link")!.stringValue!
            let kind = element.attribute(forName: "type")?.stringValue ?? ""
            guard ["fixed", "revolute", "continuous", "prismatic"].contains(kind),
                  element.elements(forName: "mimic").isEmpty else {
                throw ROBKinematicsError.invalid("Unsupported joint \(name): expand mimic joints and remove floating/planar joints from the selected chain.")
            }
            let origin = element.elements(forName: "origin").first
            let xyz = try Self.vector(origin?.attribute(forName: "xyz")?.stringValue ?? "0 0 0")
            let rpy = try Self.vector(origin?.attribute(forName: "rpy")?.stringValue ?? "0 0 0")
            let axis = try Self.vector(element.elements(forName: "axis").first?.attribute(forName: "xyz")?.stringValue ?? "1 0 0")
            guard simd_length(axis).isFinite, simd_length(axis) > 1e-10,
                  simd_length(xyz) < 1000 else { throw ROBKinematicsError.invalid("Invalid axis or implausibly large origin for \(name).") }
            var lower = -Double.infinity, upper = Double.infinity
            if kind == "revolute" || kind == "prismatic" {
                guard let limit = element.elements(forName: "limit").first,
                      let lo = Double(limit.attribute(forName: "lower")?.stringValue ?? ""),
                      let hi = Double(limit.attribute(forName: "upper")?.stringValue ?? ""),
                      lo.isFinite, hi.isFinite, lo < hi else {
                    throw ROBKinematicsError.invalid("Joint \(name) needs finite ordered position limits.")
                }
                lower = lo; upper = hi
            }
            reversed.append(Joint(name: name, parent: parent, child: cursor, kind: kind,
                                  origin: Self.pose(xyz: xyz, rpy: rpy), axis: simd_normalize(axis), lower: lower, upper: upper))
            cursor = parent
        }
        guard reversed.filter(\.movable).count <= 20 else { throw ROBKinematicsError.invalid("Select a chain with at most 20 moving joints.") }
        self.base = base; self.tip = tip; joints = reversed.reversed()
    }

    private static func vector(_ text: String) throws -> SIMD3<Double> {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let values = tokens.compactMap { Double($0) }
        guard tokens.count == 3, values.count == 3, values.allSatisfy(\.isFinite) else {
            throw ROBKinematicsError.invalid("Expected three finite numbers, got: \(text)")
        }
        return SIMD3(values[0], values[1], values[2])
    }

    static func pose(xyz: SIMD3<Double>, rpy: SIMD3<Double>) -> simd_double4x4 {
        let rotation = simd_quatd(angle: rpy.z, axis: SIMD3(0, 0, 1))
            * simd_quatd(angle: rpy.y, axis: SIMD3(0, 1, 0))
            * simd_quatd(angle: rpy.x, axis: SIMD3(1, 0, 0))
        var value = simd_matrix4x4(rotation)
        value.columns.3 = SIMD4(xyz.x, xyz.y, xyz.z, 1)
        return value
    }

    static func rigid(_ value: simd_double4x4) -> Bool {
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { value[c][$0].isFinite } }),
              abs(value[0].w) < 1e-8, abs(value[1].w) < 1e-8, abs(value[2].w) < 1e-8,
              abs(value[3].w - 1) < 1e-8 else { return false }
        let r = rotation(value), unit = r.transpose * r
        return abs(simd_determinant(r) - 1) < 1e-6 && (0..<3).allSatisfy { c in
            (0..<3).allSatisfy { abs(unit[c][$0] - (c == $0 ? 1 : 0)) < 1e-6 }
        }
    }
    static func rotation(_ m: simd_double4x4) -> simd_double3x3 {
        .init(columns: (SIMD3(m[0].x, m[0].y, m[0].z), SIMD3(m[1].x, m[1].y, m[1].z), SIMD3(m[2].x, m[2].y, m[2].z)))
    }
    static func translation(_ m: simd_double4x4) -> SIMD3<Double> { SIMD3(m[3].x, m[3].y, m[3].z) }

    /// Includes the fixed flange-to-tool transform. A bare seventh link is not
    /// the gripper contact point unless an independently measured offset is zero.
    func forward(_ q: [Double], tipFromTool: simd_double4x4 = matrix_identity_double4x4) throws -> simd_double4x4 {
        try state(q, tipFromTool: tipFromTool).pose
    }

    private func state(_ q: [Double], tipFromTool: simd_double4x4) throws -> (pose: simd_double4x4, columns: [[Double]]) {
        guard q.count == movingJoints.count, Self.rigid(tipFromTool), simd_length(Self.translation(tipFromTool)) < 1000 else {
            throw ROBKinematicsError.invalid("Supply one model-coordinate position per named moving joint and a rigid tool offset.")
        }
        var current = matrix_identity_double4x4, i = 0
        var origins: [SIMD3<Double>] = [], axes: [SIMD3<Double>] = [], kinds: [String] = []
        for joint in joints {
            current = current * joint.origin
            if joint.movable {
                let angle = q[i]; i += 1
                guard angle.isFinite, angle >= joint.lower, angle <= joint.upper else {
                    throw ROBKinematicsError.invalid("Joint \(joint.name) is non-finite or outside its URDF limits; seed values are never silently clamped.")
                }
                origins.append(Self.translation(current)); axes.append(Self.rotation(current) * joint.axis); kinds.append(joint.kind)
                if joint.kind == "prismatic" {
                    var displacement = matrix_identity_double4x4
                    displacement[3] = SIMD4(joint.axis.x * angle, joint.axis.y * angle, joint.axis.z * angle, 1)
                    current = current * displacement
                } else {
                    current = current * simd_matrix4x4(simd_quatd(angle: angle, axis: joint.axis))
                }
            }
        }
        current = current * tipFromTool
        let end = Self.translation(current)
        let columns: [[Double]] = axes.indices.map { index in
            let linear = kinds[index] == "prismatic" ? axes[index] : simd_cross(axes[index], end - origins[index])
            let angular = kinds[index] == "prismatic" ? SIMD3<Double>.zero : axes[index]
            return [linear.x, linear.y, linear.z, angular.x, angular.y, angular.z]
        }
        return (current, columns)
    }

    struct Options {
        var positionToleranceMeters = 0.001
        var orientationToleranceRadians = 0.01
        var orientationWeightMeters = 0.2
        var positionOnly = false
        var maximumIterations = 250
        var maximumSeconds = 0.25
        var maximumStep = 0.12
        /// A continuity bound, in radians (meters for prismatic joints).
        var maximumDisplacementFromSeed = 0.35
    }
    struct Solution {
        let converged: Bool
        let positions: [Double]
        let positionErrorMeters: Double
        let orientationErrorRadians: Double
        let iterations: Int
        let reason: String
    }

    /// Bounded damped least squares with an analytic spatial Jacobian, joint
    /// limits, seed continuity and backtracking. Failure is not a proof that a
    /// target is unreachable; it may require another seed or more time.
    func solve(targetInBase target: simd_double4x4, seed: [Double],
               tipFromTool: simd_double4x4 = matrix_identity_double4x4,
               options: Options = Options()) throws -> Solution {
        guard Self.rigid(target), simd_length(Self.translation(target)) < 10000, !movingJoints.isEmpty,
              (1...5000).contains(options.maximumIterations),
              [options.positionToleranceMeters, options.orientationToleranceRadians, options.orientationWeightMeters,
               options.maximumSeconds, options.maximumStep, options.maximumDisplacementFromSeed].allSatisfy({ $0.isFinite && $0 > 0 }),
              options.maximumSeconds <= 5, options.maximumStep <= 0.5 else {
            throw ROBKinematicsError.invalid("Invalid rigid target or bounded solver options.")
        }
        _ = try forward(seed, tipFromTool: tipFromTool)
        let start = ProcessInfo.processInfo.systemUptime, n = seed.count
        var q = seed, damping = 0.02
        func errors(_ pose: simd_double4x4) -> (vector: [Double], position: Double, orientation: Double, cost: Double) {
            let p = Self.translation(target) - Self.translation(pose)
            let delta = simd_quatd(Self.rotation(target) * Self.rotation(pose).transpose).normalized
            let v = delta.real < 0 ? -delta.imag : delta.imag
            let length = simd_length(v)
            let angle = 2 * atan2(length, abs(delta.real))
            let rotation = length > 1e-12 ? v * (angle / length) : .zero
            let w = options.positionOnly ? 0 : options.orientationWeightMeters
            let e = [p.x, p.y, p.z, rotation.x * w, rotation.y * w, rotation.z * w]
            return (e, simd_length(p), angle, e.reduce(0) { $0 + $1 * $1 })
        }
        func result(_ iteration: Int, _ reason: String) throws -> Solution {
            let error = errors(try forward(q, tipFromTool: tipFromTool))
            let converged = error.position <= options.positionToleranceMeters
                && (options.positionOnly || error.orientation <= options.orientationToleranceRadians)
            return Solution(converged: converged, positions: q, positionErrorMeters: error.position,
                            orientationErrorRadians: error.orientation, iterations: iteration,
                            reason: converged ? "converged_kinematically_collision_unchecked" : reason)
        }
        for iteration in 0..<options.maximumIterations {
            if ProcessInfo.processInfo.systemUptime - start >= options.maximumSeconds {
                return try result(iteration, "time_budget_exhausted")
            }
            let current = try state(q, tipFromTool: tipFromTool), error = errors(current.pose)
            if error.position <= options.positionToleranceMeters && (options.positionOnly || error.orientation <= options.orientationToleranceRadians) {
                return try result(iteration, "converged")
            }
            let w = options.positionOnly ? 0 : options.orientationWeightMeters
            let jacobian = current.columns.map { c in [c[0], c[1], c[2], c[3] * w, c[4] * w, c[5] * w] }
            var normal = Array(repeating: Array(repeating: 0.0, count: n), count: n), rhs = Array(repeating: 0.0, count: n)
            for i in 0..<n {
                rhs[i] = zip(jacobian[i], error.vector).reduce(0) { $0 + $1.0 * $1.1 }
                for j in 0..<n {
                    normal[i][j] = zip(jacobian[i], jacobian[j]).reduce(0) { $0 + $1.0 * $1.1 }
                }
                normal[i][i] += damping * damping
            }
            guard var step = Self.linearSolve(normal, rhs) else { return try result(iteration, "singular_normal_system") }
            let largest = step.map(abs).max() ?? 0
            if largest > options.maximumStep { step = step.map { $0 * options.maximumStep / largest } }
            var improved = false, scale = 1.0
            for _ in 0..<10 {
                let candidate = q.indices.map { i -> Double in
                    let joint = movingJoints[i]
                    let lower = max(joint.lower, seed[i] - options.maximumDisplacementFromSeed)
                    let upper = min(joint.upper, seed[i] + options.maximumDisplacementFromSeed)
                    return min(upper, max(lower, q[i] + step[i] * scale))
                }
                let next = errors(try forward(candidate, tipFromTool: tipFromTool))
                if next.cost < error.cost - 1e-15 {
                    q = candidate; improved = true; damping = max(0.001, damping * 0.7); break
                }
                scale *= 0.5
            }
            if !improved {
                damping *= 3
                if damping > 3 { return try result(iteration + 1, "stalled_at_seed_or_joint_limits") }
            }
        }
        return try result(options.maximumIterations, "iteration_budget_exhausted")
    }

    private static func linearSolve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = zip(a, b).map { $0 + [$1] }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }),
                  abs(m[pivot][column]) > 1e-15 else { return nil }
            m.swapAt(column, pivot)
            let denominator = m[column][column]
            for j in column...n { m[column][j] /= denominator }
            for row in 0..<n where row != column {
                let multiplier = m[row][column]
                for j in column...n { m[row][j] -= multiplier * m[column][j] }
            }
        }
        let result = m.map { $0[n] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}

enum ROBKinematicFrames {
    /// Convert camera/world/board goals through an explicitly calibrated frame.
    static func targetInBase(worldFromBase: simd_double4x4, worldFromTarget: simd_double4x4) throws -> simd_double4x4 {
        guard ROBSerialChain.rigid(worldFromBase), ROBSerialChain.rigid(worldFromTarget) else {
            throw ROBKinematicsError.invalid("Target conversion requires proper rigid frames, without reflection or scale.")
        }
        return worldFromBase.inverse * worldFromTarget
    }

    /// Clutch alignment for Vision Pro / recorded controller poses. At the
    /// clutch instant the output exactly equals the measured robot tool pose.
    /// robotFromTracking includes the measured AR-world to ROB-axis alignment.
    static func controllerFromTool(robotFromTracking: simd_double4x4, trackingFromController: simd_double4x4,
                                   robotFromTool: simd_double4x4) throws -> simd_double4x4 {
        guard [robotFromTracking, trackingFromController, robotFromTool].allSatisfy(ROBSerialChain.rigid) else {
            throw ROBKinematicsError.invalid("Clutch alignment requires rigid transforms.")
        }
        return trackingFromController.inverse * robotFromTracking.inverse * robotFromTool
    }
}
