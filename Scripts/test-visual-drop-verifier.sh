#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-visual-drop.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -emit-executable \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBVisualGraspVerifier.swift" \
  "$repo_dir/Tests/ROBVisualDropVerifierFixtureTests.swift" \
  -o "$fixture_dir/drop"
"$fixture_dir/drop"
