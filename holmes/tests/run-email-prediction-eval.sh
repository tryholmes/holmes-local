#!/bin/bash
# Live evaluation of predictive email writing. Needs local Ollama and the model;
# not part of CI. Runs the production prompt, parser, grounding checks and the
# single repair retry on every fixture, then writes each answer into a jsdom
# composer with the production writer and prints success rates.
#   HOLMES_EVAL_MODEL   model name (default qwen3-vl:4b-instruct)
#   HOLMES_EVAL_CASE    comma separated scenario ids to run only those
#   HOLMES_EVAL_OUT     directory for model-results.json and report.json
set -euo pipefail
eval_root=$(cd "$(dirname "$0")/../.." && pwd)
eval_build=$(mktemp -d "${TMPDIR:-/tmp}/holmes-email-eval-build.XXXXXX")
trap 'rm -rf "$eval_build"' EXIT
eval_out="${HOLMES_EVAL_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/holmes-email-eval.XXXXXX")}"
mkdir -p "$eval_out"
cd "$eval_root"
if ! curl -sf "${OLLAMA_HOST:-http://127.0.0.1:11434}/api/tags" >/dev/null; then
  echo "Ollama is not reachable at ${OLLAMA_HOST:-http://127.0.0.1:11434}; start it and pull the model first." >&2
  exit 2
fi
xcrun swiftc -swift-version 5 \
  holmes/holmes/Core/OllamaConfig.swift \
  holmes/holmes/Core/WorkActivity.swift \
  holmes/holmes/Core/OllamaClient.swift \
  holmes/holmes/Core/EmailComposeSnapshot.swift \
  holmes/holmes/Core/EmailDrafting.swift \
  holmes/holmes/Core/EmailPrediction.swift \
  holmes/tests/EmailPredictionEval.swift \
  -o "$eval_build/email-prediction-eval"
HOLMES_EVAL_FIXTURES=holmes/tests/fixtures/email-prediction-scenarios.json \
HOLMES_EVAL_OUTPUT="$eval_out/model-results.json" \
  "$eval_build/email-prediction-eval"
if [ -z "${COMPOSE_NODE_MODULES:-}" ]; then
  npm install --prefix "$eval_build" --no-audit --no-fund --silent jsdom@26.1.0
  COMPOSE_NODE_MODULES="$eval_build/node_modules"
fi
NODE_PATH="$COMPOSE_NODE_MODULES" node holmes/tests/EmailPredictionDOMEval.cjs \
  "$eval_out/model-results.json" holmes/tests/fixtures/email-prediction-scenarios.json "$eval_out/report.json"
echo "Results: $eval_out"
