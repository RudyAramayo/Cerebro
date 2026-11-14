#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_carry_fixture_dir=$(mktemp -d /private/tmp/rob-can-carry-preview.XXXXXX)
trap 'rm -rf "$task_carry_fixture_dir"' EXIT
xcrun swiftc -O -whole-module-optimization -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBArmRoutinePlan.swift Cerebro/ROBArmJointLimits.swift Cerebro/ROBArmControlProtocol.swift \
  Cerebro/ROBGhostMotionPlan.swift Cerebro/ROBWorkspaceSearchPlan.swift Cerebro/ROBWorkspaceCollisionPlan.swift \
  Tests/ROBCanCarryPreviewFixtureTests.swift -o "$task_carry_fixture_dir/fixture"
"$task_carry_fixture_dir/fixture" "$PWD"
