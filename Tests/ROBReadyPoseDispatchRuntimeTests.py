#!/usr/bin/env python3
"""Exercise actual dispatch admission without actuator IO."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1]
source=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
actual=braced_declaration(source,'struct ROBReviewedArmDispatchStart {')
ready=(root/'Cerebro/ROBGhostMotionPlan.swift').read_text()
reached=braced_declaration(ready,'    static func reached(')
plan=(root/'Cerebro/ROBArmRoutinePlan.swift').read_text()
near=braced_declaration(plan,'    static func near(')
fixture='''import Foundation
enum ROBArmRoutinePlan {static let tolerance=0.025
/* NEAR */ }
enum ROBCanRecyclingReadyPose {static let jointTolerance=0.015
/* REACHED */ }
/* ACTUAL */
@main enum Test {static func main() {
 let id=UUID(),q=[-0.044,-0.290,0.0,-0.177,0.191,0.300,0.081]
 let observed=[-0.04404229284329441,-0.29343348049154666,0,-0.17862354063379465,0.19212257156718832,0.30325095753401476,0.08222137023067037]
 let review=ROBReviewedArmDispatchStart(proposalID:id,index:1,generation:42,mapFingerprint:"map",positions:q,sequence:100,reviewCompletedAtUptime:10)
 func admits(_ ready:Bool,_ positions:[Double]=observed,identifier:UUID=id,index:Int=1,generation:UInt64=42,map:String="map",sequence:UInt64=101,now:Double=10.1)->Bool {
  review.matches(proposalID:identifier,index:index,generation:generation,mapFingerprint:map,positions:positions,sequence:sequence,nowUptime:now,coordinatedReadyPose:ready)
 }
 precondition(!admits(false) && admits(true))
 var excessive=observed;excessive[1]-=0.03
 precondition(!admits(true,excessive))
 precondition(!admits(true,identifier:UUID()) && !admits(true,index:2) && !admits(true,generation:43) && !admits(true,map:"changed"))
 precondition(!admits(true,sequence:99) && !admits(true,now:10.251) && !admits(true,now:9.999) && !admits(true,now:Double.nan))
 precondition(!admits(true,[0,0]) && !admits(true,[Double.nan,0,0,0,0,0,0]))
 print("PASS taught ready handoff accepts motor settling beyond the ordinary2mm gate; joint accuracy, packet order, freshness and exact context remain enforced; no actuator IO")
}}
'''.replace('/* NEAR */',near).replace('/* REACHED */',reached).replace('/* ACTUAL */',actual)
with tempfile.TemporaryDirectory(prefix='rob-ready-dispatch-') as directory:
 path=Path(directory);(path/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(path/'Fixture.swift'),'-o',str(path/'fixture')],check=True)
 subprocess.run([str(path/'fixture')],check=True)
