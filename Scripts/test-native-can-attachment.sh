#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_attachment_dir=$(mktemp -d /private/tmp/rob-native-can-attachment.XXXXXX)
trap 'rm -rf "$task_attachment_dir"' EXIT
xcrun swiftc -O -whole-module-optimization -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBArmRoutinePlan.swift Cerebro/ROBArmJointLimits.swift Cerebro/ROBArmControlProtocol.swift \
  Cerebro/ROBGhostMotionPlan.swift Cerebro/ROBWorkspaceSearchPlan.swift Cerebro/ROBWorkspaceCollisionPlan.swift \
  Cerebro/ROBVisualGraspVerifier.swift Cerebro/ROBNativeCanAttachment.swift Tests/ROBNativeCanAttachmentFixtureTests.swift -o "$task_attachment_dir/fixture"
"$task_attachment_dir/fixture" "$PWD"
