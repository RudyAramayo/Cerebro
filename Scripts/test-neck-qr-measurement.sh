#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-neck-qr-measurement.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBNeckQRMeasurement.swift" \
  "$repo_dir/Tests/ROBNeckQRMeasurementFixtureTests.swift" \
  -o "$fixture_dir/neck-qr-measurement"
"$fixture_dir/neck-qr-measurement"
