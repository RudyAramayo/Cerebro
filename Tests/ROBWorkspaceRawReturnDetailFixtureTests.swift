import Foundation
import simd

/// Isolated protocol provider: the mapper's source-voxel provenance and storage
/// completeness are tested separately. This fixture exercises the consumer's
/// disjoint-envelope geometry and fail-closed fallback against the real model.
private struct DetailMap: ROBWorkspaceCollisionMap {
    let sceneID:UUID,cameraGeneration:UUID
    let sessionGeneration:UInt64=42
    let modelID:String,geometryID:String,mappingID:String
    let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0,voxelSizeMeters=0.025
    let registrationID:String?=nil,registrationUncertaintyMeters:Double?=nil
    let cell:SIMD3<Int>,kind:ROBWorkspaceVoxelState
    let legacy:ROBWorkspaceOccupiedReturnBounds
    let details:[ROBWorkspaceOccupiedReturnBounds]?
    var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope? {
        .init(bodyMotionIdentity:"isolated stationary body",bodyContextIsCurrent:true,
              estimatedCameraProjectionIdentity:String(repeating:"a",count:64),
              observationPoseIdentity:String(repeating:"b",count:64),observedFrameCount:2)
    }
    var fingerprint:String {ROBGhostRobotModel.hash(Data("\(cell)-\(kind)-\(legacy)-\(String(describing:details))".utf8))}
    func state(at p:SIMD3<Double>)->ROBWorkspaceVoxelState {
        SIMD3(Int(floor(p.x/voxelSizeMeters)),Int(floor(p.y/voxelSizeMeters)),Int(floor(p.z/voxelSizeMeters)))==cell ? kind:.free
    }
    func state(inBoundsLow low:SIMD3<Double>,high:SIMD3<Double>)->ROBWorkspaceVoxelState {
        (0..<3).allSatisfy({Int(floor(low[$0]/voxelSizeMeters))<=cell[$0] && Int(floor(high[$0]/voxelSizeMeters))>=cell[$0]}) ? kind:.free
    }
    func occupiedSampleBounds(at p:SIMD3<Double>)->(low:SIMD3<Double>,high:SIMD3<Double>)? {
        guard state(at:p) == .occupied else{return nil}
        return (SIMD3(legacy.lowMeters[0],legacy.lowMeters[1],legacy.lowMeters[2]),SIMD3(legacy.highMeters[0],legacy.highMeters[1],legacy.highMeters[2]))
    }
    func occupiedSampleSubBounds(at p:SIMD3<Double>)->[ROBWorkspaceOccupiedReturnBounds]? {state(at:p) == .occupied ? details:nil}
}

@main enum RawReturnDetailFixtures {
    static func main()throws {
        setbuf(stdout,nil)
        // Two physically nearby return groups share a dilated25mm cell.
        // The old union creates a corner50mm from the cube; both actual
        // groups remain61.03mm away under the unchanged60mm margin.
        let cube="""
        v -0.005 -0.005 -0.005
        v 0.005 -0.005 -0.005
        v 0.005 0.005 -0.005
        v -0.005 0.005 -0.005
        v -0.005 -0.005 0.005
        v 0.005 -0.005 0.005
        v 0.005 0.005 0.005
        v -0.005 0.005 0.005
        f 1 3 2
        f 1 4 3
        f 5 6 7
        f 5 7 8
        f 1 2 6
        f 1 6 5
        f 4 8 7
        f 4 7 3
        f 1 5 8
        f 1 8 4
        f 2 3 7
        f 2 7 6
        """
        func cubeDistance(_ low:SIMD3<Double>,_ high:SIMD3<Double>)throws->Double {
            try ROBWorkspaceVerifiedConvexEnvelope.distance(hullText:cube,frame:matrix_identity_double4x4,low:low,high:high)
        }
        let first=SIMD3<Double>(0.040,0,0.055),second=SIMD3<Double>(0,0.040,0.055)
        let firstDistance=try cubeDistance(first,first),secondDistance=try cubeDistance(second,second)
        let unionDistance=try cubeDistance(simd_min(first,second),simd_max(first,second))
        let contactDistance=try cubeDistance(SIMD3(0,0,0.010),SIMD3(0,0,0.010))
        precondition(firstDistance>0.060 && secondDistance>0.060 && unionDistance<0.060 && contactDistance<0.060)
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
        let q=model.recyclingFrontTarget,frames=model.frames(model.positions(vendorLeft:q))
        let catalog=try JSONSerialization.jsonObject(with:Data(contentsOf:model.directory.appendingPathComponent("surfaces.json")))as![String:Any]
        let row=(catalog["surfaces"]as![[String:Any]]).first{$0["link"]as?String==model.toolLink}!
        let text=try String(contentsOf:model.directory.appendingPathComponent(row["hull"]as!String),encoding:.utf8)
        let hull=try ROBEstimatedConvexHull(text:text),local=hull.vertices.reduce(SIMD3<Double>.zero,+)/Double(hull.vertices.count)
        let p4=frames[model.toolLink]!*SIMD4(local,1),p=SIMD3(p4.x,p4.y,p4.z)
        let cell=SIMD3(Int(floor(p.x/0.025)),Int(floor(p.y/0.025)),Int(floor(p.z/0.025)))
        let scene=UUID(),camera=UUID()
        func point(_ p:SIMD3<Double>)->ROBWorkspaceOccupiedReturnBounds {.init(lowMeters:[p.x,p.y,p.z],highMeters:[p.x,p.y,p.z])}
        let a=point(SIMD3(-2,-2,-0.2)),b=point(SIMD3(2,2,2.3)),contact=point(p)
        let union=ROBWorkspaceOccupiedReturnBounds(lowMeters:a.lowMeters,highMeters:b.highMeters)
        func map(_ detail:[ROBWorkspaceOccupiedReturnBounds]?,kind:ROBWorkspaceVoxelState = .occupied)->DetailMap {
            .init(sceneID:scene,cameraGeneration:camera,modelID:model.modelID,geometryID:model.geometryID,
                  mappingID:model.selectedMappingID,cell:cell,kind:kind,legacy:union,details:detail)
        }
        func review(_ m:DetailMap)throws {
            let t=ROBWorkspaceVisualCalibrationTrial(receiptID:"isolated",receiptSHA256:String(repeating:"c",count:64),
                appSessionID:"isolated",command:"right_recycle_cans",canCount:4,summarySHA256:String(repeating:"d",count:64),
                authorizationContextIdentity:"isolated",sessionGeneration:42,sceneID:scene,cameraGeneration:camera,
                modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:m.fingerprint,
                bodyMotionIdentity:"isolated stationary body",estimatedCameraProjectionIdentity:String(repeating:"a",count:64),
                observationPoseIdentity:String(repeating:"b",count:64),currentPoseIdentity:String(repeating:"e",count:64),
                baseline:q,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.035)
            _=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:[.init(positions:q,seconds:0.7)],
                map:m,model:model,generation:42,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:t)
        }
        func blocked(_ m:DetailMap,_ expected:String) {
            do {try review(m);preconditionFailure("Unsafe detail provider admitted")}
            catch {if !expected.isEmpty {precondition(error.localizedDescription.contains(expected),error.localizedDescription)}}
        }
        try review(map([a,b]))
        blocked(map([a,contact,b]),"obstacle")
        blocked(map([b,contact,a]),"obstacle")
        blocked(map(nil),"obstacle")
        blocked(map([]),"obstacle")
        blocked(map([a]),"obstacle") // Incomplete aggregate must retain legacy union.
        blocked(map([.init(lowMeters:[Double.nan,0,0],highMeters:[0,0,0])]),"")
        blocked(map([a,b],kind:.unknown),"unobserved")
        print("PASS raw-return detail consumer: disjoint groups clear; every real contact vetoes; absent/empty/incomplete/invalid detail retains legacy obstacle; unknown unchanged; unchanged real-model margins.")
    }
}
