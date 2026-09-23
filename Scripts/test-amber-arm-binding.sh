#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-amber-binding.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repo_dir/Cerebro/ROBArmControlProtocol.swift" \
  "$repo_dir/Cerebro/ROBGripperControlProtocol.swift" \
  "$repo_dir/Cerebro/ROBAmberArmBinding.swift" \
  "$repo_dir/Cerebro/ROBGripperControllerBridge.swift" \
  "$repo_dir/Tests/ROBAmberArmBindingFixtureTests.swift" \
  -o "$fixture_dir/binding"
"$fixture_dir/binding"
python3 -B "$repo_dir/Tests/ROBAmberDiagnosticsUIStaticTests.py"
