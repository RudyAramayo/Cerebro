#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${ROB_SHADOW_TEST_PYTHON:-$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3}"
fixture_dir="$(mktemp -d /private/tmp/rob-torso-fixture.XXXXXX)"
trap 'rm -r "$fixture_dir"' EXIT
"$python_bin" -B "$repo_dir/Tests/ROBTorsoMarkerlessTests.py"
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repo_dir/Cerebro/ROBTorsoMotionPolicy.swift" "$repo_dir/Cerebro/ROBTicVelocityTransport.swift" \
  "$repo_dir/Tests/ROBTorsoControlFixtureTests.swift" -o "$fixture_dir/policy"
"$fixture_dir/policy"
"$python_bin" - "$repo_dir" "$fixture_dir" <<'PY'
from pathlib import Path
import sys
source = (Path(sys.argv[1]) / "Cerebro/CameraManager.swift").read_text()
frames = source[source.index("enum CameraSource: String"):source.index("protocol CameraManagerDelegate:")]
roles = source[source.index("enum CameraRole: String"):source.index("struct CameraDeviceOption:")]
(Path(sys.argv[2]) / "CameraFrameTypes.swift").write_text("import Foundation\nimport CoreMedia\n" + frames + roles)
PY
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$fixture_dir/CameraFrameTypes.swift" "$repo_dir/Cerebro/ROBMarkerlessVisionService.swift" \
  "$repo_dir/Cerebro/ROBTorsoMotionPolicy.swift" "$repo_dir/Cerebro/ROBTicVelocityTransport.swift" \
  "$repo_dir/Cerebro/ROBTorsoControlCenter.swift" "$repo_dir/Cerebro/ROBTorsoControlWindowController.swift" \
  "$repo_dir/Tests/ROBTorsoCoordinatorFixtureTests.swift" -o "$fixture_dir/coordinator"
"$fixture_dir/coordinator"
"$python_bin" -B "$repo_dir/Tests/ROBTiccmdTaskLifecycleStaticTests.py"
"$python_bin" -B "$repo_dir/Tests/DepthCameraIPCFixtureTests.py"
