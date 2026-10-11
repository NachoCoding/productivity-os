#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clip_bundle='assets/Drop Shelf.app'
mkdir -p "$clip_bundle/Contents/MacOS"
swiftc -swift-version 5 -O -wmo -num-threads 2 -target arm64-apple-macos15.0 native/drop-shelf/*.swift -o "$clip_bundle/Contents/MacOS/DropShelf"
cat > "$clip_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.productivity-os.drop-shelf</string>
<key>CFBundleName</key><string>Drop Shelf</string>
<key>CFBundleExecutable</key><string>DropShelf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Drop Shelf Commands</string><key>CFBundleURLSchemes</key><array><string>pos-shelf</string></array></dict></array>
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
/usr/bin/codesign --force --sign "$sign_id" --identifier com.productivity-os.drop-shelf "$clip_bundle"
echo 'Drop Shelf built.'
