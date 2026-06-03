# RESEARCH — pgmnemo 0.8.0 navigate_locate/expand + maintenance + source_type

**DAG**: SWDEV-260603-1
**Date**: 2026-06-03
**Phase**: RESEARCH (reuse-point audit + design alternatives)

---

## 1. 0.7.2 Reuse-Point Audit

### 1.1 Schema (agent_lesson)

| Column | Type | Notes for 0.8.0 |
|--------|------|-----------------|
| `metadata` | JSONB (GIN-indexed, partial WHERE is_active) | **JSONB pushdown target**. Spec says `attributes`; actual column is `metadata`. All 0.8.0 JSONB filters use `metadata @> jsonb_filter`. |
| `lesson_text` | TEXT | Budget-cap window uses `length(lesson_text)`. |
| `lesson_tsv` | TSVECTOR (GIN-indexed, trigger-maintained) | BM25 path in recall_hybrid. |
| `embedding` | vector(1024) (HNSW, partial WHERE is_active) | Vector path. |
| `t_valid_from` / `t_valid_to` | TIMESTAMPTZ | Bitemporal. Active rows have `t_valid_to = 'infinity'`. |
| `content_hash` | TEXT, **GENERATED ALWAYS** | `MD5(role||project_id||topic||lesson_text)`. Cannot be SET directly. recompute_content must work around this. |
| `confidence` | REAL [0,1] DEFAULT 0.5 | 0.7.0+. Available for recall scoring. |
| `is_active` | BOOLEAN DEFAULT TRUE | Soft-delete. Partial indexes depend on it. |
| **`embedding_at`** | **DOES NOT EXIST** | Must ADD COLUMN. Tracks last embedding refresh timestamp. |
| **`source_type`** | **DOES NOT EXIST** | Must ADD COLUMN. CHECK constraint enum. |

### 1.2 recall_hybrid() CTE Pipeline (v0.6.2+)

```
raw_candidates → rrf_ranked → scored → anchors(top-5) → graph_walk(BFS causal+temporal) → graph_proximity → final ORDER+LIMIT
```

- **Reusable for navigate_locate**: Same ranking logic. navigate_locate adds (a) JSONB predicate pushdown in raw_candidates WHERE clause, (b) budget-cap window in final SELECT, (c) strips content from output.
- **Key detail**: recall_hybrid graph_walk uses `relation_type IN ('CAUSED_BY','CO_OCCURRED','DERIVED_FROM')` (uppercase strings), while recall_lessons vector-only path uses `edge_kind IN ('causal','temporal')` (ENUM). navigate_locate should use edge_kind (the canonical approach).

### 1.3 Bitemporal Trigger (_close_prior_version)

- Fires BEFORE INSERT on agent_lesson.
- If incoming row's `content_hash` matches an active row (`t_valid_to = 'infinity'`), closes the prior row (`t_valid_to = now()`).
- **Critical for reembed/recompute**: These functions UPDATE existing rows. UPDATE does NOT fire the BEFORE INSERT trigger. Safe by design — no special bypass needed.
- **recompute_content caveat**: `content_hash` is GENERATED ALWAYS AS `MD5(role||project_id||topic||lesson_text)`. When we UPDATE `lesson_text`, PG automatically recomputes `content_hash`. This is correct behavior — the content_hash should change to reflect the new content.

### 1.4 Indexes Relevant to 0.8.0

| Index | Supports |
|-------|----------|
| `pgmnemo_agent_lesson_metadata_idx` (GIN, partial) | JSONB pushdown (`metadata @> jsonb_filter`) |
| `pgmnemo_agent_lesson_embedding_idx` (HNSW) | Vector similarity in navigate_locate |
| `pgmnemo_agent_lesson_tsv_gin_idx` (GIN) | BM25 in navigate_locate |
| `ix_mem_edge_kind_causal` / `ix_mem_edge_kind_temporal` | Graph expand in navigate_expand |

### 1.5 mem_edge Graph Structure

- `edge_kind` ENUM: semantic, temporal, causal, entity.
- navigate_expand traversal uses `edge_kind IN ('causal','temporal')` — matches spec.
- Bidirectional traversal available via source_id/target_id indexes.

---

## 2. Design Decisions — >=3 Alternatives Per Key Area

### 2.1 navigate_locate: Ranking Implementation

**A) Inline CTE (copy recall_hybrid body, add JSONB gate + budget window)** [RECOMMENDED]

- Pros: Single self-contained function; no cross-function call overhead; can add JSONB pushdown directly in raw_candidates WHERE clause; planner sees full query → can push GIN predicate down.
- Cons: Code duplication with recall_hybrid (~100 lines of CTE logic duplicated). Maintenance burden if recall_hybrid scoring formula changes.
- Mechanism: JSONB predicate `AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)` in raw_candidates CTE. Budget cap via `SUM(length(al.lesson_text)) OVER (ORDER BY score DESC) <= token_budget_chars` in final output CTE.

**B) Wrapper around recall_hybrid (call recall_hybrid, post-filter + budget)**

- Pros: Zero code duplication; always inherits recall_hybrid improvements.
- Cons: JSONB pushdown CANNOT be pushed into recall_hybrid's candidate scan — it becomes a post-filter after recall_hybrid returns. This defeats the purpose of GIN index pushdown. recall_hybrid LIMIT k truncates results BEFORE JSONB filter, losing relevant matches.
- Verdict: **REJECTED** — violates JSONB pushdown requirement.

**C) Parameterized recall_hybrid (add jsonb_filter + budget params to recall_hybrid)**

- Pros: Single ranking function for all paths; no duplication.
- Cons: **Breaks additivity constraint**. Changing recall_hybrid signature is explicitly forbidden ("do not change existing recall_hybrid/recall_lessons signatures"). Adding optional params to existing function = signature change in PG (different overload, but existing callers with positional args could break).
- Verdict: **REJECTED** — violates additivity.

**D) SQL view + wrapper (create a view that pre-filters, navigate_locate queries the view)**

- Pros: Clean separation of concerns.
- Cons: Views cannot accept parameters (JSONB filter, budget). Would require SET-based GUCs for each parameter, which is fragile and non-reentrant. PL/pgSQL function is the right abstraction.
- Verdict: **REJECTED** — wrong abstraction level.

**Decision: A (Inline CTE)** — only option that satisfies both JSONB pushdown and additivity.

### 2.2 navigate_locate: Budget Enforcement Strategy

**A) Window SUM + WHERE cumulative <= budget** [RECOMMENDED]

- Pros: Standard SQL window pattern; clean; predictable. Returns all rows whose cumulative char sum does not exceed budget. Last included row may push total past budget by up to one lesson_text length.
- Cons: Slightly over-budget if last row is large (acceptable — budget is advisory, not a hard cap on bytes returned since navigate_locate doesn't return content).
- Mechanism: `SUM(length(lesson_text)) OVER (ORDER BY final_score DESC) AS cum_chars` then `WHERE cum_chars - length(lesson_text) < token_budget_chars` (ensures at least one row returned even if first row exceeds budget).

**B) PL/pgSQL loop with explicit accumulator**

- Pros: Exact budget enforcement (can stop at exact byte boundary).
- Cons: Row-by-row processing = slower; cannot use set-returning RETURN QUERY; more complex code.
- Verdict: Workable but unnecessary complexity — budget is advisory (navigate_locate returns IDs, not content).

**C) LIMIT based on estimated avg lesson size**

- Pros: Simple.
- Cons: Wildly inaccurate — lesson sizes vary 10x+. Defeats the purpose of budget-aware retrieval.
- Verdict: **REJECTED** — too imprecise.

**Decision: A** — window SUM with inclusive-first-row semantics.

### 2.3 navigate_expand: Graph Expansion Strategy

**A) Inline recursive CTE with depth + threshold filter** [RECOMMENDED]

- Pros: Single-pass recursive CTE; can filter by edge_kind IN ('causal','temporal') and weight >= threshold; depth-bounded; returns deduplicated neighbors.
- Cons: For deep graphs (depth>2), CTE can be expensive. Mitigated by default depth=1 and threshold filter.
- Mechanism: Start from input IDs where score >= graph_expand_threshold; recursive step JOINs mem_edge; cycle guard via `NOT (target_id = ANY(path))`; mark navigation_path='graph_expand' for new rows.

**B) Call traverse_causal_chain for each input ID**

- Pros: Reuses existing function; well-tested code.
- Cons: traverse_causal_chain traverses causal edges only (not temporal); returns full columns (role, topic, lesson_text) — navigate_expand needs different projection; N separate function calls for N input IDs (cannot batch); traverse_causal_chain has no score threshold filter.
- Verdict: **REJECTED** — wrong scope and cannot batch.

**C) Materialized adjacency via temp table + JOIN**

- Pros: Can pre-compute adjacency for all input IDs in one pass.
- Cons: Unnecessary — recursive CTE already handles this. Temp table adds DDL overhead.
- Verdict: Overkill.

**Decision: A** — inline recursive CTE.

### 2.4 reembed: Trigger Bypass Strategy

**A) Direct UPDATE (no bypass needed)** [RECOMMENDED]

- Pros: The bitemporal trigger `_close_prior_version` fires on INSERT only. UPDATE of embedding column does NOT trigger it. No bypass mechanism needed.
- Cons: None — this is correct by design.
- Mechanism: `UPDATE pgmnemo.agent_lesson SET embedding = new_vector, embedding_at = now(), updated_at = now() WHERE id = lesson_id`. The `_set_updated_at` trigger fires on UPDATE (desired). The `_close_prior_version` trigger fires on INSERT only (not triggered).

**B) Disable trigger temporarily (ALTER TABLE DISABLE TRIGGER)**

- Pros: Guarantees no trigger interference.
- Cons: **Requires superuser or table owner**. Breaks trusted=true constraint. Disables ALL triggers including _set_updated_at (undesirable). Race condition with concurrent INSERTs.
- Verdict: **REJECTED** — violates trusted PL/pgSQL constraint.

**C) Use session GUC flag to skip trigger logic**

- Pros: No privilege escalation.
- Cons: Trigger already doesn't fire on UPDATE. Adds unnecessary complexity and a new GUC to maintain.
- Verdict: **REJECTED** — solving a non-problem.

**Decision: A** — plain UPDATE. Bitemporal trigger is INSERT-only by definition.

### 2.5 recompute_content: content_hash Handling

**A) Let GENERATED ALWAYS recompute automatically** [RECOMMENDED]

- Pros: `content_hash` is `GENERATED ALWAYS AS (MD5(role||...||lesson_text))`. When we UPDATE lesson_text, PG automatically recomputes content_hash. This is exactly what we want — new content → new hash.
- Cons: If another row has the same content_hash after recomputation and is later INSERTed (not our concern here — we're UPDATEing, not INSERTing).
- Mechanism: `UPDATE pgmnemo.agent_lesson SET lesson_text = new_text WHERE id = lesson_id`. PG recalculates content_hash, lesson_tsv trigger fires to update the tsvector.

**B) DROP + re-ADD the generated column**

- Pros: None.
- Cons: Destructive; requires DDL; breaks the column definition for all rows.
- Verdict: **REJECTED** — absurd.

**C) UPDATE via system column bypass (pg_attribute manipulation)**

- Pros: None.
- Cons: Unsafe; requires superuser; not portable.
- Verdict: **REJECTED**.

**Decision: A** — let PG handle generated columns automatically.

### 2.6 reembed_batch: Concurrency Strategy

**A) FOR UPDATE SKIP LOCKED + ordered locking** [RECOMMENDED]

- Pros: Lock rows by ascending ID to prevent deadlocks with concurrent ingest(). SKIP LOCKED means concurrent batches skip already-locked rows (returns count of actually updated rows). No edge locks needed since we only update the lesson row's embedding.
- Cons: Caller must retry skipped rows. Acceptable — batch is best-effort by spec.
- Mechanism: `FOR i IN 1..array_length(lesson_ids,1) LOOP ... SELECT ... WHERE id = lesson_ids[i] FOR UPDATE SKIP LOCKED ... UPDATE ... END LOOP`. Return count of successful updates.

**B) Single UPDATE with subquery (no explicit locking)**

- Pros: Simpler. `UPDATE agent_lesson SET embedding = ... FROM unnest(ids, vecs) AS t(id, vec) WHERE agent_lesson.id = t.id`.
- Cons: No SKIP LOCKED semantics; blocks on locked rows; potential deadlock if concurrent batch locks rows in different order.
- Verdict: Workable but misses the lock-ordering requirement.

**C) Advisory locks**

- Pros: Non-blocking coordination.
- Cons: Overkill; advisory locks require manual lifecycle management; FOR UPDATE SKIP LOCKED is the standard PG pattern for this.
- Verdict: **REJECTED** — over-engineered.

**Decision: A** — FOR UPDATE SKIP LOCKED with ordered ID processing.

### 2.7 navigate_locate: navigation_path Derivation

**A) Dominant-signal tag from RRF components** [RECOMMENDED]

- Pros: navigation_path reflects HOW the result was found. If `jsonb_filter IS NOT NULL` and row matches, tag='jsonb_gate'. Otherwise compare vec_rank vs bm25_rank: better vec_rank → 'vector', better bm25_rank → 'bm25'.
- Cons: Heuristic — a row might score well on both signals. Acceptable for observability.
- Mechanism: CASE expression in final SELECT of navigate_locate CTE.

**B) Return array of all contributing signals**

- Pros: More informative.
- Cons: Spec says TEXT not TEXT[]; changes the API shape; downstream consumers expect a single string.
- Verdict: Violates spec.

**C) Always return 'hybrid'**

- Pros: Simple.
- Cons: Useless — provides no signal about how the result was located.
- Verdict: **REJECTED**.

**Decision: A** — dominant-signal tag.

---

## 3. Schema Delta Summary (0.7.2 → 0.8.0)

### New Columns on agent_lesson
```sql
ADD COLUMN source_type   TEXT CHECK (source_type IN ('agent_authored','auto_captured','imported','system'))
                         DEFAULT 'auto_captured';
ADD COLUMN embedding_at  TIMESTAMPTZ;  -- tracks last embedding refresh
```

### New Functions
| Function | Returns | Category |
|----------|---------|----------|
| `navigate_locate(vector(1024), text, int, jsonb)` | TABLE(id, score, tokens_consumed, navigation_path) | Navigation |
| `navigate_expand(bigint[], text[], int, float)` | TABLE(id, content, expand_detail, navigation_path) | Navigation |
| `reembed(bigint, vector(1024))` | void | Maintenance |
| `reembed_batch(bigint[], vector[])` | int | Maintenance |
| `recompute_content(bigint, text)` | void | Maintenance |

### Migration Files
- `extension/pgmnemo--0.7.2--0.8.0.sql` (upgrade path)
- `extension/pgmnemo--0.8.0.sql` (fresh install = full 0.7.2 + 0.8.0 delta)
- `extension/pgmnemo.control` (default_version bump)
- `META.json` (version bump)
- `CHANGELOG.md` (customer-readable entry)

---

## 4. Critical Observations

### 4.1 `metadata` vs `attributes` Column Name
The task spec references `attributes @> jsonb_filter`. The actual column in 0.7.2 is `metadata` (not `attributes`). **All 0.8.0 JSONB pushdown will use `metadata @> jsonb_filter`**. The GIN index `pgmnemo_agent_lesson_metadata_idx` covers this predicate.

### 4.2 recall_hybrid graph_walk Uses Old relation_type Strings
recall_hybrid's graph_walk filters on `relation_type IN ('CAUSED_BY','CO_OCCURRED','DERIVED_FROM')` — uppercase strings. recall_lessons' vector-only path uses `edge_kind IN ('causal','temporal')` — the ENUM. navigate_locate should use `edge_kind IN ('causal','temporal')` for consistency with the ENUM-based approach.

### 4.3 Bitemporal Safety of UPDATE Operations
Both reembed and recompute_content use UPDATE (not INSERT). The `_close_prior_version` trigger is BEFORE INSERT only. Therefore **no trigger bypass is needed** — UPDATE is inherently safe from bitemporal close-create churn.

### 4.4 GENERATED ALWAYS Constraint on content_hash
`content_hash` is `GENERATED ALWAYS AS (MD5(role||project_id||topic||lesson_text))`. It cannot be SET explicitly. recompute_content's UPDATE of lesson_text will automatically recompute content_hash. This is desired behavior.

### 4.5 lesson_tsv Trigger on UPDATE OF lesson_text
The trigger `pgmnemo_agent_lesson_tsv_trg` fires `BEFORE INSERT OR UPDATE OF lesson_text`. When recompute_content updates lesson_text, `lesson_tsv` is automatically refreshed. No manual tsvector update needed.

---

## 5. Verdict

All design decisions resolved. No blockers. Ready for PLAN phase.

- **navigate_locate**: Inline CTE (copied from recall_hybrid + JSONB gate + budget window)
- **navigate_expand**: Inline recursive CTE with edge_kind filter
- **reembed/reembed_batch**: Direct UPDATE + FOR UPDATE SKIP LOCKED (bitemporal trigger is INSERT-only)
- **recompute_content**: Direct UPDATE (GENERATED ALWAYS + lesson_tsv trigger handle cascade)
- **source_type**: Simple ALTER TABLE ADD COLUMN with CHECK constraint
