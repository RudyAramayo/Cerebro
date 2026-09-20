#!/usr/bin/env python3
"""Derive a portable, mesh-free FK/IK model; never alter the approved source."""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("bundle", type=Path)
args = parser.parse_args()
source = args.bundle / "rob_droid.urdf"
profile_path = args.bundle / "calibration.json"
profile = json.loads(profile_path.read_text())
assert profile["simulationOnly"] is True
root = ET.fromstring(source.read_bytes())
for link in root.findall("link"):
    for node in list(link):
        link.remove(node)  # kinematics only; no meshes, inertias or collision claims
output = Path(__file__).resolve().parents[1] / "Cerebro/Resources/ShadowPlanner"
output.mkdir(parents=True, exist_ok=True)
ET.indent(root)
model = ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"
(output / "model.urdf").write_bytes(model)
reference = dict(simulationOnly=True, modelID=hashlib.sha256(model).hexdigest(),
                 referenceID=hashlib.sha256(profile_path.read_bytes()).hexdigest(),
                 approvedURDFSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
                 referenceSource="approved_scan_estimate", frame="base_link",
                 axes="X forward, Y ROB-left, Z up; meters/radians",
                 activeArm="left", hardwareLabel="R-11", positions=profile["previewPositions"],
                 provisionalCenteredLimitRadians=2.0943951023931953,
                 toolNote="Provisional 110 mm tool offset; not a measured grasp point.",
                 note="Only left R-11 moves. Base, torso, right arm and all other joints stay at the scan reference. Right J2 +120.417 degrees exceeds the provisional +120 range and is not enabled. Cable travel and collisions are unverified.")
(output / "reference.json").write_text(json.dumps(reference, indent=2, sort_keys=True) + "\n")
print(json.dumps({"modelID": reference["modelID"], "links": len(root.findall('link')), "output": str(output)}))
