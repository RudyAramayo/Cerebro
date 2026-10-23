import Foundation
import CryptoKit
import simd

struct ROBWorkspaceVoxel: Hashable, Codable {
    let x: Int
    let y: Int
    let z: Int
    func center(voxelSizeMeters size: Double) -> SIMD3<Double> {
        SIMD3((Double(x) + 0.5) * size, (Double(y) + 0.5) * size, (Double(z) + 0.5) * size)
    }
}

struct ROBWorkspaceDepthObservation: Codable {
    let sequence: UInt64
    let capturedAtMilliseconds: Double
    let recordedPanDegrees: Double?
    let recordedUpperTarget: Int?
    let cameraToRobotColumnMajor: [Double]
    let measuredSelfMaskApplied: Bool
}

/// Session-only evidence. No code writes this map to disk or promotes a neck
/// command prior into measured hand-eye registration. Unknown remains blocked.
struct ROBWorkspaceCollisionSnapshot: Codable, ROBWorkspaceCollisionMap {
    let sceneID: UUID
    let modelID: String
    let geometryID: String
    let mappingID: String
    let sessionGeneration: UInt64
    let cameraGeneration: UUID
    let createdAtMilliseconds: Double
    let oldestCapturedAtMilliseconds: Double
    let lastCapturedAtMilliseconds: Double
    let voxelSizeMeters: Double
    let registrationID: String?
    let registrationUncertaintyMeters: Double?
    let observedFrameCount: Int
    let isTruncated: Bool
    let registrationDetail: String
    let observations: [ROBWorkspaceDepthObservation]
    private let occupied: Set<ROBWorkspaceVoxel>
    private let free: Set<ROBWorkspaceVoxel>
    let fingerprint: String
    var occupiedVoxels: [ROBWorkspaceVoxel] { Array(occupied) }
    var freeVoxels: [ROBWorkspaceVoxel] { Array(free) }
    var occupiedVoxelCount: Int { occupied.count }
    var freeVoxelCount: Int { free.count }

    fileprivate init(sceneID: UUID, modelID: String, geometryID: String, mappingID: String,
        sessionGeneration: UInt64, cameraGeneration: UUID, createdAtMilliseconds: Double,
        oldestCapturedAtMilliseconds: Double, lastCapturedAtMilliseconds: Double,
        voxelSizeMeters: Double, observedFrameCount: Int, isTruncated: Bool,
        occupied: Set<ROBWorkspaceVoxel>, free: Set<ROBWorkspaceVoxel>, observations:[ROBWorkspaceDepthObservation]) {
        self.sceneID = sceneID; self.modelID = modelID; self.geometryID = geometryID; self.mappingID = mappingID
        self.sessionGeneration = sessionGeneration; self.cameraGeneration = cameraGeneration
        self.createdAtMilliseconds = createdAtMilliseconds
        self.oldestCapturedAtMilliseconds = oldestCapturedAtMilliseconds
        self.lastCapturedAtMilliseconds = lastCapturedAtMilliseconds
        self.voxelSizeMeters = voxelSizeMeters; self.observedFrameCount = observedFrameCount
        self.isTruncated = isTruncated; self.occupied = occupied; self.free = free.subtracting(occupied)
        self.observations = observations
        // Existing cameraFrame is explicitly a provisional neck/URDF prior.
        // Floor alignment does not determine a complete 6-DOF hand-eye frame.
        registrationID = nil; registrationUncertaintyMeters = nil
        registrationDetail = "Unverified neck-command camera prior; measured base/torso registration and independent validation are required before arm clearance can be certified."
        func ordered(_ values: Set<ROBWorkspaceVoxel>) -> [[Int]] {
            values.map { [$0.x, $0.y, $0.z] }.sorted {
                $0[0] != $1[0] ? $0[0] < $1[0] : $0[1] != $1[1] ? $0[1] < $1[1] : $0[2] < $1[2]
            }
        }
        let identity: [String: Any] = ["scene": sceneID.uuidString, "model": modelID, "geometry": geometryID,
            "mapping": mappingID, "session": NSNumber(value: sessionGeneration), "camera": cameraGeneration.uuidString,
            "created": createdAtMilliseconds, "oldest": oldestCapturedAtMilliseconds,
            "latest": lastCapturedAtMilliseconds, "voxel_size": voxelSizeMeters, "frames": observedFrameCount,
            "truncated": isTruncated, "registration": "unverified", "occupied": ordered(occupied), "free": ordered(self.free)]
        var bytes = (try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])) ?? Data()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        bytes.append((try? encoder.encode(observations)) ?? Data())
        fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func state(at point: SIMD3<Double>) -> ROBWorkspaceVoxelState {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite, voxelSizeMeters > 0,
              simd_length(point) < 10 else { return .unknown }
        let voxel = ROBWorkspaceVoxel(x: Int(floor(point.x / voxelSizeMeters)),
            y: Int(floor(point.y / voxelSizeMeters)), z: Int(floor(point.z / voxelSizeMeters)))
        if occupied.contains(voxel) { return .occupied }
        return !isTruncated && free.contains(voxel) ? .free : .unknown
    }
}

/// Conservative ray evidence: only valid, locally consistent stereo returns
/// mark space in front of their surface free. Never clear behind any return,
/// depth hole, known self surface, or at an image/depth discontinuity.
struct ROBWorkspaceDepthMap {
    let sceneID = UUID()
    let modelID: String
    let geometryID: String
    let mappingID: String
    let sessionGeneration: UInt64
    let cameraGeneration: UUID
    let createdAtMilliseconds: Double
    let voxelSizeMeters = 0.025
    private let maximumOccupied = 100_000
    private let maximumFree = 300_000
    private var occupied = Set<ROBWorkspaceVoxel>()
    private var free = Set<ROBWorkspaceVoxel>()
    private var oldestCapture: Double?
    private var latestCapture = 0.0
    private var lastSequence: UInt64 = 0
    private var frameCount = 0
    private var truncated = false
    private var observations: [ROBWorkspaceDepthObservation] = []

    init(modelID: String, geometryID: String, mappingID: String, sessionGeneration: UInt64,
         cameraGeneration: UUID, nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000) {
        self.modelID = modelID; self.geometryID = geometryID; self.mappingID = mappingID
        self.sessionGeneration = sessionGeneration; self.cameraGeneration = cameraGeneration
        createdAtMilliseconds = nowMilliseconds
    }

    mutating func append(width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double,
        depth: (Int, Int) -> UInt16?, cameraToRobot: simd_double4x4,
        capturedAtMilliseconds: Double, sequence: UInt64, cameraGeneration: UUID,
        nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000,
        measuredSelfBounds: [(low: SIMD3<Double>, high: SIMD3<Double>)] = [],
        cameraRegistrationVerified: Bool = false, recordedPanDegrees:Double? = nil,
        recordedUpperTarget:Int? = nil) throws {
        guard sessionGeneration > 0 else { throw ROBWorkspaceDepthMapError.acquisition("No authenticated gateway session for depth projection") }
        guard self.cameraGeneration == cameraGeneration else {
            throw ROBWorkspaceDepthMapError.acquisition("Camera generation changed (expected \(self.cameraGeneration), received \(cameraGeneration))")
        }
        guard sequence > lastSequence else {
            throw ROBWorkspaceDepthMapError.acquisition("Depth sequence did not advance (received \(sequence), previous \(lastSequence))")
        }
        guard capturedAtMilliseconds > latestCapture else {
            throw ROBWorkspaceDepthMapError.acquisition("Depth capture time did not advance (received \(capturedAtMilliseconds), previous \(latestCapture))")
        }
        let frameAge = nowMilliseconds - capturedAtMilliseconds
        guard (0...700).contains(frameAge) else {
            throw ROBWorkspaceDepthMapError.acquisition("Depth frame age \(String(format:"%.1f",frameAge)) ms is outside 0...700 ms at projection")
        }
        guard nowMilliseconds-createdAtMilliseconds <= 60_000 else {
            throw ROBWorkspaceDepthMapError.acquisition("Scene acquisition exceeded 60000 ms (elapsed \(String(format:"%.1f",nowMilliseconds-createdAtMilliseconds)) ms)")
        }
        guard (16...1920).contains(width), (16...1200).contains(height) else {
            throw ROBWorkspaceDepthMapError.acquisition("Depth dimensions \(width)x\(height) are outside the bounded mapper")
        }
        guard [fx,fy,cx,cy].allSatisfy(\.isFinite), fx > 0, fy > 0,
              (0..<Double(width)).contains(cx), (0..<Double(height)).contains(cy) else {
            throw ROBWorkspaceDepthMapError.acquisition("Invalid aligned intrinsics fx=\(fx), fy=\(fy), cx=\(cx), cy=\(cy) for \(width)x\(height)")
        }
        guard recordedPanDegrees.map({ $0.isFinite && abs($0) <= 90 }) ?? true,
              recordedUpperTarget.map({ (5000...8000).contains($0) }) ?? true else {
            throw ROBWorkspaceDepthMapError.acquisition("Recorded neck view is outside the mapper's provenance bounds")
        }
        guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { cameraToRobot[column][$0].isFinite } }) else {
            throw ROBWorkspaceDepthMapError.acquisition("Camera-to-robot matrix contains non-finite values")
        }
        guard frameCount < 256 else { throw ROBWorkspaceDepthMapError.acquisition("Scene exceeded its 256-frame acquisition bound") }
        let rotation = simd_double3x3(columns: (SIMD3(cameraToRobot.columns.0.x,cameraToRobot.columns.0.y,cameraToRobot.columns.0.z),
            SIMD3(cameraToRobot.columns.1.x,cameraToRobot.columns.1.y,cameraToRobot.columns.1.z),
            SIMD3(cameraToRobot.columns.2.x,cameraToRobot.columns.2.y,cameraToRobot.columns.2.z)))
        guard abs(simd_determinant(rotation) - 1) < 0.001,
              (0..<3).allSatisfy({ column in abs(simd_length(rotation[column]) - 1) < 0.001 }),
              abs(simd_dot(rotation[0],rotation[1])) + abs(simd_dot(rotation[1],rotation[2])) + abs(simd_dot(rotation[0],rotation[2])) < 0.001,
              abs(cameraToRobot.columns.0.w) + abs(cameraToRobot.columns.1.w) + abs(cameraToRobot.columns.2.w) < 0.001,
              abs(cameraToRobot.columns.3.w - 1) < 0.001 else {
            throw ROBWorkspaceDepthMapError.acquisition("Camera transform is not rigid/homogeneous (rotation determinant \(simd_determinant(rotation)))")
        }
        lastSequence = sequence; latestCapture = capturedAtMilliseconds
        oldestCapture = oldestCapture ?? capturedAtMilliseconds; frameCount += 1
        observations.append(.init(sequence:sequence,capturedAtMilliseconds:capturedAtMilliseconds,
            recordedPanDegrees:recordedPanDegrees,recordedUpperTarget:recordedUpperTarget,
            cameraToRobotColumnMajor:(0..<4).flatMap { column in (0..<4).map { cameraToRobot[column][$0] } },
            measuredSelfMaskApplied:cameraRegistrationVerified && !measuredSelfBounds.isEmpty))
        let origin = SIMD3(cameraToRobot.columns.3.x,cameraToRobot.columns.3.y,cameraToRobot.columns.3.z)
        // A provisional transform cannot justify erasing a table because it
        // overlaps an estimated robot hull. Retain those occupied returns.
        let selfBounds = cameraRegistrationVerified ? measuredSelfBounds : []
        let step = max(2, Int(ceil(sqrt(Double(width * height) / 12_000))))
        for y in stride(from: 1, to: height - 1, by: step) {
            for x in stride(from: 1, to: width - 1, by: step) {
                guard let mm = depth(x,y), (100...3000).contains(Int(mm)) else { continue }
                let z = Double(mm) / 1000
                let p = cameraToRobot * SIMD4((Double(x)-cx)*z/fx, (Double(y)-cy)*z/fy, z, 1)
                let endpoint = SIMD3(p.x,p.y,p.z)
                guard withinBounds(endpoint) else { continue }
                let ray = endpoint - origin, distance = simd_length(ray)
                guard distance.isFinite, distance > 0.1 else { continue }
                let direction = ray / distance
                let hitSelf = selfBounds.contains { contains(endpoint, bounds: $0, margin: 0.01) }
                if !hitSelf { markOccupied(endpoint) }
                let neighbors = [(x-1,y),(x+1,y),(x,y-1),(x,y+1)].compactMap { depth($0.0,$0.1) }
                guard neighbors.count == 4, neighbors.allSatisfy({ abs(Int($0) - Int(mm)) <= 30 }) else { continue }
                var freeUntil = distance - 0.075
                for bounds in selfBounds where !contains(origin, bounds: bounds, margin: 0) {
                    if let entry = rayEntry(origin: origin, direction: direction, bounds: bounds) {
                        freeUntil = min(freeUntil, entry - 0.025)
                    }
                }
                guard freeUntil > 0.1 else { continue }
                for along in stride(from: 0.1, to: freeUntil, by: voxelSizeMeters * 0.5) {
                    let point = origin + direction * along
                    guard withinBounds(point) else { continue }
                    if free.count < maximumFree { free.insert(voxel(point)) } else { truncated = true; break }
                }
            }
        }
    }

    func snapshot(nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000) -> ROBWorkspaceCollisionSnapshot? {
        guard frameCount >= 2, let oldestCapture else { return nil }
        return ROBWorkspaceCollisionSnapshot(sceneID: sceneID, modelID: modelID, geometryID: geometryID,
            mappingID: mappingID, sessionGeneration: sessionGeneration, cameraGeneration: cameraGeneration,
            createdAtMilliseconds: max(nowMilliseconds,latestCapture), oldestCapturedAtMilliseconds: oldestCapture,
            lastCapturedAtMilliseconds: latestCapture, voxelSizeMeters: voxelSizeMeters,
            observedFrameCount: frameCount, isTruncated: truncated, occupied: occupied, free: free, observations:observations)
    }

    private func voxel(_ point: SIMD3<Double>) -> ROBWorkspaceVoxel {
        .init(x: Int(floor(point.x / voxelSizeMeters)), y: Int(floor(point.y / voxelSizeMeters)), z: Int(floor(point.z / voxelSizeMeters)))
    }
    private func withinBounds(_ point: SIMD3<Double>) -> Bool {
        (-2...2).contains(point.x) && (-2...2).contains(point.y) && (-0.3...2.4).contains(point.z)
    }
    private mutating func markOccupied(_ point: SIMD3<Double>) {
        let center = voxel(point)
        for x in -1...1 { for y in -1...1 { for z in -1...1 {
            guard occupied.count < maximumOccupied else { truncated = true; return }
            occupied.insert(.init(x:center.x+x,y:center.y+y,z:center.z+z))
        } } }
    }
    private func contains(_ p: SIMD3<Double>, bounds: (low: SIMD3<Double>, high: SIMD3<Double>), margin: Double) -> Bool {
        (0..<3).allSatisfy { p[$0] >= bounds.low[$0] - margin && p[$0] <= bounds.high[$0] + margin }
    }
    private func rayEntry(origin: SIMD3<Double>, direction: SIMD3<Double>, bounds: (low: SIMD3<Double>, high: SIMD3<Double>)) -> Double? {
        var low = 0.0, high = Double.infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 1e-9 {
                if origin[axis] < bounds.low[axis] || origin[axis] > bounds.high[axis] { return nil }
            } else {
                let a = (bounds.low[axis] - origin[axis]) / direction[axis]
                let b = (bounds.high[axis] - origin[axis]) / direction[axis]
                low = max(low,min(a,b)); high = min(high,max(a,b))
                if high < low { return nil }
            }
        }
        return high >= low ? low : nil
    }
}

enum ROBWorkspaceDepthMapError: LocalizedError {
    case invalidFrame
    case acquisition(String)
    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "Depth map invalidated by stale/reordered frames, camera generation, scene expiry, or invalid camera geometry. Scan again without moving ROB."
        case .acquisition(let reason): return "Depth acquisition: \(reason). No arm travel was sent by this scan."
        }
    }
}
