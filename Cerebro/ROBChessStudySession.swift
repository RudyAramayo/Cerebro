import Foundation
import CryptoKit

struct ROBChessStudyRecord: Codable {
    let id: UUID
    let frameID: UUID
    let capturedAt: Date
    let reviewedAt: Date
    let source: String
    let kind: String
    let moveUCI: String?
    let fen: String
    let map: ROBChessBoardMap
    let sourceWidth: Int
    let sourceHeight: Int
    let labels: [String:String]
    let labelKind: String
    let sourceSHA256: String
    let boardSHA256: String
    let depthSHA256: String?
    let heightsMillimeters: [String:Double]?
    let supersedesRecordID: UUID?
}

struct ROBChessStudyManifest: Codable {
    let schemaVersion: Int
    let sessionID: UUID
    let createdAt: Date
    var records: [ROBChessStudyRecord]
    var trainingRecords: [ROBChessStudyRecord] {
        let replaced = Set(records.compactMap(\.supersedesRecordID))
        return records.filter { !replaced.contains($0.id) }
    }
}

final class ROBChessStudySession {
    let directory: URL
    private(set) var manifest: ROBChessStudyManifest
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601; return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()
    init(createAt directory: URL) throws {
        guard !FileManager.default.fileExists(atPath:directory.path) else {
            throw ROBChessStudyError.invalid("Choose a new session folder; existing sessions are preserved.")
        }
        self.directory = directory
        manifest = ROBChessStudyManifest(schemaVersion:1,sessionID:UUID(),createdAt:Date(),records:[])
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Self.encoder.encode(manifest).write(to:directory.appendingPathComponent("session.json"),options:.atomic)
    }
    init(open directory: URL) throws {
        self.directory = directory
        let url = directory.appendingPathComponent("session.json")
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 15_000_000 else {
            throw ROBChessStudyError.invalid("Session manifest is too large.")
        }
        manifest = try Self.decoder.decode(ROBChessStudyManifest.self,from:Data(contentsOf:url))
        guard manifest.schemaVersion == 1, manifest.records.count <= 1500,
              Set(manifest.records.map(\.id)).count == manifest.records.count else {
            throw ROBChessStudyError.invalid("Invalid session version, size, or duplicate frames.")
        }
        var previous: ROBChessPosition?
        var priorFrames: [UUID:ROBChessStudyRecord] = [:]
        for record in manifest.records {
            let position = try ROBChessPosition(fen:record.fen)
            guard record.labels == position.labels, record.labelKind == "operator_verified_square_occupancy",
                  ["baseline","move","correction","rebaseline"].contains(record.kind),
                  (64...4096).contains(record.sourceWidth), (64...4096).contains(record.sourceHeight) else {
                throw ROBChessStudyError.invalid("Session record labels or image dimensions are invalid.")
            }
            if record.kind == "move" {
                guard let previous, let move = record.moveUCI, try previous.applying(uci:move) == position else {
                    throw ROBChessStudyError.invalid("Session move does not match its prior position.")
                }
            } else if record.moveUCI != nil {
                throw ROBChessStudyError.invalid("Only a move record may contain a move.")
            }
            if record.kind == "rebaseline", let previous, previous != position {
                throw ROBChessStudyError.invalid("A rebaseline may not silently change the position.")
            }
            if let replaced = priorFrames[record.frameID] {
                guard record.kind == "correction", record.supersedesRecordID == replaced.id,
                      record.sourceSHA256 == replaced.sourceSHA256 else {
                    throw ROBChessStudyError.invalid("Duplicate frames require an explicit correction of the same image.")
                }
            } else if record.supersedesRecordID != nil {
                throw ROBChessStudyError.invalid("Correction refers to an unknown image.")
            }
            priorFrames[record.frameID] = record
            if let heights = record.heightsMillimeters,
               !heights.allSatisfy({ ROBChessPosition.square($0.key) != nil && $0.value.isFinite && (0...200).contains($0.value) }) {
                throw ROBChessStudyError.invalid("Invalid saved height measurements.")
            }
            _ = try images(for:record)
            previous = position
        }
    }
    func images(for record: ROBChessStudyRecord) throws -> (source:Data,board:Data) {
        let folder = directory.appendingPathComponent(record.id.uuidString,isDirectory:true)
        let sourceURL = folder.appendingPathComponent("source.jpg"), boardURL = folder.appendingPathComponent("board.png")
        for url in [sourceURL,boardURL] {
            let values = try url.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 40_000_000 else {
                throw ROBChessStudyError.invalid("Invalid session image file.")
            }
        }
        let source = try Data(contentsOf:sourceURL), board = try Data(contentsOf:boardURL)
        guard Self.hash(source) == record.sourceSHA256, Self.hash(board) == record.boardSHA256 else {
            throw ROBChessStudyError.invalid("A saved image changed after it was reviewed.")
        }
        if let expected = record.depthSHA256 {
            let url = folder.appendingPathComponent("depth.json")
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 50_000_000 else {
                throw ROBChessStudyError.invalid("Depth payload is too large.")
            }
            let data = try Data(contentsOf:url)
            let depth = try JSONDecoder().decode(ROBChessStudyDepth.self,from:data)
            guard Self.hash(data) == expected, depth.valid,
                  depth.width == record.sourceWidth, depth.height == record.sourceHeight else {
                throw ROBChessStudyError.invalid("Depth payload no longer matches its reviewed image.")
            }
        }
        return (source,board)
    }
    func append(frame: ROBChessStudyFrame, board: ROBChessRaster, map: ROBChessBoardMap,
                position: ROBChessPosition, kind: String, move: String?) throws {
        let priorFrame = manifest.records.last { $0.frameID == frame.id }
        guard manifest.records.count < 1500, priorFrame == nil || kind == "correction" else {
            throw ROBChessStudyError.invalid("This frame was already saved, or the session is full.")
        }
        guard ["baseline","move","correction","rebaseline"].contains(kind),
              !frame.handVisible else { throw ROBChessStudyError.invalid("Remove hands from the board before saving labels.") }
        if kind == "move" {
            guard let prior = manifest.records.last, let move,
                  try ROBChessPosition(fen:prior.fen).applying(uci:move) == position else {
                throw ROBChessStudyError.invalid("The reviewed move does not match the saved game.")
            }
        } else if move != nil { throw ROBChessStudyError.invalid("Unexpected move on a position record.") }
        if kind == "rebaseline", let prior = manifest.records.last, prior.fen != position.fen {
            throw ROBChessStudyError.invalid("Use an explicit correction to change a saved position.")
        }
        let sourceData = try frame.raster.encoded(), boardData = try board.encoded("public.png" as CFString)
        if let priorFrame, priorFrame.sourceSHA256 != Self.hash(sourceData) {
            throw ROBChessStudyError.invalid("Frame pixels changed before correction.")
        }
        let depthData = try frame.depth.map { try JSONEncoder().encode($0) }
        let heights = frame.depth?.heights(map:map,position:position).map { values in
            Dictionary(uniqueKeysWithValues:values.enumerated().compactMap { index,value in value.map { (ROBChessPosition.squareName(index),$0) } })
        }
        let record = ROBChessStudyRecord(id:UUID(),frameID:frame.id,capturedAt:frame.capturedAt,reviewedAt:Date(),
            source:frame.source,kind:kind,moveUCI:move,fen:position.fen,map:map,
            sourceWidth:frame.raster.width,sourceHeight:frame.raster.height,labels:position.labels,
            labelKind:"operator_verified_square_occupancy",sourceSHA256:Self.hash(sourceData),boardSHA256:Self.hash(boardData),
            depthSHA256:depthData.map(Self.hash),heightsMillimeters:heights,supersedesRecordID:priorFrame?.id)
        let folder = directory.appendingPathComponent(record.id.uuidString,isDirectory:true)
        var next = manifest; next.records.append(record)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        do {
            try sourceData.write(to:folder.appendingPathComponent("source.jpg"),options:.atomic)
            try boardData.write(to:folder.appendingPathComponent("board.png"),options:.atomic)
            if let depthData { try depthData.write(to:folder.appendingPathComponent("depth.json"),options:.atomic) }
            try Self.encoder.encode(record).write(to:folder.appendingPathComponent("labels.json"),options:.atomic)
            try Self.encoder.encode(next).write(to:directory.appendingPathComponent("session.json"),options:.atomic)
            manifest = next
        } catch {
            try? FileManager.default.removeItem(at:folder)
            throw error
        }
    }
}
