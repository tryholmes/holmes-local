#!/bin/bash
set -euo pipefail
capability_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
capability_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-capability-tests.XXXXXX")
trap 'rm -rf "$capability_test_dir"' EXIT
cd "$capability_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/OllamaConfig.swift \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/OllamaClient.swift \
  holmes/holmes/Core/ModelJSON.swift \
  holmes/tests/OllamaCapabilityCacheTests.swift \
  -o "$capability_test_dir/ollama-capability-cache-tests"
"$capability_test_dir/ollama-capability-cache-tests"
