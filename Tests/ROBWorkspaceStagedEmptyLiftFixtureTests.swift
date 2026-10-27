import Foundation
import simd

private struct SyntheticMap: ROBWorkspaceCollisionMap {
    let sceneID: UUID
    let cameraGeneration: UUID
    let sessionGeneration: UInt64
    let modelID: String
    let geometryID: String
    let mappingID: String
    var createdAtMilliseconds = 1_000.0
    var oldestCapturedAtMilliseconds = 1_000.0
    var lastCapturedAtMilliseconds = 1_000.0
    let voxelSizeMeters = 0.025
    var registrationID: String? = "isolated synthetic measured registration"
    var registrationUncertaintyMeters: Double? = 0
    var obstacleLow: SIMD3<Double>?
    var obstacleHigh: SIMD3<Double>?
    var observed = true
    var visualCalibrationScope: ROBWorkspaceVisualCalibrationMapScope? = nil
    var fingerprint: String {
        ROBGhostRobotModel.hash(Data("synthetic-map:\(obstacleLow.debugDescription):\(obstacleHigh.debugDescription):\(observed)".utf8))
    }
    func state(at point: SIMD3<Double>) -> ROBWorkspaceVoxelState {
        guard (0..<3).allSatisfy({ abs(point[$0]) <= 3 }) else { return .unknown }
        if let low = obstacleLow, let high = obstacleHigh, (0..<3).allSatisfy({ (low[$0]...high[$0]).contains(point[$0]) }) { return .occupied }
        return observed ? .free:.unknown
    }
    func state(inBoundsLow low:SIMD3<Double>,high:SIMD3<Double>) -> ROBWorkspaceVoxelState {
        guard observed, (0..<3).allSatisfy({ low[$0] >= -3 && high[$0] <= 3 }) else { return .unknown }
        if let a = obstacleLow, let b = obstacleHigh, (0..<3).allSatisfy({ low[$0] <= b[$0] && high[$0] >= a[$0] }) { return .occupied }
        return .free
    }
}

@main struct StagedEmptyLiftFixtures {
 static func blocked(_ text:String,_ body:()throws->Void) {
  do {try body();preconditionFailure("Invalid staged lift admitted")}catch{precondition(error.localizedDescription.contains(text),error.localizedDescription)}
 }
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
  let scene=UUID(),camera=UUID(),generation:UInt64=42,hash=ROBGhostRobotModel.hash(Data("staged-empty-lift-fixture".utf8))
  var map=SyntheticMap(sceneID:scene,cameraGeneration:camera,sessionGeneration:generation,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID)
  map.registrationID=nil;map.registrationUncertaintyMeters=nil
  map.visualCalibrationScope = .init(bodyMotionIdentity:"fixture",bodyContextIsCurrent:true,estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
  func trial(_ source:SyntheticMap,_ start:[Double])->ROBWorkspaceVisualCalibrationTrial {
   .init(receiptID:"fixture",receiptSHA256:hash,appSessionID:"fixture",command:"right_recycle_cans",canCount:8,summarySHA256:hash,authorizationContextIdentity:"fixture",sessionGeneration:generation,sceneID:scene,cameraGeneration:camera,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:source.fingerprint,bodyMotionIdentity:"fixture",estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,currentPoseIdentity:hash,baseline:start,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.05)
  }
  func review(_ start:[Double],source:SyntheticMap?=nil,age:Double=0,empty:Bool=true)throws->ROBWorkspaceStagedEmptyLift {
   let m=source ?? map
   return try ROBWorkspaceCollisionPlan.reviewStagedEmptyLift(from:start,map:m,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(m,start),measuredAtMilliseconds:1000-age,emptyTrialEligibility:empty,emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")
  }
  let start=[0.000409,-0.020453,0,0,0,0,0],hanging=Array(repeating:0.0,count:7)
  for q in [hanging,start] {
   let geometry=try ROBEmptyArmLiftGeometry.make(model:model,baseline:q)
   precondition(geometry.maximumInitialHorizontalTravelMeters<0.0003 && abs(geometry.liftedTip.z-geometry.initialTip.z-0.06)<0.0003)
   precondition(abs(geometry.rearwardTip.x-geometry.liftedTip.x+0.1)<0.0003 && geometry.finalTip.z-geometry.initialTip.z>0.159 && geometry.finalTip.x<geometry.initialTip.x-0.08)
   var previous=q
   for step in geometry.steps {
    let allowed=step.stage=="J1 rearward clearance" ? [0]:[1,3]
    precondition((0..<7).allSatisfy{allowed.contains($0) || step.positions[$0]==previous[$0]})
    precondition(step.jawAction==nil)
    previous=step.positions
   }
   let proof=try review(q)
   precondition(proof.steps==geometry.steps && proof.endpointProxyClearancesMeters.values.allSatisfy{$0>=0.03})
   let decoded=try JSONDecoder().decode(ROBWorkspaceStagedEmptyLift.self,from:JSONEncoder().encode(proof));precondition(decoded==proof)
   print("PASS staged modeled lift",proof.checkedPoseCount,"poses; initial horizontal mm",geometry.maximumInitialHorizontalTravelMeters*1000,"final delta m",geometry.finalTip-geometry.initialTip)
  }
  let proof=try review(start)
  for index in [0,4,9,15] {
   let q=index==0 ? proof.baseline:proof.steps[index-1].positions
   try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(proof,index:index,from:q,map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map,q),measuredAtMilliseconds:1000)
  }
  blocked("fresh measured hanging") {_=try review(start,age:251)}
  blocked("fresh measured hanging") {_=try review(start,empty:false)}
  blocked("fresh measured hanging") {_=try review([0.2,0,0,0,0,0,0])}
  var unseen=map;unseen.observed=false
  let unseenProof=try review(start,source:unseen)
  precondition(unseenProof.steps==proof.steps,"Unknown space changed the fixed lift geometry")
  let advisory=unseenProof.context.unknownSpaceAdvisory!
  precondition(advisory.kind=="operator_cleared_unknown_initial_empty_lift_not_observed_free")
  precondition(advisory.broadPhaseUnknownCellVisits>0 && !advisory.observedFreeInferred && !advisory.occupiedFilteringChanged)
  precondition(unseen.state(at:SIMD3(0,0,0)) == .unknown,"The lift must not relabel unknown cells")
  try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(unseenProof,index:0,from:start,map:unseen,model:model,
    generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(unseen,start),measuredAtMilliseconds:1000)
  let raised=proof.steps.last!.positions
  blocked("unobserved") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:raised,
    steps:[.init(positions:raised,seconds:0.8)],map:unseen,model:model,generation:generation,sceneID:scene,
    cameraGeneration:camera,nowMilliseconds:1000,trial:trial(unseen,raised))}
  var obstacle=map
  let endpoint=model.worldCollisionBounds(positions:model.positions(vendorLeft:proof.steps.last!.positions))[model.toolLink]!
  obstacle.obstacleLow=endpoint.low;obstacle.obstacleHigh=endpoint.high
  blocked("obstacle") {_=try review(start,source:obstacle)}
  obstacle.observed=false
  blocked("obstacle") {_=try review(start,source:obstacle)}
  var wrong=start;wrong[0]+=0.005
  blocked("start corridor") {try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(proof,index:0,from:wrong,map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map,wrong),measuredAtMilliseconds:1000)}
  blocked("frozen route") {try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(proof,index:16,from:start,map:map,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map,start),measuredAtMilliseconds:1000)}
  blocked("bounded relative distances") {_=try ROBEmptyArmLiftGeometry.make(model:model,baseline:start,initialRise:0.2)}
  // Independent verification uses every actual convex-hull vertex, including
  // intermediate subintervals absent from the enclosing-box sampler.
  var vertices:[String:[SIMD3<Double>]]=[:]
  for (link,path) in model.hulls where link.hasPrefix("right_") && (link.hasSuffix("_Link") || link==model.toolLink) {
   vertices[link]=try String(contentsOf:model.directory.appendingPathComponent(path),encoding:.utf8).split(separator:"\n").compactMap{line in
    let p=line.split(whereSeparator:\.isWhitespace)
    guard p.count>=4,p[0]=="v",let x=Double(p[1]),let y=Double(p[2]),let z=Double(p[3]) else{return nil};return SIMD3(x,y,z)
   }
  }
  precondition(vertices.count>=8)
  var previous=start,maxHop=0.0
  for step in proof.steps {
   let count=try ROBWorkspaceCollisionPlan.emptyLiftSampleCount(from:previous,to:step.positions,model:model)
   for interval in 0..<count {
    let t=Double(interval)/Double(count),from=model.frames(model.positions(vendorLeft:zip(previous,step.positions).map{$0+($1-$0)*t}))
    for sub in 1...8 {
     let u=(Double(interval)+Double(sub)/8)/Double(count),to=model.frames(model.positions(vendorLeft:zip(previous,step.positions).map{$0+($1-$0)*u}))
     for (link,points) in vertices {for p in points {let a=from[link]!*SIMD4(p,1),b=to[link]!*SIMD4(p,1);maxHop=max(maxHop,simd_length(SIMD3(b.x-a.x,b.y-a.y,b.z-a.z)))}}
    }
   }
   previous=step.positions
  }
  precondition(maxHop<=ROBWorkspaceCollisionPlan.sweptPointTravelMeters)
  print("PASS independent actual-hull sweep bound",maxHop,"m; initial UNKNOWN advisory, mixed occupied veto, ordinary UNKNOWN veto, start/empty/limits rejection; no hardware or transfer")
 }
}
