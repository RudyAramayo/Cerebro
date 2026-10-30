#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-recycle-mission.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$repo_dir" "$fixture_dir" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Cerebro/AutoNet/AutoNetShared/AutoNetDataTransferProtocol.swift').read_text()
a = source.index('struct ROBLidarWirePoint:')
b = source.index('\nenum ROBLidarLocalIPC', a)
(out / 'ScanCodec.swift').write_text('import Foundation\n' + source[a:b])
# Keep the coordinator implementation intact; a same-file fixture extension
# drives its private phase setter without real camera/model/actuator adapters.
coordinator = (root / 'Cerebro/ROBRecycleMissionCoordinator.swift').read_text()
(out / 'MissionCoordinator.swift').write_text(coordinator + '''
extension ROBRecycleMissionCoordinator {
    func fixturePhase(_ phase: ROBRecycleMissionMessage.Phase) {
        setPhase(phase, "Inert phase fixture")
    }
}
''')
PY
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBRecycleMissionProtocol.swift" \
  "$repo_dir/Cerebro/ROBRoomMapFragment.swift" \
  "$repo_dir/Cerebro/ROBRoomMissionPlanner.swift" \
  "$fixture_dir/ScanCodec.swift" \
  "$repo_dir/Tests/ROBRecycleMissionFixtureTests.swift" \
  -o "$fixture_dir/missions"
"$fixture_dir/missions"
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBRecycleMissionProtocol.swift" \
  "$repo_dir/Cerebro/ROBRoomMapFragment.swift" \
  "$repo_dir/Cerebro/ROBRoomMissionPlanner.swift" \
  "$repo_dir/Cerebro/ROBRoomSpatialStore.swift" \
  "$repo_dir/Cerebro/ROBTreadMotionRamp.swift" \
  "$fixture_dir/MissionCoordinator.swift" \
  "$repo_dir/Cerebro/ROBLocalControlProtocol.swift" \
  "$fixture_dir/ScanCodec.swift" \
  "$repo_dir/Tests/ROBRecycleMissionRuntimeFixtures.swift" \
  -o "$fixture_dir/mission-runtime"
"$fixture_dir/mission-runtime"
python3 -B "$repo_dir/Tests/ROBWorkspaceMissionCameraRuntimeTests.py"
