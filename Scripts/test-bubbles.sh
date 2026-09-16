#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-bubble-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path /private/tmp/rob-bubble-swift-cache \
  "$repo_dir/Cerebro/ROBBubbleProtocol.swift" \
  "$repo_dir/Cerebro/ROBBubbleSafety.swift" \
  "$repo_dir/Tests/ROBBubbleFixtureTests.swift" -o "$test_dir/bubbles"
"$test_dir/bubbles" "$repo_dir/Cerebro/rob-visual.json"
xcrun swiftc -module-cache-path /private/tmp/rob-bubble-swift-cache \
  "$repo_dir/Cerebro/ROBBubbleProtocol.swift" \
  "$repo_dir/Cerebro/ROBBubbleSafety.swift" \
  "$repo_dir/Cerebro/ROBBubbleRuntime.swift" \
  "$repo_dir/Cerebro/ROBBubbleRelayWatchdog.swift" \
  "$repo_dir/Tests/ROBBubbleRuntimeFixtureTests.swift" -o "$test_dir/bubble-runtime"
"$test_dir/bubble-runtime"
xcrun swiftc -module-cache-path /private/tmp/rob-bubble-swift-cache \
  "$repo_dir/Cerebro/ROBBubbleProtocol.swift" \
  "$repo_dir/Cerebro/ROBBubbleConsole.swift" \
  "$repo_dir/Tests/ROBBubbleConsoleFixtureTests.swift" -o "$test_dir/bubble-console"
"$test_dir/bubble-console"
