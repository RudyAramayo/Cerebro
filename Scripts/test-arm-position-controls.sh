#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-arm-controls.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repo_dir/Cerebro/ROBArmJointLimits.swift" "$repo_dir/Tests/ROBArmPositionControlFixtureTests.swift" \
  -o "$fixture_dir/controls"
"$fixture_dir/controls"
