#!/bin/bash
set -euo pipefail
extension_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
extension_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-extension-tests.XXXXXX")
trap 'rm -rf "$extension_test_dir"' EXIT
cd "$extension_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/Setup/ExtensionInstaller.swift \
  holmes/tests/ExtensionInstallerTests.swift \
  -o "$extension_test_dir/extension-installer-tests"
"$extension_test_dir/extension-installer-tests"
