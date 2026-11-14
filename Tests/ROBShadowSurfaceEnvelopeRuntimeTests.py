#!/usr/bin/env python3
"""Verify the repaired envelope with the actual native convex/self-proxy code."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
from shadow_surface_envelope import serialized_convex_envelope


def sha(data):
    return hashlib.sha256(data).hexdigest()


resources = ROOT / "Cerebro/Resources/ShadowPlanner"
surface_bytes = (resources / "surfaces.json").read_bytes()
surfaces = json.loads(surface_bytes)
reference = json.loads((resources / "reference.json").read_bytes())
review = json.loads((resources / "clearance-review.json").read_bytes())
assert reference["surfacesSHA256"] == sha(surface_bytes) == review["surfacesSHA256"]
assert reference["modelID"] == surfaces["modelID"] == sha((resources / "model.urdf").read_bytes())
for entry in surfaces["surfaces"]:
    assert sha((resources / entry["hull"]).read_bytes()) == entry["hullSHA256"]
left = next(entry for entry in surfaces["surfaces"] if entry["link"] == "left_track_link")
evidence = left["envelopeConstruction"]
source = (resources / evidence["sourceHull"]).read_bytes()
canonical = (resources / left["hull"]).read_bytes()
assert sha(source) == evidence["sourceHullSHA256"]
source_lines = [line for line in source.splitlines(keepends=True) if line.startswith(b"v ")]
canonical_lines = [line for line in canonical.splitlines(keepends=True) if line.startswith(b"v ")]
assert len(source_lines) == 78 and source_lines == canonical_lines
assert sha(b"".join(source_lines)) == evidence["sourceVertexLinesSHA256"]
assert evidence["allSourceVertexLinesPreserved"] is True
assert sha((ROOT / evidence["generatorPath"]).read_bytes()) == evidence["generatorSHA256"]
assert sha((ROOT / evidence["envelopeAlgorithmPath"]).read_bytes()) == evidence["envelopeAlgorithmSHA256"]
points = np.asarray([[float(value) for value in line.split()[1:]] for line in source_lines])
regenerated, regenerated_evidence = serialized_convex_envelope(points)
assert regenerated.encode() == canonical
assert regenerated_evidence["sourceVertexCount"] == regenerated_evidence["envelopeVertexCount"] == 78
assert regenerated_evidence["maximumSerializedSourceOutsideMeters"] <= 1e-10
for invalid in [np.full((4, 3), np.nan), np.zeros((4, 3)), np.zeros((3, 3))]:
    try:
        serialized_convex_envelope(invalid)
    except Exception:
        pass
    else:
        raise AssertionError("Invalid source vertices generated an envelope")

ghost = (ROOT / "Cerebro/ROBGhostMotionPlan.swift").read_text()
collision = (ROOT / "Cerebro/ROBWorkspaceCollisionPlan.swift").read_text()
model = braced_declaration(ghost, "final class ROBGhostRobotModel {")
joint_bounds = braced_declaration(collision, "    static func jointBounds(model:")
jaw_allowance = next(line for line in collision.splitlines() if "static let openJawAdditionalMarginMeters =" in line)
hulls = collision[collision.index("struct ROBEstimatedConvexHull {"):collision.index("/// Original retained source-return bounds")]
fixture = r'''
import Foundation
import CryptoKit
import simd
enum ROBGhostMotionError:LocalizedError {
 case blocked(String)
 var errorDescription:String?{if case .blocked(let message)=self{return message};return nil}
}
// These corridor-only dependencies are unused by the actual FK/hull checks.
enum ROBLeftArmInteractionPlan {static let frontIndex=0;static func target(index:Int)->[Double]?{Array(repeating:0,count:7)}}
enum ROBLeftGestureCompiler {static let frontBounds=[ClosedRange<Double>](repeating:-3.1...3.1,count:7)}
enum ROBWorkspaceCollisionPlan {
__JOINT_BOUNDS__
__JAW_ALLOWANCE__
}
__MODEL__
__HULLS__
@main enum Main {
 static func main()throws {
  let directory=URL(fileURLWithPath:CommandLine.arguments[1])
  let repaired=try ROBEstimatedConvexHull(text:String(contentsOf:directory.appendingPathComponent("hulls/left_track_link.obj"),encoding:.utf8))
  let source=try String(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]),encoding:.utf8)
  var originalRejected=false
  do {_ = try ROBEstimatedConvexHull(text:source)}catch{originalRejected=true}
  precondition(originalRejected,"The original micron-scale convexity defect was not reproduced")
  for line in source.split(separator:"\n") where line.hasPrefix("v ") {
   let values=line.split(separator:" ").dropFirst().map{Double($0)!}
   let distance=try repaired.distance(to:SIMD3(values[0],values[1],values[2]))
   precondition(distance==0,
       "An original source vertex was removed from the envelope")
  }
  let zero=Array(repeating:0.0,count:7)
  for (side,expected) in [("left",-0.07079439955622627),("right",-0.014714339118161057)] {
   let model=try ROBGhostRobotModel(directory:directory,physicalSide:side)
   var checker=ROBWorkspaceSelfProxyClearance(model:model)
   let pairs=try checker.separations(vendorLeft:zero),minimum=pairs.min{$0.value<$1.value}!
   precondition(minimum.key==side+"_tool|"+side+"_track_upper_idler_link")
   precondition(abs(minimum.value-expected)<1e-10 && minimum.value<0.030,
       "Envelope repair waived or changed the actual hanging proxy overlap")
   print(side,"actual q0 strict convex clearance",minimum.value,"ordinary30mm still blocked")
  }
  print("Surface envelope PASS: original rejected, repaired strict hull accepted, all78 original vertices contained, both q0 conflicts retained; no hardware")
 }
}
'''.replace("__MODEL__", model).replace("__HULLS__", hulls).replace("__JOINT_BOUNDS__", joint_bounds).replace("__JAW_ALLOWANCE__", jaw_allowance)

with tempfile.TemporaryDirectory(prefix="rob-surface-envelope-", dir="/private/tmp") as directory:
    path = Path(directory)
    (path / "fixture.swift").write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-whole-module-optimization", "-parse-as-library",
                    "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                    str(ROOT / "Cerebro/ROBArmJointLimits.swift"), str(path / "fixture.swift"),
                    "-o", str(path / "fixture")], check=True)
    subprocess.run([str(path / "fixture"), str(resources), str(resources / evidence["sourceHull"])], check=True)

print("Generator/hash/source-containment regression PASS; canonical hull changes faces only")
