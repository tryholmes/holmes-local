#!/bin/bash
set -euo pipefail
text_entry_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
text_entry_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-text-entry.XXXXXX")
trap 'rm -rf "$text_entry_test_dir"' EXIT
cd "$text_entry_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/TextEntrySupport.swift \
  holmes/tests/TextEntrySupportTests.swift \
  -o "$text_entry_test_dir/text-entry-tests"
"$text_entry_test_dir/text-entry-tests"
