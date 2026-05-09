# LoCoMo v0.2.1 Benchmark Run — BLOCKED

**Status:** BLOCKED
**Date:** 2026-05-09
**Target version:** v0.2.1

## Blockers

| # | Blocker | Resolution |
|---|---------|------------|
| 1 | `PGMNEMO_DSN` not configured — no benchmark database | Provision PostgreSQL instance with pgmnemo v0.2.1 |
| 2 | `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` not configured | Set API key for embeddings + judge |
| 3 | `FETCH_REAL_DATASETS=1` not set in CI environment | Set env var or configure `LOCOMO_DATA_DIR` |

## Resolution Path

```bash
# 1. Provision benchmark database
createdb pgmnemo_bench
psql pgmnemo_bench -c "CREATE EXTENSION pgmnemo;"

# 2. Set env vars
export PGMNEMO_DSN="host=localhost dbname=pgmnemo_bench user=postgres"
export OPENAI_API_KEY="sk-..."
export FETCH_REAL_DATASETS=1

# 3. Install dependencies
pip install -r benchmarks/locomo/requirements.txt

# 4. Run benchmark
cd benchmarks/locomo
bash run_locomo.sh v0.2.1 results/v0.2.1_20260509
```

## Expected Output Schema (when unblocked)

```json
{
  "version": "v0.2.1",
  "date": "20260509",
  "dataset": "snap-research/LoCoMo",
  "judge_model": "gpt-4o-2024-08-06",
  "judge_prompt_sha256": "<sha256 of JUDGE_PROMPT_TEMPLATE in runner.py>",
  "categories": [
    {"category": "single_hop",         "n": ">=50", "accuracy": null, "ci95_lo": null, "ci95_hi": null},
    {"category": "multi_hop",          "n": ">=50", "accuracy": null, "ci95_lo": null, "ci95_hi": null},
    {"category": "temporal_reasoning", "n": ">=50", "accuracy": null, "ci95_lo": null, "ci95_hi": null},
    {"category": "open_domain",        "n": ">=50", "accuracy": null, "ci95_lo": null, "ci95_hi": null},
    {"category": "adversarial",        "n": ">=50", "accuracy": null, "ci95_lo": null, "ci95_hi": null}
  ],
  "bonferroni_alpha": 0.01,
  "multiple_comparison_correction": "bonferroni"
}
```

## Runner

`benchmarks/locomo/runner.py` is fully implemented and ready to run.
Use `--dry-run` to validate dataset loading without DB/API calls:

```bash
FETCH_REAL_DATASETS=1 python benchmarks/locomo/runner.py --dry-run --version v0.2.1
```
