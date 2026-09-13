#!/bin/bash
# Opt-in: requires the already-installed local model; makes no system/app changes.
set -euo pipefail
email_smoke_root=$(cd "$(dirname "$0")/../.." && pwd)
email_smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/holmes-email-live.XXXXXX")
trap 'rm -rf "$email_smoke_dir"' EXIT
cd "$email_smoke_root"
xcrun swiftc -swift-version 5 holmes/holmes/Core/{OllamaConfig,WorkActivity,OllamaClient,EmailComposeSnapshot,EmailDrafting}.swift holmes/tests/EmailDraftLiveSmoke.swift -o "$email_smoke_dir/live-smoke"
"$email_smoke_dir/live-smoke"
