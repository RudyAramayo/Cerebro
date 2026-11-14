#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_registration_fixture_dir=$(mktemp -d /private/tmp/rob-fixed-head-registration.XXXXXX)
trap 'rm -rf "$task_registration_fixture_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path /private/tmp/cerebro-swift-module-cache \
  Cerebro/ROBFixedHeadRegistration.swift Tests/ROBFixedHeadRegistrationFixtureTests.swift \
  -o "$task_registration_fixture_dir/registration-fixtures"
"$task_registration_fixture_dir/registration-fixtures"

task_registration_python="${ROB_REGISTRATION_TEST_PYTHON:-$HOME/Library/Application Support/Cerebro/ShadowPlanner/venv/bin/python3}"
"$task_registration_python" -B -m unittest discover -s Tests -p test_fixed_head_registration.py
"$task_registration_python" -B - "$task_registration_fixture_dir/interchange.json" <<'PYTHON'
import json
from pathlib import Path
import sys
sys.path[:0]=['Tests','Cerebro/Resources/ShadowPlanner']
from test_fixed_head_registration import FixedHeadRegistrationTests
case=FixedHeadRegistrationTests();case.setUp()
try:
    output,_=case.fit();Path(sys.argv[1]).write_text(json.dumps(output))
finally:case.tearDown()
PYTHON
"$task_registration_fixture_dir/registration-fixtures" "$task_registration_fixture_dir/interchange.json"
