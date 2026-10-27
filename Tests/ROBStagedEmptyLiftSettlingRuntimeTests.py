#!/usr/bin/env python3
"""Exercise the production staged-lift endpoint wait with inert feedback/time."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

root = Path(__file__).resolve().parents[1]
source = (root / 'Cerebro/ROBLeftArmTrial.swift').read_text()
flow = braced_declaration(source, '    @MainActor private func performStagedEmptyLiftIfNeeded(')
start = flow.index('            let began=')
wait = braced_declaration(flow[start:], '            try await wait(step.seconds+3)')
actual = flow[start:flow.index('            try await wait(step.seconds+3)', start)] + wait
actual = actual.replace('ProcessInfo.processInfo.systemUptime', 'clock')
plan = (root / 'Cerebro/ROBArmRoutinePlan.swift').read_text()
settler = braced_declaration(plan, 'struct ROBArmRoutineSettler {')
near = braced_declaration(plan, '    static func near(')
tolerance = next(line for line in plan.splitlines() if 'static let tolerance =' in line)
fixture = r'''
import Foundation
enum ROBArmRoutinePlan { /* TOLERANCE */
/* NEAR */ }
/* SETTLER */
struct Step {let positions:[Double];let seconds:Double}
struct Sample {let sequence:UInt64;let positionsRadians:[NSNumber];let time:Double}
enum Failure:Error {case timeout}
@MainActor final class Harness {
 var clock=0.0,index=0,feedback:[Sample]=[]
 func measured()throws->Sample {feedback[index]}
 func wait(_ timeout:Double,_ body:()->Bool)async throws {
  for i in feedback.indices {index=i;clock=feedback[i].time;if clock>timeout{break};if body(){return}}
  throw Failure.timeout
 }
 func run(_ step:Step)async throws { /* ACTUAL */ }
}
@main enum Test {
 @MainActor static func main()async throws {
  let q=Array(repeating:0.0,count:7),goal=[0.0,-0.02,0,0,0,0,0],step=Step(positions:[0,-0.02,0,0,0,0,0],seconds:4)
  func samples(_ positions:[[Double]],times:[Double])->[Sample] {zip(positions.indices,times).map {i,t in
   .init(sequence:UInt64(i+1),positionsRadians:positions[i].map{NSNumber(value:$0)},time:t)}}
  func rejected(_ feedback:[Sample])async {
   let h=Harness();h.feedback=feedback
   do {try await h.run(step);preconditionFailure("An unreached or unstable segment advanced")}catch{}
  }
  // The old ordinary settler accepted a whole20mrad move without movement.
  await rejected(samples(Array(repeating:q,count:5),times:[0,1,2,3,4.1]))
  // Individually tiny errors can still exceed the aggregate next-start bound.
  var drift=goal;drift[0]+=0.001;drift[2]+=0.001;drift[4]+=0.001
  await rejected(samples(Array(repeating:drift,count:5),times:[0,1,2,3,4.1]))
  await rejected(samples([q,q,goal],times:[0,3.9,4.1]))
  await rejected(samples(Array(repeating:goal,count:5),times:[0,0.1,0.2,0.3,3.9]))
  await rejected(samples([goal,goal,goal,goal,drift,goal,goal],times:[0,0.1,0.2,0.3,3.9,4,4.1]))
  let h=Harness();h.feedback=samples([q,q,goal,goal,goal,goal],times:[0,3.5,3.8,3.9,4,4.1])
  try await h.run(step);precondition(h.clock>=4)
  print("PASS actual staged endpoint wait: untraveled, aggregate drift, unstable and early endpoints cannot advance; distinct stable reached endpoint passes; no hardware")
 }
}
'''.replace('/* TOLERANCE */', tolerance).replace('/* NEAR */', near).replace('/* SETTLER */', settler).replace('/* ACTUAL */', actual)
with tempfile.TemporaryDirectory(prefix='rob-staged-settling-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path',
                    '/private/tmp/cerebro-swift-module-cache', str(path / 'Fixture.swift'), '-o', str(path / 'fixture')], check=True)
    subprocess.run([str(path / 'fixture')], check=True)
