#!/bin/bash
set -euo pipefail
demo_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
demo_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-guided-demo.XXXXXX")
trap 'rm -rf "$demo_test_dir"' EXIT
cd "$demo_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/OllamaConfig.swift \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/OllamaClient.swift \
  holmes/holmes/Core/ModelJSON.swift \
  holmes/holmes/Core/AppLauncher.swift \
  holmes/holmes/Core/GuidedDemo.swift \
  holmes/tests/GuidedDemoTests.swift \
  -o "$demo_test_dir/guided-demo-tests"
"$demo_test_dir/guided-demo-tests"
