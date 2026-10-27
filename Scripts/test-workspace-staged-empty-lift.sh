#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-workspace-staged-lift.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc ${CEREBRO_FIXTURE_SWIFT_FLAGS:-} -swift-version 5 -O -whole-module-optimization -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" "$repo_dir/Cerebro/ROBArmJointLimits.swift" "$repo_dir/Cerebro/ROBArmControlProtocol.swift" "$repo_dir/Cerebro/ROBGhostMotionPlan.swift" \
  "$repo_dir/Cerebro/ROBWorkspaceSearchPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceCollisionPlan.swift" \
  "$repo_dir/Tests/ROBWorkspaceStagedEmptyLiftFixtureTests.swift" -o "$fixture_dir/collision"
"$fixture_dir/collision" "$repo_dir" "$@"
