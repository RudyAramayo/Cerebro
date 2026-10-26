#!/usr/bin/env python3
"""Actual initial-empty post-proof camera checkpoint; inert native-value seams."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1];s=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
helper=braced_declaration(s,'    @MainActor private func refreshInitialEmptyDispatchView(').replace('private func','func',1)
referenceType=braced_declaration(s,'    private struct InitialEmptyViewReference {').replace('private struct','struct',1)
pin=braced_declaration(s,'    @MainActor private func initialEmptyViewReference(').replace('private func','func',1)
scopeBody=braced_declaration((root/'Cerebro/ROBFixedHeadCalibrationWindowController.swift').read_text(),'    @nonobjc func scope(model:').replace('@nonobjc func','func',1)
flow=braced_declaration(s,'    @MainActor private func performInitialLocalRetreatIfNeeded(')
assert flow.count('try await refreshInitialEmptyDispatchView(')==2
assert flow.index('proof.maximumHullTravelMeters+admissionDrift')<flow.index('announce?(')<flow.index('try await accepted {gateway.sendApprovedLeftGestureStep')
assert flow.index('cameraReady=false // No travel')<flow.index('stage:"fresh_dispatch_start"')<flow.rindex('try await refreshInitialEmptyDispatchView(')<flow.index('cameraReady=true')<flow.index('gateway.sendApprovedLeftGestureStep')
fixture=r'''
import Foundation
struct ROBWorkspaceCollisionSnapshot{}
struct ROBGhostRobotModel{let modelID="model",geometryID="geometry",selectedMappingID="mapping"}
struct ROBWorkspaceVisualCalibrationTrial{let cameraGeneration:UUID;let bodyMotionIdentity="body",estimatedCameraProjectionIdentity="projection"}
enum ROBArmRoutineError:Error{case blocked(String)}
enum ROBGhostMotionError:Error{case blocked(String)}
struct Runtime{let identity:String;let actualDeviceMXID="device"}
struct Correspondence{let status="matched"}
struct Intrinsics{
 var runtimeCalibration:Runtime?=Runtime(identity:"runtime"),cameraServiceSourceSHA256:String?="source",key="K"
 var rgbOutputUndistorted:Bool?=true,depthRGBGeometryCorrespondence:Correspondence?=Correspondence(),inertial:String?="actual-inertial"
 func isValid(forWidth:Int,height:Int)->Bool{forWidth==640 && height==480}
}
struct Depth{let width=640,height=480}
@MainActor enum ROBArmRoutineVision{static let shared=Vision();struct Frame{var capturedAt:Double,sequence:UInt64,handsClear=true,depthCoverage=0.5;var cameraGeneration:UUID;var intrinsics:Intrinsics?=Intrinsics();var depth:Depth?=Depth()}}
struct ROBFixedHeadRegistrationScope:Equatable{
 let modelID:String,geometryID:String,mappingID:String,cameraGeneration:UUID,gatewaySessionGeneration:UInt64,displayCorrectionIdentity:String
 let panTarget:Int,lowerTarget:Int,upperTarget:Int,intrinsicsIdentity:String
}
@MainActor enum ROBWorkspaceDepthAlignment{struct Correction{let identity="correction"};static func snapshot()->Correction?{.init()}}
@MainActor final class ROBAmberGatewayClient{static let shared=ROBAmberGatewayClient();func connectionSnapshot()->NSDictionary{["sessionGeneration":NSNumber(value:1)]}}
@MainActor final class ROBFixedHeadCalibrationWindowController{
 static let shared=ROBFixedHeadCalibrationWindowController();var readyAt=ProcessInfo.processInfo.systemUptime-0.2,known=true,stationary=true
 var readNeck:(()->NSDictionary)?{{["known":self.known,"stationary":self.stationary,"pan":6000,"lower":6011,"upper":5650,"ready_at":self.readyAt]}}
 static func intrinsicsIdentity(_ frame:ROBArmRoutineVision.Frame)throws->String{frame.intrinsics!.key}
 /* ACTUAL SCOPE */
}
@MainActor enum ROBFixedHeadBodyMotionIdentity{static var currentIdentity="body"}
@MainActor enum ROBNeckRGBPoseDisplay{
 struct ActualFrameSource{let cameraGeneration:UUID,actualDeviceMXID:String?,runtimeCalibrationIdentity:String?,cameraServiceSourceSHA256:String?;let scope:ROBFixedHeadRegistrationScope;let inertialJSON:Data?}
 static var accepts=true
 static func estimatedCameraProjectionIdentity(model:ROBGhostRobotModel)->String?{"projection"}
 static func estimatedProjectionAcceptsSource(model:ROBGhostRobotModel,actualFrame:ActualFrameSource)->Bool{accepts}
}
@MainActor final class Vision{
 var cameraGeneration=UUID(),frame:ROBArmRoutineVision.Frame!
 var fresh:Bool{(0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt)}
 var handsClear:Bool{fresh && frame.handsClear}
 func snapshot()->[String:ROBArmRoutineVision.Frame]{["face":frame]}
}
final class Sample{var positionsRadians=Array(repeating:NSNumber(value:0),count:7)}
@MainActor final class Trial{
 let vision=ROBArmRoutineVision.shared,sample=Sample();var localReceiptCommand:String?="right_recycle_cans"
 var cameraReady=false,leased=false,armTravelDispatched=false,jawCommandDispatched=false,jawSetupDispatchUncertain=false,recyclingGripDispatched=false,servoPossiblePayloadUncertain=false
 var localReceiptHeldNeckIdentity:String?="head",head="head",stopped=false,feedbackFresh=true,checks=0,strictCalls=0
 var generation:UInt64=1,collisionReviewStatus:NSDictionary=[:]
 /* REFERENCE TYPE */
 /* PIN */
 var deadline=ProcessInfo.processInfo.systemUptime+5
 func check()throws{checks+=1;if stopped || !feedbackFresh{throw ROBArmRoutineError.blocked("Stop/feedback")}}
 func localNeckIdentity()->String?{head}
 func measured()throws->Sample{if !feedbackFresh{throw ROBArmRoutineError.blocked("feedback")};return sample}
 func requireLiveVisualTrial(_ t:ROBWorkspaceVisualCalibrationTrial,map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel)throws{precondition(vision.fresh && vision.handsClear);strictCalls+=1}
 /* HELPER */
}
@main enum Test{
 @MainActor static func make()->Trial{let t=Trial();t.vision.frame = .init(capturedAt:Date().timeIntervalSince1970*1000-1000,sequence:1,cameraGeneration:t.vision.cameraGeneration);return t}
 @MainActor static func run(_ t:Trial)async throws{try await t.refreshInitialEmptyDispatchView(map:.init(),model:.init(),trial:.init(cameraGeneration:t.vision.cameraGeneration),baseline:Array(repeating:0,count:7),reference:try t.initialEmptyViewReference(t.vision.frame))}
 @MainActor static func advance(_ t:Trial){t.vision.frame.capturedAt=Date().timeIntervalSince1970*1000;t.vision.frame.sequence+=1}
 @MainActor static func main()async throws{
  let controller=ROBFixedHeadCalibrationWindowController.shared
  let pass=make(),old=pass.vision.frame.capturedAt
  do{_ = try controller.scope(model:.init(),frame:pass.vision.frame);preconditionFailure("Fixture must reject the old pre-ready reference under the REAL ready_at rule")}catch{}
  // Live source must pass the ACTUAL native controller scope method.
  let producer=Task{@MainActor in try await Task.sleep(nanoseconds:40_000_000);advance(pass)}
  try await run(pass);try await producer.value
  precondition(pass.strictCalls==1 && pass.checks>0 && old != pass.vision.frame.capturedAt && !pass.cameraReady && !pass.armTravelDispatched && !pass.jawCommandDispatched)
  _ = try controller.scope(model:.init(),frame:pass.vision.frame)
  for mode in 0..<12{
   let t=make();let task=Task{@MainActor in
    try await Task.sleep(nanoseconds:20_000_000);advance(t)
    switch mode{
     case 0:t.stopped=true
     case 1:t.feedbackFresh=false
     case 2:t.sample.positionsRadians[0]=0.01
     case 3:t.vision.frame.intrinsics!.runtimeCalibration=Runtime(identity:"changed")
     case 4:t.vision.frame.intrinsics!.key="changed-K"
     case 5:t.vision.frame.handsClear=false
     case 6:t.head="changed-head"
     case 7:t.vision.cameraGeneration=UUID()
     case 8:ROBFixedHeadBodyMotionIdentity.currentIdentity="changed-body"
     case 9:t.armTravelDispatched=true
     case 10:ROBNeckRGBPoseDisplay.accepts=false
     default:controller.readyAt=ProcessInfo.processInfo.systemUptime
    }
   }
   do{try await run(t);preconditionFailure("Invalid preflight accepted") }catch{
    if mode==5{let reason=String(describing:error);precondition(reason.contains("A hand or person is visible") && !reason.contains("RGB-D source changed"))}
   }
   try await task.value;precondition(t.strictCalls==0)
   if mode==11{precondition((t.collisionReviewStatus["initial_empty_view_refresh"]as?NSDictionary)?["reason"]as?String=="held_neck_changed")}
   ROBFixedHeadBodyMotionIdentity.currentIdentity="body";ROBNeckRGBPoseDisplay.accepts=true;controller.readyAt=ProcessInfo.processInfo.systemUptime-0.2
  }
  let timeout=make();timeout.deadline=ProcessInfo.processInfo.systemUptime+0.06
  do{try await run(timeout);preconditionFailure("Old frame reused/restamped")}catch{}
  precondition(timeout.strictCalls==0 && timeout.vision.frame.sequence==1)
  precondition((timeout.collisionReviewStatus["initial_empty_view_refresh"]as?NSDictionary)?["reason"]as?String=="fresh_post_ready_frame_timeout")
  precondition(timeout.vision.frame.capturedAt<Date().timeIntervalSince1970*1000-500,"Historical exposure was retimed")
  let active=make();active.leased=true
  do{try await run(active);preconditionFailure("Travel lease admitted")}catch{}
  print("PASS actual native scope + source-only pre-proof pin + fresh-view checkpoint: old reference before ready rejects as a live pose; NEW post-proof/post-ready source accepts; same q/K/runtime/gen/head/body/person; Stop/feedback/gravity veto; shared timeout; no restamp/travel/jaws/lease")
 }
}
'''.replace('/* HELPER */',helper).replace('/* REFERENCE TYPE */',referenceType).replace('/* PIN */',pin).replace('/* ACTUAL SCOPE */',scopeBody)
with tempfile.TemporaryDirectory(prefix='rob-initial-view-refresh-',dir='/private/tmp')as folder:
 p=Path(folder);(p/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True,timeout=10)
