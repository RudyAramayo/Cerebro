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
    var sourceGroups:[ROBWorkspaceOccupiedSourceGroup]? = nil
    var provideRefinement=true
    var visualCalibrationScope: ROBWorkspaceVisualCalibrationMapScope? = nil
    var fingerprint: String {
        ROBGhostRobotModel.hash(Data("synthetic-map:\(obstacleLow.debugDescription):\(obstacleHigh.debugDescription):\(observed):\(sourceGroups.debugDescription):\(provideRefinement)".utf8))
    }
    var originalOccupiedSourceGroups:[ROBWorkspaceOccupiedSourceGroup]? {sourceGroups}
    func groups(at p:SIMD3<Double>)->[ROBWorkspaceOccupiedReturnBounds] {
        let cell=(0..<3).map{Int(floor(p[$0]/voxelSizeMeters))}
        return (sourceGroups ?? []).filter{g in (0..<3).allSatisfy{abs(g.sourceVoxel[$0]-cell[$0])<=1}}.map(\.bounds)
    }
    func occupiedSampleBounds(at p:SIMD3<Double>)->(low:SIMD3<Double>,high:SIMD3<Double>)? {
        let g=groups(at:p);guard !g.isEmpty else{return nil}
        var lo=SIMD3<Double>(repeating:.infinity),hi=SIMD3<Double>(repeating:-.infinity)
        for b in g {lo=simd_min(lo,SIMD3(b.lowMeters[0],b.lowMeters[1],b.lowMeters[2]));hi=simd_max(hi,SIMD3(b.highMeters[0],b.highMeters[1],b.highMeters[2]))}
        return(lo,hi)
    }
    func occupiedSampleSubBounds(at p:SIMD3<Double>)->[ROBWorkspaceOccupiedReturnBounds]? {provideRefinement ? groups(at:p):nil}
    func state(at point: SIMD3<Double>) -> ROBWorkspaceVoxelState {
        guard (0..<3).allSatisfy({ abs(point[$0]) <= 3 }) else { return .unknown }
        if let low = obstacleLow, let high = obstacleHigh, (0..<3).allSatisfy({ (low[$0]...high[$0]).contains(point[$0]) }) { return .occupied }
        if !groups(at:point).isEmpty {return .occupied}
        return observed ? .free:.unknown
    }
    func state(inBoundsLow low:SIMD3<Double>,high:SIMD3<Double>) -> ROBWorkspaceVoxelState {
        guard observed, (0..<3).allSatisfy({ low[$0] >= -3 && high[$0] <= 3 }) else { return .unknown }
        if let a = obstacleLow, let b = obstacleHigh, (0..<3).allSatisfy({ low[$0] <= b[$0] && high[$0] >= a[$0] }) { return .occupied }
        if sourceGroups != nil {return .occupied}
        return .free
    }
}

@main struct StagedEmptyLiftFixtures {
 static func blocked(_ text:String,_ body:()throws->Void) {
  do {try body();preconditionFailure("Invalid staged lift admitted")}catch{precondition(error.localizedDescription.contains(text),error.localizedDescription)}
 }
 static func main()throws {
  setbuf(stdout,nil)
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
  let scene=UUID(),camera=UUID(),generation:UInt64=42,hash=ROBGhostRobotModel.hash(Data("staged-empty-lift-fixture".utf8))
  var map=SyntheticMap(sceneID:scene,cameraGeneration:camera,sessionGeneration:generation,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID)
  map.registrationID=nil;map.registrationUncertaintyMeters=nil
  map.visualCalibrationScope = .init(bodyMotionIdentity:"fixture",bodyContextIsCurrent:true,estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,observedFrameCount:2)
  func trial(_ source:SyntheticMap,_ start:[Double],cameraAdvisory:Bool=false)->ROBWorkspaceVisualCalibrationTrial {
   .init(receiptID:"fixture",receiptSHA256:hash,appSessionID:"fixture",command:"right_recycle_cans",canCount:8,summarySHA256:hash,authorizationContextIdentity:"fixture",sessionGeneration:generation,sceneID:scene,cameraGeneration:camera,modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:source.fingerprint,bodyMotionIdentity:"fixture",estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,currentPoseIdentity:hash,baseline:start,issuedAtMilliseconds:1000,expiresAtMilliseconds:601000,assumedSpatialErrorMeters:0.05,operatorClearedCameraCollisionAdvisory:cameraAdvisory ? true:nil)
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
    precondition(step.jawAction==nil && step.seconds>=3.2)
    previous=step.positions
   }
   let proof=try review(q)
   precondition(proof.steps==geometry.steps && proof.endpointProxyClearancesMeters.values.allSatisfy{$0>=0.03})
   let decoded=try JSONDecoder().decode(ROBWorkspaceStagedEmptyLift.self,from:JSONEncoder().encode(proof));precondition(decoded==proof)
   print("PASS staged modeled lift",proof.checkedPoseCount,"poses; initial horizontal mm",geometry.maximumInitialHorizontalTravelMeters*1000,"final delta m",geometry.finalTip-geometry.initialTip)
  }
  let actual=[0.0,-0.0272707695624114,0,-0.01308996938995747,0,0,0]
  let firstBaseline=[0.0,-0.01949860023712415,0,0,0,0,0]
  let firstGoal=[0.0,-0.1282092619004997,0,-0.1435886966215985,0,0,0]
  let delta=zip(firstBaseline,firstGoal).map{$1-$0},length=delta.reduce(0.0){$0+$1*$1}
  let fraction=min(1,max(0,zip(zip(actual,firstBaseline),delta).reduce(0.0){$0+($1.0.0-$1.0.1)*$1.1}/length))
  let nearest=zip(firstBaseline,delta).map{$0+fraction*$1}
  let oldBound=1.5*zip(actual,nearest).reduce(0.0){$0+abs($1.0-$1.1)}
  let physicalBound=try model.maximumArmHullDisplacement(from:nearest,to:actual,openJawPadding:0.04)
  precondition(oldBound>0.003 && physicalBound<0.003)
  var far=nearest;far[3]-=0.08
  let rejected=try model.maximumArmHullDisplacement(from:nearest,to:far,openJawPadding:0.04)
  precondition(rejected>0.003)
  // Full-box displacement must cover every interior tool-box sample too.
  let a=model.frames(model.positions(vendorLeft:nearest))[model.toolLink]!,b=model.frames(model.positions(vendorLeft:actual))[model.toolLink]!
  let centerA=a*SIMD4<Double>(0,0,0,1),centerB=b*SIMD4<Double>(0,0,0,1)
  precondition(simd_distance(SIMD3(centerA.x,centerA.y,centerA.z),SIMD3(centerB.x,centerB.y,centerB.z))<=physicalBound+1e-9)
  print("PASS recorded tracking deviation: old lever bound",oldBound*1000,"mm; complete arm/open-jaw box bound",physicalBound*1000,"mm; actual excessive displacement rejected")
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
  #if DEBUG
  let readyGoal=try ROBCanRecyclingReadyPose.target(physicalSide:"right")
  precondition(readyGoal == [-0.2564815877344792,-1.6648804817852159,0,-0.9825658273336827,1.107465951929527,1.7111044361935033,0.46278495947412146])
  let readyProof=try ROBWorkspaceCollisionPlan.reviewStagedEmptyLift(from:start,map:map,model:model,generation:generation,
    sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map,start,cameraAdvisory:true),
    measuredAtMilliseconds:1000,emptyTrialEligibility:true,emptyStateEvidenceSource:"operator_declared_empty",operatorReadyPose:true)
  precondition(readyProof.steps.last!.positions==readyGoal && readyProof.operatorReadyPoseRevision==ROBCanRecyclingReadyPose.revision)
  precondition(readyProof.endpointProxyClearancesMeters.values.allSatisfy{$0>=0.03})
  var previousReady=start
  for (index,step) in readyProof.steps.enumerated() {
   precondition(step.jawAction==nil && step.seconds<=5 && step.seconds>=3.2)
   precondition(zip(previousReady,step.positions).allSatisfy{abs($0-$1)<=0.30 && abs($0-$1)/step.seconds<=ROBArmRoutinePlan.maximumAverageSpeed})
   try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(readyProof,index:index,from:previousReady,map:map,model:model,
     generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,
     trial:trial(map,previousReady,cameraAdvisory:true),measuredAtMilliseconds:1000)
   previousReady=step.positions
  }
  blocked("operator-cleared can campaign") {
   _=try ROBWorkspaceCollisionPlan.reviewStagedEmptyLift(from:start,map:map,model:model,generation:generation,
     sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map,start),measuredAtMilliseconds:1000,
     emptyTrialEligibility:true,emptyStateEvidenceSource:"operator_declared_empty",operatorReadyPose:true)
  }
  var alteredReady=readyProof;alteredReady.operatorReadyPoseRevision="changed"
  blocked("frozen route") {try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(alteredReady,index:0,from:start,map:map,
    model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,
    trial:trial(map,start,cameraAdvisory:true),measuredAtMilliseconds:1000)}
  blocked("frozen route") {try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(readyProof,index:0,from:start,map:map,
    model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1251,
    trial:trial(map,start,cameraAdvisory:true),measuredAtMilliseconds:1000)}
  var driftedReady=start;driftedReady[1]-=0.02
  blocked("start corridor") {try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(readyProof,index:0,from:driftedReady,map:map,
    model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,
    trial:trial(map,driftedReady,cameraAdvisory:true),measuredAtMilliseconds:1000)}
  let zeroReady=try ROBWorkspaceCollisionPlan.reviewStagedEmptyLift(from:hanging,map:map,model:model,generation:generation,
    sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map,hanging,cameraAdvisory:true),
    measuredAtMilliseconds:1000,emptyTrialEligibility:true,emptyStateEvidenceSource:"operator_declared_empty",operatorReadyPose:true)
  let recordedLag=[-0.000272707695624114,-0.009817477042468104,0,-0.008317584716535477,0.002318015412804969,0.009817477042468104,0.000272707695624114]
  let readyDelta=zeroReady.steps[0].positions
  let readyFraction=zip(recordedLag,readyDelta).reduce(0.0){$0+$1.0*$1.1}/readyDelta.reduce(0.0){$0+$1*$1}
  let readyNearest=readyDelta.map{$0*readyFraction}
  let recordedHullDeviation=try model.maximumArmHullDisplacement(from:readyNearest,to:recordedLag,openJawPadding:0.04)
  print("Recorded coordinated motor lag hull deviation mm",recordedHullDeviation*1000)
  precondition(recordedHullDeviation>0)
  try ROBWorkspaceCollisionPlan.checkReadyPoseFeedback(zeroReady,index:0,actual:recordedLag,model:model)
  // The aborting packet is not recorded after the monitor throws. Exercise
  // a larger synthetic phase lag as well as the last actual recorded packet.
  let phaseLag=recordedLag.map{$0*2},phaseNearest=readyNearest.map{$0*2}
  let phaseHullDeviation=try model.maximumArmHullDisplacement(from:phaseNearest,to:phaseLag,openJawPadding:0.04)
  precondition(phaseHullDeviation>0.003)
  try ROBWorkspaceCollisionPlan.checkReadyPoseFeedback(zeroReady,index:0,actual:phaseLag,model:model)
  for (index,step) in zeroReady.steps.enumerated() {
   let previous=index==0 ? zeroReady.baseline:zeroReady.steps[index-1].positions
   for fraction in [0.0,0.1,0.5,1.0] {
    let q=zip(previous,step.positions).map{$0+fraction*($1-$0)}
    try ROBWorkspaceCollisionPlan.checkReadyPoseFeedback(zeroReady,index:index,actual:q,model:model)
   }
  }
  var wrongDirection=hanging;wrongDirection[1]=0.04
  blocked("segment or motor bounds") {try ROBWorkspaceCollisionPlan.checkReadyPoseFeedback(zeroReady,index:0,actual:wrongDirection,model:model)}
  var overshoot=zeroReady.steps[0].positions;overshoot[5]+=0.04
  blocked("segment or motor bounds") {try ROBWorkspaceCollisionPlan.checkReadyPoseFeedback(zeroReady,index:0,actual:overshoot,model:model)}
  var invalid=hanging;invalid[0] = .nan
  blocked("segment or motor bounds") {try ROBWorkspaceCollisionPlan.checkReadyPoseFeedback(zeroReady,index:0,actual:invalid,model:model)}
  blocked("exact empty-arm scope") {try ROBWorkspaceCollisionPlan.checkReadyPoseFeedback(alteredReady,index:0,actual:start,model:model)}
  blocked("exact empty-arm scope") {try ROBWorkspaceCollisionPlan.checkReadyPoseFeedback(proof,index:0,actual:start,model:model)}
  let interruptedReady=[-0.000954476934684399,-0.022771092584613517,0,-0.019089538693687978,0.012817261694333358,0.02590723108429083,0.002454369260617026]
  let resumedReady=try ROBWorkspaceCollisionPlan.reviewStagedEmptyLift(from:interruptedReady,map:map,model:model,generation:generation,
    sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(map,interruptedReady,cameraAdvisory:true),
    measuredAtMilliseconds:1000,emptyTrialEligibility:true,emptyStateEvidenceSource:"operator_declared_empty",operatorReadyPose:true)
  precondition(resumedReady.baseline==interruptedReady && resumedReady.steps.last!.positions==readyGoal)
  print("PASS taught ready pose: recorded asynchronous progress, complete route and fresh interrupted-pose replan accepted; wrong direction, overshoot, stale feedback and changed scope rejected; no jaws")
  let interruptedStart=[0.0,-0.03941,0,-0.03082,0,0,0]
  precondition(ROBEmptyArmLiftGeometry.acceptsOperatorClearedInitialStart(interruptedStart))
  precondition(!ROBEmptyArmLiftGeometry.acceptsOperatorClearedInitialStart([0,-0.051,0,0,0,0,0]))
  precondition(!ROBEmptyArmLiftGeometry.acceptsOperatorClearedInitialStart([0.026,0,0,0,0,0,0]))
  blocked("fresh measured hanging") {_=try review(interruptedStart)}
  let interruptedProof=try ROBWorkspaceCollisionPlan.reviewStagedEmptyLift(from:interruptedStart,map:map,model:model,
    generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,
    trial:trial(map,interruptedStart,cameraAdvisory:true),measuredAtMilliseconds:1000,
    emptyTrialEligibility:true,emptyStateEvidenceSource:"operator_declared_empty")
  precondition(interruptedProof.baseline==interruptedStart && interruptedProof.steps.reduce(0,{$0+$1.seconds})<=60)
  print("PASS fresh interrupted-start lift with unchanged3mm execution corridor; minimum3.2seconds per segment")
  let cameraTrial=trial(obstacle,start,cameraAdvisory:true)
  precondition(cameraTrial.valid && cameraTrial.usesOperatorClearedCameraCollisionAdvisory)
  let cameraProof=try ROBWorkspaceCollisionPlan.reviewStagedEmptyLift(from:start,map:obstacle,model:model,generation:generation,
    sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:cameraTrial,measuredAtMilliseconds:1000,
    emptyTrialEligibility:true,emptyStateEvidenceSource:"operator_declared_empty")
  precondition(cameraProof.steps==proof.steps && cameraProof.initialSelfHypothesis==nil && cameraProof.initialMarginRetreats.isEmpty)
  let cameraAudit=cameraProof.context.cameraCollisionAdvisory!
  precondition(cameraAudit.occupiedBroadPhaseQueries>0 && !cameraAudit.rawMapModified && !cameraAudit.observedFreeInferred && !cameraAudit.collisionClearanceCertified)
  precondition(obstacle.state(inBoundsLow:endpoint.low,high:endpoint.high) == .occupied)
  try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(cameraProof,index:0,from:start,map:obstacle,model:model,
    generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:70000,
    trial:cameraTrial,measuredAtMilliseconds:70000)
  blocked("frozen route") {try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(cameraProof,index:0,from:start,map:obstacle,
    model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,
    trial:trial(obstacle,start),measuredAtMilliseconds:1000)}
  blocked("self-proxy") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:start,
    steps:[.init(positions:start,seconds:0.8)],map:obstacle,model:model,generation:generation,sceneID:scene,
    cameraGeneration:camera,nowMilliseconds:1000,trial:cameraTrial)}
  let advisoryPayload=ROBWorkspaceCarriedObject(measurementID:"fixture",centerInToolMeters:[0,0,0.05],halfExtentsMeters:[0.03,0.03,0.06])
  let carryProof=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:raised,
    steps:[.init(positions:raised,seconds:0.8)],map:obstacle,model:model,generation:generation,sceneID:scene,
    cameraGeneration:camera,nowMilliseconds:1000,trial:trial(obstacle,raised,cameraAdvisory:true),payload:advisoryPayload,carryingAtStart:true)
  precondition(carryProof.context.cameraCollisionAdvisory!.occupiedBroadPhaseQueries>0)
  let invalidPayload=ROBWorkspaceCarriedObject(measurementID:"fixture",centerInToolMeters:[0,0,0],halfExtentsMeters:[-1,0.03,0.06])
  blocked("payload") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:raised,
    steps:[.init(positions:raised,seconds:0.8)],map:obstacle,model:model,generation:generation,sceneID:scene,
    cameraGeneration:camera,nowMilliseconds:1000,trial:trial(obstacle,raised,cameraAdvisory:true),payload:invalidPayload,carryingAtStart:true)}
  let unseenCarry=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:raised,
    steps:[.init(positions:raised,seconds:0.8)],map:unseen,model:model,generation:generation,sceneID:scene,
    cameraGeneration:camera,nowMilliseconds:1000,trial:trial(unseen,raised,cameraAdvisory:true),payload:advisoryPayload,carryingAtStart:true)
  precondition(unseenCarry.context.cameraCollisionAdvisory!.unknownBroadPhaseQueries>0)
  var changed=try JSONSerialization.jsonObject(with:JSONEncoder().encode(cameraTrial)) as! [String:Any]
  changed["command"]="left_recycle_cans"
  let changedTrial=try JSONDecoder().decode(ROBWorkspaceVisualCalibrationTrial.self,from:JSONSerialization.data(withJSONObject:changed))
  precondition(!changedTrial.valid)
  print("PASS camera advisory retains occupied/UNKNOWN raw data, full lift geometry and payload validity; self collision and policy changes still reject")
  #else
  precondition(!trial(obstacle,start,cameraAdvisory:true).valid,"Release admitted camera advisory")
  #endif
  obstacle.observed=false
  blocked("obstacle") {_=try review(start,source:obstacle)}
  func pointGroup(_ p:SIMD3<Double>)->ROBWorkspaceOccupiedSourceGroup {
   .init(sourceVoxel:(0..<3).map{Int(floor(p[$0]/0.025))},bounds:.init(lowMeters:[p.x,p.y,p.z],highMeters:[p.x,p.y,p.z]))
  }
  let initialBox=model.worldCollisionBounds(positions:model.positions(vendorLeft:start))["right_four_Link"]!
  var selfMap=map;selfMap.sourceGroups=[pointGroup((initialBox.low+initialBox.high)/2)]
  let selfProof=try review(start,source:selfMap)
  let hypothesis=selfProof.initialSelfHypothesis!
  precondition(hypothesis.groups.count==1 && !hypothesis.measuredSelf && !hypothesis.rawMapModified && !hypothesis.collisionClearanceCertified)
  precondition(hypothesis.assumedAlignmentAllowanceMeters==0.05 && hypothesis.baseline==start)
  precondition(selfMap.originalOccupiedSourceGroups==selfMap.sourceGroups,"Raw self returns were erased")
  try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(selfProof,index:15,from:selfProof.steps[14].positions,
    map:selfMap,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,
    trial:trial(selfMap,selfProof.steps[14].positions),measuredAtMilliseconds:1000)
  var aggregateOnly=selfMap;aggregateOnly.provideRefinement=false
  blocked("obstacle") {_=try review(start,source:aggregateOnly)}
  var mixed=selfMap;mixed.obstacleLow=endpoint.low;mixed.obstacleHigh=endpoint.high
  blocked("obstacle") {_=try review(start,source:mixed)}
  var ordinary=map;ordinary.sourceGroups=[pointGroup((endpoint.low+endpoint.high)/2)]
  blocked("obstacle") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:raised,
    steps:[.init(positions:raised,seconds:0.8)],map:ordinary,model:model,generation:generation,sceneID:scene,
    cameraGeneration:camera,nowMilliseconds:1000,trial:trial(ordinary,raised))}
  print("PASS frozen initial self hypothesis; raw returns retained; mixed external, aggregate-only and ordinary-route obstacles still veto")
  let toolFrame=model.frames(model.positions(vendorLeft:start))[model.toolLink]!
  let toolVertices=try String(contentsOf:model.directory.appendingPathComponent(model.hulls[model.toolLink]!),encoding:.utf8)
    .split(separator:"\n").compactMap{line->SIMD3<Double>? in
     let fields=line.split(whereSeparator:\.isWhitespace)
     guard fields.count==4,fields[0]=="v",let x=Double(fields[1]),let y=Double(fields[2]),let z=Double(fields[3]) else{return nil}
     let p=toolFrame*SIMD4(x,y,z,1);return SIMD3(p.x,p.y,p.z)
    }
  let lowest=toolVertices.min{$0.z<$1.z}!
  var retreatMap=map;retreatMap.sourceGroups=[pointGroup(lowest-SIMD3(0,0,0.105))]
  let retreatProof=try review(start,source:retreatMap)
  precondition(!retreatProof.initialMarginRetreats.isEmpty)
  precondition(retreatProof.initialMarginRetreats.allSatisfy{$0.minimumReviewedClearanceMeters+1e-9 >= $0.initialClearanceMeters && $0.initialClearanceMeters >= $0.minimumRequiredClearanceMeters})
  try ROBWorkspaceCollisionPlan.reviewStagedEmptyLiftSegment(retreatProof,index:15,from:retreatProof.steps[14].positions,
    map:retreatMap,model:model,generation:generation,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,
    trial:trial(retreatMap,retreatProof.steps[14].positions),measuredAtMilliseconds:1000)
  var tooClose=map;tooClose.sourceGroups=[pointGroup(lowest-SIMD3(0,0,0.075))]
  blocked("obstacle") {_=try review(start,source:tooClose)}
  print("PASS initial mechanical-margin retreat moves away, restores full endpoint clearance and retains alignment/jaw/sweep allowances")
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
