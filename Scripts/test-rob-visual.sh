#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-visual-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cp "$repo_dir/Cerebro/rob-visual.json" "$test_dir/rob-visual.json"
xcrun swiftc "$repo_dir/Cerebro/ROBScanVisualModel.swift" "$repo_dir/Tests/ROBScanVisualModelTests.swift" -o "$test_dir/visual-tests"
"$test_dir/visual-tests" "$@"
