import Foundation
import simd

/// Commissioned separately from the scan's simulationOnly reference. No default
/// encoder offsets or provisional tool offsets are promoted to physical calibration.
struct ROBArmTeleoperationCalibration: Codable {
    struct Arm: Codable {
        let measurementID: String
        let sourceParkRadians: [Double]
        let sourceDirections: [Int]
        let canonicalAtB1Zero: [Double]
        let canonicalDirections: [Int]
        let toolMeasurementID: String
        let toolFromMeasuredTool: ROBShadowPose

        var valid: Bool {
            !measurementID.isEmpty && !toolMeasurementID.isEmpty &&
                sourceParkRadians.count == 7 && canonicalAtB1Zero.count == 7 &&
                (sourceParkRadians + canonicalAtB1Zero).allSatisfy { $0.isFinite && abs($0) <= 7 } &&
                [sourceDirections, canonicalDirections].allSatisfy { $0.count == 7 && $0.allSatisfy { abs($0) == 1 } } &&
                toolFromMeasuredTool.isValid && toolFromMeasuredTool.position.allSatisfy { abs($0) <= 0.3 }
        }
        func canonical(_ b1: [Double]) -> [Double] {
            zip(zip(b1, canonicalDirections), canonicalAtB1Zero).map { $0.0.0 * Double($0.0.1) + $0.1 }
        }
        func b1(_ canonical: [Double]) -> [Double] {
            zip(zip(canonical, canonicalAtB1Zero), canonicalDirections).map { ($0.0.0 - $0.0.1) * Double($0.1) }
        }
    }
    let schemaVersion: Int
    let modelID: String
    let geometryID: String
    let bodyMeasurementID: String
    let bodyPositions: [String: Double]
    let arms: [String: Arm]
}

final class ROBArmTeleoperationPlanner {
    let model: ROBGhostRobotModel
    let calibration: ROBArmTeleoperationCalibration
    let fingerprint: String
    private let chains: [String: ROBSerialChain]
    static var calibrationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/ArmTeleoperation/calibration.json")
    }
    init(directory: URL, calibrationURL: URL = ROBArmTeleoperationPlanner.calibrationURL) throws {
        model = try ROBGhostRobotModel(directory: directory)
        guard let data = try? Data(contentsOf: calibrationURL), data.count <= 32_768 else {
            throw ROBKinematicsError.invalid("Commission the canonical URDF motor mapping and measured tool offsets in ArmTeleoperation/calibration.json before physical teleoperation. The scan reference is preview-only.")
        }
        let calibration = try JSONDecoder().decode(ROBArmTeleoperationCalibration.self, from: data)
        self.calibration = calibration
        fingerprint = ROBGhostRobotModel.hash(data)
        let nonArm = model.joints.filter { $0.kind != "fixed" && !$0.name.hasPrefix("left_joint") && !$0.name.hasPrefix("right_joint") }
        guard calibration.schemaVersion == 1, calibration.modelID == model.modelID,
              calibration.geometryID == model.geometryID, !calibration.bodyMeasurementID.isEmpty,
              Set(calibration.arms.keys) == Set(["left", "right"]), calibration.arms.values.allSatisfy(\.valid),
              Set(calibration.bodyPositions.keys) == Set(nonArm.map(\.name)),
              nonArm.allSatisfy({ joint in calibration.bodyPositions[joint.name].map { $0.isFinite && (joint.lower...joint.upper).contains($0) } == true }) else {
            throw ROBKinematicsError.invalid("Teleoperation calibration does not match the complete URDF, geometry or measured body pose.")
        }
        let urdf = try Data(contentsOf: directory.appendingPathComponent("model.urdf"))
        var loaded: [String: ROBSerialChain] = [:]
        for arm in ["left", "right"] {
            let chain = try ROBSerialChain(urdf: urdf, base: arm + "_base_link", tip: arm + "_tool")
            guard chain.movingJoints.map(\.name) == (1...7).map({ arm + "_joint\($0)" }) else {
                throw ROBKinematicsError.invalid("Unexpected canonical arm joint order.")
            }
            loaded[arm] = chain
        }
        chains = loaded
    }

    func positions(_ measured: [String: [Double]]) throws -> [String: Double] {
        var q = model.reference.merging(calibration.bodyPositions) { _, measured in measured }
        for arm in ["left", "right"] {
            guard let b1 = measured[arm], ROBArmControlProtocol.containsTargetPositions(b1) else {
                throw ROBKinematicsError.invalid("Both arms need fresh calibrated joint feedback.")
            }
            let values = calibration.arms[arm]!.canonical(b1)
            _ = try chains[arm]!.forward(values)
            for index in 0..<7 { q[arm + "_joint\(index+1)"] = values[index] }
        }
        return q
    }
    func tool(arm: String, measured: [String: [Double]]) throws -> simd_double4x4 {
        let q = try positions(measured)
        return model.frames(q)[arm + "_tool"]! * (try ROBArmTeleoperationClutch.transform(calibration.arms[arm]!.toolFromMeasuredTool))
    }
    func solve(arm: String, target: simd_double4x4, measured: [String: [Double]]) throws -> [Double] {
        let q = try positions(measured), binding = calibration.arms[arm]!, chain = chains[arm]!
        let base = model.frames(q)[arm + "_base_link"]!
        var options = ROBSerialChain.Options()
        options.maximumSeconds = 0.025; options.maximumIterations = 70
        options.maximumDisplacementFromSeed = 0.08; options.maximumStep = 0.025
        options.positionToleranceMeters = 0.001; options.orientationToleranceRadians = 0.015
        let solution = try chain.solve(targetInBase: base.inverse * target, seed: binding.canonical(measured[arm]!),
            tipFromTool: ROBArmTeleoperationClutch.transform(binding.toolFromMeasuredTool), options: options)
        guard solution.converged else { throw ROBKinematicsError.invalid("Cartesian IK held: \(solution.reason). Release and reposition your hand.") }
        let result = binding.b1(solution.positions)
        guard ROBArmControlProtocol.containsTargetPositions(result),
              zip(result, measured[arm]!).allSatisfy({ abs($0-$1) <= 0.080001 }) else {
            throw ROBKinematicsError.invalid("Cartesian solution exceeds commissioned joint travel or continuity.")
        }
        return result
    }

    /// Full swept boxes for both arms, including any other in-flight endpoint.
    /// Comparing swept unions covers independent progress of the two trajectories.
    /// Conservative boxes may reject a physically clear pose; they never remove
    /// occupied/unknown voxels or exempt an observed overlap to make a pose pass.
    func checkPath(from measured: [String: [Double]], to goals: [String: [Double]],
                   map: any ROBWorkspaceCollisionMap, generation: UInt64, cameraGeneration: UUID,
                   now: Double) throws {
        let context = try ROBWorkspaceCollisionPlan.validateMap(map, model: model, generation: generation,
            sceneID: map.sceneID, cameraGeneration: cameraGeneration, nowMilliseconds: now)
        let start = try positions(measured), end = try positions(measured.merging(goals) { _, goal in goal })
        let travel = ["left", "right"].map { arm in (1...7).reduce(0.0) { $0 + abs(end[arm + "_joint\($1)"]! - start[arm + "_joint\($1)"]!) } }.max()!
        // A conservative 2m lever bound; reject models exceeding it below.
        let count = max(1, Int(ceil(2 * travel / 0.005)))
        guard count <= 250 else { throw ROBKinematicsError.invalid("Cartesian sweep exceeds the bounded path budget.") }
        typealias Box = (low: SIMD3<Double>, high: SIMD3<Double>)
        var swept: [String: Box] = [:]
        let started = ProcessInfo.processInfo.systemUptime
        for sample in 0...count {
            guard ProcessInfo.processInfo.systemUptime - started < 0.08 else { throw ROBKinematicsError.invalid("Cartesian clearance timed out; holding.") }
            let t = Double(sample) / Double(count)
            let q = start.mapValues { $0 }.merging(end.mapValues { $0 }) { a, b in a + (b-a)*t }
            let bounds = model.worldCollisionBounds(positions: q)
            guard bounds.count == model.hulls.count else { throw ROBKinematicsError.invalid("Missing robot collision envelopes.") }
            for (link, box) in bounds {
                guard simd_length(box.high-box.low) <= 2 else { throw ROBKinematicsError.invalid("Collision envelope exceeds the sweep lever bound.") }
                if let old = swept[link] { swept[link] = (simd_min(old.low,box.low),simd_max(old.high,box.high)) }
                else { swept[link] = box }
            }
        }
        func armLink(_ link: String) -> Bool {
            ["left", "right"].contains { link.hasPrefix($0 + "_") && (link.hasSuffix("_Link") || link == $0 + "_tool") }
        }
        let armLinks = swept.keys.filter(armLink).sorted()
        guard armLinks.count >= 16 else { throw ROBKinematicsError.invalid("Both complete arm hulls are required.") }
        // Direct mechanical neighbors only. Fixed tool/flange assemblies share a body.
        func fixedRoot(_ link: String) -> String {
            var root = link
            for _ in 0..<model.joints.count {
                guard let joint = model.joints.first(where: { $0.child == root && $0.kind == "fixed" }) else { break }
                root = joint.parent
            }
            return root
        }
        func adjacent(_ a: String, _ b: String) -> Bool {
            let a = fixedRoot(a), b = fixedRoot(b)
            return a == b || model.joints.contains { (fixedRoot($0.parent) == a && fixedRoot($0.child) == b) || (fixedRoot($0.parent) == b && fixedRoot($0.child) == a) }
        }
        guard let uncertainty = context.registrationUncertaintyMeters else {
            throw ROBKinematicsError.invalid("Measured registration uncertainty is required for teleoperation.")
        }
        let voxelAllowance = sqrt(3.0) * map.voxelSizeMeters / 2.0
        let margin = 0.025 + uncertainty + voxelAllowance
        for link in armLinks {
            let box = swept[link]!, jaw = link.hasSuffix("_tool") ? 0.04 : 0
            let extra = SIMD3<Double>(repeating: margin + jaw)
            guard map.state(inBoundsLow: box.low-extra, high: box.high+extra) == .free else {
                throw ROBKinematicsError.invalid("\(link) swept path enters occupied or unobserved workspace. Hold and scan with both arms stationary.")
            }
            for (other, obstacle) in swept where other != link && !adjacent(link, other) {
                let separation = simd_length(simd_max(.zero, simd_max(box.low-obstacle.high, obstacle.low-box.high)))
                guard separation >= 0.025 + jaw + (other.hasSuffix("_tool") ? 0.04 : 0) else {
                    throw ROBKinematicsError.invalid("Swept robot clearance is blocked between \(link) and \(other).")
                }
            }
        }
    }
}
