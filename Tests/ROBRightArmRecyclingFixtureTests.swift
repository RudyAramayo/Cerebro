import Foundation
import simd

@main struct ROBRightArmRecyclingFixtures {
    static func main() throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Cerebro/Resources/ShadowPlanner")
        let left=try ROBGhostRobotModel(directory:directory)
        let right=try ROBGhostRobotModel(directory:directory,physicalSide:"right")
        precondition(left.physicalSide=="left" && right.physicalSide=="right")
        precondition(left.selectedMappingID==ROBGhostRobotModel.mappingID)
        precondition(right.selectedMappingID != left.selectedMappingID)
        precondition(right.armJointPrefix=="right_joint" && right.toolLink=="right_tool")
        let q=[0.16,-0.30,0.04,-0.03,0.02,-0.01,0.09]
        let pose=right.positions(vendorLeft:q)
        precondition(zip(right.vendorLeft(pose),q).allSatisfy {abs($0-$1)<1e-12})
        for i in 1...7 {
            precondition(pose["left_joint\(i)"]==right.reference["left_joint\(i)"])
            precondition(abs(pose["right_joint\(i)"]!-(q[i-1]+right.reference["right_joint\(i)"]!))<1e-12)
        }
        let changed=right.positions(vendorLeft:q.enumerated().map {$0.offset==0 ? $0.element+0.10 : $0.element})
        let before=right.frames(pose),after=right.frames(changed)
        precondition(simd_distance(SIMD3(before["right_tool"]!.columns.3.x,before["right_tool"]!.columns.3.y,before["right_tool"]!.columns.3.z),
            SIMD3(after["right_tool"]!.columns.3.x,after["right_tool"]!.columns.3.y,after["right_tool"]!.columns.3.z))>0.001)
        for column in 0..<4 {for row in 0..<4 {precondition(before["left_tool"]![column][row]==after["left_tool"]![column][row])}}
        let bounds=ROBWorkspaceCollisionPlan.jointBounds(model:right)
        for i in 0..<7 {
            let joint=right.joints.first {$0.name=="right_joint\(i+1)"}!
            precondition(bounds[i].lowerBound==max(ROBArmJointLimits.radians[i].lowerBound,joint.lower+right.armUprightPrior[i]))
            precondition(bounds[i].upperBound==min(ROBArmJointLimits.radians[i].upperBound,joint.upper+right.armUprightPrior[i]))
        }
        precondition(right.recyclingFrontTarget==[1.05,-0.60,0,0,0,0,0])
        precondition(right.recyclingFrontTarget != left.recyclingFrontTarget.map {-$0})
        precondition(ROBLeftCanReachCalibration.file(forPhysicalSide:"right") != ROBLeftCanReachCalibration.file)
        // Right FK/IK uses the actual right mount/chain. A left datum or a
        // right proposal cannot be accepted under the other mapping identity.
        let front=right.positions(vendorLeft:right.recyclingFrontTarget)
        let now=Date().timeIntervalSince1970*1000
        let can=ROBWorkspaceLocatedObject(target:.can,position:[0.40,-0.20,0.80],confidence:0.9,
            capturedAt:now,sequence:17,view:.init(panDegrees:0,upperTarget:6306))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("right-reach-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let base=folder.appendingPathComponent("can-reach.json")
        let old=ROBLeftCanReachCalibration(modelID:right.modelID,referenceID:right.referenceID,mappingID:right.selectedMappingID,
            translationMeters:[0.12,0,-0.05],source:"Historical provisional-frame tuning",bucketYawDegrees:20,bucketInwardMeters:0.0381)
        try JSONEncoder().encode(old).write(to:base)
        let legacyBytes=try Data(contentsOf:base)
        var registeredCan=can;registeredCan.registrationID="measured-view-A"
        let initialResidual=try ROBLeftCanReachCalibration.load(model:right,can:registeredCan,file:base,depthAlignment:nil)
        precondition(initialResidual == .zero)
        let initialYaw=try ROBLeftCanReachCalibration.loadBucketYaw(model:right,file:base,registrationID:"measured-view-A")
        precondition(initialYaw==0)
        let residual=try ROBLeftCanReachCalibration.saveRegisteredResidual(model:right,registrationID:"measured-view-A",
            regionLowMeters:[0.3,-0.4,0.6],regionHighMeters:[0.6,0,1],translationMeters:[0.01,-0.005,0.02],
            source:"Isolated operator correction",baseFile:base)
        let preservedBytes=try Data(contentsOf:base)
        precondition(residual != base && preservedBytes==legacyBytes)
        let scopedResidual=try ROBLeftCanReachCalibration.load(model:right,can:registeredCan,file:base,depthAlignment:nil)
        precondition(scopedResidual==SIMD3(0.01,-0.005,0.02))
        registeredCan.registrationID="measured-view-B"
        let otherRegistrationResidual=try ROBLeftCanReachCalibration.load(model:right,can:registeredCan,file:base,depthAlignment:nil)
        precondition(otherRegistrationResidual == .zero)
        let preview=try ROBCanGrabPreview.make(can:can,model:right,baseline:front,side:"right",now:now)
        precondition(preview.side=="right" && !preview.steps.isEmpty)
        for step in preview.steps {for i in 1...7 {precondition(step.pose["left_joint\(i)"]==front["left_joint\(i)"])}}
        let step=ROBLeftGestureProposal.Step(positions:right.recyclingFrontTarget,seconds:1)
        let proposal=ROBLeftGestureProposal(id:UUID(),name:"Right identity",kind:"workspace_collision",modelID:right.modelID,
            referenceID:right.referenceID,geometryID:right.geometryID,mappingID:right.selectedMappingID,sessionGeneration:1,
            baseline:right.recyclingFrontTarget,poses:[front],steps:[step])
        precondition(proposal.validForReplay(model:right) && !proposal.validForReplay(model:left))
        let camera=UUID(),generation:UInt64=51
        var depthMap=ROBWorkspaceDepthMap(modelID:right.modelID,geometryID:right.geometryID,mappingID:right.selectedMappingID,
            sessionGeneration:generation,cameraGeneration:camera,nowMilliseconds:now)
        for sequence in 1...2 {
            try depthMap.append(width:40,height:30,fx:100,fy:100,cx:20,cy:15,depth:{_,_ in 2000},
                cameraToRobot:matrix_identity_double4x4,capturedAtMilliseconds:now-100+Double(sequence*20),
                sequence:UInt64(sequence),cameraGeneration:camera,nowMilliseconds:now)
        }
        guard let snapshot=depthMap.snapshot(nowMilliseconds:now) else {preconditionFailure("Synthetic depth snapshot unavailable")}
        let proofStarted=ProcessInfo.processInfo.systemUptime
        let probe=try ROBEstimatedArmCalibrationPlan.make(from:Array(repeating:0,count:7),map:snapshot,model:right,
            generation:generation,cameraGeneration:camera,nowMilliseconds:now)
        print("RIGHT proof build seconds",ProcessInfo.processInfo.systemUptime-proofStarted)
        precondition(probe.target==[0,-0.039,0,0,0,0,0] && probe.seconds==4)
        precondition(probe.maximumVertexDisplacementMeters<=0.03 && probe.maximumVertexDisplacementMeters>0.029)
        precondition(probe.mappingID==right.selectedMappingID && probe.steps.count==1 && probe.step.jawAction==nil)
        precondition(!probe.baselineSelfProxyPairs.isEmpty)
        for pair in probe.baselineSelfProxyPairs {
            precondition(pair.armLink.hasPrefix("right_"))
            precondition(pair.finalHullSignedSeparationMeters!>pair.baselineHullSignedSeparationMeters!)
        }
        try probe.validate(map:snapshot,model:right,generation:generation,cameraGeneration:camera,nowMilliseconds:now+1)
        do {
            _ = try ROBEstimatedArmCalibrationPlan.make(from:probe.target,map:snapshot,model:right,generation:generation,
                cameraGeneration:camera,nowMilliseconds:now+1)
            preconditionFailure("An estimated right step chained from its endpoint")
        } catch is ROBGhostMotionError {}
        print("Right estimated probe: one 4-second EMPTY J2 -0.039 rad step, full-hull travel \(probe.maximumVertexDisplacementMeters*1000) mm, actual convex-hull self-clearance improves, occupied-depth checks retained; endpoint chaining rejected. No physical transport.")
        print("Right-arm model: actual right URDF/mount/tool, own reference/mapping, FK/IK, transport bounds, other-arm immobility and side-isolated calibration/replay pass.")
    }
}
