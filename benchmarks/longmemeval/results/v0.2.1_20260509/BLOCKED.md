# LongMemEval v0.2.1 Benchmark Run — BLOCKED (real API run)

**Status:** BLOCKED — dry-run outputs present; real run blocked on credentials  
**Date:** 2026-05-09  
**Target version:** v0.2.1

## What is Complete

- `runner.py` fully implemented with verbatim LongMemEval `evaluate_qa.py` judge protocol
- `run_longmemeval.sh` shell wrapper present
- `requirements.txt` present
- `metrics.json`, `raw_judge_calls.jsonl`, `report.md` generated (dry-run fixture values)
- LongMemEval repo cloned: `https://github.com/xiaowu0162/LongMemEval`
- Dataset files available at: `https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned`

## Blockers for Real Run

| # | Blocker | Owner |
|---|---------|-------|
| 1 | `OPENAI_API_KEY` empty — embedding, answer generation, and judge unavailable | Infra |
| 2 | `PGMNEMO_DSN` not set — no benchmark PostgreSQL instance with pgmnemo v0.2.1 | Infra |
| 3 | `LONGMEMEVAL_DATA_DIR` not set — dataset not downloaded locally | Infra |

## Resolution Path

```bash
# 1. Download dataset
mkdir -p /data/longmemeval
curl -L "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/longmemeval_oracle.json" \
     -o /data/longmemeval/longmemeval_oracle.json

# 2. Provision database
createdb pgmnemo_bench
psql pgmnemo_bench -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql pgmnemo_bench -c "CREATE EXTENSION IF NOT EXISTS pgmnemo;"

# 3. Set env vars
export PGMNEMO_DSN="host=localhost dbname=pgmnemo_bench user=postgres"
export OPENAI_API_KEY="sk-..."
export LONGMEMEVAL_DATA_DIR="/data/longmemeval"

# 4. Install deps
pip install -r benchmarks/longmemeval/requirements.txt

# 5. Run
cd benchmarks/longmemeval
bash run_longmemeval.sh v0.2.1 results/v0.2.1_20260509
```

## Runner Implementation

`benchmarks/longmemeval/runner.py` covers:
- All 5 LongMemEval categories (single_session_user, multi_session_user, temporal_reasoning, knowledge_update, multi_session_topic_absent)
- **Verbatim LongMemEval judge protocol**: task-specific yes/no prompts from `evaluate_qa.py`
  - `single-session-user/assistant/multi-session`: standard QA template
  - `temporal-reasoning`: includes off-by-one leniency clause
  - `knowledge-update`: accepts updated answers over prior facts
  - `single-session-preference`: rubric-based evaluation
  - Abstention (`_abs` suffix): unanswerable-detection template
- pgmnemo.recall_lessons() hybrid retrieval (vector + BM25 + recency + graph)
- Wilson 95% CIs per question type
- Cohen's h effect sizes (arcsine transform vs 0.5 random baseline)
- Bonferroni multiple-comparison correction (α=0.01 across 5 types)
- Batched parallel judge calls (10 workers, exponential backoff on 429)

## Output Schema

```json
{
  "version": "v0.2.1",
  "date": "2026-05-09",
  "dataset": "xiaowu0162/longmemeval-cleaned",
  "judge": "gpt-4o",
  "judge_protocol": "verbatim LongMemEval evaluate_qa.py (yes/no per task type)",
  "metrics": {
    "single_session_user":        {"accuracy": null, "ci95_lo": null, "ci95_hi": null, "n": null},
    "multi_session_user":         {"accuracy": null, "ci95_lo": null, "ci95_hi": null, "n": null},
    "temporal_reasoning":         {"accuracy": null, "ci95_lo": null, "ci95_hi": null, "n": null},
    "knowledge_update":           {"accuracy": null, "ci95_lo": null, "ci95_hi": null, "n": null},
    "multi_session_topic_absent": {"accuracy": null, "ci95_lo": null, "ci95_hi": null, "n": null}
  },
  "overall": {"accuracy": null, "ci95_lo": null, "ci95_hi": null, "n": 500},
  "effect_sizes": {
    "single_session_user": {"vs_random_baseline_0.5": {"cohens_h": null, "interpretation": null}}
  },
  "multiple_comparison_correction": "bonferroni",
  "alpha_corrected": 0.01
}
```
