#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-animation-entry.XXXXXX)"
trap 'rm -r "$fixture_dir"' EXIT
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" "$repo_dir/Cerebro/ROBArmJointLimits.swift" \
  "$repo_dir/Cerebro/ROBAnimationDocument.swift" "$repo_dir/Cerebro/ROBGhostMotionPlan.swift" \
  "$repo_dir/Cerebro/ROBWorkspaceSearchPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceCollisionPlan.swift" \
  "$repo_dir/Tests/ROBAnimationEntryGeometryTests.swift" -o "$fixture_dir/check"
"$fixture_dir/check" "$repo_dir"
