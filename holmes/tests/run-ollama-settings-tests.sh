#!/bin/bash
set -euo pipefail
settings_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
settings_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-settings-tests.XXXXXX")
trap 'rm -rf "$settings_test_dir"' EXIT
cd "$settings_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/OllamaConfig.swift \
  holmes/holmes/Core/OllamaServer.swift \
  holmes/tests/OllamaServerSettingsTests.swift \
  -o "$settings_test_dir/ollama-settings-tests"
"$settings_test_dir/ollama-settings-tests"
