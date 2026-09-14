#!/usr/bin/env python3
"""Read only the two boot launch files and their selected URDFs; never actuate."""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET


def audit(root: Path) -> dict:
    report = {
        "scope": "Files under the supplied Amber root; this is not proof of what a running core loaded.",
        "units": {"translation": "meters", "rotation": "radians"},
        "arms": [],
    }
    for folder in ("L-10", "R-11"):
        directory = root / folder
        launch = directory / "launch.json"
        config = json.loads(launch.read_text())
        solver = config["Solver"]
        # Relative paths are resolved from the per-arm CWD in rc.local.
        path = (directory / solver["URDF_Path"]).resolve()
        if not path.is_relative_to(root.resolve()):
            raise ValueError("Selected URDF escapes the supplied Amber root")
        data = path.read_bytes()
        if len(data) > 5_000_000 or b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
            raise ValueError("Refusing oversized URDF or entity declarations")
        robot = ET.fromstring(data)
        joints = robot.findall("joint")
        by_child = {j.find("child").attrib["link"]: j for j in joints}
        if len(by_child) != len(joints):
            raise ValueError("Multiple parents in selected URDF")
        chain, cursor, visited = [], solver["EEF_Name"], set()
        while cursor != solver["Base_Name"]:
            if cursor in visited or cursor not in by_child:
                raise ValueError("Missing or cyclic base-to-tip chain")
            visited.add(cursor)
            joint = by_child[cursor]
            chain.append({"name": joint.attrib["name"], "type": joint.attrib["type"],
                          "parent": joint.find("parent").attrib["link"], "child": cursor,
                          "origin": joint.find("origin").attrib if joint.find("origin") is not None else {},
                          "axis": joint.find("axis").attrib if joint.find("axis") is not None else {},
                          "limit": joint.find("limit").attrib if joint.find("limit") is not None else {}})
            cursor = joint.find("parent").attrib["link"]
        chain.reverse()
        report["arms"].append({
            "boot_directory": folder, "launch": str(launch.relative_to(root)),
            "launch_sha256": hashlib.sha256(launch.read_bytes()).hexdigest(),
            "solver_type": solver["Type"], "enabled": solver["Enable"],
            "selected_urdf": str(path.relative_to(root.resolve())),
            "urdf_sha256": hashlib.sha256(data).hexdigest(),
            "base": solver["Base_Name"], "tip": solver["EEF_Name"],
            "lcm_prefix": config["LCM_Interface"]["Prefix"],
            "robot_direction": config["Robot"]["Rotation_Direction"],
            "solver_direction": solver["Rotation_Direction"], "chain": chain,
        })
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--amber-root", required=True, type=Path,
                        help="Directory containing L-10 and R-11; for example ../Amber-HomeFolder/amber")
    args = parser.parse_args()
    print(json.dumps(audit(args.amber_root), indent=2, sort_keys=True))
