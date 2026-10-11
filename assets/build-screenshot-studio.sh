#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
studio_bundle="assets/Screenshot Studio.app"
mkdir -p "$studio_bundle/Contents/MacOS" "$studio_bundle/Contents/Resources"
swiftc -swift-version 5 -O -wmo -num-threads 2 -target arm64-apple-macos15.0 native/screenshot-studio/*.swift -o "$studio_bundle/Contents/MacOS/ScreenshotStudio"
studio_icon_dir="$(mktemp -d /tmp/screenshot-icon.XXXXXX)"
trap 'rm -rf "$studio_icon_dir"' EXIT
mkdir "$studio_icon_dir/Studio.iconset"
for studio_size in 16 32 128 256 512; do
  /usr/bin/sips -z "$studio_size" "$studio_size" assets/command-screenshot-studio.png --out "$studio_icon_dir/Studio.iconset/icon_${studio_size}x${studio_size}.png" >/dev/null
  studio_double="$((studio_size * 2))"
  /usr/bin/sips -z "$studio_double" "$studio_double" assets/command-screenshot-studio.png --out "$studio_icon_dir/Studio.iconset/icon_${studio_size}x${studio_size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$studio_icon_dir/Studio.iconset" -o "$studio_bundle/Contents/Resources/ScreenshotStudio.icns"
cat > "$studio_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.productivity-os.screenshot-studio</string>
<key>CFBundleName</key><string>Screenshot Studio</string>
<key>CFBundleIconFile</key><string>ScreenshotStudio.icns</string>
<key>CFBundleExecutable</key><string>ScreenshotStudio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Record microphone audio only when you enable Microphone for a short recording.</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Screenshot Studio Commands</string><key>CFBundleURLSchemes</key><array><string>pos-screenshot</string></array></dict></array>
<key>UTExportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>com.productivity-os.screenshot-project</string><key>UTTypeDescription</key><string>Screenshot Studio Project</string><key>UTTypeConformsTo</key><array><string>com.apple.package</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>posshot</string></array></dict></dict></array>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Screenshot Studio Project</string><key>CFBundleTypeExtensions</key><array><string>posshot</string></array><key>CFBundleTypeRole</key><string>Editor</string><key>LSTypeIsPackage</key><true/></dict><dict><key>CFBundleTypeName</key><string>Image</string><key>LSItemContentTypes</key><array><string>public.image</string></array><key>CFBundleTypeRole</key><string>Editor</string></dict></array>
</dict></plist>
PLIST
/usr/bin/plutil -insert POSLauncherProtocol -integer 1 "$studio_bundle/Contents/Info.plist"
/usr/bin/plutil -insert POSBuildID -string "$(/usr/bin/uuidgen)" "$studio_bundle/Contents/Info.plist"
sign_id=-
if bash assets/ensure-signing-identity.sh && /usr/bin/security find-identity -p codesigning | grep -q "\"Productivity OS Local Signing\""; then
  sign_id="Productivity OS Local Signing"
else
  echo "Warning: signing ad-hoc; privacy grants will reset after each rebuild." >&2
fi
/usr/bin/codesign --force --sign "$sign_id" --identifier com.productivity-os.screenshot-studio "$studio_bundle"
echo "Screenshot Studio built (signed: $sign_id)."
