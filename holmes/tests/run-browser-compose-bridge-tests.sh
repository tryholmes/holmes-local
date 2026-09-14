#!/bin/bash
set -euo pipefail
bridge_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
bridge_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-browser-compose.XXXXXX")
trap 'rm -rf "$bridge_test_dir"' EXIT
cd "$bridge_repo_root"
xcrun swiftc -D DEBUG -swift-version 5 \
  holmes/holmes/Core/EmailComposeSnapshot.swift \
  holmes/holmes/Core/ContextEngine.swift \
  holmes/holmes/Core/LiveContext.swift \
  holmes/holmes/Core/BrowserBridge.swift \
  holmes/holmes/Core/Setup/ExtensionInstaller.swift \
  holmes/tests/BrowserComposeTestSupport.swift \
  holmes/tests/BridgeLoopbackSupport.swift \
  holmes/tests/BridgeLoopbackTests.swift \
  holmes/tests/BrowserComposeBridgeTests.swift \
  -o "$bridge_test_dir/bridge-tests"
"$bridge_test_dir/bridge-tests"
