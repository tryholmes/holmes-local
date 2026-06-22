#!/usr/bin/env bash
# Scaffolds Holmes's MCP config. Safe: never overwrites an existing file.
set -euo pipefail

CFG_DIR="$HOME/.holmes"
CFG="$CFG_DIR/mcp.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$CFG_DIR"

if [[ -f "$CFG" ]]; then
  echo "✓ Config already exists: $CFG (leaving it untouched)"
else
  cp "$HERE/mcp.example.json" "$CFG"
  echo "✓ Wrote example config: $CFG"
  echo "  Edit it to keep only the servers you want, then fill in any keys/tokens."
fi

echo
echo "Next:"
echo "  1. API key:   echo 'sk-ant-...' > $CFG_DIR/anthropic_key"
echo "  2. Google auth: see MCP-SETUP.md (one-time Terminal sign-in per server)"
echo "  3. Quick test: keep the \"test\" server, launch Holmes, run:  /run use echo to say hi"
echo
echo "Tooling check:"
for bin in node npx uvx; do
  if command -v "$bin" >/dev/null 2>&1; then echo "  ✓ $bin ($(command -v "$bin"))"; else echo "  ✗ $bin not found"; fi
done
