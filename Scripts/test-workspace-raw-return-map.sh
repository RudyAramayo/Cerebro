#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_raw_map_dir=$(mktemp -d /private/tmp/rob-raw-return-map.XXXXXX)
trap 'rm -rf "$task_raw_map_dir"' EXIT
# Concatenate the unchanged production source and fixture so the test can
# inspect its fileprivate canonical identity without adding a runtime API.
cat Cerebro/ROBWorkspaceDepthMap.swift Tests/ROBWorkspaceRawReturnMapFixtureTests.swift > "$task_raw_map_dir/MapFixture.swift"
xcrun swiftc -O -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBArmRoutinePlan.swift Cerebro/ROBArmJointLimits.swift Cerebro/ROBArmControlProtocol.swift \
  Cerebro/ROBGhostMotionPlan.swift Cerebro/ROBWorkspaceSearchPlan.swift Cerebro/ROBWorkspaceCollisionPlan.swift \
  Cerebro/ROBFixedHeadRegistration.swift "$task_raw_map_dir/MapFixture.swift" -o "$task_raw_map_dir/fixture"
"$task_raw_map_dir/fixture"
