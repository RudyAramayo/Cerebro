#!/usr/bin/env python3
"""Actual immutable native human-observation adapter; no image/device or motion."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
evidence=braced_declaration(source,'struct ROBArmHumanObservationEvidence {')
method=braced_declaration(source,'private static func makeHumanObservations(')
offer=braced_declaration(source,'func offer(_ frame: CameraFrameSet, role: CameraRole)')
assert 'humanRequestsSucceeded=false' in offer and 'humanRequestsSucceeded=true' in offer
assert 'requestSucceeded:humanRequestsSucceeded' in offer and 'humanObservations:humanObservations' in offer
assert 'people.upperBodyOnly = true' in offer and 'hands.maximumHandCount = 6' in offer
assert 'clear = !(hands.results ?? []).contains { $0.confidence >= 0.3 }' in offer
assert 'if distances.isEmpty || distances.min()! < 1200 { clear = false }' in offer
swift=r'''
import Foundation
import Vision
/* EVIDENCE */
final class Harness {
 /* METHOD */
 static func observe(hands:[VNHumanHandPoseObservation]?,people:[VNHumanObservation]?,success:Bool=true,
  sequence:UInt64=7,captured:Double=12345,generation:UUID,width:Int=640,height:Int=480)->ROBArmHumanObservationEvidence {
  makeHumanObservations(hands:hands,people:people,requestSucceeded:success,sequence:sequence,
   capturedAt:captured,cameraGeneration:generation,width:width,height:height)
 }
}
@main enum Fixture {
 static func main() {
  let generation=UUID()
  let empty=Harness.observe(hands:[],people:[],generation:generation)
  precondition(empty.localizationSucceeded && empty.regions.isEmpty)
  precondition(empty.sequence==7 && empty.capturedAtMilliseconds==12345 && empty.cameraGeneration==generation)
  precondition(empty.width==640 && empty.height==480 && empty.handObservationCount==0 && empty.personObservationCount==0)
  for unknown in [Harness.observe(hands:nil,people:[],generation:generation),
   Harness.observe(hands:[],people:nil,generation:generation),
   Harness.observe(hands:[],people:[],success:false,generation:generation)] {
   precondition(!unknown.localizationSucceeded && unknown.unavailableReason != nil)
  }
  // Actual native observation object; rectangle conversion must retain its
  // original upper-body extent and label rather than claim visible legs.
  let nativePerson=VNHumanObservation(boundingBox:CGRect(x:0.2,y:0.3,width:0.25,height:0.4))
  let person=Harness.observe(hands:[],people:[nativePerson],generation:generation)
  precondition(person.localizationSucceeded && person.personObservationCount==1 && person.regions.count==1)
  let region=person.regions[0],bounds=region.normalizedTopLeft
  precondition(region.kind == .person && region.upperBodyOnly && region.confidence==Double(nativePerson.confidence))
  precondition(abs(bounds.xMin-0.2)<1e-12 && abs(bounds.xMax-0.45)<1e-12)
  precondition(abs(bounds.yMin-0.3)<1e-12 && abs(bounds.yMax-0.7)<1e-12)
  precondition(!Harness.observe(hands:[],people:Array(repeating:nativePerson,count:32),generation:generation).localizationSucceeded)
  precondition(!Harness.observe(hands:[],people:[],sequence:0,generation:generation).localizationSucceeded)
  precondition(!Harness.observe(hands:[],people:[],captured:.nan,generation:generation).localizationSucceeded)
  precondition(!Harness.observe(hands:[],people:[],generation:generation,width:0).localizationSucceeded)
  let points=(0..<21).map {index in ROBArmHumanObservationEvidence.Point(x:0.3+Double(index%5)*0.02,
   y:0.5+Double(index/5)*0.02,confidence:0.8)}
  let hand=ROBArmHumanObservationEvidence.handBounds(points:points)!
  precondition(hand.xMin<=0.26+1e-12 && hand.xMax>=0.42-1e-12 && hand.yMin<=0.38+1e-12 && hand.yMax>=0.54-1e-12)
  precondition(ROBArmHumanObservationEvidence.handBounds(points:Array(points.dropLast()))==nil)
  var poor=points;poor[3] = .init(x:0.3,y:0.5,confidence:0.09)
  precondition(ROBArmHumanObservationEvidence.handBounds(points:poor)==nil)
  poor[3] = .init(x:.nan,y:0.5,confidence:0.9)
  precondition(ROBArmHumanObservationEvidence.handBounds(points:poor)==nil)
  poor[3] = .init(x:1.01,y:0.5,confidence:0.9)
  precondition(ROBArmHumanObservationEvidence.handBounds(points:poor)==nil)
  print("PASS actual native immutable humanadapter: sameframeidentity/nativepersonTOPLEFT+upperbodylabel; successfulzero distinguishedfromfailure/nil; saturated/malformed holds; all21handpoints conservativeenvelope; legacyhandveto unchanged. No image/device/clearancetoken or motion.")
 }
}
'''.replace('/* EVIDENCE */',evidence).replace('/* METHOD */',method)
with tempfile.TemporaryDirectory(prefix='rob-native-human-observation-',dir='/private/tmp') as folder:
 path=Path(folder);(path/'Fixture.swift').write_text(swift)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-parse-as-library',str(path/'Fixture.swift'),'-o',str(path/'fixture')],check=True,timeout=35)
 subprocess.run([str(path/'fixture')],check=True,timeout=10)
