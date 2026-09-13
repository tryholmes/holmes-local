#!/bin/bash
set -euo pipefail
routing_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
routing_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-routing-tests.XXXXXX")
trap 'rm -rf "$routing_test_dir"' EXIT
cd "$routing_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/EmailDraftIntent.swift \
  holmes/holmes/Core/AppLaunchIntent.swift \
  holmes/holmes/Core/ClickyController.swift \
  holmes/holmes/Views/SearchBar/CommandViewModel.swift \
  holmes/tests/RequestRoutingTests.swift \
  -o "$routing_test_dir/request-routing-tests"
"$routing_test_dir/request-routing-tests"
