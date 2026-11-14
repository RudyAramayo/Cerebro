#!/usr/bin/env python3
"""Exercise the native grasp-source map reuse handoff without device APIs."""
from pathlib import Path
import subprocess,tempfile
from ROBSceneArmModeRefreshRuntimeTests import block
ROOT=Path(__file__).resolve().parents[1]
actual=block((ROOT/'Cerebro/ROBLeftArmTrial.swift').read_text(),'        func reusableSearchScene()')
source=r'''
import Foundation
struct ROBWorkspaceCollisionSnapshot {var sceneID=UUID(),cameraGeneration=UUID();var sessionGeneration:UInt64=1;var modelID="model",geometryID="geometry";var oldestCapturedAtMilliseconds=1000.0}
final class ROBWorkspaceSearch {static let shared=ROBWorkspaceSearch();var collisionSnapshot:ROBWorkspaceCollisionSnapshot?}
enum ROBWorkspaceCollisionPlan {static let maximumMapAgeMilliseconds=60_000.0}
struct Model {let modelID="model",geometryID="geometry"}
struct Vision {var cameraGeneration:UUID}
struct Sample {let positionsRadians=Array(repeating:NSNumber(value:0.3),count:7)}
enum Failure:Error {case invalidProof}
func exercise(age:Double,advisory:Bool,receipt:Bool,proof:Bool=true,fail:Bool=false,change:String="")throws->(Bool,Int) {
 let original=ROBWorkspaceCollisionSnapshot(),now=original.oldestCapturedAtMilliseconds+age
 var changed=original
 if change=="session" {changed.sessionGeneration=2}
 if change=="camera" {changed.cameraGeneration=UUID()}
 if change=="model" {changed.modelID="changed"}
 if change=="geometry" {changed.geometryID="changed"}
 ROBWorkspaceSearch.shared.collisionSnapshot=change=="missing" ? nil:changed
 let sceneCapturedForThisTask=change != "not_this_task",generation:UInt64=1,vision=Vision(cameraGeneration:original.cameraGeneration),model=Model()
 let activeCameraCollisionAdvisory=advisory,localReceiptCommand:String?=receipt ? "right_recycle_cans":nil
 var proofCalls=0
 func measured()throws->Sample {Sample()}
 func visualTrial(map:ROBWorkspaceCollisionSnapshot,model:Model,baseline:[Double])throws->String? {
  proofCalls+=1;precondition(map.sceneID==original.sceneID && baseline.count==7)
  if fail {throw Failure.invalidProof}
  return proof ? "validated_native_trial":nil
 }
 __ACTUAL__
 let result=try reusableSearchScene()
 if let result {precondition(result.sceneID==original.sceneID,"Source scene was fabricated or replaced")}
 return(result != nil,proofCalls)
}
@main enum Test {
 static func main()throws {
  let fresh=try exercise(age:59_000,advisory:false,receipt:false);precondition(fresh.0 && fresh.1==0)
  let ordinary=try exercise(age:65_000,advisory:false,receipt:true);precondition(!ordinary.0 && ordinary.1==0)
  let noReceipt=try exercise(age:65_000,advisory:true,receipt:false);precondition(!noReceipt.0 && noReceipt.1==0)
  let validated=try exercise(age:65_000,advisory:true,receipt:true);precondition(validated.0 && validated.1==1)
  let nilProof=try exercise(age:65_000,advisory:true,receipt:true,proof:false);precondition(!nilProof.0 && nilProof.1==1)
  do {_=try exercise(age:65_000,advisory:true,receipt:true,fail:true);preconditionFailure("Invalid live proof ignored")}
  catch Failure.invalidProof {}
  for change in ["session","camera","model","geometry","missing","not_this_task"] {
   let changed=try exercise(age:65_000,advisory:true,receipt:true,change:change);precondition(!changed.0 && changed.1==0)
  }
  print("PASS native source-map handoff: original scene retained only under the existing validated live advisory trial; normal60s limit, receipt/scope rejection and failed proof preserved. No hardware.")
 }
}
'''.replace('__ACTUAL__',actual)
with tempfile.TemporaryDirectory(prefix='rob-source-scene-') as folder:
 p=Path(folder);f=p/'Fixture.swift';binary=p/'fixture';f.write_text(source)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(f),'-o',str(binary)],check=True,timeout=45)
 subprocess.run([str(binary)],check=True,timeout=15)
