#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ge 1 ]; then app_path="$1"; else app_path="$repo_dir/build/ROB Chess Study.app"; fi
mkdir -p "$app_path/Contents/MacOS"
xcrun swiftc -O -target "$(uname -m)-apple-macos14.0" -D ROB_CHESS_STANDALONE -module-name ROBChessStudy \
  "$repo_dir/Cerebro/ROBChessStudyCore.swift" \
  "$repo_dir/Cerebro/ROBChessStudyVision.swift" \
  "$repo_dir/Cerebro/ROBChessStudySession.swift" \
  "$repo_dir/Cerebro/ROBChessStudyWindowController.swift" \
  "$repo_dir/Tools/ChessStudy/main.swift" \
  -o "$app_path/Contents/MacOS/ROB Chess Study"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ROB Chess Study</string>
<key>CFBundleIdentifier</key><string>com.orbitusrobotics.chessstudy.local</string>
<key>CFBundleExecutable</key><string>ROB Chess Study</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
# Local study utility, not a published production download.
codesign --force --sign - "$app_path"
printf 'Built chess observation utility: %s\n' "$app_path"
