#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_pour_native_dir="$(mktemp -d /private/tmp/rob-pour-native.XXXXXX)"
trap 'rm -rf "$task_pour_native_dir"' EXIT
python_bin="${ROB_SHADOW_TEST_PYTHON:-$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3}"
OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 "$python_bin" -B Scripts/plan-can-pour.py \
  --scene Cerebro/Resources/ShadowPlanner/fixtures/coke-pour-scene.json \
  --status Cerebro/Resources/ShadowPlanner/fixtures/coke-pour-status.json \
  --base-advance .25 --output "$task_pour_native_dir/report.json" > "$task_pour_native_dir/summary.json"
"$python_bin" -B - "$task_pour_native_dir/report.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['hardwareOutputEnabled'] is False and d['executable'] is False
audit=d['rotationPivot']['interpolationAudit']
assert audit['valid'] and audit['checkedSamples']>100 and audit['interpolationCoverageIncluded']
assert d['preparedTimedPour']['rotationAudit']['valid']
assert d['geometryAudit']['valid']
print('Linear rotation review:',json.dumps(audit))
print('Timed rotation review:',json.dumps(d['preparedTimedPour']['rotationAudit']))
PY
xcrun swiftc -O -whole-module-optimization -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBArmRoutinePlan.swift Cerebro/ROBArmJointLimits.swift Cerebro/ROBArmControlProtocol.swift \
  Cerebro/ROBGhostMotionPlan.swift Cerebro/ROBWorkspaceSearchPlan.swift Cerebro/ROBWorkspaceCollisionPlan.swift \
  Tests/ROBCanPourPreviewFixtureTests.swift -o "$task_pour_native_dir/fixture"
"$task_pour_native_dir/fixture" "$PWD" "$task_pour_native_dir/report.json"
