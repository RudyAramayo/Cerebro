import Foundation
import simd

/// Verified closed-convex queries. OBJ precision is at most one micron;
/// the inside tolerance is conservative and never increases clearance.
struct ROBEstimatedConvexHull {
    private struct Triangle {
        let a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>, normal: SIMD3<Double>
    }
    private struct Edge: Hashable {
        let a: Int, b: Int
        init(_ x:Int,_ y:Int) { a = min(x,y); b = max(x,y) }
    }
    let vertices: [SIMD3<Double>]
    private let triangles: [Triangle]
    private let localFaceDirections:[SIMD3<Double>]
    private let localEdgeDirections:[SIMD3<Double>]
    private static let precision = 0.000001

    init(text:String) throws {
        func invalid() -> ROBGhostMotionError { .blocked("An estimated arm hull is malformed, open, nonmanifold or nonconvex. No nudge was admitted.") }
        var points: [SIMD3<Double>] = [], faces: [[Int]] = []
        for line in text.split(separator:"\n") {
            let fields = line.split(whereSeparator:\.isWhitespace)
            guard let kind = fields.first, !kind.hasPrefix("#") else { continue }
            if kind == "v" {
                guard fields.count == 4, let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]),
                      [x,y,z].allSatisfy(\.isFinite), max(abs(x),abs(y),abs(z)) < 10 else { throw invalid() }
                points.append(SIMD3(x,y,z))
            } else if kind == "f" {
                guard fields.count == 4 else { throw invalid() }
                let indices = fields.dropFirst().compactMap { Int($0) }
                guard indices.count == 3, indices.allSatisfy({ $0 > 0 }) else { throw invalid() }
                faces.append(indices.map { $0-1 })
            } else { throw invalid() }
            guard points.count <= 10_000, faces.count <= 20_000 else { throw invalid() }
        }
        guard points.count >= 4, faces.count >= 4 else { throw invalid() }
        let center = points.reduce(SIMD3<Double>.zero,+)/Double(points.count)
        var result: [Triangle] = [], canonicalFaces = Set<[Int]>(), edges: [Edge:[(face:Int,direction:Int)]] = [:]
        var incident: [Int:Set<Int>] = [:], volume = 0.0
        for (index,raw) in faces.enumerated() {
            guard raw.allSatisfy({ points.indices.contains($0) }), Set(raw).count == 3,
                  canonicalFaces.insert(raw.sorted()).inserted else { throw invalid() }
            var f = raw
            let a = points[f[0]], b = points[f[1]], c = points[f[2]], cross = simd_cross(b-a,c-a)
            let length = simd_length(cross)
            guard length.isFinite, length > 1e-14 else { throw invalid() }
            var normal = cross/length
            if simd_dot(normal,center-a) > 0 { normal = -normal; f.swapAt(1,2) }
            guard points.allSatisfy({ simd_dot(normal,$0-a) <= Self.precision }) else { throw invalid() }
            result.append(.init(a:points[f[0]],b:points[f[1]],c:points[f[2]],normal:normal))
            volume += simd_dot(points[f[0]],simd_cross(points[f[1]],points[f[2]]))/6
            for vertex in f { incident[vertex,default:[]].insert(index) }
            for offset in 0..<3 {
                let x = f[offset], y = f[(offset+1)%3]
                edges[Edge(x,y),default:[]].append((index,x < y ? 1 : -1))
            }
        }
        guard incident.count == points.count, volume.isFinite, volume > 1e-12,
              points.count-edges.count+faces.count == 2,
              edges.values.allSatisfy({ $0.count == 2 && $0[0].direction+$0[1].direction == 0 }) else { throw invalid() }
        // Each vertex must have one closed fan, excluding pinched/nonmanifold
        // vertices even when all individual edges happen to have two faces.
        for (vertex,fan) in incident {
            var adjacent: [Int:Set<Int>] = [:]
            for (edge,pair) in edges where edge.a == vertex || edge.b == vertex {
                adjacent[pair[0].face,default:[]].insert(pair[1].face)
                adjacent[pair[1].face,default:[]].insert(pair[0].face)
            }
            var visited = Set<Int>(), pending = [fan.first!]
            while let face = pending.popLast() {
                if visited.insert(face).inserted { pending.append(contentsOf:adjacent[face] ?? []) }
            }
            guard visited == fan, adjacent.values.allSatisfy({ $0.count == 2 }) else { throw invalid() }
        }
        vertices = points; triangles = result
        func normalized(_ raw:SIMD3<Double>)->(SIMD3<Double>,SIMD3<Int>)? {
            let length=simd_length(raw);guard length>1e-10,length.isFinite else{return nil}
            var n=raw/length
            if n.x < -1e-8 || (abs(n.x)<=1e-8 && n.y < -1e-8) || (abs(n.x)<=1e-8 && abs(n.y)<=1e-8 && n.z<0) {n = -n}
            return (n,SIMD3(Int((n.x*1e7).rounded()),Int((n.y*1e7).rounded()),Int((n.z*1e7).rounded())))
        }
        var faceDirections:[SIMD3<Double>]=[],edgeDirections:[SIMD3<Double>]=[]
        var faceKeys=Set<SIMD3<Int>>(),edgeKeys=Set<SIMD3<Int>>()
        for triangle in result {
            if let (n,key)=normalized(triangle.normal),faceKeys.insert(key).inserted {faceDirections.append(n)}
        }
        for (edge,pair) in edges {
            let first=result[pair[0].face],second=result[pair[1].face]
            // A triangulation diagonal is not a polyhedron edge. Coplanarity
            // uses the same one-micron export precision as hull validation.
            let coplanar=[second.a,second.b,second.c].allSatisfy {abs(simd_dot(first.normal,$0-first.a))<=Self.precision} &&
                [first.a,first.b,first.c].allSatisfy {abs(simd_dot(second.normal,$0-second.a))<=Self.precision}
            if !coplanar,let (n,key)=normalized(points[edge.b]-points[edge.a]),edgeKeys.insert(key).inserted {edgeDirections.append(n)}
        }
        localFaceDirections=faceDirections;localEdgeDirections=edgeDirections
    }

    func distance(to point:SIMD3<Double>) throws -> Double {
        guard (0..<3).allSatisfy({ point[$0].isFinite }) else {
            throw ROBGhostMotionError.blocked("An estimated hull query has a nonfinite point.")
        }
        if triangles.allSatisfy({ simd_dot($0.normal,point-$0.a) <= Self.precision }) { return 0 }
        var best = Double.infinity
        for triangle in triangles {
            let closest = Self.closest(point,to:triangle), distance = simd_distance(point,closest)
            guard (0..<3).allSatisfy({ closest[$0].isFinite }), distance.isFinite, distance >= 0 else {
                throw ROBGhostMotionError.blocked("An estimated hull distance is nonfinite. No occupied cell was admitted.")
            }
            best = min(best,distance)
        }
        guard best.isFinite else { throw ROBGhostMotionError.blocked("The estimated hull has no finite surface distance.") }
        return best
    }

    /// Diagnostic-only surface location. distance(to:) above remains the
    /// admission metric, including its conservative zero for inside points.
    func nearestSurfacePoint(to point:SIMD3<Double>)throws->SIMD3<Double> {
        guard [point.x,point.y,point.z].allSatisfy(\.isFinite) else {
            throw ROBGhostMotionError.blocked("A hull surface diagnostic needs a finite point.")
        }
        var closestPoint:SIMD3<Double>?,best=Double.infinity
        for triangle in triangles {
            let candidate=Self.closest(point,to:triangle),distance=simd_distance(point,candidate)
            if distance.isFinite,distance<best {best=distance;closestPoint=candidate}
        }
        guard let closestPoint else {throw ROBGhostMotionError.blocked("The hull surface diagnostic has no finite point.")}
        return closestPoint
    }

    /// Convex-polyhedron SAT clearance. A negative result is penetration
    /// depth along the nearest separating support plane; a positive result is
    /// a conservative surface-gap lower bound. Face normals and edge-cross
    /// axes test actual hulls rather than rotated bounding-box overlap.
    func signedSeparation(to other:Self,frame:simd_double4x4,otherFrame:simd_double4x4) throws ->Double {
        func vector(_ frame:simd_double4x4,_ v:SIMD3<Double>)->SIMD3<Double> {
            let p=frame*SIMD4(v,0);return SIMD3(p.x,p.y,p.z)
        }
        func points(_ frame:simd_double4x4,_ vertices:[SIMD3<Double>])->[SIMD3<Double>] {
            vertices.map {let p=frame*SIMD4($0,1);return SIMD3(p.x,p.y,p.z)}
        }
        var axes:[SIMD3<Double>]=[],seen=Set<SIMD3<Int>>()
        func add(_ raw:SIMD3<Double>) {
            let length=simd_length(raw);guard length>1e-10,length.isFinite else{return}
            var n=raw/length
            if n.x < -1e-8 || (abs(n.x)<=1e-8 && n.y < -1e-8) || (abs(n.x)<=1e-8 && abs(n.y)<=1e-8 && n.z<0) {n = -n}
            let key=SIMD3(Int((n.x*1e7).rounded()),Int((n.y*1e7).rounded()),Int((n.z*1e7).rounded()))
            if seen.insert(key).inserted {axes.append(n)}
        }
        for n in localFaceDirections {add(vector(frame,n))}
        for n in other.localFaceDirections {add(vector(otherFrame,n))}
        let aEdges=localEdgeDirections.map {vector(frame,$0)},bEdges=other.localEdgeDirections.map {vector(otherFrame,$0)}
        for a in aEdges {for b in bEdges {add(simd_cross(a,b))}}
        let a=points(frame,vertices),b=points(otherFrame,other.vertices)
        guard !axes.isEmpty,(a+b).allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}) else {
            throw ROBGhostMotionError.blocked("The estimated convex-hull separation is invalid.")
        }
        // No per-axis map/min/max arrays: this loop is also fast in the
        // commissioning Debug app, where generic collection iteration boxes
        // otherwise made a single proof outlive its fresh depth evidence.
        let signed=a.withUnsafeBufferPointer { ap in b.withUnsafeBufferPointer { bp in
            axes.withUnsafeBufferPointer { directions in
                var result = -Double.infinity,axisIndex=0
                while axisIndex<directions.count {
                    let n=directions[axisIndex]
                    var lowA=Double.infinity,highA = -Double.infinity,lowB=Double.infinity,highB = -Double.infinity
                    var i=0
                    while i<ap.count {let p=ap[i],v=p.x*n.x+p.y*n.y+p.z*n.z;if v<lowA {lowA=v};if v>highA {highA=v};i+=1}
                    i=0
                    while i<bp.count {let p=bp[i],v=p.x*n.x+p.y*n.y+p.z*n.z;if v<lowB {lowB=v};if v>highB {highB=v};i+=1}
                    let gap=max(lowA-highB,lowB-highA)
                    if gap>result {result=gap};axisIndex+=1
                }
                return result
            }
        }}
        guard signed.isFinite else{throw ROBGhostMotionError.blocked("The estimated convex-hull separation is nonfinite.")}
        return signed
    }

    private static func closest(_ p:SIMD3<Double>,to t:Triangle) -> SIMD3<Double> {
        let ab = t.b-t.a, ac = t.c-t.a, ap = p-t.a, d1 = simd_dot(ab,ap), d2 = simd_dot(ac,ap)
        if d1 <= 0 && d2 <= 0 { return t.a }
        let bp = p-t.b, d3 = simd_dot(ab,bp), d4 = simd_dot(ac,bp)
        if d3 >= 0 && d4 <= d3 { return t.b }
        let vc = d1*d4-d3*d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return t.a+(d1/(d1-d3))*ab }
        let cp = p-t.c, d5 = simd_dot(ab,cp), d6 = simd_dot(ac,cp)
        if d6 >= 0 && d5 <= d6 { return t.c }
        let vb = d5*d2-d1*d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return t.a+(d2/(d2-d6))*ac }
        let va = d3*d6-d5*d4
        if va <= 0 && d4-d3 >= 0 && d5-d6 >= 0 { return t.b+((d4-d3)/((d4-d3)+(d5-d6)))*(t.c-t.b) }
        let denominator = 1/(va+vb+vc)
        return t.a+(vb*denominator)*ab+(vc*denominator)*ac
    }
}


/// AABB is a fast sufficient separation proof. When it cannot prove 30 mm,
/// use the same verified closed-convex SAT as the commissioning checker.
/// Positive SAT support-plane gaps are conservative distance lower bounds.
struct ROBWorkspaceSelfProxyClearance {
    let model: ROBGhostRobotModel
    private var catalog: [String:(path:String,sha256:String)]?
    private var hulls: [String:ROBEstimatedConvexHull] = [:]
    init(model:ROBGhostRobotModel) { self.model=model }

    private mutating func hull(_ link:String) throws -> ROBEstimatedConvexHull {
        if let value=hulls[link] {return value}
        if catalog==nil {
            let data=try Data(contentsOf:model.directory.appendingPathComponent("surfaces.json"))
            guard ROBGhostRobotModel.hash(data)==model.geometryID,
                  let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  value["modelID"] as? String==model.modelID,let entries=value["surfaces"] as? [[String:Any]] else {
                throw ROBGhostMotionError.blocked("Convex self-clearance geometry no longer matches the verified model.")
            }
            var loaded:[String:(path:String,sha256:String)]=[:]
            for entry in entries {
                guard let name=entry["link"] as? String,let path=entry["hull"] as? String,
                      let hash=entry["hullSHA256"] as? String,hash.count==64,hash.allSatisfy(\.isHexDigit),
                      loaded[name]==nil,model.hulls[name]==path,!path.contains(".."),!path.hasPrefix("/") else {
                    throw ROBGhostMotionError.blocked("Convex self-clearance hull identity is invalid.")
                }
                loaded[name]=(path,hash)
            }
            catalog=loaded
        }
        guard let record=catalog?[link] else {throw ROBGhostMotionError.blocked("Convex self-clearance hull is missing for \(link).")}
        let data=try Data(contentsOf:model.directory.appendingPathComponent(record.path))
        guard ROBGhostRobotModel.hash(data)==record.sha256,let text=String(data:data,encoding:.utf8) else {
            throw ROBGhostMotionError.blocked("Convex self-clearance hull hash changed for \(link).")
        }
        let value=try ROBEstimatedConvexHull(text:text);hulls[link]=value;return value
    }

    mutating func minimum(vendorLeft:[Double]) throws -> Double {
        try separations(vendorLeft:vendorLeft).values.min() ?? -.infinity
    }

    /// Force one metric for initially deficient pairs throughout a retreat;
    /// switching between two lower bounds must not mimic worsening geometry.
    mutating func separations(vendorLeft:[Double],forceNarrowPairs:Set<String> = []) throws -> [String:Double] {
        let positions=model.positions(vendorLeft:vendorLeft),bounds=model.worldCollisionBounds(positions:positions)
        let arms=bounds.keys.filter{$0.hasPrefix(model.physicalSide+"_") && ($0.hasSuffix("_Link") || $0==model.toolLink)}.sorted()
        let proxies=bounds.keys.filter{$0.contains("track") || $0.contains("flipper") || $0.contains("sprocket")}.sorted()
        guard arms.count>=8,!proxies.isEmpty else {throw ROBGhostMotionError.blocked("The full-arm or tread convex proxy catalog is incomplete.")}
        var frames:[String:simd_double4x4]?,result:[String:Double]=[:]
        for arm in arms {for proxy in proxies {
            let a=bounds[arm]!,b=bounds[proxy]!,key=arm+"|"+proxy
            let broad=simd_length(simd_max(.zero,simd_max(a.low-b.high,b.low-a.high)))
            guard broad.isFinite else {throw ROBGhostMotionError.blocked("Self-clearance bounds are nonfinite.")}
            if broad>=0.030 && !forceNarrowPairs.contains(key) {result[key]=broad;continue}
            if frames==nil {frames=model.frames(positions)}
            guard let frame=frames?[arm],let otherFrame=frames?[proxy] else {
                throw ROBGhostMotionError.blocked("Convex self-clearance lost an actual link transform.")
            }
            let left=try hull(arm),right=try hull(proxy)
            result[key]=try left.signedSeparation(to:right,frame:frame,otherFrame:otherFrame)
        }}
        return result
    }
}

/// Original retained source-return bounds, before conservative voxel dilation.
/// They remain obstacles; this value supplies no self label or free space.
struct ROBWorkspaceOccupiedReturnBounds: Codable, Equatable {
    let lowMeters:[Double],highMeters:[Double]
}

enum ROBWorkspaceVoxelState: UInt8, Codable { case unknown, free, occupied }

/// A map is evidence from this camera/robot scene, never arm authority. Free
/// space must have been observed; absence of an obstacle is not free space.
struct ROBWorkspaceOccupiedSourceGroup:Codable,Equatable {
    let sourceVoxel:[Int]
    let bounds:ROBWorkspaceOccupiedReturnBounds
    var id:String {sourceVoxel.map(String.init).joined(separator:",")}
}

protocol ROBWorkspaceCollisionMap {
    var sceneID: UUID { get }
    var cameraGeneration: UUID { get }
    var sessionGeneration: UInt64 { get }
    var modelID: String { get }
    var geometryID: String { get }
    var mappingID: String { get }
    var createdAtMilliseconds: Double { get }
    var oldestCapturedAtMilliseconds: Double { get }
    var lastCapturedAtMilliseconds: Double { get }
    var voxelSizeMeters: Double { get }
    var registrationID: String? { get }
    var registrationUncertaintyMeters: Double? { get }
    var fingerprint: String { get }
    var visualCalibrationScope: ROBWorkspaceVisualCalibrationMapScope? { get }
    var originalOccupiedReturnBounds:[ROBWorkspaceOccupiedReturnBounds]? {get}
    var originalOccupiedSourceGroups:[ROBWorkspaceOccupiedSourceGroup]? {get}
    func state(at point: SIMD3<Double>) -> ROBWorkspaceVoxelState
    func state(inBoundsLow low: SIMD3<Double>, high: SIMD3<Double>) -> ROBWorkspaceVoxelState
    func containsTargetObservation(sequence: UInt64, capturedAtMilliseconds: Double) -> Bool
    func occupiedSampleBounds(at point:SIMD3<Double>) -> (low:SIMD3<Double>,high:SIMD3<Double>)?
    func occupiedSampleSubBounds(at point:SIMD3<Double>) -> [ROBWorkspaceOccupiedReturnBounds]?
}

extension ROBWorkspaceCollisionMap {
    var visualCalibrationScope: ROBWorkspaceVisualCalibrationMapScope? { nil }
    var originalOccupiedReturnBounds:[ROBWorkspaceOccupiedReturnBounds]? {nil}
    var originalOccupiedSourceGroups:[ROBWorkspaceOccupiedSourceGroup]? {nil}
    func containsTargetObservation(sequence:UInt64,capturedAtMilliseconds:Double) -> Bool { false }
    func occupiedSampleBounds(at point:SIMD3<Double>) -> (low:SIMD3<Double>,high:SIMD3<Double>)? { nil }
    func occupiedSampleSubBounds(at point:SIMD3<Double>) -> [ROBWorkspaceOccupiedReturnBounds]? { nil }
    /// An implementation may accelerate this with an octree/bitset, but must
    /// preserve the requirement that every intersecting voxel is known free.
    func state(inBoundsLow low: SIMD3<Double>, high: SIMD3<Double>) -> ROBWorkspaceVoxelState {
        let size = voxelSizeMeters
        guard size.isFinite, size > 0,
              (0..<3).allSatisfy({ low[$0].isFinite && high[$0].isFinite && abs(low[$0]) <= 20 && abs(high[$0]) <= 20 && low[$0] <= high[$0] }) else { return .unknown }
        let lo = (0..<3).map { Int(floor(low[$0]/size)) }, hi = (0..<3).map { Int(floor(high[$0]/size)) }
        guard zip(lo,hi).allSatisfy({ $1 >= $0 && $1-$0 <= 200 }),
              zip(lo,hi).reduce(1,{ $0*($1.1-$1.0+1) }) <= 250_000 else { return .unknown }
        for x in lo[0]...hi[0] { for y in lo[1]...hi[1] { for z in lo[2]...hi[2] {
            let point = SIMD3((Double(x)+0.5)*size,(Double(y)+0.5)*size,(Double(z)+0.5)*size)
            switch state(at:point) { case .free: continue; case .occupied: return .occupied; case .unknown: return .unknown }
        } } }
        return .free
    }
}

/// Evidence identity only. It supplies no authorization or measured transform.
struct ROBWorkspaceVisualCalibrationMapScope: Codable, Equatable {
    let bodyMotionIdentity: String
    let bodyContextIsCurrent: Bool
    let estimatedCameraProjectionIdentity: String
    let observationPoseIdentity: String
    let observedFrameCount: Int
}

/// Frozen scope for one explicitly authorized local recycling experiment.
/// The runtime broker must independently confirm its active exact-job receipt
/// before planning and every dispatch. Decoding this value never grants motion.
struct ROBWorkspaceVisualCalibrationTrial: Codable, Equatable {
    let receiptID: String
    let receiptSHA256: String
    let appSessionID: String
    let command: String
    let canCount: Int
    let summarySHA256: String
    let authorizationContextIdentity: String
    let sessionGeneration: UInt64
    let sceneID: UUID
    let cameraGeneration: UUID
    let modelID: String
    let geometryID: String
    let mappingID: String
    let mapFingerprint: String
    let bodyMotionIdentity: String
    let estimatedCameraProjectionIdentity: String
    let observationPoseIdentity: String
    /// Root binds the current held neck and fresh arm start to this hash and
    /// checks it against live feedback; it is not inferred from commanded FK.
    let currentPoseIdentity: String
    let baseline: [Double]
    let issuedAtMilliseconds: Double
    let expiresAtMilliseconds: Double
    /// An operator-trial assumption, NEVER measured registration uncertainty.
    let assumedSpatialErrorMeters: Double

    var valid: Bool {
        func hash(_ value: String) -> Bool {value.count == 64 && value.allSatisfy(\.isHexDigit)}
        return !receiptID.isEmpty && receiptID.utf8.count <= 128 && !appSessionID.isEmpty &&
            appSessionID.utf8.count <= 128 && !authorizationContextIdentity.isEmpty &&
            authorizationContextIdentity.utf8.count <= 256 && (1...8).contains(canCount) &&
            ["left_recycle_cans","right_recycle_cans"].contains(command) &&
            [receiptSHA256,summarySHA256,mapFingerprint,estimatedCameraProjectionIdentity,observationPoseIdentity,currentPoseIdentity].allSatisfy(hash) &&
            !bodyMotionIdentity.isEmpty && bodyMotionIdentity.utf8.count <= 128 && sessionGeneration > 0 &&
            baseline.count == 7 && baseline.allSatisfy(\.isFinite) &&
            issuedAtMilliseconds.isFinite && expiresAtMilliseconds.isFinite &&
            expiresAtMilliseconds > issuedAtMilliseconds && expiresAtMilliseconds-issuedAtMilliseconds <= 600_000 &&
            assumedSpatialErrorMeters.isFinite && (0.025...0.15).contains(assumedSpatialErrorMeters)
    }
    var detail: String {
        String(format:"Operator-authorized visual calibration trial; camera alignment unmeasured; assumed spatial allowance %.1f mm. No registration authority.",assumedSpatialErrorMeters*1000)
    }
}

/// A measured object envelope, expressed in the tool frame. No object name,
/// remembered world position, gripper command or permission is encoded here.
struct ROBWorkspaceCarriedObject: Codable, Equatable {
    let measurementID: String
    let centerInToolMeters: [Double]
    let halfExtentsMeters: [Double]
    var valid: Bool {
        !measurementID.isEmpty && measurementID.count <= 128 && centerInToolMeters.count == 3 && halfExtentsMeters.count == 3 &&
        centerInToolMeters.allSatisfy({ $0.isFinite && abs($0) <= 0.5 }) &&
        halfExtentsMeters.allSatisfy({ $0.isFinite && (0.005...0.30).contains($0) })
    }
    var fingerprint:String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return ROBGhostRobotModel.hash((try? encoder.encode(self)) ?? Data())
    }
}

/// Frozen native verification identities, not a possession sensor or a grant.
/// The runtime must separately match its active, memory-only native phase;
/// decoding this record cannot authenticate the visual evidence it names.
struct ROBWorkspaceVerifiedAttachedCan: Codable, Equatable {
    let nativePhaseID:UUID
    let nativeVisualEvidenceSHA256:String
    let sourceContactFingerprint:String
    let sourceCylinderFingerprint:String
    let sourceMapFingerprint:String
    let payloadFingerprint:String
    let bodyMotionIdentity:String
    let sessionGeneration:UInt64
    let verificationFirstSequence:UInt64
    let verificationLastSequence:UInt64
    let verificationCapturedAtMilliseconds:Double
    let fixedViewIdentity:String
    let targetIdentity:String
    let baseline:[Double]
    let baselineTelemetrySequence:UInt64
    let baselineCapturedAtMilliseconds:Double

    var valid:Bool {
        func hash(_ value:String)->Bool {value.utf8.count==64 && value.allSatisfy{$0.isHexDigit && !$0.isUppercase}}
        return [nativeVisualEvidenceSHA256,sourceContactFingerprint,sourceCylinderFingerprint,sourceMapFingerprint,payloadFingerprint].allSatisfy(hash) &&
            !bodyMotionIdentity.isEmpty && bodyMotionIdentity.utf8.count<=128 && sessionGeneration>0 &&
            verificationFirstSequence>0 && verificationLastSequence>verificationFirstSequence &&
            verificationCapturedAtMilliseconds.isFinite &&
            !fixedViewIdentity.isEmpty && fixedViewIdentity.utf8.count<=1024 &&
            !targetIdentity.isEmpty && targetIdentity.utf8.count<=1024 &&
            baseline.count==7 && baseline.allSatisfy{$0.isFinite && abs($0)<=3.1} && baselineTelemetrySequence>0 &&
            baselineCapturedAtMilliseconds.isFinite &&
            baselineCapturedAtMilliseconds>=verificationCapturedAtMilliseconds-150
    }
}

/// A frozen exception for intentional contact with ONE measured can. It never
/// clears a map cell, creates free space or exempts another link/table/target.
/// Cylinder endpoints are measured axis centers, not visible front-wall points.
struct ROBWorkspaceIntentionalContact: Codable, Equatable {
    let measurementID: String
    let observationSequence: UInt64
    let capturedAtMilliseconds: Double
    let sceneID: UUID
    let cameraGeneration: UUID
    let mapFingerprint: String
    let modelID: String
    let geometryID: String
    let mappingID: String
    let toolLink: String
    let topCenterMeters: [Double]
    let bottomCenterMeters: [Double]
    let diameterMeters: Double
    let firstContactStepIndex: Int
    let gripStepIndex: Int?
    let releaseStepIndex: Int?
    let stepCount: Int
    /// Explicit measured radial fit tolerance, never the much larger global
    /// registration uncertainty or a generic obstacle-clearance allowance.
    var radialFitUncertaintyMeters:Double = 0
    /// Only an explicit local visual trial may finish holding a verified lift.
    var terminalGraspHold:Bool? = nil
    /// A distinct carry phase starts with an already attached can; nil keeps
    /// legacy grasp/release archives and their fingerprints unchanged.
    var verifiedAttachment:ROBWorkspaceVerifiedAttachedCan? = nil

    var fingerprint:String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return ROBGhostRobotModel.hash((try? encoder.encode(self)) ?? Data())
    }
    /// Reconstructible original observation identity, independent of the new
    /// carry phase's step boundaries. Every cylinder/source field participates.
    var sourceCylinderFingerprint:String {
        let source:[String:Any]=["measurementID":measurementID,"observationSequence":NSNumber(value:observationSequence),
            "capturedAtMilliseconds":capturedAtMilliseconds,"sceneID":sceneID.uuidString,
            "cameraGeneration":cameraGeneration.uuidString,"mapFingerprint":mapFingerprint,
            "modelID":modelID,"geometryID":geometryID,"mappingID":mappingID,"toolLink":toolLink,
            "topCenterMeters":topCenterMeters,"bottomCenterMeters":bottomCenterMeters,"diameterMeters":diameterMeters,
            "radialFitUncertaintyMeters":radialFitUncertaintyMeters]
        return ROBGhostRobotModel.hash((try?JSONSerialization.data(withJSONObject:source,options:[.sortedKeys])) ?? Data())
    }
    func matchesSourceContact(_ original:ROBWorkspaceIntentionalContact)->Bool {
        guard valid,original.valid,original.verifiedAttachment==nil,original.gripStepIndex != nil,
              let attachment=verifiedAttachment else{return false}
        return sourceCylinderFingerprint==original.sourceCylinderFingerprint &&
            attachment.sourceCylinderFingerprint==original.sourceCylinderFingerprint &&
            attachment.sourceContactFingerprint==original.fingerprint && attachment.sourceMapFingerprint==original.mapFingerprint
    }
    private var axis:SIMD3<Double> {
        SIMD3(topCenterMeters[0]-bottomCenterMeters[0],topCenterMeters[1]-bottomCenterMeters[1],topCenterMeters[2]-bottomCenterMeters[2])
    }
    var valid:Bool {
        guard !measurementID.isEmpty,measurementID.utf8.count<=128,observationSequence>0,
              capturedAtMilliseconds.isFinite,mapFingerprint.count==64,
              topCenterMeters.count==3,bottomCenterMeters.count==3,
              (topCenterMeters+bottomCenterMeters).allSatisfy({ $0.isFinite && abs($0)<=5 }),
              diameterMeters.isFinite,(0.04...0.09).contains(diameterMeters),
              radialFitUncertaintyMeters.isFinite,(0...0.003).contains(radialFitUncertaintyMeters),
              (1...80).contains(stepCount),firstContactStepIndex>=0 else { return false }
        if let attachment=verifiedAttachment {
            guard attachment.valid,attachment.sourceCylinderFingerprint==sourceCylinderFingerprint,
                  stepCount>=3,gripStepIndex==nil,terminalGraspHold != true,firstContactStepIndex==0,
                  let releaseStepIndex,(1..<stepCount-1).contains(releaseStepIndex) else{return false}
        } else {
            guard let gripStepIndex,firstContactStepIndex<=gripStepIndex else{return false}
            if let releaseStepIndex {
                guard terminalGraspHold != true,gripStepIndex<releaseStepIndex,releaseStepIndex<stepCount else{return false}
            } else {
                guard terminalGraspHold == true,gripStepIndex<stepCount-1 else{return false}
            }
        }
        let length=simd_length(axis)
        return (0.09...0.18).contains(length) && axis.z>=0.6*length
    }
    func validate(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,nowMilliseconds:Double) throws {
        guard valid,sceneID==map.sceneID,cameraGeneration==map.cameraGeneration,mapFingerprint==map.fingerprint,
              modelID==model.modelID,geometryID==model.geometryID,mappingID==model.selectedMappingID,
              toolLink==model.toolLink,(0...ROBWorkspaceCollisionPlan.maximumMapAgeMilliseconds).contains(nowMilliseconds-capturedAtMilliseconds),
              capturedAtMilliseconds>=map.oldestCapturedAtMilliseconds-1,
              capturedAtMilliseconds<=map.lastCapturedAtMilliseconds+1,
              map.containsTargetObservation(sequence:observationSequence,capturedAtMilliseconds:capturedAtMilliseconds) else {
            throw ROBGhostMotionError.blocked("Intentional can contact needs a fresh measured cylinder from this exact scene, map, camera, tool and recorded observation.")
        }
        if let attachment=verifiedAttachment {
            guard attachment.sourceCylinderFingerprint==sourceCylinderFingerprint,
                  attachment.sourceMapFingerprint==map.fingerprint,attachment.sessionGeneration==map.sessionGeneration,
                  attachment.verificationCapturedAtMilliseconds>=capturedAtMilliseconds,
                  (0...ROBWorkspaceCollisionPlan.maximumMapAgeMilliseconds).contains(nowMilliseconds-attachment.verificationCapturedAtMilliseconds),
                  (0...ROBWorkspaceCollisionPlan.maximumMapAgeMilliseconds).contains(nowMilliseconds-attachment.baselineCapturedAtMilliseconds),
                  map.visualCalibrationScope.map({$0.bodyContextIsCurrent && $0.bodyMotionIdentity==attachment.bodyMotionIdentity}) ?? true else {
                throw ROBGhostMotionError.blocked("Verified attached-can source map, native verification, body, held baseline or session changed.")
            }
        }
    }
    func permits(label:String,payload:ROBWorkspaceCarriedObject?,stepIndex:Int) -> Bool {
        guard valid,stepIndex>=firstContactStepIndex,stepIndex<=(releaseStepIndex ?? stepCount-1) else { return false }
        if label==toolLink { return true }
        return label=="carried object" && payload?.measurementID==measurementID &&
            (verifiedAttachment != nil || gripStepIndex.map({stepIndex>$0}) == true)
    }
    /// Pure structural/path binding only. The caller still needs the runtime's
    /// active native verification record before any carrying or jaw dispatch.
    func validateAttachedPhase(baseline:[Double],steps:[ROBLeftGestureProposal.Step],payload:ROBWorkspaceCarriedObject?,
        contactStepIndex:Int?,carryingAtStart:Bool?) throws {
        guard let attachment=verifiedAttachment else{return}
        guard valid,let payload,payload.valid,payload.measurementID==measurementID,
              payload.fingerprint==attachment.payloadFingerprint,
              !steps.contains(where:{$0.jawAction == .prepare || $0.jawAction == .grip}),
              let release=releaseStepIndex else {
            throw ROBGhostMotionError.blocked("An attached-can phase needs its exact verified payload and cannot prepare or grip again.")
        }
        if let index=contactStepIndex {
            guard (0..<stepCount).contains(index),steps.count==1,
                  carryingAtStart == (index<=release),
                  (steps[0].jawAction == .release) == (index==release),
                  index != 0 || (baseline.count==7 && 1.5*zip(baseline,attachment.baseline).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.002) else {
                throw ROBGhostMotionError.blocked("The verified attached-can segment changed its explicit carrying state, held baseline or frozen release phase.")
            }
        } else {
            guard carryingAtStart==true,baseline==attachment.baseline,steps.count==stepCount,
                  steps[release].jawAction == .release,steps.filter({$0.jawAction == .release}).count==1,
                  ROBArmRoutinePlan.near(steps[release-1].positions,steps[release].positions,tolerance:0.001) else {
                throw ROBGhostMotionError.blocked("The verified attached-can route must start carrying at its exact held baseline and retain one stationary release.")
            }
        }
    }
    /// All eight voxel corners must lie inside the measured finite cylinder.
    /// A center-only/ROI test could also erase an adjacent table or second can.
    func containsWholeVoxel(center:SIMD3<Double>,size:Double) -> Bool {
        guard valid,size.isFinite,(0.01...0.04).contains(size) else { return false }
        return containsMeasuredBounds(low:center-SIMD3(repeating:size/2),high:center+SIMD3(repeating:size/2))
    }
    func containsMeasuredBounds(low:SIMD3<Double>,high:SIMD3<Double>) -> Bool {
        guard valid,(0..<3).allSatisfy({low[$0].isFinite && high[$0].isFinite && abs(low[$0])<=5 && abs(high[$0])<=5 && low[$0]<=high[$0]}) else { return false }
        let bottom=SIMD3(bottomCenterMeters[0],bottomCenterMeters[1],bottomCenterMeters[2])
        let length=simd_length(axis),unit=axis/length,radius=diameterMeters/2+radialFitUncertaintyMeters
        for x in [low.x,high.x] { for y in [low.y,high.y] { for z in [low.z,high.z] {
            let delta=SIMD3(x,y,z)-bottom,t=simd_dot(delta,unit)
            guard t>=0,t<=length,simd_length(delta-unit*t)<=radius else { return false }
        } } }
        return true
    }
}

/// Evidence for a zero-new-sweep static-world pair at the selected arm mount.
/// Its returns remain in the map and in every moving-link query. This creates
/// no observed/free cells and makes no physical self-classification claim.
struct ROBWorkspaceStaticRobotLinkEvidence: Codable, Equatable {
    let kind:String
    let link:String
    let bodyMotionIdentity:String
    let frameColumnMajor:[Double]
    let lowMeters:[Double]
    let highMeters:[Double]
}

struct ROBWorkspaceCollisionContext: Codable, Equatable {
    let sceneID: UUID
    let cameraGeneration: UUID
    let sessionGeneration: UInt64
    let modelID: String
    let geometryID: String
    let mappingID: String
    let mapFingerprint: String
    let registrationID: String?
    let registrationUncertaintyMeters: Double?
    let oldestCapturedAtMilliseconds: Double
    let lastCapturedAtMilliseconds: Double
    let checkedAtMilliseconds: Double
    var intentionalContactFingerprint: String? = nil
    var visualTrial: ROBWorkspaceVisualCalibrationTrial? = nil
    var skippedStaticRobotLinks:[ROBWorkspaceStaticRobotLinkEvidence]? = nil
    var spatialErrorAllowanceMeters: Double {
        visualTrial?.assumedSpatialErrorMeters ?? registrationUncertaintyMeters ?? .infinity
    }
}

/// One EMPTY start-only escape, never an ordinary route/contact exemption.
/// The broker independently checks its active receipt and fresh measured pose.
struct ROBWorkspaceInitialEmptyRetreat: Codable, Equatable {
    let context: ROBWorkspaceCollisionContext
    let baseline: [Double]
    let goal: [Double]
    let step: ROBLeftGestureProposal.Step
    let checkedPoseCount: Int
    let maximumHullTravelMeters: Double
    let initialProxyClearancesMeters: [String:Double]
    let endpointProxyClearancesMeters: [String:Double]
    let initialEmptyStateAssumed: Bool
    let emptyStateEvidenceSource: String

    func validate(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,
        sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,
        measuredAtMilliseconds:Double,measuredBaseline:[Double],emptyTrialEligibility:Bool,emptyStateEvidenceSource:String) throws {
        let startDriftBound=1.5*zip(measuredBaseline,baseline).reduce(0.0){$0+abs($1.0-$1.1)}
        guard context.visualTrial==trial,context.mapFingerprint==map.fingerprint,
              ROBArmRoutinePlan.near(measuredBaseline,baseline,tolerance:0.004),
              startDriftBound.isFinite,startDriftBound<=0.003,
              maximumHullTravelMeters.isFinite,maximumHullTravelMeters+startDriftBound<=0.060,
              step.positions==goal,step.seconds==4,step.jawAction==nil,initialEmptyStateAssumed,
              self.emptyStateEvidenceSource==emptyStateEvidenceSource else {
            throw ROBGhostMotionError.blocked("The initial EMPTY retreat proof or fresh measured start changed.")
        }
        let checked=try ROBWorkspaceCollisionPlan.reviewInitialEmptyVisualCalibrationRetreat(from:baseline,to:goal,
            map:map,model:model,generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,
            nowMilliseconds:nowMilliseconds,trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,
            emptyTrialEligibility:emptyTrialEligibility,emptyStateEvidenceSource:emptyStateEvidenceSource)
        guard checked.checkedPoseCount==checkedPoseCount,checked.maximumHullTravelMeters==maximumHullTravelMeters,
              checked.initialProxyClearancesMeters==initialProxyClearancesMeters,
              checked.endpointProxyClearancesMeters==endpointProxyClearancesMeters,
              checked.context.skippedStaticRobotLinks==context.skippedStaticRobotLinks else {
            throw ROBGhostMotionError.blocked("The initial EMPTY retreat geometry proof changed.")
        }
    }
}

/// Bounded model-estimated endpoints; each still needs the complete initial
/// empty-retreat proof and an independent fresh dispatch-start reproof.
struct ROBWorkspaceInitialRetreatCandidate:Codable {
    let name:String,offset:[Double],goal:[Double],estimatedToolDeltaMeters:[Double]
    let estimatedOutwardForearmDeltaMeters:Double
}

struct ROBWorkspaceInitialRetreatAttempt:Codable {
    let name:String,offset:[Double],goal:[Double],estimatedToolDeltaMeters:[Double]
    let estimatedOutwardForearmDeltaMeters:Double
    let admitted:Bool,detail:String
    let maximumHullTravelMeters:Double?,checkedPoseCount:Int?
}

struct ROBWorkspaceInitialRetreatSelection:Codable {
    let proof:ROBWorkspaceInitialEmptyRetreat?
    let attempts:[ROBWorkspaceInitialRetreatAttempt]
    let rejectionDetail:String
    let representativeRejectedGoal:[Double]?
    let budgetExhausted:Bool
    static func representativeRejection(_ attempts:[ROBWorkspaceInitialRetreatAttempt])->ROBWorkspaceInitialRetreatAttempt? {
        // An occupied corridor must not hide an alternate corridor that only
        // needs more observation. Its precise native diagnostic remains tied
        // to that same attempted goal for the next targeted depth view.
        attempts.first{$0.detail.contains("enters unobserved space.")} ??
            attempts.first{$0.detail.contains("would intersect an observed workspace obstacle.")} ?? attempts.last
    }
}

/// Full-arm planning/checking against a fresh, registered RGB-D map. The
/// registered hanging/front corridor gets exactly the same checks as a new
/// connector. All output remains a proposal until the normal runtime grant.
struct ROBWorkspaceCollisionPlan: Codable, Equatable {
    let context: ROBWorkspaceCollisionContext
    let baseline: [Double]
    let goal: [Double]
    let steps: [ROBLeftGestureProposal.Step]
    let payload: ROBWorkspaceCarriedObject?
    let checkedPoseCount: Int
    var intentionalContact: ROBWorkspaceIntentionalContact? = nil
    /// nil reviews the full frozen task; a runtime actual-start review can
    /// check one logical task segment without changing its contact stage.
    var contactStepIndex: Int? = nil
    var carryingAtStart: Bool? = nil
    static let maximumMapAgeMilliseconds = 60_000.0
    static let maximumRegistrationUncertaintyMeters = 0.05
    static let sweptPointTravelMeters = 0.005
    static let mechanicalClearanceMeters = 0.02
    // The model has one rigid gripper proxy, not measured moving finger meshes.
    // Cover the open jaws on every connector; never pretend closed proxy mesh
    // bounds establish open-jaw clearance beside the table.
    static let openJawAdditionalMarginMeters = 0.04
    static let maximumPoseChecks = 12_000
    static let maximumPlanningSeconds = 10.0

    static func invariantSelectedArmBase(model:ROBGhostRobotModel,positions:[String:Double],
        link:String,bodyMotionIdentity:String)->ROBWorkspaceStaticRobotLinkEvidence? {
        guard link==model.physicalSide+"_base_link",!bodyMotionIdentity.isEmpty else{return nil}
        var child=link,seen=Set<String>()
        while child != "base_link" {
            guard seen.insert(child).inserted,let joint=model.joints.first(where:{$0.child==child}),
                  !joint.name.hasPrefix(model.armJointPrefix) else{return nil}
            // The selected-arm mount itself is rigid; body articulation is
            // frozen independently by the trial/map body identity.
            if child==link && joint.kind != "fixed" {return nil}
            child=joint.parent
        }
        guard let frame=model.frames(positions)[link],let box=model.worldCollisionBounds(positions:positions)[link] else{return nil}
        let matrix=(0..<4).flatMap{c in (0..<4).map{r in frame[c][r]}}
        guard matrix.allSatisfy(\.isFinite),[box.low.x,box.low.y,box.low.z,box.high.x,box.high.y,box.high.z].allSatisfy(\.isFinite) else{return nil}
        return .init(kind:"skipped_static_robot_link",link:link,bodyMotionIdentity:bodyMotionIdentity,frameColumnMajor:matrix,
            lowMeters:[box.low.x,box.low.y,box.low.z],highMeters:[box.high.x,box.high.y,box.high.z])
    }

    /// An explicit visual trial may defer only this proven fixed mount's own
    /// world pair. Every moving shape still checks the unchanged map, even
    /// when the same return is also close to the mount. No source is erased.
    static func deferredStaticWorldPair(model:ROBGhostRobotModel,positions:[String:Double],link:String,
        map:any ROBWorkspaceCollisionMap,context:ROBWorkspaceCollisionContext,
        prior:ROBWorkspaceStaticRobotLinkEvidence?)throws->ROBWorkspaceStaticRobotLinkEvidence? {
        guard let trial=context.visualTrial,link==model.physicalSide+"_base_link" else{return nil}
        guard context.modelID==model.modelID,context.geometryID==model.geometryID,context.mappingID==model.selectedMappingID,
              map.modelID==context.modelID,map.geometryID==context.geometryID,map.mappingID==context.mappingID,
              map.sceneID==context.sceneID,map.cameraGeneration==context.cameraGeneration,
              map.sessionGeneration==context.sessionGeneration,map.fingerprint==context.mapFingerprint,
              let scope=map.visualCalibrationScope,scope.bodyContextIsCurrent,scope.bodyMotionIdentity==trial.bodyMotionIdentity,
              let fixed=invariantSelectedArmBase(model:model,positions:positions,link:link,bodyMotionIdentity:trial.bodyMotionIdentity) else {
            throw ROBGhostMotionError.blocked("The deferred static-world pair lost its fixed mount, body or exact source context.")
        }
        let evidence=ROBWorkspaceStaticRobotLinkEvidence(kind:"deferred_static_world_pair",link:fixed.link,
            bodyMotionIdentity:fixed.bodyMotionIdentity,frameColumnMajor:fixed.frameColumnMajor,
            lowMeters:fixed.lowMeters,highMeters:fixed.highMeters)
        guard prior==nil || prior==evidence else {
            throw ROBGhostMotionError.blocked("The deferred static-world pair changed transform or bounds during the reviewed path.")
        }
        return evidence
    }

    /// Planning takes the intersection of converted model limits and the
    /// exact raw-coordinate ranges the existing gateway accepts.
    static func jointBounds(model: ROBGhostRobotModel) -> [ClosedRange<Double>] {
        (0..<7).map { index in
            let joint = model.joints.first { $0.name == "\(model.armJointPrefix)\(index+1)" }!
            let raw = ROBArmJointLimits.radians[index]
            return max(raw.lowerBound,joint.lower+model.armUprightPrior[index])...min(raw.upperBound,joint.upper+model.armUprightPrior[index])
        }
    }

    static func validateMap(_ map: any ROBWorkspaceCollisionMap, model: ROBGhostRobotModel, generation: UInt64,
                            sceneID: UUID, cameraGeneration: UUID, nowMilliseconds: Double) throws -> ROBWorkspaceCollisionContext {
        guard generation > 0, map.sessionGeneration == generation, map.sceneID == sceneID,
              map.cameraGeneration == cameraGeneration, map.modelID == model.modelID,
              map.geometryID == model.geometryID, map.mappingID == model.selectedMappingID,
              map.fingerprint.count == 64 else {
            throw ROBGhostMotionError.blocked("The workspace map belongs to another robot, scene, camera or arm connection. Scan again before moving.")
        }
        guard let registrationID = map.registrationID, !registrationID.isEmpty,
              let uncertainty = map.registrationUncertaintyMeters, uncertainty.isFinite,
              (0...maximumRegistrationUncertaintyMeters).contains(uncertainty) else {
            throw ROBGhostMotionError.blocked("Measure camera-to-arm registration and its error before using the depth map for arm clearance. The current neck-camera prior is not a calibrated collision map.")
        }
        let times = [nowMilliseconds,map.createdAtMilliseconds,map.oldestCapturedAtMilliseconds,map.lastCapturedAtMilliseconds]
        guard times.allSatisfy(\.isFinite), map.oldestCapturedAtMilliseconds <= map.lastCapturedAtMilliseconds,
              map.lastCapturedAtMilliseconds <= map.createdAtMilliseconds+5,
              (0...maximumMapAgeMilliseconds).contains(nowMilliseconds-map.oldestCapturedAtMilliseconds),
              (0...maximumMapAgeMilliseconds).contains(nowMilliseconds-map.lastCapturedAtMilliseconds),
              map.voxelSizeMeters.isFinite, (0.01...0.04).contains(map.voxelSizeMeters) else {
            throw ROBGhostMotionError.blocked("Workspace free-space evidence is stale or invalid. Hold the arm and scan the entire route again.")
        }
        return .init(sceneID:sceneID,cameraGeneration:cameraGeneration,sessionGeneration:generation,modelID:model.modelID,
            geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:map.fingerprint,
            registrationID:registrationID,registrationUncertaintyMeters:uncertainty,
            oldestCapturedAtMilliseconds:map.oldestCapturedAtMilliseconds,lastCapturedAtMilliseconds:map.lastCapturedAtMilliseconds,
            checkedAtMilliseconds:nowMilliseconds)
    }

    /// Explicit experimental admission. Ordinary validateMap still rejects the
    /// same nil-registration map. Authority is checked by the runtime broker.
    static func validateVisualCalibrationTrialMap(_ map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,
        nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial) throws -> ROBWorkspaceCollisionContext {
        guard trial.valid, nowMilliseconds.isFinite,
              (trial.issuedAtMilliseconds...trial.expiresAtMilliseconds).contains(nowMilliseconds),
              trial.sessionGeneration == generation, trial.sceneID == sceneID, trial.cameraGeneration == cameraGeneration,
              trial.command.hasPrefix(model.physicalSide + "_"),
              trial.modelID == model.modelID, trial.geometryID == model.geometryID, trial.mappingID == model.selectedMappingID,
              map.sessionGeneration == generation, map.sceneID == sceneID, map.cameraGeneration == cameraGeneration,
              map.modelID == model.modelID, map.geometryID == model.geometryID, map.mappingID == model.selectedMappingID,
              map.fingerprint == trial.mapFingerprint, map.registrationID == nil, map.registrationUncertaintyMeters == nil,
              let scope = map.visualCalibrationScope, scope.bodyContextIsCurrent, scope.observedFrameCount >= 2,
              scope.bodyMotionIdentity == trial.bodyMotionIdentity,
              scope.estimatedCameraProjectionIdentity == trial.estimatedCameraProjectionIdentity,
              scope.observationPoseIdentity == trial.observationPoseIdentity else {
            throw ROBGhostMotionError.blocked("The operator visual-calibration trial receipt scope, expiry, map, body, projection or pose evidence changed. No estimated travel admitted.")
        }
        let times = [map.createdAtMilliseconds,map.oldestCapturedAtMilliseconds,map.lastCapturedAtMilliseconds]
        guard times.allSatisfy(\.isFinite), map.oldestCapturedAtMilliseconds <= map.lastCapturedAtMilliseconds,
              map.lastCapturedAtMilliseconds <= map.createdAtMilliseconds+5,
              (0...maximumMapAgeMilliseconds).contains(nowMilliseconds-map.oldestCapturedAtMilliseconds),
              (0...maximumMapAgeMilliseconds).contains(nowMilliseconds-map.lastCapturedAtMilliseconds),
              map.voxelSizeMeters.isFinite, (0.01...0.04).contains(map.voxelSizeMeters) else {
            throw ROBGhostMotionError.blocked("Workspace free-space evidence is stale or invalid. Hold the arm and scan the entire route again.")
        }
        return .init(sceneID:sceneID,cameraGeneration:cameraGeneration,sessionGeneration:generation,
            modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:map.fingerprint,
            registrationID:nil,registrationUncertaintyMeters:nil,oldestCapturedAtMilliseconds:map.oldestCapturedAtMilliseconds,
            lastCapturedAtMilliseconds:map.lastCapturedAtMilliseconds,checkedAtMilliseconds:nowMilliseconds,visualTrial:trial)
    }

    /// Check a complete fixed proposal, including presentation, recovery,
    /// approach, carrying and retreat. No saved-route or TCP-only exemption.
    static func review(baseline: [Double], steps: [ROBLeftGestureProposal.Step], map: any ROBWorkspaceCollisionMap,
                       model: ROBGhostRobotModel, generation: UInt64, sceneID: UUID, cameraGeneration: UUID,
                       nowMilliseconds: Double, payload: ROBWorkspaceCarriedObject? = nil,
                       intentionalContact:ROBWorkspaceIntentionalContact? = nil,contactStepIndex:Int? = nil,
                       carryingAtStart:Bool? = nil) throws -> Self {
        let context = try validateMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
        return try reviewUsingContext(baseline:baseline,steps:steps,map:map,model:model,context:context,
            nowMilliseconds:nowMilliseconds,payload:payload,intentionalContact:intentionalContact,
            contactStepIndex:contactStepIndex,carryingAtStart:carryingAtStart)
    }

    static func reviewVisualCalibrationTrial(baseline:[Double],steps:[ROBLeftGestureProposal.Step],
        map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,
        nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,payload:ROBWorkspaceCarriedObject? = nil,
        intentionalContact:ROBWorkspaceIntentionalContact? = nil,contactStepIndex:Int? = nil,carryingAtStart:Bool? = nil) throws -> Self {
        let context = try validateVisualCalibrationTrialMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        guard baseline == trial.baseline else {throw ROBGhostMotionError.blocked("The visual-calibration path start differs from its frozen fresh arm pose.")}
        return try reviewUsingContext(baseline:baseline,steps:steps,map:map,model:model,context:context,
            nowMilliseconds:nowMilliseconds,payload:payload,intentionalContact:intentionalContact,
            contactStepIndex:contactStepIndex,carryingAtStart:carryingAtStart)
    }

    /// Candidate endpoints only. Their names/deltas are model estimates, not
    /// clearance or actuator authority. Actual URDF FK chooses each side's
    /// rearward/outward/forward signs, rather than mirroring motor commands.
    static func initialEmptyRetreatCandidates(from start:[Double],model:ROBGhostRobotModel)->[ROBWorkspaceInitialRetreatCandidate] {
        guard model.physicalSide=="right",start.count==7,start.allSatisfy(\.isFinite),
              ROBArmRoutinePlan.near(start,Array(repeating:0,count:7)),
              (1...3).allSatisfy({index in model.joints.contains{$0.name==model.armJointPrefix+String(index)}}) else {return []}
        let pose=model.positions(vendorLeft:start),bounds=model.worldCollisionBounds(positions:pose)
        let links=["four","five","six","seven"].map{model.physicalSide+"_"+$0+"_Link"}+[model.toolLink]
        func meanY(_ boxes:[String:(low:SIMD3<Double>,high:SIMD3<Double>)])->Double? {
            let values=links.compactMap{boxes[$0].map{($0.low.y+$0.high.y)/2}}
            return values.count==links.count ? values.reduce(0,+)/Double(values.count):nil
        }
        guard let origin=model.toolPosition(pose),let initialY=meanY(bounds) else {return []}
        let rearward=ROBCanGrabPreview.rearwardJoint1Direction(model:model,baseline:pose,side:model.physicalSide)
        let outward=ROBCanGrabPreview.outwardJoint2Direction(model:model,baseline:pose,side:model.physicalSide)
        let forward=ROBCanGrabPreview.forwardJoint3Direction(model:model,baseline:pose,side:model.physicalSide)
        let limits=jointBounds(model:model)
        func candidate(_ name:String,_ three:[Double])->ROBWorkspaceInitialRetreatCandidate? {
            let offset=three+[0,0,0,0],goal=zip(start,offset).map(+)
            guard offset.count==7,offset.allSatisfy({$0.isFinite && abs($0)<=0.20}),
                  zip(goal,limits).allSatisfy({$0.isFinite && $1.contains($0)}) else {return nil}
            let target=model.positions(vendorLeft:goal)
            guard let end=model.toolPosition(target),let y=meanY(model.worldCollisionBounds(positions:target)) else {return nil}
            let delta=end-origin,outwardDelta = -(y-initialY)
            guard [delta.x,delta.y,delta.z,outwardDelta].allSatisfy(\.isFinite) else {return nil}
            return .init(name:name,offset:offset,goal:goal,estimatedToolDeltaMeters:[delta.x,delta.y,delta.z],
                estimatedOutwardForearmDeltaMeters:outwardDelta)
        }
        var coupled:[ROBWorkspaceInitialRetreatCandidate]=[]
        for magnitude in [0.02,0.04] {for shoulder in [1.0,-1.0] {for roll in [1.0,-1.0] {
            let j2=magnitude==0.02 ? 0.060:0.055
            if let value=candidate("coupled_\(coupled.count+1)",[rearward*shoulder*magnitude,outward*j2,forward*roll*0.02]) {coupled.append(value)}
        }}}
        // Prefer an actual FK-predicted rise and outward motion where one
        // exists. A useful empty escape is still eligible for full review
        // even when its tool does not rise. Ties retain stable names/order.
        coupled.sort {
            let a=$0.estimatedToolDeltaMeters[2]>0 && $0.estimatedOutwardForearmDeltaMeters>0
            let b=$1.estimatedToolDeltaMeters[2]>0 && $1.estimatedOutwardForearmDeltaMeters>0
            if a != b {return a}
            if abs($0.estimatedToolDeltaMeters[2]-$1.estimatedToolDeltaMeters[2])>1e-9 {
                return $0.estimatedToolDeltaMeters[2]>$1.estimatedToolDeltaMeters[2]
            }
            return $0.name<$1.name
        }
        let pure=[0.060,0.071,0.075,0.045].enumerated().compactMap { index,amount in
            candidate("outward_\(index+1)",[0,outward*amount,0])
        }
        return Array((coupled+pure).prefix(12))
    }

    /// Try distinct bounded initial corridors through the SAME complete proof.
    /// Unknown cells, original returns, self pairs, jaw inflation and margins
    /// are unchanged. A collision at their common start rejects every route.
    static func selectInitialEmptyVisualCalibrationRetreat(from start:[Double],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,
        trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        emptyTrialEligibility:Bool,emptyStateEvidenceSource:String)throws->ROBWorkspaceInitialRetreatSelection {
        _=try validateVisualCalibrationTrialMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        let generated=initialEmptyRetreatCandidates(from:start,model:model)
        guard !generated.isEmpty else {throw ROBGhostMotionError.blocked("Initial retreat candidate generation requires the physical RIGHT arm at a finite hanging pose.")}
        // Reserve an early attempt for a useful outward fallback; exhausting
        // the budget on coupled endpoints must not starve that corridor. All
        // candidates still pass the identical complete sampled proof below.
        var candidates:[ROBWorkspaceInitialRetreatCandidate]=[]
        if let first=generated.first {candidates.append(first)}
        for name in ["outward_2","outward_3","outward_1"] {
            if let candidate=generated.first(where:{$0.name==name}) {candidates.append(candidate)}
        }
        candidates += generated.filter {candidate in !candidates.contains(where:{$0.name==candidate.name})}
        let began=ProcessInfo.processInfo.systemUptime
        var attempts:[ROBWorkspaceInitialRetreatAttempt]=[],budgetExhausted=false
        for candidate in candidates {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime-began<8 else {budgetExhausted=true;break}
            do {
                let proof=try reviewInitialEmptyVisualCalibrationRetreat(from:start,to:candidate.goal,map:map,model:model,
                    generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,
                    trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,emptyTrialEligibility:emptyTrialEligibility,
                    emptyStateEvidenceSource:emptyStateEvidenceSource)
                attempts.append(.init(name:candidate.name,offset:candidate.offset,goal:candidate.goal,
                    estimatedToolDeltaMeters:candidate.estimatedToolDeltaMeters,
                    estimatedOutwardForearmDeltaMeters:candidate.estimatedOutwardForearmDeltaMeters,
                    admitted:true,detail:"Complete initial empty-retreat proof passed; dispatch still requires fresh reproof of this exact offset.",
                    maximumHullTravelMeters:proof.maximumHullTravelMeters,checkedPoseCount:proof.checkedPoseCount))
                return .init(proof:proof,attempts:attempts,rejectionDetail:"",representativeRejectedGoal:nil,budgetExhausted:false)
            } catch is CancellationError {throw CancellationError()}
            catch {
                attempts.append(.init(name:candidate.name,offset:candidate.offset,goal:candidate.goal,
                    estimatedToolDeltaMeters:candidate.estimatedToolDeltaMeters,
                    estimatedOutwardForearmDeltaMeters:candidate.estimatedOutwardForearmDeltaMeters,
                    admitted:false,detail:error.localizedDescription,maximumHullTravelMeters:nil,checkedPoseCount:nil))
            }
        }
        let representative=ROBWorkspaceInitialRetreatSelection.representativeRejection(attempts)
        return .init(proof:nil,attempts:attempts,
            rejectionDetail:representative?.detail ?? "Initial retreat candidate review reached its bounded planning deadline before a route was admitted.",
            representativeRejectedGoal:representative?.goal,budgetExhausted:budgetExhausted)
    }

    /// Distinct start-only admission for a fresh EMPTY hanging arm. Existing
    /// arm/tread proxy pairs may start below 30 mm only while every such pair
    /// improves monotonically; ordinary endpoint and map checks remain intact.
    static func reviewInitialEmptyVisualCalibrationRetreat(from start:[Double],to goal:[Double],
        map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,
        nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        emptyTrialEligibility:Bool,emptyStateEvidenceSource:String) throws -> ROBWorkspaceInitialEmptyRetreat {
        var context=try validateVisualCalibrationTrialMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        let limits=jointBounds(model:model)
        // Eligibility is an explicit operator/task-history declaration, NOT
        // a gripper sensor or an inferred successful release/possession check.
        guard emptyTrialEligibility,["operator_declared_empty","local_first_attempt_no_arm_travel_or_task_grip"].contains(emptyStateEvidenceSource),
              measuredAtMilliseconds.isFinite,(0...250).contains(nowMilliseconds-measuredAtMilliseconds),
              start==trial.baseline,ROBArmRoutinePlan.near(start,Array(repeating:0,count:7)),
              start.count==7,goal.count==7,
              zip(start,limits).allSatisfy({$0.isFinite && $1.contains($0)}),
              zip(goal,limits).allSatisfy({$0.isFinite && $1.contains($0)}),
              zip(start,goal).allSatisfy({abs($1-$0)<=0.20}),
              let minimum=ROBLeftArmInteractionPlan.duration(from:start,to:goal),minimum<=4 else {
            throw ROBGhostMotionError.blocked("Initial retreat requires declared first-attempt EMPTY eligibility, fresh measured hanging, unchanged pose and at most 0.20 rad per joint over four seconds.")
        }
        let initialFrames=model.frames(model.positions(vendorLeft:start))
        let initialBounds=model.worldCollisionBounds(positions:model.positions(vendorLeft:start))
        let arms=initialBounds.keys.filter { $0.hasPrefix(model.physicalSide+"_") &&
            ($0.hasSuffix("_Link") || $0==model.toolLink) }.sorted()
        let proxies=initialBounds.keys.filter { $0.contains("track") || $0.contains("flipper") || $0.contains("sprocket") }.sorted()
        guard arms.count>=8,!proxies.isEmpty else {throw ROBGhostMotionError.blocked("Initial retreat is missing full-arm or tread proxy geometry.")}
        var selfProxyClearance=ROBWorkspaceSelfProxyClearance(model:model)

        let initial=try selfProxyClearance.separations(vendorLeft:start)
        let deficientPairs=Set(initial.filter{$0.value<0.030}.keys)
        guard !deficientPairs.isEmpty else {
            throw ROBGhostMotionError.blocked("No pre-existing self-proxy clearance deficit needs an initial retreat; use ordinary path review.")
        }
        // Baseline world AABB corners enclose the actual hull. Transporting
        // that enclosing box by each link's rigid delta conservatively covers
        // every full-hull point, including the wrist and gripper.
        var localEnvelopes:[String:[SIMD3<Double>]]=[:]
        for arm in arms {
            guard let frame=initialFrames[arm],let box=initialBounds[arm] else {throw ROBGhostMotionError.blocked("Initial retreat is missing a link transform.")}
            var points:[SIMD3<Double>]=[]
            for x in [box.low.x,box.high.x] {for y in [box.low.y,box.high.y] {for z in [box.low.z,box.high.z] {
                let p=simd_inverse(frame)*SIMD4(x,y,z,1);points.append(SIMD3(p.x,p.y,p.z))
            } } }
            localEnvelopes[arm]=points
        }
        let angle=zip(start,goal).reduce(0.0){$0+abs($1.1-$1.0)}
        let count=max(1,Int(ceil(1.5*angle/sweptPointTravelMeters)))
        guard count<=maximumPoseChecks else {throw ROBGhostMotionError.blocked("Initial retreat exceeds its bounded swept sampling budget.")}
        var checker=Checker(map:map,model:model,context:context)
        var previous=initial,endpoint=initial,previousPoints:[String:[SIMD3<Double>]]=[:],travel:[String:[Double]]=[:]
        var maximumTravel=0.0
        for sample in 0...count {
            let t=Double(sample)/Double(count),q=zip(start,goal).map{$0+($1-$0)*t}
            let positions=model.positions(vendorLeft:q)
            let current=try selfProxyClearance.separations(vendorLeft:q,forceNarrowPairs:deficientPairs)
            for (pair,first) in initial {
                let value=current[pair]!
                if first<0.030 {
                    guard value+1e-9>=previous[pair]! else {throw ROBGhostMotionError.blocked("Initial retreat worsens pre-existing self-proxy pair \(pair).")}
                } else if value<0.030 {throw ROBGhostMotionError.blocked("Initial retreat creates a new self-proxy clearance deficit at \(pair).")}
            }
            let frames=model.frames(positions)
            for arm in arms {
                guard let frame=frames[arm] else {throw ROBGhostMotionError.blocked("Initial retreat lost a full-arm transform.")}
                let points=localEnvelopes[arm]!.map { p -> SIMD3<Double> in let v=frame*SIMD4(p,1);return SIMD3(v.x,v.y,v.z) }
                if let prior=previousPoints[arm] {
                    var lengths=travel[arm] ?? Array(repeating:0,count:points.count)
                    // Existing swept checker uses the same conservative 1.5m
                    // lever. Include a second-order intersample arc allowance.
                    let curvatureAllowance=0.75*pow(angle/Double(count),2)
                    for index in points.indices {lengths[index]+=simd_distance(points[index],prior[index])+curvatureAllowance}
                    travel[arm]=lengths;maximumTravel=max(maximumTravel,lengths.max() ?? 0)
                }
                previousPoints[arm]=points
            }
            guard maximumTravel<=0.060 else {throw ROBGhostMotionError.blocked("Initial retreat exceeds 60 mm full-hull travel.")}
            // No map cells are ignored, cleared or relabeled as current self.
            // Only this private call defers the tread proxy gate; environment,
            // unknown-space, jaw inflation and ordinary endpoint checks remain.
            if let reason=checker.pose(q,payload:nil,requireSelfClearance:sample==count) {throw ROBGhostMotionError.blocked(reason)}
            previous=current;endpoint=current
        }
        guard initial.allSatisfy({ pair,first in endpoint[pair]!>=0.030 && (first>=0.030 || endpoint[pair]!>first+0.000001) }) else {
            throw ROBGhostMotionError.blocked("Initial retreat must strictly improve every existing proxy deficit and finish with ordinary 30 mm self clearance.")
        }
        context.skippedStaticRobotLinks=checker.staticRobotLinkEvidence
        return .init(context:context,baseline:start,goal:goal,step:.init(positions:goal,seconds:4,stage:"Initial EMPTY nonworsening self-proxy retreat"),
            checkedPoseCount:checker.checked,maximumHullTravelMeters:maximumTravel,
            initialProxyClearancesMeters:initial,endpointProxyClearancesMeters:endpoint,
            initialEmptyStateAssumed:true,emptyStateEvidenceSource:emptyStateEvidenceSource)
    }

    private static func reviewUsingContext(baseline:[Double],steps:[ROBLeftGestureProposal.Step],
        map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,context initialContext:ROBWorkspaceCollisionContext,
        nowMilliseconds:Double,payload:ROBWorkspaceCarriedObject?,intentionalContact:ROBWorkspaceIntentionalContact?,
        contactStepIndex:Int?,carryingAtStart:Bool?) throws -> Self {
        var context = initialContext
        guard !steps.isEmpty, steps.count <= 80, payload?.valid ?? true,
              steps.allSatisfy({ $0.seconds.isFinite && (0.7...5).contains($0.seconds) }),
              steps.reduce(0,{ $0+$1.seconds }) <= 135 else {
            throw ROBGhostMotionError.blocked("The workspace path or measured payload envelope is invalid or exceeds one bounded operation.")
        }
        guard !steps.contains(where:{ $0.jawAction == .grip || $0.jawAction == .release }) || payload != nil else {
            throw ROBGhostMotionError.blocked("A grasp or release route needs a measured payload envelope before any arm travel.")
        }
        if let contact=intentionalContact {
            try contact.validate(map:map,model:model,nowMilliseconds:nowMilliseconds)
            if contact.verifiedAttachment != nil {
                try contact.validateAttachedPhase(baseline:baseline,steps:steps,payload:payload,
                    contactStepIndex:contactStepIndex,carryingAtStart:carryingAtStart)
            } else {
                guard contact.releaseStepIndex != nil || (contact.terminalGraspHold == true && context.visualTrial != nil) else {
                    throw ROBGhostMotionError.blocked("A terminal grasp hold needs its explicit local visual-calibration trial; ordinary contact still requires release.")
                }
                guard payload == nil || payload?.measurementID==contact.measurementID else {
                    throw ROBGhostMotionError.blocked("Intentional contact and the carried-object envelope identify different measurements.")
                }
                if let index=contactStepIndex {
                    guard (0..<contact.stepCount).contains(index) else { throw ROBGhostMotionError.blocked("The intentional-contact segment index is invalid.") }
                    if contact.releaseStepIndex == nil {
                        guard steps.count==1,steps[0].jawAction != .release,
                              (index != contact.stepCount-1 || steps[0].stage == "Verification lift") else {
                            throw ROBGhostMotionError.blocked("A terminal grasp hold segment must retain its frozen verification lift and cannot release.")
                        }
                    }
                } else {
                    guard let grip=contact.gripStepIndex,steps.count==contact.stepCount,steps[grip].jawAction == .grip,
                          steps.filter({$0.jawAction == .grip}).count==1 else {
                        throw ROBGhostMotionError.blocked("Intentional contact must remain attached to the frozen grasp, lift and release stages.")
                    }
                    if let release=contact.releaseStepIndex {
                        guard steps[release].jawAction == .release,steps.filter({$0.jawAction == .release}).count==1 else {
                            throw ROBGhostMotionError.blocked("Intentional contact must retain its frozen release stages.")
                        }
                    } else {
                        guard !steps.contains(where:{$0.jawAction == .release}),steps.last?.stage == "Verification lift" else {
                            throw ROBGhostMotionError.blocked("A terminal grasp hold must end at its verification lift without a carry or release stage.")
                        }
                    }
                }
            }
            context.intentionalContactFingerprint=contact.fingerprint
        } else if contactStepIndex != nil { throw ROBGhostMotionError.blocked("A contact-stage index has no measured target proof.") }
        var checker = Checker(map:map,model:model,context:context,intentionalContact:intentionalContact), previous = baseline
        guard carryingAtStart != true || payload != nil else {throw ROBGhostMotionError.blocked("A measured payload envelope is required for an attached-object start.")}
        var carrying = carryingAtStart ?? !steps.contains { $0.jawAction == .grip }
        for (index,step) in steps.enumerated() {
            checker.contactStepIndex=contactStepIndex ?? index
            if let reason = checker.segment(from:previous,to:step.positions,payload:carrying ? payload : nil) {
                throw ROBGhostMotionError.blocked(reason)
            }
            guard let minimum = ROBLeftArmInteractionPlan.duration(from:previous,to:step.positions), step.seconds >= minimum-1e-9 else {
                throw ROBGhostMotionError.blocked("The collision-checked path exceeds the unchanged trajectory speed bound.")
            }
            if step.jawAction == .grip { carrying = true }
            if step.jawAction == .release { carrying = false }
            previous = step.positions
        }
        context.skippedStaticRobotLinks=checker.staticRobotLinkEvidence
        return .init(context:context,baseline:baseline,goal:previous,steps:steps,payload:payload,checkedPoseCount:checker.checked,
            intentionalContact:intentionalContact,contactStepIndex:contactStepIndex,carryingAtStart:carryingAtStart)
    }

    func validate(map: any ROBWorkspaceCollisionMap, model: ROBGhostRobotModel, generation: UInt64,
                  sceneID: UUID, cameraGeneration: UUID, nowMilliseconds: Double) throws {
        let current = try Self.validateMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
        guard current.mapFingerprint == context.mapFingerprint, current.registrationID == context.registrationID,
              current.registrationUncertaintyMeters == context.registrationUncertaintyMeters,
              context.sessionGeneration == generation, context.sceneID == sceneID, context.cameraGeneration == cameraGeneration,
              context.modelID == current.modelID, context.geometryID == current.geometryID, context.mappingID == current.mappingID,
              context.oldestCapturedAtMilliseconds == current.oldestCapturedAtMilliseconds,
              context.lastCapturedAtMilliseconds == current.lastCapturedAtMilliseconds,
              context.intentionalContactFingerprint == intentionalContact?.fingerprint,
              context.checkedAtMilliseconds.isFinite, (0...Self.maximumMapAgeMilliseconds).contains(nowMilliseconds-context.checkedAtMilliseconds),
              goal == steps.last?.positions else {
            throw ROBGhostMotionError.blocked("The reviewed workspace map or path changed. Build a new proposal before moving.")
        }
        _ = try Self.review(baseline:baseline,steps:steps,map:map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,payload:payload,
            intentionalContact:intentionalContact,contactStepIndex:contactStepIndex,carryingAtStart:carryingAtStart)
    }

    func validateVisualCalibrationTrial(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,
        sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial) throws {
        let current = try Self.validateVisualCalibrationTrialMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        guard context.visualTrial == trial, context.registrationID == nil, context.registrationUncertaintyMeters == nil,
              context.mapFingerprint == current.mapFingerprint, context.sessionGeneration == generation,
              context.sceneID == sceneID, context.cameraGeneration == cameraGeneration,
              context.modelID == current.modelID, context.geometryID == current.geometryID,context.mappingID == current.mappingID,
              context.oldestCapturedAtMilliseconds == current.oldestCapturedAtMilliseconds,
              context.lastCapturedAtMilliseconds == current.lastCapturedAtMilliseconds,
              context.intentionalContactFingerprint == intentionalContact?.fingerprint,
              context.checkedAtMilliseconds.isFinite,
              (0...Self.maximumMapAgeMilliseconds).contains(nowMilliseconds-context.checkedAtMilliseconds),
              baseline == trial.baseline,goal == steps.last?.positions else {
            throw ROBGhostMotionError.blocked("The reviewed visual-calibration trial or path changed. Build a new explicitly scoped proposal.")
        }
        let reviewed = try Self.reviewUsingContext(baseline:baseline,steps:steps,map:map,model:model,context:current,
            nowMilliseconds:nowMilliseconds,payload:payload,intentionalContact:intentionalContact,
            contactStepIndex:contactStepIndex,carryingAtStart:carryingAtStart)
        guard reviewed.context.skippedStaticRobotLinks==context.skippedStaticRobotLinks else {
            throw ROBGhostMotionError.blocked("The invariant static robot-link evidence changed; review the current body and arm context again.")
        }
    }

    /// Deterministic bounded joint-space search. Current/goal poses, every
    /// connecting segment and every shortcut are checked against the map.
    static func make(from start: [Double], to goal: [Double], map: any ROBWorkspaceCollisionMap,
                     model: ROBGhostRobotModel, generation: UInt64, sceneID: UUID, cameraGeneration: UUID,
                     nowMilliseconds: Double, payload: ROBWorkspaceCarriedObject? = nil,
                     intentionalContact:ROBWorkspaceIntentionalContact? = nil,contactStepIndex:Int? = nil) throws -> Self {
        let context = try validateMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
        return try makeUsingContext(from:start,to:goal,map:map,model:model,context:context,
            nowMilliseconds:nowMilliseconds,payload:payload,intentionalContact:intentionalContact,contactStepIndex:contactStepIndex)
    }

    static func makeVisualCalibrationTrial(from start:[Double],to goal:[Double],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,
        trial:ROBWorkspaceVisualCalibrationTrial,payload:ROBWorkspaceCarriedObject? = nil,
        intentionalContact:ROBWorkspaceIntentionalContact? = nil,contactStepIndex:Int? = nil) throws -> Self {
        let context = try validateVisualCalibrationTrialMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        guard start == trial.baseline else {throw ROBGhostMotionError.blocked("The visual-calibration connector start differs from its frozen fresh arm pose.")}
        return try makeUsingContext(from:start,to:goal,map:map,model:model,context:context,
            nowMilliseconds:nowMilliseconds,payload:payload,intentionalContact:intentionalContact,contactStepIndex:contactStepIndex)
    }

    private static func makeUsingContext(from start:[Double],to goal:[Double],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,context initialContext:ROBWorkspaceCollisionContext,nowMilliseconds:Double,
        payload:ROBWorkspaceCarriedObject?,intentionalContact:ROBWorkspaceIntentionalContact?,contactStepIndex:Int?) throws -> Self {
        var context = initialContext
        guard payload?.valid ?? true else { throw ROBGhostMotionError.blocked("Measure the carried object's complete envelope before planning.") }
        if let contact=intentionalContact {
            try contact.validate(map:map,model:model,nowMilliseconds:nowMilliseconds)
            guard contact.verifiedAttachment==nil else {
                throw ROBGhostMotionError.blocked("Verified attached-can paths need an explicit carrying-at-start full or indexed phase review.")
            }
            guard contact.releaseStepIndex != nil || (contact.terminalGraspHold == true && context.visualTrial != nil) else {
                throw ROBGhostMotionError.blocked("A terminal grasp hold needs its explicit local visual-calibration trial; ordinary contact still requires release.")
            }
            guard let index=contactStepIndex,(0..<contact.stepCount).contains(index),
                  payload == nil || payload?.measurementID==contact.measurementID else {
                throw ROBGhostMotionError.blocked("An intentional-contact connector needs an explicit frozen task stage and matching measured payload.")
            }
            context.intentionalContactFingerprint=contact.fingerprint
        } else if contactStepIndex != nil { throw ROBGhostMotionError.blocked("A contact-stage index has no measured target proof.") }
        var checker = Checker(map:map,model:model,context:context,intentionalContact:intentionalContact,
            contactStepIndex:contactStepIndex ?? -1)
        if let reason = checker.pose(start,payload:payload) { throw ROBGhostMotionError.blocked("Current arm clearance is unconfirmed. "+reason) }
        if let reason = checker.pose(goal,payload:payload) { throw ROBGhostMotionError.blocked("Requested arm endpoint is blocked. "+reason) }
        var path: [[Double]]?
        if checker.segment(from:start,to:goal,payload:payload) == nil { path = [start,goal] }
        if path == nil {
            // These are generated joint-space search seeds, not registered
            // routes. Table/unknown clearance is checked for both connectors.
            for joint in [0,1,3,5,2,4,6] {
                for delta in [0.35,-0.35,0.70,-0.70] {
                    var a = start, b = goal; a[joint] += delta; b[joint] += delta
                    if checker.segment(from:start,to:a,payload:payload) == nil,
                       checker.segment(from:a,to:b,payload:payload) == nil,
                       checker.segment(from:b,to:goal,payload:payload) == nil { path = [start,a,b,goal]; break }
                }
                if path != nil { break }
            }
        }
        if path == nil { path = search(from:start,to:goal,checker:&checker,payload:payload) }
        guard var route = path else {
            throw ROBGhostMotionError.blocked("No fully observed, collision-free arm connector was found within the bounded search. Hold position and improve the workspace view or move the obstruction.")
        }
        // Only shortcut when the replacement's entire swept arm is clear.
        var compact: [[Double]] = [route.removeFirst()], index = 0
        while index < route.count {
            var last = route.count-1
            while last > index && checker.segment(from:compact.last!,to:route[last],payload:payload) != nil { last -= 1 }
            compact.append(route[last]); index = last+1
        }
        var steps: [ROBLeftGestureProposal.Step] = [], previous = start
        for target in compact.dropFirst() {
            let origin = previous, delta = zip(origin,target).map { abs($0-$1) }.max() ?? 0
            let count = max(1,Int(ceil(delta/0.30)))
            for part in 1...count {
                let t = Double(part)/Double(count), q = zip(origin,target).map { $0+($1-$0)*t }
                guard let seconds = ROBLeftArmInteractionPlan.duration(from:previous,to:q,padding:ROBArmRoutinePlan.tolerance), seconds <= 5 else {
                    throw ROBGhostMotionError.blocked("The workspace connector exceeds the existing motion timing bound.")
                }
                steps.append(.init(positions:q,seconds:seconds,stage:"Follow observed collision-free arm connector")); previous = q
            }
        }
        return try reviewUsingContext(baseline:start,steps:steps,map:map,model:model,context:context,
            nowMilliseconds:nowMilliseconds,payload:payload,intentionalContact:intentionalContact,
            contactStepIndex:contactStepIndex,carryingAtStart:nil)
    }

    private struct Node { let q: [Double]; let parent: Int? }
    private static func search(from start: [Double], to goal: [Double], checker: inout Checker,
                               payload: ROBWorkspaceCarriedObject?) -> [[Double]]? {
        var a = [Node(q:start,parent:nil)], b = [Node(q:goal,parent:nil)]
        let primes = [2,3,5,7,11,13,17]
        func halton(_ value: Int,_ base: Int) -> Double {
            var n = value, f = 1.0, result = 0.0
            while n > 0 { f /= Double(base); result += f*Double(n%base); n /= base }
            return result
        }
        func distance(_ a:[Double],_ b:[Double]) -> Double { zip(a,b).reduce(0) { $0+pow($1.0-$1.1,2) } }
        func extend(_ tree:inout [Node],toward target:[Double],checker:inout Checker) -> Int? {
            let nearest = tree.indices.min { distance(tree[$0].q,target) < distance(tree[$1].q,target) }!
            let origin = tree[nearest].q, delta = zip(origin,target).map { $1-$0 }, largest = delta.map(abs).max() ?? 0
            let scale = min(1,0.25/max(1e-12,largest)), q = zip(origin,delta).map { $0+$1*scale }
            guard checker.segment(from:origin,to:q,payload:payload) == nil else { return nil }
            tree.append(.init(q:q,parent:nearest)); return tree.count-1
        }
        func trace(_ tree:[Node],_ index:Int) -> [[Double]] {
            var result:[[Double]] = [], cursor:Int? = index
            while let i = cursor { result.append(tree[i].q); cursor = tree[i].parent }
            return result.reversed()
        }
        for iteration in 1...192 {
            guard !checker.exhausted else { return nil }
            let target = iteration%5 == 0 ? goal : checker.limits.enumerated().map { index,limit in
                limit.lowerBound+(limit.upperBound-limit.lowerBound)*halton(iteration,primes[index])
            }
            guard let ai = extend(&a,toward:target,checker:&checker) else { continue }
            for _ in 0..<24 {
                guard let bi = extend(&b,toward:a[ai].q,checker:&checker) else { break }
                if distance(b[bi].q,a[ai].q) < 1e-12 { return trace(a,ai)+Array(trace(b,bi).reversed().dropFirst()) }
            }
        }
        return nil
    }

    private struct Checker {
        let map: any ROBWorkspaceCollisionMap
        let model: ROBGhostRobotModel
        let context: ROBWorkspaceCollisionContext
        var intentionalContact:ROBWorkspaceIntentionalContact? = nil
        var contactStepIndex = -1
        var selfProxyClearance:ROBWorkspaceSelfProxyClearance? = nil
        let started = ProcessInfo.processInfo.systemUptime
        var checked = 0
        var staticRobotLinkEvidence:[ROBWorkspaceStaticRobotLinkEvidence]? = nil
        var verifiedShapes:[String:ROBNominalShape] = [:]
        var unavailableConvexLinks=Set<String>()
        var limits: [ClosedRange<Double>] { ROBWorkspaceCollisionPlan.jointBounds(model:model) }
        var exhausted: Bool { checked >= maximumPoseChecks || ProcessInfo.processInfo.systemUptime-started > maximumPlanningSeconds }
        mutating func segment(from start:[Double],to end:[Double],payload:ROBWorkspaceCarriedObject?) -> String? {
            guard start.count == 7, end.count == 7 else { return "Arm coordinates are incomplete." }
            let bounds = limits
            guard zip(start,bounds).allSatisfy({ $0.isFinite && $1.contains($0) }),
                  zip(end,bounds).allSatisfy({ $0.isFinite && $1.contains($0) }) else {
                return "Arm pose exceeds the model or transport joint bounds."
            }
            let travel = 1.5*zip(start,end).reduce(0.0) { $0+abs($1.0-$1.1) }
            guard travel.isFinite else { return "Arm coordinates are not finite." }
            let requestedSamples = ceil(travel/sweptPointTravelMeters)
            guard requestedSamples.isFinite, requestedSamples <= Double(maximumPoseChecks) else {
                return "The proposed swept path exceeds the bounded sampling budget."
            }
            let count = max(1,Int(requestedSamples))
            for sample in 0...count {
                let t = Double(sample)/Double(count), q = zip(start,end).map { $0+($1-$0)*t }
                if let reason = pose(q,payload:payload) { return reason }
            }
            return nil
        }
        mutating func pose(_ q:[Double],payload:ROBWorkspaceCarriedObject?,requireSelfClearance:Bool = true) -> String? {
            guard !exhausted else { return "Workspace collision search reached its time or sampling bound." }
            checked += 1
            guard q.count == 7, zip(q,limits).allSatisfy({ $0.isFinite && $1.contains($0) }) else { return "Arm pose exceeds the model or transport joint bounds." }
            let positions = model.positions(vendorLeft:q), bounds = model.worldCollisionBounds(positions:positions)
            let frames=model.frames(positions)
            let arms = bounds.keys.filter { $0.hasPrefix(model.physicalSide + "_") && ($0.hasSuffix("_Link") || $0 == model.toolLink || $0 == model.physicalSide + "_base_link") }.sorted()
            guard arms.count >= 8 else {return "The complete arm collision model is missing."}
            var selfGap=model.treadSeparation(vendorLeft:q)
            if requireSelfClearance && selfGap<0.030 {
                do {
                    if selfProxyClearance==nil {selfProxyClearance=ROBWorkspaceSelfProxyClearance(model:model)}
                    selfGap=try selfProxyClearance!.minimum(vendorLeft:q)
                } catch {return error.localizedDescription}
            }
            if requireSelfClearance && selfGap<0.030 {
                if context.visualTrial != nil {
                    return String(format:"The complete arm model enters its tread/self-proxy clearance (%.1f mm; required 30 mm). A distinct checked nonworsening retreat is required; visual-trial alignment permission does not exempt it.",selfGap*1000)
                }
                return "The complete arm model is missing or enters its tread clearance margin."
            }
            // Physical uncertainty remains mechanical + registration + one
            // full swept sample travel. Exact queries below use WHOLE voxel
            // or original-return bounds, already containing their extent.
            // The old center-sphere halfdiagonal remains broad-phase/fallback
            // conservatism only; adding it again to box distance double counts.
            let margin = mechanicalClearanceMeters+context.spatialErrorAllowanceMeters+sweptPointTravelMeters
            let broadVoxelAllowance=sqrt(3)*map.voxelSizeMeters/2
            for link in arms {
                let box = bounds[link]!, extra = margin+(link == model.toolLink ? openJawAdditionalMarginMeters : 0)
                do {
                    if let deferredStaticWorldPair=try ROBWorkspaceCollisionPlan.deferredStaticWorldPair(model:model,
                        positions:positions,link:link,map:map,context:context,prior:staticRobotLinkEvidence?.first) {
                        staticRobotLinkEvidence=[deferredStaticWorldPair]
                        continue
                    }
                } catch {return error.localizedDescription}
                let queryLow=box.low-SIMD3(repeating:extra+broadVoxelAllowance),queryHigh=box.high+SIMD3(repeating:extra+broadVoxelAllowance)
                if context.visualTrial==nil {
                    // Existing measured-route admission remains unchanged;
                    // the explicit visual trial opts into exact-box queries.
                    if let reason=volume(low:queryLow,high:queryHigh,label:link,payload:payload){return reason}
                    continue
                }
                if map.state(inBoundsLow:queryLow,high:queryHigh) == .free {continue}
                if verifiedShapes[link]==nil && !unavailableConvexLinks.contains(link) {
                    do {verifiedShapes[link]=try ROBWorkspaceVerifiedConvexEnvelope.load(model:model,link:link)}catch{unavailableConvexLinks.insert(link)}
                }
                guard let shape=verifiedShapes[link],let frame=frames[link] else {
                    // An open/unverified scan envelope cannot narrow a query.
                    // Retain the pre-existing conservative AABB veto instead.
                    if let reason=volume(low:queryLow,high:queryHigh,label:link,payload:payload){return reason}
                    continue
                }
                let convex=ROBNominalWorldShape(shape,frame)
                if let reason = narrowVolume(shape:convex,low:queryLow,high:queryHigh,
                    margin:extra,label:link,payload:payload) { return reason }
            }
            if let payload {
                guard payload.valid, let tool = model.frames(positions)[model.toolLink] else { return "The carried-object envelope or tool transform is invalid." }
                let center = payload.centerInToolMeters, half = payload.halfExtentsMeters
                var points: [SIMD3<Double>] = []
                for x in [-1.0,1] { for y in [-1.0,1] { for z in [-1.0,1] {
                    let local = SIMD4<Double>(center[0]+x*half[0],center[1]+y*half[1],center[2]+z*half[2],1)
                    let point = tool*local
                    points.append(SIMD3(point.x,point.y,point.z))
                } } }
                let low = points.reduce(points[0]) { simd_min($0,$1) }-SIMD3<Double>(repeating:margin+broadVoxelAllowance)
                let high = points.reduce(points[0]) { simd_max($0,$1) }+SIMD3<Double>(repeating:margin+broadVoxelAllowance)
                if context.visualTrial==nil {
                    if let reason=volume(low:low,high:high,label:"carried object",payload:payload){return reason}
                } else if map.state(inBoundsLow:low,high:high) != .free {do {
                    let localLow=SIMD3(center[0]-half[0],center[1]-half[1],center[2]-half[2]),localHigh=SIMD3(center[0]+half[0],center[1]+half[1],center[2]+half[2])
                    let convex=ROBNominalWorldShape(try ROBNominalShape.box(low:localLow,high:localHigh),tool)
                    if let reason=narrowVolume(shape:convex,low:low,high:high,margin:margin,label:"carried object",payload:payload){return reason}
                }catch{return error.localizedDescription}}
            }
            return nil
        }
        /// AABB is broad phase only. Unknown remains unknown wherever the
        /// WHOLE voxel intersects the protected verified convex envelope.
        /// Fresh occupied detail retains complete endpoint groups within each
        /// original25mm source voxel. Every conservative group is checked;
        /// unavailable/incomplete detail retains the legacy aggregate union.
        /// Groups still enclose unmeasured corners within their source voxel.
        func narrowVolume(shape:ROBNominalWorldShape,low:SIMD3<Double>,high:SIMD3<Double>,margin:Double,
            label:String,payload:ROBWorkspaceCarriedObject?)->String? {
            if map.state(inBoundsLow:low,high:high) == .free {return nil}
            let size=map.voxelSizeMeters
            guard margin.isFinite,margin>=0,size.isFinite,size>0,(0..<3).allSatisfy({low[$0].isFinite && high[$0].isFinite && abs(low[$0])<=20 && abs(high[$0])<=20 && low[$0]<=high[$0]}) else{return "The convex workspace query is invalid."}
            let lo=(0..<3).map{Int(floor(low[$0]/size))},hi=(0..<3).map{Int(floor(high[$0]/size))}
            guard zip(lo,hi).allSatisfy({$1 >= $0 && $1-$0<=200}),zip(lo,hi).reduce(1,{$0*($1.1-$1.0+1)})<=250_000 else{return "Convex workspace review exceeded its bounded volume."}
            for x in lo[0]...hi[0] {for y in lo[1]...hi[1] {for z in lo[2]...hi[2] {
                let center=SIMD3((Double(x)+0.5)*size,(Double(y)+0.5)*size,(Double(z)+0.5)*size),state=map.state(at:center)
                if state == .free {continue}
                let whole=ROBNominalRawBox(low:center-SIMD3(repeating:size/2),high:center+SIMD3(repeating:size/2),key:"\(x),\(y),\(z)")
                let raw=state == .occupied ? map.occupiedSampleBounds(at:center):nil
                let aggregate=raw.map{ROBNominalRawBox(low:$0.low,high:$0.high,key:whole.key)} ?? whole
                guard (0..<3).allSatisfy({aggregate.low[$0].isFinite && aggregate.high[$0].isFinite && aggregate.low[$0]<=aggregate.high[$0]}) else{return "An original occupied-return envelope is invalid."}
                var queries=[aggregate],representation=raw == nil ? "whole_voxel":"all_original_return_bounds"
                if let raw,let groups=map.occupiedSampleSubBounds(at:center),!groups.isEmpty,groups.count<=27 {
                    var refined:[ROBNominalRawBox]=[],low=SIMD3<Double>(repeating:.infinity),high=SIMD3<Double>(repeating:-.infinity)
                    for group in groups {
                        guard group.lowMeters.count==3,group.highMeters.count==3,
                              (0..<3).allSatisfy({group.lowMeters[$0].isFinite && group.highMeters[$0].isFinite &&
                                  abs(group.lowMeters[$0])<=20 && abs(group.highMeters[$0])<=20 && group.lowMeters[$0]<=group.highMeters[$0]}) else {refined=[];break}
                        let a=SIMD3(group.lowMeters[0],group.lowMeters[1],group.lowMeters[2]),b=SIMD3(group.highMeters[0],group.highMeters[1],group.highMeters[2])
                        low=simd_min(low,a);high=simd_max(high,b)
                        refined.append(ROBNominalRawBox(low:a,high:b,key:whole.key))
                    }
                    // A partial provider never weakens the retained legacy
                    // union. Every group's aggregate must match it exactly.
                    if refined.count==groups.count,(0..<3).allSatisfy({abs(low[$0]-raw.low[$0])<=1e-12 && abs(high[$0]-raw.high[$0])<=1e-12}) {
                        queries=refined;representation="all_original_source_voxel_bounds"
                    }
                }
                for query in queries {
                    if shape.separationLowerBound(query)>margin+0.000001 {continue}
                    let distance:Double
                    do {distance=try shape.distance(query,stopAtDistance:margin)}catch{return error.localizedDescription}
                    if distance>margin+0.000001 {continue}
                    if state == .occupied,let contact=intentionalContact,contact.permits(label:label,payload:payload,stepIndex:contactStepIndex),
                       (raw != nil ? contact.containsMeasuredBounds(low:query.low,high:query.high):contact.containsWholeVoxel(center:center,size:size)) {continue}
                    let detail=String(format:" Convex distance upper bound %.3f mm; retained envelope margin %.3f mm; voxel [%d,%d,%d]; representation %@.",distance*1000,margin*1000,x,y,z,representation)
                    if state == .occupied {return "\(label) would intersect an observed workspace obstacle."+detail}
                    return "\(label) enters unobserved space. Scan the whole arm route before moving."+detail
                }
            }}}
            return nil
        }
        func volume(low:SIMD3<Double>,high:SIMD3<Double>,label:String,payload:ROBWorkspaceCarriedObject?) -> String? {
            var state=map.state(inBoundsLow:low,high:high)
            if state == .occupied,let contact=intentionalContact,
               contact.permits(label:label,payload:payload,stepIndex:contactStepIndex) {
                let size=map.voxelSizeMeters
                let lo=(0..<3).map{Int(floor(low[$0]/size))},hi=(0..<3).map{Int(floor(high[$0]/size))}
                guard zip(lo,hi).allSatisfy({$1 >= $0 && $1-$0<=200}),
                      zip(lo,hi).reduce(1,{$0*($1.1-$1.0+1)})<=250_000 else { return "Intentional-contact voxel review exceeded its bounded volume." }
                state = .free
                cells: for x in lo[0]...hi[0] { for y in lo[1]...hi[1] { for z in lo[2]...hi[2] {
                    let point=SIMD3((Double(x)+0.5)*size,(Double(y)+0.5)*size,(Double(z)+0.5)*size)
                    let cell=map.state(at:point)
                    if cell == .free { continue }
                    if cell == .occupied {
                        if let bounds=map.occupiedSampleBounds(at:point) {
                            // Includes EVERY source endpoint contributing to
                            // this cell, including conservative map dilation.
                            // Never inspect just the closest/selected sample.
                            if contact.containsMeasuredBounds(low:bounds.low,high:bounds.high) { continue }
                        } else if contact.containsWholeVoxel(center:point,size:size) { continue }
                    }
                    state=cell;break cells
                } } }
            }
            switch state {
            case .free: return nil
            case .occupied: return "\(label) would intersect an observed workspace obstacle. No arm movement was authorized by this check."
            case .unknown: return "\(label) enters unobserved space. Scan the whole arm route before moving."
            }
        }
    }
}

/// Pure geometry query; it neither changes map state nor grants motion.
enum ROBWorkspaceVerifiedConvexEnvelope {
    static func distance(hullText:String,frame:simd_double4x4,low:SIMD3<Double>,high:SIMD3<Double>)throws->Double {
        guard (0..<3).allSatisfy({low[$0].isFinite && high[$0].isFinite && low[$0]<=high[$0]}) else {throw ROBGhostMotionError.blocked("Invalid convex query bounds.")}
        return try ROBNominalWorldShape(ROBNominalShape(text:hullText),frame).distance(.init(low:low,high:high,key:""))
    }
    fileprivate static func load(model:ROBGhostRobotModel,link requested:String)throws->ROBNominalShape {
        let data=try Data(contentsOf:model.directory.appendingPathComponent("surfaces.json"))
        guard ROBGhostRobotModel.hash(data)==model.geometryID,
              let catalog=try JSONSerialization.jsonObject(with:data)as?[String:Any],catalog["modelID"]as?String==model.modelID,
              let records=catalog["surfaces"]as?[[String:Any]] else {throw ROBGhostMotionError.blocked("The convex collision geometry catalog changed.")}
        var result:ROBNominalShape?
        for row in records {
            guard let link=row["link"]as?String,link==requested else{continue}
            guard let path=row["hull"]as?String,model.hulls[link]==path,!path.hasPrefix("/"),!path.contains(".."),let sha=row["hullSHA256"]as?String,result==nil else {throw ROBGhostMotionError.blocked("The convex arm hull identity is invalid.")}
            let bytes=try Data(contentsOf:model.directory.appendingPathComponent(path))
            guard ROBGhostRobotModel.hash(bytes)==sha,let text=String(data:bytes,encoding:.utf8) else {throw ROBGhostMotionError.blocked("A convex arm hull changed.")}
            result=try ROBNominalShape(text:text)
        }
        guard let result else {throw ROBGhostMotionError.blocked("The verified convex arm geometry is missing.")};return result
    }
}
private struct ROBNominalRawBox {let low:SIMD3<Double>,high:SIMD3<Double>;let key:String
 var center:SIMD3<Double>{(low+high)/2};var half:SIMD3<Double>{(high-low)/2}
 func gap(to b:ROBNominalRawBox)->Double {simd_length(simd_max(.zero,simd_max(low-b.high,b.low-high)))}
}
private struct ROBNominalShape {
 let local:ROBEstimatedConvexHull,vertices:[SIMD3<Double>],edges:[(Int,Int)],normals:[SIMD3<Double>]
 static func box(low:SIMD3<Double>,high:SIMD3<Double>)throws->Self {
  guard (0..<3).allSatisfy({low[$0].isFinite && high[$0].isFinite && low[$0]<high[$0]}) else{throw ROBGhostMotionError.blocked("Invalid tool-local carried-object box.")}
  var vertices:[SIMD3<Double>]=[];for x in [low.x,high.x]{for y in [low.y,high.y]{for z in [low.z,high.z]{vertices.append(SIMD3(x,y,z))}}}
  let faces=[[1,2,4],[1,4,3],[5,7,8],[5,8,6],[1,5,6],[1,6,2],[3,4,8],[3,8,7],[1,3,7],[1,7,5],[2,6,8],[2,8,4]]
  let text=vertices.map{"v \($0.x) \($0.y) \($0.z)"}.joined(separator:"\n")+"\n"+faces.map{"f \($0[0]) \($0[1]) \($0[2])"}.joined(separator:"\n")
  return try Self(text:text)
 }
 init(text:String)throws {local=try ROBEstimatedConvexHull(text:text);var v:[SIMD3<Double>]=[],f:[[Int]]=[]
  for line in text.split(separator:"\n") {let a=line.split(whereSeparator:\.isWhitespace);if a.first=="v" {v.append(SIMD3(Double(a[1])!,Double(a[2])!,Double(a[3])!))};if a.first=="f" {f.append(a.dropFirst().map{Int($0)!-1})}}
  vertices=v;var e=Set<String>(),out:[(Int,Int)]=[],ns:[SIMD3<Double>]=[]
  for a in f {let n=simd_cross(v[a[1]]-v[a[0]],v[a[2]]-v[a[0]]);if simd_length(n)>1e-10 {ns.append(simd_normalize(n))};for (i,j) in [(a[0],a[1]),(a[1],a[2]),(a[2],a[0])] {let lo=min(i,j),hi=max(i,j),k="\(lo):\(hi)";if e.insert(k).inserted {out.append((lo,hi))}}};edges=out;normals=ns
 }
}
private struct ROBNominalWorldShape {
 let source:ROBNominalShape,frame:simd_double4x4,inverse:simd_double4x4,vertices:[SIMD3<Double>],box:ROBNominalRawBox,axes:[SIMD3<Double>],supportIntervals:[(Double,Double)]
 init(_ shape:ROBNominalShape,_ frame:simd_double4x4) {source=shape;self.frame=frame;inverse=simd_inverse(frame)
  let v=shape.vertices.map{p->SIMD3<Double> in let q=frame*SIMD4(p,1);return SIMD3(q.x,q.y,q.z)};vertices=v
  box=ROBNominalRawBox(low:v.reduce(v[0]){simd_min($0,$1)},high:v.reduce(v[0]){simd_max($0,$1)},key:"")
  var out:[SIMD3<Double>]=[SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1)],seen=Set<String>()
  func add(_ x:SIMD3<Double>){let l=simd_length(x);guard l>1e-9 else{return};var n=x/l;if n.x < -1e-8 || (abs(n.x)<1e-8 && n.y < -1e-8) || (abs(n.x)<1e-8 && abs(n.y)<1e-8 && n.z<0){n = -n};let k="\(Int((n.x*1e7).rounded())):\(Int((n.y*1e7).rounded())):\(Int((n.z*1e7).rounded()))";if seen.insert(k).inserted {out.append(n)}}
  for n in shape.normals {let a=frame*SIMD4(n,0);add(SIMD3(a.x,a.y,a.z))}
  for (i,j) in shape.edges {let d=v[j]-v[i];for b in [SIMD3<Double>(1,0,0),SIMD3<Double>(0,1,0),SIMD3<Double>(0,0,1)] {add(simd_cross(d,b))}};axes=out
  supportIntervals=out.map{n in var lo=Double.infinity,hi = -Double.infinity;for p in v {let d=simd_dot(n,p);lo=min(lo,d);hi=max(hi,d)};return(lo,hi)}
 }
 func separationLowerBound(_ b:ROBNominalRawBox)->Double {
  var best=box.gap(to:b)
  for (n,interval) in zip(axes,supportIntervals) {let mid=simd_dot(n,b.center),r=simd_dot(simd_abs(n),b.half);best=max(best,max(interval.0-(mid+r),(mid-r)-interval.1))}
  return best
 }
 func point(_ p:SIMD3<Double>)throws->Double {let q=inverse*SIMD4(p,1);return try source.local.distance(to:SIMD3(q.x,q.y,q.z))}
 func distance(_ b:ROBNominalRawBox,stopAtDistance:Double?=nil)throws->Double {
  if simd_length(b.high-b.low)<1e-10 {return try point(b.low)}
  var separated=false
  for (n,interval) in zip(axes,supportIntervals) {let mid=simd_dot(n,b.center),r=simd_dot(simd_abs(n),b.half);if max(interval.0-(mid+r),(mid-r)-interval.1)>1e-10 {separated=true;break}}
  if !separated{return 0}
  var corners:[SIMD3<Double>]=[];for x in [b.low.x,b.high.x] {for y in [b.low.y,b.high.y] {for z in [b.low.z,b.high.z] {corners.append(SIMD3(x,y,z))}}}
  var result=Double.infinity
  for p in corners {result=min(result,try point(p));if let stopAtDistance,result<=stopAtDistance{return result}}
  for p in vertices {result=min(result,simd_length(simd_max(.zero,simd_max(b.low-p,p-b.high))));if let stopAtDistance,result<=stopAtDistance{return result}}
  let be=[(0,1),(0,2),(0,4),(1,3),(1,5),(2,3),(2,6),(3,7),(4,5),(4,6),(5,7),(6,7)]
  for (i,j) in source.edges {for (k,l) in be {result=min(result,robNominalSegmentDistance(vertices[i],vertices[j],corners[k],corners[l]));if let stopAtDistance,result<=stopAtDistance{return result}}}
  return result
 }
}
private func robNominalSegmentDistance(_ p1:SIMD3<Double>,_ q1:SIMD3<Double>,_ p2:SIMD3<Double>,_ q2:SIMD3<Double>)->Double {
 let d1=q1-p1,d2=q2-p2,r=p1-p2,a=simd_dot(d1,d1),e=simd_dot(d2,d2),f=simd_dot(d2,r);var s=0.0,t=0.0
 func clamp(_ x:Double)->Double {max(0,min(1,x))}
 if a<=1e-18 && e<=1e-18{return simd_distance(p1,p2)}
 if a<=1e-18 {t=clamp(f/e)} else {let c=simd_dot(d1,r);if e<=1e-18{s=clamp(-c/a)}else{let b=simd_dot(d1,d2),den=a*e-b*b;if den>1e-18{s=clamp((b*f-c*e)/den)};t=(b*s+f)/e;if t<0 {t=0;s=clamp(-c/a)}else if t>1 {t=1;s=clamp((b-c)/a)}}}
 return simd_distance(p1+d1*s,p2+d2*t)
}

/// An explicitly UNVERIFIED nominal empty-arm commissioning experiment.
/// Positive nominal clearance is not certified clearance: the recorded35mm
/// assumed camera/model uncertainty may exceed this experiment's nominal gap.
/// This type is never accepted as an ordinary workspace collision certificate.
struct ROBWorkspaceNominalEmptyCommissioningRetreat:Codable,Equatable {
    struct LocalRegion:Codable,Equatable {let link:String;let lowMeters:[Double],highMeters:[Double]}
    let id:UUID
    let mode:String
    let context:ROBWorkspaceCollisionContext
    let baseline:[Double],goal:[Double]
    let measuredAtMilliseconds:Double
    let checkedPoseCount:Int
    let originalOccupiedBoundsCount:Int,deduplicatedOccupiedBoundsCount:Int
    let originalOccupiedBoundsSHA256:String
    let minimumRawClearanceMeters:Double
    let minimumAfterJawEnvelopeMeters:Double
    let minimumSweptNominalClearanceMeters:Double
    let closestMovingLink:String
    let closestRawBounds:ROBWorkspaceOccupiedReturnBounds
    let assumedCalibrationUncertaintyMeters:Double
    let isotropicJawEnvelopeMeters:Double
    let intersamplePointTravelAllowanceMeters:Double
    let curvatureAllowanceMeters:Double
    let maximumHullTravelMeters:Double
    let unknownVoxelCount:Int
    let unknownLocalRegions:[LocalRegion]
    let staticRobotLinks:[ROBWorkspaceStaticRobotLinkEvidence]
    let initialSelfMinimumMeters:Double,endpointSelfMinimumMeters:Double
    let emptyStateEvidenceSource:String
    let calibrationUncertaintyCertified:Bool
    let occupiedVoxelsMutated:Bool
    let automaticChainingPermitted:Bool
    struct AssumedSelfGroup:Codable,Equatable {
        let sourceGroupID:String
        let sourceVoxel:[Int]
        let originalBounds:ROBWorkspaceOccupiedReturnBounds
        let baselineMovingLink:String
    }
    struct AssumedSelfAudit:Codable,Equatable {
        let label:String
        let completeSourceGroupCount:Int
        let completeSourceGroupsSHA256:String
        let baseline:[Double]
        let mapFingerprint:String,modelID:String,referenceID:String,geometryID:String,mappingID:String
        let bodyMotionIdentity:String,cameraGeneration:UUID,gatewayGeneration:UInt64
        let groups:[AssumedSelfGroup]
        let observedSelf:Bool
        let rawMapModified:Bool
    }
    let modelAssumedSelfAudit:AssumedSelfAudit?
    var sourcePixelSelfAudit:ROBWorkspaceSourcePixelSelf.Audit? = nil
    var step:ROBLeftGestureProposal.Step {.init(positions:goal,seconds:4,stage:"One UNVERIFIED nominal EMPTY commissioning retreat, then hold")}
    func validateContext(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,
        cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        measuredBaseline:[Double],nominalEmptyCommissioningEnabled:Bool,emptyStateEvidenceSource:String,modelAssumedSelfEnabled:Bool=false,
        sourcePixelSelfView:ROBWorkspaceSourcePixelSelf.View?=nil)throws {
        let current=try ROBWorkspaceCollisionPlan.validateVisualCalibrationTrialMap(map,model:model,generation:generation,
            sceneID:sceneID,cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        let drift=1.5*zip(baseline,measuredBaseline).reduce(0.0){$0+abs($1.0-$1.1)}
        if let view=sourcePixelSelfView {
#if DEBUG
            try view.validate(map:map,model:model,baseline:measuredBaseline,now:nowMilliseconds)
            guard !modelAssumedSelfEnabled,modelAssumedSelfAudit==nil,sourcePixelSelfAudit==view.audit,!view.audit.excludedGroups.isEmpty else {
                throw ROBGhostMotionError.blocked("Frozen experimental source-pixel classification/audit changed.")
            }
#else
            throw ROBGhostMotionError.blocked("Source-pixel EMPTY commissioning is DEBUG only.")
#endif
        } else if sourcePixelSelfAudit != nil {throw ROBGhostMotionError.blocked("A decoded source-pixel proof needs its current native perception view.")}
        if let audit=modelAssumedSelfAudit {
            guard modelAssumedSelfEnabled,audit.label=="assumed_alignment_not_observed_self",!audit.observedSelf,!audit.rawMapModified,
                  audit.baseline==baseline,audit.mapFingerprint==map.fingerprint,audit.modelID==model.modelID,audit.referenceID==model.referenceID,
                  audit.geometryID==model.geometryID,audit.mappingID==model.selectedMappingID,audit.bodyMotionIdentity==trial.bodyMotionIdentity,
                  audit.cameraGeneration==cameraGeneration,audit.gatewayGeneration==generation,!audit.groups.isEmpty else {
                throw ROBGhostMotionError.blocked("Frozen MODEL-ASSUMED group/q0/reference/source identity changed.")
            }
        }
        let expectedMode=sourcePixelSelfView != nil ? "unverified_nominal_empty_source_pixel_self_commissioning_retreat":
            (modelAssumedSelfEnabled ? "unverified_nominal_empty_model_assumed_self_commissioning_retreat":"unverified_nominal_empty_commissioning_retreat")
        guard nominalEmptyCommissioningEnabled,mode==expectedMode,
              (modelAssumedSelfAudit != nil)==modelAssumedSelfEnabled,model.physicalSide=="right",
              context.visualTrial==trial,current.mapFingerprint==context.mapFingerprint,
              context.modelID==current.modelID,context.geometryID==current.geometryID,context.mappingID==current.mappingID,
              measuredBaseline.count==7,drift.isFinite,drift<=min(0.002,minimumSweptNominalClearanceMeters/2),
              maximumHullTravelMeters+drift<=0.060,nowMilliseconds-measuredAtMilliseconds>=0,nowMilliseconds-measuredAtMilliseconds<=150,
              baseline==trial.baseline,goal==zip(baseline,[0.0,-0.075,0,0,0,0,0]).map(+),
              checkedPoseCount==129,minimumSweptNominalClearanceMeters>0,minimumAfterJawEnvelopeMeters>minimumSweptNominalClearanceMeters,
              assumedCalibrationUncertaintyMeters==0.035,isotropicJawEnvelopeMeters==0.040,
              !calibrationUncertaintyCertified,!occupiedVoxelsMutated,!automaticChainingPermitted,
              self.emptyStateEvidenceSource==emptyStateEvidenceSource,!unknownLocalRegions.isEmpty,
              (0...60_000).contains(nowMilliseconds-context.checkedAtMilliseconds) else {
            throw ROBGhostMotionError.blocked("The separate nominal EMPTY commissioning proof, permission, fresh start or context changed. Hold; no trial step admitted.")
        }
    }
    func validate(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,
        cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        measuredBaseline:[Double],nominalEmptyCommissioningEnabled:Bool,emptyStateEvidenceSource:String,modelAssumedSelfEnabled:Bool=false)throws {
        try validateContext(map:map,model:model,generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,
            nowMilliseconds:nowMilliseconds,trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,measuredBaseline:measuredBaseline,
            nominalEmptyCommissioningEnabled:nominalEmptyCommissioningEnabled,emptyStateEvidenceSource:emptyStateEvidenceSource,modelAssumedSelfEnabled:modelAssumedSelfEnabled)
        let expected=try ROBWorkspaceCollisionPlan.buildNominalEmptyCommissioningRetreat(id:id,from:baseline,map:map,model:model,
            generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,nowMilliseconds:context.checkedAtMilliseconds,
            trial:trial,measuredAtMilliseconds:self.measuredAtMilliseconds,nominalEmptyCommissioningEnabled:nominalEmptyCommissioningEnabled,
            emptyStateEvidenceSource:emptyStateEvidenceSource,modelAssumedSelfEnabled:modelAssumedSelfEnabled)
        guard expected==self else {throw ROBGhostMotionError.blocked("The nominal commissioning geometry, raw returns or recorded local scope changed.")}
    }
    func validateSourcePixelContext(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,
        cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        measuredBaseline:[Double],nominalEmptyCommissioningEnabled:Bool,emptyStateEvidenceSource:String,
        sourcePixelSelfView:ROBWorkspaceSourcePixelSelf.View)throws {
        try validateContext(map:map,model:model,generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,
            nowMilliseconds:nowMilliseconds,trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,measuredBaseline:measuredBaseline,
            nominalEmptyCommissioningEnabled:nominalEmptyCommissioningEnabled,emptyStateEvidenceSource:emptyStateEvidenceSource,
            sourcePixelSelfView:sourcePixelSelfView)
    }
    func validateSourcePixel(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,
        cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        measuredBaseline:[Double],nominalEmptyCommissioningEnabled:Bool,emptyStateEvidenceSource:String,
        sourcePixelSelfView:ROBWorkspaceSourcePixelSelf.View)throws {
        try validateSourcePixelContext(map:map,model:model,generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,
            nowMilliseconds:nowMilliseconds,trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,measuredBaseline:measuredBaseline,
            nominalEmptyCommissioningEnabled:nominalEmptyCommissioningEnabled,emptyStateEvidenceSource:emptyStateEvidenceSource,sourcePixelSelfView:sourcePixelSelfView)
        let expected=try ROBWorkspaceCollisionPlan.buildNominalEmptyCommissioningRetreat(id:id,from:baseline,map:map,model:model,
            generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,nowMilliseconds:context.checkedAtMilliseconds,
            trial:trial,measuredAtMilliseconds:self.measuredAtMilliseconds,nominalEmptyCommissioningEnabled:nominalEmptyCommissioningEnabled,
            emptyStateEvidenceSource:emptyStateEvidenceSource,sourcePixelSelfView:sourcePixelSelfView)
        guard expected==self else {throw ROBGhostMotionError.blocked("The source-pixel commissioning geometry, actual sources or classified-return audit changed.")}
    }
}
extension ROBWorkspaceCollisionPlan {
    static func reviewSourcePixelNominalEmptyCommissioningRetreat(from baseline:[Double],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,
        trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,nominalEmptyCommissioningEnabled:Bool,
        emptyStateEvidenceSource:String,sourcePixelSelfView:ROBWorkspaceSourcePixelSelf.View)throws->ROBWorkspaceNominalEmptyCommissioningRetreat {
#if DEBUG
        try buildNominalEmptyCommissioningRetreat(id:UUID(),from:baseline,map:map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,
            nominalEmptyCommissioningEnabled:nominalEmptyCommissioningEnabled,emptyStateEvidenceSource:emptyStateEvidenceSource,sourcePixelSelfView:sourcePixelSelfView)
#else
        throw ROBGhostMotionError.blocked("Source-pixel EMPTY commissioning is DEBUG only.")
#endif
    }
    static func reviewNominalEmptyCommissioningRetreat(from baseline:[Double],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,
        trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,nominalEmptyCommissioningEnabled:Bool,
        emptyStateEvidenceSource:String,modelAssumedSelfEnabled:Bool=false)throws->ROBWorkspaceNominalEmptyCommissioningRetreat {
        try buildNominalEmptyCommissioningRetreat(id:UUID(),from:baseline,map:map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,
            nominalEmptyCommissioningEnabled:nominalEmptyCommissioningEnabled,emptyStateEvidenceSource:emptyStateEvidenceSource,modelAssumedSelfEnabled:modelAssumedSelfEnabled)
    }
    fileprivate static func buildNominalEmptyCommissioningRetreat(id:UUID,from baseline:[Double],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,
        trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,nominalEmptyCommissioningEnabled:Bool,
        emptyStateEvidenceSource:String,modelAssumedSelfEnabled:Bool=false,sourcePixelSelfView:ROBWorkspaceSourcePixelSelf.View?=nil)throws->ROBWorkspaceNominalEmptyCommissioningRetreat {
        let context=try validateVisualCalibrationTrialMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        if let view=sourcePixelSelfView {
#if DEBUG
            try view.validate(map:map,model:model,baseline:baseline,now:nowMilliseconds)
            guard !modelAssumedSelfEnabled,!view.audit.excludedGroups.isEmpty else {throw ROBGhostMotionError.blocked("No isolated current experimental robot-pixel group was recognized; every raw obstacle remains.")}
#else
            throw ROBGhostMotionError.blocked("Source-pixel EMPTY commissioning is DEBUG only.")
#endif
        }
        guard nominalEmptyCommissioningEnabled,model.physicalSide=="right",baseline.count==7,baseline==trial.baseline,
              baseline.enumerated().allSatisfy({i,q in q.isFinite && ((modelAssumedSelfEnabled || sourcePixelSelfView != nil) && i==1 ? (-0.04...0.004).contains(q):abs(q)<=0.004)}),trial.assumedSpatialErrorMeters==0.035,
              ["operator_declared_empty","local_first_attempt_no_arm_travel_or_task_grip"].contains(emptyStateEvidenceSource),
              measuredAtMilliseconds.isFinite,(0...150).contains(nowMilliseconds-measuredAtMilliseconds),
              let supplied=map.originalOccupiedReturnBounds,!supplied.isEmpty,supplied.count<=400_000 else {
            throw ROBGhostMotionError.blocked("The nominal EMPTY commissioning step needs its distinct local permission, fresh q0,35mm assumed uncertainty and every original occupied return.")
        }
        let goal=zip(baseline,[0.0,-0.075,0,0,0,0,0]).map(+),limits=jointBounds(model:model)
        guard zip(goal,limits).allSatisfy({$0.isFinite && $1.contains($0)}),zip(baseline,goal).allSatisfy({abs($1-$0)<=0.20}) else {
            throw ROBGhostMotionError.blocked("The nominal commissioning endpoint exceeds unchanged joint bounds.")
        }
        var raw:[ROBNominalRawBox]=[],seen=Set<String>()
        for value in supplied {let lo=value.lowMeters,hi=value.highMeters
            guard lo.count==3,hi.count==3,(lo+hi).allSatisfy({$0.isFinite && abs($0)<=10}),zip(lo,hi).allSatisfy({$0<=$1}) else {
                throw ROBGhostMotionError.blocked("An original occupied-return bound is invalid; no nominal trial admitted.")
            }
            let key=(lo+hi).map{String($0.bitPattern)}.joined(separator:":")
            if seen.insert(key).inserted {raw.append(.init(low:SIMD3(lo[0],lo[1],lo[2]),high:SIMD3(hi[0],hi[1],hi[2]),key:key))}
        }
        raw.sort{$0.key<$1.key}
        let rawHash=ROBGhostRobotModel.hash(Data(raw.map(\.key).joined(separator:"\n").utf8))
        let catalogData=try Data(contentsOf:model.directory.appendingPathComponent("surfaces.json"))
        guard ROBGhostRobotModel.hash(catalogData)==model.geometryID,
              let catalog=try JSONSerialization.jsonObject(with:catalogData)as?[String:Any],catalog["modelID"]as?String==model.modelID,
              let records=catalog["surfaces"]as?[[String:Any]] else {throw ROBGhostMotionError.blocked("The nominal trial geometry catalog changed.")}
        var shapes:[String:ROBNominalShape]=[:]
        for row in records {
            guard let link=row["link"]as?String,link.hasPrefix(model.physicalSide+"_"),
                  link.hasSuffix("_Link") || link==model.toolLink || link==model.physicalSide+"_base_link" else {continue}
            guard let path=row["hull"]as?String,model.hulls[link]==path,!path.hasPrefix("/"),!path.contains(".."),
                  let sha=row["hullSHA256"]as?String,shapes[link]==nil else {throw ROBGhostMotionError.blocked("A nominal arm hull identity is invalid.")}
            let data=try Data(contentsOf:model.directory.appendingPathComponent(path))
            guard ROBGhostRobotModel.hash(data)==sha,let text=String(data:data,encoding:.utf8) else {throw ROBGhostMotionError.blocked("A nominal arm hull changed.")}
            shapes[link]=try ROBNominalShape(text:text)
        }
        guard shapes.count>=9 else {throw ROBGhostMotionError.blocked("The complete arm and gripper hulls are required for a nominal trial.")}
        let links=shapes.keys.sorted(),startFrames=model.frames(model.positions(vendorLeft:baseline)),count=128
        // Analytic ancestor proof identifies only links upstream of the SOLE
        // moving joint. Exact transforms and every vertex are checked below.
        let movingJoint=model.armJointPrefix+"2"
        var fixed=Set<String>()
        for link in links {var child=link,visited=Set<String>(),depends=false
            while child != "base_link" {
                guard visited.insert(child).inserted,let joint=model.joints.first(where:{$0.child==child}) else {throw ROBGhostMotionError.blocked("The nominal trial kinematic chain is incomplete.")}
                if joint.name==movingJoint {depends=true};child=joint.parent
            }
            if !depends {fixed.insert(link)}
        }
        var assumedAudit:ROBWorkspaceNominalEmptyCommissioningRetreat.AssumedSelfAudit?
        if modelAssumedSelfEnabled {
            guard let groups=map.originalOccupiedSourceGroups,!groups.isEmpty,groups.count<=400_000,map.voxelSizeMeters==0.025 else {
                throw ROBGhostMotionError.blocked("MODEL-ASSUMED self commissioning requires complete original source groups; legacy/incomplete unions remain external.")
            }
            var cells:[SIMD3<Int>:ROBNominalRawBox]=[:],groupIDs=Set<String>(),ordered:[(ROBWorkspaceOccupiedSourceGroup,ROBNominalRawBox)]=[]
            for group in groups {
                guard group.sourceVoxel.count==3,groupIDs.insert(group.id).inserted,
                      group.bounds.lowMeters.count==3,group.bounds.highMeters.count==3 else {throw ROBGhostMotionError.blocked("Incomplete original source-group provenance.")}
                let lo=group.bounds.lowMeters,hi=group.bounds.highMeters,size=map.voxelSizeMeters
                guard (lo+hi).allSatisfy({$0.isFinite && abs($0)<=10}),zip(lo,hi).allSatisfy({$0<=$1}),
                      (0..<3).allSatisfy({Int(floor(lo[$0]/size))==group.sourceVoxel[$0] && Int(floor(hi[$0]/size))==group.sourceVoxel[$0]}) else {throw ROBGhostMotionError.blocked("An original source group exceeds its exact source voxel.")}
                let b=ROBNominalRawBox(low:SIMD3(lo[0],lo[1],lo[2]),high:SIMD3(hi[0],hi[1],hi[2]),key:group.id)
                ordered.append((group,b))
                for x in -1...1 {for y in -1...1 {for z in -1...1 {
                    let c=SIMD3(group.sourceVoxel[0]+x,group.sourceVoxel[1]+y,group.sourceVoxel[2]+z)
                    if let old=cells[c] {cells[c] = .init(low:simd_min(old.low,b.low),high:simd_max(old.high,b.high),key:"")}
                    else {cells[c]=b}
                }}}
            }
            var reconstructed=Set<String>()
            for (cell,b) in cells {
                let point=(SIMD3<Double>(Double(cell.x),Double(cell.y),Double(cell.z))+0.5)*map.voxelSizeMeters
                guard map.state(at:point) == .occupied,let actual=map.occupiedSampleBounds(at:point),
                      (0..<3).allSatisfy({abs(actual.low[$0]-b.low[$0])<=1e-12 && abs(actual.high[$0]-b.high[$0])<=1e-12}) else {
                    throw ROBGhostMotionError.blocked("Incomplete source groups cannot reconstruct every retained occupied union.")
                }
                reconstructed.insert(([b.low.x,b.low.y,b.low.z,b.high.x,b.high.y,b.high.z]).map{String($0.bitPattern)}.joined(separator:":"))
            }
            guard reconstructed==seen else {throw ROBGhostMotionError.blocked("Incomplete source groups leave an original occupied union unaccounted for.")}
            var excluded:[ROBWorkspaceNominalEmptyCommissioningRetreat.AssumedSelfGroup]=[],external:[ROBNominalRawBox]=[]
            let moving=links.filter{!fixed.contains($0)}.map{($0,ROBNominalWorldShape(shapes[$0]!,startFrames[$0]!))}
            for (group,b) in ordered.sorted(by:{$0.0.id<$1.0.id}) {
                let owner=moving.first{_,shape in
                    // Every corner must be in the NONinflated convex hull.
                    // Never test only a center or an intersecting AABB.
                    for x in [b.low.x,b.high.x] {for y in [b.low.y,b.high.y] {for z in [b.low.z,b.high.z] {
                        let p=SIMD3(x,y,z)
                        if !zip(shape.axes,shape.supportIntervals).allSatisfy({n,interval in let d=simd_dot(n,p);return d>=interval.0 && d<=interval.1}) {return false}
                    }}}
                    return true
                }?.0
                if let owner {excluded.append(.init(sourceGroupID:group.id,sourceVoxel:group.sourceVoxel,originalBounds:group.bounds,baselineMovingLink:owner))}
                else {external.append(b)}
            }
            guard !excluded.isEmpty,!external.isEmpty else {throw ROBGhostMotionError.blocked("MODEL-ASSUMED commissioning needs isolated complete self hypotheses and retained external returns.")}
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            assumedAudit = .init(label:"assumed_alignment_not_observed_self",completeSourceGroupCount:groups.count,
                completeSourceGroupsSHA256:ROBGhostRobotModel.hash(try encoder.encode(ordered.sorted{$0.0.id<$1.0.id}.map{$0.0})),baseline:baseline,
                mapFingerprint:map.fingerprint,modelID:model.modelID,referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
                bodyMotionIdentity:trial.bodyMotionIdentity,cameraGeneration:cameraGeneration,gatewayGeneration:generation,
                groups:excluded,observedSelf:false,rawMapModified:false)
            raw=external
        }
        if let view=sourcePixelSelfView {
            raw=view.retainedGroups.map { group in
                let a=group.bounds.lowMeters,b=group.bounds.highMeters
                return ROBNominalRawBox(low:SIMD3(a[0],a[1],a[2]),high:SIMD3(b[0],b[1],b[2]),key:group.id)
            }
        }
        let intersample=1.5*0.075/(2*Double(count)),curvature=0.75*pow(0.075/Double(count),2)
        var minimumRaw=Double.infinity,minimumJaw=Double.infinity,closestLink="",closestBox:ROBNominalRawBox?
        var previous:[String:[SIMD3<Double>]]=[:],cumulative:[String:[Double]]=[:],maximumTravel=0.0
        var regionLow:[String:SIMD3<Double>]=[:],regionHigh:[String:SIMD3<Double>]=[:],fixedEvidence:[ROBWorkspaceStaticRobotLinkEvidence]=[]
        var selfChecker=ROBWorkspaceSelfProxyClearance(model:model),initialSelf:[String:Double]?,previousSelf:[String:Double]?,endpointSelf:[String:Double]=[:]
        for sample in 0...count {
            let t=Double(sample)/Double(count),q=zip(baseline,goal).map{$0+($1-$0)*t},positions=model.positions(vendorLeft:q),frames=model.frames(positions)
            let selfPairs=try selfChecker.separations(vendorLeft:q)
            if initialSelf==nil {initialSelf=selfPairs}
            if let before=previousSelf {for (key,distance) in selfPairs {
                guard distance+1e-9>=min(before[key]!,0.030) else {throw ROBGhostMotionError.blocked("The nominal empty retreat worsens a current arm/tread clearance pair.")}
            }}
            previousSelf=selfPairs;endpointSelf=selfPairs
            for link in links {
                guard let frame=frames[link],let firstFrame=startFrames[link] else {throw ROBGhostMotionError.blocked("The nominal trial lost an arm transform.")}
                let shape=ROBNominalWorldShape(shapes[link]!,frame)
                if let prior=previous[link] {var lengths=cumulative[link] ?? Array(repeating:0,count:shape.vertices.count)
                    for i in shape.vertices.indices {lengths[i]+=simd_distance(prior[i],shape.vertices[i])+curvature}
                    cumulative[link]=lengths;maximumTravel=max(maximumTravel,lengths.max() ?? 0)
                };previous[link]=shape.vertices
                guard maximumTravel<=0.060 else {throw ROBGhostMotionError.blocked("The nominal commissioning sweep exceeds60mm full-hull travel.")}
                if fixed.contains(link) {
                    guard (0..<4).allSatisfy({c in (0..<4).allSatisfy{abs(frame[c][$0]-firstFrame[c][$0])<=1e-12}}) else {throw ROBGhostMotionError.blocked("A supposedly static robot link moved during the nominal sweep.")}
                    if sample==0 {fixedEvidence.append(.init(kind:"invariant_robot_link_no_new_sweep",link:link,bodyMotionIdentity:trial.bodyMotionIdentity,
                        frameColumnMajor:(0..<4).flatMap{c in (0..<4).map{r in frame[c][r]}},lowMeters:[shape.box.low.x,shape.box.low.y,shape.box.low.z],highMeters:[shape.box.high.x,shape.box.high.y,shape.box.high.z]))}
                    continue
                }
                let jaw=link==model.toolLink ? 0.040:0,nominalEnvelope=jaw+intersample+curvature
                // A broadphase lower bound rejects no source geometry. Every
                // return that could approach the nominal jaw/hull is queried
                // against its ORIGINAL bounds, never a dilated voxel center.
                for b in raw where shape.box.gap(to:b)<=jaw+0.060 {
                    let distance=try shape.distance(b),afterJaw=distance-jaw
                    minimumRaw=min(minimumRaw,distance)
                    if afterJaw<minimumJaw {minimumJaw=afterJaw;closestLink=link;closestBox=b}
                    guard distance>nominalEnvelope else {throw ROBGhostMotionError.blocked("The UNVERIFIED nominal empty retreat would contact an original occupied return, including40mm gripper envelope and intersample motion. No step admitted.")}
                }
                let pad=jaw+intersample+curvature+trial.assumedSpatialErrorMeters
                let low=shape.box.low-SIMD3(repeating:pad),high=shape.box.high+SIMD3(repeating:pad)
                regionLow[link]=regionLow[link].map{simd_min($0,low)} ?? low;regionHigh[link]=regionHigh[link].map{simd_max($0,high)} ?? high
            }
        }
        guard endpointSelf.values.allSatisfy({$0>=0.030}),let closestBox,minimumJaw.isFinite,minimumJaw>intersample+curvature else {
            throw ROBGhostMotionError.blocked("The nominal retreat must finish with ordinary30mm self clearance and retain positive nominal raw-return clearance.")
        }
        var unknown=Set<SIMD3<Int>>(),regions:[ROBWorkspaceNominalEmptyCommissioningRetreat.LocalRegion]=[]
        for link in links where !fixed.contains(link) {let low=regionLow[link]!,high=regionHigh[link]!,size=map.voxelSizeMeters
            let lo=(0..<3).map{Int(floor(low[$0]/size))},hi=(0..<3).map{Int(floor(high[$0]/size))}
            guard zip(lo,hi).allSatisfy({$1 >= $0 && $1-$0<=100}),zip(lo,hi).reduce(1,{$0*($1.1-$1.0+1)})<=250_000 else {throw ROBGhostMotionError.blocked("The nominal commissioning unknown region exceeds its local bound.")}
            for x in lo[0]...hi[0] {for y in lo[1]...hi[1] {for z in lo[2]...hi[2] {
                if map.state(at:SIMD3((Double(x)+0.5)*size,(Double(y)+0.5)*size,(Double(z)+0.5)*size)) == .unknown {unknown.insert(SIMD3(x,y,z))}
            }}}
            regions.append(.init(link:link,lowMeters:[low.x,low.y,low.z],highMeters:[high.x,high.y,high.z]))
        }
        let mode=sourcePixelSelfView != nil ? "unverified_nominal_empty_source_pixel_self_commissioning_retreat":
            (modelAssumedSelfEnabled ? "unverified_nominal_empty_model_assumed_self_commissioning_retreat":"unverified_nominal_empty_commissioning_retreat")
        return .init(id:id,mode:mode,context:context,baseline:baseline,goal:goal,
            measuredAtMilliseconds:measuredAtMilliseconds,checkedPoseCount:count+1,originalOccupiedBoundsCount:supplied.count,
            deduplicatedOccupiedBoundsCount:raw.count,originalOccupiedBoundsSHA256:rawHash,
            minimumRawClearanceMeters:minimumRaw,minimumAfterJawEnvelopeMeters:minimumJaw,
            minimumSweptNominalClearanceMeters:minimumJaw-intersample-curvature,closestMovingLink:closestLink,
            closestRawBounds:.init(lowMeters:[closestBox.low.x,closestBox.low.y,closestBox.low.z],highMeters:[closestBox.high.x,closestBox.high.y,closestBox.high.z]),
            assumedCalibrationUncertaintyMeters:0.035,isotropicJawEnvelopeMeters:0.040,intersamplePointTravelAllowanceMeters:intersample,
            curvatureAllowanceMeters:curvature,maximumHullTravelMeters:maximumTravel,unknownVoxelCount:unknown.count,unknownLocalRegions:regions,
            staticRobotLinks:fixedEvidence,initialSelfMinimumMeters:initialSelf!.values.min()!,endpointSelfMinimumMeters:endpointSelf.values.min()!,
            emptyStateEvidenceSource:emptyStateEvidenceSource,calibrationUncertaintyCertified:false,occupiedVoxelsMutated:false,automaticChainingPermitted:false,modelAssumedSelfAudit:assumedAudit,sourcePixelSelfAudit:sourcePixelSelfView?.audit)
    }
}

/// One explicitly risk-accepted EMPTY actuator-calibration observation.
/// Environment estimates are diagnostics ONLY. This is neither a collision
/// certificate nor a recycling/grasp/carry capability.
struct ROBWorkspaceOneDegreeEmptyCalibrationStep:Codable,Equatable {
    struct EnvironmentDiagnostics:Codable,Equatable {
        let diagnosticOnly:Bool
        let sourceBoundsAllRetained:Bool
        let originalOccupiedBoundsCount:Int,deduplicatedOccupiedBoundsCount:Int
        let originalOccupiedBoundsSHA256:String
        let minimumRawClearanceMeters:Double?
        let minimumAfterJawEnvelopeMeters:Double?
        let minimumSweptNominalClearanceMeters:Double?
        let closestMovingLink:String?
        let closestRawBounds:ROBWorkspaceOccupiedReturnBounds?
        let predictedNominalContact:Bool
        let isotropicJawEnvelopeMeters:Double
        let assumedCalibrationUncertaintyMeters:Double
        let intersampleAllowanceMeters:Double
    }
    let id:UUID
    let mode:String
    let context:ROBWorkspaceCollisionContext
    let baseline:[Double],goal:[Double]
    let measuredAtMilliseconds:Double
    let maximumHullTravelMeters:Double
    let checkedPoseCount:Int
    let staticRobotLinks:[ROBWorkspaceStaticRobotLinkEvidence]
    let initialSelfMinimumMeters:Double,endpointSelfMinimumMeters:Double
    let unknownVoxelCount:Int
    let unknownLocalRegions:[ROBWorkspaceNominalEmptyCommissioningRetreat.LocalRegion]
    let environmentDiagnostics:EnvironmentDiagnostics
    let environmentPredictionIsDiagnosticOnly:Bool
    let collisionCertificate:Bool
    let occupiedVoxelsMutated:Bool
    let automaticChainingPermitted:Bool
    let emptyStateAssumed:Bool
    let emptyStateEvidenceSource:String
    let completedTransferCount:Int
    var step:ROBLeftGestureProposal.Step {.init(positions:goal,seconds:4,stage:"One EMPTY RIGHT J2 actuator calibration step, then hold; environment unverified")}
    func validateContext(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,
        cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        measuredBaseline:[Double],oneDegreeEmptyCalibrationStepEnabled:Bool,emptyStateEvidenceSource:String)throws {
        let current=try ROBWorkspaceCollisionPlan.validateVisualCalibrationTrialMap(map,model:model,generation:generation,
            sceneID:sceneID,cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        let drift=1.5*zip(baseline,measuredBaseline).reduce(0.0){$0+abs($1.0-$1.1)}
        guard oneDegreeEmptyCalibrationStepEnabled,mode=="risk_accepted_one_degree_empty_actuator_calibration",model.physicalSide=="right",
              context.visualTrial==trial,current.mapFingerprint==context.mapFingerprint,
              context.modelID==current.modelID,context.geometryID==current.geometryID,context.mappingID==current.mappingID,
              measuredBaseline.count==7,drift.isFinite,drift<=0.003,maximumHullTravelMeters+drift<=0.020,
              nowMilliseconds-measuredAtMilliseconds>=0,nowMilliseconds-measuredAtMilliseconds<=150,
              baseline==trial.baseline,goal==zip(baseline,[0.0,-0.020,0,0,0,0,0]).map(+),checkedPoseCount==65,
              maximumHullTravelMeters.isFinite,(0...0.020).contains(maximumHullTravelMeters),
              environmentPredictionIsDiagnosticOnly,environmentDiagnostics.diagnosticOnly,environmentDiagnostics.sourceBoundsAllRetained,
              !collisionCertificate,!occupiedVoxelsMutated,!automaticChainingPermitted,emptyStateAssumed,completedTransferCount==0,
              self.emptyStateEvidenceSource==emptyStateEvidenceSource,!unknownLocalRegions.isEmpty,
              (0...60_000).contains(nowMilliseconds-context.checkedAtMilliseconds) else {
            throw ROBGhostMotionError.blocked("The distinct one-degree EMPTY actuator permission, fresh start or frozen body/source/receipt context changed. Hold; no calibration command admitted.")
        }
    }
    func validate(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,
        cameraGeneration:UUID,nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        measuredBaseline:[Double],oneDegreeEmptyCalibrationStepEnabled:Bool,emptyStateEvidenceSource:String)throws {
        try validateContext(map:map,model:model,generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,
            nowMilliseconds:nowMilliseconds,trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,measuredBaseline:measuredBaseline,
            oneDegreeEmptyCalibrationStepEnabled:oneDegreeEmptyCalibrationStepEnabled,emptyStateEvidenceSource:emptyStateEvidenceSource)
        let expected=try ROBWorkspaceCollisionPlan.buildOneDegreeEmptyCalibrationStep(id:id,from:baseline,map:map,model:model,
            generation:generation,sceneID:sceneID,cameraGeneration:cameraGeneration,nowMilliseconds:context.checkedAtMilliseconds,
            trial:trial,measuredAtMilliseconds:self.measuredAtMilliseconds,oneDegreeEmptyCalibrationStepEnabled:oneDegreeEmptyCalibrationStepEnabled,
            emptyStateEvidenceSource:emptyStateEvidenceSource)
        guard expected==self else {throw ROBGhostMotionError.blocked("The one-degree actuator proof or retained environment diagnostics changed.")}
    }
}
extension ROBWorkspaceCollisionPlan {
    static func reviewOneDegreeEmptyCalibrationStep(from baseline:[Double],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,
        trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,oneDegreeEmptyCalibrationStepEnabled:Bool,
        emptyStateEvidenceSource:String)throws->ROBWorkspaceOneDegreeEmptyCalibrationStep {
        try buildOneDegreeEmptyCalibrationStep(id:UUID(),from:baseline,map:map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial,measuredAtMilliseconds:measuredAtMilliseconds,
            oneDegreeEmptyCalibrationStepEnabled:oneDegreeEmptyCalibrationStepEnabled,emptyStateEvidenceSource:emptyStateEvidenceSource)
    }
    fileprivate static func buildOneDegreeEmptyCalibrationStep(id:UUID,from baseline:[Double],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,nowMilliseconds:Double,
        trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,oneDegreeEmptyCalibrationStepEnabled:Bool,
        emptyStateEvidenceSource:String)throws->ROBWorkspaceOneDegreeEmptyCalibrationStep {
        let context=try validateVisualCalibrationTrialMap(map,model:model,generation:generation,sceneID:sceneID,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds,trial:trial)
        guard oneDegreeEmptyCalibrationStepEnabled,model.physicalSide=="right",baseline.count==7,baseline==trial.baseline,
              baseline.allSatisfy({$0.isFinite && abs($0)<=0.004}),
              ["operator_declared_empty","local_first_attempt_no_arm_travel_or_task_grip"].contains(emptyStateEvidenceSource),
              measuredAtMilliseconds.isFinite,(0...150).contains(nowMilliseconds-measuredAtMilliseconds),
              let supplied=map.originalOccupiedReturnBounds,!supplied.isEmpty,supplied.count<=400_000 else {
            throw ROBGhostMotionError.blocked("The one-degree actuator calibration needs its NEW distinct permission, fresh EMPTY q0 and retained raw source diagnostics.")
        }
        let goal=zip(baseline,[0.0,-0.020,0,0,0,0,0]).map(+),limits=jointBounds(model:model)
        guard zip(goal,limits).allSatisfy({$0.isFinite && $1.contains($0)}),zip(baseline,goal).allSatisfy({abs($1-$0)<=0.020000001}) else {
            throw ROBGhostMotionError.blocked("The one-degree actuator endpoint exceeds unchanged raw/model joint bounds.")
        }
        var raw:[ROBNominalRawBox]=[],seen=Set<String>()
        for value in supplied {let lo=value.lowMeters,hi=value.highMeters
            guard lo.count==3,hi.count==3,(lo+hi).allSatisfy({$0.isFinite && abs($0)<=10}),zip(lo,hi).allSatisfy({$0<=$1}) else {
                throw ROBGhostMotionError.blocked("An original occupied-return bound is invalid; no nominal trial admitted.")
            }
            let key=(lo+hi).map{String($0.bitPattern)}.joined(separator:":")
            if seen.insert(key).inserted {raw.append(.init(low:SIMD3(lo[0],lo[1],lo[2]),high:SIMD3(hi[0],hi[1],hi[2]),key:key))}
        }
        raw.sort{$0.key<$1.key}
        let rawHash=ROBGhostRobotModel.hash(Data(raw.map(\.key).joined(separator:"\n").utf8))
        let catalogData=try Data(contentsOf:model.directory.appendingPathComponent("surfaces.json"))
        guard ROBGhostRobotModel.hash(catalogData)==model.geometryID,
              let catalog=try JSONSerialization.jsonObject(with:catalogData)as?[String:Any],catalog["modelID"]as?String==model.modelID,
              let records=catalog["surfaces"]as?[[String:Any]] else {throw ROBGhostMotionError.blocked("The nominal trial geometry catalog changed.")}
        var shapes:[String:ROBNominalShape]=[:]
        for row in records {
            guard let link=row["link"]as?String,link.hasPrefix(model.physicalSide+"_"),
                  link.hasSuffix("_Link") || link==model.toolLink || link==model.physicalSide+"_base_link" else {continue}
            guard let path=row["hull"]as?String,model.hulls[link]==path,!path.hasPrefix("/"),!path.contains(".."),
                  let sha=row["hullSHA256"]as?String,shapes[link]==nil else {throw ROBGhostMotionError.blocked("A nominal arm hull identity is invalid.")}
            let data=try Data(contentsOf:model.directory.appendingPathComponent(path))
            guard ROBGhostRobotModel.hash(data)==sha,let text=String(data:data,encoding:.utf8) else {throw ROBGhostMotionError.blocked("A nominal arm hull changed.")}
            shapes[link]=try ROBNominalShape(text:text)
        }
        guard shapes.count>=9 else {throw ROBGhostMotionError.blocked("The complete arm and gripper hulls are required for a nominal trial.")}
        let links=shapes.keys.sorted(),startFrames=model.frames(model.positions(vendorLeft:baseline)),count=64
        var fixed=Set<String>()
        for link in links {var child=link,seen=Set<String>(),depends=false
            while child != "base_link" {guard seen.insert(child).inserted,let joint=model.joints.first(where:{$0.child==child}) else {throw ROBGhostMotionError.blocked("The actuator calibration chain is incomplete.")};if joint.name==model.armJointPrefix+"2" {depends=true};child=joint.parent}
            if !depends {fixed.insert(link)}
        }
        let intersample=1.5*0.020/(2*Double(count)),curvature=0.75*pow(0.020/Double(count),2)
        var previous:[String:[SIMD3<Double>]]=[:],cumulative:[String:[Double]]=[:],maximumTravel=0.0
        var regionLow:[String:SIMD3<Double>]=[:],regionHigh:[String:SIMD3<Double>]=[:],staticLinks:[ROBWorkspaceStaticRobotLinkEvidence]=[]
        var selfChecker=ROBWorkspaceSelfProxyClearance(model:model),initialSelf:[String:Double]?,priorSelf:[String:Double]?,lastSelf:[String:Double]=[:]
        var minimumRaw=Double.infinity,minimumJaw=Double.infinity,closestLink:String?,closestBox:ROBNominalRawBox?
        for sample in 0...count {
            let t=Double(sample)/Double(count),q=zip(baseline,goal).map{$0+($1-$0)*t},positions=model.positions(vendorLeft:q),frames=model.frames(positions)
            let pairs=try selfChecker.separations(vendorLeft:q);if initialSelf==nil{initialSelf=pairs}
            if let before=priorSelf {for (key,value) in pairs {guard value+1e-9>=min(before[key]!,0.030) else {throw ROBGhostMotionError.blocked("The one-degree actuator step worsens the existing modeled arm/tread clearance.")}}};priorSelf=pairs;lastSelf=pairs
            for link in links {guard let frame=frames[link],let first=startFrames[link] else {throw ROBGhostMotionError.blocked("The one-degree step lost an arm transform.")}
                let shape=ROBNominalWorldShape(shapes[link]!,frame)
                if let prior=previous[link] {var lengths=cumulative[link] ?? Array(repeating:0,count:shape.vertices.count)
                    for i in shape.vertices.indices {lengths[i]+=simd_distance(prior[i],shape.vertices[i])+curvature};cumulative[link]=lengths;maximumTravel=max(maximumTravel,lengths.max() ?? 0)
                };previous[link]=shape.vertices
                guard maximumTravel<=0.020 else {throw ROBGhostMotionError.blocked("The one-degree calibration exceeds20mm modeled full-hull travel.")}
                if fixed.contains(link) {guard (0..<4).allSatisfy({c in (0..<4).allSatisfy{abs(frame[c][$0]-first[c][$0])<=1e-12}}) else {throw ROBGhostMotionError.blocked("A fixed link moved in the one-degree model.")}
                    if sample==0 {staticLinks.append(.init(kind:"invariant_robot_link_no_new_sweep",link:link,bodyMotionIdentity:trial.bodyMotionIdentity,
                        frameColumnMajor:(0..<4).flatMap{c in (0..<4).map{r in frame[c][r]}},lowMeters:[shape.box.low.x,shape.box.low.y,shape.box.low.z],highMeters:[shape.box.high.x,shape.box.high.y,shape.box.high.z]))};continue
                }
                let jaw=link==model.toolLink ? 0.040:0
                // DIAGNOSTICS ONLY for this explicitly risk-accepted actuator
                // observation. Every retained return stays in the raw map.
                // Predicted contact is recorded, never renamed as clearance.
                for b in raw where shape.box.gap(to:b)<=jaw+0.100 {
                    let distance=try shape.distance(b);minimumRaw=min(minimumRaw,distance)
                    if distance-jaw<minimumJaw {minimumJaw=distance-jaw;closestLink=link;closestBox=b}
                }
                let pad=jaw+intersample+curvature+trial.assumedSpatialErrorMeters
                let low=shape.box.low-SIMD3(repeating:pad),high=shape.box.high+SIMD3(repeating:pad)
                regionLow[link]=regionLow[link].map{simd_min($0,low)} ?? low;regionHigh[link]=regionHigh[link].map{simd_max($0,high)} ?? high
            }
        }
        var unknown=Set<SIMD3<Int>>(),regions:[ROBWorkspaceNominalEmptyCommissioningRetreat.LocalRegion]=[]
        for link in links where !fixed.contains(link) {let low=regionLow[link]!,high=regionHigh[link]!,size=map.voxelSizeMeters
            let lo=(0..<3).map{Int(floor(low[$0]/size))},hi=(0..<3).map{Int(floor(high[$0]/size))}
            guard zip(lo,hi).allSatisfy({$1 >= $0 && $1-$0<=100}),zip(lo,hi).reduce(1,{$0*($1.1-$1.0+1)})<=250_000 else {throw ROBGhostMotionError.blocked("The actuator observation's diagnostic region exceeds its local bound.")}
            for x in lo[0]...hi[0] {for y in lo[1]...hi[1] {for z in lo[2]...hi[2] {if map.state(at:SIMD3((Double(x)+0.5)*size,(Double(y)+0.5)*size,(Double(z)+0.5)*size)) == .unknown {unknown.insert(SIMD3(x,y,z))}}}}
            regions.append(.init(link:link,lowMeters:[low.x,low.y,low.z],highMeters:[high.x,high.y,high.z]))
        }
        let rawMinimum=minimumRaw.isFinite ? minimumRaw:nil,afterJaw=minimumJaw.isFinite ? minimumJaw:nil
        let swept=afterJaw.map{$0-intersample-curvature}
        let diagnostics=ROBWorkspaceOneDegreeEmptyCalibrationStep.EnvironmentDiagnostics(diagnosticOnly:true,sourceBoundsAllRetained:true,
            originalOccupiedBoundsCount:supplied.count,deduplicatedOccupiedBoundsCount:raw.count,originalOccupiedBoundsSHA256:rawHash,
            minimumRawClearanceMeters:rawMinimum,minimumAfterJawEnvelopeMeters:afterJaw,minimumSweptNominalClearanceMeters:swept,
            closestMovingLink:closestLink,closestRawBounds:closestBox.map{.init(lowMeters:[$0.low.x,$0.low.y,$0.low.z],highMeters:[$0.high.x,$0.high.y,$0.high.z])},
            predictedNominalContact:swept.map{$0<=0} ?? false,isotropicJawEnvelopeMeters:0.040,
            assumedCalibrationUncertaintyMeters:trial.assumedSpatialErrorMeters,intersampleAllowanceMeters:intersample+curvature)
        return .init(id:id,mode:"risk_accepted_one_degree_empty_actuator_calibration",context:context,baseline:baseline,goal:goal,
            measuredAtMilliseconds:measuredAtMilliseconds,maximumHullTravelMeters:maximumTravel,checkedPoseCount:count+1,staticRobotLinks:staticLinks,
            initialSelfMinimumMeters:initialSelf!.values.min()!,endpointSelfMinimumMeters:lastSelf.values.min()!,unknownVoxelCount:unknown.count,
            unknownLocalRegions:regions,environmentDiagnostics:diagnostics,environmentPredictionIsDiagnosticOnly:true,collisionCertificate:false,
            occupiedVoxelsMutated:false,automaticChainingPermitted:false,emptyStateAssumed:true,emptyStateEvidenceSource:emptyStateEvidenceSource,completedTransferCount:0)
    }
}

/// DEBUG commissioning perception hypothesis only. Historical images train a
/// narrowly repeated pixel recognizer; only fresh actually matched returns can
/// be excluded from its separate EMPTY-step review. No object here is a map,
/// measured registration or arm capability, and Template/View cannot decode.
enum ROBWorkspaceSourcePixelSelf {
    struct ReplayFrame {
        let metadataJSON:Data,rgb888:Data,depthU16LittleEndian:Data
    }
    struct ProtectedPolygon:Codable {let label:String,points:[[Int]]}
    struct FrameReview:Codable {
        let frameID:UUID,sequence:UInt64,capturedAtHostMilliseconds:Double,cameraGeneration:UUID
        let width:Int,height:Int,metadataSHA256:String,rgbSHA256:String,depthSHA256:String
        let robotPolygons:[[[Int]]],protectedPolygons:[ProtectedPolygon]
    }
    struct ReviewDocument:Codable {
        let schemaVersion:Int,kind:String,classificationBasis:String,reviewID:UUID,reviewedAtMilliseconds:Double
        let archiveDirectory:String,archiveManifestSHA256:String,sourceMapSHA256:String,mapFingerprint:String
        let frames:[FrameReview]
    }
    struct SourceBinding:Codable,Equatable {
        let manifestSHA256:String,sourceMapSHA256:String,mapFingerprint:String
        let archiveID:UUID,sceneID:UUID,cameraGeneration:UUID,bodyMotionIdentity:String,gatewayGeneration:UInt64
        let modelID:String,referenceID:String,geometryID:String,mappingID:String,estimatedCameraProjectionIdentity:String
    }
    struct Contributor:Codable,Equatable {
        let frameID:UUID,x:Int,y:Int,depthMillimeters:Int
    }
    struct GroupAudit:Codable,Equatable {
        let sourceGroupID:String,sourceVoxel:[Int],originalBounds:ROBWorkspaceOccupiedReturnBounds
        let contributors:[Contributor]
    }
    struct FrameMatch:Codable,Equatable {
        let currentFrameID:UUID,sequence:UInt64,capturedAtHostMilliseconds:Double,cameraGeneration:UUID
        let currentMetadataSHA256:String,currentRGBSHA256:String,currentDepthSHA256:String
        let referenceFrameIDs:[UUID],matchedComponentCount:Int,classifiedAcceptedReturnCount:Int
    }
    struct Audit:Codable,Equatable {
        let label:String,templateReviewSHA256:String,reviewID:UUID,reviewedAtMilliseconds:Double
        let historical:SourceBinding,current:SourceBinding
        let physicalLeftBaseline:[Double],physicalRightBaseline:[Double]
        let frames:[FrameMatch],completeSourceGroupCount:Int,completeSourceGroupsSHA256:String
        let excludedGroups:[GroupAudit],retainedGroupCount:Int,acceptedReturnCount:Int
        let maximumRGBChannelDifference:Int,maximumDepthDifferenceMillimeters:Int,maskErosionPixels:Int
        let minimumAnchorCorrelation:Double,minimumAnchorStandardDeviation:Double
        let rawMapModified:Bool,unknownPromotedToFree:Bool,measuredRegistration:Bool,motionAuthority:Bool
    }
    final class Template {
        fileprivate let archive:Archive,document:ReviewDocument,reviewSHA256:String,components:[[Component]]
        fileprivate init(_ archive:Archive,_ document:ReviewDocument,_ sha:String,_ components:[[Component]]) {
            self.archive=archive;self.document=document;reviewSHA256=sha;self.components=components
        }
    }
    final class View {
        let audit:Audit,fingerprint:String,physicalLeftBaseline:[Double],physicalRightBaseline:[Double]
        fileprivate let retainedGroups:[ROBWorkspaceOccupiedSourceGroup]
        fileprivate init(audit:Audit,retained:[ROBWorkspaceOccupiedSourceGroup])throws {
            self.audit=audit;retainedGroups=retained;physicalLeftBaseline=audit.physicalLeftBaseline;physicalRightBaseline=audit.physicalRightBaseline
            let e=JSONEncoder();e.outputFormatting=[.sortedKeys];fingerprint=ROBGhostRobotModel.hash(try e.encode(audit))
        }
        fileprivate func validate(map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,baseline:[Double],now:Double)throws {
            let c=audit.current
            guard audit.label=="llm_visual_review_experimental_fresh_pixel_match_not_registration",!audit.rawMapModified,!audit.unknownPromotedToFree,
                  !audit.measuredRegistration,!audit.motionAuthority,map.fingerprint==c.mapFingerprint,map.sceneID==c.sceneID,
                  map.cameraGeneration==c.cameraGeneration,map.sessionGeneration==c.gatewayGeneration,
                  model.modelID==c.modelID,model.referenceID==c.referenceID,model.geometryID==c.geometryID,model.selectedMappingID==c.mappingID,
                  map.modelID==c.modelID,map.geometryID==c.geometryID,map.mappingID==c.mappingID,
                  let scope=map.visualCalibrationScope,scope.bodyContextIsCurrent,scope.bodyMotionIdentity==c.bodyMotionIdentity,
                  scope.estimatedCameraProjectionIdentity==c.estimatedCameraProjectionIdentity,
                  now.isFinite,(0...60_000).contains(now-map.oldestCapturedAtMilliseconds),now>=map.createdAtMilliseconds,
                  baseline.count==7,physicalRightBaseline.count==7,physicalLeftBaseline.count==7,
                  Self.drift(baseline,physicalRightBaseline)<=0.002 else {
                throw ROBGhostMotionError.blocked("The experimental source-pixel view lost its current map/body/source or actual observed RIGHT q0 binding.")
            }
        }
        private static func drift(_ a:[Double],_ b:[Double])->Double {1.5*zip(a,b).reduce(0.0){$0+abs($1.0-$1.1)}}
    }
    fileprivate struct Cell:Codable,Hashable {let x:Int,y:Int,z:Int;var vector:SIMD3<Int>{SIMD3(x,y,z)};var id:String{"\(x),\(y),\(z)"}}
    fileprivate struct Bounds:Codable {var low:SIMD3<Double>,high:SIMD3<Double>}
    fileprivate struct EmptyScope:Codable {}
    fileprivate struct Observation:Codable {
        let sequence:UInt64,capturedAtMilliseconds:Double,recordedPanDegrees:Double?,recordedUpperTarget:Int?,recordedLowerTarget:Int?
        let registrationID:String?,registrationUncertaintyMeters:Double?,fixedHeadScope:EmptyScope?
        let cameraToRobotColumnMajor:[Double],measuredSelfMaskApplied:Bool,estimatedDepthHypothesisID:String?,estimatedCameraProjectionIdentity:String?
    }
    fileprivate struct MapDocument:Decodable {
        let sceneID:UUID,modelID:String,geometryID:String,mappingID:String,sessionGeneration:UInt64,cameraGeneration:UUID
        let createdAtMilliseconds:Double,oldestCapturedAtMilliseconds:Double,lastCapturedAtMilliseconds:Double,voxelSizeMeters:Double
        let observedFrameCount:Int,isTruncated:Bool,capturedRegistrationID:String?,registrationUncertaintyMeters:Double?,bodyMotionIdentity:String
        let occupied:Set<Cell>,free:Set<Cell>,occupiedSamples:[Cell:Bounds],occupiedSourceSamples:[Cell:Bounds]
        let observations:[Observation],estimatedCameraProjectionIdentity:String?,fingerprint:String
    }
    fileprivate struct Scene:Decodable {let archiveID:UUID,workspaceSceneID:UUID,bodyMotionIdentity:String,gatewayGeneration:UInt64,modelID:String,referenceID:String,geometryID:String,mappingID:String}
    fileprivate struct Record:Decodable {let frameID:UUID,sequence:UInt64,capturedAtHostMilliseconds:Double,cameraGeneration:UUID,relativeDirectory:String,rgbSHA256:String,depthSHA256:String,metadataSHA256:String,byteCount:Int}
    fileprivate struct SourceObservation:Decodable {let sequence:UInt64,capturedAtHostMilliseconds:Double,cameraGeneration:UUID}
    fileprivate struct SourceMapBinding:Decodable {let workspaceSceneID:UUID,mapFingerprint:String,relativePath:String,serializedSHA256:String,observations:[SourceObservation]}
    fileprivate struct Manifest:Decodable {let schemaVersion:Int,kind:String,scene:Scene,status:String,frames:[Record],sourceMapBinding:SourceMapBinding?,classificationAuthority:Bool,motionAuthority:Bool}
    fileprivate struct Available<T:Decodable>:Decodable {let value:T?,unavailableReason:String?}
    fileprivate struct Neck:Decodable {let appliedPanTarget:Int,appliedLowerTarget:Int,appliedUpperTarget:Int,observedAtHostMilliseconds:Double,stationary:Bool,source:String}
    fileprivate struct Arm:Decodable {
        let physicalSide:String,gatewayArm:String,telemetrySequence:UInt64,receivedAtHostMilliseconds:Double,effectiveSampleAgeMilliseconds:Double,effectiveGripperAgeMilliseconds:Double
        let positionsRadians:[Double],reportedModes:[Int],gatewayModes:[Int],modelID:String,geometryID:String,mappingID:String
    }
    fileprivate struct Metadata:Decodable {
        let schemaVersion:Int,frameID:UUID,sequence:UInt64,capturedAtHostMilliseconds:Double,cameraGeneration:UUID,width:Int,height:Int
        let rgbPath:String,rgbSHA256:String,depthPath:String,depthSHA256:String,intrinsics:[Double],sourceContractsJSON:Data,runtimeCalibrationJSON:Data
        let actualAppliedNeck:Available<Neck>,physicalLeftFeedback:Available<Arm>,physicalRightFeedback:Available<Arm>
        let cameraToRobotColumnMajor:[Double],projectionMethod:String,projectionScopeJSON:Data,returnSamplingContractJSON:Data
        let classificationAuthority:Bool,motionAuthority:Bool
    }
    fileprivate struct Runtime:Decodable {
        let schemaVersion:Int,actualDeviceMXID:String,cameraRole:String,sdkVersion:String,factoryEEPROMSHA256:String,effectiveRuntimeCalibrationSHA256:String,stereoPolicySHA256:String,candidateSHA256:String?,profileSHA256:String?
        var identity:String {ROBGhostRobotModel.hash(Data(["runtime-camera-calibration-v1",actualDeviceMXID,cameraRole,sdkVersion,factoryEEPROMSHA256,effectiveRuntimeCalibrationSHA256,stereoPolicySHA256,candidateSHA256 ?? "-",profileSHA256 ?? "-"].joined(separator:"\n").utf8))}
    }
    fileprivate struct ParsedFrame {
        let raw:ReplayFrame,metadata:Metadata,runtime:Runtime,serviceSHA:String
        let depth:[UInt16],rgb:[UInt8],gray:[Double],matrix:simd_double4x4
    }
    fileprivate struct Archive {
        let binding:SourceBinding,manifest:Manifest,map:MapDocument,frames:[ParsedFrame],groups:[ROBWorkspaceOccupiedSourceGroup]
        let contributors:[Cell:[Contributor]],acceptedCount:Int
    }
    fileprivate struct Anchor {let x:Int,y:Int,values:[Double],mean:Double,norm:Double}
    fileprivate struct Component {let pixels:Set<Int>,anchors:[Anchor]}
    private static func reject(_ text:String)->ROBGhostMotionError { .blocked("Experimental source-pixel perception rejected: "+text) }
    private static func hash(_ data:Data)->String {ROBGhostRobotModel.hash(data)}
    private static func isHash(_ value:String)->Bool {value.count==64 && value.allSatisfy(\.isHexDigit)}
    private static func encode<T:Encodable>(_ x:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(x)}
    private static func object(_ d:Data)throws->[String:Any] {guard d.count<=64_000_000,let x=try JSONSerialization.jsonObject(with:d)as?[String:Any] else {throw reject("bounded JSON object required")};return x}
    private static func same(_ a:Bounds,_ b:Bounds)->Bool {(0..<3).allSatisfy{abs(a.low[$0]-b.low[$0])<=1e-12 && abs(a.high[$0]-b.high[$0])<=1e-12}}
    private static func ordered(_ cells:Set<Cell>)->[[Int]] {cells.map{[$0.x,$0.y,$0.z]}.sorted{a,b in a[0] != b[0] ? a[0]<b[0]:a[1] != b[1] ? a[1]<b[1]:a[2]<b[2]}}
    private static func rows(_ bounds:[Cell:Bounds])->[[Double]] {bounds.map{c,b in [Double(c.x),Double(c.y),Double(c.z),b.low.x,b.low.y,b.low.z,b.high.x,b.high.y,b.high.z]}.sorted{a,b in a[0] != b[0] ? a[0]<b[0]:a[1] != b[1] ? a[1]<b[1]:a[2]<b[2]}}
    private static func canonicalFingerprint(_ m:MapDocument)throws->String {
        var identity:[String:Any]=["scene":m.sceneID.uuidString,"model":m.modelID,"geometry":m.geometryID,"mapping":m.mappingID,
            "session":NSNumber(value:m.sessionGeneration),"camera":m.cameraGeneration.uuidString,"bodyMotionIdentity":m.bodyMotionIdentity,
            "created":m.createdAtMilliseconds,"oldest":m.oldestCapturedAtMilliseconds,"latest":m.lastCapturedAtMilliseconds,
            "voxel_size":m.voxelSizeMeters,"frames":m.observedFrameCount,"truncated":m.isTruncated,"registration":m.capturedRegistrationID ?? "unverified",
            "registrationUncertaintyMeters":m.registrationUncertaintyMeters as Any? ?? NSNull(),"occupied":ordered(m.occupied),"free":ordered(m.free.subtracting(m.occupied)),
            "occupiedSampleBounds":rows(m.occupiedSamples),"occupiedSourceSampleBounds":rows(m.occupiedSourceSamples)]
        if let p=m.estimatedCameraProjectionIdentity {identity["estimatedCameraProjectionIdentity"]=p}
        var bytes=try JSONSerialization.data(withJSONObject:identity,options:[.sortedKeys]);bytes.append(try encode(m.observations));return hash(bytes)
    }
    private static func archive(manifestJSON:Data,sourceMapJSON:Data,frames:[ReplayFrame],model:ROBGhostRobotModel)throws->Archive {
        let d=JSONDecoder(),manifest=try d.decode(Manifest.self,from:manifestJSON),m=try d.decode(MapDocument.self,from:sourceMapJSON)
        guard manifestJSON.count<=2_000_000,sourceMapJSON.count<=64_000_000,manifest.schemaVersion==1,manifest.kind=="raw_workspace_pixel_provenance_only",
              manifest.status=="complete",!manifest.classificationAuthority,!manifest.motionAuthority,(1...14).contains(frames.count),frames.count==manifest.frames.count,
              let binding=manifest.sourceMapBinding,binding.relativePath=="source-map.json",binding.serializedSHA256==hash(sourceMapJSON),binding.mapFingerprint==m.fingerprint,
              binding.workspaceSceneID==m.sceneID,manifest.scene.workspaceSceneID==m.sceneID,manifest.scene.gatewayGeneration==m.sessionGeneration,
              manifest.scene.bodyMotionIdentity==m.bodyMotionIdentity,manifest.scene.modelID==model.modelID,manifest.scene.referenceID==model.referenceID,
              manifest.scene.geometryID==model.geometryID,manifest.scene.mappingID==model.selectedMappingID,
              m.modelID==model.modelID,m.geometryID==model.geometryID,m.mappingID==model.selectedMappingID,m.voxelSizeMeters==0.025,!m.isTruncated,
              m.capturedRegistrationID==nil,m.registrationUncertaintyMeters==nil,m.occupied.count<=400_000,m.free.count<=500_000,
              !m.occupiedSourceSamples.isEmpty,m.occupiedSourceSamples.count<=400_000,m.observedFrameCount==frames.count,m.observations.count==frames.count,
              binding.observations.count==frames.count,Set(manifest.frames.map(\.frameID)).count==frames.count,
              let projection=m.estimatedCameraProjectionIdentity,isHash(projection),try canonicalFingerprint(m)==m.fingerprint else {
            throw reject("archive/map/model/fingerprint must be complete original unregistered normalized-depth evidence")
        }
        var parsed:[ParsedFrame]=[],source:[Cell:Bounds]=[:],contributors:[Cell:[Contributor]]=[:],accepted=0,totalBytes=0
        for index in frames.indices {
            let raw=frames[index],r=manifest.frames[index],meta=try d.decode(Metadata.self,from:raw.metadataJSON),o=m.observations[index],b=binding.observations[index]
            totalBytes+=raw.metadataJSON.count+raw.rgb888.count+raw.depthU16LittleEndian.count
            guard totalBytes<=64_000_000,hash(raw.metadataJSON)==r.metadataSHA256,hash(raw.rgb888)==r.rgbSHA256,hash(raw.depthU16LittleEndian)==r.depthSHA256,
                  meta.schemaVersion==1,!meta.classificationAuthority,!meta.motionAuthority,meta.frameID==r.frameID,meta.sequence==r.sequence,
                  meta.capturedAtHostMilliseconds==r.capturedAtHostMilliseconds,meta.cameraGeneration==r.cameraGeneration,meta.cameraGeneration==m.cameraGeneration,
                  meta.sequence==o.sequence,meta.capturedAtHostMilliseconds==o.capturedAtMilliseconds,meta.sequence==b.sequence,
                  meta.capturedAtHostMilliseconds==b.capturedAtHostMilliseconds,meta.cameraGeneration==b.cameraGeneration,
                  meta.rgbSHA256==r.rgbSHA256,meta.depthSHA256==r.depthSHA256,meta.rgbPath=="rgb888.raw",meta.depthPath=="depth-u16le.raw",
                  (16...1920).contains(meta.width),(16...1200).contains(meta.height),raw.rgb888.count==meta.width*meta.height*3,raw.depthU16LittleEndian.count==meta.width*meta.height*2,
                  meta.intrinsics.count==4,meta.intrinsics.allSatisfy(\.isFinite),meta.intrinsics[0]>0,meta.intrinsics[1]>0,
                  meta.cameraToRobotColumnMajor==o.cameraToRobotColumnMajor,meta.cameraToRobotColumnMajor.count==16,
                  meta.cameraToRobotColumnMajor.allSatisfy(\.isFinite),o.registrationID==nil,o.fixedHeadScope==nil,!o.measuredSelfMaskApplied,
                  o.estimatedDepthHypothesisID==nil,o.estimatedCameraProjectionIdentity==projection,
                  index==0 || (meta.sequence>parsed[index-1].metadata.sequence && meta.capturedAtHostMilliseconds>parsed[index-1].metadata.capturedAtHostMilliseconds) else {
                throw reject("a raw frame/hash/order/source differs from its original map observation")
            }
            let contract=try object(meta.returnSamplingContractJSON),scope=try object(meta.projectionScopeJSON),contracts=try object(meta.sourceContractsJSON)
            let step=max(2,Int(ceil(sqrt(Double(meta.width*meta.height)/12_000))))
            guard contract["mapper"]as?String=="ROBWorkspaceDepthMap.append_original_normalized_depth_v1",contract["firstPixel"]as?[Int]==[1,1],
                  contract["exclusivePixelUpperBound"]as?[Int]==[meta.width-1,meta.height-1],contract["stride"]as?Int==step,
                  contract["acceptedDepthMillimeters"]as?[Int]==[100,3000],contract["depthUnits"]as?String=="u16le_mm",contract["sourceVoxelSizeMeters"]as?Double==0.025,
                  contract["occupiedDilationOffsets"]as?[Int]==[-1,0,1],contract["workspaceLowMeters"]as?[Double]==[-2,-2,-0.3],contract["workspaceHighMeters"]as?[Double]==[2,2,2.4],
                  contract["measuredSelfMaskApplied"]as?Bool==false,(contract["measuredSelfBounds"]as?[[String:Any]])?.isEmpty==true,
                  contract["registeredValidRobotVolume"]is NSNull,scope["registrationID"]is NSNull,scope["estimatedCameraProjectionIdentity"]as?String==projection,
                  contracts["rgbOutputUndistorted"]as?Bool==true,contracts["depthRGBGeometryCorrespondence"]as?String=="matched",
                  let service=contracts["cameraServiceSourceSHA256"]as?String,isHash(service) else {throw reject("unsupported or changed original sampling/projection/source contract")}
            let runtime=try d.decode(Runtime.self,from:meta.runtimeCalibrationJSON)
            guard runtime.schemaVersion==1,runtime.cameraRole=="face",!runtime.actualDeviceMXID.isEmpty,!runtime.sdkVersion.isEmpty,
                  [runtime.factoryEEPROMSHA256,runtime.effectiveRuntimeCalibrationSHA256,runtime.stereoPolicySHA256].allSatisfy(isHash),
                  contracts["runtimeCalibrationIdentity"]as?String==runtime.identity else {throw reject("actual device/runtime source identity is missing")}
            let bytes=[UInt8](raw.depthU16LittleEndian),depth=stride(from:0,to:bytes.count,by:2).map{UInt16(bytes[$0]) | UInt16(bytes[$0+1])<<8}
            let rgb=[UInt8](raw.rgb888);var gray:[Double]=[];gray.reserveCapacity(meta.width*meta.height)
            for i in stride(from:0,to:rgb.count,by:3) {gray.append(Double(rgb[i])*0.299+Double(rgb[i+1])*0.587+Double(rgb[i+2])*0.114)}
            let c=meta.cameraToRobotColumnMajor,T=simd_double4x4(columns:(SIMD4(c[0],c[1],c[2],c[3]),SIMD4(c[4],c[5],c[6],c[7]),SIMD4(c[8],c[9],c[10],c[11]),SIMD4(c[12],c[13],c[14],c[15])))
            let rotation=simd_double3x3(columns:(SIMD3(T[0].x,T[0].y,T[0].z),SIMD3(T[1].x,T[1].y,T[1].z),SIMD3(T[2].x,T[2].y,T[2].z)))
            guard abs(simd_determinant(rotation)-1)<0.001,(0..<3).allSatisfy({abs(simd_length(rotation[$0])-1)<0.001}),
                  abs(simd_dot(rotation[0],rotation[1]))+abs(simd_dot(rotation[1],rotation[2]))+abs(simd_dot(rotation[0],rotation[2]))<0.001,
                  abs(T[0].w)+abs(T[1].w)+abs(T[2].w)<0.001,abs(T[3].w-1)<0.001 else {throw reject("nonrigid original camera transform")}
            let origin=SIMD3(T[3].x,T[3].y,T[3].z),k=meta.intrinsics
            // Occupied endpoints are accepted BEFORE the mapper's four-neighbor
            // free-ray check. Missing neighbors never discard an obstacle here.
            for y in stride(from:1,to:meta.height-1,by:step) {for x in stride(from:1,to:meta.width-1,by:step) {
                let mm=depth[y*meta.width+x];guard (100...3000).contains(Int(mm)) else{continue}
                let z=Double(mm)/1000,p=T*SIMD4((Double(x)-k[2])*z/k[0],(Double(y)-k[3])*z/k[1],z,1),point=SIMD3(p.x,p.y,p.z)
                guard (-2...2).contains(point.x),(-2...2).contains(point.y),(-0.3...2.4).contains(point.z),simd_length(point-origin)>0.1 else{continue}
                let cell=Cell(x:Int(floor(point.x/0.025)),y:Int(floor(point.y/0.025)),z:Int(floor(point.z/0.025)))
                if var bounds=source[cell] {bounds.low=simd_min(bounds.low,point);bounds.high=simd_max(bounds.high,point);source[cell]=bounds}
                else {source[cell]=Bounds(low:point,high:point)}
                contributors[cell,default:[]].append(.init(frameID:meta.frameID,x:x,y:y,depthMillimeters:Int(mm)));accepted+=1
            }}
            parsed.append(.init(raw:raw,metadata:meta,runtime:runtime,serviceSHA:service,depth:depth,rgb:rgb,gray:gray,matrix:T))
        }
        guard parsed.first?.metadata.capturedAtHostMilliseconds==m.oldestCapturedAtMilliseconds,
              parsed.last?.metadata.capturedAtHostMilliseconds==m.lastCapturedAtMilliseconds,
              source.count==m.occupiedSourceSamples.count else {
            // Keep the comparison explicit below; every original group matters.
            throw reject("raw endpoint replay omitted or changed an original group")
        }
        for (cell,bounds) in source {guard let original=m.occupiedSourceSamples[cell],same(bounds,original) else{throw reject("raw endpoint bounds differ from original group")}}
        var unions:[Cell:Bounds]=[:]
        for (cell,b) in source {for x in -1...1 {for y in -1...1 {for z in -1...1 {
            let c=Cell(x:cell.x+x,y:cell.y+y,z:cell.z+z)
            if var old=unions[c] {old.low=simd_min(old.low,b.low);old.high=simd_max(old.high,b.high);unions[c]=old}else{unions[c]=b}
        }}}}
        guard Set(unions.keys)==m.occupied,unions.count==m.occupiedSamples.count else {throw reject("original27-cell occupied union is incomplete")}
        for (cell,b) in unions {guard let old=m.occupiedSamples[cell],same(b,old) else{throw reject("original27-cell occupied union bounds changed")}}
        let groups=m.occupiedSourceSamples.map{c,b in ROBWorkspaceOccupiedSourceGroup(sourceVoxel:[c.x,c.y,c.z],bounds:.init(lowMeters:[b.low.x,b.low.y,b.low.z],highMeters:[b.high.x,b.high.y,b.high.z]))}.sorted{$0.id<$1.id}
        return Archive(binding:.init(manifestSHA256:hash(manifestJSON),sourceMapSHA256:hash(sourceMapJSON),mapFingerprint:m.fingerprint,
            archiveID:manifest.scene.archiveID,sceneID:m.sceneID,cameraGeneration:m.cameraGeneration,bodyMotionIdentity:m.bodyMotionIdentity,gatewayGeneration:m.sessionGeneration,
            modelID:m.modelID,referenceID:model.referenceID,geometryID:m.geometryID,mappingID:m.mappingID,estimatedCameraProjectionIdentity:projection),manifest:manifest,map:m,frames:parsed,groups:groups,contributors:contributors,acceptedCount:accepted)
    }
}

extension ROBWorkspaceSourcePixelSelf {
    private static func inside(_ x:Double,_ y:Double,_ polygon:[[Int]])->Bool {
        var result=false,j=polygon.count-1
        for i in polygon.indices {let a=polygon[i],b=polygon[j]
            if (Double(a[1])>y) != (Double(b[1])>y),x < Double(b[0]-a[0])*(y-Double(a[1]))/Double(b[1]-a[1])+Double(a[0]) {result.toggle()};j=i
        };return result
    }
    private static func polygon(_ p:[[Int]],width:Int,height:Int)throws {
        guard (3...64).contains(p.count),p.allSatisfy({$0.count==2 && (0...width).contains($0[0]) && (0...height).contains($0[1])}),
              Set(p.map{$0.map(String.init).joined(separator:",")}).count==p.count else {throw reject("invalid bounded pixel polygon")}
        var area=0
        for i in p.indices {let a=p[i],b=p[(i+1)%p.count];area+=a[0]*b[1]-b[0]*a[1]}
        guard abs(area)>=16 else {throw reject("degenerate pixel polygon")}
        func orient(_ a:[Int],_ b:[Int],_ c:[Int])->Int {(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])}
        for i in p.indices {for j in p.indices where j>i+1 && !(i==0 && j==p.count-1) {
            let a=p[i],b=p[(i+1)%p.count],c=p[j],d=p[(j+1)%p.count]
            if orient(a,b,c)*orient(a,b,d)<=0 && orient(c,d,a)*orient(c,d,b)<=0 {throw reject("self-intersecting pixel polygon")}
        }}
    }
    private static func components(_ review:FrameReview,frame:ParsedFrame)throws->[Component] {
        let w=frame.metadata.width,h=frame.metadata.height
        guard review.robotPolygons.count<=64,review.protectedPolygons.count<=64 else {throw reject("pixel polygon budget exceeded")}
        for p in review.robotPolygons {try polygon(p,width:w,height:h)}
        for p in review.protectedPolygons {guard ["table","person","hand","uncertain"].contains(p.label) else{throw reject("unknown protected pixel class")};try polygon(p.points,width:w,height:h)}
        var result:[Component]=[]
        for p in review.robotPolygons {
            let loX=p.map{$0[0]}.min()!,hiX=min(w-1,p.map{$0[0]}.max()!),loY=p.map{$0[1]}.min()!,hiY=min(h-1,p.map{$0[1]}.max()!)
            guard (hiX-loX+1)*(hiY-loY+1)<=250_000 else {throw reject("an experimental robot polygon exceeds the narrow image-area budget")}
            guard max(2,loX)<=min(w-3,hiX),max(2,loY)<=min(h-3,hiY) else {result.append(.init(pixels:[],anchors:[]));continue}
            var pixels=Set<Int>()
            for y in max(2,loY)...min(h-3,hiY) {for x in max(2,loX)...min(w-3,hiX) {
                let allInside=[-2,0,2].allSatisfy{dy in [-2,0,2].allSatisfy{dx in inside(Double(x+dx)+0.5,Double(y+dy)+0.5,p)}}
                let protected=review.protectedPolygons.contains{keep in [-2,0,2].contains{dy in [-2,0,2].contains{dx in inside(Double(x+dx)+0.5,Double(y+dy)+0.5,keep.points)}}}
                if allInside && !protected {pixels.insert(y*w+x)}
            }}
            var anchors:[Anchor]=[]
            let spacing=max(4,min(hiX-loX+1,hiY-loY+1)/4)
            for y in stride(from:max(4,loY),through:min(h-8,hiY),by:spacing) {for x in stride(from:max(4,loX),through:min(w-8,hiX),by:spacing) {
                guard (0..<8).allSatisfy({dy in (0..<8).allSatisfy{dx in pixels.contains((y+dy)*w+x+dx)}}) else{continue}
                var values:[Double]=[];for dy in 0..<8 {for dx in 0..<8 {values.append(frame.gray[(y+dy)*w+x+dx])}}
                let mean=values.reduce(0,+)/64,norm=sqrt(values.reduce(0){$0+pow($1-mean,2)})
                if norm/8>=10 {anchors.append(.init(x:x,y:y,values:values,mean:mean,norm:norm))}
            }}
            anchors.sort{$0.norm>$1.norm};anchors=Array(anchors.prefix(12))
            result.append(.init(pixels:pixels,anchors:anchors))
        }
        return result
    }
    private static func held(_ arm:Arm?,side:String,model:ROBGhostRobotModel)->[Double]? {
        guard let arm,arm.physicalSide==side,arm.modelID==model.modelID,arm.geometryID==model.geometryID,
              arm.telemetrySequence>0,arm.positionsRadians.count==7,arm.positionsRadians.allSatisfy(\.isFinite),
              arm.effectiveSampleAgeMilliseconds.isFinite,(0...700).contains(arm.effectiveSampleAgeMilliseconds),
              arm.effectiveGripperAgeMilliseconds.isFinite,(0...700).contains(arm.effectiveGripperAgeMilliseconds) else{return nil}
        return arm.positionsRadians
    }
    private static func samePose(_ a:[Double],_ b:[Double])->Bool {a.count==7 && b.count==7 && 1.5*zip(a,b).reduce(0.0){$0+abs($1.0-$1.1)}<=0.002}
    private static func compatible(_ ref:ParsedFrame,_ current:ParsedFrame,model:ROBGhostRobotModel)->Bool {
        let a=ref.metadata,b=current.metadata
        guard a.width==b.width,a.height==b.height,a.intrinsics==b.intrinsics,ref.runtime.identity==current.runtime.identity,
              ref.runtime.actualDeviceMXID==current.runtime.actualDeviceMXID,ref.serviceSHA==current.serviceSHA,a.sourceContractsJSON==b.sourceContractsJSON,
              let n=a.actualAppliedNeck.value,let m=b.actualAppliedNeck.value,n.stationary,m.stationary,
              n.appliedPanTarget==m.appliedPanTarget,n.appliedLowerTarget==m.appliedLowerTarget,n.appliedUpperTarget==m.appliedUpperTarget,
              let al=held(a.physicalLeftFeedback.value,side:"left",model:model),let ar=held(a.physicalRightFeedback.value,side:"right",model:model),
              let bl=held(b.physicalLeftFeedback.value,side:"left",model:model),let br=held(b.physicalRightFeedback.value,side:"right",model:model),
              a.physicalLeftFeedback.value?.mappingID==b.physicalLeftFeedback.value?.mappingID,
              a.physicalRightFeedback.value?.mappingID==b.physicalRightFeedback.value?.mappingID,samePose(al,bl),samePose(ar,br) else{return false}
        return true
    }
    private static func matches(_ component:Component,reference:ParsedFrame,current:ParsedFrame)->Bool {
        guard component.anchors.count>=3 else{return false}
        let spread=component.anchors.map{a in component.anchors.map{b in hypot(Double(a.x-b.x),Double(a.y-b.y))}.max() ?? 0}.max() ?? 0
        guard spread>=8 else{return false}
        let w=current.metadata.width
        for a in component.anchors {
            var values:[Double]=[];for dy in 0..<8 {for dx in 0..<8 {values.append(current.gray[(a.y+dy)*w+a.x+dx])}}
            let mean=values.reduce(0,+)/64,variance=values.reduce(0){$0+pow($1-mean,2)},norm=sqrt(variance)
            guard norm/8>=10,abs(mean-a.mean)<=20 else{return false}
            let dot=zip(a.values,values).reduce(0.0){$0+($1.0-a.mean)*($1.1-mean)}
            let i=(a.y+4)*w+a.x+4,old=Int(reference.depth[i]),now=Int(current.depth[i])
            guard dot/(a.norm*norm)>=0.95,(100...3000).contains(old),(100...3000).contains(now),abs(old-now)<=10 else{return false}
        }
        return true
    }
    private static func pixelAgrees(_ i:Int,reference:ParsedFrame,current:ParsedFrame)->Bool {
        let w=current.metadata.width,x=i%w,y=i/w,old=Int(reference.depth[i]),now=Int(current.depth[i])
        guard x>=1,y>=1,x<w-1,y<current.metadata.height-1,(100...3000).contains(old),(100...3000).contains(now),abs(old-now)<=10,
              (0..<3).allSatisfy({abs(Int(reference.rgb[i*3+$0])-Int(current.rgb[i*3+$0]))<=20}) else{return false}
        for j in [i-1,i+1,i-w,i+w] {
            let a=Int(reference.depth[j]),b=Int(current.depth[j])
            guard (100...3000).contains(a),(100...3000).contains(b),abs(a-old)<=30,abs(b-now)<=30,abs(a-b)<=10 else{return false}
        }
        return true
    }
    static func loadTemplate(reviewJSON:Data,manifestJSON:Data,sourceMapJSON:Data,frames:[ReplayFrame],model:ROBGhostRobotModel)throws->Template {
#if DEBUG
        guard reviewJSON.count<=2_000_000 else{throw reject("review JSON exceeds its bounded perception record")}
        let doc=try JSONDecoder().decode(ReviewDocument.self,from:reviewJSON),a=try archive(manifestJSON:manifestJSON,sourceMapJSON:sourceMapJSON,frames:frames,model:model)
        let expected:Set<String>=["schemaVersion","kind","classificationBasis","reviewID","reviewedAtMilliseconds","archiveDirectory","archiveManifestSHA256","sourceMapSHA256","mapFingerprint","frames"]
        guard Set(try object(reviewJSON).keys)==expected,doc.schemaVersion==1,doc.kind=="experimental_robot_source_pixel_template",doc.classificationBasis=="llm_visual_review_experimental",
              doc.archiveDirectory.hasPrefix("/"),doc.archiveDirectory.utf8.count<=4096,doc.reviewedAtMilliseconds.isFinite,doc.reviewedAtMilliseconds>=a.map.lastCapturedAtMilliseconds,
              doc.archiveManifestSHA256==a.binding.manifestSHA256,doc.sourceMapSHA256==a.binding.sourceMapSHA256,doc.mapFingerprint==a.binding.mapFingerprint,
              doc.frames.count==a.frames.count else{throw reject("historical review must name its exact immutable raw sources and experimental LLM basis")}
        var allComponents:[[Component]]=[]
        for i in doc.frames.indices {
            let r=doc.frames[i],f=a.frames[i],m=f.metadata,record=a.manifest.frames[i]
            guard r.frameID==m.frameID,r.sequence==m.sequence,r.capturedAtHostMilliseconds==m.capturedAtHostMilliseconds,r.cameraGeneration==m.cameraGeneration,
                  r.width==m.width,r.height==m.height,r.metadataSHA256==record.metadataSHA256,r.rgbSHA256==record.rgbSHA256,r.depthSHA256==record.depthSHA256 else{throw reject("historical review relabelled a source frame")}
            allComponents.append(try components(r,frame:f))
        }
        return Template(a,doc,hash(reviewJSON),allComponents)
#else
        throw reject("source-pixel commissioning is DEBUG only")
#endif
    }
    static func classify(template:Template,currentManifestJSON:Data,currentSourceMapJSON:Data,currentFrames:[ReplayFrame],map:any ROBWorkspaceCollisionMap,
        model:ROBGhostRobotModel,nowMilliseconds:Double)throws->View {
#if DEBUG
        let current=try archive(manifestJSON:currentManifestJSON,sourceMapJSON:currentSourceMapJSON,frames:currentFrames,model:model)
        let b=current.binding
        guard nowMilliseconds.isFinite,(0...60_000).contains(nowMilliseconds-map.oldestCapturedAtMilliseconds),nowMilliseconds>=map.createdAtMilliseconds,
              map.fingerprint==b.mapFingerprint,map.sceneID==b.sceneID,map.cameraGeneration==b.cameraGeneration,map.sessionGeneration==b.gatewayGeneration,
              map.modelID==b.modelID,map.geometryID==b.geometryID,map.mappingID==b.mappingID,
              let scope=map.visualCalibrationScope,scope.bodyContextIsCurrent,scope.bodyMotionIdentity==b.bodyMotionIdentity,
              scope.estimatedCameraProjectionIdentity==b.estimatedCameraProjectionIdentity,
              map.originalOccupiedSourceGroups==current.groups,
              let first=current.frames.first,let left=held(first.metadata.physicalLeftFeedback.value,side:"left",model:model),
              let right=held(first.metadata.physicalRightFeedback.value,side:"right",model:model) else {throw reject("fresh native map/source/both-arm baseline does not match the replayed current archive")}
        var classified:[UUID:Set<Int>]=[:],frameAudits:[FrameMatch]=[]
        for f in current.frames {
            guard let l=held(f.metadata.physicalLeftFeedback.value,side:"left",model:model),let r=held(f.metadata.physicalRightFeedback.value,side:"right",model:model),samePose(left,l),samePose(right,r) else {throw reject("both observed arm poses were not held throughout the current source frames")}
            var pixels=Set<Int>(),referenceIDs=Set<UUID>(),count=0
            for i in template.archive.frames.indices {
                let reference=template.archive.frames[i]
                guard compatible(reference,f,model:model) else{continue}
                for component in template.components[i] where matches(component,reference:reference,current:f) {
                    count+=1;referenceIDs.insert(reference.metadata.frameID)
                    for p in component.pixels where pixelAgrees(p,reference:reference,current:f) {pixels.insert(p)}
                }
            }
            classified[f.metadata.frameID]=pixels
            let record=current.manifest.frames.first{$0.frameID==f.metadata.frameID}!
            let accepted=current.contributors.values.flatMap{$0}.filter{$0.frameID==f.metadata.frameID && pixels.contains($0.y*f.metadata.width+$0.x)}.count
            frameAudits.append(.init(currentFrameID:f.metadata.frameID,sequence:f.metadata.sequence,capturedAtHostMilliseconds:f.metadata.capturedAtHostMilliseconds,cameraGeneration:f.metadata.cameraGeneration,
                currentMetadataSHA256:record.metadataSHA256,currentRGBSHA256:record.rgbSHA256,currentDepthSHA256:record.depthSHA256,
                referenceFrameIDs:referenceIDs.sorted{$0.uuidString<$1.uuidString},matchedComponentCount:count,classifiedAcceptedReturnCount:accepted))
        }
        let widths=Dictionary(uniqueKeysWithValues:current.frames.map{($0.metadata.frameID,$0.metadata.width)})
        var excluded:[GroupAudit]=[],retained:[ROBWorkspaceOccupiedSourceGroup]=[]
        for group in current.groups {
            let cell=Cell(x:group.sourceVoxel[0],y:group.sourceVoxel[1],z:group.sourceVoxel[2]),points=current.contributors[cell] ?? []
            if !points.isEmpty,points.allSatisfy({classified[$0.frameID]?.contains($0.y*widths[$0.frameID]!+$0.x)==true}) {
                excluded.append(.init(sourceGroupID:group.id,sourceVoxel:group.sourceVoxel,originalBounds:group.bounds,contributors:points))
            } else {retained.append(group)}
        }
        guard !retained.isEmpty else{throw reject("the entire external scene cannot be labelled robot by this commissioning recognizer")}
        let audit=Audit(label:"llm_visual_review_experimental_fresh_pixel_match_not_registration",templateReviewSHA256:template.reviewSHA256,
            reviewID:template.document.reviewID,reviewedAtMilliseconds:template.document.reviewedAtMilliseconds,historical:template.archive.binding,current:b,
            physicalLeftBaseline:left,physicalRightBaseline:right,frames:frameAudits,completeSourceGroupCount:current.groups.count,
            completeSourceGroupsSHA256:hash(try encode(current.groups)),excludedGroups:excluded,retainedGroupCount:retained.count,acceptedReturnCount:current.acceptedCount,
            maximumRGBChannelDifference:20,maximumDepthDifferenceMillimeters:10,maskErosionPixels:2,minimumAnchorCorrelation:0.95,minimumAnchorStandardDeviation:10,
            rawMapModified:false,unknownPromotedToFree:false,measuredRegistration:false,motionAuthority:false)
        return try View(audit:audit,retained:retained)
#else
        throw reject("source-pixel commissioning is DEBUG only")
#endif
    }
}
