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
parser.add_argument("--require-qr", action="store_true", help="Require native QR payloads in represented textures and rendered pixels (native or 2x nearest scale); report native-scale results separately")
parser.add_argument("--max-qr-corner-error-pixels", type=float, help="Maximum source/render QR corner displacement at native resolution")
parser.add_argument("--require-native-render-qr", action="store_true", help="Also require QR decoding without enlarging the rendered scene")
parser.add_argument("--warmup-frames", type=int, default=1, help="Explicit number of initial captures excluded from decoding assertions (default: 1); all remain in the report")
parser.add_argument("--expected-can-count", type=int, help="Require this many persistent can identities in a stationary capture")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="rob-surface-replay-", dir="/private/tmp") as temporary:
    executable = Path(temporary) / "replay"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror", "-I", str(root / "Cerebro"),
                    str(root / "Tests/ROBAccumulatedSurfaceReplay.m"), str(root / "Cerebro/ROBAccumulatedSurfaceRenderer.m"),
                    "-framework", "AppKit", "-framework", "SceneKit", "-framework", "CoreVideo", "-framework", "Vision", "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(args.capture_input), str(args.output_directory)], check=True)
report = json.loads((args.output_directory / "report.json").read_text())
assert 0 <= args.warmup_frames < len(report["frames"]), "Warm-up must leave frames to verify"
visible = report["frames"][args.warmup_frames:]
assert visible, "Need at least one reconstructed frame after warm-up"
if args.require_qr:
    for frame in visible:
        assert frame["nativeQR"], "Capture must contain a natively readable QR target"
        assert set(frame["nativeQR"]) <= set(frame["reconstructedQR"]), frame
        assert set(frame["nativeQR"]) <= set(frame["renderedQR"]), frame
    assert sum(f["textureProbesCompared"] for f in visible) > 0, "Texture stability was not measured"
    assert not any(f["textureProbesChanged"] for f in visible), "Previously observed QR texture pixels changed"
if args.max_qr_corner_error_pixels is not None:
    assert args.require_qr, "Corner-error checking requires successful QR decoding"
    assert all(f["maxRenderQRCornerErrorPixels"] <= args.max_qr_corner_error_pixels for f in visible), "QR corners drifted after reconstruction"
if args.require_native_render_qr:
    assert args.require_qr, "Native-resolution checking requires --require-qr"
    assert all(set(f["nativeQR"]) <= set(f["renderedNativeResolutionQR"]) for f in visible), "Native-size rendered QR decoding failed"
if args.expected_can_count is not None:
    expected = sorted(visible[0]["canIDs"])
    assert len(expected) == args.expected_can_count, visible[0]
    assert all(sorted(f["canIDs"]) == expected for f in visible), "Can tracks flashed or changed identity"
print(f"Verified {len(visible)} reconstructed frames; {sum(f['textureProbesCompared'] for f in visible)} world-anchored texture comparisons, no camera/actuator IO.")
