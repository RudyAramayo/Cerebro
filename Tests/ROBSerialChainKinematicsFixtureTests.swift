import Foundation
import simd

@main struct ROBSerialChainKinematicsFixtureTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ROBKinematicsError.invalid(message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw ROBKinematicsError.invalid("Expected rejection: \(message)")
    }
    static func main() throws {
        let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Tests/Fixtures/Kinematics")
        var solved = 0
        for (file, tip) in [("amber_b1.urdf", "seven_Link"), ("DualArmL.urdf", "Lseven_Link"), ("DualArmR.urdf", "Rseven_Link")] {
            let data = try Data(contentsOf: fixtureRoot.appendingPathComponent(file))
            let chain = try ROBSerialChain(urdf: data, base: "base_link", tip: tip)
            try expect(chain.movingJoints.count == 7, "Chain joint order/count lost")
            let tool = ROBSerialChain.pose(xyz: SIMD3(0.012, -0.004, 0.075), rpy: SIMD3(0.1, -0.2, 0.3))
            for sample in 0..<30 {
                let q = (0..<7).map { i in 0.6 * sin(Double(sample * 7 + i) * 0.73) }
                let seed = q.enumerated().map { i, value in value + 0.07 * cos(Double(i + sample)) }
                let target = try chain.forward(q, tipFromTool: tool)
                let solution = try chain.solve(targetInBase: target, seed: seed, tipFromTool: tool)
                try expect(solution.converged, "\(file) fixture \(sample) failed: \(solution.reason), \(solution.positionErrorMeters), \(solution.orientationErrorRadians)")
                try expect(solution.positionErrorMeters <= 0.001 && solution.orientationErrorRadians <= 0.01, "Pose tolerances failed")
                try expect(zip(solution.positions, seed).allSatisfy { abs($0 - $1) <= 0.350000001 }, "Seed continuity was violated")
                solved += 1
            }
            let zero = Array(repeating: 0.0, count: 7)
            let far = ROBSerialChain.pose(xyz: SIMD3(20, 0, 0), rpy: .zero)
            let failure = try chain.solve(targetInBase: far, seed: zero)
            try expect(!failure.converged, "Impossible 20-meter goal was reported as solved")
            try rejects("NaN seed") { _ = try chain.forward([.nan, 0, 0, 0, 0, 0, 0]) }
            try rejects("Out-of-range seed") { _ = try chain.forward([9, 0, 0, 0, 0, 0, 0]) }
            try rejects("Missing base") { _ = try ROBSerialChain(urdf: data, base: "missing", tip: tip) }
        }

        // Independent analytic FK: an origin rotates the JOINT axis, not the
        // visual mesh. This chain ends with a fixed tool and has a prismatic axis.
        let analytic = Data("""
        <robot name="analytic"><link name="base"/><link name="rotor"/><link name="slide"/><link name="tool"/>
        <joint name="rotation" type="revolute"><parent link="base"/><child link="rotor"/><origin xyz="1 2 3" rpy="0 0 1.5707963267948966"/><axis xyz="0 0 -1"/><limit lower="-3.14" upper="3.14"/></joint>
        <joint name="slide" type="prismatic"><parent link="rotor"/><child link="slide"/><axis xyz="1 0 0"/><limit lower="0" upper="1"/></joint>
        <joint name="tcp" type="fixed"><parent link="slide"/><child link="tool"/><origin xyz="0.1 0 0"/></joint></robot>
        """.utf8)
        let chain = try ROBSerialChain(urdf: analytic, base: "base", tip: "tool")
        let pose = try chain.forward([0, 0.2])
        try expect(simd_length(ROBSerialChain.translation(pose) - SIMD3(1, 2.3, 3)) < 1e-10, "Origin/axis/TCP frame convention is wrong")
        let rotated = try chain.forward([.pi / 2, 0.2])
        try expect(simd_length(ROBSerialChain.translation(rotated) - SIMD3(1.3, 2, 3)) < 1e-10, "Negative joint axis was lost")
        let solvedAnalytic = try chain.solve(targetInBase: chain.forward([0.2, 0.3]), seed: [0, 0.2])
        try expect(solvedAnalytic.converged, "Analytic rotation/translation case did not converge")
        var options = ROBSerialChain.Options(); options.maximumDisplacementFromSeed = 0.01
        let limited = try chain.solve(targetInBase: chain.forward([0.6, 0.6]), seed: [0, 0.2], options: options)
        try expect(!limited.converged && abs(limited.positions[0]) <= 0.010000001, "Branch limit was ignored")

        // 180-degree orientation error must not collapse to zero (as the
        // skew-symmetric approximation does at pi).
        let halfTurn = ROBSerialChain.pose(xyz: ROBSerialChain.translation(pose), rpy: SIMD3(.pi, 0, .pi / 2))
        let halfFailure = try chain.solve(targetInBase: halfTurn, seed: [0, 0.2])
        try expect(!halfFailure.converged && halfFailure.orientationErrorRadians > 3, "Half-turn error was hidden")

        let worldBase = ROBSerialChain.pose(xyz: SIMD3(4, 5, 6), rpy: SIMD3(0.3, 0.2, -0.5))
        let converted = try ROBKinematicFrames.targetInBase(worldFromBase: worldBase, worldFromTarget: worldBase * pose)
        try expect(simd_length(ROBSerialChain.translation(converted) - ROBSerialChain.translation(pose)) < 1e-10, "Target frame conversion changed position")
        let trackingController = ROBSerialChain.pose(xyz: SIMD3(0.1, 1.2, -0.6), rpy: SIMD3(0.5, -0.2, 0.1))
        let clutch = try ROBKinematicFrames.controllerFromTool(robotFromTracking: worldBase, trackingFromController: trackingController, robotFromTool: pose)
        let aligned = worldBase * trackingController * clutch
        try expect((0..<4).allSatisfy { simd_length(aligned[$0] - pose[$0]) < 1e-10 }, "Vision clutch introduces a jump")
        var reflected = worldBase; reflected[0] = -reflected[0]
        try rejects("Reflected tracking coordinate system") { _ = try ROBKinematicFrames.targetInBase(worldFromBase: reflected, worldFromTarget: pose) }
        try rejects("External entity") { _ = try ROBSerialChain(urdf: Data("<!DOCTYPE robot><robot/>".utf8), base: "base", tip: "tool") }
        let zeroAxis = Data(String(decoding: analytic, as: UTF8.self).replacingOccurrences(of: "0 0 -1", with: "0 0 0").utf8)
        try rejects("Zero axis") { _ = try ROBSerialChain(urdf: zeroAxis, base: "base", tip: "tool") }
        print("URDF IK fixtures passed: \(solved) six-dimensional arm targets, analytic FK/IK, fixed TCP, signs, limits, failures, frame conversion and Vision clutch")
    }
}
