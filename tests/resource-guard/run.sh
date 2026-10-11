#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
guard_test_dir="$(mktemp -d /tmp/rg-tests.XXXXXX)"
trap 'rm -rf "$guard_test_dir"' EXIT
python3 tests/resource-guard/installer.py
swiftc native/resource-guard/Core.swift native/resource-guard/Apps.swift native/resource-priority/Priority.swift tests/resource-guard/main.swift -o "$guard_test_dir/policy-tests"
"$guard_test_dir/policy-tests"
swiftc -D GUARD_TESTING native/resource-guard/Core.swift native/resource-guard/Apps.swift native/resource-guard/main.swift -o "$guard_test_dir/resource-guard"
swiftc tests/resource-guard/RAMFixture.swift -o "$guard_test_dir/RAMFixture"
python3 tests/resource-guard/apps.py "$guard_test_dir/resource-guard" "$guard_test_dir/RAMFixture" "$guard_test_dir/apps"
python3 tests/resource-guard/integration.py "$guard_test_dir/resource-guard" "$guard_test_dir/state"
python3 tests/resource-guard/service.py "$guard_test_dir/resource-guard" "$guard_test_dir/service"
