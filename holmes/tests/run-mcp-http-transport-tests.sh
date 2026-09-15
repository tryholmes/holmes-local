#!/bin/bash
set -euo pipefail
mcp_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
mcp_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-mcp-http-tests.XXXXXX")
trap 'rm -rf "$mcp_test_dir"' EXIT
cd "$mcp_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/OllamaConfig.swift \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/OllamaClient.swift \
  holmes/holmes/Core/ModelJSON.swift \
  holmes/holmes/Core/MCPModels.swift \
  holmes/holmes/Core/MCPClient.swift \
  holmes/tests/MCPHTTPTransportTests.swift \
  -o "$mcp_test_dir/mcp-http-transport-tests"
"$mcp_test_dir/mcp-http-transport-tests"
