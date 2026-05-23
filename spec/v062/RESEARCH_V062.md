---
date: 2026-05-23
author: principal_investigator (id=77)
task_id: SWDEV-260523-2-RESEARCH
phase: RESEARCH
parent_dag: SWDEV-260523-2
status: complete
base_research: spec/v061/RESEARCH_V061.md (commit 111cfca)
---

# pgmnemo v0.6.2 — Research Document

**Scope:** F1 only — RRF Fix-A. F2 (as_of_ts) and F3 (stress test) shipped in v0.6.1.

---

## 0. Delta from v0.6.1 Research (commit 111cfca)

The v0.6.1 research (commit 111cfca) remains accurate for F2 and F3 — those shipped
successfully. For F1, the real-DB benchmark run during the v0.6.1 IMPLEMENT phase
(before the death-loop killed the run) produced a decisive finding that invalidates the
A-scale recommendation:

**ORDER BY `rrf_diag` with fixed k=60 causes −22.44pp regression in recall@10
(0.9334 → 0.7090) on LongMemEval-S (N=500, bge-m3 1024d).**
Results: `benchmarks/longmemeval/results/v0.6.1_realdb_20260523/`. Gate verdict: FAIL.

Root cause (from `benchmarks/gate/v0.6.1.json`): with ~48 segments per session, rank
differences compress severely under k=60. Items with no BM25 match receive an
*arbitrary* `bm25_rank` via `ROW_NUMBER()` on tied 0-scores — these ties break
deterministically but incorrectly, placing high-cosine/no-BM25 answers below
BM25-matching non-answers in the RRF fusion. `fusion_score` avoids this because
`bm25_weight × 0 = 0` for non-matching items, so they do not corrupt the ordering.

The v0.6.1 research expected +0.5 to +2pp; the actual result was −22.44pp.
The v0.6.1 analysis of A-scale's *normalization* properties was correct but missed
this *list-semantics* problem. A-scale, A-pure, and A-norm all share this defect:
`rrf_diag` itself is computed from ROW_NUMBER() over all candidates, so any variant
that ORDER BYs on `rrf_diag` inherits the sparse-BM25 corruption.

**v0.6.2 therefore requires a different fix-class, not just constant tuning.**

---

## 1. Current State After v0.6.1 Ship

| Feature | v0.6.1 status | v0.6.2 target |
|---------|---------------|---------------|
| F1 RRF Fix-A | DEFERRED (−22.44pp gate fail) | IMPLEMENT with corrected semantics |
| F2 as_of_ts | **SHIPPED** (commit e4d640e) | n/a |
| F3 stress test | **SHIPPED** (commit e4d640e) | n/a |
| recall_hybrid() ORDER BY | fusion_score (unchanged from v0.5.1) | target: rrf with proper semantics |

Baseline metrics (carry-forward unchanged):
| Metric | Gate value |
|--------|-----------|
| LongMemEval-S recall@10 (bge-m3) | ≥ 0.9434 (+1pp vs v0.5.1 0.9334) |
| LoCoMo session recall@10 | ≥ 0.7994 (must not regress) |
| pg_regress | 16/16 PASS (v0.6.1 now has 16 tests, not 14) |

---

## 2. RRF Fix-A Alternatives for v0.6.2

All variants share the same goal: make RRF semantics correct for sparse BM25 corpora
(items without any BM25 match should not receive a rank in the BM25 list).

### Alternative A: Sparse-safe proper RRF (RECOMMENDED)

**Principle:** Only assign a rank to an item in the BM25 list if its `bm25_score > 0`.
Items absent from a list do not contribute to (or receive) an RRF rank for that list.
This is the semantically correct RRF formulation (Cormack et al. 2009).

**Implementation (recall_hybrid()):**
```sql
-- Replace the unified ROW_NUMBER() approach with two separate ranked lists:
--
-- Vec list: all candidates (every item gets a vec_rank)
-- BM25 list: ONLY items with bm25_score > 0 (absent items use sentinel = 1/rrf_k)
--
-- In the anchors CTE, rrf_diag formula changes to:
_rrf_diag := (
    vec_w / (_rrf_k_f + ROW_NUMBER() OVER (ORDER BY cosine_score DESC))
  + CASE WHEN bm25_score > 0
         THEN bm25_w / (_rrf_k_f + RANK() OVER (PARTITION BY (bm25_score>0) ORDER BY bm25_score DESC))
         ELSE bm25_w / (_rrf_k_f + _total_candidates + 1)  -- effective exclusion
    END
);
```

Alternatively: run two separate subqueries, join on lesson_id, compute rrf_diag from
the two independent rank columns.

| Criterion | Assessment |
|-----------|-----------|
| Fixes sparse-BM25 corruption | **YES** — non-matching items get sentinel rank, not arbitrary tie-break |
| Output column `rrf_score` meaning | **changes** — now semantically correct |
| Diff size | **~30–40 lines** (CTE restructuring required) |
| CTE restructuring risk | **MEDIUM** — increases AmbiguousColumn/UndefinedTable risk (same class as v0.6.0 failure) |
| Smoke test safe | **MUST verify** — output column set unchanged but computation changes |
| Backward compat | **YES** — signature unchanged |
| Literature support | **STRONG** — this is the canonical RRF definition |
| Expected recall@10 gain | **+1 to +3pp** (eliminates the 22pp regression; may exceed baseline) |

**Pros:**
- Fixes the root cause, not a symptom
- Semantically correct RRF — defensible in paper and documentation
- Items with no BM25 signal are ranked purely by vector similarity (correct behavior)
- Largest expected recall gain of all variants

**Cons:**
- Requires CTE restructuring — the exact failure mode from v0.6.0 must be avoided with care
- Implementation must use a CTE for each ranked list separately, then JOIN — more code
- The existing `rrf_score` output column changes meaning (breaking for anyone parsing it numerically, but pgmnemo has no documented external consumers of this value)
- Two separate subqueries may have slightly higher runtime (~5–10% for typical corpus sizes)

**Guard:** After implementing, run `smoke_recall_hybrid.py` BEFORE any benchmark. If
AmbiguousColumn or UndefinedTable appears, stop and debug CTE scope — do not proceed.

---

### Alternative B: Corpus-size-adaptive k

**Principle:** Set `_rrf_k_f = GREATEST(5.0, _total_candidates::FLOAT / 10.0)` instead
of the fixed constant 60. For a 48-segment corpus, k≈5; for a 10K corpus, k≈1000.
Adaptive k makes rank deltas proportional to corpus density, reducing compression.

**Implementation:**
```sql
-- In DECLARE:
_rrf_k_f   DOUBLE PRECISION;  -- was CONSTANT 60.0

-- In BEGIN, after counting candidates:
SELECT COUNT(*) INTO _total_candidates FROM candidates;
_rrf_k_f := GREATEST(5.0, _total_candidates::DOUBLE PRECISION / 10.0);

-- Everything else unchanged — rrf_diag uses _rrf_k_f dynamically
```

| Criterion | Assessment |
|-----------|-----------|
| Fixes sparse-BM25 corruption | **PARTIAL** — reduces distortion but doesn't eliminate it |
| CTE restructuring | **NONE** — single variable change |
| Diff size | **~5 lines** |
| Smoke test safe | **YES** |
| Backward compat | **YES** — same signature, same output columns |
| Expected recall gain | **UNKNOWN** — mathematically reduces rank distortion; magnitude unproven |
| Regression risk | **LOW** — k=60 was already a reasonable default; adaptive k adds coverage |

**Pros:**
- Smallest possible code change
- No CTE restructuring risk
- Composable with Alternative A (can combine both)
- Easy to tune via GUC in future (`pgmnemo.rrf_k = 'adaptive'`)

**Cons:**
- Does not fix the semantic error — tied 0-score items still corrupt ranking, just less so
- Unpredictable behavior: formula `N/10` is a heuristic without literature support
- May introduce non-monotonic quality as corpus size changes (users adding data see varying recall)
- Still requires real-DB bench to verify gain — cannot ship without it
- Alone, unlikely to recover the full 22pp regression

---

### Alternative C: BM25-gate conditional fusion (no RRF for zero-match items)

**Principle:** Keep `ORDER BY fusion_score` (current, which preserves baseline).
Add RRF-boosting only when `bm25_score > 0` for a candidate. Items with no BM25
match use pure vector similarity; items with BM25 match use rrf_diag. This is a
conditional blend, not pure RRF.

**Implementation (final ORDER BY):**
```sql
ORDER BY (
    CASE
        WHEN s.bm25_score > 0 THEN
            -- RRF with proper semantics for matched items
            vec_w / (_rrf_k_f + s.vec_rank) + bm25_w / (_rrf_k_f + s.bm25_rank_among_matched)
        ELSE
            -- Pure vector for non-BM25-matching items (identical to fusion_score path when bm25=0)
            vec_w * s.cosine_score
    END
  + _aux_scale * (importance/5.0 + recency + provenance)
) DESC
```

Where `bm25_rank_among_matched` is a rank computed only over candidates with `bm25_score > 0`.

| Criterion | Assessment |
|-----------|-----------|
| Fixes sparse-BM25 corruption | **YES** — non-matching items are correctly ordered by vec |
| Regression risk vs baseline | **LOW** — degrades gracefully to fusion_score semantics |
| Diff size | **~20 lines** |
| CTE restructuring | **MINOR** — need `bm25_rank_among_matched` window function, addable to existing CTE |
| Smoke test safe | **YES** — output columns unchanged |
| Literature support | **NONE** — non-standard hybrid, novel approach |
| Expected recall gain | **+0.5 to +1.5pp** (conservative: only BM25-matched queries benefit) |

**Pros:**
- Conservative: non-BM25 sessions are unaffected (baseline preserved for worst case)
- Addresses root cause for BM25-matched queries without touching the zero-match path
- No deep CTE restructuring (one additional window function partition)
- Easier to explain to users: "RRF when BM25 matches; pure vector otherwise"

**Cons:**
- Non-standard: no paper supports this exact formulation
- Conditional branch in ORDER BY is harder to reason about
- Gain is bounded by the fraction of queries where BM25 matches (if corpus is predominantly semantic, gain is minimal)
- Two execution paths make benchmarking and regression testing more complex

---

### Alternative D: Revert to fusion_score + mark F1 won't-fix (deferral)

**Principle:** Keep `recall_hybrid()` unchanged (fusion_score). Ship v0.6.2 with
pre-tag checklist items only (CHANGELOG, version bumps, fresh-install SQL).
Revisit RRF in v0.7.0 with a proper two-list implementation after stress test data
informs realistic corpus size distributions.

| Criterion | Assessment |
|-----------|-----------|
| Regression risk | **NONE** — no code change |
| Recall gain | **NONE** |
| Ship risk | **LOWEST** |
| Addresses gate | **NO** — LME gate criterion (+1pp) cannot pass without F1 |

**Pros:** Zero risk; preserves all baselines; allows time for proper implementation

**Cons:**
- Cannot pass the headline gate (LME recall@10 ≥ 0.9434)
- Delays RRF capability — already deferred twice (v0.6.0, v0.6.1)
- Task spec explicitly states "all-or-nothing" gate — this is the gate-fail path, not a valid ship path

**Verdict:** Valid only if Alternatives A/B/C all fail real-DB bench.

---

## 3. Recommendation

**Implement Alternative A (sparse-safe proper RRF) as primary, with Alternative B
(adaptive k) as a composable add-on.**

Rationale:
1. Alternative A fixes the root cause identified in the v0.6.1 bench finding
2. Alternative B adds marginal safety for edge-case corpora; composing both costs ~5 extra lines
3. Alternative C (conditional fusion) is defensible but non-standard; use as fallback if A fails gate
4. CTE restructuring risk is real but mitigated by: (a) write separate dense_ranked + bm25_ranked CTEs, JOIN on lesson_id, (b) run smoke_recall_hybrid.py immediately after any CTE change

**IMPLEMENT guard order:**
1. Write CTE restructuring
2. Run smoke_recall_hybrid.py — must PASS before proceeding
3. Run pg_regress 16/16 — must PASS before bench
4. Run real-DB bench at `localhost:15432` (pgvector:pg17) with LME-S
5. Compare vs baseline (0.9334) — need ≥ +1pp AND p < 0.05
6. If FAIL but within 0.5pp: try disabling aux terms (A-pure variant of Alternative A)
7. If FAIL > 0.5pp gap: switch to Alternative C (BM25-gate conditional), run bench again

---

## 4. Evidence Grades (D79 §3.3)

| Claim | Grade |
|-------|-------|
| rrf_diag ORDER BY with k=60 regresses −22.44pp on LME-S | **STRONG** (real bench, N=500, p=1.0 direction confirmed) |
| Root cause: tied 0-score bm25_rank via ROW_NUMBER() | **STRONG** (analytical, confirmed by corpus stats: ~48 segs/session, k=60 >> N) |
| Proper sparse-safe RRF expected to recover regression | **PRELIMINARY** (no pgmnemo-specific bench yet; theoretical basis sound) |
| Adaptive k reduces rank distortion | **MODERATE** (mathematical property; regression magnitude unverified) |
| Alternative C (conditional fusion) preserves baseline | **STRONG** (degrades to fusion_score for zero-BM25 items = current behavior) |
| Real-DB bench required; simulation invalid proxy | **STRONG** (v0.6.1 confirmed: ρ(sim,real) for this fix-class ≈ −1.0) |

---

## 5. Pre-Tag Checklist Delta (v0.6.2 vs v0.6.1)

| Item | v0.6.1 status | v0.6.2 change |
|------|---------------|---------------|
| `extension/pgmnemo--0.6.1--0.6.2.sql` | n/a | NEW — upgrade migration |
| `extension/pgmnemo--0.6.2.sql` | n/a | NEW — fresh-install (squash all history) |
| `extension/pgmnemo.control default_version` | '0.6.1' | → '0.6.2' |
| `META.json version` | '0.6.1' | → '0.6.2' |
| `pgmnemo_mcp/pyproject.toml version` | '0.6.1' | → '0.6.2' |
| `benchmarks/gate/v0.6.2.json` | n/a | NEW — must include real-DB bench result |
| `CHANGELOG.md [0.6.2]` | n/a | NEW — note F1 finally ships; v0.6.1 deferral context |
| pg_regress fixtures with `UPDATE TO '0.6.1'` | 16 tests | must update version strings to '0.6.2' |
| `docs/release_notes/v0.6.2_telegram.md` | n/a | NEW (≤3500 chars) |

The F2/F3 items (as_of_ts pg_regress, stress_recall.sql) are already shipped — no changes needed.
