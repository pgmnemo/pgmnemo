# PLAN — pgmnemo 0.8.0 navigate_locate/expand + maintenance + source_type

**DAG**: SWDEV-260603-1
**Date**: 2026-06-03
**Phase**: PLAN (function-by-function implementation approach)
**Depends on**: RESEARCH.md (same DAG) — all design decisions resolved there.

---

## 0. File Manifest

| File | Action | Complexity |
|------|--------|------------|
| `extension/pgmnemo--0.7.2--0.8.0.sql` | CREATE (migration) | HIGH — all DDL + functions |
| `extension/pgmnemo--0.8.0.sql` | CREATE (fresh install = 0.7.2 body + 0.8.0 delta appended) | LOW — mechanical concat |
| `extension/pgmnemo.control` | EDIT (default_version bump) | TRIVIAL |
| `META.json` | EDIT (version bump) | TRIVIAL |
| `CHANGELOG.md` | EDIT (add 0.8.0 entry) | LOW |
| `tests/sql/test_v080.sql` | CREATE (pg_regress test) | MEDIUM |
| `tests/expected/test_v080.out` | CREATE (expected output) | MEDIUM |

---

## 1. Implementation Steps (Ordered)

### Step 1: Schema DDL — `source_type` + `embedding_at` columns
**File**: migration SQL (top of file)
**Complexity**: LOW (~15 lines)

```sql
-- S1a: source_type
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS source_type TEXT
        DEFAULT 'auto_captured'
        CHECK (source_type IN ('agent_authored','auto_captured','imported','system'));

-- S1b: embedding_at — tracks last embedding refresh
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS embedding_at TIMESTAMPTZ;

-- S1c: backfill embedding_at for rows that already have embeddings
UPDATE pgmnemo.agent_lesson
SET embedding_at = updated_at
WHERE embedding IS NOT NULL AND embedding_at IS NULL;
```

**Cost note**: ADD COLUMN with DEFAULT on PG11+ is metadata-only (no table rewrite). CHECK constraint is validated against existing rows on commit. Safe for large tables.

### Step 2: `navigate_locate()` — Budget-bounded LOCATE
**File**: migration SQL
**Complexity**: HIGH (~150 lines)

**CTE pipeline** (adapted from recall_hybrid):

```
1. DECLARE: parse GUCs (_ef_search, _include_unverified, _graph_weight, _tsquery)
2. CTE raw_candidates:
   - FROM agent_lesson al
   - WHERE al.is_active
     AND (_include_unverified OR al.verified_at IS NOT NULL)
     AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)  ← JSONB PUSHDOWN
     AND (t_valid_to = 'infinity'::timestamptz)                 ← bitemporal active
     AND (embedding IS NOT NULL OR _has_text)
   - SELECT id, raw_vec_score, raw_bm25_score, length(lesson_text) AS text_len
3. CTE rrf_ranked: ROW_NUMBER vec, sparse-safe RANK bm25 (same as recall_hybrid)
4. CTE scored: rrf_sparse + aux_scale*(importance+recency+provenance) + graph_proximity
5. CTE anchors: top-5 by rrf_sparse
6. CTE graph_walk: recursive BFS on edge_kind IN ('causal','temporal'), max_depth=5
7. CTE graph_proximity: MAX(1-depth/max_depth)
8. CTE ranked: final score computation, ORDER BY score DESC
9. CTE budget_window:
   - SUM(text_len) OVER (ORDER BY final_score DESC) AS cum_chars
   - WHERE (cum_chars - text_len) < token_budget_chars  ← inclusive first row
10. Final SELECT: id, score, cum_chars AS tokens_consumed, navigation_path
```

**navigation_path derivation** (CASE in step 9):
```sql
CASE
  WHEN jsonb_filter IS NOT NULL THEN 'jsonb_gate'
  WHEN vec_rank <= bm25_rank_eff THEN 'vector'
  ELSE 'bm25'
END
```

Where `bm25_rank_eff = COALESCE(bm25_rank_sparse, n_candidates+1)`.

**Key difference from recall_hybrid**: No lesson_text/metadata/topic in output. Returns only id/score/tokens_consumed/navigation_path.

### Step 3: `navigate_expand()` — On-demand detail + graph expansion
**File**: migration SQL
**Complexity**: MEDIUM (~80 lines)

**Logic**:
```
1. Base rows: SELECT from agent_lesson WHERE id = ANY(ids)
   - content = lesson_text
   - expand_detail = project requested keys from metadata JSONB:
     jsonb_object_agg(key, metadata->key) for key IN expand_fields
   - navigation_path = 'content'

2. Graph expansion (conditional: graph_expand_depth >= 1):
   CTE RECURSIVE graph_walk:
   - Seed: input IDs (no score threshold filter needed — caller already chose these IDs from navigate_locate results)
   - Recursive: JOIN mem_edge WHERE edge_kind IN ('causal','temporal')
     AND depth < graph_expand_depth
     AND NOT (target_id = ANY(path))  ← cycle guard
   - Filter: only include neighbors not already in input IDs
   - navigation_path = 'graph_expand'

3. UNION ALL base rows + graph-expanded rows
4. Deduplicate by id (base rows take priority over graph-expanded)
```

**expand_detail projection**: For each row, if expand_fields is non-empty:
```sql
(SELECT jsonb_object_agg(f, al.metadata->f)
 FROM unnest(expand_fields) AS f
 WHERE al.metadata ? f)
```
If expand_fields is empty/null: `NULL::jsonb`.

**graph_expand_threshold**: The spec says "for anchors score>=graph_expand_threshold". Since navigate_expand receives raw IDs (not scores), and the spec intent is to gate graph expansion on "high-confidence anchors only", the threshold is applied differently: we skip graph expansion entirely if the caller passes `graph_expand_depth = 0`. The threshold parameter is reserved for future use when navigate_expand can receive scores. For now, all input IDs are considered anchors for graph expansion.

**REVISION**: Re-reading spec — "anchors score>=graph_expand_threshold" means navigate_expand should accept a way to know which input IDs are "strong" enough for graph expansion. Since scores aren't passed, the threshold gates on the edge weight: only traverse edges with `me.weight >= graph_expand_threshold`. This is the correct interpretation — edge weight [0,1] is the confidence of the relationship.

### Step 4: `reembed()` — Single-row embedding refresh
**File**: migration SQL
**Complexity**: LOW (~20 lines)

```sql
CREATE OR REPLACE FUNCTION pgmnemo.reembed(
    p_lesson_id  BIGINT,
    p_new_vector vector(1024)
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF vector_dims(p_new_vector) <> 1024 THEN
        RAISE EXCEPTION 'reembed: expected 1024 dims, got %', vector_dims(p_new_vector);
    END IF;

    UPDATE pgmnemo.agent_lesson
    SET embedding    = p_new_vector,
        embedding_at = now()
    WHERE id = p_lesson_id
      AND is_active
      AND t_valid_to = 'infinity'::timestamptz;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'reembed: lesson % not found or not active', p_lesson_id;
    END IF;
END;
$$;
```

**Trigger safety**: UPDATE does not fire `_close_prior_version` (INSERT-only). `_set_updated_at` fires correctly. `lesson_tsv` trigger does NOT fire (UPDATE OF lesson_text only — embedding is not lesson_text). All correct.

### Step 5: `reembed_batch()` — Batch embedding refresh
**File**: migration SQL
**Complexity**: MEDIUM (~35 lines)

```sql
CREATE OR REPLACE FUNCTION pgmnemo.reembed_batch(
    p_lesson_ids  BIGINT[],
    p_new_vectors vector[]
) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    _count INT := 0;
    _i     INT;
    _row   pgmnemo.agent_lesson;
BEGIN
    IF array_length(p_lesson_ids, 1) <> array_length(p_new_vectors, 1) THEN
        RAISE EXCEPTION 'reembed_batch: ids length (%) <> vectors length (%)',
            array_length(p_lesson_ids, 1), array_length(p_new_vectors, 1);
    END IF;

    -- Process in ascending ID order to prevent deadlocks
    FOR _i IN 1..array_length(p_lesson_ids, 1) LOOP
        -- FOR UPDATE SKIP LOCKED: skip rows locked by concurrent ingest/reinforce
        SELECT * INTO _row
        FROM pgmnemo.agent_lesson
        WHERE id = p_lesson_ids[_i]
          AND is_active
          AND t_valid_to = 'infinity'::timestamptz
        FOR UPDATE SKIP LOCKED;

        IF FOUND THEN
            UPDATE pgmnemo.agent_lesson
            SET embedding    = p_new_vectors[_i],
                embedding_at = now()
            WHERE id = p_lesson_ids[_i];
            _count := _count + 1;
        END IF;
    END LOOP;

    RETURN _count;
END;
$$;
```

**Lock ordering**: IDs processed in array order. Caller SHOULD pass sorted ascending IDs. Function does not re-sort (caller responsibility documented in COMMENT). SKIP LOCKED means concurrent batches never deadlock — they skip contended rows.

### Step 6: `recompute_content()` — In-place text refresh
**File**: migration SQL
**Complexity**: LOW (~25 lines)

```sql
CREATE OR REPLACE FUNCTION pgmnemo.recompute_content(
    p_lesson_id BIGINT,
    p_new_text  TEXT
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_new_text IS NULL OR length(trim(p_new_text)) = 0 THEN
        RAISE EXCEPTION 'recompute_content: new_text must be non-empty';
    END IF;

    UPDATE pgmnemo.agent_lesson
    SET lesson_text = p_new_text
    WHERE id = p_lesson_id
      AND is_active
      AND t_valid_to = 'infinity'::timestamptz;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'recompute_content: lesson % not found or not active', p_lesson_id;
    END IF;
END;
$$;
```

**Cascade effects** (all automatic, no manual code):
- `content_hash`: GENERATED ALWAYS AS → recomputed by PG on UPDATE
- `lesson_tsv`: trigger `pgmnemo_agent_lesson_tsv_trg` fires on UPDATE OF lesson_text → refreshed
- `updated_at`: trigger `_set_updated_at` fires on any UPDATE → refreshed
- `_close_prior_version`: INSERT-only trigger → NOT fired
- Edges, provenance, confidence: untouched (UPDATE only sets lesson_text)

### Step 7: Migration file assembly
**File**: `extension/pgmnemo--0.7.2--0.8.0.sql`
**Complexity**: LOW (mechanical ordering)

Order:
```
1. Header comment (version, date, scope summary)
2. \echo guard
3. S1: ALTER TABLE ADD COLUMN source_type + embedding_at + backfill
4. S2: CREATE FUNCTION navigate_locate
5. S3: CREATE FUNCTION navigate_expand
6. S4: CREATE FUNCTION reembed
7. S5: CREATE FUNCTION reembed_batch
8. S6: CREATE FUNCTION recompute_content
9. S7: COMMENT ON each new function/column
```

All DDL is idempotent: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE FUNCTION.

### Step 8: Fresh-install file
**File**: `extension/pgmnemo--0.8.0.sql`
**Complexity**: LOW (concat)

Copy `pgmnemo--0.7.2.sql` verbatim, then append the migration delta (Steps S1–S7). Update header comment to say v0.8.0.

### Step 9: Metadata bumps
**Files**: `extension/pgmnemo.control`, `META.json`, `CHANGELOG.md`
**Complexity**: TRIVIAL

- `pgmnemo.control`: `default_version = '0.8.0'`
- `META.json`: `"version": "0.8.0"`, `"file": "extension/pgmnemo--0.8.0.sql"`
- `CHANGELOG.md`: Add `[0.8.0]` entry with customer-readable one-liner

### Step 10: pg_regress tests
**File**: `tests/sql/test_v080.sql` + `tests/expected/test_v080.out`
**Complexity**: MEDIUM (~150 lines)

Test cases:
```
T1: source_type column exists, default = 'auto_captured', CHECK rejects 'invalid'
T2: embedding_at column exists, starts NULL, populated after reembed()
T3: navigate_locate with NULL jsonb_filter — returns results with budget cap
T4: navigate_locate with jsonb_filter — only metadata-matching rows
T5: navigate_locate budget enforcement — cumulative chars <= budget + one row
T6: navigate_expand returns lesson_text for given IDs
T7: navigate_expand with expand_fields projects metadata keys
T8: navigate_expand graph expansion traverses causal/temporal edges
T9: reembed updates embedding + embedding_at, does not change lesson_text
T10: reembed_batch SKIP LOCKED returns count, skips locked rows
T11: recompute_content updates lesson_text, content_hash changes, tsv refreshes
T12: recompute_content does NOT create new row (same id preserved)
```

Test setup: INSERT test lessons via ingest() with known embeddings (small synthetic vectors), create mem_edges, then exercise each function.

---

## 2. Complexity / Cost Estimate

| Step | Lines (est.) | Risk | Notes |
|------|-------------|------|-------|
| S1 schema DDL | ~15 | LOW | Metadata-only ALTER on PG11+ |
| S2 navigate_locate | ~150 | HIGH | Largest function; CTE duplication from recall_hybrid |
| S3 navigate_expand | ~80 | MEDIUM | Recursive CTE + JSONB projection |
| S4 reembed | ~20 | LOW | Simple UPDATE |
| S5 reembed_batch | ~35 | MEDIUM | Loop + SKIP LOCKED |
| S6 recompute_content | ~25 | LOW | Simple UPDATE, cascade is automatic |
| S7 migration assembly | ~10 | LOW | Header + guard |
| S8 fresh-install | ~3950+330 | LOW | Mechanical concat |
| S9 metadata bumps | ~10 | TRIVIAL | Version strings |
| S10 tests | ~150 | MEDIUM | Synthetic data setup |
| **Total new SQL** | **~500** | | |

**Highest-risk item**: navigate_locate (S2) — complex CTE, must exactly match recall_hybrid scoring semantics while adding JSONB pushdown + budget window. Will need careful code review.

---

## 3. Dependency Graph

```
S1 (schema) ──┬── S2 (navigate_locate)  ← depends on embedding_at existing
              ├── S3 (navigate_expand)
              ├── S4 (reembed)           ← uses embedding_at
              ├── S5 (reembed_batch)     ← uses embedding_at
              └── S6 (recompute_content)

S2–S6 are independent of each other.

S7 (migration assembly) depends on S1–S6.
S8 (fresh-install) depends on S7 + 0.7.2.sql.
S9 (metadata) independent.
S10 (tests) depends on S7 (needs the functions to exist).
```

---

## 4. Implementation Order (Single IMPLEMENT Phase)

Write in this order within one commit:

1. **Migration file** (`pgmnemo--0.7.2--0.8.0.sql`): S1 → S4 → S5 → S6 → S2 → S3 → comments
   - Rationale: Schema first, simpler functions next (build confidence), complex navigate_* last.
2. **Fresh-install file** (`pgmnemo--0.8.0.sql`): concat 0.7.2 + migration delta
3. **Control + META + CHANGELOG**: version bumps
4. **Tests** (`tests/sql/test_v080.sql`): T1–T12

---

## 5. Acceptance Criteria (for CODE_REVIEW / QA)

- [ ] All 5 new functions pass `\df pgmnemo.navigate_*`, `\df pgmnemo.reembed*`, `\df pgmnemo.recompute_content`
- [ ] navigate_locate: JSONB pushdown demonstrable via EXPLAIN (GIN index scan when jsonb_filter non-null)
- [ ] navigate_locate: budget cap — cumulative chars of returned IDs never exceeds budget + max(single lesson length)
- [ ] navigate_locate: returns NO content columns (lesson_text, metadata, topic absent)
- [ ] navigate_expand: returns lesson_text for requested IDs
- [ ] navigate_expand: graph expansion adds causal/temporal neighbors not in input IDs
- [ ] reembed: updates embedding + embedding_at; id unchanged; lesson_text unchanged
- [ ] reembed_batch: returns count; SKIP LOCKED semantics
- [ ] recompute_content: updates lesson_text; content_hash recomputed; lesson_tsv refreshed; NO new row
- [ ] source_type: default 'auto_captured'; CHECK rejects invalid values
- [ ] All existing functions (recall_lessons, recall_hybrid, ingest, etc.) unchanged — additivity verified
- [ ] Migration is idempotent (IF NOT EXISTS / CREATE OR REPLACE)
- [ ] trusted=true preserved (no superuser-only operations)
