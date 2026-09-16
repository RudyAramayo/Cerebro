#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-control-latency.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"
xcrun swiftc -module-cache-path /private/tmp/cerebro-swift-module-cache -parse-as-library \
  Cerebro/ROBControlLatencyDiagnostics.swift Cerebro/ROBControlLatencyWindowController.swift \
  Tests/ROBControlLatencyTests.swift -o "$test_dir/control-latency-tests"
"$test_dir/control-latency-tests" "$@"
