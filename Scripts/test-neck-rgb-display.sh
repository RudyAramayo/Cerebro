#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/rob-neck-rgb-display.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
cd "$task_root"
# Exercise both the opt-in DEMO branch and the production rejection branch.
for task_configuration in release debug; do
  task_compiler=(xcrun swiftc)
  if [[ "$task_configuration" == debug ]]; then task_compiler+=(-DDEBUG); fi
  "${task_compiler[@]}" -swift-version 5 -O -whole-module-optimization -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBArmRoutinePlan.swift Cerebro/ROBArmJointLimits.swift \
  Cerebro/ROBGhostMotionPlan.swift Cerebro/ROBWorkspaceSearchPlan.swift \
  Cerebro/ROBWorkspaceCollisionPlan.swift Cerebro/ROBWorkspaceDepthMap.swift \
  Cerebro/ROBFixedHeadRegistration.swift Cerebro/ROBEstimatedArmCalibrationPlan.swift \
  Cerebro/ROBNeckBundleEvidence.swift Cerebro/ROBEstimatedFixedHeadCapture.swift \
  Cerebro/ROBNeckRGBPoseDisplay.swift Tests/ROBNeckRGBPoseDisplayFixture.swift Tests/ROBNeckGravityPitchFixture.swift \
  -o "$task_temp/fixture-$task_configuration"
  "$task_temp/fixture-$task_configuration" "$task_root/Cerebro/Resources/ShadowPlanner"
  if [[ $# -gt 0 ]]; then
    "$task_temp/fixture-$task_configuration" "$task_root/Cerebro/Resources/ShadowPlanner" "$@"
  fi
done
