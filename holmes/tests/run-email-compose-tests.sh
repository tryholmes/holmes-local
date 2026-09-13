#!/bin/bash
set -euo pipefail
compose_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
compose_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-email-compose.XXXXXX")
trap 'rm -rf "$compose_test_dir"' EXIT
cd "$compose_repo_root"
xcrun swiftc -swift-version 5 holmes/holmes/Core/EmailComposeSnapshot.swift \
  holmes/tests/EmailComposeSnapshotTests.swift -o "$compose_test_dir/snapshot-tests"
"$compose_test_dir/snapshot-tests"
node --check holmes/holmes-extension/email-compose.js
node --check holmes/holmes-extension/content.js
node --check holmes/holmes-extension/background.js
if [ -z "${COMPOSE_NODE_MODULES:-}" ]; then
  npm install --prefix "$compose_test_dir" --no-audit --no-fund --silent jsdom@26.1.0
  COMPOSE_NODE_MODULES="$compose_test_dir/node_modules"
fi
NODE_PATH="$COMPOSE_NODE_MODULES" node holmes/tests/EmailComposeDOMTests.cjs
node holmes/tests/EmailComposeBackgroundTests.cjs
