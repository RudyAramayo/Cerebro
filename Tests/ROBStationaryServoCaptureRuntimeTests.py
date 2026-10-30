#!/usr/bin/env python3
"""Execute the real nonactuating detector wrapper, with no device access."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

root = Path(__file__).resolve().parents[1]
source = (root / 'Cerebro/ROBLeftArmTrial.swift').read_text()
method = braced_declaration(source, '    @MainActor private func captureIncrementalCanContext(').replace('private func', 'func', 1)
fixture = r'''
import Foundation
enum ROBGhostMotionError:Error {case blocked(String)}
struct ROBGhostRobotModel {}
struct ROBWorkspaceLocatedObject {}
struct ROBWorkspaceCollisionSnapshot {}
struct ROBWorkspaceVisualCalibrationTrial {}
struct Frame {}
final class Sample {var positionsRadians=Array(repeating:NSNumber(value:0.2),count:7)}
final class Vision {var fresh=true}
@MainActor final class ROBArmRoutineCoordinator {
 static let shared=ROBArmRoutineCoordinator()
 var stationary=true
 var viewIsStationary:(()->Bool)? { {self.stationary} }
}
@MainActor enum ROBRecyclingVisualInspection {
 struct ServoContext {}
 static var duringCapture:(()->Void)?
 static var captures=0
 static func beginIncrementalVisualServo(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,
  map:ROBWorkspaceCollisionSnapshot,trial:ROBWorkspaceVisualCalibrationTrial,gatewayArm:String,
  feedbackForFrame:(Frame)->Sample?,check:()throws->Void)async throws->ServoContext {
  captures+=1;duringCapture?();try check();return .init()
 }
}
@MainActor final class Trial {
 var positionReady=true,leased=false,leaseRenewals:[Int:Int]=[:],taskJawTarget:[Double]?
 var jawSetupDispatchUncertain=false,recyclingGripDispatched=false,servoPossiblePayloadUncertain=false
 var cameraReady=true,phase="",arm="left",stopped=false,neverFresh=false,checks=0,waits=0
 let sample=Sample(),vision=Vision()
 func check()throws {checks+=1;if stopped || (cameraReady && !vision.fresh) {throw ROBGhostMotionError.blocked("Stop/stale camera")}}
 func measured()throws->Sample {sample}
 func heldHullDrift(side:String,from:[Double],to:[Double])->Double {abs(from[0]-to[0])}
 func exposureMatchedServoFeedback(_ f:Frame)->Sample? {sample}
 func update(_ text:String) {}
 func wait(_ seconds:Double,_ ready:()->Bool)async throws {
  waits+=1;precondition(seconds==2);try check()
  if !ready() && !neverFresh {vision.fresh=true}
  guard ready() else {throw ROBGhostMotionError.blocked("Fresh frame timeout")}
 }
 /* METHOD */
 func run()async throws { _ = try await captureIncrementalCanContext(model:.init(),can:.init(),map:.init(),trial:.init()) }
}
@main enum Test {
 @MainActor static func main()async throws {
  let good=Trial()
  ROBRecyclingVisualInspection.duringCapture={
   precondition(!good.cameraReady && good.taskJawTarget != nil)
   good.vision.fresh=false
  }
  try await good.run()
  precondition(good.cameraReady && good.vision.fresh && good.taskJawTarget==nil && good.waits==1)
  for mode in 0..<8 {
   let bad=Trial();let captures=ROBRecyclingVisualInspection.captures
   ROBArmRoutineCoordinator.shared.stationary=true
   if mode==0 {bad.leased=true}
   if mode==1 {bad.jawSetupDispatchUncertain=true}
   if mode==2 {bad.recyclingGripDispatched=true}
   if mode==3 {bad.servoPossiblePayloadUncertain=true}
   ROBRecyclingVisualInspection.duringCapture={
    if mode==4 {bad.stopped=true}
    if mode==5 {bad.sample.positionsRadians[0]=0.21}
    if mode==6 {ROBArmRoutineCoordinator.shared.stationary=false}
    if mode==7 {bad.neverFresh=true;bad.vision.fresh=false}
   }
   do {try await bad.run();preconditionFailure("Invalid capture accepted")}catch {}
   precondition(bad.cameraReady && bad.taskJawTarget==nil)
   if mode<4 {precondition(ROBRecyclingVisualInspection.captures==captures)}
  }
  print("PASS actual stationary capture wrapper: no in-flight motion/jaws/payload; bounded fresh-view wait; Stop/arm/body change reject; live camera gate always restored")
 }
}
'''.replace('/* METHOD */', method)
with tempfile.TemporaryDirectory(prefix='rob-stationary-servo-', dir='/private/tmp') as folder:
    path = Path(folder)
    (path / 'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(path / 'Fixture.swift'), '-o', str(path / 'fixture')], check=True)
    subprocess.run([str(path / 'fixture')], check=True, timeout=10)
