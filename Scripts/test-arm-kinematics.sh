#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-ik-fixtures.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBSerialChainKinematics.swift" \
  "$repo_dir/Tests/ROBSerialChainKinematicsFixtureTests.swift" \
  -o "$test_dir/ik-tests"
"$test_dir/ik-tests" "$repo_dir/Tests/Fixtures/Kinematics"
