# pgmnemo Canonical Recall Benchmark Protocol

**Protocol version:** 1.0.0
**Frozen:** 2026-05-10
**Status:** CANONICAL — do not modify without bumping version and updating HISTORY.md

> Release notes citing a recall improvement MUST reference this document as:
> "pgmnemo Recall Benchmark Protocol v1.0.0 (benchmarks/PROTOCOL.md)"

---

## 1. Purpose

This document defines the one canonical procedure for measuring recall quality of `pgmnemo`.
Any deviation from this protocol must be (a) labelled a deviation in the results artefact, and
(b) logged in `benchmarks/HISTORY.md` before publication.

---

## 2. Registered Corpora

### 2.1 LongMemEval

| Field | Value |
|-------|-------|
| Paper | Wu et al. ICLR 2025 — arXiv:2410.10813 |
| Dataset | `xiaowu0162/longmemeval-cleaned`, file `longmemeval_s_cleaned.json` |
| Split | Test split only (500 items) |
| sha256 | `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442` |
| License | See dataset repository |
| Download | `git clone https://github.com/xiaowu0162/LongMemEval "$LONGMEMEVAL_DATA_DIR"` |
| Corpus unit | One item = one multi-session conversation haystack (~47.7 sessions/item) |

**Query taxonomy (n=500):**

| Question type | N |
|---|---|
| single-session-user | 70 |
| multi-session | 133 |
| single-session-preference | 30 |
| temporal-reasoning | 133 |
| knowledge-update | 78 |
| single-session-assistant | 56 |
| **Total** | **500** |

### 2.2 LoCoMo

| Field | Value |
|-------|-------|
| Paper | Maharana et al. ACL 2024 — arXiv:2402.17753 |
| Dataset | `snap-research/locomo`, file `locomo10.json` |
| Split | Full eval set (10 conversations, 1986 questions) |
| License | See dataset repository |
| Download | `huggingface-cli download snap-research/locomo --local-dir "$LOCOMO_DATA_DIR"` |
| Corpus unit | **Session-level** — one segment per dialog session (not per turn). See §2.2.1. |

#### 2.2.1 Session-level granularity rule (MANDATORY)

Corpus must be extracted at session granularity: one text segment per dialog session, formed
by concatenating all turns within that session. This yields ~272 segments for locomo10.json
(10 conversations × ~27 sessions each).

**DO NOT** extract at turn granularity. Turn-level extraction was a methodology bug
(deprecated run `locomo/results/v0.2.1_20260509/`); it inflates corpus size to 5882 segments
and depresses recall@10 by ~43pp vs. the paper-class result. See `benchmarks/HISTORY.md`
(2026-05-09 entry) for the full correction record.

Evidence reference normalisation: strip the turn suffix from evidence IDs before matching
(e.g. `"D1:3"` → `"D1"`). All 1982 questions with evidence must resolve to at least one
corpus segment; verify 100% oracle coverage before any run.

---

## 3. Embedding Sources

### 3.1 Canonical embedders

| Benchmark | Canonical embedder | Dimensions | Source |
|-----------|-------------------|-----------|--------|
| LongMemEval | `BAAI/bge-m3` | 1024 | Hugging Face |
| LoCoMo | `facebook/dragon-plus` | 768 (zero-padded to 1024 in pgvector) | Hugging Face |

**LongMemEval deviation note:** The Wu et al. paper uses `NovaSearch/stella_en_1.5B_v5`.
`bge-m3` is a permanent protocol-level substitution (not a per-run deviation) because
Stella V5 `modeling_qwen.py` is incompatible with transformers ≥5.8.0. The substitution is
documented in `benchmarks/longmemeval/ADDENDA/LONGMEMEVAL_EMBEDDER_BGE_M3.md` and in
`benchmarks/HISTORY.md` (2026-05-09). Claims based on this protocol must disclose this
substitution.

### 3.2 Truncation

| Parameter | Value |
|-----------|-------|
| max_seq_length | 512 tokens (bge-m3 default cap) |
| batch_size | 8 (MPS-safe) |
| PYTHONHASHSEED | 42 |

---

## 4. Recall Metric Definition

### 4.1 Primary metrics

| Metric | Definition |
|--------|-----------|
| `recall@k` | Fraction of questions for which at least one ground-truth evidence segment appears in the top-k retrieved results. Binary per question. |
| `MRR` | Mean Reciprocal Rank over all questions. `1/rank` of the first relevant result; 0 if not in top-k (k=50 for MRR). |

### 4.2 Retrieval function

```sql
SELECT *
FROM pgmnemo.recall_lessons(
    embedding       := $query_embedding,  -- float4[] dim=1024
    k               := $recall_k,         -- protocol default: 10
    query_text      := $query_text,        -- for BM25 component
    project_id      := $project_uuid
)
ORDER BY score DESC
LIMIT $recall_k;
```

Active scoring components: cosine similarity (HNSW) + BM25 (FTS) + recency decay + importance weight + graph proximity.

### 4.3 GUC state required

```sql
SET pgmnemo.gate_strict = 'warn';   -- provenance gate: warn, not block
SET pgmnemo.tenant_id   = '<bench_uuid>';
SET pgmnemo.recency_weight = 0.10;  -- protocol default (calibration result)
```

Record actual GUC values in `metrics.json["guc_state"]` per run.

---

## 5. Include / Exclude Rules for Unverified Results

A result is **UNVERIFIED** and MUST NOT be cited in release notes unless ALL of the following are true:

| Gate | Requirement |
|------|-------------|
| Dataset integrity | `sha256sum <corpus_archive>` matches §2 value |
| Version pin | `SELECT pgmnemo.version()` matches `metrics.json["pgmnemo_version"]` |
| Seed recorded | `PYTHONHASHSEED=42` set; value in `metrics.json["seed"]` |
| Oracle coverage | LoCoMo: 100% of evidence items resolve to ≥1 corpus segment |
| Corpus granularity | LoCoMo: session-level extraction confirmed (segments ≈ 272, not ~5882) |
| Artefacts present | `metrics.json`, `report.md`, `raw_retrievals.jsonl` all committed |
| BLOCKED absent | No `BLOCKED.md` in the results directory |

A result with a `BLOCKED.md` present is **BLOCKED** and must carry that label if referenced at all.

---

## 6. Acceptable Variance Band

| Metric | Benchmark | Acceptable run-to-run variance |
|--------|-----------|-------------------------------|
| recall@10 | LongMemEval | ± 0.005 (95% CI half-width ~0.019; run variance << CI) |
| recall@10 | LoCoMo | ± 0.010 |
| MRR | LongMemEval | ± 0.010 |
| MRR | LoCoMo | ± 0.015 |

Variance exceeding these bands must be investigated before a result is declared canonical.
Typical causes: corpus extraction granularity bug (§2.2.1), embedding model substitution,
pgmnemo GUC drift, PostgreSQL planner variance on cold vs. warm HNSW index.

**Baseline numbers for v0.2.1 (protocol v1.0.0):**

| Benchmark | recall@10 | recall@10 CI 95% | MRR | MRR CI 95% |
|-----------|-----------|-------------------|-----|------------|
| LongMemEval | **0.933** | (0.914, 0.952) | **0.855** | (0.829, 0.882) |
| LoCoMo | **0.795** | — | **0.548** | — |

---

## 7. Canonical Run Procedure (summary)

Full step-by-step procedure with exact commands is in `benchmarks/README.md §5`. This section
provides the canonical command sequence; README is authoritative on parameters.

```bash
# 1. Install pgmnemo at the exact tag
git clone <repo> pgmnemo && cd pgmnemo && git checkout <VERSION_TAG>
make && sudo make install

# 2. Create benchmark DB
createdb pgmnemo_bench
psql pgmnemo_bench -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pgmnemo;"

# 3. Set environment
export PYTHONHASHSEED=42
export PGMNEMO_DSN="postgresql://user:pass@host:5432/pgmnemo_bench"

# 4. LongMemEval
cd benchmarks/longmemeval && python runner.py --version <VERSION_TAG> --dry-run  # must exit 0
python runner.py --version <VERSION_TAG>

# 5. LoCoMo
cd benchmarks/locomo && bash run_locomo.sh <VERSION_TAG> results/<VERSION_TAG>_$(date +%Y%m%d)

# 6. Verify outputs — each results/ dir must contain:
#    metrics.json  report.md  raw_retrievals.jsonl
#    No BLOCKED.md present
```

---

## 8. Citation in Release Notes

When a release note cites a recall improvement, use this template:

```
Recall improvement measured per pgmnemo Recall Benchmark Protocol v1.0.0
(benchmarks/PROTOCOL.md). Corpus: [LongMemEval | LoCoMo]. Embedder: [name].
Result: recall@10 [value] (v[prev] → v[new]). Full run artefacts:
benchmarks/[bench]/results/[version_date]/
```

Do not cite a recall number without the protocol version reference. Do not cite a result with
a `BLOCKED.md` marker.

---

## 9. Protocol Versioning

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-05-10 | Initial frozen protocol; baseline from v0.2.1 runs |

To amend this protocol:

1. Bump version (semver: breaking change = major, methodology addition = minor, typo = patch).
2. Add a row to the table above.
3. Add an entry to `benchmarks/HISTORY.md`.
4. Re-run both benchmarks under the new protocol and update §6 baseline numbers.
5. Update README.md Benchmarks section to cite the new version.

---

## 10. References

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
```
