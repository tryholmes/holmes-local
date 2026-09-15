#!/bin/bash
set -euo pipefail
coordinator_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
coordinator_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-email-coordinator.XXXXXX")
trap 'rm -rf "$coordinator_test_dir"' EXIT
cd "$coordinator_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/EmailComposeSnapshot.swift \
  holmes/holmes/Core/EmailDraftIntent.swift \
  holmes/holmes/Core/EmailDrafting.swift \
  holmes/holmes/Core/EmailPrediction.swift \
  holmes/holmes/Core/EmailDraftCoordinator.swift \
  holmes/tests/EmailDraftCoordinatorTests.swift \
  -o "$coordinator_test_dir/email-draft-coordinator-tests"
"$coordinator_test_dir/email-draft-coordinator-tests"
