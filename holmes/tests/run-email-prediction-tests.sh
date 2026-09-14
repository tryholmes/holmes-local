#!/bin/bash
set -euo pipefail
prediction_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
prediction_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-email-prediction.XXXXXX")
trap 'rm -rf "$prediction_test_dir"' EXIT
cd "$prediction_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/EmailComposeSnapshot.swift \
  holmes/holmes/Core/EmailDrafting.swift \
  holmes/holmes/Core/EmailPrediction.swift \
  holmes/tests/EmailPredictionTests.swift \
  -o "$prediction_test_dir/email-prediction-tests"
"$prediction_test_dir/email-prediction-tests"
