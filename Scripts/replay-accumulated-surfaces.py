#!/usr/bin/env python3
"""Replay saved native RGB-D captures through the production reconstruction.

No camera, robot service, calibration installation or actuator is opened.
"""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("capture_input", type=Path)
parser.add_argument("output_directory", type=Path)
parser.add_argument("--require-qr", action="store_true", help="Require all native QR payloads in both the reconstructed texture and rendered scene after warm-up")
parser.add_argument("--expected-can-count", type=int, help="Require this many persistent can identities in a stationary capture")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="rob-surface-replay-", dir="/private/tmp") as temporary:
    executable = Path(temporary) / "replay"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror", "-I", str(root / "Cerebro"),
                    str(root / "Tests/ROBAccumulatedSurfaceReplay.m"), str(root / "Cerebro/ROBAccumulatedSurfaceRenderer.m"),
                    "-framework", "AppKit", "-framework", "SceneKit", "-framework", "CoreVideo", "-framework", "Vision", "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(args.capture_input), str(args.output_directory)], check=True)
report = json.loads((args.output_directory / "report.json").read_text())
visible = report["frames"][1:]
assert visible, "Need at least one reconstructed frame after warm-up"
if args.require_qr:
    for frame in visible:
        assert frame["nativeQR"], "Capture must contain a natively readable QR target"
        assert set(frame["nativeQR"]) <= set(frame["reconstructedQR"]), frame
        assert set(frame["nativeQR"]) <= set(frame["renderedQR"]), frame
    assert sum(f["textureProbesCompared"] for f in visible) > 0, "Texture stability was not measured"
    assert not any(f["textureProbesChanged"] for f in visible), "Previously observed QR texture pixels changed"
if args.expected_can_count is not None:
    expected = sorted(visible[0]["canIDs"])
    assert len(expected) == args.expected_can_count, visible[0]
    assert all(sorted(f["canIDs"]) == expected for f in visible), "Can tracks flashed or changed identity"
print(f"Verified {len(visible)} reconstructed frames; {sum(f['textureProbesCompared'] for f in visible)} world-anchored texture comparisons, no camera/actuator IO.")
