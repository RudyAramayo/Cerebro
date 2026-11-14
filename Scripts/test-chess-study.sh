#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-chess-fixtures.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O \
  "$repo_dir/Cerebro/ROBChessStudyCore.swift" \
  "$repo_dir/Cerebro/ROBChessStudyVision.swift" \
  "$repo_dir/Cerebro/ROBChessStudySession.swift" \
  "$repo_dir/Cerebro/ROBLocalAgentBridge.swift" \
  "$repo_dir/Tests/ROBChessStudyFixtureTests.swift" \
  -o "$test_dir/chess-tests"
if [ "$#" -ge 1 ]; then fixture_dir="$1"; else fixture_dir="$repo_dir/build/chess-study-fixtures"; fi
"$test_dir/chess-tests" "$fixture_dir"
python3 "$repo_dir/Tests/DepthCameraIPCFixtureTests.py"
