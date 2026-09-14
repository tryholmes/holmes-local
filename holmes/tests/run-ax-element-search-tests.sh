#!/bin/bash
set -euo pipefail
ax_search_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
ax_search_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-ax-search.XXXXXX")
trap 'rm -rf "$ax_search_test_dir"' EXIT
cd "$ax_search_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/AXElementSearch.swift \
  holmes/tests/AXElementSearchTests.swift \
  -o "$ax_search_test_dir/ax-element-search-tests"
"$ax_search_test_dir/ax-element-search-tests"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/AutonomousRunTally.swift \
  holmes/tests/AutonomousRunTallyTests.swift \
  -o "$ax_search_test_dir/autonomous-run-tally-tests"
"$ax_search_test_dir/autonomous-run-tally-tests"
