# ROADMAP REVIEW — pgmnemo 0.7.0

**Task:** PGMREL-070-ROADMAP_REVIEW  
**Date:** 2026-05-29  
**Owner:** Technical Lead (Karpov)  
**Inputs:** ROADMAP.md v2 (§v0.7.0), AGENCY_REQUIREMENTS_FOR_PGMNEMO.md (via PGMNEMO_RESPONSE_TO_AGENCY_REQUIREMENTS_2026-05-16.md + AGENCY_FOLLOWUP_RFC_2026-05-20.md), POSITIONING_REFRESH_PGMREL-070.md  
**Gate:** scope fits release class and budget

---

## 1. Pre-condition Assessment (Graph Eval)

ROADMAP.md v2 §v0.7.0 states three pre-conditions for graph eval release, **all failing** as of 2026-05-29:

| Pre-condition | Status |
|---|---|
| ≥1 external adopter has populated `mem_edge` in production | ❌ Not met |
| That adopter has reproducible bench showing graph traversal lifts their recall | ❌ Not met |
| Bench contributed back to pgmnemo suite as `benchmarks/graph_*/` | ❌ Not met |

**Conclusion:** ROADMAP fallback clause fires. Per ROADMAP.md: *"v0.7 skipped; advance to v0.7 = embeddings configurability (DIM-FLEX) or whatever bench-validated H-N is next on ICE."*

---

## 2. Candidate Scope: Production Maturity + Outcome Learning

**Theme:** Close Tier-1 footguns. Add outcome-feedback loop. Defer graph.

### 2.1 Scope Items

| Item | Description | ICE signal | Migration risk |
|---|---|---|---|
| **Tier-1 footgun closure** | Enumerate + fix known sharp edges in default `recall_lessons()` path: ambiguous-column class (v0.6.3 `#variable_conflict`), NULL embedding handling, empty-query fallback. Each footgun gets an explicit fix + regression test as P0 acceptance criteria. | High — Agency hit the ambiguous-column footgun at 0% hit rate in production. | None — fixes only; no signature change. |
| **`confidence` column on `mem_item`** | Migration `pgmnemo--0.6.3--0.7.0.sql` adds `confidence NUMERIC(4,3) NOT NULL DEFAULT 0.5 CHECK (confidence BETWEEN 0 AND 1)`. Exposed as named column in `recall_lessons()` output. Recall scoring weights `confidence` alongside `vec_score + bm25_score`. | Medium — closes "good write, wrong outcome" gap that provenance gate can't address. | Low — `ADD COLUMN … DEFAULT` is a metadata-only change on PG17; no table rewrite; < 1 ms on Agency's 2,054-row corpus. |
| **`reinforce(lesson_id, delta)` SP** | New SP: validates delta range (−1.0 to +1.0), updates `confidence = LEAST(1, GREATEST(0, confidence + delta))` atomically, stamps `reinforced_at`. Returns updated confidence. | High — addresses MENTOR_REVIEW risk #3 (H-2/H-3 production value unproven); `reinforce()` gives Agency the signal infrastructure to run their A/B. | None — additive SP. |
| **Ingestion guards on `pgmnemo.ingest()`** | Write-time validation layer: schema completeness check (role, topic non-empty), range checks (importance_factor 0–1), dedup fence (same `content_hash` within 60s → NOTICE, not silent INSERT). Ships as `NOTICE` in v0.7.0; promote to `ERROR` in v0.7.1. | Medium — Agency RFC Q2 (NULL embedding) + Q5 (dedup observability) surfaced this gap. Guards address both without breaking callers. | Low — NOTICE-first policy means no existing callers break. |
| **Recall scoring integration** | `recall_lessons()` inner score becomes: `final_score = 0.4×vec_score + 0.4×bm25_score + 0.1×importance_factor + 0.05×recency_factor + 0.05×confidence`. Default `confidence=0.5` flat must reproduce v0.6.3 LongMemEval recall@10 within ±0.001 (bench regression gate). | Medium — verifiable, additive, zero behavior change at default. | Low — flat default is algebraically equivalent to removing the term (0.05 × 0.5 = 0.025 constant, same across all rows). |

**Explicitly out of scope:**
- BFS graph-proximity mixin (v0.7.0 pre-conditions not met → v0.8.0 at earliest)
- DIM-FLEX / configurable vector dimension (no adopter pull; backlog)
- Auto-learning / self-supervised confidence update (ROADMAP "Will not happen" anti-promise)
- `reinforce_by_query()` overload (HIGH-risk UX complexity; backlog for v0.7.1)

---

## 3. Tradeoff Notes

### T1 — `reinforce()` caller burden vs. scope creep
**Problem:** Caller must hold `lesson_id` at outcome time. For agentic pipelines (fire-and-forget pattern), the lesson_id may not be in scope when the outcome is determined.  
**Tradeoff decision:** Ship `reinforce(lesson_id, delta)` only. Document the "store lesson_id in agent state" pattern in USAGE.md. `reinforce_by_query()` overload deferred to v0.7.1 — avoids vector-search-at-outcome-time complexity and the "what if multiple lessons match?" ambiguity from rushing it.  
**Cost of deferral:** Adopters with fire-and-forget loops cannot use `reinforce()` without architectural change. Acceptable for v0.7.0 because Agency's RESTORE-C1/C2 scaffolding already tracks `lesson_id` per run.

### T2 — Recall scoring weight rebalancing bench risk
**Problem:** Adding `confidence` to scoring formula changes weights of other components. At flat default this is algebraically neutral, but any CI that compares bench numbers literally may flag a delta.  
**Tradeoff decision:** Acceptance gate is strict: `confidence=0.5` default reproduces v0.6.3 LongMemEval recall@10 ±0.001. If it fails, the formula reverts to an additive post-filter (confidence adjusts sort order only, does not enter the score). This fallback preserves the feature without bench regression risk.  
**Cost of fallback:** Slight loss of theoretical purity (confidence as filter vs. as score component). Pragmatically identical for adopters.

### T3 — Ingestion guard break risk vs. too-lenient guards
**Problem:** Existing callers may rely on sloppy ingest (empty topic, duplicate content_hash). Guards that error immediately would break them.  
**Tradeoff decision:** NOTICE-first for v0.7.0; ERROR-first in v0.7.1. This gives one release cycle for adopters to clean up. Dedup fence (60s window) is conservative — NOTICE only if same `content_hash` appears within 60 seconds (idempotent retry scenario), not across all time.  
**Cost:** v0.7.0 guards are advisory, not enforcement. Ghost lessons can still be created. Ghost_count metric (Agency RFC Q4) is the monitoring signal.

### T4 — Footgun enumeration must happen before implementation lock
**Problem:** "Tier-1 footgun closure" is stated as a scope item but the canonical list is implicit (derived from v0.6.3 changelog, Agency RFC Q1–Q5, POSITIONING_REFRESH §2.3).  
**Tradeoff decision:** PLAN task (PGMREL-070-PLAN) must produce an explicit numbered footgun checklist before any implementation starts. Each footgun gets: description, reproduction case, fix, regression test. This is a hard dependency on implementation start.  
**Cost of skipping:** Risk of "we fixed footguns" narrative claim with incomplete enumeration. Prevents this.

### T5 — DIM-FLEX vs. proposed scope (ICE comparison)
DIM-FLEX was the ROADMAP fallback suggestion for when graph eval pre-conditions aren't met. Evaluating against proposed scope:

| Item | I | C | E | ICE |
|---|---|---|---|---|
| DIM-FLEX (configurable vector dim) | 3 (no adopter pull) | 5 | 7 | 105 |
| Tier-1 footgun closure | 9 (Agency at 0% hit rate) | 10 | 9 | 810 |
| `confidence` column + `reinforce()` | 8 (moat-deepening, addresses MENTOR R3) | 7 | 7 | 392 |
| Ingestion guards | 7 (Agency RFC Q2, Q5) | 8 | 8 | 448 |

**DIM-FLEX loses by >7× on ICE vs. any individual item in proposed scope.** DIM-FLEX remains backlog. Proposed theme wins.

---

## 4. Release Class Fit Assessment

| Criterion | Assessment |
|---|---|
| **Theme coherence** | PASS — all items cluster on "production maturity + feedback loop." No scatter. |
| **API stability** | PASS — `recall_lessons()` adds `confidence` column (named, backward-compatible). `reinforce()` is additive. `ingest()` gains NOTICE, no signature change. |
| **Migration complexity** | PASS — one `ADD COLUMN DEFAULT` migration. No table rewrite, no data migration, no orphan risk. |
| **Bench gate viability** | PASS — two gates: (1) `confidence=0.5` flat reproduces v0.6.3 recall@10 ±0.001; (2) footgun regression suite all pass. Both are deterministic and cheap to run. |
| **External adopter signal** | PASS — every item traces to Agency RFC evidence (Q1–Q7, ambiguous-column 0% hit rate, dedup observability, NULL embedding). This is adopter-pull, not spec-driven. |
| **No new services** | PASS — pure SQL, PL/pgSQL. No external service, no Python daemon, no background thread. |
| **Budget** | PASS — 4–5 SQL items, comparable scope to v0.4.1 (6 items). Estimated: ~$4–8 implementation + ~$2 bench runs. Within minor release budget. |

**Gate verdict: PASS — scope fits release class and budget.**

---

## 5. Roadmap Update Required

Per POSITIONING_REFRESH_PGMREL-070.md §4, the following ROADMAP.md §v0.7.0 changes are required before implementation lock:

1. Replace "Optional graph eval (only if adopter pulls)" with "Production maturity + outcome learning"
2. Document graph eval pre-conditions not met as of 2026-05-29; graph eval deferred to v0.8.0 or later pending ICE re-rank
3. List new acceptance gates:
   - `confidence=0.5` default reproduces v0.6.3 LongMemEval recall@10 ±0.001
   - Tier-1 footgun checklist (from PLAN task) — all items have regression test; all pass CI
   - `pgmnemo.stats()` includes `reinforcement_count BIGINT` (count of `reinforce()` calls since install)

**Owner of ROADMAP update:** Project Lead. Dependency: PLAN task must enumerate footguns first.

---

## 6. Next Steps

| Action | Owner | Dependency |
|---|---|---|
| PLAN task (PGMREL-070-PLAN): enumerate Tier-1 footguns, write migration spec, design `reinforce()` signature | chief_architect | This review |
| Update ROADMAP.md §v0.7.0 | Project Lead | PLAN task footgun list |
| Bench baseline snapshot: run v0.6.3 LongMemEval to establish the ±0.001 reference | research_supervisor | None |
| Update ADR_AGENT_MEMORY_PGMNEMO with `reinforce()` + `confidence` column in Agency write path | TL (Karpov) | PLAN task |
