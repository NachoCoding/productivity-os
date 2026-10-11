#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
health_test_dir="$(mktemp -d /tmp/health-breaks-qa.XXXXXX)"
trap 'rm -f "$health_test_dir/tests"' EXIT
swiftc -swift-version 5 -O -target arm64-apple-macos15.0 -parse-as-library native/health-breaks/Core.swift native/health-breaks/App.swift native/health-breaks/Pomodoro*.swift native/health-breaks/Posture*.swift tests/health-breaks/*.swift -o "$health_test_dir/tests"
"$health_test_dir/tests" "$health_test_dir"
[[ -f "$health_test_dir/qa-complete" ]] || { echo 'FAIL: incomplete QA run' >&2; exit 1; }
echo "QA artifacts: $health_test_dir"
