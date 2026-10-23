import Foundation
import simd
import Dispatch

@main struct WorkspaceDepthAlignmentFixtures {
    static func main() throws {
        let suite = "ROBWorkspaceDepthAlignmentFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = ROBWorkspaceDepthAlignment.snapshot(defaults: defaults)!
        precondition(raw.towardRobotMeters == 0 && raw.downwardPitchDegrees == 0)

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

        // Older persisted revisions contain only the translation. They must
        // load with zero added pitch, preserving the previously applied shift.
        defaults.set(try JSONSerialization.data(withJSONObject: ["version": 1,
            "towardRobotMeters": 0.1778, "revision": UUID().uuidString]), forKey: ROBWorkspaceDepthAlignment.preferenceKey)
        let legacy = ROBWorkspaceDepthAlignment.snapshot(defaults: defaults)!
        precondition(legacy.towardRobotMeters == 0.1778 && legacy.downwardPitchDegrees == 0)
        let pitched = try ROBWorkspaceDepthAlignment.setAlignment(towardRobotMeters: 0.1778,
            downwardPitchDegrees: 15, defaults: defaults)
        precondition(pitched.identity != legacy.identity && pitched.downwardPitchDegrees == 15)
        precondition(ROBWorkspaceDepthAlignment.snapshot(defaults: defaults) == pitched)

        // Calibrated optical convention: camera X is right, Y is down, and Z
        // is forward. Adding downward pitch must lower the sightline even
        // after neck pan and existing neck tilt, rotating about the lens.
        let optical = simd_double4x4(columns: (SIMD4(0, -1, 0, 0), SIMD4(0, 0, -1, 0),
            SIMD4(1, 0, 0, 0), SIMD4(0.13, -0.04, 1.12, 1)))
        for pan in [-45.0, 0, 45] {
            let yaw = simd_double4x4(simd_quatd(angle: pan * .pi / 180, axis: SIMD3(0, 0, 1)))
            let neckTilt = simd_double4x4(simd_quatd(angle: 12 * .pi / 180, axis: SIMD3(0, 1, 0)))
            let rawCamera = yaw * neckTilt * optical
            let pitchOnly = pitched.applyingPitch(to: rawCamera)
            precondition(pitchOnly.columns.3 == rawCamera.columns.3, "Pitch moved the camera lens")
            precondition(abs(pitchOnly.columns.2.z + sin(27 * .pi / 180)) < 1e-12,
                "Added camera pitch points the wrong way")
            let direction = pitchOnly.columns.2
            precondition(abs(atan2(direction.y, direction.x) - pan * .pi / 180) < 1e-12,
                "Pitch changed neck pan")
            let placed = pitched.applying(to: rawCamera)
            precondition(abs(placed.columns.3.x - rawCamera.columns.3.x + 0.1778) < 1e-12)
            precondition(placed.columns.3.y == rawCamera.columns.3.y && placed.columns.3.z == rawCamera.columns.3.z)
            let beforeDistance = simd_length(rawCamera * points[1] - rawCamera * points[0])
            let afterDistance = simd_length(placed * points[1] - placed * points[0])
            precondition(abs(beforeDistance-afterDistance) < 1e-12, "Pitch distorted observed object geometry")
        }
        let shiftedPitched = try ROBWorkspaceDepthAlignment.setTowardRobotMeters(0.15, defaults: defaults)
        precondition(shiftedPitched.downwardPitchDegrees == 15 && shiftedPitched.towardRobotMeters == 0.15)
        let repitched = try ROBWorkspaceDepthAlignment.setDownwardPitchDegrees(10, defaults: defaults)
        precondition(repitched.downwardPitchDegrees == 10 && repitched.towardRobotMeters == 0.15)
        for invalid in [Double.nan, .infinity, -.infinity, -0.001, 30.001] {
            do {
                try ROBWorkspaceDepthAlignment.setDownwardPitchDegrees(invalid, defaults: defaults)
                preconditionFailure("Invalid camera pitch was accepted")
            } catch ROBWorkspaceDepthAlignment.ConfigurationError.invalidPitch { }
            precondition(ROBWorkspaceDepthAlignment.snapshot(defaults: defaults) == repitched)
        }
        _ = try ROBWorkspaceDepthAlignment.setAlignment(towardRobotMeters: 0, downwardPitchDegrees: 0, defaults: defaults)

        // Every read is a complete validated parameter revision, including
        // while another thread writes; no partially updated XYZ is exposed.
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            _ = try! ROBWorkspaceDepthAlignment.setAlignment(towardRobotMeters: Double(index % 4) / 10,
                downwardPitchDegrees: Double(index % 4) * 10, defaults: defaults)
            let value = ROBWorkspaceDepthAlignment.snapshot(defaults: defaults)!
            precondition((0...0.30).contains(value.towardRobotMeters) && !value.identity.isEmpty)
            precondition(abs(value.downwardPitchDegrees-value.towardRobotMeters * 100) < 1e-12,
                "A read combined parameters from different revisions")
        }
        for malformed: Any in ["wrong type", Data("not JSON".utf8), Data(repeating: 0, count: 1_025)] {
            defaults.set(malformed, forKey: ROBWorkspaceDepthAlignment.preferenceKey)
            precondition(ROBWorkspaceDepthAlignment.snapshot(defaults: defaults) == nil)
        }
        for object: [String: Any] in [
            ["version": 2, "towardRobotMeters": 0.1778, "revision": UUID().uuidString],
            ["version": 1, "towardRobotMeters": 0.5, "revision": UUID().uuidString],
            ["version": 1, "towardRobotMeters": 0.1778, "revision": "invalid"],
            ["version": 1, "towardRobotMeters": 0.1778, "downwardPitchDegrees": 31, "revision": UUID().uuidString],
            ["version": 1, "towardRobotMeters": 0.1778, "downwardPitchDegrees": -1, "revision": UUID().uuidString]
        ] {
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ROBWorkspaceDepthAlignment.preferenceKey)
            precondition(ROBWorkspaceDepthAlignment.snapshot(defaults: defaults) == nil)
        }
        print("Workspace provisional head-depth alignment fixtures passed")
    }
}
