#!/usr/bin/env python3
"""Run the production cylinder admission and source-preserving reacquisition."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Cerebro/ROBWorkspaceSearchPlan.swift').read_text()
start = source.index('struct ROBWorkspaceCanSections: Codable {')
end = source.index('    static func measure(', start)
production = source[start:end] + '\n}\n'
fixture = r'''
import Foundation
import simd
/* PRODUCTION */
@main enum Test {
 static func main() {
  var measured = ROBWorkspaceCanSections(top:[0.6,0,0.87],middle:[0.6,0,0.81],bottom:[0.6,0,0.75],
      heightMeters:0.12,diameterMeters:0.066,surfaceToAxisOffsetMeters:[0.033,0,0])
  let assumed = ROBWorkspaceCanSections.localKnownEmptyCokeCylinder(base:SIMD3(0.6,0,0.75),axis:SIMD3(0,0,1),
      planeRMSEMeters:0.004,planePointCount:120,planeSupportFraction:0.8,silhouetteIoU:0.85,
      silhouetteMaximumEdgeErrorPixels:2)!
  precondition(measured.hasCylinderAxisGeometry && assumed.hasCylinderAxisGeometry)
  let fresh = measured.reacquireForVisualServo(measured:{measured},assumed:{fatalError("Measured target silently replaced by prior")})
  precondition(fresh?.shapePriorEvidence == nil && fresh?.surfaceToAxisOffsetMeters != nil)
  let freshPrior = assumed.reacquireForVisualServo(measured:{fatalError("Prior source silently changed")},assumed:{assumed})
  precondition(freshPrior?.shapePriorEvidence?.valid == true)
  precondition(measured.reacquireForVisualServo(measured:{nil},assumed:{fatalError("Lost depth fell back to assumption")}) == nil)
  precondition(assumed.reacquireForVisualServo(measured:{fatalError("Lost prior fell back to another source")},assumed:{nil}) == nil)
  precondition(measured.reacquireForVisualServo(measured:{assumed},assumed:{nil}) == nil)
  precondition(assumed.reacquireForVisualServo(measured:{nil},assumed:{measured}) == nil)
  var invalid = measured; invalid.surfaceToAxisOffsetMeters = [Double.nan,0,0]
  precondition(!invalid.hasCylinderAxisGeometry)
  precondition(measured.reacquireForVisualServo(measured:{invalid},assumed:{nil}) == nil)
  measured.surfaceToAxisOffsetMeters = nil
  precondition(measured.valid && !measured.hasCylinderAxisGeometry, "Legacy wall samples are not a cylinder axis")
  precondition(measured.reacquireForVisualServo(measured:{fatalError("Invalid original was used")},assumed:{nil}) == nil)
  print("PASS measured and scoped-prior cylinders; exact source retained; missing depth, invalid axes, legacy wall samples and source swaps rejected")
 }
}
'''.replace('/* PRODUCTION */', production)
with tempfile.TemporaryDirectory(prefix='rob-incremental-can-', dir='/private/tmp') as folder:
    path = Path(folder)
    (path / 'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(path / 'Fixture.swift'), '-o', str(path / 'fixture')], check=True)
    subprocess.run([str(path / 'fixture')], check=True, timeout=10)
