#!/usr/bin/env python3
"""Preview production left-arm waypoints in the bundled model; no hardware IO.

Run with the existing ShadowPlanner venv's Python. Driver signs and the old
upright reference are explicit assumptions, never runtime calibration.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Cerebro/Resources/ShadowPlanner"
sys.path.insert(0, str(RESOURCES))
from worker import ShadowPlanner


def json_scalar(value):
    if isinstance(value, np.generic):
        return value.item()
    raise TypeError(f"Unsupported preview value: {type(value).__name__}")


def production_waypoints():
    with tempfile.TemporaryDirectory(prefix="rob-interaction-preview-") as directory:
        directory = Path(directory)
        source = directory / "main.swift"
        source.write_text('import Foundation\n'
                          'let data = try JSONEncoder().encode(ROBLeftArmInteractionPlan.waypoints)\n'
                          'print(String(data: data, encoding: .utf8)!)\n')
        executable = directory / "waypoints"
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                        str(ROOT / "Cerebro/ROBArmRoutinePlan.swift"), str(source), "-o", str(executable)], check=True)
        return json.loads(subprocess.check_output([str(executable)]))


def tread_separation_lower_bound(planner, q):
    """Rigid-hull AABB distance: a model-space lower bound, not physical proof."""
    planner.plant.SetPositions(planner.context, q)
    boxes = {}
    for name, corners in planner.clearance.boxes.items():
        transform = planner.plant.CalcRelativeTransform(planner.context, planner.plant.world_frame(),
                                                        planner.plant.GetFrameByName(name, planner.model))
        points = transform @ corners.T
        boxes[name] = (points.min(axis=1), points.max(axis=1))
    arms = [name for name in boxes if name.startswith("left_") and planner.clearance.is_arm(name)]
    treads = [name for name in boxes if any(word in name for word in ("track", "sprocket", "flipper"))]
    candidates = []
    for a in arms:
        for b in treads:
            separation = np.maximum(0, np.maximum(boxes[a][0] - boxes[b][1], boxes[b][0] - boxes[a][1]))
            candidates.append((float(np.linalg.norm(separation)), [a, b]))
    distance, pair = min(candidates, key=lambda value: value[0])
    return dict(distanceMeters=distance, pair=pair)


def preview():
    planner = ShadowPlanner(RESOURCES)
    waypoints = production_waypoints()
    zero = np.array([0, 2.080432, 0, -0.687254, 0, 0.027043, 0])
    rows, previous = [], None
    for index in range(6, len(waypoints)):
        vendor = np.array(waypoints[index])
        q = planner.q0.copy()
        q[planner.indices] = vendor - zero
        collision = planner.clearance.check(q)
        sweep = planner.clearance.transition(previous, q) if previous is not None else None
        all_pairs = planner.clearance.pairs
        planner.clearance.pairs = [(a, b) for a, b in all_pairs
                                   if ((a.startswith("left_") and planner.clearance.is_arm(a)
                                        and any(word in b for word in ("track", "sprocket", "flipper")))
                                       or (b.startswith("left_") and planner.clearance.is_arm(b)
                                           and any(word in a for word in ("track", "sprocket", "flipper"))))]
        try:
            tread_sweep = planner.clearance.transition(previous, q) if previous is not None else None
        finally:
            planner.clearance.pairs = all_pairs
        treads = tread_separation_lower_bound(planner, q)
        tool = planner.plant.CalcRelativeTransform(planner.context, planner.plant.world_frame(), planner.tip)
        rows.append(dict(waypoint=index, vendorRadians=vendor.tolist(), modelRadians=(vendor - zero).tolist(),
                         toolXYZMeters=tool.translation().tolist(), fullModelClearance=collision,
                         sweepFromPrevious=sweep, treadSeparationLowerBound=treads,
                         treadSweepFromPrevious=tread_sweep))
        previous = q
    return dict(schemaVersion=1, simulationOnly=True, hardwareOutputEnabled=False,
                modelID=planner.reference["modelID"], referenceID=planner.reference["referenceID"],
                planSourceSHA256=hashlib.sha256((ROOT / "Cerebro/ROBArmRoutinePlan.swift").read_bytes()).hexdigest(),
                vendorAtModelZeroPrior=zero.tolist(), driverDirectionAssumption=[1] * 7,
                assumptions=["Positive driver directions are not a measured calibration.",
                             "September 22 upright coordinates are a prior, not a session-bound measurement.",
                             "Other joints use the scan estimate, not live robot positions.",
                             "Tool offset and hulls are provisional; cables, payloads and surroundings are unverified."],
                waypoints=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = preview()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, default=json_scalar) + "\n")
    print(f"Saved {len(result['waypoints'])} model-only poses to {args.output}")
    print("Full-model and swept warnings remain in the record; no physical clearance is certified.")
