#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
live_root="$(mktemp -d /tmp/drop-shelf-live.XXXXXX)"
mkdir -p "$live_root/http"
live_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$live_port" --bind 127.0.0.1 --directory "$live_root/http" >"$live_root/http.log" 2>&1 &
live_server_pid=$!
trap 'kill "$live_server_pid" 2>/dev/null || true; wait "$live_server_pid" 2>/dev/null || true; rm -f "$live_root/live-tests"' EXIT
echo "Live QA artifacts: $live_root"
swiftc -swift-version 5 -O -target arm64-apple-macos15.0 -parse-as-library native/drop-shelf/Core.swift native/drop-shelf/App.swift native/drop-shelf/Agent.swift native/drop-shelf/Ingest.swift native/drop-shelf/Imports.swift native/drop-shelf/UI.swift tests/drop-shelf/live/main.swift -o "$live_root/live-tests"
"$live_root/live-tests" "$live_root" "$live_port"
