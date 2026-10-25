#!/usr/bin/env python3
"""Exercise actual retreat reviewer/checker with explicit synthetic rigid geometry."""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
STUBS=r'''
import Foundation
import simd
import CryptoKit
enum ROBGhostMotionError:LocalizedError {case blocked(String);var errorDescription:String? {switch self {case .blocked(let s):return s}}}
struct ROBLeftGestureProposal {enum JawAction:String,Codable {case grip,release};struct Step:Codable,Equatable {
    var positions:[Double];var seconds:Double;var jawAction:JawAction?=nil;var stage:String?=nil
}}
enum ROBArmJointLimits {static let radians=Array(repeating:(-3.0)...3.0,count:7)}
enum ROBArmRoutinePlan {
    static let tolerance=0.025
    static func near(_ a:[Double],_ b:[Double],tolerance:Double=0.025)->Bool {
        a.count==7 && b.count==7 && zip(a,b).allSatisfy{$0.isFinite && $1.isFinite && abs($0-$1)<=tolerance}
    }
}
enum ROBLeftArmInteractionPlan {
    static let frontIndex=0
    static func target(index:Int)->[Double]? {Array(repeating:0,count:7)}
    static func duration(from:[Double],to:[Double],padding:Double=0)->Double? {0.8}
}
final class ROBGhostRobotModel {
    struct Joint {let name:String;let lower:Double;let upper:Double}
    let physicalSide="right",armJointPrefix="right_joint",toolLink="right_tool"
    let modelID="synthetic model",selectedMappingID="synthetic mapping"
    let geometryID:String,directory:URL,hulls:[String:String]
    let armUprightPrior=Array(repeating:0.0,count:7)
    var mode="linear"
    var joints:[Joint] {(1...7).map{.init(name:"right_joint\($0)",lower:-3,upper:3)}}
    static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    init() {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-retreat-hulls-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let names=["one","two","three","four","five","six","seven"].map{"right_"+$0+"_Link"}+["right_tool","right_base_link","right_track_fixture_proxy","right_track_new_proxy"]
        var records:[[String:Any]]=[],paths:[String:String]=[:]
        for name in names {
            var low=SIMD3<Double>(repeating:-0.01),high=SIMD3<Double>(repeating:0.01)
            if name=="right_track_fixture_proxy" {low=SIMD3(-0.01,0,0.89);high=SIMD3(0.01,0.02,0.91)}
            if name=="right_track_new_proxy" {low=SIMD3(-0.01,-0.065,0.89);high=SIMD3(0.01,-0.055,0.91)}
            let p=[SIMD3(low.x,low.y,low.z),SIMD3(high.x,low.y,low.z),SIMD3(high.x,high.y,low.z),SIMD3(low.x,high.y,low.z),SIMD3(low.x,low.y,high.z),SIMD3(high.x,low.y,high.z),SIMD3(high.x,high.y,high.z),SIMD3(low.x,high.y,high.z)]
            let text=p.map{"v \($0.x) \($0.y) \($0.z)"}.joined(separator:"\n")+"\nf 1 3 2\nf 1 4 3\nf 5 6 7\nf 5 7 8\nf 1 2 6\nf 1 6 5\nf 4 8 7\nf 4 7 3\nf 1 5 8\nf 1 8 4\nf 2 3 7\nf 2 7 6\n"
            let data=Data(text.utf8),path=name+".obj";try! data.write(to:directory.appendingPathComponent(path));paths[name]=path
            records.append(["link":name,"hull":path,"hullSHA256":Self.hash(data)])
        }
        hulls=paths
        let data=try! JSONSerialization.data(withJSONObject:["modelID":modelID,"surfaces":records],options:.sortedKeys)
        geometryID=Self.hash(data);try! data.write(to:directory.appendingPathComponent("surfaces.json"))
    }
    deinit {try? FileManager.default.removeItem(at:directory)}
    func positions(vendorLeft q:[Double])->[String:Double] {Dictionary(uniqueKeysWithValues:zip((1...7).map{"right_joint\($0)"},q))}
    func frames(_ p:[String:Double])->[String:simd_double4x4] {
        let q=p["right_joint2",default:0];var output:[String:simd_double4x4]=[:]
        for (index,name) in ["one","two","three","four","five","six","seven"].enumerated() {
            var t=matrix_identity_double4x4;t.columns.3=SIMD4(1+Double(index)*0.1+(mode=="large_hull" && index==6 ? q:0),0,0.9,1)
            output["right_\(name)_Link"]=t
        }
        var tool=matrix_identity_double4x4
        let y=mode=="static" ? 0 : -0.5*q+(mode=="worsens_midway" ? 0.04*sin(.pi*q/0.1):0)
        tool.columns.3=SIMD4(0,y,0.9,1);output[toolLink]=tool;output["right_base_link"]=matrix_identity_double4x4;output["right_track_fixture_proxy"]=matrix_identity_double4x4
        if mode=="new_pair" {output["right_track_new_proxy"]=matrix_identity_double4x4}
        return output
    }
    func worldCollisionBounds(positions p:[String:Double])->[String:(low:SIMD3<Double>,high:SIMD3<Double>)] {
        var result:[String:(low:SIMD3<Double>,high:SIMD3<Double>)]=[:]
        for (name,t) in frames(p) {let c=SIMD3(t.columns.3.x,t.columns.3.y,t.columns.3.z);result[name]=(c-SIMD3(repeating:0.01),c+SIMD3(repeating:0.01))}
        result["right_track_fixture_proxy"]=(SIMD3(-0.01,0,0.89),SIMD3(0.01,0.02,0.91))
        if mode=="new_pair" {result["right_track_new_proxy"]=(SIMD3(-0.01,-0.065,0.89),SIMD3(0.01,-0.055,0.91))}
        return result
    }
    func treadSeparation(vendorLeft q:[Double])->Double {
        let b=worldCollisionBounds(positions:positions(vendorLeft:q));var minimum=Double.infinity
        for a in b.keys where a.hasSuffix("_Link") || a==toolLink {for t in b.keys where t.contains("track") {
            minimum=min(minimum,simd_length(simd_max(.zero,simd_max(b[a]!.low-b[t]!.high,b[t]!.low-b[a]!.high))))
        }};return minimum
    }
}
struct Map:ROBWorkspaceCollisionMap {
    let sceneID:UUID;let cameraGeneration:UUID;let sessionGeneration:UInt64=1
    let modelID="synthetic model",mappingID="synthetic mapping"
    let geometryID:String
    let createdAtMilliseconds=1000.0,oldestCapturedAtMilliseconds=1000.0,lastCapturedAtMilliseconds=1000.0,voxelSizeMeters=0.025
    let registrationID:String?=nil,registrationUncertaintyMeters:Double?=nil
    var state:ROBWorkspaceVoxelState = .free
    var fingerprint:String {String(repeating:"b",count:64)}
    var visualCalibrationScope:ROBWorkspaceVisualCalibrationMapScope? {
        .init(bodyMotionIdentity:"body",bodyContextIsCurrent:true,estimatedCameraProjectionIdentity:fingerprint,
            observationPoseIdentity:fingerprint,observedFrameCount:2)
    }
    func state(at point:SIMD3<Double>)->ROBWorkspaceVoxelState {state}
    func state(inBoundsLow low:SIMD3<Double>,high:SIMD3<Double>)->ROBWorkspaceVoxelState {state}
}
'''
FIXTURE=r'''
@main struct InitialRetreatFixtures {
    static func blocked(_ reason:String,_ work:()throws->Void) {
        do {try work();preconditionFailure("Unexpected retreat admission")}
        catch {precondition(error.localizedDescription.contains(reason),error.localizedDescription)}
    }
    static func main() throws {
        let model=ROBGhostRobotModel(),scene=UUID(),camera=UUID(),start=Array(repeating:0.0,count:7)
        var map=Map(sceneID:scene,cameraGeneration:camera,geometryID:model.geometryID);var goal=start;goal[1]=0.1
        func trial()->ROBWorkspaceVisualCalibrationTrial {
            let hash=map.fingerprint
            return .init(receiptID:"receipt",receiptSHA256:hash,appSessionID:"app",command:"right_recycle_cans",canCount:4,
                summarySHA256:hash,authorizationContextIdentity:"broker",sessionGeneration:1,sceneID:scene,cameraGeneration:camera,
                modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,mapFingerprint:map.fingerprint,
                bodyMotionIdentity:"body",estimatedCameraProjectionIdentity:hash,observationPoseIdentity:hash,currentPoseIdentity:hash,
                baseline:start,issuedAtMilliseconds:1000,expiresAtMilliseconds:2000,assumedSpatialErrorMeters:0.025)
        }
        func review(_ q:[Double]?=nil,eligible:Bool=true,source:String="local_first_attempt_no_arm_travel_or_task_grip",age:Double=0)throws->ROBWorkspaceInitialEmptyRetreat {
            try ROBWorkspaceCollisionPlan.reviewInitialEmptyVisualCalibrationRetreat(from:start,to:q ?? goal,map:map,model:model,
                generation:1,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial(),
                measuredAtMilliseconds:1000-age,emptyTrialEligibility:eligible,emptyStateEvidenceSource:source)
        }
        let proof=try review()
        precondition(proof.maximumHullTravelMeters>=0.05 && proof.maximumHullTravelMeters<=0.051)
        precondition(proof.endpointProxyClearancesMeters.values.min()!>=0.03)
        precondition(proof.step.seconds==4 && proof.step.jawAction==nil && proof.initialEmptyStateAssumed)
        try proof.validate(map:map,model:model,generation:1,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1001,
            trial:trial(),measuredAtMilliseconds:1001,measuredBaseline:start,emptyTrialEligibility:true,
            emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")
        let toolPath=model.directory.appendingPathComponent(model.hulls[model.toolLink]!)
        let originalHull=try Data(contentsOf:toolPath)
        try Data("tampered hull".utf8).write(to:toolPath)
        blocked("hash changed") {_=try review()}
        try originalHull.write(to:toolPath)

        // Fresh-start tolerance consumes the SAME60mm budget; it is not extra travel.
        var nearGoal=goal;nearGoal[1]=0.118
        let nearLimit=try review(nearGoal)
        precondition(nearLimit.maximumHullTravelMeters>0.059 && nearLimit.maximumHullTravelMeters<0.060)
        var tinyDrift=start;tinyDrift[6]=0.0006
        blocked("fresh measured start") {try nearLimit.validate(map:map,model:model,generation:1,sceneID:scene,cameraGeneration:camera,
            nowMilliseconds:1001,trial:trial(),measuredAtMilliseconds:1001,measuredBaseline:tinyDrift,emptyTrialEligibility:true,
            emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")}
        var corridorDrift=start;corridorDrift[6]=0.003
        blocked("fresh measured start") {try proof.validate(map:map,model:model,generation:1,sceneID:scene,cameraGeneration:camera,
            nowMilliseconds:1001,trial:trial(),measuredAtMilliseconds:1001,measuredBaseline:corridorDrift,emptyTrialEligibility:true,
            emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")}

        let encoded=try JSONEncoder().encode(proof);let decoded=try JSONDecoder().decode(ROBWorkspaceInitialEmptyRetreat.self,from:encoded);precondition(decoded==proof)
        blocked("EMPTY eligibility") {_=try review(eligible:false)}
        blocked("EMPTY eligibility") {_=try review(source:"jaw_release_inferred")}
        blocked("fresh measured hanging") {_=try review(age:251)}
        var tooLarge=goal;tooLarge[1]=0.201
        blocked("0.20 rad") {_=try review(tooLarge)}
        map.state = .unknown;blocked("unobserved") {_=try review()}
        map.state = .occupied;blocked("obstacle") {_=try review()};map.state = .free
        model.mode="worsens_midway";blocked("worsens pre-existing") {_=try review()}
        model.mode="new_pair";blocked("new self-proxy") {_=try review()}
        model.mode="large_hull";blocked("60 mm full-hull") {_=try review()}
        model.mode="static";blocked("nonworsening retreat") {_=try review()}
        model.mode="linear"
        var insufficient=goal;insufficient[1]=0.06
        blocked("nonworsening retreat") {_=try review(insufficient)}
        // A distinct proof cannot create an ordinary-route or target-contact exemption.
        blocked("nonworsening retreat") {_=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:start,
            steps:[proof.step],map:map,model:model,generation:1,sceneID:scene,cameraGeneration:camera,nowMilliseconds:1000,trial:trial())}
        var moved=start;moved[0]=0.005
        blocked("fresh measured start") {try proof.validate(map:map,model:model,generation:1,sceneID:scene,cameraGeneration:camera,
            nowMilliseconds:1001,trial:trial(),measuredAtMilliseconds:1001,measuredBaseline:moved,emptyTrialEligibility:true,
            emptyStateEvidenceSource:"local_first_attempt_no_arm_travel_or_task_grip")}
        print("PASS actual retreat reviewer+checker on synthetic rigid geometry: bounded50mm monotonically improving escape admitted; initial/midpath/newpair/fullhull/endpoint/unknown/occupied/freshness/eligibility and ordinary-lane regressions reject")
    }
}
'''

def main():
    with tempfile.TemporaryDirectory(prefix='rob-initial-retreat-runtime-') as folder:
        path=Path(folder);source=path/'Fixture.swift';binary=path/'fixture'
        source.write_text(STUBS+FIXTURE)
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',
            '/private/tmp/cerebro-swift-module-cache',str(ROOT/'Cerebro/ROBWorkspaceCollisionPlan.swift'),str(source),'-o',str(binary)],check=True,timeout=45)
        subprocess.run([str(binary)],check=True,timeout=15)

if __name__=='__main__':main()
