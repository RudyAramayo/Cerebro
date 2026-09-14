#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-demo-fixtures.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"
common=( -module-cache-path /private/tmp/cerebro-swift-module-cache -parse-as-library
  Cerebro/ROBLocalImprovisationProtocol.swift Cerebro/ROBFoundationImprovisationProvider.swift
  Tests/ROBImprovisationProviderFixtureStubs.swift )
xcrun swiftc "${common[@]}" Cerebro/ROBStageShowProtocol.swift Cerebro/ROBStageShowCoordinator.swift \
  Tests/ROBStageShowFixtureTests.swift -o "$test_dir/stage"
"$test_dir/stage"
xcrun swiftc "${common[@]}" Tests/ROBFoundationImprovisationFixtureTests.swift -o "$test_dir/foundation"
"$test_dir/foundation"
xcrun swiftc -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/AutoNet/AutoNetShared/AutoNetDataTransferProtocol.swift Cerebro/ROBRobotActionProtocol.swift \
  Cerebro/ROBAutonomyCoordinator.swift Tests/ROBRobotActionProtocolFixtureTests.swift -o "$test_dir/autonomy"
"$test_dir/autonomy"
xcrun swiftc -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/GeminiRoboticsProtocol.swift Cerebro/ROBNewsSearchService.swift \
  Cerebro/ROBAppleMusicService.swift Tests/GeminiRoboticsProtocolFixtureTests.swift -o "$test_dir/gemini"
"$test_dir/gemini"
