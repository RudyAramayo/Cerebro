import Foundation

/// Canonical authoring format. Arm angles are Amber vendor radians, never
/// legacy slider units or URDF angles. Missing channels mean “leave alone”.
struct ROBAnimationChannel: Codable, Equatable {
    let id: String
    let name: String
    let group: String
    let unit: String
    let minimum: Double
    let maximum: Double
    let defaultValue: Double
    static let all: [Self] = {
        var result: [Self] = []
        for side in ["right", "left"] {
            for joint in 1...7 {
                let limit = ROBArmJointLimits.radians[joint - 1]
                result.append(.init(id: "arm.\(side).j\(joint)", name: "\(side.capitalized) J\(joint)",
                    group: "\(side.capitalized) arm", unit: "rad", minimum: limit.lowerBound,
                    maximum: limit.upperBound, defaultValue: 0))
            }
        }
        for channel in [0, 1, 2, 4, 5, 10, 11, 12, 13, 14, 15, 16, 17] {
            let neck = [0: "Neck pan", 1: "Lower neck", 2: "Upper neck"][channel]
            result.append(.init(id: "maestro.\(channel)", name: "Ch \(channel)" + (neck.map { " · \($0)" } ?? ""),
                group: neck == nil ? "Maestro" : "Neck", unit: "¼ µs", minimum: 4000, maximum: 8000, defaultValue: 6000))
        }
        result.append(.init(id: "torso.heading", name: "Torso heading", group: "Body", unit: "° to base", minimum: -3600, maximum: 3600, defaultValue: 0))
        result.append(.init(id: "lact.speed", name: "LACT speed", group: "Body", unit: "% timed", minimum: -100, maximum: 100, defaultValue: 0))
        return result
    }()
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

enum ROBAnimationEase: String, Codable, CaseIterable {
    case linear, smooth
    func fraction(_ t: Double) -> Double {
        let x = min(1, max(0, t)); return self == .smooth ? x*x*(3-2*x) : x
    }
}

struct ROBAnimationPose: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var values: [String: Double]
    var role: String? = nil
    var note = ""
    var needsReview = false
}

struct ROBAnimationClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var sourcePoseID: UUID?
    // A value snapshot, not a reference into the pose library.
    var pose: ROBAnimationPose
    var transition: Double = 2
    var hold: Double = 0
    var easing: ROBAnimationEase = .smooth
    init(pose: ROBAnimationPose, transition: Double = 2, hold: Double = 0) {
        sourcePoseID = pose.id; self.pose = pose; self.pose.id = UUID()
        self.transition = transition; self.hold = hold
    }
    var duration: Double { transition + hold }
}

struct ROBAnimationSequence: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var clips: [ROBAnimationClip] = []
    var duration: Double { clips.reduce(0) { $0 + $1.duration } }
}

struct ROBAnimationDocument: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var revision = 0
    var poses: [ROBAnimationPose] = []
    var sequences: [ROBAnimationSequence] = []
    var migrationNotes: [String] = []
    static let roles = ["grasp.horizontal.right", "grasp.vertical.right", "grasp.horizontal.left", "grasp.vertical.left"]

    func validate() throws {
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw ROBAnimationError.invalid(message) } }
        try check(schemaVersion == 1, "Unsupported animation schema \(schemaVersion).")
        try check(revision >= 0, "Invalid document revision.")
        try check(poses.count <= 10000 && sequences.count <= 1000, "Animation library is too large.")
        var ids = Set<UUID>()
        func unique(_ id: UUID) throws { try check(ids.insert(id).inserted, "Duplicate stable ID \(id).") }
        func pose(_ value: ROBAnimationPose) throws {
            try unique(value.id)
            try check(!value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.name.count <= 200, "A pose needs a name of 1–200 characters.")
            try check(value.note.count <= 10000, "Pose note is too long.")
            try check(value.role == nil || Self.roles.contains(value.role!), "Unknown grasp-ready role.")
            for (id, number) in value.values {
                guard let channel = ROBAnimationChannel.byID[id] else { throw ROBAnimationError.invalid("Unknown or reserved channel: \(id).") }
                try check(number.isFinite && (channel.minimum...channel.maximum).contains(number), "\(channel.name) must be \(channel.minimum)…\(channel.maximum) \(channel.unit).")
            }
        }
        var roles = Set<String>()
        for p in poses {
            try pose(p)
            if let role = p.role { try check(roles.insert(role).inserted, "More than one pose is assigned to \(role).") }
        }
        for sequence in sequences {
            try unique(sequence.id)
            try check(!sequence.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sequence.name.count <= 200, "A sequence needs a name of 1–200 characters.")
            try check(sequence.clips.count <= 10000, "Too many clips in a sequence.")
            for clip in sequence.clips {
                try unique(clip.id); try pose(clip.pose)
                try check(clip.transition.isFinite && (0.2...600).contains(clip.transition), "Transition must be 0.2–600 seconds.")
                try check(clip.hold.isFinite && (0...600).contains(clip.hold), "Hold must be 0–600 seconds.")
            }
            try check(sequence.duration <= 86400, "A sequence may not exceed 24 hours.")
        }
    }

    /// Timeline evaluation uses a caller-supplied baseline. Omitted joints
    /// retain their previous values. Timed LACT demand ends at each clip edge.
    static func sample(_ sequence: ROBAnimationSequence, at time: Double, baseline: [String: Double]) -> [String: Double] {
        var result = baseline
        result["lact.speed"] = 0
        var remaining = max(0, time)
        for clip in sequence.clips {
            let f = clip.easing.fraction(remaining / clip.transition)
            for (channel, target) in clip.pose.values where channel != "lact.speed" {
                // Without a known start, show the target and label the preview
                // as a reference estimate; never invent a hardware start.
                let start = result[channel] ?? target
                let destination: Double
                if channel == "torso.heading" {
                    func wrap(_ angle: Double) -> Double {
                        let value = (angle+180).truncatingRemainder(dividingBy: 360)
                        return (value < 0 ? value+360 : value)-180
                    }
                    let reference = baseline["preview.torsoReference"] ?? start
                    destination = reference + wrap(target-wrap(reference))
                } else { destination = target }
                result[channel] = start + (destination - start) * f
            }
            if remaining < clip.duration {
                result["lact.speed"] = clip.pose.values["lact.speed"] ?? 0
                return result
            }
            remaining -= clip.duration
        }
        result["lact.speed"] = 0
        return result
    }
}

enum ROBAnimationError: LocalizedError {
    case invalid(String), conflict(Int)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .conflict(let revision): return "Library changed to revision \(revision). Reload before applying this edit; your draft has been kept."
        }
    }
}

/// Single writer shared by AppKit and the JSON inbox. Atomic replace protects
/// against interrupted saves. Failed decoding never falls back to an empty save.
final class ROBAnimationStore {
    let url: URL
    private(set) var document: ROBAnimationDocument
    private(set) var loadError: String?
    private(set) var canWrite = true
    init(url: URL, legacyDirectory: URL? = nil) {
        self.url = url; document = ROBAnimationDocument()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                document = try Self.decode(Data(contentsOf: url)); return
            }
            if let legacyDirectory { document = Self.migrate(directory: legacyDirectory) }
            try document.validate()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(document).write(to: url, options: .atomic)
        } catch { loadError = error.localizedDescription; canWrite = false }
    }
    static func decode(_ data: Data) throws -> ROBAnimationDocument {
        guard data.count <= 16_000_000 else { throw ROBAnimationError.invalid("Animation JSON exceeds 16 MB.") }
        let value = try JSONDecoder().decode(ROBAnimationDocument.self, from: data)
        try value.validate(); return value
    }
    static func encode(_ document: ROBAnimationDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
    func replace(_ proposed: ROBAnimationDocument, expectedRevision: Int) throws {
        guard canWrite else { throw ROBAnimationError.invalid(loadError ?? "Library is read-only after a load failure.") }
        let disk = try Self.decode(Data(contentsOf: url))
        guard disk.id == document.id, disk.revision == document.revision, disk == document else {
            document = disk; throw ROBAnimationError.conflict(disk.revision)
        }
        guard expectedRevision == document.revision, proposed.revision == expectedRevision, proposed.id == document.id else {
            throw ROBAnimationError.conflict(document.revision)
        }
        var next = proposed
        next.revision += 1
        try next.validate()
        // Keep one previous valid version without ever touching legacy .keyAnim.
        try Self.encode(document).write(to: url.appendingPathExtension("previous"), options: .atomic)
        try Self.encode(next).write(to: url, options: .atomic)
        document = next
    }
    func reload() throws {
        let next = try Self.decode(Data(contentsOf: url)); document = next; canWrite = true; loadError = nil
    }

    /// LLMs submit the exact same schema with an expected revision. Processing
    /// is main-thread serialized with UI edits and never starts playback.
    func processInbox() -> [String] {
        let directory = url.deletingLastPathComponent().appendingPathComponent("inbox", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        struct Request: Decodable { let expectedRevision: Int; let document: ROBAnimationDocument }
        var reports: [String] = []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let resultURL = file.deletingPathExtension().appendingPathExtension("result")
            // A crash after writing the result must not apply the request again.
            if FileManager.default.fileExists(atPath: resultURL.path) { try? FileManager.default.removeItem(at: file); continue }
            var status: [String: Any]
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= 16_000_000 else { throw ROBAnimationError.invalid("Request is too large.") }
                let request = try JSONDecoder().decode(Request.self, from: data)
                try replace(request.document, expectedRevision: request.expectedRevision)
                status = ["ok": true, "revision": document.revision, "detail": "Saved. No robot motion."]
                reports.append("JSON edit saved at revision \(document.revision).")
            } catch {
                status = ["ok": false, "revision": document.revision, "detail": error.localizedDescription]
                reports.append(error.localizedDescription)
            }
            do {
                try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL, options: .atomic)
                try FileManager.default.removeItem(at: file)
            } catch { reports.append("Could not acknowledge inbox request: \(error.localizedDescription)") }
        }
        return reports
    }

    static func migrate(directory: URL) -> ROBAnimationDocument {
        var document = ROBAnimationDocument()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.pathExtension == "keyAnim" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= 16_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ROBAnimationError.invalid("Invalid legacy JSON") }
                func pose(_ old: [String: Any]) -> ROBAnimationPose {
                    var p = ROBAnimationPose(name: old["name"] as? String ?? "Imported pose", values: [:])
                    if p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.name = "Imported pose" }
                    p.name = String(p.name.prefix(200)); p.needsReview = true
                    p.note = "Imported from \(file.lastPathComponent). Legacy slider values ÷100 → vendor radians; verify before robot playback. Legacy files preserved."
                    for (legacy, physical) in [("L10", "right"), ("R11", "left")] where old["arm_\(legacy)_keyframe"] as? Bool == true {
                        for j in 1...7 {
                            if let value = old["arm_\(legacy)_servo\(j)"] as? Double { p.values["arm.\(physical).j\(j)"] = value / 100 }
                        }
                    }
                    if old["head_keyframe"] as? Bool == true {
                        for (field, id) in [("head_neckRotation", "maestro.0"), ("head_lowerNeck", "maestro.1"), ("head_upperNeck", "maestro.2")] {
                            if let value = old[field] as? Double { p.values[id] = value }
                        }
                    }
                    // Old body fields never had a working capture/playback path;
                    // their units and reference are not inferred during migration.
                    if old["LACT_keyframe"] as? Bool == true || old["torsoRotation_keyframe"] as? Bool == true {
                        p.note += " Legacy body fields require recapture with explicit units."
                    }
                    for (id, value) in p.values {
                        guard let c = ROBAnimationChannel.byID[id], value.isFinite && (c.minimum...c.maximum).contains(value) else {
                            p.values.removeValue(forKey: id); p.note += " Invalid \(id) omitted."; continue
                        }
                    }
                    return p
                }
                document.poses += (root["namedKeyframes"] as? [[String: Any]] ?? []).map(pose)
                for old in root["namedSequences"] as? [[String: Any]] ?? [] {
                    var sequence = ROBAnimationSequence(name: old["name"] as? String ?? "Imported sequence")
                    if sequence.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sequence.name = "Imported sequence" }
                    sequence.name = String(sequence.name.prefix(200))
                    for key in old["keyframes"] as? [[String: Any]] ?? [] {
                        let transition = max(key["arm_L10_cmd_time"] as? Double ?? 20, key["arm_R11_cmd_time"] as? Double ?? 20) / 10
                        let hold = max(key["arm_L10_cmd_sleep"] as? Double ?? 0, key["arm_R11_cmd_sleep"] as? Double ?? 0) / 10
                        var clip = ROBAnimationClip(pose: pose(key), transition: min(600, max(0.2, transition)), hold: min(600, max(0, hold)))
                        clip.sourcePoseID = nil; sequence.clips.append(clip)
                    }
                    document.sequences.append(sequence)
                }
                document.migrationNotes.append("Imported \(file.lastPathComponent); original unchanged. Imported values require review.")
            } catch { document.migrationNotes.append("Could not import \(file.lastPathComponent): \(error.localizedDescription)") }
        }
        return document
    }
}
