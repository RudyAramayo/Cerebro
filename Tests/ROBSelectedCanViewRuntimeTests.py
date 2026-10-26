#!/usr/bin/env python3
"""Actual selected-can hold gate: exact native raw target, not float precision."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1];s=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
method=braced_declaration(s,'    @MainActor private func prepareLocalCanObservationView(').replace('private func','func',1)
fixture=r'''
import Foundation
enum ROBArmRoutineError:Error{case blocked(String)}
struct ROBGhostRobotModel{}
struct ROBWorkspaceLocatedObject{let sequence:UInt64=21465;let capturedAt=1793050436669.878}
struct Observation{let sequence:UInt64=21465,capturedAtMilliseconds=1793050436669.878;let recordedLowerTarget:Int?=6011,recordedUpperTarget:Int?=6162,recordedPanDegrees:Double?=4.636222779750824}
struct ROBWorkspaceCollisionSnapshot{var cameraGeneration:UUID;let observations=[Observation()]}
@MainActor final class Vision{var fresh=true,cameraGeneration=UUID()}
@MainActor final class ROBArmRoutineCoordinator{static let shared=ROBArmRoutineCoordinator();var viewIsStationary:(()->Bool)?={true}}
@MainActor final class ROBFixedHeadCalibrationWindowController{
 static let shared=ROBFixedHeadCalibrationWindowController()
 var neck:NSMutableDictionary=["pan":6155,"pan_degrees":4.65,"lower":6011,"upper":6162]
 var readNeck:(()->NSDictionary)?{{self.neck}}
}
@MainActor final class ROBWorkspaceSearch{
 static let shared=ROBWorkspaceSearch();var projection=true
 var panTargetForView:((Double)->NSNumber?)?={NSNumber(value:Int(($0/0.03).rounded())+6000)}
 var prepareView:((Double,Int)->Bool)?={_,_ in true},viewReady:((Double,Int)->Bool)?={_,_ in true}
 func estimatedCameraProjectionIsCurrent(model:ROBGhostRobotModel,map:ROBWorkspaceCollisionSnapshot)->Bool{projection}
}
@MainActor final class Trial{
 var localReceiptCommand:String?="right_recycle_cans",leased=false,recyclingGripDispatched=false,cameraReady=true,phase=""
 var leaseRenewals:[Int:Int]=[:],localReceiptHeldNeckIdentity:String?,known=true,collisionReviewStatus:NSDictionary=[:]
 let vision=Vision()
 func wait(_ seconds:Double,until:(()->Bool))async throws{precondition(until())}
 func localNeckIdentity()->String?{known ? "actual-held-raw-neck":nil}
 func workspaceModel()throws->ROBGhostRobotModel{.init()}
 /* METHOD */
}
@main enum Test{
 @MainActor static func main()async throws{
  let controller=ROBFixedHeadCalibrationWindowController.shared,search=ROBWorkspaceSearch.shared
  precondition(abs(4.65-4.636222779750824)>0.01)
  let t=Trial();try await t.prepareLocalCanObservationView(.init(),map:.init(cameraGeneration:t.vision.cameraGeneration))
  precondition(t.localReceiptHeldNeckIdentity != nil,"Exactly matching raw6155 must pass despite requested-angle quantization")
  for mode in 0..<7{
   let v=Trial();var map=ROBWorkspaceCollisionSnapshot(cameraGeneration:v.vision.cameraGeneration)
   var field=""
   switch mode{
    case 0:controller.neck["pan"]=6156;field="raw_pan_target"
    case 1:controller.neck["lower"]=6012;field="raw_lower_target"
    case 2:controller.neck["upper"]=6163;field="raw_upper_target"
    case 3:map.cameraGeneration=UUID();field="camera_generation"
    case 4:v.known=false;field="stationary_neck_identity"
    case 5:search.projection=false;field="physical_projection"
    default:search.panTargetForView=nil;field="pan_target_unavailable"
   }
   do{try await v.prepareLocalCanObservationView(.init(),map:map);preconditionFailure("Changed actual field accepted")}catch{}
   let facts=v.collisionReviewStatus["selected_can_view_diagnostic"]as!NSDictionary
   precondition((facts["failed_fields"]as![String]).contains(field));precondition(v.localReceiptHeldNeckIdentity==nil)
   controller.neck["pan"]=6155;controller.neck["lower"]=6011;controller.neck["upper"]=6162;search.projection=true
   search.panTargetForView={NSNumber(value:Int(($0/0.03).rounded())+6000)}
  }
  print("PASS actual selected-can source gate: requested4.636222779750824°→raw6155/readback4.65° accepted exactly; rawone-tick/lower/upper/gen/held/projection/converter mismatches reject with field-specific facts; no hardware")
 }
}
'''.replace('/* METHOD */',method)
with tempfile.TemporaryDirectory(prefix='rob-selected-can-view-',dir='/private/tmp')as folder:
 p=Path(folder);(p/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True,timeout=10)
