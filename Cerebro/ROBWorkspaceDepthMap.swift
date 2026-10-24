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

private struct ROBWorkspaceOccupiedSampleBounds: Codable {
    var low: SIMD3<Double>
    var high: SIMD3<Double>
}

struct ROBWorkspaceDepthObservation: Codable {
    let sequence: UInt64
    let capturedAtMilliseconds: Double
    let recordedPanDegrees: Double?
    let recordedUpperTarget: Int?
    let recordedLowerTarget: Int?
    let registrationID: String?
    let registrationUncertaintyMeters: Double?
    let fixedHeadScope: ROBFixedHeadRegistrationScope?
    let cameraToRobotColumnMajor: [Double]
    let measuredSelfMaskApplied: Bool
    var estimatedDepthHypothesisID: String? = nil
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
    private let capturedRegistrationID: String?
    let bodyMotionIdentity: String
    var registrationID: String? {
        bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity ? capturedRegistrationID : nil
    }
    let registrationUncertaintyMeters: Double?
    let observedFrameCount: Int
    let isTruncated: Bool
    let registrationDetail: String
    let observations: [ROBWorkspaceDepthObservation]
    private let occupied: Set<ROBWorkspaceVoxel>
    private let free: Set<ROBWorkspaceVoxel>
    private let occupiedSamples: [ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds]
    let fingerprint: String
    var occupiedVoxels: [ROBWorkspaceVoxel] { Array(occupied) }
    var freeVoxels: [ROBWorkspaceVoxel] { Array(free) }
    var occupiedVoxelCount: Int { occupied.count }
    var freeVoxelCount: Int { free.count }

    fileprivate init(sceneID: UUID, modelID: String, geometryID: String, mappingID: String,
        sessionGeneration: UInt64, cameraGeneration: UUID, createdAtMilliseconds: Double,
        oldestCapturedAtMilliseconds: Double, lastCapturedAtMilliseconds: Double,
        voxelSizeMeters: Double, observedFrameCount: Int, isTruncated: Bool,
        registrationID: String?, registrationUncertaintyMeters: Double?,bodyMotionIdentity:String,
        occupied: Set<ROBWorkspaceVoxel>, free: Set<ROBWorkspaceVoxel>,
        occupiedSamples:[ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds], observations:[ROBWorkspaceDepthObservation]) {
        self.sceneID = sceneID; self.modelID = modelID; self.geometryID = geometryID; self.mappingID = mappingID
        self.sessionGeneration = sessionGeneration; self.cameraGeneration = cameraGeneration
        self.createdAtMilliseconds = createdAtMilliseconds
        self.oldestCapturedAtMilliseconds = oldestCapturedAtMilliseconds
        self.lastCapturedAtMilliseconds = lastCapturedAtMilliseconds
        self.voxelSizeMeters = voxelSizeMeters; self.observedFrameCount = observedFrameCount
        self.isTruncated = isTruncated; self.occupied = occupied; self.free = free.subtracting(occupied)
        self.occupiedSamples = occupiedSamples
        self.observations = observations
        self.capturedRegistrationID = registrationID; self.registrationUncertaintyMeters = registrationUncertaintyMeters
        self.bodyMotionIdentity=bodyMotionIdentity
        if let registrationID, let uncertainty = registrationUncertaintyMeters {
            registrationDetail = String(format:"Measured fixed-head optical-to-robot fit %@; local error allowance %.1f mm. Valid only within recorded pose, camera and measured volume.",registrationID,uncertainty*1000)
        } else {
            registrationDetail = "Unverified neck-command camera prior; measured base/torso registration and independent validation are required before arm clearance can be certified."
        }
        func ordered(_ values: Set<ROBWorkspaceVoxel>) -> [[Int]] {
            values.map { [$0.x, $0.y, $0.z] }.sorted {
                $0[0] != $1[0] ? $0[0] < $1[0] : $0[1] != $1[1] ? $0[1] < $1[1] : $0[2] < $1[2]
            }
        }
        var sampleRecords: [[Double]] = []
        for (voxel,bounds) in occupiedSamples {
            let cell=[Double(voxel.x),Double(voxel.y),Double(voxel.z)]
            let low=[bounds.low.x,bounds.low.y,bounds.low.z]
            let high=[bounds.high.x,bounds.high.y,bounds.high.z]
            sampleRecords.append(cell+low+high)
        }
        sampleRecords.sort { a,b in
            if a[0] != b[0] {return a[0]<b[0]}
            if a[1] != b[1] {return a[1]<b[1]}
            return a[2]<b[2]
        }
        let identity: [String: Any] = ["scene": sceneID.uuidString, "model": modelID, "geometry": geometryID,
            "mapping": mappingID, "session": NSNumber(value: sessionGeneration), "camera": cameraGeneration.uuidString,
            "bodyMotionIdentity":bodyMotionIdentity,
            "created": createdAtMilliseconds, "oldest": oldestCapturedAtMilliseconds,
            "latest": lastCapturedAtMilliseconds, "voxel_size": voxelSizeMeters, "frames": observedFrameCount,
            "truncated": isTruncated, "registration": registrationID ?? "unverified",
            "registrationUncertaintyMeters": registrationUncertaintyMeters as Any? ?? NSNull(),
            "occupied": ordered(occupied), "free": ordered(self.free),
            "occupiedSampleBounds": sampleRecords]
        var bytes = (try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])) ?? Data()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        bytes.append((try? encoder.encode(observations)) ?? Data())
        fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func occupiedSampleBounds(at point:SIMD3<Double>)->(low:SIMD3<Double>,high:SIMD3<Double>)? {
        guard [point.x,point.y,point.z].allSatisfy(\.isFinite),simd_length(point)<10 else {return nil}
        let voxel=ROBWorkspaceVoxel(x:Int(floor(point.x/voxelSizeMeters)),y:Int(floor(point.y/voxelSizeMeters)),z:Int(floor(point.z/voxelSizeMeters)))
        return occupiedSamples[voxel].map {($0.low,$0.high)}
    }

    func containsTargetObservation(sequence:UInt64,capturedAtMilliseconds:Double)->Bool {
        capturedAtMilliseconds.isFinite && observations.contains {
            $0.sequence==sequence && abs($0.capturedAtMilliseconds-capturedAtMilliseconds)<=1
        }
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
    let bodyMotionIdentity: String
    let voxelSizeMeters = 0.025
    private let maximumOccupied = 100_000
    private let maximumFree = 300_000
    private var occupied = Set<ROBWorkspaceVoxel>()
    private var free = Set<ROBWorkspaceVoxel>()
    private var occupiedSamples: [ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds] = [:]
    private var oldestCapture: Double?
    private var latestCapture = 0.0
    private var lastSequence: UInt64 = 0
    private var frameCount = 0
    private var truncated = false
    private var observations: [ROBWorkspaceDepthObservation] = []
    private var allFramesRegistered = true
    private var registrationProofs: [String:Double] = [:]

    init(modelID: String, geometryID: String, mappingID: String, sessionGeneration: UInt64,
         cameraGeneration: UUID, nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000) {
        self.modelID = modelID; self.geometryID = geometryID; self.mappingID = mappingID
        self.sessionGeneration = sessionGeneration; self.cameraGeneration = cameraGeneration
        createdAtMilliseconds = nowMilliseconds
        bodyMotionIdentity=ROBFixedHeadBodyMotionIdentity.currentIdentity
    }

    mutating func append(width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double,
        depth: (Int, Int) -> UInt16?, cameraToRobot: simd_double4x4,
        capturedAtMilliseconds: Double, sequence: UInt64, cameraGeneration: UUID,
        nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000,
        measuredSelfBounds: [(low: SIMD3<Double>, high: SIMD3<Double>)] = [],
        cameraRegistrationVerified: Bool = false, recordedPanDegrees:Double? = nil,
        recordedUpperTarget:Int? = nil, recordedLowerTarget:Int? = nil,
        registration:ROBFixedHeadRegistration? = nil,
        registrationScope:ROBFixedHeadRegistrationScope? = nil,
        alternateEstimatedDepth: ((Int,Int)->UInt16?)? = nil,
        estimatedDepthHypothesisID: String? = nil) throws {
        guard (alternateEstimatedDepth == nil && estimatedDepthHypothesisID == nil) ||
              (alternateEstimatedDepth != nil && registration == nil &&
               estimatedDepthHypothesisID.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) == true) else {
            throw ROBWorkspaceDepthMapError.acquisition("Estimated depth hypotheses need an identified unregistered map; they cannot create measured registration.")
        }
        if let first = observations.first,
           first.estimatedDepthHypothesisID != estimatedDepthHypothesisID {
            throw ROBWorkspaceDepthMapError.acquisition("Depth hypotheses changed during this scene; start a fresh estimated map.")
        }
        guard bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity else {
            throw ROBWorkspaceDepthMapError.acquisition("Body moved after this scene began; capture a fresh fixed-head registration and map")
        }
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
        if let registration {
            guard let scope=registrationScope,
                  scope.modelID==modelID, scope.geometryID==geometryID, scope.mappingID==mappingID,
                  scope.cameraGeneration==cameraGeneration, scope.gatewaySessionGeneration==sessionGeneration,
                  registration.acceptsTransform(cameraToRobot,scope:scope),
                  recordedUpperTarget.map({ $0==scope.upperTarget }) ?? true,
                  recordedLowerTarget.map({ $0==scope.lowerTarget }) ?? true else {
                throw ROBWorkspaceDepthMapError.acquisition("Fixed-head registration does not match this model, camera, connection, neck hold or applied transform")
            }
            registrationProofs[registration.id]=registration.uncertaintyMeters
        }
        // A raw boolean is not measurement evidence. One provisional frame
        // prevents the accumulated scene from becoming a registered map.
        let measuredRegistration = registration != nil
        allFramesRegistered = allFramesRegistered && measuredRegistration
        lastSequence = sequence; latestCapture = capturedAtMilliseconds
        oldestCapture = oldestCapture ?? capturedAtMilliseconds; frameCount += 1
        observations.append(.init(sequence:sequence,capturedAtMilliseconds:capturedAtMilliseconds,
            recordedPanDegrees:recordedPanDegrees,recordedUpperTarget:recordedUpperTarget,
            recordedLowerTarget:recordedLowerTarget,registrationID:registration?.id,
            registrationUncertaintyMeters:registration?.uncertaintyMeters,fixedHeadScope:registrationScope,
            cameraToRobotColumnMajor:(0..<4).flatMap { column in (0..<4).map { cameraToRobot[column][$0] } },
            measuredSelfMaskApplied:measuredRegistration && !measuredSelfBounds.isEmpty,
            estimatedDepthHypothesisID:estimatedDepthHypothesisID))
        let origin = SIMD3(cameraToRobot.columns.3.x,cameraToRobot.columns.3.y,cameraToRobot.columns.3.z)
        // A provisional transform cannot justify erasing a table because it
        // overlaps an estimated robot hull. Retain those occupied returns.
        let selfBounds = measuredRegistration ? measuredSelfBounds : []
        let step = max(2, Int(ceil(sqrt(Double(width * height) / 12_000))))
        for y in stride(from: 1, to: height - 1, by: step) {
            for x in stride(from: 1, to: width - 1, by: step) {
                guard let mm = depth(x,y), (100...3000).contains(Int(mm)) else { continue }
                if let alternateEstimatedDepth {
                    // One original frame/sequence, both possible occupied
                    // endpoints. A missing alternative cannot carve free space.
                    let alternative = alternateEstimatedDepth(x,y)
                    let samples = [Optional(mm),alternative].compactMap { $0 }.filter { (100...3000).contains(Int($0)) }
                    var endpoints:[SIMD3<Double>] = []
                    for sample in samples {
                        let z = Double(sample)/1000
                        let p = cameraToRobot * SIMD4((Double(x)-cx)*z/fx,(Double(y)-cy)*z/fy,z,1)
                        let endpoint = SIMD3(p.x,p.y,p.z)
                        if withinBounds(endpoint) { markOccupied(endpoint);endpoints.append(endpoint) }
                    }
                    guard samples.count == 2,endpoints.count == 2 else {continue}
                    let coordinates = [(x-1,y),(x+1,y),(x,y-1),(x,y+1)]
                    let neighbors = coordinates.compactMap {depth($0.0,$0.1)}
                    let alternateNeighbors = coordinates.compactMap {alternateEstimatedDepth($0.0,$0.1)}
                    guard neighbors.count == 4,alternateNeighbors.count == 4,
                          neighbors.allSatisfy({abs(Int($0)-Int(mm))<=30}),
                          alternateNeighbors.allSatisfy({abs(Int($0)-Int(alternative!))<=30}) else {continue}
                    let distances = endpoints.map {simd_length($0-origin)}
                    guard distances.allSatisfy({$0.isFinite && $0>0.1}) else {continue}
                    let direction = simd_normalize(endpoints[0]-origin)
                    let freeUntil = distances.min()!-0.075
                    guard freeUntil>0.1 else {continue}
                    for along in stride(from:0.1,to:freeUntil,by:voxelSizeMeters*0.5) {
                        let point = origin+direction*along
                        guard withinBounds(point) else {continue}
                        if free.count<maximumFree {free.insert(voxel(point))} else {truncated=true;break}
                    }
                    continue
                }
                let z = Double(mm) / 1000
                let p = cameraToRobot * SIMD4((Double(x)-cx)*z/fx, (Double(y)-cy)*z/fy, z, 1)
                let endpoint = SIMD3(p.x,p.y,p.z)
                guard withinBounds(endpoint), registration?.validRobotVolume.contains(endpoint) ?? true else { continue }
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
                    guard withinBounds(point), registration?.validRobotVolume.contains(point) ?? true else { continue }
                    if free.count < maximumFree { free.insert(voxel(point)) } else { truncated = true; break }
                }
            }
        }
        guard bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity else {
            throw ROBWorkspaceDepthMapError.acquisition("Body moved while the depth frame was projected; discard this scene")
        }
    }

    func snapshot(nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000) -> ROBWorkspaceCollisionSnapshot? {
        guard bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity else {return nil}
        guard frameCount >= 2, let oldestCapture else { return nil }
        let registrationID: String?
        let uncertainty: Double?
        if allFramesRegistered, !registrationProofs.isEmpty {
            let ordered=registrationProofs.keys.sorted().joined(separator:"|")
            registrationID="fixed-head-map-"+SHA256.hash(data:Data(ordered.utf8)).map {String(format:"%02x",$0)}.joined()
            uncertainty=registrationProofs.values.max()
        } else { registrationID=nil;uncertainty=nil }
        return ROBWorkspaceCollisionSnapshot(sceneID: sceneID, modelID: modelID, geometryID: geometryID,
            mappingID: mappingID, sessionGeneration: sessionGeneration, cameraGeneration: cameraGeneration,
            createdAtMilliseconds: max(nowMilliseconds,latestCapture), oldestCapturedAtMilliseconds: oldestCapture,
            lastCapturedAtMilliseconds: latestCapture, voxelSizeMeters: voxelSizeMeters,
            observedFrameCount: frameCount, isTruncated: truncated,
            registrationID:registrationID,registrationUncertaintyMeters:uncertainty,bodyMotionIdentity:bodyMotionIdentity,
            occupied: occupied, free: free, occupiedSamples:occupiedSamples, observations:observations)
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
            let cell=ROBWorkspaceVoxel(x:center.x+x,y:center.y+y,z:center.z+z)
            occupied.insert(cell)
            if var bounds=occupiedSamples[cell] {
                bounds.low=simd_min(bounds.low,point);bounds.high=simd_max(bounds.high,point);occupiedSamples[cell]=bounds
            } else {occupiedSamples[cell] = .init(low:point,high:point)}
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
