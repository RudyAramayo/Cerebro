import Foundation
import simd

@main
enum ROBRobotGeometryFixtureTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); expect(false, message) } catch { checks += 1 }
    }
    static func near(_ a: simd_double4x4, _ b: simd_double4x4) -> Bool {
        (0..<4).allSatisfy { simd_length(a[$0] - b[$0]) < 1e-7 }
    }
    static func main() throws {
        var profile = ROBGeometryProfile.draft()
        try profile.validate()
        expect(profile.transforms().count == profile.links.count, "all frames reachable")
        let optical = profile.joints.first { $0.name == "oak_optical_mount" }!.origin.matrix
        expect(simd_distance(ROBGeometryMath.point(optical, [0, 0, 1]) - ROBGeometryMath.point(optical, [0, 0, 0]), SIMD3(1, 0, 0)) < 1e-8, "optical forward maps to body forward")
        expect(simd_distance(ROBGeometryMath.point(optical, [1, 0, 0]) - ROBGeometryMath.point(optical, [0, 0, 0]), SIMD3(0, -1, 0)) < 1e-8, "optical right maps to body right")
        expect(ROBGeometryMath.deproject(x: 320, y: 240, depthMeters: 1, fx: 600, fy: 600, cx: 320, cy: 240) == SIMD3(0, 0, 1), "principal point deprojects on optical Z")
        expect(ROBGeometryMath.deproject(x: 620, y: 540, depthMeters: 2, fx: 600, fy: 600, cx: 320, cy: 240) == SIMD3(1, 1, 2), "pixel deprojection uses supplied focal lengths")
        expect(ROBGeometryMath.deproject(x: 1, y: 1, depthMeters: 1, fx: 0, fy: 600, cx: 0, cy: 0) == nil, "missing focal calibration has no guessed fallback")
        expect(ROBGeometryMath.deproject(x: 1, y: 1, depthMeters: 0, fx: 600, fy: 600, cx: 0, cy: 0) == nil, "invalid depth rejected")

        // URDF composition order is noncommutative: parent * origin * motion.
        let index = profile.joints.firstIndex { $0.name == "neck_pan" }!
        profile.joints[index].origin.rpyRadians = [0.2, -0.3, 0.4]
        profile.previewPositions["neck_pan"] = 0.5
        let frames = profile.transforms()
        let expected = frames["lower_neck_link"]! * profile.joints[index].origin.matrix * simd_matrix4x4(simd_quatd(angle: 0.5, axis: SIMD3(0, 0, 1)))
        expect(near(frames["neck_pan_link"]!, expected), "joint rotates after its origin")
        let oldCamera = frames["oak_link"]!
        profile.previewPositions["lower_neck"] = 0.25
        expect(!near(profile.transforms()["oak_link"]!, oldCamera), "camera inherits lower-neck articulation")
        let fixedTrack = profile.transforms()["left_track_link"]!
        profile.previewPositions["left_track_drive"] = 1
        expect(near(profile.transforms()["left_track_link"]!, fixedTrack), "drive rotation does not rotate track envelope")

        let baseLength = profile.lactEndpoints().map { simd_distance($0.0, $0.1) }!
        profile.previewPositions["body_lean"] = 0.2
        let leanLength = profile.lactEndpoints().map { simd_distance($0.0, $0.1) }!
        expect(abs(baseLength - leanLength) > 0.001, "LACT endpoint distance follows lean kinematics")
        expect(leanLength.isFinite, "LACT length is finite")

        var bad = profile; bad.simulationOnly = false
        rejects("cannot load hardware-authorized profile") { try bad.validate() }
        bad = profile; bad.joints[0].axis = [0, 0, 0]
        rejects("zero axis") { try bad.validate() }
        bad = profile; bad.joints[0].origin.xyzMeters = [.nan, 0, 0]
        rejects("nonfinite origin") { try bad.validate() }
        bad = profile; bad.joints[0].parent = bad.joints[0].child
        rejects("cycle") { try bad.validate() }
        bad = profile; bad.joints[0].child = "base_link"
        rejects("root cannot be child") { try bad.validate() }
        bad = profile; bad.links[0].boxMeters = [0, 1, 1]
        rejects("empty collision geometry") { try bad.validate() }
        bad = profile; bad.scanScale = 0
        rejects("zero scan scale") { try bad.validate() }
        bad = profile; bad.previewPositions["left_joint2"] = 20
        rejects("preview outside joint limits") { try bad.validate() }
        bad = profile; bad.previewPositions["nonexistent_joint"] = 0
        rejects("unknown joint state") { try bad.validate() }
        bad = profile; bad.lact.movingLink = "missing"
        rejects("missing LACT parent") { try bad.validate() }

        // Large rotations, especially pi, defeated power iteration initialized
        // at an eigenvector orthogonal to the desired solution.
        let points: [[Double]] = [[0, 0, 0], [0.2, 0, 0], [0, 0.15, 0], [0, 0, 0.1], [0.1, 0.05, 0.12]]
        for rpy in [[0.0, 0, 0], [Double.pi, 0, 0], [0, Double.pi, 0], [0, 0, Double.pi], [0.3, -0.4, 1.2], [0.2, Double.pi / 2, -0.4]] {
            let transform = ROBGeometryOrigin(xyzMeters: [0.15, -0.2, 0.4], rpyRadians: rpy).matrix
            let landmarks = points.enumerated().map { i, p -> ROBGeometryLandmark in
                let t = ROBGeometryMath.point(transform, p)
                return .init(name: "synthetic_\(i)", localMeters: p, parentMeters: [t.x, t.y, t.z], validationOnly: i == 4)
            }
            let fit = try ROBGeometryMath.fit(landmarks)
            expect(near(fit.origin.matrix, transform), "rigid fit and RPY round trip \(rpy)")
            expect(fit.fitRMSEMeters < 1e-7 && fit.validationRMSEMeters! < 1e-7, "fit and held-out errors \(rpy)")
            var changed = landmarks; changed[4].parentMeters[0] += 0.04
            let heldout = try ROBGeometryMath.fit(changed)
            expect(near(fit.origin.matrix, heldout.origin.matrix), "held-out point never affects fit")
            expect(abs(heldout.validationRMSEMeters! - 0.04) < 1e-7, "independent error exposed")
        }
        rejects("collinear landmarks") { _ = try ROBGeometryMath.fit((0..<4).map { .init(name: "\($0)", localMeters: [Double($0), 0, 0], parentMeters: [0, Double($0), 0]) }) }
        rejects("coincident target landmarks") { _ = try ROBGeometryMath.fit(points.map { .init(name: "a", localMeters: $0, parentMeters: [0, 0, 0]) }) }
        rejects("invalid landmark vector") { _ = try ROBGeometryMath.fit([.init(name: "bad", localMeters: [0, 0], parentMeters: [0, 0, 0])]) }

        profile = .draft()
        var desired = profile.previewPositions; desired["left_joint2"] = 0.3; desired["left_joint4"] = -0.2
        let endpoint = profile.transforms(positions: desired)["left_tool"]!.columns.3
        let solution = profile.previewIK(arm: "left", target: SIMD3(endpoint.x, endpoint.y, endpoint.z))!
        expect(solution.errorMeters < 0.015, "reachable target converges")
        profile.previewPositions = solution.positions; try profile.validate()
        expect(profile.previewIK(arm: "invalid", target: .zero) == nil, "invalid arm rejected")
        expect(profile.previewIK(arm: "left", target: SIMD3(.nan, 0, 0)) == nil, "nonfinite IK target rejected")
        var alteredChain = profile
        alteredChain.joints[alteredChain.joints.firstIndex { $0.name == "left_joint2" }!].kind = "fixed"
        expect(alteredChain.previewIK(arm: "left", target: .zero) == nil, "B1 IK rejects an altered joint type")
        let unreachable = profile.previewIK(arm: "left", target: SIMD3(20, 20, 20))!
        expect(unreachable.errorMeters > 10, "unreachable target retains error, never reports success")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rob-geometry-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try ROBGeometryURDF.export(profile, vendor: nil, to: directory)
        let xml = try XMLDocument(contentsOf: directory.appendingPathComponent("rob_droid.urdf"))
        let exported = xml.rootElement()!
        expect(exported.elements(forName: "link").count == profile.links.count, "URDF link count")
        expect(exported.elements(forName: "joint").count == profile.joints.count, "URDF joint count")
        let joint = exported.elements(forName: "joint").first { $0.attribute(forName: "name")?.stringValue == "left_joint2" }!
        let expectedOrigin = profile.joints.first { $0.name == "left_joint2" }!.origin
        let rpy = joint.elements(forName: "origin").first!.attribute(forName: "rpy")!.stringValue!.split(separator: " ").map { Double($0)! }
        expect(zip(rpy, expectedOrigin.rpyRadians).allSatisfy { abs($0 - $1) < 1e-8 }, "preview and boot angles are not baked into URDF origin")
        expect(joint.elements(forName: "limit").first!.attribute(forName: "velocity")?.stringValue == "0", "export cannot imply commissioned motion limits")
        let reloaded = try ROBGeometryProfile.load(directory.appendingPathComponent("calibration.json"))
        expect(reloaded.previewPositions == profile.previewPositions, "preview q round-trips separately")
        rejects("existing bundle must not be overwritten") { try ROBGeometryURDF.export(profile, vendor: nil, to: directory) }
        expect(!profile.envelopeOverlaps().isEmpty, "uncommissioned draft shows envelope warnings")
        print("ROB geometry fixtures passed: \(checks) checks")
    }
}
