#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d /private/tmp/rob-gripper-servo-test.XXXXXX)
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc ${CEREBRO_FIXTURE_SWIFT_FLAGS:-} -swift-version 5 -O -parse-as-library Cerebro/ROBArmJointLimits.swift Cerebro/ROBGripperVisualServo.swift Tests/ROBGripperVisualServoFixture.swift -o "$TASK_TMP/fixture"
"$TASK_TMP/fixture"
