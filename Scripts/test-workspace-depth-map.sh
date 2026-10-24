#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_depth_fixture_dir=$(mktemp -d /private/tmp/rob-workspace-depth-map.XXXXXX)
trap 'rm -rf "$task_depth_fixture_dir"' EXIT
python3 - "$task_depth_fixture_dir/protocol.swift" <<'PY'
from pathlib import Path
import sys
source = Path("Cerebro/ROBWorkspaceCollisionPlan.swift").read_text()
Path(sys.argv[1]).write_text(source[:source.index("/// A measured object envelope")])
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBArmJointLimits.swift "$task_depth_fixture_dir/protocol.swift" Cerebro/ROBFixedHeadRegistration.swift Cerebro/ROBWorkspaceDepthMap.swift \
  Tests/ROBWorkspaceDepthMapFixtureTests.swift -o "$task_depth_fixture_dir/depth-map-fixtures"
"$task_depth_fixture_dir/depth-map-fixtures"
