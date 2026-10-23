#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-left-arm-trial.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" "$repo_dir/Cerebro/ROBArmJointLimits.swift" \
  "$repo_dir/Cerebro/ROBGhostMotionPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceSearchPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceCollisionPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceDepthMap.swift" \
  "$repo_dir/Cerebro/ROBRobotActionProtocol.swift" \
  "$repo_dir/Cerebro/ROBControllerArmApproval.swift" \
  "$repo_dir/Cerebro/ROBLeftArmTrial.swift" \
  "$repo_dir/Tests/ROBLeftArmTrialFixtureTests.swift" \
  -o "$fixture_dir/left-arm"
cp -R "$repo_dir/Cerebro/Resources/ShadowPlanner" "$fixture_dir/ShadowPlanner"
"$fixture_dir/left-arm" "$repo_dir" "$@"
