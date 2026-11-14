#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-unknown-approach.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
for mode in debug release; do
  command=(xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library)
  if [[ "$mode" == debug ]]; then command+=(-D DEBUG); fi
  "${command[@]}" -module-cache-path /private/tmp/cerebro-swift-module-cache \
    "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" "$repo_dir/Cerebro/ROBArmJointLimits.swift" \
    "$repo_dir/Cerebro/ROBArmControlProtocol.swift" "$repo_dir/Cerebro/ROBGhostMotionPlan.swift" \
    "$repo_dir/Cerebro/ROBWorkspaceSearchPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceCollisionPlan.swift" \
    "$repo_dir/Tests/ROBUnknownApproachAdvisoryFixtureTests.swift" -o "$fixture_dir/$mode"
  "$fixture_dir/$mode" "$repo_dir"
done
