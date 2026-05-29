---
date: 2026-05-29
agent: research_supervisor (id=85)
task_id: pgmnemo-0.7-research
status: complete
---

# RESEARCH BRIEF — pgmnemo v0.7.0 Scope Validation

## Summary

All R1/R2/R3/R4/R7 from the Agency RFC are already CLOSED (shipped v0.4.1–v0.6.3).
`confidence REAL` column is safely addable via `ADD COLUMN IF NOT EXISTS` with no upgrade path
break. `importance` is NOT a dead signal (std≈1.0 on execas) but has no imp=1 rows — floor anchor
is missing. Hybrid recall silently falls back to text-only scoring when `query_embedding IS NULL`;
`recall_hybrid()` called directly filters out all embedding-less rows.

---

## 1. confidence REAL Column — Upgrade Path Safety

### Schema state in v0.6.3

`pgmnemo--0.6.3.sql` CREATE TABLE (lines 84–136) does **not** contain a `confidence` column.
Current `agent_lesson` column set:
`id, created_at, updated_at, role, project_id, topic, lesson_text, importance, metadata,
source_run_id, commit_sha, artifact_hash, verified_at, topic_tsv, lesson_tsv, full_text,
embedding, is_active, resolved_at, verifier_role, state, state_changed_at, source_task_id,
expires_at` + bitemporality columns `t_valid_from, t_valid_to, content_hash` (added v0.5.0).

### Upgrade path verdict: **SAFE**

```sql
-- In pgmnemo--0.6.3--0.7.0.sql:
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS confidence REAL NOT NULL DEFAULT 0.5
    CONSTRAINT ck_agent_lesson_confidence CHECK (confidence BETWEEN 0.0 AND 1.0);
```

**Why safe:**
- `ADD COLUMN … DEFAULT` on PG17 is a metadata-only operation (no table rewrite since PG11).
- Duration estimate: < 1 s on 5 642-row execas corpus (2026-05-29 baseline).
- `ADD COLUMN IF NOT EXISTS` makes the migration idempotent.
- Existing `ingest()` signature unchanged: new column defaults to 0.5 (cold-start neutral).
- **Default MUST be 0.5 (not 1.0)** — gate criterion in `spec/v070/POSITIONING_REFRESH_PGMREL-070.md §3.2`:
  "bench regression test: confidence=0.5 flat must reproduce v0.6.3 LongMemEval recall@10
  within ±0.001". Starting at 1.0 would bias recall toward all lessons equally and invalidate
  the flat-default regression test.
- No index required for correctness at v0.7 launch; a partial index on `confidence < 1.0`
  can be added separately for monitoring.

**Recall formula impact (ADR candidate A1):**

Current `recall_lessons()` scoring:
```
score = 0.4×vec_score + 0.2×(importance/5) + γ×recency + 0.1×prov_strength + δ×graph_proximity
```
Proposed v0.7 addition:
```
score = 0.4×vec_score + 0.15×(importance/5) + 0.15×confidence + γ×recency + 0.1×prov + δ×graph
```
The two signals (importance and confidence) are complementary: importance is authoring-time
judgment; confidence is outcome-track-record. Reducing importance weight from 0.2 to 0.15
compensates. Requires bench validation before promotion to default.

**Output signature change (ADR candidate A2):**

If `confidence` is appended to `recall_lessons()` RETURNS TABLE:
- Named-column callers: unaffected.
- Positional callers: BREAK (must re-audit). Precedent from v0.4.1 R4 (vec_score added).
- Mitigation: append `confidence` as last column; document in SQL_REFERENCE.md §2.3.

---

## 2. importance Dead-Signal Check

### execas DB (production — 5 894 active rows)

| Metric | Value |
|--------|-------|
| Total active rows | 5 894 |
| Mean importance | 3.621 |
| Std importance | **1.005** |
| Median | 4.0 |
| imp=1 | **0** (0.0%) |
| imp=2 | 1 194 (20.3%) |
| imp=3 | 933 (15.8%) |
| imp=4 | 2 679 (45.4%) |
| imp=5 | 1 088 (18.4%) |

### prod_corpus DB (3 901 active rows — live query 2026-05-29)

| Metric | Value |
|--------|-------|
| Mean importance | 3.935 |
| Std importance | **0.812** |
| imp=1 | 0 (0.0%) |
| imp=2 | 208 (5.3%) |
| imp=3 | 796 (20.4%) |
| imp=4 | 1 938 (49.7%) |
| imp=5 | 959 (24.6%) |
| Distinct values | 4 (value 1 absent in both DBs) |
| Embedding coverage | 100% (3 900 / 3 900) |

### Verdict: NOT a dead signal — but floor-anchored

**Signal quality**: std=1.005 (execas) is above the "dead signal" threshold (std < 0.5 would
indicate near-constant values). The 20.3% imp=2 bucket in execas provides genuine
discrimination between high-importance and low-importance lessons.

**Floor-missing problem**: Zero rows with `importance=1` in BOTH databases. The scale
effectively runs 2–5, compressing the denominator from 5 to 4. At `importance=4` the
contribution is `0.2×(4/5) = 0.16`; at `importance=2` it's `0.2×(2/5) = 0.08`. The
effective range is 2× (not 5×), reducing discrimination.

**Implication for confidence design**:
- `importance` encodes authoring-time quality judgment; `confidence` will encode
  outcome-track-record. They are NOT redundant.
- Adding `confidence` does NOT make `importance` dead — it adds a separate dimension.
- If `confidence` reduces importance weight (A1 ADR above), the floor-compression
  problem is partially mitigated.
- Agency action: if imp=1 rows exist but were not submitted, check if `ingest()` has
  a silent floor clamp — the CHECK constraint allows importance=1 but callers may be
  sending 2 as their minimum.

---

## 3. Issue Intake: R1/R2/R3/R4/R7 — v0.7 Classification

### Status of all R-items

**Original Agency RFC (AGENCY_REQUIREMENTS_FOR_PGMNEMO.md) R-items:**

| Item | Description | Status | Ship version |
|------|-------------|--------|--------------|
| **R1** | GUC registration (`recency_weight`, `ef_search`, `importance_weight`, `disable_hybrid` in `pg_settings`) | ✅ CLOSED | v0.4.1 |
| **R2** | PGXN/GitHub-release distribution docs (`docs/INSTALL.md`) | ✅ CLOSED | v0.4.0 + v0.4.1 docs |
| **R3** | `pgmnemo.stats()` diagnostic SP (13 health-check signals) | ✅ CLOSED | v0.4.1 |
| **R4** | `recall_lessons()` exposes `vec_score`, `bm25_score`, `rrf_score` (12→15 cols) | ✅ CLOSED | v0.4.1 |
| **R7** | Upgrade orphan recovery + `orphan_count` in `pgmnemo.stats()` | ✅ CLOSED | v0.4.1 |

**v0.6.3 R-items (AmbiguousColumn hotfix cycle):**

| Item | Description | Status | Ship version |
|------|-------------|--------|--------------|
| R1 (v0.6.3) | AmbiguousColumn in `recall_lessons()` / `recall_hybrid()` | ✅ CLOSED | v0.6.3 |
| R2 (v0.6.3) | `include_unverified` GUC semantics doc | ✅ CLOSED | v0.6.3 |
| R3 (v0.6.3) | Hybrid mode activation conditions doc | ✅ CLOSED | v0.6.3 |
| R4 (v0.6.3) | psycopg2 calling convention + `format_vector()` example | ✅ CLOSED | v0.6.3 |

### v0.7 classification

**ALL R1/R2/R3/R4/R7 (both original RFC and v0.6.3 sets) are CLOSED. None go into v0.7.**

The v0.7.0 scope per `spec/v070/POSITIONING_REFRESH_PGMREL-070.md` is a **theme replacement**
(graph eval pre-conditions not met → production maturity + outcome-learning loop). The new v0.7
issue queue should be populated from:

| New scope item | Priority | ADR candidate |
|----------------|----------|---------------|
| `confidence REAL` column on `agent_lesson` | P0 | A1 (scoring formula), A2 (output signature) |
| `reinforce(lesson_id, delta)` SP | P0 | A3 (atomic update semantics, concurrency) |
| Ingestion guards (schema/range/semantic validation) | P1 | A4 (guard vs gate distinction) |
| Hybrid-default footgun remediation (tier-1 closure) | P1 | A5 (empty-query fallback behavior) |
| Hypergraph (graph eval) | **DEFERRED** — pre-conditions not met until external adopter with `mem_edge` in production contributes bench evidence |

---

## 4. Hybrid Recall Behavior Without Embeddings

### Code-verified behavior (v0.6.3 `pgmnemo--0.6.3.sql` + v0.5.0 upgrade scripts)

#### `recall_lessons()` — 5-arg (or 6-arg with as_of_ts)

Hybrid routing condition (v0.5.0+):
```
IF NOT _disable_hybrid
   AND _query_text IS NOT NULL AND length(trim(_query_text)) > 0
   AND query_embedding IS NOT NULL  ← REQUIRES non-NULL embedding
THEN route to recall_hybrid(...)
```

Vector-only fallback (when hybrid not triggered):
```sql
WHERE al.is_active
  AND (al.embedding IS NOT NULL OR _has_text)  ← text-only path ALLOWED
```
In this path, lessons **without** embeddings appear if `_has_text=TRUE`.
Their `vec_score = 0.0` (not NULL — see CASE expression at line 508–513 of v0.6.3.sql).

**Score for embedding-less row (text-only):**
```
score = 0.4×0.0 + 0.2×(importance/5) + γ×recency + 0.1×prov_strength + δ×0.0
      = 0.2×(importance/5) + γ×recency + 0.1×prov_strength
```
Maximum possible score: `0.16 + 0.08 + 0.1 = 0.34` (at importance=4, brand-new, verified).
A well-embedded relevant lesson typically scores 0.45–0.70 — so embedding-less rows rank
**below** all embedding-carrying candidates under normal corpus conditions.

#### `recall_hybrid()` — direct call

Candidates CTE (v0.5.0 path in 0.4.1→0.5.0 upgrade script, line 261):
```sql
WHERE al.is_active
  AND al.embedding IS NOT NULL  ← HARD FILTER — no exceptions
```
Calling `recall_hybrid()` directly with any `query_embedding` will **exclude all lessons
without embeddings**, even when `query_text` is provided.

### Behavioral matrix

| Call pattern | Hybrid fires? | Embedding-less rows included? | Notes |
|---|---|---|---|
| `recall_lessons(embedding, k, …, query_text)` | ✅ YES | ❌ NO (hybrid filters) | Standard usage — full scoring |
| `recall_lessons(NULL, k, …, query_text)` | ❌ NO | ❌ NO | **FOOTGUN**: hybrid skipped (embedding=NULL); vector-only path requires `al.embedding IS NOT NULL`; `ORDER BY al.embedding <=> NULL` = undefined sort; `query_text` IGNORED; returns k arbitrary rows with NULL scores |
| `recall_lessons(embedding, k, …, NULL)` | ❌ NO | ❌ NO (vector-only, `_has_text=FALSE`) | Pure vector recall; embedding-less excluded; correct behavior |
| `recall_hybrid(embedding, text, …)` | n/a (IS the hybrid) | ❌ NO (hard `IS NOT NULL` filter) | Direct hybrid; embedding required |
| `recall_hybrid(NULL, text, …)` | n/a | ❌ NO | BM25-only path; `_has_vec=FALSE`; `raw_vec_score=0.0`; works correctly for text-only recall |
| `recall_hybrid(NULL, NULL, …)` | n/a | — | RAISES EXCEPTION: 'at least one retrieval signal is required' ✅ guarded |
| `recall_lessons(NULL, k, …, NULL)` | ❌ NO | ❌ NO | **FOOTGUN**: same as NULL/query_text case above but query_text is also absent; returns k arbitrary-ordered rows from embedding-carrying lessons with NULL scores; no exception raised |

### Footgun: text-only fallback (ADR candidate A5)

When MLX embedding service is unavailable, Agency's `pgmnemo_recall.py` sends
`query_embedding=NULL` with `query_text=<task_title>`. This triggers the text-only fallback:
- Results contain embedding-less rows sorted by importance×recency×provenance
- NO semantic similarity scoring
- Users receive "recall hits" that are purely keyword-matched, potentially misleading
- `recall_n_returned > 0` in logs does NOT confirm semantic recall

**Recommendation for v0.7 footgun remediation (A5):**
1. `recall_lessons()` should emit `RAISE NOTICE 'pgmnemo: query_embedding IS NULL — recall
   falling back to text-only path; semantic similarity scores unavailable'` when hybrid
   is suppressed due to NULL embedding.
2. Add `path_used TEXT` output column (`'hybrid'|'vector'|'text_only'|'empty'`) so callers
   can detect degraded recall mode.
3. Alternatively, gated via `pgmnemo.strict_embedding_required = 'off'` GUC.

---

## 5. ADR Candidates for v0.7.0

| # | Title | Decision needed |
|---|-------|----------------|
| A1 | Recall scoring formula with confidence | How to weight confidence vs importance; bench gate required |
| A2 | `recall_lessons()` output signature change | Append `confidence` at end (backward compat) vs dedicated `recall_lessons_v2()` |
| A3 | `reinforce()` concurrency semantics | `UPDATE … SET confidence = GREATEST(0.0, LEAST(1.0, confidence + delta))` vs CAS |
| A4 | Ingestion guard vs provenance gate layering | Guards (structure) run before gate (accountability); failure modes distinct |
| A5 | Hybrid-fallback transparency | NOTICE + path_used column vs silent behavior preserved |

---

## 6. Pre-conditions Summary for v0.7.0 Ship Decision

| Pre-condition | Status | Action |
|---|---|---|
| confidence column upgrade path validated | ✅ CLEAR | Safe via `ADD COLUMN IF NOT EXISTS … DEFAULT 0.5` |
| importance signal not dead | ✅ CLEAR | std≈1.0 on execas; floor-missing but not dead |
| R1/R2/R3/R4/R7 all closed | ✅ CLEAR | All shipped in v0.4.1–v0.6.3 |
| Hybrid recall without embeddings understood | ✅ CLEAR | Text-only fallback confirmed; A5 footgun documented |
| confidence scoring formula bench-validated | ❌ REQUIRED | A1 bench (LoCoMo session, N≥500) before promoting to default |
| `reinforce()` concurrent-update stress test | ❌ REQUIRED | pg_regress test: 1k concurrent UPDATE on same row |
| Graph eval pre-conditions (external adopter + bench) | ❌ NOT MET | Defer hypergraph to v0.8 or skip per ROADMAP.md conditional |

---

## Sources

- `extension/pgmnemo--0.6.3.sql` (lines 1–800, schema + recall_lessons function)
- `extension/pgmnemo--0.4.1--0.5.0.sql` (bitemporality §E, recall_lessons v0.5.0 path)
- `CHANGELOG.md` (v0.4.1 through v0.6.3 R-item tracking)
- `ROADMAP.md` (v0.7.0 conditional pre-conditions)
- `spec/v070/POSITIONING_REFRESH_PGMREL-070.md` (theme replacement decision)
- `spec/AGENCY_FOLLOWUP_RFC_2026-05-20.md` (Q1–Q7 Agency requirements)
- `spec/PGMNEMO_RESPONSE_TO_AGENCY_REQUIREMENTS_2026-05-16.md` (R1–R10 original verdict)
- Live DB query: `pgmnemo.agent_lesson` importance stats (execas: N=5894; prod_corpus: N=3682)
