#!/bin/bash
set -euo pipefail
auth_validation_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
auth_validation_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-auth-validation.XXXXXX")
trap 'rm -rf "$auth_validation_test_dir"' EXIT
cd "$auth_validation_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/AuthSupport.swift \
  holmes/tests/AuthValidationTests.swift \
  -o "$auth_validation_test_dir/auth-validation-tests"
"$auth_validation_test_dir/auth-validation-tests"
