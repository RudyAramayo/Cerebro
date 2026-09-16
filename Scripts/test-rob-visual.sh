#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-visual-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
for asset in rob-visual.json rob-captured.bin rob-captured-colors.png; do cp "$repo_dir/Cerebro/$asset" "$test_dir/$asset"; done
xcrun swiftc "$repo_dir/Cerebro/ROBScanVisualModel.swift" "$repo_dir/Tests/ROBScanVisualModelTests.swift" -o "$test_dir/visual-tests"
"$test_dir/visual-tests" "$@"
