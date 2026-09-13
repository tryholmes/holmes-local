#!/bin/bash
set -euo pipefail
launcher_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
launcher_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-app-launcher.XXXXXX")
trap 'rm -rf "$launcher_test_dir"' EXIT
cd "$launcher_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/AppLauncher.swift \
  holmes/holmes/Core/AppLaunchIntent.swift \
  holmes/tests/AppLauncherTests.swift \
  -o "$launcher_test_dir/app-launcher-tests"
"$launcher_test_dir/app-launcher-tests" "$@"
