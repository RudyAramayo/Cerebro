import Foundation

/// One bounded fragment of the SDK's accumulated occupancy grid. It travels
/// inside an authenticated, sequenced lidar scan, never as a control message.
struct ROBRoomMapFragment: Codable, Equatable, Sendable {
    static let chunkBytes = 20_000
    let epoch: UUID
    let revision: UInt64
    let capturedAtMilliseconds: Double
    let width: Int
    let height: Int
    let resolutionX: Double
    let resolutionY: Double
    let originX: Double
    let originY: Double
    let offset: Int
    let cells: Data
    var valid: Bool {
        guard (1...2048).contains(width), (1...2048).contains(height), width*height <= 1_000_000,
              revision > 0, capturedAtMilliseconds.isFinite, capturedAtMilliseconds > 0,
              [resolutionX,resolutionY].allSatisfy({ $0.isFinite && (0.01...0.25).contains($0) }),
              [originX,originY].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }),
              offset >= 0, offset < width*height, offset % Self.chunkBytes == 0 else { return false }
        return cells.count == min(Self.chunkBytes,width*height-offset)
    }
    func encoded() throws -> Data {
        guard valid else { throw ROBRoomMapError.invalid }
        let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 28_000 else { throw ROBRoomMapError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.valid else { throw ROBRoomMapError.invalid }
        return value
    }
}
enum ROBRoomMapError: Error { case invalid }
