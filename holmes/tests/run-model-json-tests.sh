#!/bin/bash
set -euo pipefail
model_json_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
model_json_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-model-json.XXXXXX")
trap 'rm -rf "$model_json_test_dir"' EXIT
cd "$model_json_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/ModelJSON.swift \
  holmes/tests/ModelJSONTests.swift \
  -o "$model_json_test_dir/model-json-tests"
"$model_json_test_dir/model-json-tests"
