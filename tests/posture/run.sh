#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
posture_test_dir="$(mktemp -d /tmp/posture-qa.XXXXXX)"
trap 'rm -rf "$posture_test_dir"' EXIT
swiftc -swift-version 5 -O -target arm64-apple-macos15.0 -parse-as-library native/health-breaks/PostureCore.swift tests/posture/Tests.swift -o "$posture_test_dir/tests"
"$posture_test_dir/tests"
