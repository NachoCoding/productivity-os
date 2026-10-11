#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clip_bundle='assets/Health Breaks.app'
mkdir -p "$clip_bundle/Contents/MacOS" "$clip_bundle/Contents/Resources"
cp assets/block-presets.json "$clip_bundle/Contents/Resources/pomodoro-presets.json"
swiftc -swift-version 5 -O -wmo -num-threads 2 -target arm64-apple-macos15.0 native/health-breaks/*.swift -o "$clip_bundle/Contents/MacOS/HealthBreaks"
cat > "$clip_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.productivity-os.health-breaks</string>
<key>CFBundleName</key><string>Health Breaks</string>
<key>CFBundleExecutable</key><string>HealthBreaks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>Posture Coach uses your built-in camera for calibration when you choose Enable &amp; Calibrate, then for optional posture reminders while you work. Images stay on your Mac and are never saved.</string>
<key>NSCameraUseContinuityCameraDeviceType</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Health Breaks Commands</string><key>CFBundleURLSchemes</key><array><string>pos-health</string></array></dict></array>
</dict></plist>
PLIST
/usr/bin/plutil -insert POSLauncherProtocol -integer 1 "$clip_bundle/Contents/Info.plist"
/usr/bin/plutil -insert POSBuildID -string "$(/usr/bin/uuidgen)" "$clip_bundle/Contents/Info.plist"
sign_id=-
if bash assets/ensure-signing-identity.sh && /usr/bin/security find-identity -p codesigning | grep -q "\"Productivity OS Local Signing\""; then
  sign_id="Productivity OS Local Signing"
else
  echo "Warning: signing ad-hoc; privacy grants will reset after each rebuild." >&2
fi
/usr/bin/codesign --force --sign "$sign_id" --identifier com.productivity-os.health-breaks "$clip_bundle"
echo 'Health Breaks built.'
