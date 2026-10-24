#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-visual-grasp.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBVisualGraspVerifier.swift" \
  "$repo_dir/Tests/ROBVisualGraspVerifierFixtureTests.swift" \
  -o "$fixture_dir/grasp"
"$fixture_dir/grasp"
