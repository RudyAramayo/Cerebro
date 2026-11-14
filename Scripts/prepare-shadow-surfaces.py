#!/usr/bin/env python3
"""Pin approved rigid scan segments for markerless fitting and clearance.

No original mesh or joint origin is modified. Convex envelopes deliberately
include every segment vertex; the point samples are only for visual fitting.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from shadow_surface_envelope import serialized_convex_envelope

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("rig", type=Path)
args = parser.parse_args()
output = Path(__file__).resolve().parents[1] / "Cerebro/Resources/ShadowPlanner"
reference = json.loads((output / "reference.json").read_text())
rig = json.loads(args.rig.read_bytes())
assert rig["simulationOnly"] and rig["provenance"]["profileSHA256"] == reference["referenceID"]
assert rig["profile"]["previewPositions"] == reference["positions"]
surfaces = []
mesh_dir = output / "hulls"
mesh_dir.mkdir(exist_ok=True)
for part in rig["segments"]:
    points = np.frombuffer(base64.b64decode(part["positions"]), dtype="<f4").reshape(-1, 3).astype(float)
    normals = np.frombuffer(base64.b64decode(part["normals"]), dtype="<f4").reshape(-1, 3).astype(float)
    mesh, envelope = serialized_convex_envelope(points)
    path = mesh_dir / (part["link"] + ".obj")
    path.write_text(mesh)
    # Deterministic 5 mm voxel representatives, then a bounded uniform sample.
    _, ids = np.unique(np.round(points / .005).astype(int), axis=0, return_index=True)
    ids = ids[np.linspace(0, len(ids) - 1, min(800, len(ids)), dtype=int)]
    surfaces.append(dict(link=part["link"], points=np.round(points[ids], 6).tolist(),
                         normals=np.round(normals[ids], 6).tolist(),
                         hull=str(path.relative_to(output)), hullSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                         envelopeConstruction=envelope,
                         radius=float(np.max(np.linalg.norm(points, axis=1)))))
document = dict(schemaVersion=1, modelID=reference["modelID"], referenceID=reference["referenceID"],
                sourceSHA256=hashlib.sha256(args.rig.read_bytes()).hexdigest(),
                provenance=rig["provenance"], surfaces=surfaces,
                limitations="Rigid scan assignments are provisional; cables, missing surfaces, payloads and the environment are not certified.")
path = output / "surfaces.json"
path.write_text(json.dumps(document, separators=(",", ":")) + "\n")
reference["surfacesSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
reference["activeArms"] = {"left": "R-11", "right": "L-10"}
reference.pop("activeArm", None); reference.pop("hardwareLabel", None)
reference["note"] = "Both arms support shadow IK. Right J2's scan reference remains outside the provisional range; a visually reconciled in-range pose is required. No cable or hardware travel is certified."
(output / "reference.json").write_text(json.dumps(reference, indent=2, sort_keys=True) + "\n")
sys.path.insert(0, str(output))
from worker import ShadowPlanner
planner = ShadowPlanner(directory=output)
violations = [result for pair in planner.clearance.pairs
              if not (result := planner.clearance.check(planner.q0, pairs=[pair]))["clear"]]
violations.sort(key=lambda result: result["distance"])
review = dict(modelID=reference["modelID"], referenceID=reference["referenceID"],
              surfacesSHA256=reference["surfacesSHA256"], marginMeters=.025,
              source="approved_scan_estimate", hardwareOutputEnabled=False, violations=violations,
              note="Convex rigid scan envelopes; these overlaps do not establish physical collisions. Review torso concavity and rigid segment assignments. No exclusions added to hide conflicts.")
(output / "clearance-review.json").write_text(json.dumps(review, indent=2) + "\n")
print(f"Prepared {len(surfaces)} convex hulls and markerless sample sets; {len(violations)} reference clearance conflicts")
