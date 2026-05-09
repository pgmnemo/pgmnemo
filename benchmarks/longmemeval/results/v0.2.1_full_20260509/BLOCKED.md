# LongMemEval Full Run — BLOCKED

**Date:** 2026-05-09
**Script:** `benchmarks/scripts/run_longmemeval_pgmnemo_full.py`
**Hypothesis:** C — does removing 500-char truncation lift recall@10?

## Blockers

1. **PostgreSQL not running** — `psql` to `host=localhost port=15432 dbname=bench` returns "Connection refused". The pgmnemo extension is unavailable.
2. **ML deps not installed** — `torch` and `sentence_transformers` are not present in the agent execution environment. Embedding step cannot run.

## What is ready

- `benchmarks/scripts/run_longmemeval_pgmnemo_full.py` — full fork complete:
  - `DEVICE = "cpu"` (forced)
  - `TRUNCATE_CHARS = 8000` (up from 500-char baseline)
  - Loads `longmemeval_s_cleaned.json` explicitly
  - Outputs to `v0.2.1_full_<date>/` with delta table vs baseline
  - Drops the addendum caveat in report if run succeeds

## How to unblock

```bash
# 1. Start pgmnemo DB (Docker or local Postgres with pgmnemo extension)
docker compose up -d  # or equivalent

# 2. Install deps
cd benchmarks && source .venv_bench/venv/bin/activate

# 3. Run (estimated 3-5h on CPU for 23867 segments × bge-m3)
LONGMEMEVAL_BENCH_ROOT=/path/to/benchmarks \
PGMNEMO_DSN="host=localhost port=15432 dbname=bench user=bench password=bench" \
python scripts/run_longmemeval_pgmnemo_full.py
```

## Expected output (when run)

- `report.md` — full results + delta table vs v0.2.1_pgmnemo_20260509
- `metrics.json` — structured metrics
- `raw_retrievals.jsonl` — per-item retrieval records
