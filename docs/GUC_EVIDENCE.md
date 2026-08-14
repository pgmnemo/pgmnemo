# pgmnemo GUC Defaults — Evidence Audit

**Version:** 0.17.0 · **Updated:** 2026-08-13  
**Purpose:** Every GUC default must be either evidence-backed (measurement named) or
explicitly labelled **UNPROVEN**. An extension whose defaults contradict its own
published evidence cannot carry the claim *"measured, not asserted."*

---

## Audit table

| GUC | Default | Evidence status | Source |
|-----|---------|-----------------|--------|
| `pgmnemo.gate_strict` | `enforce` | ✅ **PROVEN** — provenance requirement is load-bearing for compliance use-cases; no measurement needed (it is a policy knob, not a quality parameter) | Design intent: RFC-001 §provenance |
| `pgmnemo.include_unverified` | `off` | ✅ **PROVEN** — verified rows are the authoritative corpus; unverified are drafts/candidates. Default matches LongMemEval-S corpus (all rows verified). | Operational practice |
| `pgmnemo.track_recall_recency` | `on` | ⚠️ **UNPROVEN AT SCALE** — `mark_stale()` requires `last_recalled_at`; disabling prevents corpus curation. However, the claim "Zero performance impact on idle rows" (v0.17.0) was measured on a single-connection idle system only. **Measured under concurrent load (2026-08-14, 3 600-lesson corpus):** enabling recency stamping adds ~40 ms median overhead (10× above the 4 ms retrieval baseline) even with no contested locks, because `recall_hybrid` issues an inline UPDATE on every call. Under concurrent writers: blocks indefinitely when any writer holds a row lock on the returned lessons. Under DDL (`CREATE INDEX` without CONCURRENTLY): causes a relation-level lock convoy that blocks all subsequent callers regardless of this GUC. Setting `off` eliminates row-level tuple locks but does NOT eliminate the relation-level `RowExclusiveLock` — the UPDATE statement still runs and still takes that lock. **The `on` default is load-bearing for `mark_stale()` correctness; the cost is now documented. Operators on high-write corpora should benchmark before assuming the default is free.** See `benchmarks/results/PGMREL-0180-BENCH-PERF-HYBRID-UNDER-WRITE-LOAD.md`. | v0.9.5 design; measured 2026-08-14 (PGMREL-0180-BENCH) |
| `pgmnemo.ef_search` | `100` | ✅ **PROVEN** — `ef_search=100` is the pgvector recommended production value; HNSW recall degrades measurably below ~50 on 1K-row corpora. | pgvector project documentation |
| `pgmnemo.confidence_boost_weight` | `0.0` | ✅ **PROVEN** — shipped default is 0.0 (opt-in). Directional signal CONFIRMED as non-inert (2026-08-13 benchmark, n=971 pairs: Wilcoxon p=0.000511, rank-improve:worsen=147:9=16.3:1; McNemar p=0.1306 NS — insufficient power for recall@10 claim). Production installs may set 0.003 via ALTER DATABASE; see `docs/CONFIDENCE_BOOST_GUIDE.md`. Recall@10 gate pending: requires ≥305 signal lessons with ≥5 outcomes (current: ~171). Pre-registered gate thresholds: r_pb≥0.200 ✅ (current r_pb=0.577 from n=4 533 run-level correlation), chi²(df=3)=1240 p<<0.0001 ✅; McNemar-powered benchmark (22 discordant pairs) ❌ not yet reached. | `benchmarks/METRICS_BY_VERSION.md` (v0.13.0 row); 2026-08-13 rank-comparison benchmark (971 pairs) |
| `pgmnemo.recency_weight` | `0.05` | ✅ **PROVEN** — changed from 0.08 → 0.05 per internal ablation (H-06 grid search). Grid run on LoCoMo temporal category; 0.05 reduced temporal drift vs 0.08. | `benchmarks/h06_grid_search/` |
| `pgmnemo.importance_weight` | `0.15` | ⚠️ **UNPROVEN** — value chosen as a reasonable prior; no ablation systematically compared 0.15 vs alternatives. Within the 5-component scoring formula the effect is bounded. Adopt this value cautiously; opt-in adjustment: `SET pgmnemo.importance_weight = 0.0` to disable. |  |
| `pgmnemo.temporal_boost` | `1.0` | ⚠️ **UNPROVEN** — 1.0 (identity multiplier) is a safe neutral value. H-06 identified 10.0 as optimal for the LoCoMo temporal category but that is category-specific and not generalizable without broader measurement. 1.0 is the least-harm choice. |  |
| `pgmnemo.graph_proximity_weight` | `0.0` | ✅ **PROVEN** — the OPT-IN change (0.2 → 0.0) was made in **v0.10.1** (#87/#88: graph_walk OPT-IN ablation). In v0.17.0 three overloads were found to still carry 0.2 as their COALESCE fallback: `navigate_locate` (5-param) and the two most-recent `recall_hybrid` overloads; the `recall_hybrid` overloads additionally had 0.2 on the EXCEPTION path. All are reconciled in v0.17.0. All code paths now agree at 0.0. Rationale: POSITIONING.md states "we have no published benchmark showing graph-augmented recall outperforms hybrid (vector + BM25) alone." Restore graph weighting: `SET pgmnemo.graph_proximity_weight = 0.2`. | `pgmnemo--0.10.0--0.10.1.sql` preamble (Fix 5 comment); `POSITIONING.md §"The graph layer does not improve recall"` |
| `pgmnemo.bm25_budget_ms` | `250` | ✅ **PROVEN** — 250 ms is the P99 BM25 query latency observed on a 6 000-row corpus. A timeout below this risks false degradation to vector-only; a timeout above this allows BM25 to monopolise the query budget. | Operational measurement |
| `pgmnemo.max_query_text_chars` | `2000` | ⚠️ **UNPROVEN** — 2000 chars was chosen to cap BM25 GIN index scan cost. No systematic experiment measured recall degradation beyond 2000 chars vs at 2000 chars. Code default verified at lines matching `COALESCE.*max_query_text_chars.*2000` in the flat-install SQL. |  |
| `pgmnemo.disable_hybrid` | `false` | ✅ **PROVEN** — v0.4.0 benchmark: hybrid enabled LoCoMo session recall@10 0.7951→0.8409 (+4.58pp, p=0.0156). Hybrid is the proven-better default. | `benchmarks/locomo/results/v0.4.0_session_hybrid_20260515/` |
| `pgmnemo.selective_recall` (per-call `p_min_score`) | `NULL` (= **OFF**) | ✅ **PROVEN** — mem_ab_v3 live-fleet experiment: arm C (selective + typed recall) vs arm A (no memory): χ²=0.001, p=0.98 (Bonferroni p=1.000). Arm C indistinguishable from no memory. Selectivity erased the entire benefit of memory. Score-gated filtering must be opt-in, not default. Restore score-gate: pass `p_min_score := 0.3` to `recall_hybrid()` / `recall_lessons()`. | `benchmarks/mem_ab_v3/` — see §Experiment details below; reproduce: `python3 analyze.py` |
| `pgmnemo.confidence_mode` | `'posterior'` | ⚠️ **UNPROVEN** — Beta posterior is principled but no head-to-head comparison vs a simpler EMA was run. Code value: `'posterior'` (verified in `reinforce()` COMMENT: "Mode pgmnemo.confidence_mode: 'posterior' (default…)"). |  |
| `pgmnemo.confidence_prior_alpha` | `1.0` | ⚠️ **UNPROVEN** — Beta(1,1) = uniform (non-informative) prior. Principled choice but no ablation over prior parameter space. Code default verified at `reinforce()` COMMENT: "Prior: pgmnemo.confidence_prior_alpha/beta (default 1.0/1.0 = uniform)". |  |
| `pgmnemo.confidence_prior_beta` | `1.0` | ⚠️ **UNPROVEN** — same as `confidence_prior_alpha`. Code default 1.0 verified same source. |  |
| `pgmnemo.reinforce_success_delta` | `+0.02` | ✅ **PROVEN** — changed from +0.10 → +0.02 in v0.9.3. Base-rate-adjusted to prevent confidence saturation on corpora where most outcomes are successes. | v0.9.3 changelog |
| `pgmnemo.reinforce_fail_delta` | `-0.12` | ✅ **PROVEN** — changed from -0.15 → -0.12 in v0.9.3. Symmetric adjustment to avoid confidence floor erosion on mixed corpora. | v0.9.3 changelog |
| `pgmnemo.as_of_timestamp` | `NULL` (= now) | ✅ **PROVEN** — NULL means "current time", which is the only sensible default for a temporal GUC. | Logic |
| `pgmnemo.tenant_id` | `NULL` (= no filter) | ✅ **PROVEN** — NULL means "all projects visible to session", which is the safe default for a single-tenant install. | Design intent |
| `pgmnemo.test_project_floor` | `0` (= disabled) | ✅ **PROVEN** — 0 disables the guard; callers opt in. No production install should have this enabled by default. | RFC-001 testing guidance |

---

## Experiment details

### mem_ab_v3: three-arm live-fleet task-success experiment (2026-08)

**Full protocol and reproducible numbers: [docs/EVIDENCE.md](EVIDENCE.md)**

**Dataset:** `benchmarks/mem_ab_v3/runs.csv` — de-identified export of real production
runs (one row per run: arm, week, success, turns, cost, retrieved count, mean cosine).
Reproducible with `cd benchmarks/mem_ab_v3 && python3 analyze.py` (stdlib only).

**Arms:** A = recall off (no-memory baseline), B = recall always on (full recall),
C = selective + typed recall. 150 / 148 / 137 completed runs respectively.

**Result relevant to `p_min_score` default:** A vs C success rate:
χ²=0.001, p=0.98 (Bonferroni-adjusted p=1.000). Arm C indistinguishable from
arm A — selective recall erased the benefit of memory entirely.

**Conclusion:** `p_min_score` must default to NULL (no filtering). Score-gated
filtering is an opt-in escape hatch for latency-sensitive contexts; at the default
it removes enough qualifying memories that the residual provides no net benefit.

---

## Restore commands for v0.17.0 behaviour breaks

### `graph_proximity_weight` (effective default 0.2 → 0.0 for `recall_hybrid()` and `navigate_locate()` direct callers)

The OPT-IN change from 0.2 → 0.0 was made in v0.10.1 for most code paths. In v0.17.0,
three overloads were found to still carry 0.2 as their COALESCE fallback: `navigate_locate`
(5-param) and the two most-recent `recall_hybrid` overloads (10-param and 11-param); the two
`recall_hybrid` overloads additionally had 0.2 on the EXCEPTION path. If you called any of
these directly and relied on the graph proximity term being active, restore it:

```sql
-- Restore graph proximity contribution for this session:
SET pgmnemo.graph_proximity_weight = 0.2;

-- Or permanently via postgresql.conf:
-- pgmnemo.graph_proximity_weight = 0.2
```

**When to restore:** only if you have a populated `mem_edge` table with causal or
temporal edges AND have measured that graph augmentation improves your retrieval.
If `mem_edge` is empty the graph term is 0 regardless of the weight setting, so
restoring the old default has no effect.

---

*This file is the single source of truth for GUC default evidence. When a new GUC
is added to pgmnemo, its default must be documented here before the release ships.*
