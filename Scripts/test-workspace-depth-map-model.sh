#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_depth_model_dir=$(mktemp -d /private/tmp/rob-workspace-depth-model.XXXXXX)
trap 'rm -rf "$task_depth_model_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBArmJointLimits.swift Cerebro/ROBArmRoutinePlan.swift Cerebro/ROBGhostMotionPlan.swift Cerebro/ROBWorkspaceSearchPlan.swift \
  Cerebro/ROBWorkspaceCollisionPlan.swift Cerebro/ROBFixedHeadRegistration.swift Cerebro/ROBWorkspaceDepthMap.swift \
  Tests/ROBWorkspaceDepthMapModelFixtureTests.swift -o "$task_depth_model_dir/depth-model-fixtures"
"$task_depth_model_dir/depth-model-fixtures" "$PWD"
