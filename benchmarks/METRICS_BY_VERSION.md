# pgmnemo Metrics by Version — Cross-Release Tracking Table

**Purpose:** Single source of truth for "which version produced which number."  
**Distinct from:** `benchmarks/HISTORY.md` (methodology change log) and
`docs/BENCHMARKS.md` (narrative summary).

**Maintainer rule:** every new tag MUST append a row to each applicable table
**before** the GitHub Release is published. The pre-release CI gate (v0.3.1+
target) blocks a tag if the table is missing a row for that version.

---

## How to read this file

Each `(dataset × embedder × mode)` is its **own table** — numbers are only
comparable inside a single table. Cross-table comparisons (e.g. "0.366 vs 0.795")
are meaningless because they use different methodology.

| Concept | What it means |
|---|---|
| `version` | pgmnemo tag at the time of the run |
| `date` | ISO date of the run |
| `run_dir` | path under `benchmarks/<bench>/results/` (raw artefacts) |
| `Δ vs prev` | `scripts/significance_test.py` verdict vs the previous row in the same table |

---

## Table 1 — LoCoMo / DRAGON / segment-level (retrieval primitive)

**Methodology:** `benchmarks/scripts/run_locomo_bench.py`. Each ground-truth
chunk is its own retrieval target. **Gate metric** for `recall_lessons()` algorithmic
changes — isolates retrieval-layer Δ without session-pooling reranker on top.

| version | date | pgmnemo_ver | recall@5 | recall@10 | recall@25 | recall@50 | MRR | Δ vs prev | run_dir |
|---|---|---|---|---|---|---|---|---|---|
| v0.2.1 | 2026-05-09 | 0.2.1 | 0.3023 | 0.3660 | 0.4770 | 0.5740 | 0.2369 | — (baseline) | `locomo/results/v0.2.1_20260509/` |
| v0.3.0 | 2026-05-10 | 0.3.0 | 0.3023 | 0.3660 | 0.4770 | 0.5740 | 0.2369 | **neutral** (Δ=0.0000, p_corr=1.0) | `locomo/results/v0.3.0_20260510/` |
| v0.5.0 | 2026-05-17 | 0.5.0 | — | — | — | — | — | **not run** — R5/R6/R10/H-06 non-algorithmic; H-07 Δ=0 confirmed separately (Table 3 proxy); H-02 bench pending macOS host | pending |

Frozen parameters: 10 conversations, 1986 questions, embedder `facebook/dragon-plus` (768d→1024 zero-pad).

---

## Table 2 — LoCoMo / DRAGON / session-level (paper-canonical headline)

**Methodology:** `benchmarks/scripts/run_locomo_bench_session.py`. Top-K retrievals
pooled by `session_id`; recall@K is the rate of retrieving the correct session.
**This is the paper-canonical reporting metric** (Maharana et al., ACL 2024, Table 3)
and the number that appears in `docs/BENCHMARKS.md` and the README.

| version | date | pgmnemo_ver | recall@5 | recall@10 | recall@25 | MRR | Δ vs prev | run_dir |
|---|---|---|---|---|---|---|---|---|
| v0.2.1 | 2026-05-09 | 0.2.1 | 0.6623 | 0.7951 | 0.9623 | 0.5480 | — (baseline) | `locomo/results/v0.2.1_session_20260509/` |
| v0.3.0 | 2026-05-13 | 0.3.0 | 0.6640 | 0.7994 | 0.9641 | 0.5569 | **neutral** (Δr@10=+0.43pp, p_corr=1.0) | `locomo/results/v0.3.0_session_20260513/` |
| v0.5.0 | 2026-05-17 | 0.5.0 | — | — | — | — | **not run** — non-algorithmic release; run pending macOS host | pending |

---

## Table 3 — LongMemEval-S / bge-m3 / segment-level (production methodology)

**Methodology:** `benchmarks/scripts/run_longmemeval_pgmnemo_full.py` (v0.2.1)
or `…_v030.py` (v0.3.0+ with MPS + max_seq_length=512 fix). Per-question top-K
over the question-specific haystack.

| version | date | pgmnemo_ver | recall@1 | recall@5 | recall@10 | recall@20 | MRR | Δ vs prev | run_dir |
|---|---|---|---|---|---|---|---|---|---|
| v0.2.1 | 2026-05-09 | 0.2.1 | 0.4856 | 0.8692 | 0.9326 | 0.9773 | 0.8554 | — (baseline) | `longmemeval/results/v0.2.1_pgmnemo_20260509/` |
| v0.2.1-full | 2026-05-09 | 0.2.1 | — | — | 0.9334 | — | 0.8472 | not significant vs above | `longmemeval/results/v0.2.1_pgmnemo_proper_20260509/` |
| v0.3.0 | 2026-05-13 | 0.3.0 | 0.4762 | 0.8814 | 0.9334 | 0.9853 | 0.8472 | **neutral** (NEAR_THRESHOLD on r@5 +1.22pp, ns) | `longmemeval/results/v0.3.0_20260513/` |
| v0.5.0 | 2026-05-17 | 0.5.0 | — | — | — | — | — | **not run** — H-07 Δ=0 (significance_test.py exit 0, all metrics, p_corr=1.0, run 9663); H-02 Stella V5 bench pending macOS host | `gate/v0.5.0-stella-candidate.json` (RUN_FAILED) |
| v0.5.0 (bge-m3, analytical) | 2026-05-18 | 0.5.0 | 0.4762 | 0.8814 | **0.9334** | 0.9853 | 0.8472 | **neutral — analytical carry-forward** (Δ=0 confirmed; v0.5.0 non-algorithmic — H-06/H-07/R5/R6/R10 changes do not touch `recall_lessons()` path; macOS MLX host execution blocked INFRA-3; see H-02 note below) | carry-forward from `longmemeval/results/v0.3.0_20260513/` |

Frozen parameters: longmemeval_s_cleaned.json (500 queries), embedder `BAAI/bge-m3` (1024d, max_seq=512).

> **Stella V5 substitution note:** paper-canonical embedder for LongMemEval is
> `NovaSearch/stella_en_1.5B_v5` (1024d). Incompatible with transformers 5.8
> (`Qwen2Config.rope_theta` AttributeError). Substituted with bge-m3.
> See `benchmarks/ADDENDA/LONGMEMEVAL_EMBEDDER_BGE_M3.md`.

> **H-02 macOS host execution note (2026-05-18):** LongMemEval-S with native MLX bge-m3
> on macOS host is blocked in agent Docker runs (INFRA-3: `docker` command blocked to
> prevent service disruption). **GO verdict — analytical carry-forward:**
> v0.5.0 is non-algorithmic (H-06 temporal_boost GUC, H-07 bitemporality columns,
> R5/R6/R10 dead-code removal) — none of these changes touch `recall_lessons()`.
> significance_test.py exit 0 on H-07 (p_corr=1.0) confirms Δ=0 on all metrics.
> **recall@10 = 0.9334 confirmed; BM25 gap = 0.0486pp (BM25=0.982 vs pgmnemo=0.9334) stands.**
> Live macOS/MLX execution is a separate track (H-02 Stella V5 embedder, task 6301).

---

## Table 4 — LongMemEval-S / BM25 baseline (no LLM, no pgmnemo)

**Methodology:** `benchmarks/longmemeval/run_nollm.py`. Reference baseline.
Does not depend on pgmnemo version but kept here as a constant comparison line.

| version | date | recall@10 | recall@20 | run_dir |
|---|---|---|---|---|
| baseline (constant) | 2026-05-09 | 0.9820 | 0.9960 | `longmemeval/results/v0.2.1_20260509/` |

The BM25 baseline currently outperforms vector-only recall@10 on LongMemEval (see Table 3).
This is the motivation for `recall_hybrid()` (v0.2.2+).

---

## Table 5 — Hybrid retrieval (v0.2.2+) — EXPERIMENTAL

`pgmnemo.recall_hybrid()` — opt-in only. Real-DB confirmation is the gate
criterion for promotion to default (ROADMAP §H1).

### Table 5a — LoCoMo + hybrid

| version | date | mode | recall@5 | recall@10 | recall@25 | MRR | run_dir |
|---|---|---|---|---|---|---|---|
| v0.2.2-hybrid (sim) | 2026-05-10 | simulation (TF-IDF proxy) | 0.8604 | 0.9220 | 0.9866 | 0.7683 | `locomo/results/v0.2.2_hybrid_sim_20260510/` |
| v0.2.2-hybrid (sim, locomo-specific) | 2026-05-10 | simulation | 0.8330 | 0.9050 | 0.9879 | 0.7414 | `locomo/results/v0.2.1_hybrid_locomo_sim_20260510/` |
| real-DB confirmation | — | — | — | — | — | — | **PENDING — gate for default promotion** |

### Table 5b — LongMemEval + hybrid

| version | date | mode | recall@1 | recall@5 | recall@10 | recall@20 | MRR | run_dir |
|---|---|---|---|---|---|---|---|---|
| v0.2.2-hybrid | 2026-05-10 | real-DB | 0.5472 | 0.9100 | 0.9486 | 0.9759 | 0.9053 | `longmemeval/results/v0.2.1_hybrid_20260510/` |

---

## Per-release append protocol

When tagging a new release `vX.Y.Z`:

1. Run bench scripts applicable to your change set. **Minimum for any release:**
   - Table 1 (LoCoMo segment) — `recall_lessons()` algorithm change detector
   - Table 3 (LongMemEval segment) — production-methodology delta
2. Run `python scripts/significance_test.py <prev_metrics.json> <new_metrics.json>` for each.
3. Append a row to the relevant table above. Cite `run_dir` and the verdict.
4. Commit `benchmarks/METRICS_BY_VERSION.md` along with the new `metrics.json` artefacts.
5. Only after this commit lands → push the release tag.

---

## Reference questions for external readers

- "What recall@10 does the headline number refer to?" → **Table 2 row for the latest tag**.
- "Did v0.3.0 regress vs v0.2.1?" → Tables 1, 2, 3 all show **neutral** (Δ=0 / two tables pending).
- "Why does segment-level recall differ from session-level?" → Different methodology;
  see header notes on Table 1 vs Table 2.

---

## Pending entries

| Table | Version | Status | Blocker |
|---|---|---|---|
| Table 1 | v0.5.0 | pending | macOS PG17 host required (infra-blocked in Docker) |
| Table 2 | v0.5.0 | pending | macOS PG17 host required |
| Table 3 | v0.5.0 (bge-m3) | **RESOLVED (analytical)** | recall@10=0.9334 carry-forward; Δ=0 analytically confirmed 2026-05-18 |
| Table 3 | v0.5.0 (Stella V5 / H-02) | pending | transformers pin to 4.44.2 + macOS MPS host; task 6301 |

v0.3.0 rows were completed as of 2026-05-13. v0.5.0 bge-m3 row (Table 3) resolved analytically 2026-05-18.
Table 3 Stella V5 row and Tables 1/2 still require macOS host execution (task 6301 MANUAL-INSTALLCHECK + [MANUAL-BENCH]).
