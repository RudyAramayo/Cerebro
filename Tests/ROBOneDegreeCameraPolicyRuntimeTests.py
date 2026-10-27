#!/usr/bin/env python3
"""The actual camera deferral predicate is confined to the bounded experiment."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

root = Path(__file__).resolve().parents[1]
source = (root / 'Cerebro/ROBLeftArmTrial.swift').read_text()
policy = braced_declaration(source, '    private var defersOneDegreeCameraInspection:Bool {')
policy = policy.replace('private var', 'var', 1).replace('ProcessInfo.processInfo.systemUptime', 'clock')
fixture = r'''
import Foundation
struct Proof {let maximumHullTravelMeters:Double}
final class Harness {
 var clock=10.0,oneDegreeCameraInspectionDeadline:Double?=22
 var activeOneDegreeCalibration:Proof?=Proof(maximumHullTravelMeters:0.0151)
 var isRunning=true,oneDegreeEmptyCalibrationStepEnabled=true,physicalSide="right"
 var localReceiptCommand:String?="right_recycle_cans",armTravelDispatched=true
 var jawCommandDispatched=false,jawSetupDispatchUncertain=false,recyclingGripDispatched=false,servoPossiblePayloadUncertain=false
 /* POLICY */
}
@main enum Test {
 static func no(_ change:(Harness)->Void) {let h=Harness();change(h);precondition(!h.defersOneDegreeCameraInspection)}
 static func main() {
  precondition(Harness().defersOneDegreeCameraInspection)
  no{$0.oneDegreeCameraInspectionDeadline=nil}
  no{$0.activeOneDegreeCalibration=nil}
  no{$0.clock=22}
  no{$0.isRunning=false}
  no{$0.oneDegreeEmptyCalibrationStepEnabled=false}
  no{$0.physicalSide="left"}
  no{$0.localReceiptCommand=nil}
  no{$0.localReceiptCommand="right_recycle_can"}
  no{$0.armTravelDispatched=false}
  no{$0.jawCommandDispatched=true}
  no{$0.jawSetupDispatchUncertain=true}
  no{$0.recyclingGripDispatched=true}
  no{$0.servoPossiblePayloadUncertain=true}
  no{$0.activeOneDegreeCalibration=Proof(maximumHullTravelMeters:0.020001)}
  print("PASS actual camera deferral: exact RIGHT one-degree empty scope only,≤20mm, dispatched single step, finite execution window; no jaw/payload/ordinary-route exemption")
 }
}
'''.replace('/* POLICY */', policy)
with tempfile.TemporaryDirectory(prefix='rob-one-degree-camera-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cerebro-swift-module-cache', str(path / 'Fixture.swift'), '-o', str(path / 'fixture')], check=True)
    subprocess.run([str(path / 'fixture')], check=True)
