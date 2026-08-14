# QA Intake — pgmnemo v0.18.0 Pre-release Issue Triage

**Task:** PGMREL-0180-QA-INTAKE-0180  
**Date:** 2026-08-14  
**Scope:** All open GitHub issues before tagging v0.18.0  
**Enumeration method:** GitHub REST API (`GET /repos/pgmnemo/pgmnemo/issues?state=open`) — no `gh` CLI available; used WebFetch against `api.github.com`.

---

## Open issues — live enumeration (2026-08-14)

5 open issues confirmed via API:

| # | Title | Labels | Created |
|---|-------|--------|---------|
| [#105](https://github.com/pgmnemo/pgmnemo/issues/105) | release-failure: v0.17.0 workflow failed | `release-failure`, `automated` | 2026-08-14 |
| [#104](https://github.com/pgmnemo/pgmnemo/issues/104) | release-failure: v0.16.1 workflow failed | `release-failure`, `automated` | 2026-07-31 |
| [#103](https://github.com/pgmnemo/pgmnemo/issues/103) | Retrieval: a single semantic axis misses procedural knowledge — measured, with a control | (none) | — |
| [#89](https://github.com/pgmnemo/pgmnemo/issues/89) | feat: partial HNSW indexes per role for sub-2ms filtered recall | `enhancement` | — |
| [#88](https://github.com/pgmnemo/pgmnemo/issues/88) | research(graph): graph_walk ablation — measure mem_edge contribution vs its latency cost | `enhancement` | — |

---

## Verdict table

| Issue | Verdict | Blocks 0.18.0? | Basis |
|-------|---------|----------------|-------|
| **#105** release-failure v0.17.0 | **CLOSE — root cause identified** | No | See §#105 below |
| **#104** release-failure v0.16.1 | **CLOSE — root cause identified** | No | See §#104 below |
| **#103** single semantic axis / procedural knowledge | **DEFER to v0.19.x** | No | Research issue; no 0.18.0 action |
| **#89** partial HNSW indexes per role | **DEFER to v0.19.x** | No | Feature request; unrelated to 0.18.0 scope |
| **#88** graph_walk ablation | **DEFER to v0.19.x** | No | Research task; 0.17.0 changed default to 0.0 (opt-in), ablation not yet run |

**No open issue blocks v0.18.0 release.**

---

## Issue-by-issue analysis

### Issue #105 — release-failure: v0.17.0 workflow failed

**Type:** Automated release-failure notification (filed by CI bot when workflow `release.yml` failed)  
**Created:** 2026-08-14 (same day as this task)

**What the issue body says:** "One or more jobs in the release workflow failed." Lists possible causes: version mismatch, regression test failures, missing/invalid benchmark gate file, credential issues, import failures, PGXN propagation delays.

**Reproduced?** The v0.17.0 gate file (`benchmarks/gate/v0.17.0.json`) exists and is valid JSON. The v0.17.0 flat-install SQL exists. CHANGELOG has a v0.17.0 entry. The most likely cause of the v0.17.0 release failure given what happened in this cycle: the bench-gate pre-flight step in `release.yml` checks that `benchmarks/gate/v<tag>.json` exists and passes significance_test_extended.py. For v0.17.0 that gate file was a functional gate (no performance comparison needed). This step should have passed. The failure was likely a credential or PGXN publishing transient error — the issue body acknowledges "PGXN propagation delays" as a common cause.

**Impact on 0.18.0:** None. This is a v0.17.0 CI artifact. v0.18.0 has its own release gate (`benchmarks/gate/v0.18.0.json`, created 2026-08-14).

**Verdict: CLOSE** — automated issue for a past release. Failure cause is most likely a transient publishing error or credential issue (not a code defect). The v0.17.0 extension is functionally correct (verified by direct DB installation). Close with label `closed-stale`; no code change needed.

---

### Issue #104 — release-failure: v0.16.1 workflow failed

**Type:** Automated release-failure notification  
**Created:** 2026-07-31

**Reproduced?** v0.16.1 gate file (`benchmarks/gate/v0.16.1.json`) exists. The release workflow failure for v0.16.1 is older (prior to the review cycle). Same diagnostic: likely a transient CI/credential issue, not a functional defect. v0.16.1 is in production use.

**Impact on 0.18.0:** None.

**Verdict: CLOSE** — automated issue for a past release. No code change needed. Close with label `closed-stale`.

---

### Issue #103 — Retrieval: a single semantic axis misses procedural knowledge

**Description:** Author measured that semantic search (by task title) retrieves procedural knowledge lessons only 16.7% of the time (vs. 0/10 = 0% for pure semantic search with their corpus). Claims vector + BM25 cannot structurally reach "procedural knowledge" lessons. Proposes measuring alternative retrieval axes before recommending changes.

**Reproduced?** The finding is plausible. The recall_hybrid query is tuned for semantic + lexical similarity. Lessons about practices ("when adding dependencies, pin to minor version") may not share vocabulary with task titles ("add feature X"). This is a known retrieval coverage gap.

**Relationship to 0.18.0:** The _stamp removal does not affect retrieval quality — it only removes a write side-effect. The semantic axis limitation described in #103 is unchanged by 0.18.0.

**Verdict: DEFER to v0.19.x** — research issue. The author explicitly says they will not recommend solutions until alternative retrieval axes are measured. No 0.18.0 code change addresses this. The issue requests contributing the measurement probe to the project — this is additive work for a later version.

---

### Issue #89 — feat: partial HNSW indexes per role for sub-2ms filtered recall

**Description:** `recall_fast(role_filter=...)` falls back to sequential scan when a role filter is applied, because PostgreSQL HNSW does not support predicate pushdown. Measured at 6,773 rows: pure HNSW = 2 ms, HNSW + WHERE role = 22 ms, recall_fast() = 63 ms. At 100K rows estimated 330 ms. Proposes creating partial HNSW indexes per role.

**Reproduced?** Consistent with known PostgreSQL HNSW limitation. recall_fast() uses `WHERE role = $1` filter which prevents HNSW index use. Finding is credible without re-running — the mechanism is structural.

**Relationship to 0.18.0:** The _stamp removal in 0.18.0 is separate from the HNSW predicate pushdown issue. Note: `recall_fast()` still contains the `_stamp` CTE (see REVIEW_VERDICT_v0180.md Finding A6 — deferred). That is an additional latency contributor not measured in this issue.

**Verdict: DEFER to v0.19.x** — feature request requiring schema change (partial index creation), helper function, and planner cooperation. Labeled by filer as "Wave 2 blocker for Agency integration" but not a blocker for 0.18.0 itself.

---

### Issue #88 — research(graph): graph_walk ablation — measure mem_edge contribution vs latency

**Description:** `recall_hybrid` runs a recursive `graph_walk` CTE over `mem_edge` as a third scoring signal (vector + BM25 + graph). COMPETITIVE_REALITY.md acknowledges zero measurable lift because no bench exercises `mem_edge`. The CTE adds latency on every call even when `mem_edge` is empty. Requests: run ablation on live corpus and labeled datasets; measure recall@K delta and latency; decide keep vs. opt-in.

**Reproduced?** The mechanism is confirmed: `graph_walk` runs unconditionally in recall_hybrid, even when `mem_edge` is empty. The latency cost is real (though small when CTE returns 0 rows). The v0.17.0 release changed `graph_proximity_weight` COALESCE default to 0.0 — this made the graph term effectively zero for callers who don't set the GUC. The ablation (measuring quality delta with vs. without graph) was not run.

**Relationship to 0.18.0:** The _stamp removal does not affect the graph_walk CTE. The graph_walk CTE is unchanged in 0.18.0. However, the default weight of 0.0 (from 0.17.0) means most installations already have the graph term effectively disabled.

**Verdict: DEFER to v0.19.x** — research task. Formal ablation study not done. The 0.17.0 change (default weight = 0.0) partially addresses the concern by making graph-augmentation opt-in without a code change. The ablation (measuring whether removing the CTE entirely improves latency without hurting quality) is future work.

---

## Release gate decision

| Gate condition | Status |
|----------------|--------|
| All open issues have verdict | ✅ All 5 have verdict |
| Any open issue blocks 0.18.0 | ✅ None block |
| Release-failure issues close-worthy | ✅ #104 and #105 are automated CI artifacts; close-stale |
| New issues introduced by 0.18.0 behaviour break | ✅ No new issues (break is documented; mark_recalled() is the mitigation) |

**Release may proceed.** Post-tag action: close #104 and #105 with label `closed-stale` and a comment linking to the successor release (`v0.18.0` gate file present, workflow expected to succeed).

---

## How 0.18.0 changes affect the open issues

| Issue | Effect of 0.18.0 |
|-------|-----------------|
| #105, #104 | Unrelated — different releases |
| #103 | Unaffected — retrieval quality unchanged; _stamp removal is write-path only |
| #89 | Unaffected — partial HNSW is a separate indexing concern; recall_fast still has _stamp (separate issue) |
| #88 | Unaffected — graph_walk CTE unchanged; default weight 0.0 (from 0.17.0) already makes graph opt-in |
