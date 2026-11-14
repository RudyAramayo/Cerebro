import Foundation
import simd
import CryptoKit

/// A rejected geometric query, never a motion capability. Kept separate from
/// the proof so failed previews retain actionable evidence without admission.
struct ROBEstimatedArmCollisionRejection:LocalizedError {
    struct Evidence:Codable {
        let stage:String,physicalSide:String,link:String
        let sceneID:UUID,mapFingerprint:String,modelID:String,referenceID:String,geometryID:String,mappingID:String
        let bodyMotionIdentity:String,sessionGeneration:UInt64,cameraGeneration:UUID
        let estimatedCameraProjectionIdentity:String?
        let checkedAtMilliseconds:Double,baseline:[Double],target:[Double],positions:[Double]
        let sampleIndex:Int,sampleCount:Int?
        let voxel:[Int],voxelCenterMeters:[Double],voxelSizeMeters:Double,voxelBoundingSphereRadiusMeters:Double
        let hullDistanceMeters:Double,baselineHullDistanceMeters:Double,requiredDistanceMeters:Double
        let jawAdditionalMarginMeters:Double,estimatedInflationMeters:Double,sweptPointAllowanceMeters:Double
        let hullAABBLowMeters:[Double],hullAABBHighMeters:[Double],hullBoundingSphereCenterMeters:[Double],hullBoundingSphereRadiusMeters:Double
        let nearestHullSurfacePointMeters:[Double]?,observedReturnBoundsLowMeters:[Double]?,observedReturnBoundsHighMeters:[Double]?
    }
    let detail:String
    let evidence:Evidence
    var errorDescription:String? {detail}

    /// Saves the complete immutable map even when no proof was produced.
    /// Raw RGB-D scan frames are not currently retained; say so explicitly.
    @discardableResult func export(map:ROBWorkspaceCollisionSnapshot,to directory:URL)throws->URL {
        guard map.sceneID==evidence.sceneID,map.fingerprint==evidence.mapFingerprint else {
            throw ROBGhostMotionError.blocked("Collision rejection evidence belongs to another scene.")
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let mapData=try encoder.encode(map),mapURL=directory.appendingPathComponent("collision-map.json")
        try mapData.write(to:mapURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:mapURL.path)
        let mapSHA=SHA256.hash(data:mapData).map{String(format:"%02x",$0)}.joined()
        let report:[String:Any]=["schemaVersion":1,"kind":"estimated_arm_collision_rejection_diagnostic",
            "detail":detail,"motionAuthority":false,"sourceFramesNotRetained":true,
            "sourceFrameNote":"The map retains observation sequences, capture times, transforms and sample bounds; original RGB/depth frames and per-return source pixels were not retained.",
            "boundingSpheresUsedForAdmission":false,"rejectionIsGlobalMinimum":false,
            "distanceNote":"The existing convex-hull query and thresholds decide rejection. Bounding spheres and the nearest hull surface point are diagnostics only; an inside point retains its original zero admission distance.",
            "mapFile":"collision-map.json","mapSHA256":mapSHA,
            "evidence":try JSONSerialization.jsonObject(with:encoder.encode(evidence))]
        let reportURL=directory.appendingPathComponent("rejection.json")
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:reportURL.path)
        return reportURL
    }
}

struct ROBEstimatedArmLocalRegion: Codable, Equatable {
    let link: String
    let low: [Double]
    let high: [Double]
}

struct ROBEstimatedArmSelfProxyPair: Codable, Equatable {
    let armLink: String
    let treadLink: String
    let baselineOverlapCubicMeters: Double
    let finalOverlapCubicMeters: Double
    let baselineSeparationMeters: Double
    let finalSeparationMeters: Double
    var baselineHullSignedSeparationMeters:Double? = nil
    var finalHullSignedSeparationMeters:Double? = nil
}

struct ROBEstimatedArmOccupiedRetreatPair: Codable, Equatable {
    let link: String
    let voxel: ROBWorkspaceVoxel
    let baselineDistanceMeters: Double
    let finalDistanceMeters: Double
}

/// A deliberately separate, single EMPTY-arm commissioning experiment. The
/// map stays unregistered. Unknown space is admitted only inside the recorded
/// local region that the operator must visually clear for this one nudge.
/// Neither this estimate nor reduced CAD overlap authorizes a grasp or return.
struct ROBEstimatedArmCalibrationPlan: Codable, Equatable {
    let id: UUID
    let modelID: String
    let referenceID: String
    let geometryID: String
    let mappingID: String
    let sessionGeneration: UInt64
    let cameraGeneration: UUID
    let sceneID: UUID
    let mapFingerprint: String
    let createdAtMilliseconds: Double
    let baseline: [Double]
    let target: [Double]
    let seconds: Double
    let registrationMode: String
    let estimatedInflationMeters: Double
    let maximumVertexDisplacementMeters: Double
    let unknownVoxelCount: Int
    let checkedPoseCount: Int
    let baselineSelfProxyPairs: [ROBEstimatedArmSelfProxyPair]
    let baselineCloseOccupiedPairs: [ROBEstimatedArmOccupiedRetreatPair]
    let unknownLocalRegions: [ROBEstimatedArmLocalRegion]

    static let jointDeltaRadians: [Double] = [0.10,0.025,-0.075,0,0,0,0]
    // Two-joint outward retreat: the former J2-only vector approached a
    // retained table cell. The complete unchanged proof must admit this new
    // proposal again for the live map and measured baseline.
    static let rightJointDeltaRadians:[Double] = [-0.03,-0.03,0,0,0,0,0]
    private static func delta(model:ROBGhostRobotModel)->[Double] {model.physicalSide == "right" ? rightJointDeltaRadians : jointDeltaRadians}
    private static func travelLimit(model:ROBGhostRobotModel)->Double {model.physicalSide == "right" ? 0.03 : maximumVertexTravelMeters}
    static let durationSeconds = 4.0
    static let obstacleInflationMeters = 0.15
    static let maximumVertexTravelMeters = 0.06
    static let hangingToleranceRadians = 0.025
    static let maximumMapAgeMilliseconds = 60_000.0
    static let mode = "estimated_urdf_prior"
    var positions: [Double] { target }
    var step: ROBLeftGestureProposal.Step {
        .init(positions:target,seconds:seconds,stage:"One supervised estimated EMPTY-arm retreat")
    }
    var steps: [ROBLeftGestureProposal.Step] { [step] }
    var requiresConfirmedEmptyGripper: Bool { true }
    var operatorVisualScope: String {
        "Confirm the selected gripper is empty and the complete arm and its surrounding local working space are clear. One slow bounded retreat only; hold and observe before adjusting calibration."
    }

    static func make(from baseline: [Double], map: ROBWorkspaceCollisionSnapshot, model: ROBGhostRobotModel,
                     generation: UInt64, cameraGeneration: UUID, nowMilliseconds: Double) throws -> Self {
        try build(id:UUID(),from:baseline,map:map,model:model,generation:generation,
            cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
    }

    /// Fast identity/shape admission, with no mesh traversal or voxel loops.
    /// The runtime additionally binds fresh measured joints to this baseline.
    func validateContext(map: ROBWorkspaceCollisionSnapshot, model: ROBGhostRobotModel, generation: UInt64,
                         cameraGeneration: UUID, nowMilliseconds: Double) throws {
        try Self.checkMap(map,model:model,generation:generation,cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
        try Self.checkEndpoints(baseline,target:target,model:model)
        guard modelID == model.modelID, referenceID == model.referenceID, geometryID == model.geometryID,
              mappingID == model.selectedMappingID, sessionGeneration == generation,
              self.cameraGeneration == cameraGeneration, sceneID == map.sceneID, mapFingerprint == map.fingerprint,
              seconds == Self.durationSeconds, registrationMode == Self.mode,
              estimatedInflationMeters == Self.obstacleInflationMeters,
              createdAtMilliseconds.isFinite, (0...Self.maximumMapAgeMilliseconds).contains(nowMilliseconds-createdAtMilliseconds),
              maximumVertexDisplacementMeters.isFinite, (0...Self.travelLimit(model:model)).contains(maximumVertexDisplacementMeters),
              unknownVoxelCount >= 0, (2...128).contains(checkedPoseCount), baselineCloseOccupiedPairs.count <= 4_096,
              !unknownLocalRegions.isEmpty, unknownLocalRegions.count <= 16, baselineSelfProxyPairs.count <= 100 else {
            throw ROBGhostMotionError.blocked("The estimated calibration proof changed, expired or no longer matches this scene. Review a new single step.")
        }
    }

    func validate(map: ROBWorkspaceCollisionSnapshot, model: ROBGhostRobotModel, generation: UInt64,
                  cameraGeneration: UUID, nowMilliseconds: Double) throws {
        try validateContext(map:map,model:model,generation:generation,cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
        let expected = try Self.build(id:id,from:baseline,map:map,model:model,generation:generation,
            cameraGeneration:cameraGeneration,nowMilliseconds:createdAtMilliseconds)
        guard self == expected else {
            throw ROBGhostMotionError.blocked("The estimated calibration path or its recorded collision checks changed. Rebuild the one-step preview.")
        }
    }

    private static func checkMap(_ map: ROBWorkspaceCollisionSnapshot, model: ROBGhostRobotModel, generation: UInt64,
                                 cameraGeneration: UUID, nowMilliseconds: Double) throws {
        guard map.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity else {
            throw ROBGhostMotionError.blocked("The robot body moved after the estimated depth scene was captured. Capture a fresh scene before the outward retreat.")
        }
        guard generation > 0, map.sessionGeneration == generation, map.cameraGeneration == cameraGeneration,
              map.modelID == model.modelID, map.geometryID == model.geometryID, map.mappingID == model.selectedMappingID,
              map.fingerprint.count == 64 else {
            throw ROBGhostMotionError.blocked("The estimated workspace map belongs to another robot, camera or arm connection.")
        }
        let times = [nowMilliseconds,map.createdAtMilliseconds,map.oldestCapturedAtMilliseconds,map.lastCapturedAtMilliseconds]
        guard times.allSatisfy(\.isFinite), map.oldestCapturedAtMilliseconds <= map.lastCapturedAtMilliseconds,
              map.lastCapturedAtMilliseconds <= map.createdAtMilliseconds+5,
              (0...maximumMapAgeMilliseconds).contains(nowMilliseconds-map.oldestCapturedAtMilliseconds),
              (0...maximumMapAgeMilliseconds).contains(nowMilliseconds-map.lastCapturedAtMilliseconds),
              (0.01...0.04).contains(map.voxelSizeMeters), map.observedFrameCount >= 2, !map.isTruncated else {
            throw ROBGhostMotionError.blocked("The estimated depth grid is stale, incomplete or truncated. Capture a fresh scene before the nudge.")
        }
        // No registration identifier is created, and no can/TCP correction is
        // applied to occupied surfaces. Inflation is a stated estimate only.
    }

    private static func checkEndpoints(_ baseline: [Double], target: [Double], model: ROBGhostRobotModel) throws {
        guard baseline.count == 7, target.count == 7, baseline.allSatisfy({ $0.isFinite && abs($0) <= hangingToleranceRadians }),
              target.contains(where:{ abs($0) > hangingToleranceRadians+0.003 }),
              delta(model:model).allSatisfy({ abs($0) <= (model.physicalSide == "right" ? 0.05 : 0.20) }),
              target.enumerated().allSatisfy({ index,value in
                  value.isFinite && value == baseline[index]+delta(model:model)[index]
              }), zip(baseline,ROBWorkspaceCollisionPlan.jointBounds(model:model)).allSatisfy({ $1.contains($0) }),
              zip(target,ROBWorkspaceCollisionPlan.jointBounds(model:model)).allSatisfy({ $1.contains($0) }) else {
            throw ROBGhostMotionError.blocked("This experiment permits only one fixed-vector retreat from a verified near-zero EMPTY arm. The final pose cannot qualify for another retreat.")
        }
    }

    private struct Box {
        let low: SIMD3<Double>
        let high: SIMD3<Double>
        func inflated(_ amount: Double) -> Self { .init(low:low-SIMD3(repeating:amount),high:high+SIMD3(repeating:amount)) }
        func contains(_ point:SIMD3<Double>) -> Bool { (0..<3).allSatisfy { low[$0] <= point[$0] && point[$0] <= high[$0] } }
    }
    private struct Clearance {
        let overlap: Double
        let separation: Double
    }
    private struct OccupiedPair: Hashable {
        let link: String
        let voxel: ROBWorkspaceVoxel
    }
    private static func clearance(_ a:Box,_ b:Box) -> Clearance {
        let gap = simd_max(.zero,simd_max(a.low-b.high,b.low-a.high))
        let overlap = simd_max(.zero,simd_min(a.high,b.high)-simd_max(a.low,b.low))
        return .init(overlap:overlap.x*overlap.y*overlap.z,separation:simd_length(gap))
    }
    private static func notWorse(_ next:Clearance,than prior:Clearance) -> Bool {
        if prior.overlap > 0 { return next.overlap <= prior.overlap+1e-12 }
        return next.overlap <= 1e-12 && next.separation+1e-9 >= min(prior.separation,0.030)
    }

    /// Only the rigid arm mount can be omitted from incremental depth checks.
    /// A link stationary along the planned J2 path can still move under J1
    /// tracking error, so no actuated arm link qualifies for this exception.
    private static func isFixedTorsoMount(_ link:String,model:ROBGhostRobotModel) -> Bool {
        guard link == model.physicalSide + "_base_link" else { return false }
        var current = link, seen = Set<String>()
        while current != "torso_link" {
            guard seen.insert(current).inserted else { return false }
            let parents = model.joints.filter { $0.child == current }
            guard parents.count == 1, let joint = parents.first, joint.kind == "fixed" else { return false }
            current = joint.parent
        }
        return true
    }

    private static func verifiedGeometry(model: ROBGhostRobotModel) throws -> (vertices:[String:[SIMD3<Double>]],texts:[String:String]) {
        let surfacesData = try Data(contentsOf:model.directory.appendingPathComponent("surfaces.json"))
        guard ROBGhostRobotModel.hash(surfacesData) == model.geometryID,
              let document = try JSONSerialization.jsonObject(with:surfacesData) as? [String:Any],
              let entries = document["surfaces"] as? [[String:Any]] else {
            throw ROBGhostMotionError.blocked("The calibration experiment's collision geometry changed.")
        }
        var result: [String:[SIMD3<Double>]] = [:]
        var texts: [String:String] = [:]
        for entry in entries {
            guard let link = entry["link"] as? String, let path = model.hulls[link],
                  let hash = entry["hullSHA256"] as? String else { continue }
            let data = try Data(contentsOf:model.directory.appendingPathComponent(path))
            guard ROBGhostRobotModel.hash(data) == hash, let text = String(data:data,encoding:.utf8) else {
                throw ROBGhostMotionError.blocked("A collision hull changed before the calibration experiment.")
            }
            let vertices = text.split(separator:"\n").compactMap { line -> SIMD3<Double>? in
                let fields = line.split(whereSeparator:\.isWhitespace)
                guard fields.first == "v", fields.count >= 4, let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]),
                      [x,y,z].allSatisfy(\.isFinite) else { return nil }
                return SIMD3(x,y,z)
            }
            guard !vertices.isEmpty else { throw ROBGhostMotionError.blocked("The calibration experiment has an empty collision hull.") }
            result[link] = vertices
            texts[link] = text
        }
        return (result,texts)
    }

    private static func build(id:UUID,from baseline:[Double],map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,
                              generation:UInt64,cameraGeneration:UUID,nowMilliseconds:Double) throws -> Self {
        try checkMap(map,model:model,generation:generation,cameraGeneration:cameraGeneration,nowMilliseconds:nowMilliseconds)
        let jointDeltaRadians=delta(model:model), maximumVertexTravelMeters=travelLimit(model:model)
        var target = baseline
        guard target.count == 7 else { throw ROBGhostMotionError.blocked("The estimated calibration start needs all seven measured joints.") }
        for index in 0..<7 { target[index] += jointDeltaRadians[index] }
        try checkEndpoints(baseline,target:target,model:model)
        let verified = try verifiedGeometry(model:model), vertices = verified.vertices
        let arms = vertices.keys.filter { $0.hasPrefix(model.physicalSide + "_") && ($0.hasSuffix("_Link") || $0 == model.toolLink || $0 == model.physicalSide + "_base_link") }.sorted()
        let treads = vertices.keys.filter { $0.contains("track") || $0.contains("flipper") || $0.contains("sprocket") }.sorted()
        guard arms.count >= 8, !treads.isEmpty else { throw ROBGhostMotionError.blocked("The full arm and tread collision geometry are required for the nudge.") }
        func geometry(_ q:[Double]) throws -> (points:[String:[SIMD3<Double>]],boxes:[String:Box],frames:[String:simd_double4x4]) {
            let frames = model.frames(model.positions(vendorLeft:q))
            var points: [String:[SIMD3<Double>]] = [:], boxes: [String:Box] = [:]
            for link in arms+treads {
                guard let transform = frames[link], let local = vertices[link] else {
                    throw ROBGhostMotionError.blocked("A full-arm calibration transform is missing.")
                }
                let x = SIMD3(transform.columns.0.x,transform.columns.0.y,transform.columns.0.z)
                let y = SIMD3(transform.columns.1.x,transform.columns.1.y,transform.columns.1.z)
                let z = SIMD3(transform.columns.2.x,transform.columns.2.y,transform.columns.2.z)
                guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { transform[c][$0].isFinite } }),
                      abs(simd_length_squared(x)-1) < 1e-9, abs(simd_length_squared(y)-1) < 1e-9, abs(simd_length_squared(z)-1) < 1e-9,
                      abs(simd_dot(x,y)) < 1e-9, abs(simd_dot(x,z)) < 1e-9, abs(simd_dot(y,z)) < 1e-9,
                      abs(simd_dot(x,simd_cross(y,z))-1) < 1e-9,
                      abs(transform.columns.0.w) < 1e-12, abs(transform.columns.1.w) < 1e-12,
                      abs(transform.columns.2.w) < 1e-12, abs(transform.columns.3.w-1) < 1e-12 else {
                    throw ROBGhostMotionError.blocked("The estimated collision frame is not a finite rigid transform.")
                }
                let world = local.map { point -> SIMD3<Double> in
                    let p = transform*SIMD4(point,1); return SIMD3(p.x,p.y,p.z)
                }
                points[link] = world
                boxes[link] = .init(low:world.reduce(world[0]) { simd_min($0,$1) },high:world.reduce(world[0]) { simd_max($0,$1) })
            }
            return (points,boxes,frames)
        }
        let start = try geometry(baseline)
        // This mount cannot create a new collision during an arm-only nudge.
        // Keep it in vertex-travel and self/tread checks, and verify its actual
        // hull stays fixed at every pose. The map itself remains untouched.
        let fixedMounts = Set(arms.filter { isFixedTorsoMount($0,model:model) })
        let depthCheckedArms = arms.filter { !fixedMounts.contains($0) }
        var convexHulls: [String:ROBEstimatedConvexHull] = [:]
        for link in depthCheckedArms { convexHulls[link] = try .init(text:verified.texts[link]!) }
        func checkedHull(_ link:String) throws ->ROBEstimatedConvexHull {
            if let hull=convexHulls[link] {return hull}
            do {
                let hull=try ROBEstimatedConvexHull(text:verified.texts[link]!)
                convexHulls[link]=hull;return hull
            } catch {throw ROBGhostMotionError.blocked("The estimated \(link) hull is not closed/convex at the required precision; no probe admitted.")}
        }
        let voxelHalf = map.voxelSizeMeters/2
        let padding = obstacleInflationMeters+ROBWorkspaceCollisionPlan.sweptPointTravelMeters+sqrt(3)*voxelHalf
        func hullDistance(_ link:String,_ point:SIMD3<Double>,_ frames:[String:simd_double4x4]) throws -> Double {
            let local = simd_inverse(frames[link]!)*SIMD4(point,1)
            return try convexHulls[link]!.distance(to:SIMD3(local.x,local.y,local.z))
        }
        func rejection(_ detail:String,stage:String,link:String,voxel:ROBWorkspaceVoxel,distance:Double,
            baselineDistance:Double,required:Double,jaw:Double,q:[Double],sample:Int,count:Int?,
            boxes:[String:Box],frames:[String:simd_double4x4])->ROBEstimatedArmCollisionRejection {
            func values(_ p:SIMD3<Double>)->[Double]{[p.x,p.y,p.z]}
            let point=voxel.center(voxelSizeMeters:map.voxelSizeMeters),box=boxes[link]!
            let local=simd_inverse(frames[link]!)*SIMD4(point,1)
            let nearest=try? convexHulls[link]!.nearestSurfacePoint(to:SIMD3(local.x,local.y,local.z))
            let nearestWorld=nearest.map { value -> [Double] in
                let p=frames[link]!*SIMD4(value,1);return [p.x,p.y,p.z]
            }
            let bounds=map.occupiedSampleBounds(at:point)
            let evidence=ROBEstimatedArmCollisionRejection.Evidence(stage:stage,physicalSide:model.physicalSide,link:link,
                sceneID:map.sceneID,mapFingerprint:map.fingerprint,modelID:model.modelID,referenceID:model.referenceID,
                geometryID:model.geometryID,mappingID:model.selectedMappingID,bodyMotionIdentity:map.bodyMotionIdentity,
                sessionGeneration:map.sessionGeneration,cameraGeneration:map.cameraGeneration,
                estimatedCameraProjectionIdentity:map.estimatedCameraProjectionIdentity,checkedAtMilliseconds:nowMilliseconds,
                baseline:baseline,target:target,positions:q,sampleIndex:sample,sampleCount:count,
                voxel:[voxel.x,voxel.y,voxel.z],voxelCenterMeters:values(point),voxelSizeMeters:map.voxelSizeMeters,
                voxelBoundingSphereRadiusMeters:sqrt(3)*map.voxelSizeMeters/2,hullDistanceMeters:distance,
                baselineHullDistanceMeters:baselineDistance,requiredDistanceMeters:required,jawAdditionalMarginMeters:jaw,
                estimatedInflationMeters:obstacleInflationMeters,sweptPointAllowanceMeters:ROBWorkspaceCollisionPlan.sweptPointTravelMeters,
                hullAABBLowMeters:values(box.low),hullAABBHighMeters:values(box.high),
                hullBoundingSphereCenterMeters:values((box.low+box.high)/2),hullBoundingSphereRadiusMeters:simd_length(box.high-box.low)/2,
                nearestHullSurfacePointMeters:nearestWorld,observedReturnBoundsLowMeters:bounds.map{values($0.low)},
                observedReturnBoundsHighMeters:bounds.map{values($0.high)})
            return .init(detail:detail,evidence:evidence)
        }
        var baselineOccupied: [OccupiedPair:Double] = [:], previousOccupied: [OccupiedPair:Double] = [:]
        let occupiedVoxels = map.occupiedVoxels
        for link in depthCheckedArms {
            let jaw = link == model.toolLink ? ROBWorkspaceCollisionPlan.openJawAdditionalMarginMeters : 0
            let broad = start.boxes[link]!.inflated(padding+jaw)
            for voxel in occupiedVoxels {
                let point = voxel.center(voxelSizeMeters:map.voxelSizeMeters)
                guard broad.contains(point) else { continue }
                let distance = try hullDistance(link,point,start.frames)
                guard distance <= padding+jaw else { continue }
                guard distance >= 0.10+jaw else {
                    throw rejection("The estimated \(link) starts less than 100mm plus jaw clearance from an occupied depth-grid cell. No retreat was admitted.",
                        stage:"baseline_occupied_clearance",link:link,voxel:voxel,distance:distance,baselineDistance:distance,
                        required:0.10+jaw,jaw:jaw,q:baseline,sample:0,count:nil,boxes:start.boxes,frames:start.frames)
                }
                let key = OccupiedPair(link:link,voxel:voxel)
                baselineOccupied[key] = distance; previousOccupied[key] = distance
                guard baselineOccupied.count <= 4_096 else { throw ROBGhostMotionError.blocked("Too many close occupied pairs for one bounded retreat proof.") }
            }
        }
        let occupiedKeys = baselineOccupied.keys.sorted {
            if $0.link != $1.link { return $0.link < $1.link }
            if $0.voxel.x != $1.voxel.x { return $0.voxel.x < $1.voxel.x }
            if $0.voxel.y != $1.voxel.y { return $0.voxel.y < $1.voxel.y }
            return $0.voxel.z < $1.voxel.z
        }
        var localRegions: [String:Box] = [:]
        for link in depthCheckedArms {
            let jaw = link == model.toolLink ? ROBWorkspaceCollisionPlan.openJawAdditionalMarginMeters : 0
            localRegions[link] = start.boxes[link]!.inflated(padding+jaw+maximumVertexTravelMeters+voxelHalf)
        }
        var initial: [String:Clearance] = [:], previous: [String:Clearance] = [:]
        var initialHull:[String:Double]=[:],previousHull:[String:Double]=[:]
        for arm in arms { for tread in treads {
            let key = arm+"|"+tread, value = clearance(start.boxes[arm]!,start.boxes[tread]!)
            initial[key] = value; previous[key] = value
            if model.physicalSide == "right" {
                let gap = value.separation >= 0.030 ? value.separation : try checkedHull(arm).signedSeparation(to:checkedHull(tread),frame:start.frames[arm]!,otherFrame:start.frames[tread]!)
                initialHull[key]=gap;previousHull[key]=gap
            }
        } }
        let count = max(1,Int(ceil(1.5*jointDeltaRadians.reduce(0) { $0+abs($1) }/ROBWorkspaceCollisionPlan.sweptPointTravelMeters)))
        guard count+1 <= 128 else { throw ROBGhostMotionError.blocked("The bounded retreat requires too many swept poses.") }
        var unknown = Set<ROBWorkspaceVoxel>(), maximumVertex = 0.0
        for sample in 0...count {
            let fraction = Double(sample)/Double(count)
            let q = zip(baseline,jointDeltaRadians).map { $0+$1*fraction }
            let pose = try geometry(q)
            for link in arms {
                for (origin,current) in zip(start.points[link]!,pose.points[link]!) {
                    let displacement = simd_distance(origin,current)
                    guard !fixedMounts.contains(link) || displacement <= 1e-12 else {
                        throw ROBGhostMotionError.blocked("The rigid torso mount moved in the estimated arm model. No stationary-mount exception was admitted.")
                    }
                    maximumVertex = max(maximumVertex,displacement)
                }
                guard maximumVertex <= maximumVertexTravelMeters else {
                    throw ROBGhostMotionError.blocked("A modeled arm vertex would exceed the \(Int(maximumVertexTravelMeters*1000))mm experiment cap. No retreat was admitted.")
                }
            }
            for arm in arms { for tread in treads {
                let key = arm+"|"+tread, current = clearance(pose.boxes[arm]!,pose.boxes[tread]!), prior = previous[key]!
                if model.physicalSide == "right" {
                    let gap = current.separation >= 0.030 ? current.separation : try checkedHull(arm).signedSeparation(to:checkedHull(tread),frame:pose.frames[arm]!,otherFrame:pose.frames[tread]!)
                    guard gap+1e-9 >= min(previousHull[key]!,0.030) else {
                        throw ROBGhostMotionError.blocked("The RIGHT probe worsens actual \(arm) / \(tread) hull clearance; no step admitted.")
                    }
                    previousHull[key]=gap
                } else if !notWorse(current,than:prior) {
                    throw ROBGhostMotionError.blocked("The estimated nudge worsens \(arm) / \(tread) clearance. Keep the arm held and adjust its model first.")
                }
                previous[key] = current
            } }
            // Track every baseline-close pair at every pose, including after
            // it leaves broadphase. A new close pair never receives this rule.
            for key in occupiedKeys {
                let point = key.voxel.center(voxelSizeMeters:map.voxelSizeMeters)
                let distance = try hullDistance(key.link,point,pose.frames)
                guard distance+1e-9 >= previousOccupied[key]! else {
                    throw ROBGhostMotionError.blocked("The estimated \(key.link) retreat moves toward a previously close occupied depth-grid cell. No retreat was admitted.")
                }
                previousOccupied[key] = distance
            }
            for link in depthCheckedArms {
                let jaw = link == model.toolLink ? ROBWorkspaceCollisionPlan.openJawAdditionalMarginMeters : 0
                let box = pose.boxes[link]!.inflated(padding+jaw), region = localRegions[link]!, size = map.voxelSizeMeters
                let low = (0..<3).map { Int(floor(box.low[$0]/size)) }, high = (0..<3).map { Int(floor(box.high[$0]/size)) }
                guard zip(low,high).allSatisfy({ $1 >= $0 && $1-$0 < 100 }) else {
                    throw ROBGhostMotionError.blocked("The estimated local calibration envelope is too large.")
                }
                for x in low[0]...high[0] { for y in low[1]...high[1] { for z in low[2]...high[2] {
                    let voxel = ROBWorkspaceVoxel(x:x,y:y,z:z), point = voxel.center(voxelSizeMeters:size)
                    // The expanded AABB is only a broad-phase lookup. Use the
                    // Euclidean offset of the conservative hull box so its
                    // corners do not enlarge the stated clearance by sqrt(3).
                    // Voxel half-diagonal, sweep and open-jaw allowances remain
                    // included; the occupied map is never modified.
                    let nominal = pose.boxes[link]!
                    let gap = simd_max(SIMD3<Double>.zero,simd_max(nominal.low-point,point-nominal.high))
                    let nominalDistance = simd_length(gap)
                    guard nominalDistance <= padding+jaw else { continue }
                    switch map.state(at:point) {
                    case .occupied:
                        let key = OccupiedPair(link:link,voxel:voxel)
                        if baselineOccupied[key] != nil { continue }
                        let distance = try hullDistance(link,point,pose.frames)
                        guard distance <= padding+jaw else { continue }
                        let baselineDistance = try hullDistance(link,point,start.frames)
                        let diagnostic = String(format:"cell [%.3f, %.3f, %.3f]m; verified hull distance %.1fmm; baseline %.1fmm; hull-box distance %.1fmm; sample %d/%d",point.x,point.y,point.z,distance*1000,baselineDistance*1000,nominalDistance*1000,sample,count)
                        throw rejection("The estimated \(link) envelope intersects an occupied depth-grid cell, including the 15cm estimate inflation (\(diagnostic)). No nudge was admitted.",
                            stage:"swept_occupied_intersection",link:link,voxel:voxel,distance:distance,baselineDistance:baselineDistance,
                            required:padding+jaw,jaw:jaw,q:q,sample:sample,count:count,boxes:pose.boxes,frames:pose.frames)
                    case .unknown:
                        guard region.contains(point) else { throw ROBGhostMotionError.blocked("The nudge enters unknown space outside its explicit local commissioning region.") }
                        unknown.insert(voxel)
                    case .free: break
                    }
                } } }
            }
        }
        var pairs: [ROBEstimatedArmSelfProxyPair] = []
        for arm in arms { for tread in treads {
            let key = arm+"|"+tread, a = initial[key]!, b = previous[key]!
            if model.physicalSide == "right" {
                let before=initialHull[key]!,after=previousHull[key]!
                if before < 0.030 {
                    guard after>before+1e-9 else {throw ROBGhostMotionError.blocked("The RIGHT probe does not strictly improve every initial actual-hull deficit.")}
                    pairs.append(.init(armLink:arm,treadLink:tread,baselineOverlapCubicMeters:a.overlap,finalOverlapCubicMeters:b.overlap,
                        baselineSeparationMeters:a.separation,finalSeparationMeters:b.separation,
                        baselineHullSignedSeparationMeters:before,finalHullSignedSeparationMeters:after))
                }
            } else if a.overlap > 0 || a.separation < 0.030 {
                guard a.overlap > 0 ? b.overlap < a.overlap-1e-12 : b.separation > a.separation+1e-9 else {
                    throw ROBGhostMotionError.blocked("The nudge does not improve every pre-existing near-tread proxy deficit. No automatic escape was admitted.")
                }
                pairs.append(.init(armLink:arm,treadLink:tread,baselineOverlapCubicMeters:a.overlap,finalOverlapCubicMeters:b.overlap,
                    baselineSeparationMeters:a.separation,finalSeparationMeters:b.separation))
            }
        } }
        let regions = depthCheckedArms.map { link -> ROBEstimatedArmLocalRegion in
            let b = localRegions[link]!
            return .init(link:link,low:[b.low.x,b.low.y,b.low.z],high:[b.high.x,b.high.y,b.high.z])
        }
        let occupiedPairs = try occupiedKeys.map { key -> ROBEstimatedArmOccupiedRetreatPair in
            let baselineDistance = baselineOccupied[key]!, finalDistance = previousOccupied[key]!
            guard finalDistance > baselineDistance+1e-9 else {
                throw ROBGhostMotionError.blocked("The estimated \(key.link) retreat does not strictly improve every previously close occupied pair.")
            }
            return .init(link:key.link,voxel:key.voxel,baselineDistanceMeters:baselineDistance,finalDistanceMeters:finalDistance)
        }
        return .init(id:id,modelID:model.modelID,referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            sessionGeneration:generation,cameraGeneration:cameraGeneration,sceneID:map.sceneID,mapFingerprint:map.fingerprint,
            createdAtMilliseconds:nowMilliseconds,baseline:baseline,target:target,seconds:durationSeconds,registrationMode:mode,
            estimatedInflationMeters:obstacleInflationMeters,maximumVertexDisplacementMeters:maximumVertex,
            unknownVoxelCount:unknown.count,checkedPoseCount:count+1,baselineSelfProxyPairs:pairs,baselineCloseOccupiedPairs:occupiedPairs,unknownLocalRegions:regions)
    }
}
