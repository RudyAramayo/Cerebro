#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/rob-laser-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
app_dir="$test_dir/ROB Laser Calibration QA.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
/usr/bin/python3 "$repo_dir/Tests/BubbleLaserCalibrationTests.py" --fixture-dir "$app_dir/Contents/Resources"
cp "$repo_dir/Cerebro/BubbleLaserCalibration.py" "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.orbitusrobotics.laser-calibration-qa</string>
<key>CFBundleExecutable</key><string>ROB Laser Calibration QA</string>
<key>CFBundleName</key><string>ROB Laser Calibration QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -module-cache-path /private/tmp/rob-bubble-swift-cache \
  "$repo_dir/Cerebro/ROBBubbleLaserObservation.swift" \
  "$repo_dir/Cerebro/ROBBubbleLaserCalibration.swift" \
  "$repo_dir/Tests/ROBBubbleLaserCalibrationFixtureTests.swift" \
  -o "$app_dir/Contents/MacOS/ROB Laser Calibration QA"
"$app_dir/Contents/MacOS/ROB Laser Calibration QA" "$@"
