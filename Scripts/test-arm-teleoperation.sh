#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-teleoperation.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
 "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" \
 "$repo_dir/Cerebro/ROBArmJointLimits.swift" \
 "$repo_dir/Cerebro/ROBGhostMotionPlan.swift" \
 "$repo_dir/Cerebro/ROBWorkspaceSearchPlan.swift" \
 "$repo_dir/Cerebro/ROBWorkspaceCollisionPlan.swift" \
 "$repo_dir/Cerebro/ROBArmControlProtocol.swift" \
 "$repo_dir/Cerebro/ROBArmTeleoperationPlanner.swift" \
 "$repo_dir/Cerebro/ROBShadowPlanningProtocol.swift" \
 "$repo_dir/Cerebro/ROBSerialChainKinematics.swift" \
 "$repo_dir/Cerebro/ROBArmTeleoperationProtocol.swift" \
 "$repo_dir/Cerebro/ROBArmTeleoperationKinematics.swift" \
 "$repo_dir/Tests/ROBArmTeleoperationFixture.swift" -o "$fixture_dir/teleoperation"
"$fixture_dir/teleoperation" "$repo_dir"
