# pgmnemo Benchmark Suite — Reproducibility Guide

> **Publication target:** ACL/EMNLP/NeurIPS reproducibility tracks
> **Extension version:** see per-run version tag
> **Last updated:** 2026-05-09

---

## Abstract

This document is the authoritative reproducibility guide for all `pgmnemo` evaluation benchmarks. `pgmnemo` is a PostgreSQL extension that provides provenance-gated, vector-hybrid memory recall for multi-agent systems. We evaluate it on two conversational-memory benchmarks — **LongMemEval** and **LoCoMo** — using GPT-4o as both the answer model and the judge. Each benchmark runner is a self-contained Python script; results are fully deterministic given fixed model versions, random seeds, and dataset checksums documented herein. Every sub-directory contains a benchmark-specific `METHODOLOGY.md` that fills in the academic template (`_TEMPLATE/METHODOLOGY.md`) with concrete values.

---

## 1. System Under Test

| Parameter | Value |
|-----------|-------|
| Extension | `pgmnemo` |
| Tested versions | v0.2.1, v0.2.2 |
| PostgreSQL | 17 (also tested: 15, 16) |
| pgvector | >= 0.7.0 |
| Embedding model | `text-embedding-3-large` (dim = 1024, OpenAI) |
| Recall function | `pgmnemo.recall_lessons(embedding, k, filters, project_id)` |
| Recall strategy | cosine similarity + FTS (BM25) + recency weight + importance weight + graph proximity |
| GUC: tenant isolation | `pgmnemo.tenant_id` |
| GUC: provenance gate | `pgmnemo.gate_strict` |
| Schema | `pgmnemo` (extension default) |

Hardware **must** be reported in each benchmark's `METHODOLOGY.md §2`.

---

## 2. Registered Benchmarks

| Directory | Dataset | Primary metric | Paper reference |
|-----------|---------|----------------|-----------------|
| [`longmemeval/`](longmemeval/METHODOLOGY.md) | LongMemEval (Wu et al. 2024) | Accuracy by question type | arXiv:2410.10813 |
| [`locomo/`](locomo/METHODOLOGY.md) | LoCoMo (Maharana et al. 2024) | Composite F1 by category | arXiv:2402.17753 |

---

## 3. Shared Dataset Metadata

Each benchmark's `METHODOLOGY.md §3` records the full dataset entry. Required fields:

| Field | Required |
|-------|----------|
| Dataset name and version | yes |
| Source URL | yes |
| sha256 of the downloaded archive | yes |
| License | yes |
| Query taxonomy (question-type breakdown) | yes |

---

## 4. Methodology

### 4.1 Judge Model

All benchmarks use **`gpt-4o-2024-08-06`** as the judge (model string, not alias, to prevent silent version drift). The verbatim judge prompt and its SHA-256 hash are recorded in each benchmark's `METHODOLOGY.md §4` and in every `metrics.json` under the key `judge_prompt_sha256`.

### 4.2 Scoring Rubric

| Benchmark | Rubric | Source |
|-----------|--------|--------|
| LongMemEval | `autoeval_label` in {correct, incorrect} per LongMemEval protocol | Wu et al. 2024 §A.3 |
| LoCoMo | F1 over token overlap (single/multi-hop); BERTScore F1 (summarization) | Maharana et al. 2024 §4 |

### 4.3 Statistical Method

| Method | Setting |
|--------|---------|
| Confidence intervals | Wilson score interval, z = 1.96, 95% (binary accuracy); bootstrap 1 000 resamples (F1) |
| Effect size | Cohen's h (arcsine transform) for proportions; Cohen's d for continuous scores vs. random baseline p = 0.50 |
| Multiple-comparison correction | Bonferroni; familywise alpha = 0.05, per-test alpha = 0.05 / K |
| Reported corrected alpha | 0.01 (K = 5 comparison families) |
| Minimum detectable effect | d >= 0.2 at n >= 200, power = 0.80 |
| Judge parallelism | 10 workers; exponential back-off (max 5 retries) on HTTP 429 |

### 4.4 Calibration Grid

Preliminary hyperparameter search uses a **3 x 3 x 3 = 27-combination** factorial (full 5x5x5 deferred to v0.2.3):

| Axis | Values |
|------|--------|
| `recall_k` | 10, 20, 40 |
| `recency_weight` (gamma) | 0.05, 0.10, 0.20 |
| `graph_weight` | 0.05, 0.15, 0.25 |

Best parameters per run are committed as `calibration_*.json` alongside results.

---

## 5. Procedure

### 5.1 Prerequisites

**Software**

| Dependency | Tested version | Install |
|------------|---------------|---------|
| PostgreSQL | 15 - 17 | OS package or Docker |
| pgmnemo | see per-run tag | `make install` in repo root |
| Python | >= 3.11 | system / pyenv |
| openai SDK | >= 1.25 | `pip install openai` |
| psycopg | >= 3.1 | `pip install "psycopg[binary]"` |
| huggingface-cli | any | `pip install huggingface_hub` |

**Environment variables**

```bash
export PGMNEMO_DSN="postgresql://user:pass@host:5432/bench_db"
export OPENAI_API_KEY="sk-..."
export LOCOMO_DATA_DIR="/data/locomo"
export LONGMEMEVAL_DATA_DIR="/data/longmemeval"
export PYTHONHASHSEED=42
```

### 5.2 Database Setup

```bash
# Step 1 - create the benchmark database
createdb pgmnemo_bench

# Step 2 - install extensions
psql pgmnemo_bench -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql pgmnemo_bench -c "CREATE EXTENSION IF NOT EXISTS pgmnemo;"

# Step 3 - verify pgmnemo version
psql pgmnemo_bench -c "SELECT pgmnemo.version();"
```

### 5.3 Run a Benchmark (dry run first)

```bash
cd benchmarks/<benchmark>
pip install -r requirements.txt

# Dry run (fixture mode - no DB or API calls)
python runner.py --version <tag> --dry-run

# Full run
python runner.py --version <tag>
```

### 5.4 LongMemEval (v0.2.1)

```bash
git clone https://github.com/xiaowu0162/LongMemEval "$LONGMEMEVAL_DATA_DIR"
cd benchmarks/longmemeval
python runner.py --version v0.2.1
# Results -> results/v0.2.1_20260509/{metrics.json,report.md,raw_judge_calls.jsonl}
```

### 5.5 LoCoMo (v0.2.2)

```bash
huggingface-cli download maharana/locomo --local-dir "$LOCOMO_DATA_DIR"
cd benchmarks/locomo
bash run_locomo.sh v0.2.2 results/v0.2.2_$(date +%Y%m%d)
# Results -> results/v0.2.2_<date>/{locomo_report.json,locomo_report.md}
```

---

## 6. Results

Results are written to `results/<version>_<YYYYMMDD>/` per benchmark. Required output files:

| File | Content |
|------|---------|
| `metrics.json` | Machine-readable scores, CIs, effect sizes, judge prompt hash |
| `report.md` | Human-readable table (full per-category + aggregate row) |
| `raw_judge_calls.jsonl` | Verbatim judge inputs/outputs, one JSON object per line |
| `calibration_*.json` | Calibration grid sweep results |

All four files are **required** for a reproducibility claim. Current runs are **BLOCKED** (see `BLOCKED.md` in each results directory).

### GO / NO-GO Gate

| Criterion | Threshold | `metrics.json` field |
|-----------|-----------|----------------------|
| Bonferroni p-value | < alpha_corrected | `categories[].p_value_bonferroni` |
| Cohen's h / d | >= 0.2 (small effect) | `categories[].cohens_h` |
| Wilson CI lower bound | > 0.50 (baseline) | `categories[].ci95_lo` |
| N per category | >= 50 | `categories[].n` |
| Judge prompt hash | matches recorded hash | `judge_prompt_sha256` |

Results failing any criterion are **NO-GO** and must carry a disclaimer if reported.

---

## 7. Threats to Validity

- **Judge model drift.** OpenAI may silently update a model snapshot; pin via `model` + `system_fingerprint` logged in `raw_judge_calls.jsonl`.
- **Dataset contamination.** Answer and judge LLMs may have seen benchmark data during pre-training; treat absolute accuracy as an upper-bound estimate.
- **Hardware variance.** HNSW index build time and query latency are hardware-dependent; report CPU/RAM specs and `pg_prewarm` state in `METHODOLOGY.md §2`.
- **Single-seed runs.** Stochastic components (embedding, LLM sampling) yield variance; require >= 3 independent seeds for publication claims.
- **Calibration overfitting.** Best parameters from the 27-combination grid are chosen on the same split used for evaluation in preliminary runs; held-out test splits must be confirmed before final reporting.
- **Provenance gate interactions.** `pgmnemo.gate_strict = on` may filter memories differently across tenant configurations; confirm GUC state in each run's `metrics.json`.

---

## 8. Reproducibility

### 8.1 Seeds and Hashes

| Item | How to verify |
|------|---------------|
| Random seed | `PYTHONHASHSEED=42`; recorded in `metrics.json["seed"]` |
| Dataset integrity | `sha256sum <archive>` vs. value in `METHODOLOGY.md §3` |
| Judge prompt integrity | SHA-256 of prompt string vs. `metrics.json["judge_prompt_sha256"]` |
| pgmnemo version | `SELECT pgmnemo.version();` vs. `metrics.json["pgmnemo_version"]` |
| OpenAI model fingerprint | `system_fingerprint` in `raw_judge_calls.jsonl` |

### 8.2 Reproducibility Checklist

- [ ] `pgmnemo` version pinned and tagged in git
- [ ] Dataset sha256 recorded in `METHODOLOGY.md §3`
- [ ] Judge model string is a dated snapshot (`gpt-4o-2024-08-06`), not an alias
- [ ] `raw_judge_calls.jsonl` committed alongside `metrics.json`
- [ ] Calibration grid JSON committed
- [ ] `PYTHONHASHSEED=42` set and recorded in `metrics.json`
- [ ] Hardware fully specified in `METHODOLOGY.md §2`
- [ ] All steps in `METHODOLOGY.md §5` execute end-to-end on a clean environment
- [ ] `python runner.py --dry-run` exits 0 in CI
- [ ] PI has reviewed and signed off in `METHODOLOGY.md §8`

---

## Adding a New Benchmark

1. Copy `_TEMPLATE/METHODOLOGY.md` -> `benchmarks/<name>/METHODOLOGY.md`.
2. Fill every `[PLACEHOLDER]` - no placeholder may remain when the PR is merged.
3. Implement `runner.py` + `run_<name>.sh` following existing runners as reference.
4. Add an entry to the **Registered Benchmarks** table in this README.
5. Obtain PI sign-off that `METHODOLOGY.md` is publication-grade (EVIDENCE THRESHOLD gate).
6. Confirm `python runner.py --dry-run` exits 0 in CI.

---

## 9. References

```bibtex
@article{wu2024longmemeval,
  title   = {{LongMemEval}: Benchmarking Chat Assistants on Long-Term Interactive Memory},
  author  = {Wu, Di and He, Hongwei and Liu, Wenhao and Han, Sanxing and
             Ma, Yuwei and He, Xiaoxin and Yang, Diyi},
  year    = {2024},
  journal = {arXiv preprint arXiv:2410.10813}
}

@article{maharana2024locomo,
  title   = {Evaluating Very Long-Term Conversational Memory of {LLM} Agents},
  author  = {Maharana, Adyasha and Lee, Dong-Ho and Tulyakov, Sergey and
             Bansal, Mohit and Barbieri, Francesco and Fang, Yuwei},
  year    = {2024},
  journal = {arXiv preprint arXiv:2402.17753}
}

@software{pgmnemo2026,
  title   = {pgmnemo: Multi-Agent Memory Substrate for {PostgreSQL}},
  year    = {2026},
  version = {0.2.1},
  license = {Apache-2.0}
}
```
