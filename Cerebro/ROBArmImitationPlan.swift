import Foundation

/// A human demonstration supplies lift order and relative height, never motor angles.
/// The rendition uses only the already exercised front corridor (waypoints 4–6).
struct ROBArmRendition: Codable, Equatable {
    static let revision = "hanging-front-v1"
    let id: String
    let name: String
    let corridor: String
    let levels: [Int]
    let createdAt: Date

    var isValid: Bool {
        UUID(uuidString: id) != nil && !name.isEmpty && name.count <= 80
            && corridor == Self.revision && !levels.isEmpty && levels.count <= 8
            && levels.allSatisfy { (4...6).contains($0) }
            && Self.expanded(levels).count <= 8
    }
    var waypoints: [Int] { Self.expanded(levels) }
    // Estimate excludes preparation, acknowledgements and measured settling.
    var nominalMotionSeconds: Double { Double(waypoints.count) * 4 }

    static func expanded(_ levels: [Int]) -> [Int] {
        var current = 6, result: [Int] = []
        for goal in levels + [6] {
            guard (4...6).contains(goal) else { return [] }
            while current != goal { current += goal > current ? 1 : -1; result.append(current) }
        }
        return result
    }

    static var greeting: Self {
        Self(id: "70A18AF3-2A8C-4390-B7D3-BD8172C85AFF", name: "Small front-arm greeting",
             corridor: revision, levels: [5, 6, 5, 6], createdAt: Date(timeIntervalSince1970: 0))
    }
}

struct ROBArmDemonstrationSample {
    let sequence: UInt64
    let capturedAt: Double // original epoch milliseconds, not inference completion
    let elevation: Double // [0,1], normalized camera wrist height, not joint angle
    let bodyCenterX: Double
    let bodyCenterY: Double
    let torsoHeight: Double
}

/// Stable bins and a bounded travel budget remove jitter and shorten a
/// demonstration without inventing poses or queuing every camera frame.
struct ROBArmDemonstrationBuilder {
    private var lastSequence: UInt64 = 0
    private var lastCapture: Double = 0
    private var firstCapture: Double = 0
    private var lastBody: ROBArmDemonstrationSample?
    private var candidate: Int?
    private var candidateSince: Double = 0
    private(set) var samples = 0
    private(set) var levels: [Int] = []

    mutating func append(_ sample: ROBArmDemonstrationSample, now: Double) -> Bool {
        guard sample.sequence > lastSequence, sample.capturedAt > lastCapture,
              (0...700).contains(now - sample.capturedAt),
              sample.elevation.isFinite, (0...1).contains(sample.elevation),
              [sample.bodyCenterX, sample.bodyCenterY, sample.torsoHeight].allSatisfy(\.isFinite),
              (0...1).contains(sample.bodyCenterX), (0...1).contains(sample.bodyCenterY),
              (0.12...1).contains(sample.torsoHeight),
              lastCapture == 0 || sample.capturedAt - lastCapture <= 800 else { return false }
        if let previous = lastBody {
            guard hypot(sample.bodyCenterX - previous.bodyCenterX, sample.bodyCenterY - previous.bodyCenterY) <= 0.12,
                  (0.7...1.4).contains(sample.torsoHeight / previous.torsoHeight) else { return false }
        }
        lastBody = sample
        lastSequence = sample.sequence; lastCapture = sample.capturedAt
        if samples == 0 { firstCapture = sample.capturedAt }
        samples += 1
        let level = 4 + Int((sample.elevation * 2).rounded())
        if candidate != level { candidate = level; candidateSince = sample.capturedAt }
        if sample.capturedAt - candidateSince >= 300, levels.last != level,
           levels.count < 8, ROBArmRendition.expanded(levels + [level]).count <= 8 {
            levels.append(level)
        }
        return true
    }

    func rendition(name: String) -> ROBArmRendition? {
        guard samples >= 10, lastCapture - firstCapture >= 3000, !levels.isEmpty else { return nil }
        let clip = ROBArmRendition(id: UUID().uuidString, name: String(name.prefix(80)),
            corridor: ROBArmRendition.revision, levels: levels, createdAt: Date())
        return clip.isValid ? clip : nil
    }
}

@objcMembers final class ROBArmImitationStore: NSObject {
    static let shared = ROBArmImitationStore()
    private let defaults: UserDefaults
    private let key = "ROBArmFrontCorridorRenditionsV1"
    @nonobjc init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    @nonobjc private var clips: [ROBArmRendition] {
        guard let data = defaults.data(forKey: key), data.count <= 32_768,
              let decoded = try? JSONDecoder().decode([ROBArmRendition].self, from: data) else { return [] }
        return Array(decoded.filter(\.isValid).prefix(8))
    }
    @nonobjc func save(_ clip: ROBArmRendition) -> Bool {
        guard clip.isValid, let data = try? JSONEncoder().encode(Array(([clip] + clips).prefix(8))) else { return false }
        defaults.set(data, forKey: key); return true
    }
    @nonobjc func find(_ id: String) -> ROBArmRendition? {
        id == "last" ? clips.first : clips.first { $0.id == id }
    }
    func summaries() -> [NSDictionary] {
        clips.map { ["clip_id": $0.id, "name": $0.name,
                     "rendition": "symmetric_front_corridor", "nominal_motion_seconds": $0.nominalMotionSeconds,
                     "operation_timeout_seconds": 90,
                     "requires_controller_approval": true] }
    }
}
