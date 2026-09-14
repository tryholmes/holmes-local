#!/bin/bash
set -euo pipefail
matcher_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
matcher_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-mail-matcher.XXXXXX")
trap 'rm -rf "$matcher_test_dir"' EXIT
cd "$matcher_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/MailComposeMatcher.swift \
  holmes/tests/MailComposeMatcherTests.swift \
  -o "$matcher_test_dir/mail-compose-matcher-tests"
"$matcher_test_dir/mail-compose-matcher-tests"
