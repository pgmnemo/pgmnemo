#!/usr/bin/env bash
# Run LongMemEval benchmark for pgmnemo.
# Usage: bash run_longmemeval.sh [VERSION] [OUT_DIR]
# Requires: LONGMEMEVAL_DATA_DIR, PGMNEMO_DSN, OPENAI_API_KEY
set -euo pipefail

VERSION="${1:-v0.2.1}"
TODAY=$(date +%Y%m%d)
OUT_DIR="${2:-results/${VERSION}_${TODAY}}"

cd "$(dirname "$0")"

echo "=== LongMemEval benchmark ==="
echo "Version : $VERSION"
echo "Output  : $OUT_DIR"
echo ""

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "ERROR: OPENAI_API_KEY not set" >&2; exit 1
fi
if [[ -z "${PGMNEMO_DSN:-}" ]]; then
  echo "ERROR: PGMNEMO_DSN not set" >&2; exit 1
fi
if [[ -z "${LONGMEMEVAL_DATA_DIR:-}" ]]; then
  echo "WARNING: LONGMEMEVAL_DATA_DIR not set — will attempt HuggingFace download"
fi

python3 runner.py \
  --version "$VERSION" \
  --judge-model gpt-4o \
  --judge-workers 10 \
  --embed-model text-embedding-3-large \
  --answer-model gpt-4o \
  --k 20 \
  --out-dir "$OUT_DIR"

echo ""
echo "Done. Results: $OUT_DIR"
