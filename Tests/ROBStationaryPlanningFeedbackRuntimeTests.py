#!/usr/bin/env python3
"""Exercise actual selected-arm feedback admission during stationary planning."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

root = Path(__file__).resolve().parents[1]
source = (root / 'Cerebro/ROBLeftArmTrial.swift').read_text()
guard = braced_declaration(source, 'private enum ROBHeldArmFeedbackGuard {').replace('private enum', 'enum', 1)
policy = braced_declaration(source, '    private var selectedFeedbackMaximumAgeMilliseconds:Double {').replace('private var', 'var', 1)
measured = braced_declaration(source, '    private func measured()').replace('private func', 'func', 1)
record = braced_declaration(source, '    private func record(')
assert 'if deliveredAge > selectedFeedbackMaximumAgeMilliseconds' in record
assert 'sample.sampleAgeAtReceiptMilliseconds <= 250' in record
fixture = r'''
import Foundation
enum ROBArmRoutineError:Error {case blocked(String)}
/* GUARD */
final class ROBAmberGatewayTelemetry {
 var sequence:UInt64=1
 var positionsRadians=Array(repeating:NSNumber(value:0.0),count:7)
 var currents=Array(repeating:NSNumber(value:0.2),count:7)
 var statuses=Array(repeating:NSNumber(value:2),count:7)
 var effectiveSampleAgeMilliseconds=294.0,effectiveGripperFeedbackAgeMilliseconds=285.0
}
final class Gateway {
 var sample:ROBAmberGatewayTelemetry?=ROBAmberGatewayTelemetry(),mode=2
 func telemetry(forArm:String)->ROBAmberGatewayTelemetry?{sample}
 func modes(forArm:String)->[NSNumber]{Array(repeating:NSNumber(value:mode),count:7)}
}
final class Hold {
 let gateway=Gateway(),arm="left",physicalSide="right"
 var localReceiptCommand:String?="right_recycle_cans"
 var cameraReady=false,positionReady=true,leased=false,armTravelDispatched=false
 var jawCommandDispatched=false,jawSetupDispatchUncertain=false,recyclingGripDispatched=false,servoPossiblePayloadUncertain=false
 var leaseRenewals:[UInt64:Double]=[:]
 var sceneHold:[String:(positions:[Double],modes:[Int])]=["left":(Array(repeating:0,count:7),Array(repeating:0,count:7))]
 enum Recovery {case feedbackLost}
 var localCampaignRecoveryReason:Recovery?
 /* POLICY */
 /* MEASURED */
}
@main enum Test {
 static func rejected(_ change:(Hold)->Void) {
  let h=Hold();change(h)
  do{_ = try h.measured();preconditionFailure("Unqualified stale feedback admitted")}
  catch{precondition(String(describing:error).contains("Fresh right-arm"))}
 }
 static func main()throws {
  let h=Hold();precondition(h.selectedFeedbackMaximumAgeMilliseconds==350)
  _ = try h.measured()
  h.gateway.sample!.effectiveSampleAgeMilliseconds=350;h.gateway.sample!.effectiveGripperFeedbackAgeMilliseconds=350
  _ = try h.measured()
  rejected{$0.gateway.sample!.effectiveSampleAgeMilliseconds=351}
  rejected{$0.gateway.sample!.effectiveGripperFeedbackAgeMilliseconds=351}
  rejected{$0.gateway.sample!.effectiveSampleAgeMilliseconds = .nan}
  rejected{$0.gateway.sample=nil}
  rejected{$0.gateway.sample!.sequence=0}
  rejected{$0.gateway.sample!.currents[2]=NSNumber(value:Double.nan)}
  rejected{$0.gateway.sample!.positionsRadians[0]=NSNumber(value:0.003)}
  rejected{$0.gateway.sample!.statuses[0]=0}
  rejected{$0.gateway.mode=1}
  rejected{$0.sceneHold=[:]}
  rejected{$0.positionReady=false}
  rejected{$0.leased=true}
  rejected{$0.leaseRenewals=[1:0]}
  rejected{$0.armTravelDispatched=true}
  rejected{$0.jawCommandDispatched=true}
  rejected{$0.jawSetupDispatchUncertain=true}
  rejected{$0.recyclingGripDispatched=true}
  rejected{$0.servoPossiblePayloadUncertain=true}
  rejected{$0.localReceiptCommand=nil}
  let ready=Hold();ready.cameraReady=true;_ = try ready.measured()
  ready.armTravelDispatched=true
  do{_ = try ready.measured();preconditionFailure("Dispatch used stationary age allowance")}catch{}
  for mode in [0,2] {
   let scan=Hold();scan.positionReady=false;scan.gateway.mode=mode
   scan.gateway.sample!.statuses=Array(repeating:NSNumber(value:mode),count:7)
   scan.sceneHold["left"]!.modes=Array(repeating:mode,count:7)
   _ = try scan.measured();precondition(scan.selectedFeedbackMaximumAgeMilliseconds==350)
  }
  let moving=Hold();moving.armTravelDispatched=true
  moving.gateway.sample!.effectiveSampleAgeMilliseconds=250;moving.gateway.sample!.effectiveGripperFeedbackAgeMilliseconds=250
  _ = try moving.measured();precondition(moving.selectedFeedbackMaximumAgeMilliseconds==250)
  print("PASS actual selected-arm stationary feedback: inactive/position scans and empty planning accept294/350ms;351ms/missing/invalid/drift/mode fail; travel/jaw/payload/lease restores250ms before dispatch; raw receipt age unchanged; no hardware")
 }
}
'''.replace('/* GUARD */', guard).replace('/* POLICY */', policy).replace('/* MEASURED */', measured)
with tempfile.TemporaryDirectory(prefix='rob-stationary-planning-feedback-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cerebro-swift-module-cache', str(path / 'Fixture.swift'), '-o', str(path / 'fixture')], check=True)
    subprocess.run([str(path / 'fixture')], check=True)
