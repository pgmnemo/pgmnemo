# [BENCHMARK_NAME] -- Methodology

> **Copy instructions:** Replace every `[PLACEHOLDER]` with a concrete value.
> No placeholder may remain when a PR is merged.
> PI sign-off required before results may be cited in any publication.

---

## 1. Abstract

[2-4 sentences: what is evaluated, on which dataset, with which retrieval strategy, and what the headline finding is. Leave as "TBD -- results pending" until the run completes.]

---

## 2. System Under Test

### 2.1 Extension

| Parameter | Value |
|-----------|-------|
| Extension | `pgmnemo` |
| Version | `[e.g. v0.2.1]` -- pin exact git tag |
| PostgreSQL version | `[e.g. 17.2]` |
| pgvector version | `[e.g. 0.7.4]` |
| Recall function | `pgmnemo.recall_lessons(embedding, k, filters, project_id)` |
| Recall strategy | cosine similarity + FTS (BM25) + recency + importance + graph proximity |

### 2.2 Schema / GUCs

```sql
-- GUCs active during this run
SET pgmnemo.tenant_id   = '[TENANT_UUID]';
SET pgmnemo.gate_strict = [on | off];
-- [add any other non-default GUCs]
```

### 2.3 Embedding Model

| Parameter | Value |
|-----------|-------|
| Provider | `[e.g. OpenAI]` |
| Model | `[e.g. text-embedding-3-large]` |
| Dimensions | `[e.g. 1024]` |
| Truncation | `[none | right at N tokens]` |

### 2.4 Hardware

| Component | Specification |
|-----------|---------------|
| CPU | `[e.g. AMD EPYC 7R32, 16 vCPUs]` |
| RAM | `[e.g. 64 GiB DDR4]` |
| GPU | `[none | e.g. NVIDIA A10G]` |
| Storage | `[e.g. NVMe SSD, 500 GB]` |
| OS | `[e.g. Ubuntu 22.04 LTS]` |
| pg_prewarm state | `[cold | warm -- explain if warm]` |

### 2.5 Hyperparameters Used

| Parameter | Value | Chosen by |
|-----------|-------|-----------|
| `recall_k` | `[e.g. 20]` | calibration grid best |
| `recency_weight` (gamma) | `[e.g. 0.10]` | calibration grid best |
| `graph_weight` | `[e.g. 0.15]` | calibration grid best |
| `importance_weight` (delta) | `[e.g. 0.10]` | calibration grid best |

---

## 3. Dataset

| Field | Value |
|-------|-------|
| Name | `[e.g. LongMemEval]` |
| Version / split | `[e.g. v1.0, test split]` |
| Source URL | `[exact URL]` |
| Download command | `[exact CLI command to reproduce download]` |
| sha256 (archive) | `[64-hex-char hash of the downloaded file]` |
| License | `[e.g. CC BY 4.0]` |
| Total instances | `[e.g. 500]` |
| Languages | `[e.g. English]` |

### 3.1 Query Taxonomy

| Category | N | Description |
|----------|---|-------------|
| `[e.g. single_session_user]` | `[N]` | `[one-line description]` |
| `[e.g. multi_session_user]` | `[N]` | `[one-line description]` |
| `[add rows as needed]` | | |
| **Total** | `[N_total]` | |

---

## 4. Methodology

### 4.1 Judge Model

| Parameter | Value |
|-----------|-------|
| Provider | `[e.g. OpenAI]` |
| Model (exact snapshot) | `[e.g. gpt-4o-2024-08-06]` -- **must be a dated snapshot, not an alias** |
| Temperature | `[e.g. 0]` |
| max_tokens | `[e.g. 128]` |
| Judge prompt SHA-256 | `[64-hex hash -- recompute: printf '%s' "$PROMPT" | sha256sum]` |

### 4.2 Verbatim Judge Prompt

> Copy the **exact** prompt string below. Any change -- including whitespace -- invalidates the hash above.

```
[PASTE VERBATIM JUDGE PROMPT HERE]
```

### 4.3 Scoring Rubric

| Label / Score | Condition | Numeric value assigned |
|---------------|-----------|----------------------|
| `[e.g. correct]` | `[condition]` | `[e.g. 1]` |
| `[e.g. incorrect]` | `[condition]` | `[e.g. 0]` |
| `[add rows as needed]` | | |

Reference: `[citation -- paper section]`

### 4.4 Statistical Method

| Method | Setting |
|--------|---------|
| Point estimate | `[e.g. accuracy = correct / N]` |
| Confidence intervals | Wilson score interval, z = 1.96, 95% (binary); bootstrap 1 000 resamples (continuous) |
| Effect size metric | `[e.g. Cohen's h (arcsine transform) vs. random baseline p = 0.50]` |
| Multiple-comparison correction | Bonferroni; familywise alpha = 0.05, K = `[number of tests]` |
| Per-test corrected alpha | `[0.05 / K]` |
| Minimum detectable effect | d >= 0.2 at n >= 200, power = 0.80 |
| Random seed | `42` (set via `PYTHONHASHSEED=42`) |

### 4.5 Calibration

Hyperparameters selected via a **3 x 3 x 3 = 27-combination** grid on `[split name]`:

| Axis | Values |
|------|--------|
| `recall_k` | 10, 20, 40 |
| `recency_weight` (gamma) | 0.05, 0.10, 0.20 |
| `graph_weight` | 0.05, 0.15, 0.25 |

Best combination committed in `results/<version>_<date>/calibration_<version>.json`.

---

## 5. Procedure

> Every step must be executable verbatim on a clean machine given the env vars in 5.1.

### 5.1 Environment

```bash
export PGMNEMO_DSN="postgresql://user:pass@host:5432/bench_db"
export OPENAI_API_KEY="sk-..."
export [BENCHMARK]_DATA_DIR="/data/[benchmark]"
export PYTHONHASHSEED=42
```

### 5.2 Install pgmnemo

```bash
# Step 1 - clone at the exact version tag
git clone <repo-url> pgmnemo && cd pgmnemo
git checkout [VERSION_TAG]
# Step 2 - build and install
make && sudo make install
# Step 3 - verify
psql -c "SELECT pgmnemo.version();"
```

### 5.3 Database Setup

```bash
# Step 4
createdb pgmnemo_bench
psql pgmnemo_bench -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql pgmnemo_bench -c "CREATE EXTENSION IF NOT EXISTS pgmnemo;"
```

### 5.4 Download Dataset

```bash
# Step 5 - exact download command
[EXACT DOWNLOAD COMMAND]
# Step 6 - verify integrity
sha256sum [ARCHIVE_FILE]
# Expected: [SHA256_HASH]
```

### 5.5 Install Python Dependencies

```bash
# Step 7
cd benchmarks/[benchmark] && pip install -r requirements.txt
```

### 5.6 Dry Run

```bash
# Step 8 - fixture mode, no DB or API calls
python runner.py --version [VERSION_TAG] --dry-run
# Expected exit code: 0
```

### 5.7 Full Run

```bash
# Step 9
python runner.py --version [VERSION_TAG]
# Or: bash run_[benchmark].sh [VERSION_TAG] results/[VERSION_TAG]_$(date +%Y%m%d)
```

### 5.8 Verify Outputs

```bash
# Step 10 - confirm all required artefacts
ls results/[VERSION_TAG]_[DATE]/
# Expected: metrics.json  report.md  raw_judge_calls.jsonl  calibration_*.json

# Step 11 - verify judge prompt hash
python3 -c "import json; m=json.load(open('results/[VERSION_TAG]_[DATE]/metrics.json')); print(m['judge_prompt_sha256'])"
# Must match section 4.1 above
```

---

## 6. Results

> Fill in after run completes. Leave cells as "-" if criterion is not applicable.

### 6.1 Per-Category Results

| Category | N | Accuracy / Score | CI 95% (lo, hi) | Cohen's h/d | Bonferroni p | GO / NO-GO |
|----------|---|-----------------|-----------------|-------------|--------------|------------|
| `[category_1]` | - | - | (-, -) | - | - | - |
| `[category_2]` | - | - | (-, -) | - | - | - |
| `[add rows]` | | | | | | |
| **Aggregate** | - | - | (-, -) | - | - | - |

### 6.2 Aggregate Score

| Metric | Value |
|--------|-------|
| Overall accuracy / composite score | - |
| 95% CI | (-, -) |
| vs. baseline | - |
| Effect size (Cohen's h/d) | - |
| Bonferroni-corrected p | - |
| GO / NO-GO verdict | **[GO | NO-GO]** |

### 6.3 GO / NO-GO Criteria

| Criterion | Threshold | `metrics.json` field |
|-----------|-----------|----------------------|
| Bonferroni p-value | < alpha_corrected | `categories[].p_value_bonferroni` |
| Cohen's h / d | >= 0.2 | `categories[].cohens_h` |
| Wilson CI lower bound | > 0.50 (baseline) | `categories[].ci95_lo` |
| N per category | >= 50 | `categories[].n` |
| Judge prompt hash | matches section 4.1 | `judge_prompt_sha256` |

---

## 7. Threats to Validity

| Threat | Severity | Mitigation |
|--------|----------|------------|
| **Judge model drift** | High | Pin dated snapshot; log `system_fingerprint` in `raw_judge_calls.jsonl` |
| **Dataset contamination** | Medium | Treat absolute scores as upper bounds; compare relative to baseline |
| **Hardware variance** | Low | Report hardware in section 2.4; provide `pg_prewarm` state |
| **Single-seed runs** | Medium | Report seed; require >= 3 seeds for publication claims |
| **Calibration overfitting** | High | Confirm held-out test split before final reporting |
| **Provenance gate interactions** | Medium | Record GUC state in `metrics.json`; ablate with `gate_strict = off` |
| `[add benchmark-specific threats]` | | |

---

## 8. Reproducibility

### 8.1 Seeds and Hashes

| Item | Value / How to verify |
|------|-----------------------|
| Random seed | `PYTHONHASHSEED=42`; recorded in `metrics.json["seed"]` |
| Dataset sha256 | See section 3; verify with `sha256sum <archive>` |
| Judge prompt sha256 | See section 4.1; verify with `metrics.json["judge_prompt_sha256"]` |
| pgmnemo version | `SELECT pgmnemo.version();` vs. `metrics.json["pgmnemo_version"]` |
| OpenAI model fingerprint | `system_fingerprint` in `raw_judge_calls.jsonl` |

### 8.2 Reproducibility Checklist

- [ ] `pgmnemo` version pinned and tagged in git
- [ ] Dataset sha256 recorded and verified (section 3)
- [ ] Judge model is a dated snapshot, not an alias (section 4.1)
- [ ] Judge prompt SHA-256 matches `metrics.json` (section 4.1)
- [ ] `raw_judge_calls.jsonl` committed alongside `metrics.json`
- [ ] Calibration grid JSON committed
- [ ] `PYTHONHASHSEED=42` set and recorded
- [ ] Hardware fully specified in section 2.4
- [ ] All steps in section 5 execute end-to-end on a clean environment
- [ ] `python runner.py --dry-run` exits 0 in CI
- [ ] PI has reviewed and signed off below

### 8.3 PI Sign-Off

> **EVIDENCE THRESHOLD:** Must be completed by a PI before results are cited in ACL, EMNLP, NeurIPS, or equivalent venues.

| Field | Value |
|-------|-------|
| Reviewer name | `[NAME]` |
| Date of review | `[YYYY-MM-DD]` |
| pgmnemo version reviewed | `[VERSION_TAG]` |
| Verdict | `[APPROVED | REQUIRES_REVISION]` |
| Notes | `[any conditions or caveats]` |

---

## 9. References

```bibtex
@article{[CITE_KEY],
  title   = {[PAPER TITLE]},
  author  = {[AUTHORS]},
  year    = {[YEAR]},
  journal = {[VENUE]},
  url     = {[URL]}
}

@software{pgmnemo2026,
  title   = {pgmnemo: Multi-Agent Memory Substrate for {PostgreSQL}},
  year    = {2026},
  version = {[VERSION]},
  license = {Apache-2.0}
}
```
