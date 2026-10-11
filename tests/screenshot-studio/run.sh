#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# STUDIO_QA_HEADLESS=1 skips everything that orders windows on screen, captures or records.
studio_test_dir="$(mktemp -d /tmp/screenshot-studio-qa.XXXXXX)"
trap 'rm -f "$studio_test_dir/tests"' EXIT
studio_sources=()
for studio_source in native/screenshot-studio/*.swift; do
  [[ "$studio_source" == */main.swift ]] || studio_sources+=("$studio_source")
done
swiftc -swift-version 5 -O -target arm64-apple-macos15.0 -parse-as-library "${studio_sources[@]}" tests/screenshot-studio/Tests.swift -o "$studio_test_dir/tests"
"$studio_test_dir/tests" "$studio_test_dir"
[[ -f "$studio_test_dir/qa-complete" ]] || { echo 'FAIL: native QA exited before completing all checks' >&2; exit 1; }
echo "QA artifacts: $studio_test_dir"
