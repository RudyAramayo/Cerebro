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

enum ROBWorkspaceVoxelState: UInt8, Codable { case unknown, free, occupied }

/// A map is evidence from this camera/robot scene, never arm authority. Free
/// space must have been observed; absence of an obstacle is not free space.
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
    func state(at point: SIMD3<Double>) -> ROBWorkspaceVoxelState
    func state(inBoundsLow low: SIMD3<Double>, high: SIMD3<Double>) -> ROBWorkspaceVoxelState
    func containsTargetObservation(sequence: UInt64, capturedAtMilliseconds: Double) -> Bool
    func occupiedSampleBounds(at point:SIMD3<Double>) -> (low:SIMD3<Double>,high:SIMD3<Double>)?
}

extension ROBWorkspaceCollisionMap {
    var visualCalibrationScope: ROBWorkspaceVisualCalibrationMapScope? { nil }
    func containsTargetObservation(sequence:UInt64,capturedAtMilliseconds:Double) -> Bool { false }
    func occupiedSampleBounds(at point:SIMD3<Double>) -> (low:SIMD3<Double>,high:SIMD3<Double>)? { nil }
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
            authorizationContextIdentity.utf8.count <= 256 && canCount == 4 &&
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
    let gripStepIndex: Int
    let releaseStepIndex: Int?
    let stepCount: Int
    /// Explicit measured radial fit tolerance, never the much larger global
    /// registration uncertainty or a generic obstacle-clearance allowance.
    var radialFitUncertaintyMeters:Double = 0
    /// Only an explicit local visual trial may finish holding a verified lift.
    var terminalGraspHold:Bool? = nil

    var fingerprint:String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return ROBGhostRobotModel.hash((try? encoder.encode(self)) ?? Data())
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
              (1...80).contains(stepCount),firstContactStepIndex>=0,firstContactStepIndex<=gripStepIndex else { return false }
        if let releaseStepIndex {
            guard terminalGraspHold != true,gripStepIndex<releaseStepIndex,releaseStepIndex<stepCount else{return false}
        } else {
            guard terminalGraspHold == true,gripStepIndex<stepCount-1 else{return false}
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
    }
    func permits(label:String,payload:ROBWorkspaceCarriedObject?,stepIndex:Int) -> Bool {
        guard valid,stepIndex>=firstContactStepIndex,stepIndex<=(releaseStepIndex ?? stepCount-1) else { return false }
        if label==toolLink { return true }
        return label=="carried object" && stepIndex>gripStepIndex && payload?.measurementID==measurementID
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
              checked.endpointProxyClearancesMeters==endpointProxyClearancesMeters else {
            throw ROBGhostMotionError.blocked("The initial EMPTY retreat geometry proof changed.")
        }
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

    /// Distinct start-only admission for a fresh EMPTY hanging arm. Existing
    /// arm/tread proxy pairs may start below 30 mm only while every such pair
    /// improves monotonically; ordinary endpoint and map checks remain intact.
    static func reviewInitialEmptyVisualCalibrationRetreat(from start:[Double],to goal:[Double],
        map:any ROBWorkspaceCollisionMap,model:ROBGhostRobotModel,generation:UInt64,sceneID:UUID,cameraGeneration:UUID,
        nowMilliseconds:Double,trial:ROBWorkspaceVisualCalibrationTrial,measuredAtMilliseconds:Double,
        emptyTrialEligibility:Bool,emptyStateEvidenceSource:String) throws -> ROBWorkspaceInitialEmptyRetreat {
        let context=try validateVisualCalibrationTrialMap(map,model:model,generation:generation,sceneID:sceneID,
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
                guard steps.count==contact.stepCount,steps[contact.gripStepIndex].jawAction == .grip,
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
        _ = try Self.reviewUsingContext(baseline:baseline,steps:steps,map:map,model:model,context:current,
            nowMilliseconds:nowMilliseconds,payload:payload,intentionalContact:intentionalContact,
            contactStepIndex:contactStepIndex,carryingAtStart:carryingAtStart)
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
            // Sweep sampling is bounded by a conservative 1.5m lever; inflate
            // by one full sample travel as well as registration/voxel error.
            let margin = mechanicalClearanceMeters+context.spatialErrorAllowanceMeters+sweptPointTravelMeters+sqrt(3)*map.voxelSizeMeters/2
            for link in arms {
                let box = bounds[link]!, extra = margin+(link == model.toolLink ? openJawAdditionalMarginMeters : 0)
                if let reason = volume(low:box.low-SIMD3(repeating:extra),high:box.high+SIMD3(repeating:extra),label:link,payload:payload) { return reason }
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
                let low = points.reduce(points[0]) { simd_min($0,$1) }-SIMD3<Double>(repeating:margin)
                let high = points.reduce(points[0]) { simd_max($0,$1) }+SIMD3<Double>(repeating:margin)
                if let reason = volume(low:low,high:high,label:"carried object",payload:payload) { return reason }
            }
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
