#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-arm-routine.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
cp "$repo_dir/Cerebro/ROBArmImitationPlan.swift" "$fixture_dir/Imitation.swift"
cp "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" "$fixture_dir/Plan.swift"
cp "$repo_dir/Cerebro/ROBArmRoutineCoordinator.swift" "$fixture_dir/Coordinator.swift"
cp "$repo_dir/Cerebro/ROBControllerArmApproval.swift" "$fixture_dir/Approval.swift"
cp "$repo_dir/Cerebro/ROBRobotActionProtocol.swift" "$fixture_dir/Protocol.swift"
cp "$repo_dir/Tests/ROBArmRoutineFixtureTests.swift" "$fixture_dir/Fixtures.swift"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$fixture_dir/Imitation.swift" "$fixture_dir/Plan.swift" "$fixture_dir/Coordinator.swift" "$fixture_dir/Approval.swift" "$fixture_dir/Protocol.swift" "$fixture_dir/Fixtures.swift" \
  -o "$fixture_dir/routines"
"$fixture_dir/routines"
