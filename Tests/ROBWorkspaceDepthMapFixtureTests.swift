import Foundation
import simd
import Darwin

@main struct ROBWorkspaceDepthMapFixtures {
    static func expect(_ value: @autoclosure () -> Bool, _ detail: String) {
        precondition(value(),detail)
    }
    static func rejected(_ detail: String, _ block: () throws -> Void) {
        do { try block(); fatalError(detail) } catch {}
    }
    static func projectionExpirationFixtures()throws {
        let camera=UUID(),now=50_000.0
        var map=ROBWorkspaceDepthMap(modelID:"expiry-model",geometryID:"expiry-geometry",mappingID:"expiry-mapping",
            sessionGeneration:11,cameraGeneration:camera,nowMilliseconds:now)
        func append(_ sequence:UInt64,_ age:Double)throws {
            try map.append(width:16,height:16,fx:1000,fy:1000,cx:8,cy:8,depth:{_,_ in 1000},
                cameraToRobot:matrix_identity_double4x4,capturedAtMilliseconds:now+Double(sequence),sequence:sequence,
                cameraGeneration:camera,nowMilliseconds:now+Double(sequence)+age)
        }
        try append(1,10);try append(2,10)
        let before=map.snapshot(nowMilliseconds:now+725)!
        var expired:ROBWorkspaceDepthMapError?
        do {try append(3,721.6);fatalError("721.6ms projection frame was accepted")}
        catch let error as ROBWorkspaceDepthMapError {
            guard case .expiredAtProjection(let age)=error else{fatalError("Projection expiry lost its typed outcome")}
            expect(abs(age-721.6)<1e-8,"Source age changed during expiry reporting");expired=error
        }
        expect(expired!.localizedDescription.contains("721.6 ms is outside 0...700 ms at projection"),"Projection expiry lost its original user reason")
        expect(map.snapshot(nowMilliseconds:now+725)!.fingerprint==before.fingerprint,"Expired append mutated an existing partial map")
        var budget=ROBWorkspaceProjectionRetryBudget(startedAtUptime:10)
        expect(budget.permitsRetry(after:expired!,nowUptime:10.8,contextIsCurrent:true,taskCancelled:false),"Single age expiry did not permit fresh reacquisition")
        try append(4,20)
        let after=map.snapshot(nowMilliseconds:now+30)!
        expect(after.observedFrameCount==3 && after.observations.map(\.sequence)==[1,2,4],"Fresh retry discarded completed frames or enrolled expired pixels")
        expect(after.observations.map(\.capturedAtMilliseconds)==[now+1,now+2,now+4],"Retry manufactured a source timestamp")
        expect(after.state(at:SIMD3(0.0005,0.0005,1)) == .occupied,"Reacquisition erased a completed obstacle")
        rejected("Retry allowed a previously attempted/reordered source") {try append(3,20)}
        try append(5,700) // The exact existing boundary remains unchanged.
        for error:Error in [ROBWorkspaceDepthMapError.invalidFrame,ROBWorkspaceDepthMapError.acquisition("invalid geometry"),CancellationError()] {
            var other=ROBWorkspaceProjectionRetryBudget(startedAtUptime:10)
            expect(!other.permitsRetry(after:error,nowUptime:11,contextIsCurrent:true,taskCancelled:false) && other.discardedFrameCount==0,
                "Non-expiry/cancellation error entered the projection retry lane")
        }
        for (sameContext,cancelled) in [(false,false),(true,true)] {
            var changed=ROBWorkspaceProjectionRetryBudget(startedAtUptime:10)
            expect(!changed.permitsRetry(after:expired!,nowUptime:11,contextIsCurrent:sameContext,taskCancelled:cancelled) && changed.discardedFrameCount==0,
                "Changed pose/source/gateway/PID or cancellation retried an expired projection")
        }
        var exhausted=ROBWorkspaceProjectionRetryBudget(startedAtUptime:10)
        expect(exhausted.permitsRetry(after:expired!,nowUptime:11,contextIsCurrent:true,taskCancelled:false),"First discard was unavailable")
        expect(exhausted.permitsRetry(after:expired!,nowUptime:12,contextIsCurrent:true,taskCancelled:false),"Second discard was unavailable")
        expect(!exhausted.permitsRetry(after:expired!,nowUptime:13,contextIsCurrent:true,taskCancelled:false),"Third expiry did not end the held view")
        expect(!exhausted.permitsRetry(after:expired!,nowUptime:14,contextIsCurrent:true,taskCancelled:false) && exhausted.discardedFrameCount==3,
            "Discard count escaped its bound")
        var deadline=ROBWorkspaceProjectionRetryBudget(startedAtUptime:10)
        expect(!deadline.permitsRetry(after:expired!,nowUptime:18,contextIsCurrent:true,taskCancelled:false) && deadline.deadlineUptime==18,
            "Reacquisition extended its original8s deadline")
        expect(deadline.lastExpiration?.localizedDescription==expired!.localizedDescription,"Deadline replaced the original projection error")
        do {try append(6,-1);fatalError("Future source frame was accepted")}
        catch let error as ROBWorkspaceDepthMapError {
            if case .expiredAtProjection=error {fatalError("Clock/future-frame error became a recoverable expiration")}
        }
        print("Projection retry:721.6ms rejected atomically; later advancing source accepted with original timestamps/partial map;700ms unchanged;3-discard/8s bounds;geometry/context/cancel never retry")
    }
    static func projectionIdentityFixtures() throws {
        let camera=UUID(),now=30_000.0,first=String(repeating:"a",count:64),second=String(repeating:"b",count:64)
        func make(_ identity:String?)->ROBWorkspaceDepthMap {
            .init(modelID:"projection-model",geometryID:"projection-geometry",mappingID:"projection-mapping",
                sessionGeneration:10,cameraGeneration:camera,nowMilliseconds:now,estimatedCameraProjectionIdentity:identity)
        }
        func append(_ map:inout ROBWorkspaceDepthMap,_ sequence:UInt64,_ identity:String?)throws {
            try map.append(width:16,height:16,fx:1000,fy:1000,cx:8,cy:8,depth:{_,_ in 1000},
                cameraToRobot:matrix_identity_double4x4,capturedAtMilliseconds:now+Double(sequence),sequence:sequence,
                cameraGeneration:camera,nowMilliseconds:now+Double(sequence)+1,cameraRegistrationVerified:true,
                estimatedCameraProjectionIdentity:identity)
        }
        var estimated=make(first)
        try append(&estimated,1,first);try append(&estimated,2,first)
        let snapshot=estimated.snapshot(nowMilliseconds:now+3)!
        expect(snapshot.estimatedCameraProjectionIdentity==first && snapshot.observations.allSatisfy{$0.estimatedCameraProjectionIdentity==first},
            "Estimated camera projection provenance was not retained")
        expect(snapshot.registrationID==nil,"Photo-origin identity manufactured measured registration")
        rejected("Changed photo projection was accepted") {try append(&estimated,3,second)}
        rejected("Photo origin was silently disabled during a scene") {try append(&estimated,3,nil)}
        expect(estimated.snapshot(nowMilliseconds:now+3)!.fingerprint==snapshot.fingerprint,"Rejected projection changed the frozen scene")
        var legacy=make(nil)
        rejected("Photo origin was enabled after a legacy scene began") {try append(&legacy,1,first)}
        try append(&legacy,1,nil);try append(&legacy,2,nil)
        let legacySnapshot=legacy.snapshot(nowMilliseconds:now+3)!
        expect(legacySnapshot.estimatedCameraProjectionIdentity==nil && legacySnapshot.observations.allSatisfy{$0.estimatedCameraProjectionIdentity==nil},
            "Legacy map invented photo-origin provenance")
        let encoded=try JSONEncoder().encode(legacySnapshot)
        expect(!String(data:encoded,encoding:.utf8)!.contains("estimatedCameraProjectionIdentity"),"Nil projection identity changed legacy serialization")
        let decoded=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:encoded)
        expect(decoded.estimatedCameraProjectionIdentity==nil,
            "Legacy snapshot without projection identity failed to decode")
    }
    static func storageBudgetFixtures() throws {
        let camera=UUID(),now=20_000.0
        func make(_ budget:ROBWorkspaceDepthMap.StorageBudget = .standard)->ROBWorkspaceDepthMap {
            .init(modelID:"resource-model",geometryID:"resource-geometry",mappingID:"resource-mapping",
                sessionGeneration:9,cameraGeneration:camera,nowMilliseconds:now,storageBudget:budget)
        }
        func point(_ map:inout ROBWorkspaceDepthMap,_ sequence:UInt64,_ depth:UInt16) throws {
            try map.append(width:16,height:16,fx:1000,fy:1000,cx:0.5,cy:0.5,
                depth:{$0==1 && $1==1 ? depth:nil},cameraToRobot:matrix_identity_double4x4,
                capturedAtMilliseconds:now+Double(sequence),sequence:sequence,cameraGeneration:camera,
                nowMilliseconds:now+Double(sequence)+1)
        }
        // Exactly27 inflated cells fill this budget. A later observation in
        // the same cells must still expand sample bounds without truncation.
        var fullOccupied=make(.init(occupiedVoxels:27,freeVoxels:1))
        try point(&fullOccupied,1,1000);try point(&fullOccupied,2,1001)
        let occupiedAtCapacity=fullOccupied.snapshot(nowMilliseconds:now+3)!
        expect(occupiedAtCapacity.occupiedVoxelCount==27 && !occupiedAtCapacity.isTruncated,
            "Duplicate occupied cells falsely exhausted storage at exact capacity")
        let bounds=occupiedAtCapacity.occupiedSampleBounds(at:SIMD3(0.0005,0.0005,1.0005))!
        expect(bounds.low.z==1 && bounds.high.z==1.001,"A full occupied set stopped retaining observed bounds")
        try point(&fullOccupied,3,1026)
        let occupiedOverflow=fullOccupied.snapshot(nowMilliseconds:now+4)!
        expect(occupiedOverflow.isTruncated && occupiedOverflow.occupiedVoxelCount==27,
            "A new occupied cell escaped the bounded storage budget")
        expect(occupiedOverflow.state(at:SIMD3(0.0005,0.0005,1.0005)) == .occupied,
            "Storage exhaustion erased an earlier obstacle")

        func rays(_ map:inout ROBWorkspaceDepthMap,_ sequence:UInt64,_ union:Bool,
                  shifted:Bool=false) throws {
            var transform=matrix_identity_double4x4
            if shifted {transform.columns.3.x=0.05}
            try map.append(width:16,height:16,fx:1000,fy:1000,cx:8,cy:8,depth:{_,_ in 1000},
                cameraToRobot:transform,capturedAtMilliseconds:now+Double(sequence),sequence:sequence,
                cameraGeneration:camera,nowMilliseconds:now+Double(sequence)+1,
                alternateEstimatedDepth:union ? {_,_ in UInt16(500)}:nil,
                estimatedDepthHypothesisID:union ? String(repeating:"c",count:64):nil)
        }
        for union in [false,true] {
            var reference=make()
            try rays(&reference,1,union);try rays(&reference,2,union)
            let measured=reference.snapshot(nowMilliseconds:now+3)!
            expect(measured.freeVoxelCount>0 && !measured.isTruncated,"Resource fixture did not produce free rays")
            var fullFree=make(.init(occupiedVoxels:1000,freeVoxels:measured.freeVoxelCount))
            try rays(&fullFree,1,union);try rays(&fullFree,2,union)
            let atCapacity=fullFree.snapshot(nowMilliseconds:now+3)!
            expect(!atCapacity.isTruncated && atCapacity.freeVoxelCount==measured.freeVoxelCount,
                "Duplicate \(union ? "estimated-union":"raw") free cells falsely exhausted exact capacity")
            let freePoint=atCapacity.freeVoxels[0].center(voxelSizeMeters:atCapacity.voxelSizeMeters)
            expect(atCapacity.state(at:freePoint) == .free,"Free fixture point was missing")
            try rays(&fullFree,3,union,shifted:true)
            let overflow=fullFree.snapshot(nowMilliseconds:now+4)!
            expect(overflow.isTruncated && overflow.freeVoxelCount<=measured.freeVoxelCount,
                "New free cells escaped the storage cap")
            expect(overflow.state(at:freePoint) == .unknown,
                "A truncated grid still authorized observed-free traversal")
        }

        // Actual append() of10,240 spatially dispersed depth returns exceeds
        // the old100k inflated-cell budget. Adjacent invalid samples prevent
        // any free-space claim; all27 obstacle cells remain required.
        func dispersed(_ map:inout ROBWorkspaceDepthMap,_ sequence:UInt64) throws {
            try map.append(width:640,height:400,fx:350,fy:350,cx:320,cy:200,
                depth:{x,y in
                    guard x%5==1 && y%5==1 else{return nil}
                    let mixed=(x*73_856_093) ^ (y*19_349_663)
                    return UInt16(300+mixed%2000)
                },cameraToRobot:matrix_identity_double4x4,
                capturedAtMilliseconds:now+Double(sequence),sequence:sequence,cameraGeneration:camera,
                nowMilliseconds:now+Double(sequence)+1)
        }
        let started=ProcessInfo.processInfo.systemUptime
        var wide=make()
        try dispersed(&wide,1);try dispersed(&wide,2)
        let expanded=wide.snapshot(nowMilliseconds:now+3)!
        expect(expanded.occupiedVoxelCount>100_000 && !expanded.isTruncated,
            "A real multi-surface append still exhausted the former100k budget")
        expect(expanded.voxelSizeMeters==0.025 && expanded.freeVoxelCount==0 && expanded.registrationID==nil,
            "Resource expansion changed voxel resolution, carved unknown rays, or manufactured registration")
        for y in stride(from:1,to:399,by:5) {for x in stride(from:1,to:639,by:5) {
            let z=Double(300+((x*73_856_093) ^ (y*19_349_663))%2000)/1000
            let endpoint=SIMD3((Double(x)-320)*z/350,(Double(y)-200)*z/350,z)
            guard (-2...2).contains(endpoint.x) else{continue}
            let center=ROBWorkspaceVoxel(x:Int(floor(endpoint.x/0.025)),y:Int(floor(endpoint.y/0.025)),z:Int(floor(z/0.025)))
            for dx in -1...1 {for dy in -1...1 {for dz in -1...1 {
                let cell=ROBWorkspaceVoxel(x:center.x+dx,y:center.y+dy,z:center.z+dz)
                expect(expanded.state(at:cell.center(voxelSizeMeters:0.025)) == .occupied,
                    "Expanded storage dropped an inflated occupied cell")
            }}}
        }}
        print(String(format:"Depth storage: %d occupied / %d free cells from real append; %.3f s including immutable snapshot and all27-cell audit; bounded default400k/600k; duplicate-full occupied/raw-free/union-free and true overflow passed",
            expanded.occupiedVoxelCount,expanded.freeVoxelCount,ProcessInfo.processInfo.systemUptime-started))
        var usage=rusage()
        if getrusage(RUSAGE_SELF,&usage)==0 {
            print(String(format:"Depth storage fixture peak resident memory: %.1f MiB (includes immutable snapshot/fingerprint construction and Swift runtime)",Double(usage.ru_maxrss)/1_048_576))
        }
    }
    static func main() throws {
        try projectionExpirationFixtures()
        try storageBudgetFixtures()
        try projectionIdentityFixtures()
        let camera = UUID(), now = 10_000.0
        func make() -> ROBWorkspaceDepthMap {
            .init(modelID:"model",geometryID:"geometry",mappingID:"mapping",sessionGeneration:7,
                cameraGeneration:camera,nowMilliseconds:now)
        }
        func append(_ map: inout ROBWorkspaceDepthMap, sequence:UInt64, millimeters:UInt16 = 1000,
                    transform:simd_double4x4 = matrix_identity_double4x4,
                    hole:Bool = false, selfBounds:[(low:SIMD3<Double>,high:SIMD3<Double>)] = [], verified:Bool = false,
                    registration:ROBFixedHeadRegistration? = nil) throws {
            try map.append(width:32,height:24,fx:30,fy:30,cx:16,cy:12,
                depth:{ x,y in hole && (10...22).contains(x) && (6...18).contains(y) ? nil : millimeters },
                cameraToRobot:transform,capturedAtMilliseconds:now+Double(sequence),sequence:sequence,
                cameraGeneration:camera,nowMilliseconds:now+Double(sequence)+1,
                measuredSelfBounds:selfBounds,cameraRegistrationVerified:verified,
                registration:registration,registrationScope:registration?.scope)
        }
        var map = make()
        try append(&map,sequence:1)
        expect(map.snapshot(nowMilliseconds:now+2) == nil,"One frame became a confirmed map")
        try append(&map,sequence:2)
        let snapshot = map.snapshot(nowMilliseconds:now+3)!
        expect(snapshot.observedFrameCount == 2,"Distinct frame count was lost")
        expect(snapshot.containsTargetObservation(sequence:2,capturedAtMilliseconds:now+2),"Target observation frame membership was lost")
        expect(!snapshot.containsTargetObservation(sequence:4,capturedAtMilliseconds:now+2),"Unknown target frame was admitted")
        var sharedCell = make()
        try append(&sharedCell,sequence:1,millimeters:1000);try append(&sharedCell,sequence:2,millimeters:1020)
        let occupiedBounds=sharedCell.snapshot(nowMilliseconds:now+3)!.occupiedSampleBounds(at:SIMD3(0.01,0.01,1.01))!
        expect(occupiedBounds.low.z<=1.00001 && occupiedBounds.high.z>=1.01999,"Shared can/table voxel discarded one observed surface from its contact bounds")
        expect(snapshot.state(at:SIMD3(0.01,0.01,1)) == .occupied,"Depth surface was not occupied")
        expect(snapshot.state(at:SIMD3(0.01,0.01,0.5)) == .free,"Observed space before a stable surface was not free")
        expect(snapshot.state(at:SIMD3(0.01,0.01,1.3)) == .unknown,"Space behind a return became free")
        expect(snapshot.state(at:SIMD3(1.8,1.8,0.5)) == .unknown,"Unobserved space became free")
        expect(snapshot.registrationID == nil && snapshot.registrationUncertaintyMeters == nil,"A neck-command prior became calibrated hand-eye evidence")
        expect(snapshot.fingerprint.count == 64 && snapshot.fingerprint == map.snapshot(nowMilliseconds:now+3)!.fingerprint,"Immutable map fingerprint was not deterministic")
        try append(&map,sequence:3,millimeters:2000)
        expect(map.snapshot(nowMilliseconds:now+4)!.state(at:SIMD3(0.01,0.01,1)) == .occupied,"Later rays cleared a previously occupied obstacle")
        expect(map.snapshot(nowMilliseconds:now+4)!.fingerprint != snapshot.fingerprint,"Map content change retained its fingerprint")
        rejected("Reordered camera frame was accepted") { try append(&map,sequence:2) }
        rejected("Camera generation change retained transformed evidence") {
            try map.append(width:32,height:24,fx:30,fy:30,cx:16,cy:12,depth:{_,_ in 1000},
                cameraToRobot:matrix_identity_double4x4,capturedAtMilliseconds:now+4,sequence:4,
                cameraGeneration:UUID(),nowMilliseconds:now+5)
        }
        rejected("Stale camera frame was accepted") {
            try map.append(width:32,height:24,fx:30,fy:30,cx:16,cy:12,depth:{_,_ in 1000},
                cameraToRobot:matrix_identity_double4x4,capturedAtMilliseconds:now+4,sequence:4,
                cameraGeneration:camera,nowMilliseconds:now+1000)
        }
        let hypothesisID=String(repeating:"a",count:64)
        func appendUnion(_ map:inout ROBWorkspaceDepthMap,sequence:UInt64,alternative:UInt16?=500,id:String?=hypothesisID) throws {
            try map.append(width:32,height:24,fx:30,fy:30,cx:16,cy:12,depth:{_,_ in 1000},
                cameraToRobot:matrix_identity_double4x4,capturedAtMilliseconds:now+Double(sequence),sequence:sequence,
                cameraGeneration:camera,nowMilliseconds:now+Double(sequence)+1,
                alternateEstimatedDepth:{_,_ in alternative},estimatedDepthHypothesisID:id)
        }
        var union=make()
        try appendUnion(&union,sequence:1);try appendUnion(&union,sequence:2)
        let unionSnapshot=union.snapshot(nowMilliseconds:now+3)!
        expect(unionSnapshot.registrationID==nil && unionSnapshot.observedFrameCount==2,"Estimated hypotheses fabricated registration or doubled a frame")
        expect(unionSnapshot.observations.allSatisfy{$0.estimatedDepthHypothesisID==hypothesisID && !$0.measuredSelfMaskApplied},"Estimated depth provenance/self-mask changed")
        expect(unionSnapshot.state(at:SIMD3(0.01,0.01,0.5)) == .occupied,"Near hypothesis disappeared")
        expect(unionSnapshot.state(at:SIMD3(0.01,0.01,1.0)) == .occupied,"Raw hypothesis disappeared")
        expect(unionSnapshot.state(at:SIMD3(0.01,0.01,0.35)) == .free,"Shared observed free space was lost")
        expect(unionSnapshot.state(at:SIMD3(0.01,0.01,0.7)) != .free,"A longer hypothesis erased the shorter surface")
        rejected("Hypothesis identity changed mid-scene") {try appendUnion(&union,sequence:3,id:String(repeating:"b",count:64))}
        var missingAlternative=make()
        try appendUnion(&missingAlternative,sequence:1,alternative:nil);try appendUnion(&missingAlternative,sequence:2,alternative:nil)
        expect(missingAlternative.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,0.35)) == .unknown,"Missing alternative carved unverified free space")
        var missingID=make()
        rejected("Estimated hypothesis lacked provenance") {try appendUnion(&missingID,sequence:1,id:nil)}
        var holes = make()
        try append(&holes,sequence:1,hole:true); try append(&holes,sequence:2,hole:true)
        expect(holes.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,0.5)) == .unknown,"Missing depth carved free space")
        var moved = make(), transform = matrix_identity_double4x4
        transform.columns.3.x = 0.5
        try append(&moved,sequence:1,transform:transform); try append(&moved,sequence:2,transform:transform)
        expect(moved.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.51,0.01,1)) == .occupied,"Recorded camera transform was ignored")
        let hulls = [(low:SIMD3<Double>(-0.3,-0.3,0.8),high:SIMD3<Double>(0.3,0.3,1.2))]
        var priorSelf = make()
        try append(&priorSelf,sequence:1,selfBounds:hulls); try append(&priorSelf,sequence:2,selfBounds:hulls)
        expect(priorSelf.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,1)) == .occupied,"Unregistered self mask erased a possible table")
        var rawBoolean = make()
        try append(&rawBoolean,sequence:1,selfBounds:hulls,verified:true)
        try append(&rawBoolean,sequence:2,selfBounds:hulls,verified:true)
        expect(rawBoolean.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,1)) == .occupied,"A raw verified boolean erased occupied depth")
        let scope=ROBFixedHeadRegistrationScope(modelID:"model",geometryID:"geometry",mappingID:"mapping",cameraGeneration:camera,
            gatewaySessionGeneration:7,displayCorrectionIdentity:"fixture-display",panTarget:6000,lowerTarget:6011,upperTarget:6906,intrinsicsIdentity:"fixture-intrinsics")
        let fitPoints:[SIMD3<Double>]=[-0.2,0.2].flatMap {x in [-0.2,0.2].flatMap {y in [0.8,1.2].map {z in SIMD3(x,y,z)}}}
        let heldPoints:[SIMD3<Double>]=[SIMD3(-0.3,-0.1,1.0),SIMD3(0.3,-0.1,1.0),SIMD3(0,0.3,1.1)]
        let samples=(fitPoints+heldPoints).enumerated().map {i,p in
            ROBFixedHeadRegistrationSample(landmarkID:"fixture-\(i)",captureID:i<8 ? "fit":"held-\(i%2)",frameSequence:UInt64(i<8 ? 1:2+i%2),capturedAtMilliseconds:i<8 ? now:now+2+Double(i%2),
                evidenceSHA256:String(repeating:"a",count:64),referenceSource:"measured_robot_landmark",cameraMeters:[p.x,p.y,p.z],robotMeters:[p.x,p.y,p.z],cameraUncertaintyMeters:0.002,referenceUncertaintyMeters:0.002,validationOnly:i>=8)
        }
        let proof=try ROBFixedHeadRegistration.fit(.init(schemaVersion:1,scope:scope,
            validRobotVolume:.init(lowMeters:[-0.5,-0.5,0.05],highMeters:[0.5,0.5,1.5]),samples:samples))
        var measuredSelf = make()
        try append(&measuredSelf,sequence:1,selfBounds:hulls,registration:proof)
        try append(&measuredSelf,sequence:2,selfBounds:hulls,registration:proof)
        expect(measuredSelf.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,1)) == .unknown,"Measured self depth was treated as free space")
        expect(measuredSelf.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,1.3)) == .unknown,"Self occlusion cleared space behind the arm")
        expect(measuredSelf.snapshot(nowMilliseconds:now+3)!.registrationID != nil,"Measured fixed-head frame proof was not exported")
        expect(measuredSelf.snapshot(nowMilliseconds:now+3)!.registrationUncertaintyMeters == proof.uncertaintyMeters,"Registration allowance was not retained")
        var mixed = make()
        try append(&mixed,sequence:1,registration:proof);try append(&mixed,sequence:2)
        expect(mixed.snapshot(nowMilliseconds:now+3)!.registrationID == nil,"One measured frame promoted an earlier/later provisional frame")
        var local = make()
        try append(&local,sequence:1,registration:proof);try append(&local,sequence:2,registration:proof)
        expect(local.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.8,0.01,0.5)) == .unknown,"Registered free space escaped the measured local volume")
        rejected("A matrix different from the measured scoped fit was projected as registered") {
            var wrong = make()
            try append(&wrong,sequence:1,transform:transform,registration:proof)
        }
        let capturedBeforeBodyMove=local.snapshot(nowMilliseconds:now+3)!
        expect(capturedBeforeBodyMove.registrationID != nil,"Fixture registration was missing before body motion")
        ROBFixedHeadBodyMotionIdentity.invalidate()
        expect(capturedBeforeBodyMove.registrationID == nil,"A retained snapshot stayed registered after body motion")
        expect(local.snapshot(nowMilliseconds:now+3) == nil,"A captured depth scene survived body motion")
        rejected("Body movement retained an appendable old scene") {try append(&local,sequence:3,registration:proof)}
        print("Depth-map fixtures passed: fresh identities and frames, occupied/free/unknown ray semantics, holes/occlusion, transform provenance, immutable fingerprint and no provisional hand-eye promotion")
    }
}
