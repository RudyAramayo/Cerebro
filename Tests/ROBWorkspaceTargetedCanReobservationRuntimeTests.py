#!/usr/bin/env python3
"""Exercise production selected-arm recenter/ranking tail with bounded capture seams."""
from pathlib import Path
import importlib.util
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('can_candidates_fixture', ROOT/'Tests/ROBWorkspaceCanCandidatesRuntimeTests.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

FIXTURE = r'''
extension ROBWorkspaceCollisionSnapshot {func snapshot()->Self? {self}}
struct Anchor {let camera:UUID;func permitsCurrent(_ value:UUID)->Bool {value==camera}}
enum ROBWorkspaceDepthMapError:Error {case invalidFrame}
enum ROBArmRoutineError:Error {case blocked(String)}
struct Outcome {let views:[ROBWorkspaceView];let selection:ROBWorkspaceCanSelection?;let evidence:[[String:Any]];let reasons:[[String:Any]];let required:Bool;let exposures:Int}
@MainActor final class SearchFixture {
 __ACTUAL_SELECTOR__
 func exercise(side:String="right",mode:String="success",permission:Bool=true,baseline:Bool=true,canOnly:Bool=true,fixed:Bool=false)async throws->Outcome {
  ROBFixedHeadBodyMotionIdentity.currentIdentity="body";ROBAmberGatewayClient.shared.generation=1
  let model=ROBGhostRobotModel();model.physicalSide=side
  let vision=ROBArmRoutineVision.shared;vision.cameraGeneration=UUID()
  let camera=vision.cameraGeneration,scene=UUID(),now=Date().timeIntervalSince1970*1000
  let sceneCaptureAnchor=Anchor(camera:camera),sceneGatewayGeneration:UInt64=1,sceneBodyIdentity="body",estimatedProjectionIdentity:String?="projection"
  let context=ROBWorkspaceCanSceneIdentity(sceneID:scene,cameraGeneration:camera,sessionGeneration:1,bodyMotionIdentity:"body",modelID:"model",geometryID:"geometry",mappingID:"mapping",estimatedCameraProjectionIdentity:"projection")
  let oppositeY=side=="right" ? 0.25 : -0.25,selectedY = -oppositeY
  func object(_ y:Double,_ seq:UInt64,_ valid:Bool=true)->ROBWorkspaceLocatedObject {
   .init(target:.can,position:[0.5,y,0.8],confidence:0.8,capturedAt:now-2000+Double(seq)*10,sequence:seq,view:.init(panDegrees:0,upperTarget:6306),sections:.init(valid:valid,heightMeters:0.12,diameterMeters:0.066))
  }
  let initialY=mode=="already_reachable" ? selectedY:oppositeY
  var confirmedCanCandidates=ROBWorkspaceCanCandidateSet()
  confirmedCanCandidates.observe([object(initialY,1)],context:context,nowMilliseconds:now)
  confirmedCanCandidates.observe([object(initialY,2)],context:context,nowMilliseconds:now)
  var collisionMap:ROBWorkspaceCollisionSnapshot? = .init(sceneID:scene,cameraGeneration:camera,observations:[.init(sequence:1,capturedAtMilliseconds:now-1990),.init(sequence:2,capturedAtMilliseconds:now-1980)])
  var found:[ROBWorkspaceTarget:ROBWorkspaceLocatedObject]=[.can:object(initialY,2)]
  let requireDepth=true,targets:[ROBWorkspaceTarget]=canOnly ? [.can]:[.can,.orangeBucket]
  let fixedRegisteredView:ROBWorkspaceView?=fixed ? .init(panDegrees:0,upperTarget:6306):nil
  let q=Dictionary(uniqueKeysWithValues:(1...7).map{(side+"_joint\($0)",0.0)})
  let canReachBaseline:[String:Double]?=baseline ? q:nil
  var currentCanSightings:[ROBWorkspaceRecall.Sighting]=[]
  // Two left and two right boxes: the already confirmed can belongs to the
  // opposite arm, while the selected side needs new plane/shape evidence.
  for (x,y) in [(0.18,0.72),(0.28,0.55),(0.68,0.55),(0.77,0.72)] {
   currentCanSightings.append(.init(target:.can,view:.init(panDegrees:0,upperTarget:6306),box:[x-0.04,y-0.10,x+0.04,y+0.10],confidence:0.8,capturedAt:now-1000))
  }
  if mode=="stale_boxes" {currentCanSightings=currentCanSightings.map{.init(target:$0.target,view:$0.view,box:$0.box,confidence:$0.confidence,capturedAt:now-31000)}}
  var reachSelections:[[String:Any]]=[],localReachSelection:ROBWorkspaceCanSelection?,localReachSelectionRequired=false
  var locationConfirmation=ROBWorkspaceLocationConfirmation();_ = locationConfirmation.observe(object(initialY,1));_ = locationConfirmation.observe(object(initialY,2))
  var selectedCanMeasurement:ROBWorkspaceLocatedObject?=object(initialY,2)
  var evidence:[[String:Any]]=[],views:[ROBWorkspaceView]=[],exposures=0
  let boundedPan:((Double)->Double)?={max(-60,min(60,$0))}
  func permitsLocalCanShapePrior()throws->Bool {permission}
  func check()throws {}
  func requireSceneProjectionIdentity()throws {if model.projection != estimatedProjectionIdentity {throw ROBWorkspaceDepthMapError.invalidFrame}}
  func progress(_ message:String) {}
  func inspectWithRetry(_ view:ROBWorkspaceView)async throws {
   views.append(view)
   precondition(found[.can]==nil && selectedCanMeasurement==nil,"Old discovery ended fresh view before two exposures")
   let valid = mode != "all_invalid" && !(mode=="first_invalid" && views.count==1)
   let first=object(selectedY,UInt64(10+views.count*2),valid),second=object(selectedY,UInt64(11+views.count*2),valid)
   for (index,can) in [first,second].enumerated() {
    exposures+=1
    // The detector/depth seam supplies only genuine independently valid shapes;
    // the ACTUAL candidate tracker and location confirmation decide admission.
    confirmedCanCandidates.observe([can],context:context,nowMilliseconds:now)
    collisionMap!.observations.append(.init(sequence:can.sequence,capturedAtMilliseconds:can.capturedAt))
    if valid {
     let confirmed=locationConfirmation.observe(can)
     if index==0 {precondition(confirmed==nil,"One exposure reused old confirmation")}
     if let confirmed {found[.can]=confirmed}
    }
   }
   if mode=="source_changed" {vision.cameraGeneration=UUID()}
   if mode=="body_changed" {ROBFixedHeadBodyMotionIdentity.currentIdentity="changed"}
   if mode=="gateway_changed" {ROBAmberGatewayClient.shared.generation=2}
  }
  __ACTUAL_TARGETED_TAIL__
  return .init(views:views,selection:localReachSelection,evidence:evidence,reasons:reachSelections,required:localReachSelectionRequired,exposures:exposures)
 }
}
@main enum TargetedCanFixture {
 @MainActor static func main()async throws {
  let s=SearchFixture()
  for side in ["right","left"] {
   let first=try await s.exercise(side:side)
   precondition(first.required && first.views.count==1 && first.exposures==2 && first.selection?.object != nil)
   precondition(side=="right" ? first.views[0].panDegrees<0:first.views[0].panDegrees>0)
   precondition(first.reasons.count==2 && first.reasons[0]["path_admitted"]as?Bool==false)
   let second=try await s.exercise(side:side,mode:"first_invalid")
   precondition(second.views.count==2 && second.exposures==4 && second.selection?.object != nil)
  }
  let invalid=try await s.exercise(mode:"all_invalid")
  precondition(invalid.views.count==2 && invalid.selection?.object==nil,"Invalid geometry promoted by recenter")
  precondition(invalid.reasons.count==3 && invalid.evidence.allSatisfy{$0["path_admitted"]as?Bool==false})
  let already=try await s.exercise(mode:"already_reachable");precondition(already.views.isEmpty && already.selection?.object != nil)
  let stale=try await s.exercise(mode:"stale_boxes");precondition(stale.views.isEmpty && stale.selection?.object==nil)
  for mode in ["source_changed","body_changed","gateway_changed"] {
   do {_ = try await s.exercise(mode:mode);preconditionFailure("Context replacement admitted")}
   catch {precondition(error is ROBWorkspaceDepthMapError)}
  }
  for flags in [(false,true,true,false),(true,false,true,false),(true,true,false,false),(true,true,true,true)] {
   let x=try await s.exercise(permission:flags.0,baseline:flags.1,canOnly:flags.2,fixed:flags.3)
   precondition(!x.required && x.views.isEmpty,"Ordinary/fixed/unpermitted search changed")
  }
  print("PASS actual targeted recenter/ranking: two-left/two-right topology, selected-side first/second success, TWO advancing exposures, invalid geometry never promoted, <=2 views, stale hints/context/body/gateway veto, ordinary/fixed path unchanged; no motion authority")
 }
}
'''

def main():
    vision=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
    plan=(ROOT/'Cerebro/ROBWorkspaceSearchPlan.swift').read_text()
    stubs=base.STUBS.replace('struct ROBWorkspaceView: Codable {','struct ROBWorkspaceView: Codable, Equatable {')
    stubs=stubs.replace('let far=can.position[0]>0.8,orientation=', 'let far=can.position[0]>0.8 || (side=="right" && can.position[1]>0.1) || (side=="left" && can.position[1]<(-0.1)),orientation=')
    actual='\n'.join(base.block(vision,x) for x in ['struct ROBWorkspaceCanSceneIdentity:','struct ROBWorkspaceCanCandidateSet {','struct ROBWorkspaceCanSelection {','enum ROBWorkspaceCanRecenterPlan {'])
    actual+='\n'+'\n'.join(base.block(plan,x) for x in ['enum ROBWorkspaceTarget:','struct ROBWorkspaceLocatedObject:','struct ROBWorkspaceLocationConfirmation {'])
    actual+='\nenum ROBWorkspaceRecall {\n'+base.block(plan,'struct Sighting: Codable {')+'\n}'
    selection=base.block(vision,'@MainActor private func selectReachableCan(')
    tail=base.block(vision,'if requireDepth,targets == [.can],fixedRegisteredView==nil,let reachBaseline=canReachBaseline,')
    run=vision[vision.index('@MainActor @nonobjc func run(targets:'):]
    assert run.index('if requireDepth,targets == [.can],fixedRegisteredView==nil,let reachBaseline=canReachBaseline,')<run.index('// The fast object search need not see')
    assert '"nearest_reachable_can_selections":reachSelections' in run
    assert 'let noReachableCan=localReachSelectionRequired && localReachSelection?.object==nil' in run
    assert '"no_reachable_can"' in run and "a can with valid geometry and a reachable grasp" in run
    fixture=FIXTURE.replace('__ACTUAL_SELECTOR__',selection).replace('__ACTUAL_TARGETED_TAIL__',tail)
    with tempfile.TemporaryDirectory(prefix='rob-targeted-can-') as folder:
        p=Path(folder);swift=p/'fixture.swift';binary=p/'fixture'
        swift.write_text(stubs+'\n'+actual+'\n'+fixture)
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True,timeout=60)
        subprocess.run([str(binary)],check=True,timeout=30)

if __name__=='__main__':main()
