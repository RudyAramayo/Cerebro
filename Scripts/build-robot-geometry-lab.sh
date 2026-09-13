#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$repo_dir/build/ROB Geometry Lab.app}"
mkdir -p "$app_path/Contents/MacOS"
xcrun swiftc -O -target "$(uname -m)-apple-macos14.0" -D ROB_GEOMETRY_STANDALONE -module-name ROBRobotGeometryLab \
  "$repo_dir/Cerebro/ROBAmberB1Kinematics.swift" \
  "$repo_dir/Cerebro/ROBRobotGeometry.swift" \
  "$repo_dir/Cerebro/ROBRobotGeometryDocument.swift" \
  "$repo_dir/Cerebro/ROBRobotGeometryWindowController.swift" \
  "$repo_dir/Tools/RobotGeometryLab/main.swift" \
  -o "$app_path/Contents/MacOS/ROB Geometry Lab"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ROB Geometry Lab</string>
<key>CFBundleIdentifier</key><string>com.orbitusrobotics.geometrylab.local</string>
<key>CFBundleExecutable</key><string>ROB Geometry Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
# Local offline workbench, not a replacement for a production distribution.
codesign --force --sign - "$app_path"
printf 'Built offline workbench: %s\n' "$app_path"
