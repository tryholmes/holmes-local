#!/bin/bash
# Bridge reliability soak: 200 command round trips (SOAK_COMMANDS to change) through
# the real BrowserBridge server with a simulated, periodically evicted worker and a
# repeatedly blocked main thread. Fails unless every round trip succeeds.
set -euo pipefail
soak_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
soak_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-bridge-soak.XXXXXX")
trap 'rm -rf "$soak_test_dir"' EXIT
cd "$soak_repo_root"
xcrun swiftc -D DEBUG -swift-version 5 \
  holmes/holmes/Core/EmailComposeSnapshot.swift \
  holmes/holmes/Core/ContextEngine.swift \
  holmes/holmes/Core/LiveContext.swift \
  holmes/holmes/Core/BrowserBridge.swift \
  holmes/holmes/Core/Setup/ExtensionInstaller.swift \
  holmes/tests/BrowserComposeTestSupport.swift \
  holmes/tests/BridgeLoopbackSupport.swift \
  holmes/tests/BridgeSoak.swift \
  -o "$soak_test_dir/bridge-soak"
"$soak_test_dir/bridge-soak" | grep -v '^\[Bridge\]'
