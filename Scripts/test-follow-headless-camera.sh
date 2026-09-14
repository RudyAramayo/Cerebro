#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-follow-camera.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
# Use the exact production wire definitions without linking unrelated servers.
python3 - "$repo_dir" "$test_dir" <<'PY'
from pathlib import Path
import sys
repo, output = map(Path, sys.argv[1:])
source = (repo / 'Cerebro/AutoNet/AutoNetShared/AutoNetDataTransferProtocol.swift').read_text()
start = source.index('// MARK: - Visually authorized person following')
end = source.index('// MARK: - Administrator remote desktop input', start)
(output / 'FollowProtocol.swift').write_text('import Foundation\n' + source[start:end])
PY
xcrun swiftc \
  "$test_dir/FollowProtocol.swift" \
  "$repo_dir/Cerebro/ROBFollowPersonCoordinator.swift" \
  "$repo_dir/Tests/ROBFollowHeadlessCameraFixtureTests.swift" \
  -o "$test_dir/follow-camera-tests"
"$test_dir/follow-camera-tests"
