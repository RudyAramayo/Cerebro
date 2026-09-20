#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${ROB_SHADOW_TEST_PYTHON:-$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3}"
fixture_dir="$(mktemp -d /private/tmp/rob-shadow-fixture.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
"$python_bin" -B "$repo_dir/Tests/ROBShadowPlannerTests.py"
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repo_dir/Cerebro/ROBShadowPlanningProtocol.swift" \
  "$repo_dir/Cerebro/ROBShadowPlannerBridge.swift" \
  "$repo_dir/Tests/ROBShadowPlannerBridgeFixtureTests.swift" -o "$fixture_dir/bridge"
"$fixture_dir/bridge" "$repo_dir" "$python_bin"
