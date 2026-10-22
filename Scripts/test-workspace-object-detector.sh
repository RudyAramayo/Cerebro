#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-object-detector.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBWorkspaceObjectDetector.swift" \
  "$repo_dir/Tests/ROBWorkspaceObjectDetectorFixtureTests.swift" \
  -o "$fixture_dir/detector"
"$fixture_dir/detector"
