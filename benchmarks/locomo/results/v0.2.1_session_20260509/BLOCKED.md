# LoCoMo Session-Level Benchmark — BLOCKED (Hypothesis A)

**Status:** BLOCKED — script ready, execution environment unavailable
**Date:** 2026-05-09
**Target version:** v0.2.1_session (Hypothesis A: session-level granularity)
**Script:** `benchmarks/scripts/run_locomo_bench_session.py`
**Baseline:** `benchmarks/locomo/results/v0.2.1_20260509/` (turn-level, recall@10=0.366)

## Corpus Extraction — Validated (no DB required)

| Metric | Turn-level baseline | Session-level (this run) |
|---|---|---|
| Segments | 5882 | 272 |
| Oracle coverage | — | 100% (all 1982 evidence items matchable) |
| Median segment length | ~turn (~100 chars) | ~session (~2680 chars) |
| Turns per session | 1 | median 20, max 47 |

Evidence normalization validated: "D1:3" → "D1" (strip ':turn' suffix).
All 1982 questions with evidence resolve to at least one corpus segment.

## Blockers

| # | Blocker | Resolution |
|---|---------|------------|
| 1 | PostgreSQL + pgmnemo not running on port 15432 | `docker run -d --name pgmnemo-bench -p 15432:5432 -e POSTGRES_PASSWORD=bench -e POSTGRES_USER=bench -e POSTGRES_DB=bench pgvector/pgvector:pg17` |
| 2 | `torch` / `transformers` not installed in current environment | `pip install torch transformers` (or use benchmark venv) |

## Resolution Path

```bash
# 1. Start DB
docker run -d --name pgmnemo-bench -p 15432:5432 \
  -e POSTGRES_PASSWORD=bench -e POSTGRES_USER=bench -e POSTGRES_DB=bench \
  pgvector/pgvector:pg17
docker exec pgmnemo-bench psql -U bench -d bench \
  -c "CREATE EXTENSION pgmnemo CASCADE;"

# 2. Install deps
pip install torch transformers psycopg2-binary

# 3. Run session-level benchmark
python benchmarks/scripts/run_locomo_bench_session.py \
  --db-host localhost --db-port 15432 \
  --db-name bench --db-user bench --db-pass bench \
  --out-dir benchmarks/locomo/results

# Expected output: benchmarks/locomo/results/v0.2.1_session_YYYYMMDD/{report.md,metrics.json,raw_retrievals.jsonl}
# Expected recall@10: >0.366 (turn-level baseline), target 0.55-0.65
```

## Hypothesis (for record)

**Hypothesis A (2026-05-09):** Turn-level extraction (5882 segments) misaligns with the paper's
session-level retrieval unit. Concatenating all turns in a session and matching evidence at
session granularity (normalizing "D1:3" → "D1") should lift recall@10 from 0.366 into the
paper-baseline range (0.55-0.65).

**IV:** corpus granularity (session vs. turn)
**DV:** recall@K, MRR
**Control:** same embedder (DRAGON-plus), same DB, same 1986 questions
**Power:** N=1982, >0.99 power for 20pp effect at α=0.05

## Expected Output Schema

```json
{
  "version": "v0.2.1_session",
  "granularity": "session",
  "n_corpus_segments": 272,
  "overall": {
    "recall@5":  {"mean": "<expected 0.45-0.60>"},
    "recall@10": {"mean": "<expected 0.55-0.65>"},
    "recall@25": {"mean": "<expected 0.65-0.75>"},
    "recall@50": {"mean": "<expected 0.70-0.80>"},
    "mrr":       {"mean": "<expected 0.35-0.50>"}
  },
  "turn_level_baseline": {
    "run": "v0.2.1_20260509",
    "recall@10": 0.366
  }
}
```
