#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
shelf_test_dir="$(mktemp -d /tmp/drop-shelf-qa.XXXXXX)"
mkdir -p "$shelf_test_dir/http"
# Local image server for the browser-image ingest checks (loopback only).
shelf_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$shelf_port" --bind 127.0.0.1 --directory "$shelf_test_dir/http" >/dev/null 2>&1 &
shelf_http_pid=$!
trap 'kill "$shelf_http_pid" 2>/dev/null || true; wait "$shelf_http_pid" 2>/dev/null || true; rm -f "$shelf_test_dir/tests"' EXIT
export SHELF_HTTP_PORT="$shelf_port"
swiftc -swift-version 5 -O -target arm64-apple-macos15.0 -parse-as-library native/drop-shelf/Core.swift native/drop-shelf/App.swift native/drop-shelf/Agent.swift native/drop-shelf/Ingest.swift native/drop-shelf/Imports.swift native/drop-shelf/UI.swift tests/drop-shelf/*.swift -o "$shelf_test_dir/tests"
"$shelf_test_dir/tests" "$shelf_test_dir"
[[ -f "$shelf_test_dir/qa-complete" ]] || { echo 'FAIL: incomplete QA run' >&2; exit 1; }
echo "QA artifacts: $shelf_test_dir"
