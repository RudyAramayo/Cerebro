#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-controller-arm-approval.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBRobotActionProtocol.swift" \
  "$repo_dir/Cerebro/ROBControllerArmApproval.swift" \
  "$repo_dir/Tests/ROBControllerArmApprovalFixtureTests.swift" \
  -o "$fixture_dir/approvals"
"$fixture_dir/approvals"
