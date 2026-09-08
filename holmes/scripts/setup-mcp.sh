#!/usr/bin/env bash
# Scaffolds Holmes Local's MCP config. Safe: never overwrites an existing file.
# MCP is optional — Holmes runs its five playbooks without any server listed here.
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
echo "  1. Local model: install Ollama (ollama.com or 'brew install ollama'); Holmes starts the"
echo "     server and offers to download qwen3-vl:4b-instruct on first launch. No API key."
echo "  2. Google auth: see MCP-SETUP.md (one-time Terminal sign-in per server)"
echo "  3. Quick test: keep the \"test\" server, launch Holmes, run:  /run use echo to say hi"
echo
echo "Tooling check:"
for bin in ollama node npx uvx; do
  if command -v "$bin" >/dev/null 2>&1; then echo "  ✓ $bin ($(command -v "$bin"))"; else echo "  ✗ $bin not found"; fi
done
if command -v ollama >/dev/null 2>&1; then
  echo "  ollama version: $(ollama --version 2>/dev/null | head -1)"
  if curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    echo "  ✓ Ollama server is answering on 127.0.0.1:11434"
  else
    echo "  · Ollama server not running (Holmes will start it, or run 'ollama serve')"
  fi
fi
