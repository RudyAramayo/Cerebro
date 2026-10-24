#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d /private/tmp/rob-ghost-editor.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
app_dir="$fixture_dir/GhostFixture.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
ln -s "$repo_dir/Cerebro/Resources/ShadowPlanner" "$app_dir/Contents/Resources/ShadowPlanner"
ln -s "$repo_dir/Cerebro/rob-visual.json" "$app_dir/Contents/Resources/rob-visual.json"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.orbitusrobotics.ghost-render-fixture</string><key>CFBundleExecutable</key><string>GhostFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
# Compile the exact shared read-only formatter without linking the sandbox's
# app-level commands, controller broker or any real transport into this fixture.
python3 - "$repo_dir" "$fixture_dir/CollisionPresentation.swift" <<'PYFIXTURE'
from pathlib import Path
import sys
source = (Path(sys.argv[1]) / "Cerebro/ROBTestingSandboxWindowController.swift").read_text()
marker = "enum ROBWorkspaceCollisionPresentation {"
assert source.count(marker) == 1
Path(sys.argv[2]).write_text("import Foundation\n" + source[source.index(marker):])
PYFIXTURE
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path /private/tmp/cerebro-swift-module-cache \
  "$repo_dir/Cerebro/ROBArmRoutinePlan.swift" "$repo_dir/Cerebro/ROBArmJointLimits.swift" "$repo_dir/Cerebro/ROBGhostMotionPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceSearchPlan.swift" "$repo_dir/Cerebro/ROBWorkspaceCollisionPlan.swift" "$repo_dir/Cerebro/ROBFixedHeadRegistration.swift" "$repo_dir/Cerebro/ROBWorkspaceDepthMap.swift" "$fixture_dir/CollisionPresentation.swift" \
  "$repo_dir/Cerebro/ROBScanVisualModel.swift" "$repo_dir/Cerebro/ROBNeckRGBPoseDisplay.swift" "$repo_dir/Cerebro/ROBGhostGestureEditor.swift" "$repo_dir/Tests/ROBGhostEditorRenderFixture.swift" \
  -o "$app_dir/Contents/MacOS/GhostFixture"
"$app_dir/Contents/MacOS/GhostFixture" "${1:-/private/tmp/cerebro-ghost-preview.png}" "${2:-1}"
