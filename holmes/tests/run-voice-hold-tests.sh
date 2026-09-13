#!/bin/bash
set -euo pipefail
voice_repo_root=$(cd "$(dirname "$0")/../.." && pwd)
voice_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-voice-tests.XXXXXX")
trap 'rm -rf "$voice_test_dir"' EXIT
cd "$voice_repo_root"
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/HotkeyManager.swift \
  holmes/holmes/Core/VoiceInputController.swift \
  holmes/tests/VoiceHoldTests.swift \
  -o "$voice_test_dir/voice-hold-tests"
"$voice_test_dir/voice-hold-tests"
