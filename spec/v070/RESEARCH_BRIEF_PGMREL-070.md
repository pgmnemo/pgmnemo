---
date: 2026-05-29
agent: research_supervisor (id=85)
task_id: PGMREL-070-RESEARCH
status: complete
release_key: pgmnemo-release-0.7.0
---

# Research Brief — pgmnemo 0.7.0
## Tier-1 Footguns + Outcome-Learning + Ingestion Guards

---

## 1. Executive Summary

v0.7.0 replaces the conditional graph-eval theme (pre-conditions unmet) with **production
maturity + outcome-learning**. All three pre-conditions for graph eval fail as of 2026-05-29
(source: ROADMAP_REVIEW_PGMREL-070.md §1). The replacement scope — Tier-1 footgun closure,
`confidence` column, `reinforce()` SP, ingestion guards — scores ICE 810/448/392 vs. DIM-FLEX
at 105; proposed theme wins by ≥7× (source: ROADMAP_REVIEW_PGMREL-070.md §3 T5).

All five scope items trace directly to adopter evidence: Agency RFC Q1–Q7, the
AmbiguousColumn 0%-hit-rate production incident (resolved in v0.6.3), and the
MENTOR_REVIEW risk-3 gap (no production-value evidence for H-2/H-3).

**Bench baseline entering v0.7.0:**

| Metric | Value | Source |
|--------|-------|--------|
| LongMemEval-S recall@10 (bge-m3 1024d, N=500) | **0.9604** | CHANGELOG v0.6.3; benchmarks/gate/v0.6.3.json |
| LoCoMo session recall@10 | **≥ 0.7994** | RESEARCH_V061.md §0 |
| pg_regress tests passing | **18/18** | CHANGELOG v0.6.3 |
| Agency active corpus | **2,054 lessons** (793 ghost = 38.6%) | AGENCY_FOLLOWUP_RFC_2026-05-20.md Q4 |

Evidence grade for recall@10: **STRONG** (empirical real-DB bench, significance tested).

---

## 2. Scope Items — Technical Research

### 2.1 Tier-1 Footgun Closure

**Known footguns enumerated from prior reports:**

| # | Footgun | Root cause | Fix shipped? | v0.7.0 action |
|---|---------|------------|-------------|----------------|
| F-1 | `AmbiguousColumn: role` in `recall_lessons()` and `recall_hybrid()` | PL/pgSQL OUT variable `role TEXT` in RETURNS TABLE shadows CTE column even when table-qualified | **Yes — v0.6.3** (`#variable_conflict use_column`) | Regression test `role_no_ambiguity.sql` already in CI (18/18). PLAN must verify no residual scope. |
| F-2 | NULL embedding → silent drop from HNSW index, no warning | `pgmnemo.ingest()` accepts NULL embedding without NOTICE; callers get no signal that lesson is BM25-only | **No** | Add `RAISE NOTICE 'pgmnemo: embedding is NULL — lesson %L will not participate in vector recall', lesson_id` in `ingest()` (aligns with Agency RFC Q2). Ingestion-guards feature (§2.4) covers this. |
| F-3 | Empty `query_text` string → silent hybrid → vector-only fallback | `recall_lessons()` silently falls back to vector-only when `trim(query_text) = ''`. No log; adopter thinks hybrid ran. | **No** | Document explicitly + add `RAISE DEBUG` or `RAISE NOTICE` when fallback fires. |
| F-4 | `hybrid_enabled` misread in `recall_diagnostics()` | Column reflects GUC-only; no corpus-size signal. Adopters misread as "hybrid is working on my corpus." | **No** | RESEARCH_V063.md R3 docs shipped (R3 clause in USAGE.md), but no runtime signal in `recall_diagnostics()` itself. Add `bm25_coverage_pct NUMERIC` column to `recall_diagnostics()`. |
| F-5 | Default `include_unverified=off` causes 0% recall on ghost-lesson corpora | New adopter inserts via raw INSERT (pre-ingest() migration); all rows are ghost → recall returns empty → appears broken. | **No** | `pgmnemo.stats()` `ghost_count` added in v0.6.0; but no warning at INSTALL time if `ghost_count = total_lessons`. |

**Evidence grade:** F-1 STRONG (incident confirmed; fix verified). F-2 through F-5 MODERATE
(derived from Agency RFC Q1–Q5 + RESEARCH_V063.md R2/R3 + CHANGELOG audit).

**Sources:** RESEARCH_V063.md (R1–R4), AGENCY_FOLLOWUP_RFC_2026-05-20.md (Q1–Q5),
CHANGELOG v0.6.3, POSITIONING_REFRESH_PGMREL-070.md §2.3.

> **PLAN task dependency:** PLAN must produce a canonical numbered footgun checklist
> (description, reproduction case, fix, regression test) before implementation lock.
> This research identifies 5 candidates; the canonical list may be longer.

### 2.2 `confidence` Column and Recall Scoring Integration

**Proposed schema (from ROADMAP_REVIEW_PGMREL-070.md §2.1):**

```sql
-- Migration: pgmnemo--0.6.3--0.7.0.sql
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN confidence NUMERIC(4,3) NOT NULL DEFAULT 0.5
        CHECK (confidence BETWEEN 0 AND 1);
```

**Migration risk:** ADD COLUMN with DEFAULT on PG17 is a metadata-only operation on
heap tables — no table rewrite, no lock beyond `ACCESS EXCLUSIVE` for catalog update,
sub-millisecond on Agency's 2,054-row corpus. (Source: PostgreSQL 17 documentation,
ALTER TABLE ADD COLUMN behavior; independent of pgmnemo.)

**Proposed scoring formula:**

```
final_score = 0.40 × vec_score
            + 0.40 × bm25_score   (sparse-safe RRF components)
            + 0.10 × importance_factor
            + 0.05 × recency_factor
            + 0.05 × confidence
```

**Algebraic neutrality check at default:**
- All rows: `confidence = 0.5` → `0.05 × 0.5 = 0.025` constant added to every row.
- Adding a constant to all scores does not change relative ordering.
- Gate: `confidence=0.5` flat MUST reproduce v0.6.3 LongMemEval-S recall@10 within ±0.001.
- Analytical verdict: **PASS** (constant shift is rank-invariant). Bench must confirm.

**Fallback if bench gate fails:** Confidence as post-filter sort modifier only
(does not enter `ORDER BY` formula; adjusts output sort within ties). This
preserves the feature without scoring regression risk.

**Evidence grade:** Algebraic neutrality claim — **PRELIMINARY** (analytical; bench
confirmation required). Migration risk assessment — **STRONG** (per PG17 docs).

**Sources:** ROADMAP_REVIEW_PGMREL-070.md §2.1 T2, POSITIONING_REFRESH_PGMREL-070.md
§2.3, RESEARCH_V061.md §0 (baseline metrics).

### 2.3 `reinforce(lesson_id, delta)` Stored Procedure

**Proposed signature:**

```sql
CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id   BIGINT,
    p_delta       NUMERIC   -- range: −1.0 to +1.0
) RETURNS NUMERIC           -- updated confidence value
LANGUAGE plpgsql AS $$
DECLARE
    _new_confidence NUMERIC(4,3);
BEGIN
    IF p_delta NOT BETWEEN -1.0 AND 1.0 THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: delta must be in [-1, 1], got %', p_delta;
    END IF;
    UPDATE pgmnemo.agent_lesson
    SET    confidence      = LEAST(1.0, GREATEST(0.0, confidence + p_delta)),
           reinforced_at   = NOW()
    WHERE  id              = p_lesson_id
    AND    is_active        = TRUE
    RETURNING confidence INTO _new_confidence;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found or inactive', p_lesson_id;
    END IF;
    RETURN _new_confidence;
END;
$$;
```

**Key design decisions baked in:**
- Atomic: single UPDATE, no read-modify-write race.
- Clamped: confidence stays within [0, 1].
- Explicit: caller signals outcome; no background inference.
- `reinforced_at` column must be added alongside `confidence` in migration.

**Caller burden (fire-and-forget agents):**
Per ROADMAP_REVIEW_PGMREL-070.md §3 T1: `reinforce_by_query()` overload deferred
to v0.7.1. Reason: vector-search-at-outcome-time adds semantic ambiguity (what if
multiple lessons match the query at outcome time?). Agency's RESTORE-C1/C2
scaffolding already tracks `lesson_id` per run, so the burden is acceptable for
the primary adopter. Cookbook pattern ("store lesson_id in agent state") to be
documented in USAGE.md.

**`pgmnemo.stats()` addition required:** Per ROADMAP_REVIEW_PGMREL-070.md §5,
add `reinforcement_count BIGINT` (total `reinforce()` calls since install) to
`pgmnemo.stats()`. Implement via INSERT trigger on `reinforced_at` update or a
dedicated counter table.

**Evidence grade:** Signature design — **AUTHOR ESTIMATE** (no prior art in pgmnemo;
derived from PostgreSQL SP best practices + Agency RESTORE-C1/C2 pattern).
`reinforce_by_query()` deferral rationale — **MODERATE** (structural argument
from ROADMAP_REVIEW §3 T1; no user feedback data yet).

**Sources:** ROADMAP_REVIEW_PGMREL-070.md §2.1 + §3 T1, POSITIONING_REFRESH_PGMREL-070.md
§2.3 + §2.5, MENTOR_REVIEW_2026-05-19.md (risk-3: RESTORE-C1/C2 blocked).

### 2.4 Ingestion Guards on `pgmnemo.ingest()`

**Targeted gaps from Agency RFC:**

| Guard type | Target | Agency RFC reference | Severity in v0.7.0 |
|------------|--------|---------------------|---------------------|
| Schema completeness | `role` + `topic` non-empty | Q1 (NULL embedding corollary) | NOTICE |
| Range check | `importance_factor` ∈ [0, 1] | Q1 | NOTICE |
| NULL embedding | `p_embedding IS NULL` → NOTICE with lesson_id | Q2 | NOTICE |
| Dedup fence | Same `content_hash` within 60s → NOTICE with existing lesson_id | Q5 | NOTICE |

**Severity policy: NOTICE-first in v0.7.0; promote to ERROR in v0.7.1.**

Rationale (from ROADMAP_REVIEW_PGMREL-070.md §3 T3): Agency corpus has 793 ghost lessons
(38.6%) — some likely inserted via sloppy raw-INSERT paths. Immediate ERROR would break
callers relying on lenient ingest. One-release advisory period allows monitoring via
`pgmnemo.stats().ghost_count` before enforcement.

**Dedup fence semantics (60s window):** Conservative. The 60-second window catches
idempotent retries (network timeout + retry within the same agent run) without blocking
intentional lesson re-writes after the window. Callers that need longer idempotency
must implement their own `content_hash` check before calling `ingest()`.

**Evidence grade:** Guard targets — **STRONG** (directly from Agency RFC Q2 + Q5,
confirmed production incidents). 60s window — **AUTHOR ESTIMATE** (no data on retry
timing distribution; conservative default).

**Sources:** AGENCY_FOLLOWUP_RFC_2026-05-20.md Q2 + Q5, ROADMAP_REVIEW_PGMREL-070.md
§2.1 (item row "Ingestion guards") + §3 T3, POSITIONING_REFRESH_PGMREL-070.md §2.5.

---

## 3. Market Research

### 3.1 Competitive Landscape as of 2026-05-29

| Competitor | Status | Hybrid recall | Provenance gate | Outcome learning | Deps |
|-----------|--------|--------------|-----------------|-----------------|------|
| **pgmnemo v0.6.3** | Private beta, 1 adopter | 0.9604 (LME-S) | ✅ native | ❌ none | 0 (Postgres + pgvector) |
| **Constructive AgenticDB** | Series A, launched 2026-04-28 | ~0.72–0.75 (analytical, linear fusion) | ❌ none | ❌ none | 5 services |
| **Mem0** | Funded, general availability | Unknown LME-S | ❌ none | ⚠️ LLM-based extraction | API call |
| **Zep** | Funded, general availability | Unknown LME-S | ❌ none | ⚠️ community clustering | API call |
| **MAGMA** (arXiv) | Research only | Unknown | ❌ none | ❌ | N/A |

*Constructive AgenticDB hybrid recall estimate based on MTEB proxy (nomic-embed-text NDCG@10 =
54.89 vs bge-m3 54.9) + 5-service stack with BM25 + tsvector + pg_trgm unified search.
pgmnemo real-DB bench (LongMemEval-S, N=500) is not directly comparable to Constructive's
analytical estimate — different datasets and corpora.*

Source: VENDOR_BENCHMARK_VS_AGENTIC_DB_2026-05-09.md §1, §4; WG_COMPETITOR_CAPABILITY_MATRIX.md.

**pgmnemo unique leads (no competitor has these):**
- Technique 22: Provenance/trust-gated retrieval (✅ pgmnemo | ❌ all others)
- Technique 24: Importance-signal in ranking (✅ pgmnemo | ❌ all others)

Source: WG_COMPETITOR_CAPABILITY_MATRIX.md rows 22, 24.

**Moat compression timeline (from MENTOR_REVIEW_2026-05-19.md §Top-3 risks, risk 2):**
Constructive could add RLS/provenance enforcement within 12 months (Series A capital,
fast-shipping cadence: launched full product in ≤3 weeks from repo creation 2026-04-28).
pgmnemo moat window: estimated 18–24 months for provenance gate alone. Adding
`reinforce()` + confidence column deepens the moat by adding the feedback-loop story
that is structurally absent from Constructive's SQL-schema-only approach.

### 3.2 Does Outcome-Learning Differentiate?

**Evidence supporting differentiation:**
- No competitor in the matrix has explicit outcome-reinforcement signal on stored memory items.
- `reinforce()` fills the MENTOR_REVIEW risk-3 gap: H-2/H-3 (quality-score lift from
  memory context) will be empirically measurable once `reinforce()` is wired into
  Agency's RESTORE-C1/C2 scaffold. (MENTOR_REVIEW_2026-05-19.md §must-ship #2.)
- Anti-promise #4 (reinforce is explicit, not auto) prevents over-claiming while
  preserving the narrative value. (POSITIONING_REFRESH_PGMREL-070.md §2.5.)

**Evidence against differentiation:**
- LLM-based approaches (Mem0, MAGMA) infer memory quality from conversation coherence
  automatically — no caller signal required. This is operationally simpler for adopters
  who don't want to instrument outcome signals.
- "Outcome learning" as a label could be conflated with ML/neural feedback loops
  (POSITIONING_REFRESH_PGMREL-070.md §3.3 risk 3) — anti-promise #4 must appear
  in README §Limitations before tag.
- For adopters with fire-and-forget agent loops, `reinforce(lesson_id)` is a
  non-trivial adoption cost (must hold lesson_id at outcome time).

**Verdict:** `reinforce()` differentiates from *all current Postgres-native memory* competitors
(Constructive AgenticDB has no equivalent). It lags behind LLM-based competitors on *automation*
but wins on *auditability* (explicit signal, queryable `confidence` column, no external service).
Evidence grade: **MODERATE** (structural argument; no real-user adoption data yet for `reinforce()`).

---

## 4. Decision Questions Answered

> *Gates requirement: decision questions answered.*

### DQ-1: Confidence scoring — formula component or post-filter?

**Answer: Formula component (0.05 weight), with fallback to post-filter if bench gate fails.**

Rationale: Formula integration (0.05 weight) is algebraically neutral at `confidence=0.5`
flat default — it adds a constant 0.025 to all scores, which is rank-invariant. The bench
gate (`confidence=0.5` default must reproduce v0.6.3 recall@10 ±0.001) is cheap and
deterministic. If it fails, promote confidence to a post-filter sort modifier within the
same release (no API change). Decision owner: chief_architect.
Source: ROADMAP_REVIEW_PGMREL-070.md §2.1 (recall scoring), §3 T2.

### DQ-2: Ingestion guards severity — NOTICE-first or ERROR-first?

**Answer: NOTICE-first in v0.7.0; ERROR-first in v0.7.1.**

Rationale: Agency corpus has 793 ghost lessons (38.6%) from pre-ingest() raw-INSERT paths.
Immediate ERROR breaks callers. One release advisory period allows `ghost_count` monitoring
before enforcement. Dedup fence is a 60s window (idempotent retry scope) — conservative.
Decision owner: chief_architect. Source: ROADMAP_REVIEW_PGMREL-070.md §3 T3,
AGENCY_FOLLOWUP_RFC_2026-05-20.md Q5.

### DQ-3: `reinforce()` scope — lesson_id only or also `reinforce_by_query()`?

**Answer: `reinforce(lesson_id, delta)` only in v0.7.0. `reinforce_by_query()` deferred to v0.7.1.**

Rationale: Vector-search-at-outcome-time adds ambiguity (multiple lessons may match the
outcome query). Agency's RESTORE-C1/C2 scaffolding tracks lesson_id per run, making the
burden acceptable for the primary adopter. Cookbook pattern ("store lesson_id in agent
state") documented in USAGE.md is sufficient for v0.7.0. Decision owner: chief_architect.
Source: ROADMAP_REVIEW_PGMREL-070.md §3 T1.

### DQ-4: What are the Tier-1 footguns? Is the list complete?

**Answer: 5 candidates identified (§2.1 above). List is NOT guaranteed complete.**

F-1 (AmbiguousColumn) is confirmed and fixed. F-2 through F-5 are derived from Agency RFC
and changelog audit. The PLAN task (PGMREL-070-PLAN) MUST produce the canonical numbered
list with reproduction cases before implementation lock. Decision owner: chief_architect.
Source: §2.1 this document; RESEARCH_V063.md R1–R4; AGENCY_FOLLOWUP_RFC_2026-05-20.md.

### DQ-5: What is the bench regression gate for v0.7.0?

**Answer: Two gates.**

1. **`confidence=0.5` flat reproduces v0.6.3 LongMemEval-S recall@10 within ±0.001**
   (0.9604 ± 0.001 = [0.9594, 0.9614]). If gate fails → fallback to post-filter approach.
2. **Tier-1 footgun regression suite: all new tests pass in CI.**
   Each footgun from the PLAN-task canonical list must have a pg_regress or pytest test.

Owner: research_supervisor (bench snapshot) + chief_architect (implementation).
Source: ROADMAP_REVIEW_PGMREL-070.md §4 bench gate viability.

### DQ-6: Is hypergraph deferred appropriately?

**Answer: Yes. All three pre-conditions fail; deferral is warranted.**

Pre-conditions per ROADMAP.md v2: (1) ≥1 external adopter with `mem_edge` in production —
❌; (2) adopter bench showing graph traversal lifts recall — ❌; (3) bench contributed back
as `benchmarks/graph_*/` — ❌. Per ROADMAP fallback clause: advance to next ICE-ranked
hypothesis. ICE analysis confirms proposed scope beats DIM-FLEX (next ROADMAP alternative)
by 7×. Source: ROADMAP_REVIEW_PGMREL-070.md §1 + §3 T5.

### DQ-7: Does v0.7.0 scope introduce API-breaking changes?

**Answer: No breaking changes.**

- `recall_lessons()`: adds `confidence` column to output (named, additive — does not shift
  positional column indices for callers using column names; callers using positional index
  must update). SELECT * callers see one additional column.
- `ingest()`: no signature change; NOTICE is non-breaking.
- `reinforce()`: additive SP; no existing function modified.
- Migration: `ADD COLUMN DEFAULT` — no table rewrite on PG17.
Source: ROADMAP_REVIEW_PGMREL-070.md §4 API stability.

---

## 5. Benchmark Baselines to Capture Before Implementation

> Per ROADMAP_REVIEW_PGMREL-070.md §6, owner: research_supervisor.

1. **Run v0.6.3 LongMemEval-S (N=500, bge-m3 1024d)** to establish the ±0.001 reference
   number. The CHANGELOG value (0.9604) is the reference, but a pre-implementation
   snapshot run confirms reproducibility before the confidence column is wired in.
2. **Run `recall_diagnostics()` on Agency corpus** to capture current `bm25_coverage_pct`
   as a baseline for footgun F-4 (hybrid mislead).
3. **Snapshot `pgmnemo.stats()` on Agency corpus**: `ghost_count`, `orphan_count`,
   `active_lesson_count` — baseline for ingestion guard NOTICE rate estimation.

---

## 6. Sources Index

| Source | Path | Used in sections |
|--------|------|-----------------|
| POSITIONING_REFRESH_PGMREL-070.md | spec/v070/POSITIONING_REFRESH_PGMREL-070.md | 1, 2.3, 3.2, DQ-1, DQ-6 |
| ROADMAP_REVIEW_PGMREL-070.md | spec/v070/ROADMAP_REVIEW_PGMREL-070.md | 1, 2.1–2.4, 3.2, DQ-1–7, 5 |
| RESEARCH_v0.6.3.md | spec/v063/RESEARCH_v0.6.3.md | 2.1 F-1–F-5, DQ-4 |
| AGENCY_FOLLOWUP_RFC_2026-05-20.md | spec/AGENCY_FOLLOWUP_RFC_2026-05-20.md | 2.1, 2.4, DQ-2, DQ-4 |
| CHANGELOG.md | CHANGELOG.md | 1 (baseline metrics), 2.1 F-1 |
| MENTOR_REVIEW_2026-05-19.md | spec/v2/pgmnemo/MENTOR_REVIEW_2026-05-19.md | 3.1, 3.2, DQ-3 |
| VENDOR_BENCHMARK_VS_AGENTIC_DB_2026-05-09.md | spec/reports/VENDOR_BENCHMARK_VS_AGENTIC_DB_2026-05-09.md | 3.1 |
| WG_COMPETITOR_CAPABILITY_MATRIX.md | spec/v2/pgmnemo/WG_COMPETITOR_CAPABILITY_MATRIX.md | 3.1 |
| RESEARCH_V061.md | spec/v061/RESEARCH_V061.md | 1 (LoCoMo gate) |
| RESEARCH_V062.md | spec/v062/RESEARCH_V062.md | 2.2 (scoring formula lineage) |
| Cormack et al. 2009 (RRF) | arXiv / cited in RESEARCH_V062.md | 2.2 (RRF semantics) |
| PostgreSQL 17 documentation | (external) | 2.2 (ADD COLUMN behavior) |
| arXiv:2601.03236 (MAGMA) | cited in WG_COMPETITOR_CAPABILITY_MATRIX.md | 3.1 |
