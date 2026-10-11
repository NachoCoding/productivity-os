#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
clip_test_dir="$(mktemp -d /tmp/clipboard-history-qa.XXXXXX)"
trap 'rm -f "$clip_test_dir/tests"' EXIT
swiftc -swift-version 5 -O -target arm64-apple-macos15.0 -parse-as-library native/clipboard-history/Core.swift native/clipboard-history/App.swift tests/clipboard-history/Tests.swift tests/clipboard-history/ShortcutTests.swift tests/clipboard-history/ResilienceTests.swift -o "$clip_test_dir/tests"
mkdir -p "$clip_test_dir/PasteFixture.app/Contents/MacOS"
swiftc -swift-version 5 -O -parse-as-library tests/clipboard-history/PasteFixture.swift -o "$clip_test_dir/PasteFixture.app/Contents/MacOS/PasteFixture"
cat > "$clip_test_dir/PasteFixture.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.productivity-os.clipboard-qa-fixture</string><key>CFBundleExecutable</key><string>PasteFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
"$clip_test_dir/tests" "$clip_test_dir"
[[ -f "$clip_test_dir/qa-complete" ]] || { echo 'FAIL: incomplete QA run' >&2; exit 1; }
echo "QA artifacts: $clip_test_dir"
