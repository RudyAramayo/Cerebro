#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${ROB_SHADOW_TEST_PYTHON:-$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3}"
fixture_dir="$(mktemp -d /private/tmp/rob-shadow-fixture.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
"$python_bin" -B "$repo_dir/Tests/ROBShadowPlannerTests.py"
OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 "$python_bin" -B "$repo_dir/Tests/ROBShadowSafetyTests.py"
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repo_dir/Cerebro/ROBShadowPlanningProtocol.swift" \
  "$repo_dir/Cerebro/ROBShadowPlannerBridge.swift" \
  "$repo_dir/Tests/ROBShadowPlannerBridgeFixtureTests.swift" -o "$fixture_dir/bridge"
"$fixture_dir/bridge" "$repo_dir" "$python_bin"
# Compile the actual lightweight frame declarations without starting the app's
# camera manager or importing its hardware/window dependencies.
"$python_bin" - "$repo_dir" "$fixture_dir" <<'PY'
from pathlib import Path
import sys
source = (Path(sys.argv[1]) / "Cerebro/CameraManager.swift").read_text()
frames = source[source.index("enum CameraSource: String"):source.index("protocol CameraManagerDelegate:")]
roles = source[source.index("enum CameraRole: String"):source.index("struct CameraDeviceOption:")]
(Path(sys.argv[2]) / "CameraFrameTypes.swift").write_text("import Foundation\nimport CoreMedia\n" + frames + roles)
PY
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$fixture_dir/CameraFrameTypes.swift" \
  "$repo_dir/Cerebro/ROBMarkerlessVisionService.swift" \
  "$repo_dir/Tests/ROBMarkerlessVisionServiceFixtureTests.swift" -o "$fixture_dir/vision"
"$fixture_dir/vision" "$python_bin"
