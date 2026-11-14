#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-animation-fixture.XXXXXX)"
trap 'rm -r "$fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repo_dir/Cerebro/ROBArmJointLimits.swift" \
  "$repo_dir/Cerebro/ROBAnimationDocument.swift" "$repo_dir/Tests/ROBAnimationDocumentTests.swift" \
  -o "$fixture_dir/document"
"$fixture_dir/document"
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repo_dir/Cerebro/ROBArmJointLimits.swift" "$repo_dir/Cerebro/ROBAnimationDocument.swift" \
  "$repo_dir/Cerebro/ROBAnimationStudio.swift" "$repo_dir/Cerebro/ROBAnimationPlayback.swift" \
  "$repo_dir/Tests/ROBAnimationRuntimeFixture.swift" -o "$fixture_dir/runtime"
"$fixture_dir/runtime"
python3 -B "$repo_dir/Tests/ROBAnimationIntegrationTests.py"
