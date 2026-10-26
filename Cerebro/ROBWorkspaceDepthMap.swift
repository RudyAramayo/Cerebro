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

fileprivate struct ROBWorkspaceOccupiedSampleBounds: Codable {
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
    var estimatedCameraProjectionIdentity:String? = nil
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
    fileprivate let capturedRegistrationID: String?
    let bodyMotionIdentity: String
    let estimatedCameraProjectionIdentity:String?
    var registrationID: String? {
        bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity ? capturedRegistrationID : nil
    }
    let registrationUncertaintyMeters: Double?
    let observedFrameCount: Int
    let isTruncated: Bool
    let registrationDetail: String
    let observations: [ROBWorkspaceDepthObservation]
    fileprivate let occupied: Set<ROBWorkspaceVoxel>
    fileprivate let free: Set<ROBWorkspaceVoxel>
    fileprivate let occupiedSamples: [ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds]
    // Optional for legacy snapshots: missing source correlation can never be
    // reconstructed by splitting their already-merged occupied bounds.
    fileprivate let occupiedSourceSamples: [ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds]?
    fileprivate let sourceSamplesAreComplete: Bool
    let fingerprint: String
    var occupiedVoxels: [ROBWorkspaceVoxel] { Array(occupied) }
    var freeVoxels: [ROBWorkspaceVoxel] { Array(free) }
    var occupiedVoxelCount: Int { occupied.count }
    var freeVoxelCount: Int { free.count }

    /// A separate experimental consumer can bind the original unregistered
    /// evidence. This never changes registration, occupied/free cells or masks.
    var visualCalibrationScope: ROBWorkspaceVisualCalibrationMapScope? {
        guard capturedRegistrationID == nil, registrationUncertaintyMeters == nil,
              !isTruncated, observedFrameCount >= 2, observations.count == observedFrameCount,
              let projection = estimatedCameraProjectionIdentity, projection.count == 64,
              observations.allSatisfy({ $0.registrationID == nil && $0.registrationUncertaintyMeters == nil &&
                  !$0.measuredSelfMaskApplied && $0.estimatedDepthHypothesisID == nil &&
                  $0.estimatedCameraProjectionIdentity == projection &&
                  $0.recordedPanDegrees?.isFinite == true && $0.recordedUpperTarget.map({(3000...10000).contains($0)}) == true &&
                  $0.recordedLowerTarget.map({(3000...10000).contains($0)}) == true &&
                  $0.cameraToRobotColumnMajor.count == 16 && $0.cameraToRobotColumnMajor.allSatisfy(\.isFinite) }) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(observations) else { return nil }
        return .init(bodyMotionIdentity:bodyMotionIdentity,
            bodyContextIsCurrent:bodyMotionIdentity == ROBFixedHeadBodyMotionIdentity.currentIdentity,
            estimatedCameraProjectionIdentity:projection,
            observationPoseIdentity:SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined(),
            observedFrameCount:observedFrameCount)
    }

    fileprivate init(sceneID: UUID, modelID: String, geometryID: String, mappingID: String,
        sessionGeneration: UInt64, cameraGeneration: UUID, createdAtMilliseconds: Double,
        oldestCapturedAtMilliseconds: Double, lastCapturedAtMilliseconds: Double,
        voxelSizeMeters: Double, observedFrameCount: Int, isTruncated: Bool,
        registrationID: String?, registrationUncertaintyMeters: Double?,bodyMotionIdentity:String,
        occupied: Set<ROBWorkspaceVoxel>, free: Set<ROBWorkspaceVoxel>,
        occupiedSamples:[ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds], observations:[ROBWorkspaceDepthObservation],
        estimatedCameraProjectionIdentity:String? = nil,
        occupiedSourceSamples:[ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds]? = nil) {
        self.sceneID = sceneID; self.modelID = modelID; self.geometryID = geometryID; self.mappingID = mappingID
        self.sessionGeneration = sessionGeneration; self.cameraGeneration = cameraGeneration
        self.createdAtMilliseconds = createdAtMilliseconds
        self.oldestCapturedAtMilliseconds = oldestCapturedAtMilliseconds
        self.lastCapturedAtMilliseconds = lastCapturedAtMilliseconds
        self.voxelSizeMeters = voxelSizeMeters; self.observedFrameCount = observedFrameCount
        self.isTruncated = isTruncated; self.occupied = occupied; self.free = free.subtracting(occupied)
        self.occupiedSamples = occupiedSamples
        self.occupiedSourceSamples = occupiedSourceSamples
        sourceSamplesAreComplete = !isTruncated && Self.sourceCoverageIsComplete(occupiedSourceSamples,
            occupied:occupied,unions:occupiedSamples,size:voxelSizeMeters)
        self.observations = observations
        self.capturedRegistrationID = registrationID; self.registrationUncertaintyMeters = registrationUncertaintyMeters
        self.bodyMotionIdentity=bodyMotionIdentity
        self.estimatedCameraProjectionIdentity=estimatedCameraProjectionIdentity
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
        var identity: [String: Any] = ["scene": sceneID.uuidString, "model": modelID, "geometry": geometryID,
            "mapping": mappingID, "session": NSNumber(value: sessionGeneration), "camera": cameraGeneration.uuidString,
            "bodyMotionIdentity":bodyMotionIdentity,
            "created": createdAtMilliseconds, "oldest": oldestCapturedAtMilliseconds,
            "latest": lastCapturedAtMilliseconds, "voxel_size": voxelSizeMeters, "frames": observedFrameCount,
            "truncated": isTruncated, "registration": registrationID ?? "unverified",
            "registrationUncertaintyMeters": registrationUncertaintyMeters as Any? ?? NSNull(),
            "occupied": ordered(occupied), "free": ordered(self.free),
            "occupiedSampleBounds": sampleRecords]
        if let occupiedSourceSamples {
            var records:[[Double]]=[]
            for (cell,bounds) in occupiedSourceSamples {
                records.append([Double(cell.x),Double(cell.y),Double(cell.z),bounds.low.x,bounds.low.y,bounds.low.z,
                    bounds.high.x,bounds.high.y,bounds.high.z])
            }
            records.sort {a,b in a[0] != b[0] ? a[0]<b[0] : a[1] != b[1] ? a[1]<b[1] : a[2]<b[2]}
            identity["occupiedSourceSampleBounds"]=records
        }
        // Preserve legacy/frozen-context fingerprints when this is absent.
        if let estimatedCameraProjectionIdentity {identity["estimatedCameraProjectionIdentity"]=estimatedCameraProjectionIdentity}
        var bytes = (try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])) ?? Data()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        bytes.append((try? encoder.encode(observations)) ?? Data())
        fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys:String,CodingKey {
        case sceneID,modelID,geometryID,mappingID,sessionGeneration,cameraGeneration,createdAtMilliseconds
        case oldestCapturedAtMilliseconds,lastCapturedAtMilliseconds,voxelSizeMeters,capturedRegistrationID
        case bodyMotionIdentity,estimatedCameraProjectionIdentity,registrationUncertaintyMeters,observedFrameCount
        case isTruncated,registrationDetail,observations,occupied,free,occupiedSamples,occupiedSourceSamples,fingerprint
    }

    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        sceneID=try c.decode(UUID.self,forKey:.sceneID)
        modelID=try c.decode(String.self,forKey:.modelID);geometryID=try c.decode(String.self,forKey:.geometryID)
        mappingID=try c.decode(String.self,forKey:.mappingID)
        sessionGeneration=try c.decode(UInt64.self,forKey:.sessionGeneration)
        cameraGeneration=try c.decode(UUID.self,forKey:.cameraGeneration)
        createdAtMilliseconds=try c.decode(Double.self,forKey:.createdAtMilliseconds)
        oldestCapturedAtMilliseconds=try c.decode(Double.self,forKey:.oldestCapturedAtMilliseconds)
        lastCapturedAtMilliseconds=try c.decode(Double.self,forKey:.lastCapturedAtMilliseconds)
        voxelSizeMeters=try c.decode(Double.self,forKey:.voxelSizeMeters)
        capturedRegistrationID=try c.decodeIfPresent(String.self,forKey:.capturedRegistrationID)
        bodyMotionIdentity=try c.decode(String.self,forKey:.bodyMotionIdentity)
        estimatedCameraProjectionIdentity=try c.decodeIfPresent(String.self,forKey:.estimatedCameraProjectionIdentity)
        registrationUncertaintyMeters=try c.decodeIfPresent(Double.self,forKey:.registrationUncertaintyMeters)
        observedFrameCount=try c.decode(Int.self,forKey:.observedFrameCount)
        isTruncated=try c.decode(Bool.self,forKey:.isTruncated)
        registrationDetail=try c.decode(String.self,forKey:.registrationDetail)
        observations=try c.decode([ROBWorkspaceDepthObservation].self,forKey:.observations)
        occupied=try c.decode(Set<ROBWorkspaceVoxel>.self,forKey:.occupied)
        free=try c.decode(Set<ROBWorkspaceVoxel>.self,forKey:.free)
        occupiedSamples=try c.decode([ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds].self,forKey:.occupiedSamples)
        occupiedSourceSamples=try c.decodeIfPresent([ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds].self,forKey:.occupiedSourceSamples)
        fingerprint=try c.decode(String.self,forKey:.fingerprint)
        sourceSamplesAreComplete = !isTruncated && Self.sourceCoverageIsComplete(occupiedSourceSamples,
            occupied:occupied,unions:occupiedSamples,size:voxelSizeMeters)
    }

    fileprivate func canonicalFingerprint(withSourceSamples source:[ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds]?)->String {
        Self(sceneID:sceneID,modelID:modelID,geometryID:geometryID,mappingID:mappingID,sessionGeneration:sessionGeneration,
            cameraGeneration:cameraGeneration,createdAtMilliseconds:createdAtMilliseconds,
            oldestCapturedAtMilliseconds:oldestCapturedAtMilliseconds,lastCapturedAtMilliseconds:lastCapturedAtMilliseconds,
            voxelSizeMeters:voxelSizeMeters,observedFrameCount:observedFrameCount,isTruncated:isTruncated,
            registrationID:capturedRegistrationID,registrationUncertaintyMeters:registrationUncertaintyMeters,
            bodyMotionIdentity:bodyMotionIdentity,occupied:occupied,free:free,occupiedSamples:occupiedSamples,
            observations:observations,estimatedCameraProjectionIdentity:estimatedCameraProjectionIdentity,
            occupiedSourceSamples:source).fingerprint
    }

    /// Validate the complete correlation table, not just a caller's selected
    /// cell. Every original source voxel contributes to all27 dilated cells,
    /// and the aggregate must reproduce every retained legacy union exactly.
    private static func sourceCoverageIsComplete(_ source:[ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds]?,
        occupied:Set<ROBWorkspaceVoxel>,unions:[ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds],size:Double)->Bool {
        guard let source,size==0.025,source.count<=400_000,occupied.count<=400_000,
              source.count<=occupied.count,unions.count==occupied.count else {return false}
        var derived:[ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds]=[:]
        derived.reserveCapacity(occupied.count)
        for (key,bounds) in source {
            guard [key.x,key.y,key.z].allSatisfy({abs(Double($0)*size)<10}),
                  (0..<3).allSatisfy({bounds.low[$0].isFinite && bounds.high[$0].isFinite && bounds.low[$0]<=bounds.high[$0]}) else {return false}
            let low=SIMD3(Double(key.x),Double(key.y),Double(key.z))*size,high=low+SIMD3(repeating:size)
            guard (0..<3).allSatisfy({bounds.low[$0]>=low[$0]-1e-12 && bounds.high[$0]<=high[$0]+1e-12}) else {return false}
            for x in -1...1 {for y in -1...1 {for z in -1...1 {
                let cell=ROBWorkspaceVoxel(x:key.x+x,y:key.y+y,z:key.z+z)
                guard occupied.contains(cell) else {return false}
                if var aggregate=derived[cell] {
                    aggregate.low=simd_min(aggregate.low,bounds.low);aggregate.high=simd_max(aggregate.high,bounds.high)
                    derived[cell]=aggregate
                } else {derived[cell]=bounds}
            }}}
        }
        guard derived.count==occupied.count else {return false}
        return occupied.allSatisfy {cell in
            guard let a=derived[cell],let b=unions[cell] else {return false}
            return (0..<3).allSatisfy {abs(a.low[$0]-b.low[$0])<=1e-12 && abs(a.high[$0]-b.high[$0])<=1e-12}
        }
    }

    func occupiedSampleSubBounds(at point:SIMD3<Double>)->[ROBWorkspaceOccupiedReturnBounds]? {
        guard sourceSamplesAreComplete,let source=occupiedSourceSamples,
              [point.x,point.y,point.z].allSatisfy(\.isFinite),simd_length(point)<10 else {return nil}
        let cell=ROBWorkspaceVoxel(x:Int(floor(point.x/voxelSizeMeters)),y:Int(floor(point.y/voxelSizeMeters)),z:Int(floor(point.z/voxelSizeMeters)))
        guard occupied.contains(cell) else {return nil}
        var result:[ROBWorkspaceOccupiedReturnBounds]=[]
        for x in -1...1 {for y in -1...1 {for z in -1...1 {
            if let b=source[.init(x:cell.x+x,y:cell.y+y,z:cell.z+z)] {
                result.append(.init(lowMeters:[b.low.x,b.low.y,b.low.z],highMeters:[b.high.x,b.high.y,b.high.z]))
            }
        }}}
        return result.isEmpty ? nil:result
    }

    var originalOccupiedReturnBounds:[ROBWorkspaceOccupiedReturnBounds]? {
        guard occupied.allSatisfy({occupiedSamples[$0] != nil}) else{return nil}
        return occupied.map { voxel in let b=occupiedSamples[voxel]!
            return .init(lowMeters:[b.low.x,b.low.y,b.low.z],highMeters:[b.high.x,b.high.y,b.high.z])
        }
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
    struct StorageBudget {
        static let standard = StorageBudget(occupiedVoxels:400_000,freeVoxels:600_000)
        let occupiedVoxels:Int
        let freeVoxels:Int

        /// Smaller budgets support bounded consumers and resource fixtures;
        /// callers cannot exceed the production storage bound.
        init(occupiedVoxels:Int,freeVoxels:Int) {
            precondition((1...400_000).contains(occupiedVoxels) && (1...600_000).contains(freeVoxels))
            self.occupiedVoxels=occupiedVoxels;self.freeVoxels=freeVoxels
        }
    }
    let sceneID: UUID
    let modelID: String
    let geometryID: String
    let mappingID: String
    let sessionGeneration: UInt64
    let cameraGeneration: UUID
    let createdAtMilliseconds: Double
    private let acquisitionStartedAtMilliseconds: Double
    let bodyMotionIdentity: String
    let estimatedCameraProjectionIdentity:String?
    let voxelSizeMeters = 0.025
    private let storageBudget:StorageBudget
    private var occupied = Set<ROBWorkspaceVoxel>()
    private var free = Set<ROBWorkspaceVoxel>()
    private var occupiedSamples: [ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds] = [:]
    private var occupiedSourceSamples: [ROBWorkspaceVoxel:ROBWorkspaceOccupiedSampleBounds]? = [:]
    private var oldestCapture: Double?
    private var latestCapture = 0.0
    private var lastSequence: UInt64 = 0
    private var frameCount = 0
    private var truncated = false
    private var observations: [ROBWorkspaceDepthObservation] = []
    private var allFramesRegistered = true
    private var registrationProofs: [String:Double] = [:]

    init(modelID: String, geometryID: String, mappingID: String, sessionGeneration: UInt64,
         cameraGeneration: UUID, nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000,
         storageBudget:StorageBudget = .standard,estimatedCameraProjectionIdentity:String? = nil) {
        precondition(estimatedCameraProjectionIdentity.map{$0.count==64 && $0.allSatisfy(\.isHexDigit)} ?? true)
        self.modelID = modelID; self.geometryID = geometryID; self.mappingID = mappingID
        sceneID = UUID()
        self.sessionGeneration = sessionGeneration; self.cameraGeneration = cameraGeneration
        createdAtMilliseconds = nowMilliseconds
        acquisitionStartedAtMilliseconds = nowMilliseconds
        self.storageBudget=storageBudget
        self.estimatedCameraProjectionIdentity=estimatedCameraProjectionIdentity
        bodyMotionIdentity=ROBFixedHeadBodyMotionIdentity.currentIdentity
    }

    /// Continue one still-current unregistered scan for a neck-only observation.
    /// The frozen scene and every original return are retained. This cannot
    /// revive a registered/stale/truncated scene or reset its acquisition clock.
    init(continuing snapshot:ROBWorkspaceCollisionSnapshot,modelID:String,geometryID:String,mappingID:String,
         sessionGeneration:UInt64,cameraGeneration:UUID,estimatedCameraProjectionIdentity:String,
         nowMilliseconds:Double = Date().timeIntervalSince1970 * 1000) throws {
        func reject() -> ROBWorkspaceDepthMapError {
            .acquisition("The targeted depth observation cannot continue this scene's source, body, timing or raw evidence.")
        }
        guard snapshot.modelID==modelID,snapshot.geometryID==geometryID,snapshot.mappingID==mappingID,
              snapshot.sessionGeneration==sessionGeneration,sessionGeneration>0,snapshot.cameraGeneration==cameraGeneration,
              snapshot.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity,
              snapshot.estimatedCameraProjectionIdentity==estimatedCameraProjectionIdentity,
              estimatedCameraProjectionIdentity.count==64,estimatedCameraProjectionIdentity.allSatisfy(\.isHexDigit),
              snapshot.capturedRegistrationID==nil,snapshot.registrationUncertaintyMeters==nil,
              !snapshot.isTruncated,snapshot.voxelSizeMeters==0.025,
              (2..<256).contains(snapshot.observedFrameCount),snapshot.observations.count==snapshot.observedFrameCount,
              snapshot.visualCalibrationScope != nil,
              [nowMilliseconds,snapshot.createdAtMilliseconds,snapshot.oldestCapturedAtMilliseconds,
               snapshot.lastCapturedAtMilliseconds].allSatisfy(\.isFinite),
              snapshot.oldestCapturedAtMilliseconds<=snapshot.lastCapturedAtMilliseconds,
              snapshot.lastCapturedAtMilliseconds<=snapshot.createdAtMilliseconds,
              nowMilliseconds>=snapshot.createdAtMilliseconds,
              nowMilliseconds-snapshot.oldestCapturedAtMilliseconds<=60_000,
              snapshot.observations.first?.capturedAtMilliseconds==snapshot.oldestCapturedAtMilliseconds,
              snapshot.observations.last?.capturedAtMilliseconds==snapshot.lastCapturedAtMilliseconds,
              snapshot.occupied.count<=StorageBudget.standard.occupiedVoxels,
              snapshot.free.count<=StorageBudget.standard.freeVoxels,
              Set(snapshot.occupiedSamples.keys)==snapshot.occupied,
              snapshot.occupiedSamples.values.allSatisfy({ bounds in
                  (0..<3).allSatisfy { bounds.low[$0].isFinite && bounds.high[$0].isFinite &&
                      abs(bounds.low[$0])<10 && abs(bounds.high[$0])<10 && bounds.low[$0]<=bounds.high[$0] }
              }) else {throw reject()}
        for (index,observation) in snapshot.observations.enumerated() {
            guard observation.sequence>0,observation.capturedAtMilliseconds.isFinite,
                  index==0 || (observation.sequence>snapshot.observations[index-1].sequence &&
                      observation.capturedAtMilliseconds>snapshot.observations[index-1].capturedAtMilliseconds) else {throw reject()}
        }
        self.sceneID=snapshot.sceneID;self.modelID=modelID;self.geometryID=geometryID;self.mappingID=mappingID
        self.sessionGeneration=sessionGeneration;self.cameraGeneration=cameraGeneration
        self.createdAtMilliseconds=snapshot.createdAtMilliseconds
        // A snapshot's creation time is its freeze time, not the original
        // mapper start. The earliest retained capture is a stricter bound than
        // resetting sixty seconds at each subsequent frozen snapshot.
        acquisitionStartedAtMilliseconds=snapshot.oldestCapturedAtMilliseconds
        bodyMotionIdentity=snapshot.bodyMotionIdentity
        self.estimatedCameraProjectionIdentity=estimatedCameraProjectionIdentity
        storageBudget = .standard
        occupied=snapshot.occupied;free=snapshot.free;occupiedSamples=snapshot.occupiedSamples
        occupiedSourceSamples=snapshot.sourceSamplesAreComplete ? snapshot.occupiedSourceSamples:nil
        oldestCapture=snapshot.oldestCapturedAtMilliseconds;latestCapture=snapshot.lastCapturedAtMilliseconds
        lastSequence=snapshot.observations.last!.sequence;frameCount=snapshot.observedFrameCount
        truncated=false;observations=snapshot.observations;allFramesRegistered=false;registrationProofs=[:]
        let expectedFingerprint:String
        if snapshot.occupiedSourceSamples != nil && !snapshot.sourceSamplesAreComplete {
            // Invalid correlation data never becomes complete after later
            // pixels. Verify the original frozen data before dropping only
            // that optional detail; all legacy unions and observations stay.
            guard snapshot.canonicalFingerprint(withSourceSamples:snapshot.occupiedSourceSamples)==snapshot.fingerprint else {throw reject()}
            expectedFingerprint=snapshot.canonicalFingerprint(withSourceSamples:nil)
        } else {expectedFingerprint=snapshot.fingerprint}
        guard self.snapshot(nowMilliseconds:snapshot.createdAtMilliseconds)?.fingerprint==expectedFingerprint else {throw reject()}
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
        estimatedDepthHypothesisID: String? = nil,estimatedCameraProjectionIdentity:String? = nil) throws {
        guard (registration != nil && estimatedCameraProjectionIdentity == nil) ||
              (registration == nil && estimatedCameraProjectionIdentity == self.estimatedCameraProjectionIdentity) else {
            throw ROBWorkspaceDepthMapError.acquisition("The estimated camera projection changed during this scene; capture a new map.")
        }
        guard estimatedDepthHypothesisID == nil || self.estimatedCameraProjectionIdentity == nil else {
            throw ROBWorkspaceDepthMapError.acquisition("A frozen raw/corrected context cannot be combined with a photo-origin projection.")
        }
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
            if frameAge>700 {throw ROBWorkspaceDepthMapError.expiredAtProjection(frameAgeMilliseconds:frameAge)}
            throw ROBWorkspaceDepthMapError.acquisition("Depth frame age \(String(format:"%.1f",frameAge)) ms is outside 0...700 ms at projection")
        }
        guard nowMilliseconds-acquisitionStartedAtMilliseconds <= 60_000 else {
            throw ROBWorkspaceDepthMapError.acquisition("Scene acquisition exceeded 60000 ms (elapsed \(String(format:"%.1f",nowMilliseconds-acquisitionStartedAtMilliseconds)) ms)")
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
            estimatedDepthHypothesisID:estimatedDepthHypothesisID,estimatedCameraProjectionIdentity:estimatedCameraProjectionIdentity))
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
                        if !markFree(point) {break}
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
                    if !markFree(point) {break}
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
            occupied: occupied, free: free, occupiedSamples:occupiedSamples, observations:observations,
            estimatedCameraProjectionIdentity:estimatedCameraProjectionIdentity,occupiedSourceSamples:occupiedSourceSamples)
    }

    private func voxel(_ point: SIMD3<Double>) -> ROBWorkspaceVoxel {
        .init(x: Int(floor(point.x / voxelSizeMeters)), y: Int(floor(point.y / voxelSizeMeters)), z: Int(floor(point.z / voxelSizeMeters)))
    }
    private func withinBounds(_ point: SIMD3<Double>) -> Bool {
        (-2...2).contains(point.x) && (-2...2).contains(point.y) && (-0.3...2.4).contains(point.z)
    }
    private mutating func markOccupied(_ point: SIMD3<Double>) {
        let center = voxel(point)
        if occupiedSourceSamples != nil {
            if var bounds=occupiedSourceSamples?[center] {
                bounds.low=simd_min(bounds.low,point);bounds.high=simd_max(bounds.high,point)
                occupiedSourceSamples?[center]=bounds
            } else if occupiedSourceSamples!.count<storageBudget.occupiedVoxels {
                occupiedSourceSamples?[center] = .init(low:point,high:point)
            } else {truncated=true}
        }
        for x in -1...1 { for y in -1...1 { for z in -1...1 {
            let cell=ROBWorkspaceVoxel(x:center.x+x,y:center.y+y,z:center.z+z)
            // Re-observing an existing cell consumes no capacity. Continue
            // updating its full observed bounds even when the set is full.
            guard occupied.count < storageBudget.occupiedVoxels || occupied.contains(cell) else {
                truncated = true;continue
            }
            occupied.insert(cell)
            if var bounds=occupiedSamples[cell] {
                bounds.low=simd_min(bounds.low,point);bounds.high=simd_max(bounds.high,point);occupiedSamples[cell]=bounds
            } else {occupiedSamples[cell] = .init(low:point,high:point)}
        } } }
    }
    private mutating func markFree(_ point:SIMD3<Double>)->Bool {
        let cell=voxel(point)
        guard free.count < storageBudget.freeVoxels || free.contains(cell) else {
            truncated=true;return false
        }
        free.insert(cell)
        return true
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
    case expiredAtProjection(frameAgeMilliseconds:Double)
    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "Depth map invalidated by stale/reordered frames, camera generation, scene expiry, or invalid camera geometry. Scan again without moving ROB."
        case .acquisition(let reason): return "Depth acquisition: \(reason). No arm travel was sent by this scan."
        case .expiredAtProjection(let age): return "Depth acquisition: Depth frame age \(String(format:"%.1f",age)) ms is outside 0...700 ms at projection. No arm travel was sent by this scan."
        }
    }
}

/// A held view may discard stale projection inputs, never relax their age or
/// recover another failure. The third expiration or original8s deadline ends
/// the view. Completed map frames are independent of this acquisition budget.
struct ROBWorkspaceProjectionRetryBudget {
    let deadlineUptime:Double
    private(set) var discardedFrameCount=0
    private(set) var lastExpiration:ROBWorkspaceDepthMapError?
    init(startedAtUptime:Double) {deadlineUptime=startedAtUptime+8}
    mutating func permitsRetry(after error:Error,nowUptime:Double,contextIsCurrent:Bool,taskCancelled:Bool)->Bool {
        guard let typed=error as?ROBWorkspaceDepthMapError,case .expiredAtProjection=typed else{return false}
        lastExpiration=typed
        guard contextIsCurrent,!taskCancelled,nowUptime.isFinite,nowUptime<deadlineUptime,discardedFrameCount<3 else{return false}
        discardedFrameCount+=1
        return discardedFrameCount<3
    }
}

/// A read-only adapter for the existing convex checker's diagnostic. Parsing
/// this text can request another observation; it never permits arm travel or
/// changes the state of a voxel. Occupied-obstacle diagnostics do not match.
struct ROBWorkspaceUnknownCellBlocker {
    let link:String
    let voxel:ROBWorkspaceVoxel
    let voxelSizeMeters:Double
    let distanceMeters:Double
    let marginMeters:Double
    var center:SIMD3<Double> {voxel.center(voxelSizeMeters:voxelSizeMeters)}

    init?(detail:String,voxelSizeMeters:Double) {
        guard detail.utf16.count<=1024,voxelSizeMeters.isFinite,voxelSizeMeters>0,voxelSizeMeters<=1 else {return nil}
        let pattern = #"^([A-Za-z][A-Za-z0-9_ -]{0,127}) enters unobserved space\. Scan the whole arm route before moving\. Convex distance upper bound ([0-9]+\.[0-9]{3}) mm; retained envelope margin ([0-9]+\.[0-9]{3}) mm; voxel \[(-?[0-9]+),(-?[0-9]+),(-?[0-9]+)\]; representation whole_voxel\.$"#
        guard let expression=try?NSRegularExpression(pattern:pattern),
              let match=expression.firstMatch(in:detail,range:NSRange(detail.startIndex...,in:detail)),
              match.range.length==detail.utf16.count else {return nil}
        func text(_ index:Int)->String? {Range(match.range(at:index),in:detail).map {String(detail[$0])}}
        guard let link=text(1),let distance=text(2).flatMap(Double.init),let margin=text(3).flatMap(Double.init),
              let x=text(4).flatMap(Int.init),let y=text(5).flatMap(Int.init),let z=text(6).flatMap(Int.init),
              distance.isFinite,margin.isFinite,distance>=0,margin>0,margin<=1000,
              distance<=margin+0.001,
              [x,y,z].allSatisfy({abs(Double($0)*voxelSizeMeters)<20}) else {return nil}
        self.link=link;voxel = .init(x:x,y:y,z:z);self.voxelSizeMeters=voxelSizeMeters
        distanceMeters=distance/1000;marginMeters=margin/1000
    }
}

struct ROBWorkspaceBlockerCoverageCandidate {
    let view:ROBWorkspaceView
    let cameraToRobotColumnMajor:[Double]
}

/// Select a bounded, distinct neck observation by whole-cell image coverage
/// and geometric parallax. Being inside the image is not evidence that a cell
/// is visible through foreground hardware, nor that its missing depth is free.
enum ROBWorkspaceBlockerCoveragePlan {
    static func nextView(blocker:ROBWorkspaceUnknownCellBlocker,candidates:[ROBWorkspaceBlockerCoverageCandidate],
        observations:[ROBWorkspaceDepthObservation],attempted:[ROBWorkspaceView],width:Int,height:Int,
        fx:Double,fy:Double,cx:Double,cy:Double)->ROBWorkspaceView? {
        guard (16...1920).contains(width),(16...1200).contains(height),
              [fx,fy,cx,cy].allSatisfy(\.isFinite),fx>0,fy>0,
              (0..<Double(width)).contains(cx),(0..<Double(height)).contains(cy),
              !observations.isEmpty,observations.count<=256,attempted.count<=128 else {return nil}
        func transform(_ values:[Double])->simd_double4x4? {
            guard values.count==16,values.allSatisfy(\.isFinite) else {return nil}
            let matrix=simd_double4x4(columns:(SIMD4(values[0],values[1],values[2],values[3]),
                SIMD4(values[4],values[5],values[6],values[7]),SIMD4(values[8],values[9],values[10],values[11]),
                SIMD4(values[12],values[13],values[14],values[15])))
            let rotation=simd_double3x3(columns:(SIMD3(values[0],values[1],values[2]),
                SIMD3(values[4],values[5],values[6]),SIMD3(values[8],values[9],values[10])))
            guard abs(simd_determinant(rotation)-1)<0.001,
                  (0..<3).allSatisfy({abs(simd_length(rotation[$0])-1)<0.001}),
                  abs(simd_dot(rotation[0],rotation[1])) + abs(simd_dot(rotation[1],rotation[2])) +
                    abs(simd_dot(rotation[0],rotation[2]))<0.001,
                  abs(values[3])+abs(values[7])+abs(values[11])<0.001,abs(values[15]-1)<0.001,
                  [values[12],values[13],values[14]].allSatisfy({abs($0)<10}) else {return nil}
            return matrix
        }
        let previousMatrices=observations.compactMap {transform($0.cameraToRobotColumnMajor)}
        guard previousMatrices.count==observations.count else {return nil}
        let priorViews=observations.compactMap { observation->ROBWorkspaceView? in
            guard let pan=observation.recordedPanDegrees,let upper=observation.recordedUpperTarget else {return nil}
            return .init(panDegrees:pan,upperTarget:upper)
        }+attempted
        let half=blocker.voxelSizeMeters/2,center=blocker.center
        var corners:[SIMD3<Double>]=[]
        for x in [-half,half] {for y in [-half,half] {for z in [-half,half] {corners.append(center+SIMD3(x,y,z))}}}
        var result:ROBWorkspaceView?,best = -Double.infinity
        for candidate in candidates.prefix(128) {
            let view=candidate.view
            guard view.panDegrees.isFinite,abs(view.panDegrees)<=90,(5000...8000).contains(view.upperTarget),
                  !priorViews.contains(where:{abs($0.panDegrees-view.panDegrees)<3 && abs($0.upperTarget-view.upperTarget)<100}),
                  let matrix=transform(candidate.cameraToRobotColumnMajor) else {continue}
            let origin=SIMD3(matrix.columns.3.x,matrix.columns.3.y,matrix.columns.3.z),inverse=simd_inverse(matrix)
            var edgeClearance=Double.infinity,covered=true
            for corner in corners {
                let point=inverse*SIMD4(corner,1)
                guard point.z>=0.1,point.z<=3 else {covered=false;break}
                let x=fx*point.x/point.z+cx,y=fy*point.y/point.z+cy
                let edge=min(x,Double(width-1)-x,y,Double(height-1)-y)
                guard x.isFinite,y.isFinite,edge>=12 else {covered=false;break}
                edgeClearance=min(edgeClearance,edge)
            }
            guard covered else {continue}
            let ray=center-origin,range=simd_length(ray)
            guard range.isFinite,range>0.1 else {continue}
            let direction=ray/range
            var leastAngle=Double.infinity,leastParallax=Double.infinity
            for previous in previousMatrices {
                let oldOrigin=SIMD3(previous.columns.3.x,previous.columns.3.y,previous.columns.3.z)
                let oldRay=center-oldOrigin,oldRange=simd_length(oldRay)
                guard oldRange.isFinite,oldRange>1e-6 else {covered=false;break}
                leastAngle=min(leastAngle,acos(max(-1,min(1,simd_dot(direction,oldRay/oldRange)))))
                let shift=origin-oldOrigin
                leastParallax=min(leastParallax,simd_length(shift-direction*simd_dot(shift,direction)))
            }
            guard covered,leastAngle.isFinite,leastParallax.isFinite else {continue}
            // Nearest already-used viewpoint limits novelty. Image centering
            // only breaks weak parallax ties; no score is a clearance proof.
            let score=leastAngle+2*leastParallax/range+0.02*min(1,edgeClearance/(Double(min(width,height))/2))
            if score>best+1e-12 {best=score;result=view}
        }
        return result
    }
}
