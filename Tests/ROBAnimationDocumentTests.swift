import Foundation

@main struct AnimationDocumentTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        func rejects(_ message: String, _ block: () throws -> Void) { do { try block(); fatalError(message) } catch { checks += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rob-animation-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var pose = ROBAnimationPose(name: "same name", values: ["arm.right.j2": 0.2])
        let clip = ROBAnimationClip(pose: pose, transition: 2, hold: 1)
        pose.values["arm.right.j2"] = 0.7
        expect(clip.pose.values["arm.right.j2"] == 0.2, "Sequence must own a value snapshot")
        expect(clip.pose.id != pose.id && clip.id != pose.id, "Every asset and clip gets independent identity")
        var document = ROBAnimationDocument()
        document.poses = [pose, .init(name: "same name", values: ["arm.left.j1": -0.2])]
        document.sequences = [.init(name: "A", clips: [clip])]
        try document.validate(); checks += 1
        let originalSecondID = document.poses[1].id
        document.poses.removeAll { $0.id == pose.id }
        expect(document.poses.count == 1 && document.poses[0].id == originalSecondID, "Deleting one ID preserves a duplicate name")
        let baseline = ["arm.right.j2": 0.0, "arm.left.j1": 0.8, "maestro.0": 6500.0]
        let sampled = ROBAnimationDocument.sample(document.sequences[0], at: 1, baseline: baseline)
        expect(abs(sampled["arm.right.j2"]!-0.1) < 1e-9, "Smooth midpoint")
        expect(sampled["arm.left.j1"] == 0.8 && sampled["maestro.0"] == 6500, "Sparse tracks preserve other joints")
        var second = ROBAnimationClip(pose: .init(name: "neck only", values: ["maestro.0": 7000]), transition: 2)
        second.easing = .linear
        document.sequences[0].clips.append(second)
        let sample2 = ROBAnimationDocument.sample(document.sequences[0], at: 4, baseline: baseline)
        expect(sample2["arm.right.j2"] == 0.2 && sample2["maestro.0"] == 6750, "Clip carry-forward and intervals")
        let lact = ROBAnimationSequence(name: "lean", clips: [.init(pose: .init(name: "lean", values: ["lact.speed": 30]), transition: 2)])
        expect(ROBAnimationDocument.sample(lact, at: 1, baseline: [:])["lact.speed"] == 30, "Timed LACT runs within clip")
        expect(ROBAnimationDocument.sample(lact, at: 2, baseline: [:])["lact.speed"] == 0, "Timed LACT stops at exact endpoint")
        var torsoClip = ROBAnimationClip(pose: .init(name: "circular", values: ["torso.heading": -179]), transition: 2)
        torsoClip.easing = .linear
        let torso = ROBAnimationSequence(name: "circular", clips: [torsoClip])
        expect(ROBAnimationDocument.sample(torso, at: 1, baseline: ["torso.heading":179])["torso.heading"] == 180, "Untethered torso takes shortest circular route")
        expect(ROBAnimationDocument.sample(torso, at: 1, baseline: ["torso.heading":179,"preview.torsoReference":0])["torso.heading"] == 0, "Debug torso unwinds around tracked reference")
        var invalid = document
        invalid.sequences[0].clips[0].transition = -1
        rejects("Negative timing accepted") { try invalid.validate() }
        invalid = document; invalid.poses[0].values["maestro.8"] = 6000
        rejects("Reserved relay accepted") { try invalid.validate() }
        invalid = document; invalid.poses[0].values["arm.left.j1"] = 80
        rejects("Legacy slider units accepted as radians") { try invalid.validate() }
        invalid = document; invalid.poses.append(invalid.poses[0])
        rejects("Duplicate IDs accepted") { try invalid.validate() }
        var sword = ROBAnimationPose(name: "Sword", values: ["arm.right.j1": 0.2])
        sword.previewProp = ROBAnimationPreviewProp()
        let swordClip = ROBAnimationClip(pose: sword)
        let propSequence = ROBAnimationSequence(name: "Prop preview", clips: [swordClip, second])
        expect(ROBAnimationDocument.previewProp(propSequence, at: 0)?.lengthMeters == 0.6, "Reference sword is available at the start")
        expect(ROBAnimationDocument.previewProp(propSequence, at: swordClip.duration) == nil, "Omitted prop clears at the clip boundary")
        document.poses.append(sword)
        let roundtrip = try ROBAnimationStore.decode(ROBAnimationStore.encode(document))
        expect(roundtrip == document, "Preview prop survives JSON without becoming a motor channel")
        invalid = document; invalid.poses[invalid.poses.count-1].previewProp?.lengthMeters = -1
        rejects("Invalid prop dimensions accepted") { try invalid.validate() }
        let url = root.appendingPathComponent("library.json")
        let store = ROBAnimationStore(url: url)
        var initial = document; initial.id = store.document.id; initial.revision = store.document.revision
        try store.replace(initial, expectedRevision: 0)
        expect(store.document.revision == 1, "Save increments revision")
        rejects("Stale edit overwrote library") { try store.replace(initial, expectedRevision: 0) }
        expect(store.document.revision == 1, "Conflict leaves document unchanged")
        let reopened = ROBAnimationStore(url: url)
        expect(reopened.document == store.document, "Round-trip all poses, clips, timings, masks")
        expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("previous").path), "Previous valid revision preserved")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var submitted = store.document; submitted.sequences[0].name = "LLM edit"
        let json = try JSONSerialization.jsonObject(with: ROBAnimationStore.encode(submitted))
        let request = try JSONSerialization.data(withJSONObject: ["expectedRevision": 1, "document": json])
        try request.write(to: inbox.appendingPathComponent("edit.json"))
        expect(store.processInbox().count == 1 && store.document.revision == 2 && store.document.sequences[0].name == "LLM edit", "JSON inbox uses canonical writer")
        try request.write(to: inbox.appendingPathComponent("stale.json"))
        _ = store.processInbox()
        let conflict = try JSONSerialization.jsonObject(with: Data(contentsOf: inbox.appendingPathComponent("stale.result"))) as! [String: Any]
        expect(conflict["ok"] as? Bool == false && store.document.revision == 2, "Concurrent stale JSON rejected")
        let legacy = root.appendingPathComponent("old"); try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let old: [String:Any] = ["namedKeyframes": [["name":"ready", "arm_L10_keyframe":true,"arm_L10_servo2":50.0]], "namedSequences":[]]
        let oldData = try JSONSerialization.data(withJSONObject: old)
        let oldURL = legacy.appendingPathComponent("old.keyAnim"); try oldData.write(to: oldURL)
        let migrated = ROBAnimationStore.migrate(directory: legacy)
        expect(migrated.poses[0].values["arm.right.j2"] == 0.5 && migrated.poses[0].needsReview, "Legacy scaling/physical side explicit and marked for review")
        let preserved = try Data(contentsOf: oldURL)
        expect(preserved == oldData, "Migration leaves old files untouched")
        try Data("broken".utf8).write(to: url)
        let corrupt = ROBAnimationStore(url: url)
        expect(!corrupt.canWrite && corrupt.loadError != nil, "Corrupt library cannot be silently overwritten")
        print("Animation document: \(checks) checks passed")
    }
}
