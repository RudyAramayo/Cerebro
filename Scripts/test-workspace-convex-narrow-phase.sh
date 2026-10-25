#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d /private/tmp/rob-convex-test.XXXXXX)
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -swift-version 5 -O -parse-as-library Cerebro/ROBArmRoutinePlan.swift Cerebro/ROBArmJointLimits.swift Cerebro/ROBArmControlProtocol.swift Cerebro/ROBGhostMotionPlan.swift Cerebro/ROBWorkspaceSearchPlan.swift Cerebro/ROBWorkspaceCollisionPlan.swift Tests/ROBWorkspaceConvexNarrowPhaseFixture.swift -o "$TASK_TMP/fixture"
"$TASK_TMP/fixture" "$PWD"
