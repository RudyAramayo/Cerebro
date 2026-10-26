import Foundation
import CryptoKit
import simd

@main enum RawReturnMapFixtures {
    static func main()throws {
        setbuf(stdout,nil)
        let camera=UUID(),projection=String(repeating:"a",count:64)
        func initial(_ budget:ROBWorkspaceDepthMap.StorageBudget = .standard)->ROBWorkspaceDepthMap {
            .init(modelID:"model",geometryID:"geometry",mappingID:"mapping",sessionGeneration:1,cameraGeneration:camera,
                  nowMilliseconds:1000,storageBudget:budget,estimatedCameraProjectionIdentity:projection)
        }
        func append(_ map:inout ROBWorkspaceDepthMap,_ sequence:UInt64)throws {
            try map.append(width:16,height:16,fx:30,fy:30,cx:8,cy:8,depth:{_,_ in 900},cameraToRobot:matrix_identity_double4x4,
                capturedAtMilliseconds:1000+Double(sequence),sequence:sequence,cameraGeneration:camera,
                nowMilliseconds:1000+Double(sequence),recordedPanDegrees:0,recordedUpperTarget:5650,recordedLowerTarget:6011,
                estimatedCameraProjectionIdentity:projection)
        }
        func continued(_ s:ROBWorkspaceCollisionSnapshot)throws->ROBWorkspaceDepthMap {
            try .init(continuing:s,modelID:"model",geometryID:"geometry",mappingID:"mapping",sessionGeneration:1,
                cameraGeneration:camera,estimatedCameraProjectionIdentity:projection,nowMilliseconds:1005)
        }
        var map=initial();try append(&map,1);try append(&map,2)
        let snapshot=map.snapshot(nowMilliseconds:1003)!
        let point=snapshot.occupiedVoxels[0].center(voxelSizeMeters:0.025)
        precondition(snapshot.occupiedSampleSubBounds(at:point)?.isEmpty==false)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(snapshot),decoded=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:bytes)
        precondition(decoded.fingerprint==snapshot.fingerprint && decoded.occupiedSampleSubBounds(at:point)==snapshot.occupiedSampleSubBounds(at:point))
        // An omitted contributor or corrupt group may not narrow the legacy
        // aggregate; decoder must retain occupancy and fail back to its union.
        var damaged=try JSONSerialization.jsonObject(with:bytes)as![String:Any]
        var source=damaged["occupiedSourceSamples"]as![[String:Any]]
        source.removeFirst(2);damaged["occupiedSourceSamples"]=source
        let incomplete=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:JSONSerialization.data(withJSONObject:damaged))
        for cell in incomplete.occupiedVoxels {
            let p=cell.center(voxelSizeMeters:0.025)
            precondition(incomplete.state(at:p) == .occupied && incomplete.occupiedSampleSubBounds(at:p)==nil)
        }
        damaged["fingerprint"]=incomplete.canonicalFingerprint(withSourceSamples:incomplete.occupiedSourceSamples)
        let canonicalIncomplete=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:JSONSerialization.data(withJSONObject:damaged))
        var conservative=try continued(canonicalIncomplete);try append(&conservative,3)
        let conservativeNext=conservative.snapshot(nowMilliseconds:1004)!
        for cell in canonicalIncomplete.occupiedVoxels {
            let p=cell.center(voxelSizeMeters:0.025)
            precondition(conservativeNext.state(at:p) == .occupied && conservativeNext.occupiedSampleSubBounds(at:p)==nil)
        }
        var next=try continued(decoded)
        precondition(next.snapshot(nowMilliseconds:1003)!.fingerprint==snapshot.fingerprint)
        try append(&next,3)
        let newer=next.snapshot(nowMilliseconds:1004)!
        for cell in snapshot.occupiedVoxels {
            let p=cell.center(voxelSizeMeters:0.025)
            precondition(newer.state(at:p) == .occupied && newer.occupiedSampleSubBounds(at:p)?.isEmpty==false)
        }
        let unknown=SIMD3<Double>(1.9,1.9,2.3)
        precondition(snapshot.state(at:unknown) == .unknown && snapshot.occupiedSampleSubBounds(at:unknown)==nil)
        var legacy=try JSONSerialization.jsonObject(with:bytes)as![String:Any]
        precondition(legacy.removeValue(forKey:"occupiedSourceSamples") != nil)
        legacy["fingerprint"]=snapshot.canonicalFingerprint(withSourceSamples:nil)
        let old=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:JSONSerialization.data(withJSONObject:legacy))
        precondition(old.fingerprint != snapshot.fingerprint && old.occupiedSampleSubBounds(at:point)==nil)
        var oldContinued=try continued(old);try append(&oldContinued,3)
        let oldNew=oldContinued.snapshot(nowMilliseconds:1004)!
        precondition(oldNew.occupiedSampleSubBounds(at:point)==nil && oldNew.state(at:point) == .occupied)
        var bounded=initial(.init(occupiedVoxels:1,freeVoxels:100));try append(&bounded,1);try append(&bounded,2)
        let truncated=bounded.snapshot(nowMilliseconds:1003)!
        precondition(truncated.isTruncated)
        for cell in truncated.occupiedVoxels {precondition(truncated.occupiedSampleSubBounds(at:cell.center(voxelSizeMeters:0.025))==nil)}
        do {_=try continued(truncated);preconditionFailure("Truncated raw evidence continued")}catch{}
        print("PASS raw-return map detail: fresh groups, wire/fingerprint roundtrip, continuation preservation, legacy permanent fallback, unknown unchanged, truncation fail-closed; synthetic rays only.")
    }
}
