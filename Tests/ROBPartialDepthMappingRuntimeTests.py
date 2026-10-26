#!/usr/bin/env python3
"""Run actual frame-eligibility/settling methods with inert frames and a virtual clock."""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]

def block(source, marker):
    start=source.index(marker);index=source.index('{',start)+1;depth=1
    while depth:
        depth+=(source[index]=='{')-(source[index]=='}');index+=1
    return source[start:index]

SUPPORT=r'''
import Foundation
final class Clock {
 static var milliseconds=1_000_000.0
 static var tick:(()->Void)?
 static var cancelled=false
 static var latestVision:ROBArmRoutineVision?
 static var passiveChecks=0,stopAtPassiveCheck:Int?
}
struct Date {var timeIntervalSince1970:Double {Clock.milliseconds/1000}}
struct ProcessInfo {static let processInfo=ProcessInfo();var systemUptime:Double {Clock.milliseconds/1000}}
enum Task {
 static func checkCancellation()throws {if Clock.cancelled {throw CancellationError()}}
 static func sleep(nanoseconds:UInt64)async throws {try checkCancellation();Clock.milliseconds+=Double(nanoseconds)/1_000_000;Clock.tick?()}
}
enum ROBArmRoutineError:LocalizedError {case blocked(String);var errorDescription:String? {if case .blocked(let s)=self{return s};return nil}}
struct Depth {var width=640,height=480}
__ACTUAL_IMU_TYPE__
struct K {
 var fx=490.0,fy=490.0,cx=320.0,cy=240.0
 var inertial:CameraInertialObservation?=nil
 __ACTUAL_K_VALIDITY__
}
final class ROBArmRoutineVision {
 struct Frame {
  var capturedAt:Double;var sequence:UInt64;var handsClear:Bool;var depthCoverage:Double
  var thumbnail:[UInt8];var depth:Depth?;var intrinsics:K?;var cameraGeneration:UUID
 }
 let lock=NSLock();var active=true,epoch=UUID(),cameraGeneration=UUID()
 var frames:[String:Frame]=[:]
 var lastSettlingDiagnostics:[String:Any]=[:]
 func healthSnapshot()->NSDictionary { ["input_age_ms":12.0,"analysis_age_ms":345.0,
  "analysis_ms":777.0,"note":"inert source cadence fixture","settling":lastSettlingDiagnostics] }
 __ACTUAL_METHODS__
 func ordinarySettled()async throws->Frame {try await settledInspectionFrame(epoch:inspectionEpoch())}
 func passiveObjectSettled()async throws->Frame {try await settledInspectionFrame(epoch:inspectionEpoch(),requireStaticScene:false,depthMappingOnly:true,allowStationaryIMUPassiveFrame:true)}
 func passiveObjectAdvancing(_ frame:Frame,after sequence:UInt64)->Bool {isDepthMappingEligible(frame) && frame.sequence>sequence}
}
final class Feed {
 let vision:ROBArmRoutineVision,mode:String,coverage:Double
 var sleeps=0,emitted=0
 init(_ mode:String,_ coverage:Double) {
  self.mode=mode;self.coverage=coverage;vision=ROBArmRoutineVision()
  Clock.latestVision=vision
  vision.frames["face"]=frame()
 }
 func frame()->ROBArmRoutineVision.Frame {
  var captured=Clock.milliseconds
  if mode=="stale" || mode.hasSuffix("_stale") {captured-=701}
  if mode=="future" {captured+=10_000}
  if mode=="retained" && emitted==0 {captured-=50}
  if mode.hasPrefix("slow_") && emitted==0 {captured-=50}
  if mode=="timestamp_reordered" && emitted==2 {captured-=250}
  let sequence:UInt64=mode=="sequence_reordered" && emitted==2 ? 19:UInt64(20+emitted)
  let gray:UInt8=mode=="changing" && emitted%2==1 ? 60:0
  var k=K();if mode=="invalid_k" || mode.hasSuffix("_invalid_k") {k.fx=0}
  if mode.contains("imu") {
   k.inertial = .init(sensor:"inert fixture",gravityMps2:[0,0,9.8],accelerationMps2:[0,0,9.8],gyroRadS:[0,0,0],
    sampleCount:mode.hasSuffix("_few_samples") ? 19:50,windowMilliseconds:mode.hasSuffix("_short_window") ? 299:500,
    latestTimestampNs:1_000,referenceTimestampNs:1_100,ageMilliseconds:mode.hasSuffix("_old_imu") ? 251:5,
    gravityStdMps2:[0.01,0.01,0.01],imuToRGBRotation:mode.hasSuffix("_invalid_rotation") ? [2,0,0,0,1,0,0,0,1]:[1,0,0,0,1,0,0,0,1],
    stationary:!mode.hasSuffix("_moving"),gravitySource:"stationary_accelerometer_mean",axes:"sensor_native")
  }
  return .init(capturedAt:captured,sequence:sequence,handsClear:mode != "human",
   depthCoverage:mode=="zero_depth" ? 0:coverage,thumbnail:[UInt8](repeating:gray,count:64*48*4),
   depth:mode=="missing_depth" ? nil:Depth(),intrinsics:mode=="missing_k" ? nil:k,
   cameraGeneration:mode=="wrong_source" || mode.hasSuffix("_wrong_source") ? UUID():vision.cameraGeneration)
 }
 func tick() {
  sleeps+=1
  if mode=="duplicate" {return}
  let interval=mode.hasPrefix("slow_") ? 24:mode=="gap_resets" ? 16:3
  guard sleeps%interval==0 else{return};emitted+=1
  if mode=="source_changed" {vision.cameraGeneration=UUID();vision.epoch=UUID()}
  if mode=="cancelled" {Clock.cancelled=true}
  vision.frames["face"]=frame()
 }
}
@main enum PartialDepthFixture {
 static func run(_ mode:String="normal",coverage:Double=0.18,mapping:Bool=true,passiveObject:Bool=false,
  passiveMapping:Bool=false,stopAtCheck:Int?=nil,deadlineSeconds:Double?=nil)async throws->(ROBArmRoutineVision.Frame,Feed,Double) {
  Clock.milliseconds=1_000_000;Clock.cancelled=false
  Clock.passiveChecks=0;Clock.stopAtPassiveCheck=stopAtCheck
  let feed=Feed(mode,coverage);Clock.tick={feed.tick()};defer{Clock.tick=nil}
  let start=Clock.milliseconds
  let result:ROBArmRoutineVision.Frame
  if passiveObject {result=try await feed.vision.passiveObjectSettled()}
  else if passiveMapping {
   result=try await feed.vision.settledPassiveMappingFrame(deadlineUptime:deadlineSeconds.map{ProcessInfo.processInfo.systemUptime+$0},check:{
    Clock.passiveChecks+=1;if Clock.stopAtPassiveCheck==Clock.passiveChecks {throw CancellationError()}
   })
  }
  else if mapping {result=try await feed.vision.settledDepthFrame(deadlineUptime:deadlineSeconds.map{ProcessInfo.processInfo.systemUptime+$0})}
  else {result=try await feed.vision.ordinarySettled()}
  return(result,feed,Clock.milliseconds-start)
 }
 static func rejected(_ mode:String,coverage:Double=0.18,mapping:Bool=true,contains:String?=nil)async {
  do {_=try await run(mode,coverage:coverage,mapping:mapping);preconditionFailure("Bad frame admitted: \(mode)")}
  catch {if let contains {precondition(error.localizedDescription.contains(contains),error.localizedDescription)}}
 }
 static func timeoutDiagnostics(_ mode:String,passiveObject:Bool=false,mapping:Bool=true,coverage:Double=0.18,passiveMapping:Bool=false)async->[String:Any] {
  do {_=try await run(mode,coverage:coverage,mapping:mapping,passiveObject:passiveObject,passiveMapping:passiveMapping);preconditionFailure("Expected diagnostic timeout: \(mode)")}
  catch {
   let text=error.localizedDescription
   precondition(text.contains("did not settle") && !text.contains("Diagnostics:") && text.count<180,"Verbose robot error: \(text)")
   guard let details=Clock.latestVision?.healthSnapshot()["settling"]as?[String:Any] else {preconditionFailure(text)}
   precondition(details["kind"]as?String=="settled_capture_timeout_diagnostics_only")
   precondition(details["capture_time_refreshed"]as?Bool==false)
   let health=details["camera_health"]as![String:Any]
   precondition(health["analysis_ms"]as?Double==777 && health["note"]as?String=="inert source cadence fixture")
   precondition(details["poll_count"]as!Int>0)
   return details
  }
 }
 static func main()async throws {
  let partial=try await run()
  precondition(partial.0.sequence==22 && partial.2==300,"Mapping did not require three advancing exposures over300ms")
  precondition(!partial.1.vision.fresh && !partial.1.vision.handsClear,"Partial map frame changed general motion readiness")
  let object=try await run("changing",passiveObject:true)
  precondition(object.0.sequence==22 && object.2==300,"Passive object attention did not retain3fresh advancing exposures/300ms")
  precondition(!object.1.vision.fresh && !object.1.vision.handsClear,"Object attention granted arm/human readiness")
  precondition(object.1.vision.passiveObjectAdvancing(object.0,after:21))
  precondition(!object.1.vision.passiveObjectAdvancing(object.0,after:22),"Duplicate object frame passed advancing gate")
  var invalidObject=object.0;invalidObject.intrinsics=nil
  precondition(!object.1.vision.passiveObjectAdvancing(invalidObject,after:21),"Post-inference object gate omitted intrinsics")
  invalidObject=object.0;invalidObject.capturedAt-=701
  precondition(!object.1.vision.passiveObjectAdvancing(invalidObject,after:21),"Post-inference object gate refreshed old capture")
  await rejected("normal",mapping:false,contains:"did not settle")
  let ordinary=try await run(coverage:0.25,mapping:false)
  precondition(ordinary.0.sequence==22 && ordinary.1.vision.fresh && ordinary.1.vision.handsClear)
  let human=try await run("human")
  precondition(!human.1.vision.handsClear,"Depth-map acquisition granted human clearance")
  let retained=try await run("retained")
  precondition(retained.0.sequence==23 && retained.2==450,"Retained pre-start frame counted toward settling")
  for mode in ["stale","future","wrong_source","zero_depth","missing_depth","missing_k","invalid_k","duplicate","changing"] {
   await rejected(mode,contains:"did not settle")
  }
  await rejected("normal",coverage:.nan,contains:"did not settle")
  await rejected("normal",coverage:1.01,contains:"did not settle")
  for mode in ["sequence_reordered","timestamp_reordered"] {await rejected(mode,contains:"restarted")}
  for mode in ["source_changed","cancelled"] {
   do {_=try await run(mode);preconditionFailure("Changed/cancelled source admitted")}
   catch {precondition(error is CancellationError)}
  }
  let imu=try await run("slow_imu_valid",passiveObject:true)
  precondition(imu.2==1200 && imu.0.sequence==21,"Passive IMU path did not use one actual post-call frame")
  precondition(imu.1.vision.lastSettlingDiagnostics["method"]as?String=="stationary_imu_single_actual_post_call_frame")
  precondition(imu.1.vision.lastSettlingDiagnostics["human_clearance_granted"]as?Bool==false)
  precondition(!imu.1.vision.fresh && !imu.1.vision.handsClear,"IMU attention changed ordinary readiness")
  for (mode,reason) in [("slow_imu_moving","single_frame_imu_not_stationary"),("slow_imu_old_imu","single_frame_imu_invalid"),
   ("slow_imu_invalid_rotation","single_frame_imu_invalid"),("slow_imu_short_window","single_frame_imu_window_below_300ms"),
   ("slow_imu_few_samples","single_frame_imu_samples_below_20"),("imu_valid_stale","exposure_older_than_700ms"),
   ("imu_valid_wrong_source","camera_generation_mismatch"),("imu_valid_invalid_k","invalid_intrinsics")] {
   let diagnostics=await timeoutDiagnostics(mode,passiveObject:true)
   precondition((diagnostics["failed_condition_poll_counts"]as![String:Int])[reason] != nil,"Missing actual condition \(reason)")
  }
  let ordinaryIMU=await timeoutDiagnostics("slow_imu_valid",mapping:false,coverage:0.25)
  precondition(ordinaryIMU["stationary_imu_passive_frame_allowed"]as?Bool==false,"IMU changed ordinary capture")
  let mappingIMU=await timeoutDiagnostics("slow_imu_valid")
  precondition(mappingIMU["stationary_imu_passive_frame_allowed"]as?Bool==false,"IMU changed static depth capture")
  let passiveMap=try await run("slow_imu_valid",passiveMapping:true)
  precondition(passiveMap.2==1200 && passiveMap.0.sequence==21 && Clock.passiveChecks>=20,"Passive mapping did not await/check actual sparse cadence")
  precondition(passiveMap.1.vision.lastSettlingDiagnostics["three_frame_fallback_requires_static_scene"]as?Bool==true)
  precondition(!passiveMap.1.vision.fresh && !passiveMap.1.vision.handsClear,"Passive mapping supplied motion/human readiness")
  let fallback=try await run(passiveMapping:true)
  precondition(fallback.0.sequence==22 && fallback.2==300,"No-IMU passive mapping lost static3frame fallback")
  let changedFallback=await timeoutDiagnostics("changing",passiveMapping:true)
  precondition(changedFallback["static_scene_resets"]as!Int>0,"Passive mapping weakened fallback scene-change veto")
  for mode in ["slow_imu_moving","slow_imu_old_imu","slow_imu_invalid_rotation","imu_valid_stale","imu_valid_wrong_source","imu_valid_invalid_k"] {
   _=await timeoutDiagnostics(mode,passiveMapping:true)
  }
  do {_=try await run("slow_imu_valid",passiveMapping:true,stopAtCheck:4);preconditionFailure("Passive context/Stop failure ignored")}
  catch {precondition(error is CancellationError && Clock.passiveChecks==4)}
  do {_=try await run("slow_imu_valid",passiveMapping:true,deadlineSeconds:0.2);preconditionFailure("Passive deadline extended")}
  catch {precondition(Clock.milliseconds==1_000_200)}
  let gaps=await timeoutDiagnostics("gap_resets",passiveObject:true)
  precondition(gaps["capture_gap_resets"]as!Int>=2 && gaps["maximum_accepted_capture_gap_ms"]as!Double==800)
  precondition(gaps["static_scene_resets"]as!Int==0,"Passive failure mislabeled scene motion")
  let kFailure=await timeoutDiagnostics("invalid_k")
  let facts=kFailure["latest_frame"]as![String:Any]
  precondition(facts["intrinsics_valid_for_depth_dimensions"]as?Bool==false)
  precondition(facts["current_camera_generation"]as?String != nil && facts["capture_age_ms"] != nil)
  do {_=try await run(deadlineSeconds:0.2);preconditionFailure("Caller deadline extended")}
  catch {precondition(Clock.milliseconds==1_000_200)}
  print("PASS actual partial-depth settling+diagnostics:18% mapping andlegacy3frame unchanged; passiveonly single validstationaryIMU postcallframe accepted at1200ms; moving/invalid/old/short/sparseIMU plusage/source/K negatives; timeoutreasoncounts+health/gapresets; ordinary/static/human readiness unchanged; no mapping rays or motor output invented")
 }
}
'''

def main():
    vision=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
    camera=(ROOT/'Cerebro/CameraManager.swift').read_text()
    markers=['func snapshot() -> [String: Frame]', 'var fresh: Bool', 'var handsClear: Bool',
             'private func isFresh(', 'private func isDepthMappingEligible(', 'private func inspectionEpoch(',
             'func settledDepthFrame(', '@MainActor func settledPassiveMappingFrame(',
             'private static func passiveMappingNoopCheck(', 'private func inspectionFrame(', 'static func sceneChangeFraction(',
             'private static func settledFrameDiagnostics(', 'private func recordSettlingDiagnostics(',
             'private func settledInspectionFrame(']
    actual='\n'.join(block(vision,m) for m in markers)
    general=block(vision,'private func isFresh(')
    assert general=='''private func isFresh(_ frame: Frame) -> Bool {
        (0 ... 700).contains(Date().timeIntervalSince1970 * 1000 - frame.capturedAt)
            && frame.depthCoverage >= 0.25
    }'''
    assert vision.count('depthMappingOnly:true')==2
    assert 'depthMappingOnly:true' in block(vision,'func settledDepthFrame(')
    assert 'depthMappingOnly:Bool=false' in block(vision,'private func settledInspectionFrame(')
    object_branch=vision[vision.index('func observeWorkspace('):].split('if objectDetection {',1)[1].split('let result = try await ROBMLXEngine',1)[0]
    assert 'nonactuatingSparseDepth:Bool = false' in vision
    assert 'depthMappingOnly:nonactuatingSparseDepth,allowStationaryIMUPassiveFrame:nonactuatingSparseDepth)' in object_branch
    assert '(nonactuatingSparseDepth ? isDepthMappingEligible(current):isFresh(current)),current.sequence > frame.sequence' in object_branch
    assert vision.count('nonactuatingSparseDepth:true')==1
    assert 'vision.observeWorkspace(objectDetection: !targets.isEmpty,nonactuatingSparseDepth:true)' in vision
    assert vision.count('allowStationaryIMUPassiveFrame:nonactuatingSparseDepth')==1
    source=SUPPORT.replace('__ACTUAL_METHODS__',actual).replace('__ACTUAL_K_VALIDITY__',block(camera,'func isValid(forWidth width: Int, height: Int)'))
    source=source.replace('__ACTUAL_IMU_TYPE__',block(camera,'struct CameraInertialObservation:'))
    with tempfile.TemporaryDirectory(prefix='rob-partial-depth-settle-')as folder:
        p=Path(folder);swift=p/'fixture.swift';binary=p/'fixture';swift.write_text(source)
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True,timeout=60)
        subprocess.run([str(binary)],check=True,timeout=20)

if __name__=='__main__':main()
