#!/bin/bash
set -euo pipefail
run_registry_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
run_registry_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-computer-use-runs.XXXXXX")
trap 'rm -rf "$run_registry_test_dir"' EXIT
cd "$run_registry_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/ComputerUseRunRegistry.swift \
  holmes/tests/ComputerUseRunRegistryTests.swift \
  -o "$run_registry_test_dir/computer-use-run-tests"
"$run_registry_test_dir/computer-use-run-tests"
