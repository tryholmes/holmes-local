#!/bin/bash
set -euo pipefail
action_evidence_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
action_evidence_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-action-evidence.XXXXXX")
trap 'rm -rf "$action_evidence_test_dir"' EXIT
cd "$action_evidence_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/ActionRunEvidence.swift \
  holmes/tests/ActionRunEvidenceTests.swift \
  -o "$action_evidence_test_dir/action-run-evidence-tests"
"$action_evidence_test_dir/action-run-evidence-tests"
