#!/usr/bin/env python3
"""Production perception-stage budgets and final readiness; inert clock/frames."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    index = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
    return source[start:index]


SUPPORT = r'''
import Foundation
enum Clock {static var milliseconds=1_000_474.0}
struct Date {var timeIntervalSince1970:Double {Clock.milliseconds/1000}}
__ACTUAL_TIMING__
__ACTUAL_BUDGET__
final class Harness {
 struct Frame {let capturedAt:Double,depthCoverage:Double;let handsClear:Bool}
 var frame:Frame?
 func snapshot()->[String:Frame] {frame.map{["face":$0]} ?? [:]}
 __ACTUAL_FRESH__
 __ACTUAL_HANDS__
 func finalFresh(_ frame:Frame)->Bool {isFresh(frame)}
}
@main enum Fixture {
 static func main() {
  UserDefaults.standard.setVolatileDomain(["ROBDevelopmentMode":false],forName:UserDefaults.argumentDomain)
  let h=Harness(),exposure=1_000_000.0
  // Actual production incident:450ms transport plus24ms analysis is still
  // inside the existing final700ms motion age. Preserve the original stamp.
  precondition(ROBVisionFrameAgeBudget.acceptsIngress(ageMilliseconds:450))
  precondition(ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:474))
  h.frame = .init(capturedAt:exposure,depthCoverage:0.25,handsClear:true)
  precondition(h.frame!.capturedAt==exposure && h.finalFresh(h.frame!) && h.handsClear)
  h.frame = .init(capturedAt:exposure,depthCoverage:0.25,handsClear:false)
  precondition(h.finalFresh(h.frame!) && !h.handsClear,"Age budget cleared a visible-hand veto")
  h.frame = .init(capturedAt:exposure,depthCoverage:0.249,handsClear:true)
  precondition(!h.finalFresh(h.frame!) && !h.handsClear,"Age budget changed ordinary25% readiness")
  precondition(ROBVisionFrameAgeBudget.acceptsIngress(ageMilliseconds:550))
  precondition(!ROBVisionFrameAgeBudget.acceptsIngress(ageMilliseconds:550.001))
  precondition(ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:550+150))
  precondition(ROBVisionFrameAgeBudget.acceptsAnalysisOpportunity(active:true,busy:false,elapsedSeconds:0.1))
  precondition(ROBVisionFrameAgeBudget.acceptsAnalysisOpportunity(active:true,busy:false,elapsedSeconds:0.15))
  precondition(!ROBVisionFrameAgeBudget.acceptsAnalysisOpportunity(active:true,busy:false,elapsedSeconds:0.099))
  precondition(!ROBVisionFrameAgeBudget.acceptsAnalysisOpportunity(active:true,busy:true,elapsedSeconds:1))
  precondition(!ROBVisionFrameAgeBudget.acceptsAnalysisOpportunity(active:false,busy:false,elapsedSeconds:1))
  for late in [450+251.0,550+151.0,701.0,5_000.0] {
   precondition(!ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:late),"Late analysis published")
   Clock.milliseconds=exposure+late
   precondition(!h.finalFresh(.init(capturedAt:exposure,depthCoverage:1,handsClear:true)),"Final700ms changed")
  }
  for invalid in [-0.001,-10,.nan,.infinity,-.infinity] {
   precondition(!ROBVisionFrameAgeBudget.acceptsIngress(ageMilliseconds:invalid))
   precondition(!ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:invalid))
  }
  Clock.milliseconds=exposure+700
  precondition(h.finalFresh(.init(capturedAt:exposure,depthCoverage:0.25,handsClear:true)),"Existing boundary changed")
  UserDefaults.standard.setVolatileDomain(["ROBDevelopmentMode":true],forName:UserDefaults.argumentDomain)
  #if DEBUG
  precondition(ROBVisionFrameAgeBudget.maximumAgeMilliseconds==1200)
  precondition(ROBArmFeedbackTiming.maximumAgeMilliseconds==1200,"Requested debug motor budget differs from1200ms")
  precondition(ROBVisionFrameAgeBudget.acceptsIngress(ageMilliseconds:1050))
  precondition(!ROBVisionFrameAgeBudget.acceptsIngress(ageMilliseconds:1050.001))
  for age in [713.0,1050,1200] {
   Clock.milliseconds=exposure+age
   precondition(ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:age))
   precondition(h.finalFresh(.init(capturedAt:exposure,depthCoverage:0.25,handsClear:true)))
  }
  precondition(!ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:1200.001))
  Clock.milliseconds=exposure+1200.001
  precondition(!h.finalFresh(.init(capturedAt:exposure,depthCoverage:1,handsClear:true)))
  #else
  precondition(ROBVisionFrameAgeBudget.maximumAgeMilliseconds==700)
  precondition(!ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:713))
  #endif
  UserDefaults.standard.setVolatileDomain(["ROBDevelopmentMode":false],forName:UserDefaults.argumentDomain)
  precondition(!ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:713))
  UserDefaults.standard.removeVolatileDomain(forName:UserDefaults.argumentDomain)
  print("PASS DEBUG + Development Mode camera1200ms; normal700ms; original timestamps, depth coverage and requested motor1200ms independently enforced")
  print("PASS actual ingress550/publication700 and100ms no-backlog cadence:450+24 accepted with originalstamp; >550/future/nonfinite input and >700 completedanalysis rejected; busy/inactive analysis rejected; final700/25%/hands checks unchanged; no hardware or authority")
 }
}
'''


def main():
    source = (ROOT / 'Cerebro/ROBArmRoutineVision.swift').read_text()
    timing_source = (ROOT / 'Cerebro/ROBArmJointLimits.swift').read_text()
    budget = block(timing_source, 'struct ROBVisionFrameAgeBudget {')
    timing = block(timing_source, 'enum ROBArmFeedbackTiming {')
    offer = block(source, 'func offer(_ frame: CameraFrameSet, role: CameraRole)')
    # Exercise the actual value functions below and bind them to BOTH actual
    # production boundaries. A late result cannot overwrite the current frame.
    ingress = 'guard ROBVisionFrameAgeBudget.acceptsIngress(ageMilliseconds:age)'
    publication = 'guard ROBVisionFrameAgeBudget.acceptsPublication(ageMilliseconds:publicationAge)'
    assert ingress in offer and publication in offer
    assert 'acceptsAnalysisOpportunity(active:active,busy:busy.contains(key),' in offer
    assert 'elapsedSeconds:now-(lastOffer[key] ?? 0))' in offer
    assert offer.index('acceptsAnalysisOpportunity(') < offer.index('busy.insert(key)')
    assert offer.index(ingress) < offer.index('busy.insert(key)')
    assert offer.index('self.busy.remove(key)') < offer.index(publication) < offer.index('self.frames[key] = Frame(')
    assert 'capturedAt: captured' in offer and 'let publicationAge=Date().timeIntervalSince1970*1000-captured' in offer
    final = block(source, 'private func isFresh(')
    assert final == '''private func isFresh(_ frame: Frame) -> Bool {
        (0 ... ROBVisionFrameAgeBudget.maximumAgeMilliseconds).contains(Date().timeIntervalSince1970 * 1000 - frame.capturedAt)
            && frame.depthCoverage >= 0.25
    }'''
    swift = SUPPORT.replace('__ACTUAL_TIMING__', timing).replace('__ACTUAL_BUDGET__', budget).replace('__ACTUAL_FRESH__', final)
    swift = swift.replace('__ACTUAL_HANDS__', block(source, 'var handsClear: Bool'))
    with tempfile.TemporaryDirectory(prefix='rob-vision-age-budget-') as folder:
        path = Path(folder)
        (path / 'Fixture.swift').write_text(swift)
        for flags in [[], ['-DDEBUG']]:
            subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-parse-as-library', *flags,
                '-module-cache-path', '/private/tmp/cerebro-swift-module-cache', str(path / 'Fixture.swift'),
                '-o', str(path / 'fixture')], check=True, timeout=30)
            subprocess.run([str(path / 'fixture')], check=True, timeout=10)


if __name__ == '__main__':
    main()
