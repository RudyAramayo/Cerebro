#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-arm-feedback.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -D ARM_FEEDBACK_ALERT_FIXTURE -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBArmFeedbackAlerts.swift" \
  "$repo_dir/Tests/ROBArmFeedbackAlertFixtureTests.swift" \
  -o "$fixture_dir/alerts"
"$fixture_dir/alerts"
