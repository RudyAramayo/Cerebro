#!/usr/bin/env python3
"""Exercise the real application-restart/Stop boundary without any hardware."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Cerebro/ROBArmRoutineCoordinator.swift').read_text()
def block(marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    level = 1
    while level:
        level += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

methods = block('    func cancel(reason: String)') + '\n' + block('    func suspendForApplicationRestart(reason: String)')
main = (ROOT / 'Cerebro/ROBMainViewController.mm').read_text()
assert 'suspendForApplicationRestartWithReason:@"Cerebro is shutting down"' in main
assert '[[ROBArmRoutineCoordinator shared] cancelWithReason:@"Cerebro is shutting down"]' not in main
fixture = r'''
import Foundation
final class ROBGripperStartupCalibration {
 static let shared=ROBGripperStartupCalibration();var stopped=0
 func stop(reason:String){stopped+=1}
}
final class ROBControllerArmApproval {
 static let shared=ROBControllerArmApproval();var paused=0,revoked=0
 func pauseStandingLocalCanCampaign(reason:String){paused+=1}
 func cancel(reason:String){revoked+=1}
}
final class ROBLeftArmTrial {
 static let shared=ROBLeftArmTrial();var cancelled=0
 func cancel(reason:String){cancelled+=1}
}
final class Coordinator {
 var holds=0
 private func cancelAuthorized(reason:String){holds+=1}
 /* ACTUAL METHODS */
}
@main enum Test {
 static func main(){
  let c=Coordinator(),broker=ROBControllerArmApproval.shared
  c.suspendForApplicationRestart(reason:"Cerebro is shutting down")
  precondition(broker.paused==1 && broker.revoked==0 && c.holds==1)
  precondition(ROBGripperStartupCalibration.shared.stopped==1 && ROBLeftArmTrial.shared.cancelled==1)
  c.cancel(reason:"Stop requested by operator")
  precondition(broker.paused==1 && broker.revoked==1 && c.holds==2)
  precondition(ROBGripperStartupCalibration.shared.stopped==2 && ROBLeftArmTrial.shared.cancelled==2)
  print("PASS actual application restart pauses standing campaign and ends old execution; explicit Stop still revokes and holds; native quit caller wired; no hardware")
 }
}
'''.replace('/* ACTUAL METHODS */', methods)
with tempfile.TemporaryDirectory(prefix='rob-standing-lifecycle-') as tmp:
    folder=Path(tmp);swift=folder/'Fixture.swift';swift.write_text(fixture);binary=folder/'fixture'
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
