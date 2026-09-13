#!/bin/bash
set -euo pipefail
work_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-work-tests.XXXXXX")
trap 'rm -rf "$work_test_dir"' EXIT
cd "$work_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Views/NotchAnimation/NotchDetector.swift \
  holmes/holmes/Views/NotchAnimation/NotchViewModel.swift \
  holmes/tests/WorkActivityTests.swift \
  -o "$work_test_dir/work-activity-tests"
"$work_test_dir/work-activity-tests"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/MenuBarManager.swift \
  holmes/tests/WorkLifecycleTests.swift \
  -o "$work_test_dir/work-lifecycle-tests"
"$work_test_dir/work-lifecycle-tests"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Views/NotchAnimation/NotchDetector.swift \
  holmes/holmes/Views/NotchAnimation/NotchViewModel.swift \
  holmes/tests/notch_geometry_tests.swift \
  -o "$work_test_dir/notch-geometry-tests"
"$work_test_dir/notch-geometry-tests"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/OllamaConfig.swift \
  holmes/holmes/Core/OllamaClient.swift \
  holmes/tests/OllamaWorkActivityTests.swift \
  -o "$work_test_dir/ollama-work-tests"
"$work_test_dir/ollama-work-tests"
