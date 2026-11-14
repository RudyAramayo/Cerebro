#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${ROB_SHADOW_TEST_PYTHON:-$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3}"
OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 "$python_bin" -B "$repo_dir/Tests/ROBCanPourTests.py"
task_pour_fixture_dir="$(mktemp -d /private/tmp/rob-pour-fixture.XXXXXX)"
trap 'rm -rf "$task_pour_fixture_dir"' EXIT
# Compile the actual rendering matrix block without starting the hardware app.
"$python_bin" - "$repo_dir" "$task_pour_fixture_dir" <<'PY'
from pathlib import Path
import sys
source = (Path(sys.argv[1]) / 'Cerebro/ROBGhostGestureEditor.swift').read_text()
start = source.index('            var canAtGrasp =')
end = source.index('\n        }', start)
block = source[start:end]
fixture = '''import simd
struct Can { var point: SIMD3<Double> }
struct Preview { var can: Can }
struct Node { var simdTransform = matrix_identity_float4x4 }
let preview = Preview(can: Can(point: [1,3,3]))
var start = matrix_identity_double4x4
start.columns.3 = [1,2,3,1]
var current = simd_double4x4(simd_quatd(angle: .pi/2, axis: [1,0,0]))
current.columns.3 = [2,2,3,1]
var carriedCan = Node()
''' + block + '''
let point = carriedCan.simdTransform.columns.3
precondition(simd_length(SIMD3<Float>(point.x,point.y,point.z) - [2,2,4]) < 1e-6)
let cylinderAxis = carriedCan.simdTransform.columns.1
precondition(simd_length(SIMD3<Float>(cylinderAxis.x,cylinderAxis.y,cylinderAxis.z) - [0,-1,0]) < 1e-6)
print("Native ghost payload retains rigid position and rotation")
'''
(Path(sys.argv[2]) / 'fixture.swift').write_text(fixture)
PY
xcrun swiftc -swift-version 5 -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$task_pour_fixture_dir/fixture.swift" -o "$task_pour_fixture_dir/fixture"
"$task_pour_fixture_dir/fixture"
