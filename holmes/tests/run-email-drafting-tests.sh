#!/bin/bash
set -euo pipefail
email_drafting_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
email_drafting_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-email-drafting.XXXXXX")
trap 'rm -rf "$email_drafting_test_dir"' EXIT
cd "$email_drafting_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/EmailComposeSnapshot.swift \
  holmes/holmes/Core/EmailDrafting.swift \
  holmes/holmes/Core/EmailPrediction.swift \
  holmes/tests/EmailDraftingTests.swift \
  -o "$email_drafting_test_dir/email-drafting-tests"
"$email_drafting_test_dir/email-drafting-tests"
