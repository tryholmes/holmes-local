#!/bin/bash
# Extension side of the browser bridge: worker transport and lifecycle against a
# mock chrome.* surface, and content script lifecycle in jsdom. No browser needed.
set -euo pipefail
bridge_extension_root=$(cd "$(dirname "$0")/../.." && pwd)
bridge_extension_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-bridge-extension.XXXXXX")
trap 'rm -rf "$bridge_extension_dir"' EXIT
cd "$bridge_extension_root"
for script in background.js content.js automation.js popup.js options.js history-hook.js email-compose.js; do
  node --check "holmes/holmes-extension/$script"
done
node -e 'JSON.parse(require("fs").readFileSync("holmes/holmes-extension/manifest.json", "utf8"))'
if [ -z "${COMPOSE_NODE_MODULES:-}" ]; then
  npm install --prefix "$bridge_extension_dir" --no-audit --no-fund --silent jsdom@26.1.0
  COMPOSE_NODE_MODULES="$bridge_extension_dir/node_modules"
fi
node holmes/tests/BrowserBridgeBackgroundTests.cjs
NODE_PATH="$COMPOSE_NODE_MODULES" node holmes/tests/BrowserBridgeContentTests.cjs
