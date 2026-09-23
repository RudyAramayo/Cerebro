import Foundation

/// The small, physically exercised hanging-to-front corridor. These are Amber
/// hanging-frame coordinates, NOT B1/URDF angles or a seven-joint calibration.
/// The folded endpoint in the calibration notebook has no validated route.
enum ROBArmRoutinePlan {
    static let startupDefaultsKey = "ROBCalibrateArmsOnStartup"
    static let tolerance = 0.025
    static let segmentSeconds = 4.0
    static let rightWaypoints: [[Double]] = [
        [0, 0, 0, 0, 0, 0, 0],
        [0, -0.15, 0, 0, 0, 0, 0],
        [0.15, -0.30, 0, 0, 0, 0, 0],
        [0.30, -0.45, 0, 0, 0, 0, 0],
        [0.45, -0.60, 0, 0, 0, 0, 0],
        [0.75, -0.60, 0, 0, 0, 0, 0],
        [1.05, -0.60, 0, 0, 0, 0, 0],
    ]

    static func target(index: Int, physicalLeft: Bool) -> [Double]? {
        guard rightWaypoints.indices.contains(index) else { return nil }
        return rightWaypoints[index].map { physicalLeft ? -$0 : $0 }
    }

    static func near(_ measured: [Double], _ target: [Double], tolerance: Double = tolerance) -> Bool {
        measured.count == 7 && target.count == 7
            && zip(measured, target).allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) <= tolerance }
    }

    /// Locate only the exercised polyline, including a stopped mid-segment
    /// position. An arbitrary folded pose must never be interpolated to zero.
    static func progress(_ positions: [Double], physicalLeft: Bool) -> Double? {
        guard positions.count == 7, positions.allSatisfy(\.isFinite) else { return nil }
        let q = positions.map { physicalLeft ? -$0 : $0 }
        for index in rightWaypoints.indices where near(q, rightWaypoints[index]) { return Double(index) }
        for index in 0 ..< rightWaypoints.count - 1 {
            let a = rightWaypoints[index], b = rightWaypoints[index + 1]
            let delta = zip(a, b).map { $1 - $0 }
            let square = delta.reduce(0) { $0 + $1 * $1 }
            let dot = zip(zip(q, a), delta).reduce(0.0) { $0 + ($1.0.0 - $1.0.1) * $1.1 }
            let fraction = max(0, min(1, dot / square))
            let projected = zip(a, delta).map { $0 + fraction * $1 }
            if near(q, projected) { return Double(index) + fraction }
        }
        return nil
    }

    static func route(from positions: [Double], physicalLeft: Bool, hanging: Bool) -> [Int]? {
        guard let p = progress(positions, physicalLeft: physicalLeft) else { return nil }
        if hanging {
            let next = Int(ceil(p)) - 1
            return next < 0 ? [] : Array(stride(from: next, through: 0, by: -1))
        }
        let next = Int(floor(p)) + 1
        return next >= rightWaypoints.count ? [] : Array(next ..< rightWaypoints.count)
    }
}

/// Settling is derived from distinct measured positions. The Amber velocity
/// field is unavailable on this hardware and must not be fabricated as zero.
struct ROBArmRoutineSettler {
    private var previousSequence: UInt64 = 0
    private var previous: [Double]?
    private var firstStableAt: TimeInterval?
    private var samples = 0
    private var settled = false

    mutating func observe(sequence: UInt64, positions: [Double], target: [Double], now: TimeInterval) -> Bool {
        guard sequence > previousSequence else { return settled }
        previousSequence = sequence
        defer { previous = positions }
        guard ROBArmRoutinePlan.near(positions, target),
              previous.map({ ROBArmRoutinePlan.near(positions, $0, tolerance: 0.004) }) == true else {
            firstStableAt = nil; samples = 0; settled = false; return false
        }
        if firstStableAt == nil { firstStableAt = now }
        samples += 1
        settled = samples >= 3 && now - (firstStableAt ?? now) >= 0.15
        return settled
    }
}

/// Read-only visual evidence. Unknown/occluded facts are false, never inferred
/// from a commanded arm position. No numeric joint target comes from a model.
struct ROBArmRoutineObservation: Decodable {
    let pathVisible: Bool
    let pathClear: Bool
    let hanging: Bool
    let armsInFront: Bool
    let leftJawEmpty: Bool
    let rightJawEmpty: Bool
    let leftObjectBetweenJaws: Bool
    let rightObjectBetweenJaws: Bool
    let leftJawOpen: Bool
    let rightJawOpen: Bool
    let leftJawClosedOnObject: Bool
    let rightJawClosedOnObject: Bool
    let handsClear: Bool
    let confidence: Double

    var permitsMotion: Bool {
        confidence.isFinite && (0.9 ... 1).contains(confidence) && pathVisible && pathClear && handsClear
    }
    var permitsCalibration: Bool { permitsMotion && armsInFront && leftJawEmpty && rightJawEmpty }
    var graspArm: String? {
        guard permitsMotion, armsInFront else { return nil }
        if leftObjectBetweenJaws && !rightObjectBetweenJaws && leftJawOpen { return "right" }
        if rightObjectBetweenJaws && !leftObjectBetweenJaws && rightJawOpen { return "left" }
        return nil
    }
}
