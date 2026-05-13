# pgmnemo Benchmark Protocol

**Status:** v1 — 2026-05-10  
**Maintainer:** Project Lead  
**Scope:** Reproducible recall-quality benchmarks for every released version

This document defines the canonical benchmark protocol for pgmnemo. It is referenced
by `RELEASE_PROCESS.md` and gated by CI on every release tag.

---

## 1. Why a protocol?

Without a frozen protocol, recall numbers across releases are incomparable. Different
embedders, truncation rules, batch sizes, hardware, or DB states all silently move
the metric. The protocol below freezes everything that is **not** the version under test.

The unit of measurement is **Δ vs previous tagged version** on a fixed corpus.

---

## 2. Two-phase architecture

Benchmarks split into two phases with very different cost:

| Phase | Cost | When to re-run |
|---|---|---|
| **A. Corpus snapshot** (embed + INSERT) | ~20–60 min | Only when **(a)** the dataset changes, **(b)** the embedder changes, or **(c)** the `agent_lesson` schema changes in a way that affects ingest |
| **B. Query/retrieval test** (recall@K, MRR) | ~1–2 min | **Every release** — this is the version-comparison primitive |

For a typical bug-fix or schema-additive release (e.g. v0.2.0 → v0.3.0), only Phase B
runs. The corpus snapshot from the previous version is reused via `pg_dump`/`pg_restore`.

When `recall_lessons()` itself changes (scoring weights, GUC defaults, BFS algorithm,
filter logic) — Phase B is sufficient to detect the regression, the corpus snapshot
need not be regenerated.

---

## 3. Frozen parameters (DO NOT MODIFY without RFC)

| Parameter | Value | Rationale |
|---|---|---|
| LoCoMo dataset | `snap-research/locomo10.json` SHA-256 `79fa87e9…ea698ff4` | Paper-canonical, 10 conversations, 1986 questions |
| LoCoMo embedder | `facebook/dragon-plus` (768d, zero-padded to 1024) | Paper-canonical (Maharana et al., ACL 2024) |
| LongMemEval dataset | `longmemeval_s_cleaned.json` from `xiaowu0162/longmemeval-cleaned` | Paper-canonical (Wu et al., ICLR 2025) |
| LongMemEval embedder | `BAAI/bge-m3` (1024d, native) | Substitution for Stella (paper canonical) due to transformers 5.8 incompatibility — documented in `benchmarks/ADDENDA/LONGMEMEVAL_EMBEDDER_BGE_M3.md` |
| Storage vector dim | `vector(1024)` | pgmnemo schema constraint until DIM-FLEX lands |
| Truncation per session | LME: 8000 chars (≈ bge-m3 8192 token ctx); LoCoMo: no truncation | Mathematically near-equivalent to no-truncation for both datasets |
| Retrieval k | `{5, 10, 25, 50}` | Paper canonical |
| Primary gate metric | `recall@10` | Paper-canonical headline metric |
| Significance test | Two-proportion z-test + Holm-Bonferroni correction across all metrics | `scripts/significance_test.py` |
| Significance threshold | `p_corr < 0.05` for both improvement claims and regression alarms | Bonferroni-safe |
| Regression threshold | Δ recall@10 ≥ 2pp absolute drop with `p_corr < 0.05` → BLOCKING | Discriminates from CI/noise |

Batch size is a hardware constraint, **not a methodology parameter** — the embedding
is deterministic for given (model_weights, input_text). MPS at batch=8 produces
identical vectors to CPU at batch=16.

---

## 4. Hardware-tier baselines

Benchmarks are run on the maintainer's reference rig (`pgmnemo-bench` Docker container).
Latency numbers (p50, p95, p99) are **only comparable** within the same rig — they are
**not** absolute claims. Recall metrics are hardware-independent.

| Tier | Hardware | Notes |
|---|---|---|
| Reference (maintainer) | Apple M-series, 24+GB unified memory, MPS for embeddings | Numbers in `benchmarks/*/results/` are from this rig |
| CI (self-hosted runner) | TBD — Issue #16 follow-up | Reproducibility check, may use CPU and longer runtimes |
| External reproducers | Any; recall results must match within 95% CI overlap | Latency may differ by 10×+ |

---

## 5. Phase A — Corpus snapshot (rare)

Run when `dataset` or `embedder` or `agent_lesson` ingest path changes.

```bash
# 1. Start a clean bench DB
docker run -d --name pgmnemo-bench -p 15432:5432 \
  -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=bench \
  pgvector/pgvector:pg17

# 2. Install pgmnemo at the current default_version (or the version owning the
#    schema you want to freeze) and run CREATE EXTENSION pgmnemo CASCADE

# 3. Run the bench script — it will TRUNCATE + re-embed + INSERT
python benchmarks/scripts/run_locomo_bench.py        # ~20 min
python benchmarks/scripts/run_longmemeval_pgmnemo_full.py    # ~30 min on MPS

# 4. Snapshot the DB for reuse
docker exec pgmnemo-bench pg_dump -U bench -F custom -f /tmp/corpus.dump bench
docker cp pgmnemo-bench:/tmp/corpus.dump \
  benchmarks/snapshots/corpus_<dataset>_<embedder>_<date>.dump

# 5. Record the snapshot SHA-256 in benchmarks/snapshots/INDEX.md
```

The corpus snapshot is the immutable reference for all subsequent retrieval-only runs.

---

## 6. Phase B — Per-version retrieval-only test (every release)

For releases that do not change the embedding pipeline or core schema:

```bash
# 1. Restore the corpus snapshot into a fresh DB
docker exec pgmnemo-bench psql -U bench -c "DROP DATABASE IF EXISTS bench_test"
docker exec pgmnemo-bench psql -U bench -c "CREATE DATABASE bench_test"
docker cp benchmarks/snapshots/corpus_locomo_dragon_<date>.dump pgmnemo-bench:/tmp/c.dump
docker exec pgmnemo-bench pg_restore -U bench -d bench_test /tmp/c.dump

# 2. Upgrade pgmnemo extension inside the snapshot DB to the target version
docker exec pgmnemo-bench psql -U bench -d bench_test \
  -c "ALTER EXTENSION pgmnemo UPDATE TO '<target_version>'"

# 3. Run the query-only suite (skip TRUNCATE + re-embed by pointing at bench_test)
python benchmarks/scripts/run_locomo_bench.py \
  --db-name bench_test --skip-corpus  # NOTE: --skip-corpus flag is a v0.3.1 backlog item

# 4. Run the significance test
python scripts/significance_test.py \
  benchmarks/locomo/results/v<previous>_<date>/metrics.json \
  benchmarks/locomo/results/v<target>_<date>/metrics.json

# 5. If z-test verdict is "neutral" or "improvement" — gate PASS
#    If verdict is "regression with p<0.05" on recall@10 ≥ 2pp — gate FAIL, block release
```

**Backlog item (v0.3.1):** `--skip-corpus` flag for `run_locomo_bench.py` and the LME
scripts. Currently they unconditionally TRUNCATE + re-embed. Snapshot-restore today
works but Phase B re-embeds on top, wasting ~20 min/release.

---

## 7. Gate decision matrix

**Tool:** `scripts/significance_test_extended.py` — runs z-test per category × metric
+ OVERALL with Holm-Bonferroni correction across all cells. Exit code drives the gate.

```
exit code   significance_test_extended verdict             gate    Action
---------   ----------------------------------------       ----    ------
0           neutral (all cells within noise)               PASS    Tag, ship; CHANGELOG omits perf claim
1           significant improvement, no regression         PASS    Tag, ship; CHANGELOG includes claim
2           significant regression in any cell             FAIL    Block release; root-cause before re-tag
3           NEAR_THRESHOLD: |Δ| ≥ 1pp in any cell, ns      WARN    Tag allowed, but the cells MUST be listed
                                                                   in the release notes as monitor-watchlist
```

The per-category coverage is the crucial part: `OVERALL` can be neutral while
`temporal` regresses by −3pp and `open_domain` improves by +2pp; these offset
each other in the average but expose real algorithmic drift. The extended test
catches this where the old overall-only test missed it.

**Sample run (v0.2.1 → v0.3.0, LoCoMo session-level):**

```
SIGNIFICANT REGRESSIONS  : 0
SIGNIFICANT IMPROVEMENTS : 0
NEAR-THRESHOLD (|Δ| ≥ 1.0pp, ns): 9
  📉 temporal/recall@5: -3.81pp     ← weakest category, watch
  📉 temporal/recall@10: -1.49pp
  📉 temporal/mrr: -1.71pp
  📈 open_domain/recall@5: +1.66pp  ← offsets in OVERALL
  📈 open_domain/recall@10: +1.96pp
  📈 open_domain/mrr: +1.99pp
  📉 single_hop/recall@5: -1.53pp
  📉 multi_hop/recall@5: -1.19pp
  📈 multi_hop/mrr: +1.57pp
```

This is exit 3 (WARN) — the v0.3.0 release notes must list these 9 cells in a
"Monitor watchlist" section so reviewers know what to track next release.

---

## 7a. Visualisation of cross-version progression

After every release, regenerate the SVG + markdown progression artefacts:

```bash
# LoCoMo session-level (paper-canonical headline)
python scripts/render_progression.py \
  --pattern "benchmarks/locomo/results/v*_session_*/metrics.json" \
  --out-svg docs/img/progression_locomo_session.svg \
  --out-md docs/img/progression_locomo_session.md \
  --title "LoCoMo session-level — version progression"

# LoCoMo segment-level (algorithmic gate)
python scripts/render_progression.py \
  --pattern "benchmarks/locomo/results/v*[0-9]_[0-9]*/metrics.json" \
  --out-svg docs/img/progression_locomo_segment.svg \
  --out-md docs/img/progression_locomo_segment.md \
  --title "LoCoMo segment-level — version progression"

# LongMemEval
python scripts/render_progression.py \
  --pattern "benchmarks/longmemeval/results/v*_pgmnemo*/metrics.json" \
  --out-svg docs/img/progression_longmemeval.svg \
  --out-md docs/img/progression_longmemeval.md \
  --title "LongMemEval-S — version progression"
```

**What gets rendered (per `(dataset × mode)`):**
- One SVG: 6 rows × 4 cols small-multiples — overall + 5 LoCoMo categories,
  each with recall@5/10/25/MRR line chart, CI95 band, version labels on X axis,
  Δpp annotation between consecutive versions when |Δ|≥1pp (green up / red down)
- One markdown table: per-version × per-metric, with `▲/▼ Xpp` superscript
  showing delta vs prev row; 📈/📉 emoji when |Δ|≥1pp

These artefacts are committed under `docs/img/` and referenced from
`docs/BENCHMARKS.md`. Pure-SVG, no chart-library dependency — GitHub renders
them natively in the markdown reader.

---

## 8. CI integration (v0.3.1 target)

```yaml
# .github/workflows/release.yml — proposed addition
- name: Benchmark gate
  run: |
    test -f benchmarks/gate/v${VERSION}.json || {
      echo "Release-blocking: benchmarks/gate/v${VERSION}.json missing"
      echo "Run Phase B retrieval test against snapshot and commit the gate file"
      exit 1
    }
    python scripts/significance_test.py \
      benchmarks/gate/v<prev_tag>.json \
      benchmarks/gate/v${VERSION}.json
```

The gate file format is `metrics.json` shape with frozen schema columns:
`version`, `date`, `dataset`, `dataset_sha256`, `embedder`, `pgmnemo_version`,
`overall.{recall@5,recall@10,recall@25,recall@50,mrr}`.

---

## 9. Reporting

For every release the bench owner files:

- `benchmarks/<bench>/results/v<version>_<date>/metrics.json` — full numbers, machine-readable
- `benchmarks/<bench>/results/v<version>_<date>/report.md` — narrative summary
- `spec/reports/BENCH_<bench>_v<version>_vs_v<prev>_<date>.md` — significance test output
- **`benchmarks/METRICS_BY_VERSION.md`** — append a row to every applicable table.
  **This is the single source of truth for version-to-version dynamics.** Public
  release notes cite numbers via a link to the relevant row in this file.

Public-facing claims (`docs/BENCHMARKS.md`, README, release notes) cite only
`p_corr < 0.05` improvements. Simulation / proxy results carry an explicit
`(simulation, <proxy>)` label.

---

## 10. Open issues tracked here

- **Issue #16** — protocol freeze: closed by this document
- **Backlog v0.3.1** — `--skip-corpus` flag on bench scripts
- **Backlog v0.3.1** — `benchmarks/snapshots/` directory + `INDEX.md`
- **Backlog v0.3.2** — CI integration of the gate file mechanism (self-hosted runner)

---

## Appendix — Why the LoCoMo numbers in BENCHMARKS.md differ from segment-level metrics.json

BENCHMARKS.md reports session-level metrics (recall@10 = 0.795) — this uses a
session-pooling reranker on top of segment-level retrieval. The raw
`benchmarks/locomo/results/v0.2.1_20260509/metrics.json` shows segment-level
metrics (recall@10 = 0.366). Both are valid; the session-level number matches
the paper convention. The gate protocol uses the segment-level run because it
isolates the retrieval-layer Δ without the reranker confound.
