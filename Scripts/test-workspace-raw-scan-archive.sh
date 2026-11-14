#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_raw_archive_dir=$(mktemp -d /private/tmp/rob-raw-scan-archive.XXXXXX)
trap 'rm -rf "$task_raw_archive_dir"' EXIT
xcrun swiftc -O -whole-module-optimization -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBWorkspaceRawScanArchive.swift Tests/ROBWorkspaceRawScanArchiveFixtureTests.swift -o "$task_raw_archive_dir/fixture"
"$task_raw_archive_dir/fixture"
