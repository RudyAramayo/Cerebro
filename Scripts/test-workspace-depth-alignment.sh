#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_alignment_fixture_dir=$(mktemp -d /private/tmp/rob-workspace-depth-alignment.XXXXXX)
trap 'rm -rf "$task_alignment_fixture_dir"' EXIT
# Compile the actual shared alignment implementation independently of robot
# transport, native UI, and model fixtures. No preferences or hardware touched.
python3 - "$task_alignment_fixture_dir/alignment.swift" <<'PY'
from pathlib import Path
import sys
source = Path("Cerebro/ROBWorkspaceSearchPlan.swift").read_text()
Path(sys.argv[1]).write_text(source[:source.index("enum ROBWorkspaceTarget:")])
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$task_alignment_fixture_dir/alignment.swift" Tests/ROBWorkspaceDepthAlignmentFixtureTests.swift \
  -o "$task_alignment_fixture_dir/alignment-fixtures"
"$task_alignment_fixture_dir/alignment-fixtures"
