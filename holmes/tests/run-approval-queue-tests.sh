#!/bin/bash
set -euo pipefail
approval_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
approval_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-approval-queue.XXXXXX")
trap 'rm -rf "$approval_test_dir"' EXIT
cd "$approval_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/ApprovalQueue.swift \
  holmes/tests/ApprovalQueueTests.swift \
  -o "$approval_test_dir/approval-queue-tests"
"$approval_test_dir/approval-queue-tests"
