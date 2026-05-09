# LongMemEval v0.2.2 Benchmark Run — BLOCKED

**Status:** BLOCKED  
**Date:** 2026-05-09  
**Target version:** v0.2.2  

## Blockers

| # | Blocker | Owner |
|---|---------|-------|
| 1 | ACTIVATE-1 (graph activation) not merged — no code in repo | ACTIVATE-1 task |
| 2 | ACTIVATE-2 (calibrated recall weights) not merged — no code in repo | ACTIVATE-2 task |
| 3 | v0.2.2 tag does not exist (latest: v0.2.1) | Requires 1+2 |
| 4 | `LONGMEMEVAL_DATA_DIR` not configured — dataset not present | Infra |
| 5 | `PGMNEMO_DSN` not configured — no benchmark database | Infra |
| 6 | `OPENAI_API_KEY` not configured — judge unavailable | Infra |

## Resolution Path

1. Merge ACTIVATE-1 + ACTIVATE-2 PRs → main
2. Tag `v0.2.2` on main
3. Provision benchmark PostgreSQL instance with pgmnemo v0.2.2
4. Download LongMemEval dataset: `huggingface-cli download wu-lab/longmemeval --local-dir $LONGMEMEVAL_DATA_DIR`
5. Set env vars: `LONGMEMEVAL_DATA_DIR`, `OPENAI_API_KEY`, `PGMNEMO_DSN`
6. Run: `cd benchmarks/longmemeval && bash run_longmemeval.sh v0.2.2 results/v0.2.2_20260509`
7. Results write to this directory: `longmemeval_report.json` + `longmemeval_report.md`

## Expected Output Schema (when unblocked)

```json
{
  "version": "v0.2.2",
  "date": "2026-05-09",
  "dataset": "wu-lab/longmemeval",
  "judge": "gpt-4o-2024-08-06",
  "n_sessions": 500,
  "n_questions": null,
  "metrics": {
    "Q1_single_session":  {"accuracy": null, "ci95_lo": null, "ci95_hi": null},
    "Q2_cross_session":   {"accuracy": null, "ci95_lo": null, "ci95_hi": null},
    "Q3_temporal":        {"accuracy": null, "ci95_lo": null, "ci95_hi": null},
    "Q4_knowledge_update":{"accuracy": null, "ci95_lo": null, "ci95_hi": null},
    "Q5_absence_aware":   {"accuracy": null, "ci95_lo": null, "ci95_hi": null},
    "overall_accuracy":   {"mean": null, "ci95_lo": null, "ci95_hi": null}
  },
  "effect_sizes": {
    "vs_retrieval_only": {"cohens_d": null, "interpretation": null}
  },
  "multiple_comparison_correction": "bonferroni",
  "alpha_corrected": 0.01
}
```
