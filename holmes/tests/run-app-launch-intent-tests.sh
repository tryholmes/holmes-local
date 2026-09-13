#!/bin/bash
set -euo pipefail
launch_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
launch_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-launch-intent.XXXXXX")
trap 'rm -rf "$launch_test_dir"' EXIT
cd "$launch_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/AppLaunchIntent.swift \
  holmes/tests/AppLaunchIntentTests.swift \
  -o "$launch_test_dir/app-launch-intent-tests"
"$launch_test_dir/app-launch-intent-tests"
