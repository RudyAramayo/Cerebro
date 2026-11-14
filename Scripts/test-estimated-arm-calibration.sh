#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-estimated-calibration.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBArmJointLimits.swift" "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" \
  "$repo_dir/Cerebro/ROBGhostMotionPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceSearchPlan.swift" \
  "$repo_dir/Cerebro/ROBWorkspaceCollisionPlan.swift" "$repo_dir/Cerebro/ROBFixedHeadRegistration.swift" "$repo_dir/Cerebro/ROBWorkspaceDepthMap.swift" \
  "$repo_dir/Cerebro/ROBEstimatedArmCalibrationPlan.swift" "$repo_dir/Tests/ROBEstimatedArmCalibrationFixtureTests.swift" \
  -o "$fixture_dir/estimated"
"$fixture_dir/estimated" "$repo_dir"
