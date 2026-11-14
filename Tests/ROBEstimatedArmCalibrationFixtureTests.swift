import Foundation
import simd
import CryptoKit

@main struct EstimatedArmCalibrationFixtures {
    static func blocked(_ text:String? = nil,line:UInt = #line,_ body:() throws -> Void) {
        do {
            try body()
            FileHandle.standardError.write(Data("Unexpected acceptance at fixture line \(line)\n".utf8))
            preconditionFailure("An invalid estimated calibration step was accepted")
        }
        catch { if let text { precondition(error.localizedDescription.contains(text),error.localizedDescription) } }
    }
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let model = try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
        let camera = UUID(), generation: UInt64 = 42, now = 2_000.0
        let cubeText = """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 0 0 1
        v 1 0 1
        v 1 1 1
        v 0 1 1
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
        let cube = try ROBEstimatedConvexHull(text:cubeText)
        let metricCases: [(SIMD3<Double>,Double)] = [([0.5,0.5,0.5],0),([1,0.5,0.5],0),
            ([1.1,0.5,0.5],0.1),([1.1,1.1,0.5],sqrt(0.02)),([1.1,1.1,1.1],sqrt(0.03))]
        let completeMargin = ROBEstimatedArmCalibrationPlan.obstacleInflationMeters+ROBWorkspaceCollisionPlan.sweptPointTravelMeters+sqrt(3)*0.025/2
        var rigid = simd_double4x4(simd_quatd(angle:0.63,axis:simd_normalize(SIMD3<Double>(1,2,-1))))
        rigid.columns.3 = SIMD4(0.23,-0.14,0.69,1)
        for (point,expected) in metricCases {
            let distance = try cube.distance(to:point)
            precondition(abs(distance-expected) < 1e-12 && distance <= completeMargin,
                "Occupied inside/near face, edge and corner queries must remain inside the veto margin")
            let rotatedWorld = rigid*SIMD4(point,1), recovered = simd_inverse(rigid)*rotatedWorld
            let recoveredDistance = try cube.distance(to:SIMD3(recovered.x,recovered.y,recovered.z))
            precondition(abs(recoveredDistance-expected) < 1e-12)
        }
        for malformed in ["",cubeText.replacingOccurrences(of:"f 1 3 2\n",with:""),cubeText+"\nf 1 3 2",
                          cubeText.replacingOccurrences(of:"f 1 3 2",with:"f 1 1 2"),
                          cubeText.replacingOccurrences(of:"f 1 3 2",with:"f 1 3 99"),
                          cubeText.replacingOccurrences(of:"v 1 1 1",with:"v 0.4 0.4 0.4"),
                          cubeText.replacingOccurrences(of:"v 1 1 1",with:"v nan 1 1"),
                          cubeText.replacingOccurrences(of:"f 1 3 2",with:"f bad 3 2")] {
            blocked("malformed") { _ = try ROBEstimatedConvexHull(text:malformed) }
        }
        blocked { _ = try cube.distance(to:[.nan,0,0]) }
        blocked { _ = try cube.distance(to:[1e308,1e308,1e308]) }
        func grid(origin:SIMD3<Double> = [1.2,1.2,0.9], session:UInt64 = generation,
                  cameraID:UUID = camera, modelID:String? = nil, focalLength:Double = 100,
                  using selectedModel:ROBGhostRobotModel? = nil,projectionID:String? = nil) throws -> ROBWorkspaceCollisionSnapshot {
            let selected=selectedModel ?? model
            var builder = ROBWorkspaceDepthMap(modelID:modelID ?? selected.modelID,geometryID:selected.geometryID,
                mappingID:selected.selectedMappingID,sessionGeneration:session,cameraGeneration:cameraID,nowMilliseconds:now,
                estimatedCameraProjectionIdentity:projectionID)
            var transform = matrix_identity_double4x4; transform.columns.3 = SIMD4(origin,1)
            for (sequence,captured) in [(UInt64(1),1_900.0),(UInt64(2),1_950.0)] {
                try builder.append(width:16,height:16,fx:focalLength,fy:focalLength,cx:7.5,cy:7.5,depth:{ _,_ in 800 },cameraToRobot:transform,
                    capturedAtMilliseconds:captured,sequence:sequence,cameraGeneration:cameraID,nowMilliseconds:now,
                    estimatedCameraProjectionIdentity:projectionID)
            }
            return builder.snapshot(nowMilliseconds:now)!
        }
        func worldBounds(_ link:String,q:[Double]) throws -> (low:SIMD3<Double>,high:SIMD3<Double>) {
            let frame = model.frames(model.positions(vendorLeft:q))[link]!
            let text = try String(contentsOf:model.directory.appendingPathComponent(model.hulls[link]!),encoding:.utf8)
            let points = text.split(separator:"\n").compactMap { line -> SIMD3<Double>? in
                let fields = line.split(whereSeparator:\.isWhitespace)
                guard fields.first == "v", fields.count >= 4 else { return nil }
                let p = frame*SIMD4(Double(fields[1])!,Double(fields[2])!,Double(fields[3])!,1)
                return SIMD3(p.x,p.y,p.z)
            }
            return (points.reduce(points[0]) { simd_min($0,$1) },points.reduce(points[0]) { simd_max($0,$1) })
        }
        let map = try grid(), zero = [Double](repeating:0,count:7)
        precondition(map.registrationID == nil && map.observedFrameCount == 2 && map.occupiedVoxelCount > 0)
        let plan = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:map,model:model,generation:generation,
            cameraGeneration:camera,nowMilliseconds:now)
        precondition(plan.steps.count == 1 && plan.step.jawAction == nil && plan.seconds == 4 && plan.target == [0.10,0.025,-0.075,0,0,0,0])
        precondition(plan.registrationMode == "estimated_urdf_prior" && plan.estimatedInflationMeters == 0.15)
        precondition(plan.maximumVertexDisplacementMeters <= 0.06 && plan.maximumVertexDisplacementMeters > 0.03 && (61...62).contains(plan.checkedPoseCount))
        precondition(plan.unknownVoxelCount > 0 && !plan.unknownLocalRegions.isEmpty && !plan.baselineSelfProxyPairs.isEmpty)
        precondition(map.registrationID == nil,"An estimate manufactured measured registration")
        try plan.validateContext(map:map,model:model,generation:generation,cameraGeneration:camera,nowMilliseconds:now+1)
        try plan.validate(map:map,model:model,generation:generation,cameraGeneration:camera,nowMilliseconds:now+1)
        let decoded = try JSONDecoder().decode(ROBEstimatedArmCalibrationPlan.self,from:JSONEncoder().encode(plan))
        precondition(decoded == plan)
        let regionLinks = plan.unknownLocalRegions.map(\.link)
        precondition(regionLinks == regionLinks.sorted() && !regionLinks.contains("left_base_link"))
        precondition(regionLinks.contains("left_one_Link"),"An actuated link stationary along J2 alone lost its depth veto")
        let repeated = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:map,model:model,generation:generation,
            cameraGeneration:camera,nowMilliseconds:now)
        precondition(repeated.unknownLocalRegions == plan.unknownLocalRegions && repeated.unknownVoxelCount == plan.unknownVoxelCount)
        // This narrow observed patch hits only the fixed mount's former
        // inflated envelope; all actuated-link envelopes remain independently
        // checked against the same unmodified occupied grid.
        let fixedMountObstacle = try grid(origin:[-0.05,-0.1875,0.05],focalLength:1_000)
        let fixedFingerprint = fixedMountObstacle.fingerprint, fixedOccupied = Set(fixedMountObstacle.occupiedVoxels)
        let fixedCell = ROBWorkspaceVoxel(x:-2,y:-7,z:34)
        precondition(fixedOccupied.contains(fixedCell))
        let mount = try worldBounds("left_base_link",q:zero)
        let mountPadding = ROBEstimatedArmCalibrationPlan.obstacleInflationMeters+ROBWorkspaceCollisionPlan.sweptPointTravelMeters+sqrt(3)*fixedMountObstacle.voxelSizeMeters/2
        let mountLow = mount.low-SIMD3(repeating:mountPadding)
        let mountHigh = mount.high+SIMD3(repeating:mountPadding)
        let fixedCenter = fixedCell.center(voxelSizeMeters:fixedMountObstacle.voxelSizeMeters)
        precondition((0..<3).allSatisfy { mountLow[$0] <= fixedCenter[$0] && fixedCenter[$0] <= mountHigh[$0] },
            "The fixed-only occupied patch must exercise the mount's former inflated-depth veto")
        let fixedMountPlan = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:fixedMountObstacle,model:model,generation:generation,
            cameraGeneration:camera,nowMilliseconds:now)
        precondition(fixedMountObstacle.fingerprint == fixedFingerprint && Set(fixedMountObstacle.occupiedVoxels) == fixedOccupied)
        precondition(fixedMountPlan.unknownLocalRegions == plan.unknownLocalRegions)
        // AABB corner padding previously treated this surface as too close,
        // although its true distance to the conservative hull AABB exceeds
        // the entire spherical inflation (including voxel and sweep padding).
        let cornerObstacle = try grid(origin:[-0.30,-0.10,0.375],focalLength:1_000)
        let cornerCell = ROBWorkspaceVoxel(x:-12,y:-4,z:47)
        precondition(cornerObstacle.occupiedVoxels.contains(cornerCell))
        let cornerCenter = cornerCell.center(voxelSizeMeters:cornerObstacle.voxelSizeMeters)
        let shoulder = try worldBounds("left_one_Link",q:zero)
        let cornerGap = simd_max(SIMD3<Double>.zero,simd_max(shoulder.low-cornerCenter,cornerCenter-shoulder.high))
        precondition((0..<3).allSatisfy { cornerGap[$0] <= mountPadding } && simd_length(cornerGap) > mountPadding,
            "Corner fixture must lie inside axis padding but outside rounded padding")
        let cornerFingerprint = cornerObstacle.fingerprint, cornerOccupied = Set(cornerObstacle.occupiedVoxels)
        let cornerPlan = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:cornerObstacle,model:model,generation:generation,
            cameraGeneration:camera,nowMilliseconds:now)
        precondition(cornerPlan.checkedPoseCount >= 61)
        precondition(cornerObstacle.fingerprint == cornerFingerprint && Set(cornerObstacle.occupiedVoxels) == cornerOccupied)
        let reportedBaseline = [0.000681769239060285,0.008863000107783705,0,-0.002181661564992912,
            0.001908953869368798,0.0020453077171808547,0.000272707695624114]
        let reportedPoint = SIMD3<Double>(0.2125,0.0125,0.7875)
        let upperArmText = try String(contentsOf:model.directory.appendingPathComponent(model.hulls["left_two_Link"]!),encoding:.utf8)
        let upperArm = try ROBEstimatedConvexHull(text:upperArmText)
        var exactDistances: [Double] = []
        for sample in 0...11 {
            var q = reportedBaseline; q[1] += 0.035*Double(sample)/11
            let frame = model.frames(model.positions(vendorLeft:q))["left_two_Link"]!
            let local = simd_inverse(frame)*SIMD4(reportedPoint,1)
            let distance = try upperArm.distance(to:SIMD3(local.x,local.y,local.z))
            precondition(distance > completeMargin)
            exactDistances.append(distance)
        }
        precondition(abs(exactDistances[0]-0.23474931394830523) < 1e-9,
            "Reported table voxel needs nearest triangle-face distance, not vertex-only or AABB distance")
        let reportedObstacle = try grid(origin:[0.2125,0.0125,-0.0125],focalLength:1_000)
        let reportedOccupied = Set(reportedObstacle.occupiedVoxels), reportedFingerprint = reportedObstacle.fingerprint
        precondition(reportedOccupied.contains(ROBWorkspaceVoxel(x:8,y:0,z:31)))
        let reportedPlan = try ROBEstimatedArmCalibrationPlan.make(from:reportedBaseline,map:reportedObstacle,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now)
        precondition(reportedPlan.checkedPoseCount >= 61)
        precondition(Set(reportedObstacle.occupiedVoxels) == reportedOccupied && reportedObstacle.fingerprint == reportedFingerprint)
        let closeImproving = try grid(origin:[0.1875,0.2625,0.0125],focalLength:1_000_000)
        let closeFingerprint = closeImproving.fingerprint, closeOccupied = Set(closeImproving.occupiedVoxels)
        let retreat = try ROBEstimatedArmCalibrationPlan.make(from:reportedBaseline,map:closeImproving,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now)
        precondition(!retreat.baselineCloseOccupiedPairs.isEmpty)
        precondition(retreat.baselineCloseOccupiedPairs.allSatisfy { pair in
            let jaw = pair.link == "left_tool" ? ROBWorkspaceCollisionPlan.openJawAdditionalMarginMeters : 0
            return pair.baselineDistanceMeters >= 0.10+jaw && pair.finalDistanceMeters > pair.baselineDistanceMeters
        })
        try retreat.validate(map:closeImproving,model:model,generation:generation,cameraGeneration:camera,nowMilliseconds:now)
        precondition(closeImproving.fingerprint == closeFingerprint && Set(closeImproving.occupiedVoxels) == closeOccupied)
        let closeWorsening = try grid(origin:[-0.0375,0.5125,-0.4375],focalLength:1_000_000)
        blocked("moves toward") { _ = try ROBEstimatedArmCalibrationPlan.make(from:reportedBaseline,map:closeWorsening,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        let newlyClose = try grid(origin:[-0.0375,0.5375,-0.4375],focalLength:1_000_000)
        blocked("occupied depth-grid") { _ = try ROBEstimatedArmCalibrationPlan.make(from:reportedBaseline,map:newlyClose,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        let insideLocal = upperArm.vertices.reduce(SIMD3<Double>.zero,+)/Double(upperArm.vertices.count)
        let insideWorld4 = model.frames(model.positions(vendorLeft:reportedBaseline))["left_two_Link"]!*SIMD4(insideLocal,1)
        let projectionID=String(repeating:"a",count:64)
        let insideMap = try grid(origin:[insideWorld4.x,insideWorld4.y,insideWorld4.z-0.8],focalLength:1_000_000,projectionID:projectionID)
        let insideFingerprint=insideMap.fingerprint,insideOccupied=Set(insideMap.occupiedVoxels)
        do {
            _ = try ROBEstimatedArmCalibrationPlan.make(from:reportedBaseline,map:insideMap,model:model,
                generation:generation,cameraGeneration:camera,nowMilliseconds:now)
            preconditionFailure("A rejected occupied start unexpectedly produced a motion proof")
        } catch let rejection as ROBEstimatedArmCollisionRejection {
            let evidence=rejection.evidence
            precondition(rejection.localizedDescription.contains("100mm") && evidence.stage=="baseline_occupied_clearance")
            precondition(evidence.estimatedCameraProjectionIdentity==projectionID && evidence.mapFingerprint==insideFingerprint && evidence.sceneID==insideMap.sceneID)
            precondition(evidence.baseline==reportedBaseline && evidence.positions==reportedBaseline && evidence.sampleIndex==0)
            precondition(evidence.hullDistanceMeters<evidence.requiredDistanceMeters && evidence.requiredDistanceMeters==0.10+evidence.jawAdditionalMarginMeters && evidence.estimatedInflationMeters==0.15)
            let world=SIMD3(evidence.voxelCenterMeters[0],evidence.voxelCenterMeters[1],evidence.voxelCenterMeters[2])
            precondition(insideMap.state(at:world) == .occupied && evidence.nearestHullSurfacePointMeters != nil && evidence.observedReturnBoundsLowMeters != nil)
            let frame=model.frames(model.positions(vendorLeft:reportedBaseline))[evidence.link]!,local=simd_inverse(frame)*SIMD4(world,1)
            let exactHull=try ROBEstimatedConvexHull(text:String(contentsOf:model.directory.appendingPathComponent(model.hulls[evidence.link]!),encoding:.utf8))
            let exactDistance=try exactHull.distance(to:SIMD3(local.x,local.y,local.z))
            precondition(abs(exactDistance-evidence.hullDistanceMeters)<1e-12,"Rejection diagnostics changed the existing metric")
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("rob-rejected-collision-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:directory)}
            let exported=try rejection.export(map:insideMap,to:directory)
            let report=try JSONSerialization.jsonObject(with:Data(contentsOf:exported))as![String:Any]
            precondition(report["motionAuthority"]as?Bool==false && report["sourceFramesNotRetained"]as?Bool==true &&
                report["boundingSpheresUsedForAdmission"]as?Bool==false && report["rejectionIsGlobalMinimum"]as?Bool==false)
            let mapFile=directory.appendingPathComponent(report["mapFile"]as!String),mapBytes=try Data(contentsOf:mapFile)
            let hash=SHA256.hash(data:mapBytes).map{String(format:"%02x",$0)}.joined()
            precondition(hash==report["mapSHA256"]as?String)
            let saved=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:mapBytes)
            precondition(saved.fingerprint==insideFingerprint && Set(saved.occupiedVoxels)==insideOccupied && saved.observations.count==2 && saved.estimatedCameraProjectionIdentity==projectionID)
            precondition(saved.registrationID==nil && insideMap.registrationID==nil && insideMap.fingerprint==insideFingerprint && Set(insideMap.occupiedVoxels)==insideOccupied,
                "Diagnostic export modified or promoted the rejected scene")
            let permissions=try FileManager.default.attributesOfItem(atPath:exported.path)[.posixPermissions]as!NSNumber
            precondition(permissions.intValue&0o777==0o600)
            blocked("another scene") {_ = try rejection.export(map:map,to:directory.appendingPathComponent("wrong-map"))}
            precondition(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("wrong-map").path))
            print("Rejected-start evidence: exact cell/link/hull metric and photo projection identity, complete immutable map/hash/private export; no source-frame claim, motion authority or map mutation")
        }
        var alteredRetreat = try JSONSerialization.jsonObject(with:JSONEncoder().encode(retreat)) as! [String:Any]
        alteredRetreat["baselineCloseOccupiedPairs"] = []
        let missingPairs = try JSONDecoder().decode(ROBEstimatedArmCalibrationPlan.self,from:JSONSerialization.data(withJSONObject:alteredRetreat))
        blocked("changed") { try missingPairs.validate(map:closeImproving,model:model,generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        let withinMarginObstacle = try grid(origin:[-0.10,-0.08,0.18],focalLength:1_000)
        let withinCell = ROBWorkspaceVoxel(x:-4,y:-4,z:39)
        precondition(withinMarginObstacle.occupiedVoxels.contains(withinCell))
        let withinCenter = withinCell.center(voxelSizeMeters:withinMarginObstacle.voxelSizeMeters)
        let withinGap = simd_max(SIMD3<Double>.zero,simd_max(shoulder.low-withinCenter,withinCenter-shoulder.high))
        precondition(simd_length(withinGap) < mountPadding)
        blocked("left_one_Link") { _ = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:withinMarginObstacle,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        blocked("fixed-vector") { _ = try ROBEstimatedArmCalibrationPlan.make(from:plan.target,map:map,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        for value in [0.026,1e300,Double.nan] {
            var bad = zero; bad[0] = value
            blocked { _ = try ROBEstimatedArmCalibrationPlan.make(from:bad,map:map,model:model,generation:generation,
                cameraGeneration:camera,nowMilliseconds:now) }
        }
        var settledUndertravel = plan.target; settledUndertravel[0] -= 0.002
        precondition(settledUndertravel[0] > ROBEstimatedArmCalibrationPlan.hangingToleranceRadians)
        blocked { _ = try ROBEstimatedArmCalibrationPlan.make(from:settledUndertravel,map:map,model:model,generation:generation,
            cameraGeneration:camera,nowMilliseconds:now) }
        blocked("stale") { try plan.validateContext(map:map,model:model,generation:generation,cameraGeneration:camera,nowMilliseconds:62_001) }
        blocked("another") { try plan.validateContext(map:map,model:model,generation:generation+1,cameraGeneration:camera,nowMilliseconds:now) }
        blocked("another") { try plan.validateContext(map:map,model:model,generation:generation,cameraGeneration:UUID(),nowMilliseconds:now) }
        let wrongModel = try grid(modelID:"wrong-model")
        blocked("another") { _ = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:wrongModel,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        let occupied = try grid(origin:[0.30,0.25,0.05])
        let occupiedRetreat = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:occupied,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now)
        precondition(!occupiedRetreat.baselineCloseOccupiedPairs.isEmpty && occupiedRetreat.baselineCloseOccupiedPairs.allSatisfy {
            let jaw = $0.link == "left_tool" ? ROBWorkspaceCollisionPlan.openJawAdditionalMarginMeters : 0
            return $0.baselineDistanceMeters >= 0.10+jaw && $0.finalDistanceMeters > $0.baselineDistanceMeters
        },"The old table plane may qualify only through recorded, improving baseline-close pairs")
        var independentlyVerifiedHulls: [String:ROBEstimatedConvexHull] = [:]
        for pair in occupiedRetreat.baselineCloseOccupiedPairs where independentlyVerifiedHulls[pair.link] == nil {
            let text = try String(contentsOf:model.directory.appendingPathComponent(model.hulls[pair.link]!),encoding:.utf8)
            independentlyVerifiedHulls[pair.link] = try .init(text:text)
        }
        var independentFirst: [Double] = [], independentPrevious: [Double] = []
        for sample in 0..<occupiedRetreat.checkedPoseCount {
            let fraction = Double(sample)/Double(occupiedRetreat.checkedPoseCount-1)
            let q = zip(occupiedRetreat.baseline,occupiedRetreat.target).map { $0+($1-$0)*fraction }
            let frames = model.frames(model.positions(vendorLeft:q))
            for (index,pair) in occupiedRetreat.baselineCloseOccupiedPairs.enumerated() {
                let world = pair.voxel.center(voxelSizeMeters:occupied.voxelSizeMeters)
                let local = simd_inverse(frames[pair.link]!)*SIMD4(world,1)
                let actual = try independentlyVerifiedHulls[pair.link]!.distance(to:SIMD3(local.x,local.y,local.z))
                let jaw = pair.link == "left_tool" ? ROBWorkspaceCollisionPlan.openJawAdditionalMarginMeters : 0
                precondition(actual >= 0.10+jaw)
                if sample == 0 {
                    independentFirst.append(actual); independentPrevious.append(actual)
                    precondition(abs(actual-pair.baselineDistanceMeters) < 1e-12)
                } else {
                    precondition(actual+1e-9 >= independentPrevious[index],"Every occupied pair must independently recede at each pose")
                    independentPrevious[index] = actual
                }
                if sample == occupiedRetreat.checkedPoseCount-1 {
                    precondition(actual > independentFirst[index]+1e-9 && abs(actual-pair.finalDistanceMeters) < 1e-12)
                }
            }
        }
        // Actuated upstream links retain the same floor and monotonic checks.
        let upstreamObstacle = try grid(origin:[-0.10,-0.08,0.18],focalLength:1_000)
        blocked("left_one_Link") { _ = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:upstreamObstacle,model:model,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        let replacement = try grid()
        blocked("changed") { try plan.validateContext(map:replacement,model:model,generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        func tampered(_ key:String,_ value:Any) throws -> ROBEstimatedArmCalibrationPlan {
            var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
            object[key] = value
            return try JSONDecoder().decode(ROBEstimatedArmCalibrationPlan.self,from:JSONSerialization.data(withJSONObject:object))
        }
        for (key,value) in [("seconds",3.0 as Any),("estimatedInflationMeters",0.14 as Any),
                            ("maximumVertexDisplacementMeters",0.061 as Any),("unknownVoxelCount",-1 as Any),
                            ("registrationMode","measured" as Any),("target",[0,0.06,0,0,0,0,0] as Any),
                            ("baseline",[0,0,0] as Any)] {
            let changed = try tampered(key,value)
            blocked { try changed.validate(map:map,model:model,generation:generation,cameraGeneration:camera,nowMilliseconds:now) }
        }
        let right=try ROBGhostRobotModel(directory:model.directory,physicalSide:"right")
        let rightMap=try grid(using:right)
        let rightPlan=try ROBEstimatedArmCalibrationPlan.make(from:zero,map:rightMap,model:right,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now)
        precondition(rightPlan.target==[-0.03,-0.03,0,0,0,0,0] && rightPlan.seconds==4 && rightPlan.step.jawAction==nil)
        precondition(abs(rightPlan.maximumVertexDisplacementMeters-0.02724768960042634)<1e-10 && rightPlan.maximumVertexDisplacementMeters<0.03)
        precondition(rightPlan.estimatedInflationMeters==0.15 && rightMap.registrationID==nil)
        precondition(rightPlan.baselineSelfProxyPairs.count==2 && rightPlan.baselineSelfProxyPairs.allSatisfy {
            ($0.finalHullSignedSeparationMeters ?? -.infinity)>($0.baselineHullSignedSeparationMeters ?? .infinity)
        })
        try rightPlan.validate(map:rightMap,model:right,generation:generation,cameraGeneration:camera,nowMilliseconds:now)
        // Historical table-cell regression. This is a geometry fixture, not a
        // fabricated live depth source or registration: the old J2 direction
        // moves toward this retained voxel; the two-joint retreat moves away.
        let tableCell=SIMD3<Double>(0.2125,-0.2625,0.5875),link="right_six_Link"
        let rightHull=try ROBEstimatedConvexHull(text:String(contentsOf:right.directory.appendingPathComponent(right.hulls[link]!),encoding:.utf8))
        func rightDistance(_ q:[Double]) throws->Double {
            let local=simd_inverse(right.frames(right.positions(vendorLeft:q))[link]!)*SIMD4(tableCell,1)
            return try rightHull.distance(to:SIMD3(local.x,local.y,local.z))
        }
        let startingDistance=try rightDistance(zero)
        let formerJ2Distance=try rightDistance([0,-0.039,0,0,0,0,0]),outwardDistance=try rightDistance(rightPlan.target)
        precondition(formerJ2Distance<startingDistance-0.0007)
        precondition(outwardDistance>startingDistance+0.008)
        blocked("fixed-vector") {_ = try ROBEstimatedArmCalibrationPlan.make(from:rightPlan.target,map:rightMap,model:right,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now)}
        let oldBodyIdentity=rightMap.bodyMotionIdentity
        ROBFixedHeadBodyMotionIdentity.invalidate()
        precondition(oldBodyIdentity != ROBFixedHeadBodyMotionIdentity.currentIdentity && rightMap.registrationID==nil)
        blocked("body moved") {try rightPlan.validateContext(map:rightMap,model:right,generation:generation,
            cameraGeneration:camera,nowMilliseconds:now)}
        let freshRightMap=try grid(using:right)
        _ = try ROBEstimatedArmCalibrationPlan.make(from:zero,map:freshRightMap,model:right,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now)
        print("RIGHT two-joint outward retreat: 27.248mm full-hull travel; old J2 approach versus new table-cell retreat checked; both self deficits improve; no jaw/chaining; unregistered scene rejected after body motion and fresh recapture accepted.")
        print("Estimated commissioning: one 4s EMPTY fixed-vector retreat, \(plan.maximumVertexDisplacementMeters)m maximum actual hull-vertex motion, \(plan.checkedPoseCount) swept poses, \(plan.unknownVoxelCount) explicitly local unknown voxels, \(plan.baselineSelfProxyPairs.count) monotonically improving proxy deficits")
        print("Unsafe/new occupied cells, stale/wrong scene-camera-session-model, altered/oversized proofs, malformed joints and blind repeat all rejected; no measured registration or actuator transport exists")
        print("Only the verified rigid torso mount omits incremental depth veto; its occupied cells remain intact. Actuated upstream and moving arm envelopes still reject occupied cells; local proof regions reconstruct deterministically.")
        print("Occupied AABB-corner cells outside rounded padding are accepted unchanged; occupied cells within the complete spherical margin still block the nudge.")
        print("Closed-convex exact hull: inside returns zero; face/edge/vertex and rotated queries preserve metric; malformed/open/degenerate/nonconvex hulls reject. Reported table voxel is \(exactDistances[0]*1000)mm from the verified hull and its unchanged occupied patch passes the complete path.")
        print("Retreat records \(retreat.baselineCloseOccupiedPairs.count) baseline-close pairs with >=100mm+jaw clearance and strict improvement; worsening, new deficits, inside/too-close cells and proof-pair tampering reject.")
    }
}
