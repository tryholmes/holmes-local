#!/bin/bash
set -euo pipefail
draft_intent_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
draft_intent_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-draft-intent.XXXXXX")
trap 'rm -rf "$draft_intent_test_dir"' EXIT
cd "$draft_intent_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/EmailDraftIntent.swift \
  holmes/tests/EmailDraftIntentTests.swift \
  -o "$draft_intent_test_dir/email-draft-intent-tests"
"$draft_intent_test_dir/email-draft-intent-tests"
