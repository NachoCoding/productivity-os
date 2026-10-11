#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build and sign beside the target, then rename: Setup and the helper-update check never see a partial probe.
staged=$(/usr/bin/mktemp assets/.focus-probe.XXXXXX)
trap 'rm -f "$staged"' EXIT
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 native/focus-probe/main.swift -o "$staged"
/usr/bin/codesign --force --sign - --identifier com.productivity-os.focus-probe "$staged"
/bin/chmod 755 "$staged"
/bin/mv -f "$staged" assets/focus-probe
echo 'Focus state probe built.'
