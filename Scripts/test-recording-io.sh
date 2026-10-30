#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/rob-recording-io.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$repo_root" "$fixture_dir" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
s = (root / 'Cerebro/ROBRecordingCoordinator.swift').read_text()
start = s.index('final class ROBJSONLinesWriter {')
end = s.index('private final class ROBTrainingSession {', start)
(out / 'ROBJSONLinesWriter.swift').write_text('import Foundation\n' + s[start:end])
PY
swiftc "$fixture_dir/ROBJSONLinesWriter.swift" "$repo_root/Tests/ROBRecordingIOFixtureTests.swift" -o "$fixture_dir/recording-io"
"$fixture_dir/recording-io"
