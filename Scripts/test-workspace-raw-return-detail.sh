#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_raw_detail_dir=$(mktemp -d /private/tmp/rob-raw-return-detail.XXXXXX)
trap 'rm -rf "$task_raw_detail_dir"' EXIT
xcrun swiftc -O -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBArmRoutinePlan.swift Cerebro/ROBArmJointLimits.swift Cerebro/ROBArmControlProtocol.swift \
  Cerebro/ROBGhostMotionPlan.swift Cerebro/ROBWorkspaceSearchPlan.swift Cerebro/ROBWorkspaceCollisionPlan.swift \
  Tests/ROBWorkspaceRawReturnDetailFixtureTests.swift -o "$task_raw_detail_dir/fixture"
"$task_raw_detail_dir/fixture" "$PWD"
