import Foundation
import simd
import Dispatch

@main struct WorkspaceDepthAlignmentFixtures {
    static func main() throws {
        let suite = "ROBWorkspaceDepthAlignmentFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = ROBWorkspaceDepthAlignment.snapshot(defaults: defaults)!
        precondition(raw.towardRobotMeters == 0)

        // A depth optical frame can face anywhere after neck pan and tilt.
        // The provisional shift must still be along ROB's base X, not the
        // camera's optical depth direction, and must preserve world height.
        var camera = simd_double4x4(simd_quatd(angle: 0.81, axis: simd_normalize(SIMD3<Double>(1, 2, -3))))
        camera.columns.3 = SIMD4(0.13, -0.04, 1.12, 1)
        let unchanged = raw.applying(to: camera)
        for column in 0..<4 { precondition(unchanged[column] == camera[column]) }
        let correction = try ROBWorkspaceDepthAlignment.setTowardRobotMeters(7 * 0.0254, defaults: defaults)
        let corrected = correction.applying(to: camera)
        precondition(abs(correction.towardRobotMeters - 0.1778) < 1e-12)
        precondition(correction.identity != raw.identity)
        precondition(ROBWorkspaceDepthAlignment.snapshot(defaults: defaults) == correction)
        for column in 0..<3 { precondition(corrected[column] == camera[column]) }
        precondition(corrected.columns.3.y == camera.columns.3.y && corrected.columns.3.z == camera.columns.3.z)
        precondition(abs(corrected.columns.3.x - camera.columns.3.x + 0.1778) < 1e-12)

        let points = [SIMD4<Double>(0.06, -0.13, 0.7, 1), SIMD4<Double>(-0.16, 0.22, 1.3, 1)]
        for point in points {
            let before = camera * point, after = corrected * point
            precondition(abs(after.x - before.x + 0.1778) < 1e-12)
            precondition(after.y == before.y && after.z == before.z && after.w == before.w)
        }
        let oldSeparation = simd_length((camera * points[1] - camera * points[0]))
        let newSeparation = simd_length((corrected * points[1] - corrected * points[0]))
        precondition(abs(oldSeparation - newSeparation) < 1e-12, "Translation distorted the observed objects")
        precondition(camera.columns.3.x == 0.13, "The raw transform was mutated")

        // Reapplying settings invalidates pending capture identity even with an
        // unchanged camera generation or an edit back to an earlier distance.
        let repeated = try ROBWorkspaceDepthAlignment.setTowardRobotMeters(0.1778, defaults: defaults)
        precondition(repeated.identity != correction.identity)
        let reset = try ROBWorkspaceDepthAlignment.setTowardRobotMeters(0, defaults: defaults)
        precondition(reset.identity != raw.identity)
        for invalid in [Double.nan, .infinity, -.infinity, -0.001, 0.301] {
            do {
                try ROBWorkspaceDepthAlignment.setTowardRobotMeters(invalid, defaults: defaults)
                preconditionFailure("Invalid translation was accepted")
            } catch ROBWorkspaceDepthAlignment.ConfigurationError.invalidTranslation { }
            precondition(ROBWorkspaceDepthAlignment.snapshot(defaults: defaults) == reset)
        }

        // Every read is a complete validated parameter revision, including
        // while another thread writes; no partially updated XYZ is exposed.
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            _ = try! ROBWorkspaceDepthAlignment.setTowardRobotMeters(Double(index % 4) / 10, defaults: defaults)
            let value = ROBWorkspaceDepthAlignment.snapshot(defaults: defaults)!
            precondition((0...0.30).contains(value.towardRobotMeters) && !value.identity.isEmpty)
        }
        for malformed: Any in ["wrong type", Data("not JSON".utf8), Data(repeating: 0, count: 1_025)] {
            defaults.set(malformed, forKey: ROBWorkspaceDepthAlignment.preferenceKey)
            precondition(ROBWorkspaceDepthAlignment.snapshot(defaults: defaults) == nil)
        }
        for object: [String: Any] in [
            ["version": 2, "towardRobotMeters": 0.1778, "revision": UUID().uuidString],
            ["version": 1, "towardRobotMeters": 0.5, "revision": UUID().uuidString],
            ["version": 1, "towardRobotMeters": 0.1778, "revision": "invalid"]
        ] {
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ROBWorkspaceDepthAlignment.preferenceKey)
            precondition(ROBWorkspaceDepthAlignment.snapshot(defaults: defaults) == nil)
        }
        print("Workspace provisional head-depth alignment fixtures passed")
    }
}
