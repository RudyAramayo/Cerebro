#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-source-pixel-self.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
# Snapshot the owned source: unrelated team builds can safely continue.
cat "$repo_dir/Cerebro/ROBWorkspaceCollisionPlan.swift" "$repo_dir/Tests/ROBSourcePixelSelfFixtureTests.swift" > "$fixture_dir/ActualCollisionAndFixture.swift"
xcrun swiftc -swift-version 5 -D DEBUG -O -whole-module-optimization -parse-as-library -emit-executable \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" "$repo_dir/Cerebro/ROBArmJointLimits.swift" "$repo_dir/Cerebro/ROBArmControlProtocol.swift" \
  "$repo_dir/Cerebro/ROBGhostMotionPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceSearchPlan.swift" \
  "$repo_dir/Cerebro/ROBFixedHeadRegistration.swift" "$repo_dir/Cerebro/ROBWorkspaceDepthMap.swift" \
  "$fixture_dir/ActualCollisionAndFixture.swift" -o "$fixture_dir/fixture"
"$fixture_dir/fixture" "$repo_dir" "$@"
