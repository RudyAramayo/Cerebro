#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-geometry-fixtures.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc \
  "$repo_dir/Cerebro/ROBAmberB1Kinematics.swift" \
  "$repo_dir/Cerebro/ROBRobotGeometry.swift" \
  "$repo_dir/Cerebro/ROBRobotGeometryDocument.swift" \
  "$repo_dir/Tests/ROBRobotGeometryFixtureTests.swift" \
  -o "$test_dir/geometry-tests"
"$test_dir/geometry-tests"
