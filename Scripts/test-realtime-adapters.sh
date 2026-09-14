#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-realtime-fixtures.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"
xcrun swiftc -module-cache-path /private/tmp/cerebro-swift-module-cache -parse-as-library \
  Cerebro/GeminiRoboticsProtocol.swift Cerebro/ROBNewsSearchService.swift Cerebro/ROBAppleMusicService.swift \
  Cerebro/ROBRealtimeSession.swift Cerebro/ROBRealtimePreferences.swift Cerebro/ROBOpenAIRealtimeProtocol.swift \
  Cerebro/ROBOpenAIRealtimeSession.swift Cerebro/ROBRealtimeRouter.swift \
  Tests/ROBRealtimeAdapterFixtureTests.swift -o "$test_dir/realtime-tests"
"$test_dir/realtime-tests"
