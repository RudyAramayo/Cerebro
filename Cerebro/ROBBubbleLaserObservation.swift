import Foundation

struct ROBBubbleLaserGrid: Codable, Equatable {
    var columns = 9
    var rows = 6
    var spacingMM = 25.4

    var targets: [Int] {
        let middleColumn = (columns - 1) / 2, middleRow = (rows - 1) / 2
        return [middleRow * columns + middleColumn, 0, columns - 1,
                rows * columns - 1, (rows - 1) * columns, middleColumn,
                middleRow * columns + columns - 1, (rows - 1) * columns + middleColumn,
                middleRow * columns]
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var valid: Bool {
        (2...30).contains(columns) && (2...30).contains(rows)
            && spacingMM.isFinite && (1...200).contains(spacingMM)
    }
}

struct ROBBubbleLaserResult: Decodable {
    struct Board: Decodable {
        let found: Bool
        let cols: Int?
        let rows: Int?
        let spacingMM: Double?
        let corners: [[Double]]?
    }
    struct Point: Codable {
        let x: Double
        let y: Double
        let matXMM: Double?
        let matYMM: Double?
    }
    struct Laser: Decodable {
        let status: String
        let usedBackground: Bool
        let detail: String
        let point: Point?
    }
    let width: Int
    let height: Int
    let board: Board
    let laser: Laser

    func targetErrorMM(grid: ROBBubbleLaserGrid, target: Int) -> Double? {
        guard grid.valid, target >= 0, target < grid.columns * grid.rows,
              let point = laser.point, let x = point.matXMM, let y = point.matYMM,
              x.isFinite, y.isFinite else { return nil }
        return hypot(x - Double(target % grid.columns) * grid.spacingMM,
                     y - Double(target / grid.columns) * grid.spacingMM)
    }

    func recordingProblem(grid: ROBBubbleLaserGrid, target: Int, settled: Bool) -> String? {
        guard grid.valid, board.found, board.cols == grid.columns, board.rows == grid.rows,
              board.spacingMM == grid.spacingMM,
              board.corners?.count == grid.columns * grid.rows else { return "Mark and detect the grid first." }
        guard laser.usedBackground, laser.status == "found", let point = laser.point,
              point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < Double(width), point.y < Double(height)
        else { return "Detect one unambiguous dot using the laser-off reference." }
        guard let error = targetErrorMM(grid: grid, target: target), error <= grid.spacingMM / 4
        else { return "Align the laser within a quarter square of the highlighted intersection, then detect again." }
        guard settled else { return "Check the captured dot and confirm the servos had settled." }
        return nil
    }
}

/// Observations preserve actual detected coordinates, rather than snapping the
/// dot to the requested grid intersection. No fitted transform is activated here.
struct ROBBubbleLaserObservation: Encodable {
    let schemaVersion = 1
    let sessionID: UUID
    let passID: UUID
    let passName: String
    let frameID: UUID
    let referenceFrameID: UUID
    let capturedAt: Date
    let referenceCapturedAt: Date
    let recordedAt: Date
    let grid: ROBBubbleLaserGrid
    let markedCornersPixels: [[Double]]
    let targetColumn: Int
    let targetRow: Int
    let targetErrorMM: Double
    let laser: ROBBubbleLaserResult.Point
    let pan: Int
    let tilt: Int
    let panChannel: Int
    let tiltChannel: Int
    let neck: [Int]
    let pulseUnit = "quarter_microsecond_command_not_encoder"
    let neckOrder = ["neck_pan", "lower_neck_tilt", "upper_neck_tilt"]
    let rgbWidth: Int
    let rgbHeight: Int
    let intrinsicsFXFYCXCY: [Double]?
    let laserDepthMM: Double?
    let operatorConfirmedSettled: Bool
}

enum ROBBubbleLaserArchive {
    /// A directory rename exposes a complete observation or nothing. Original
    /// frames and detector output remain available for later fitting/review.
    static func save(_ observation: ROBBubbleLaserObservation, in sessionURL: URL,
                     image: Data, reference: Data, analysis: Data,
                     overlay: Data, mask: Data) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let pending = sessionURL.appendingPathComponent(".pending-\(token)", isDirectory: true)
        let final = sessionURL.appendingPathComponent("sample-\(token)", isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: pending) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (name, data) in [("observation.json", try encoder.encode(observation)),
                             ("image.png", image), ("laser-off.png", reference),
                             ("analysis.json", analysis), ("overlay.png", overlay), ("mask.png", mask)] {
            try data.write(to: pending.appendingPathComponent(name), options: .atomic)
        }
        try fm.moveItem(at: pending, to: final)
        return final
    }
}
